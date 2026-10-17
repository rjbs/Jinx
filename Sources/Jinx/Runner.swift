import Cnotify
import Foundation
import JinxStore
import JinxWire

/// Darwin notifications: a name posted by one process and observed by
/// others on the same machine, carrying no payload.  Jinx uses one per
/// shared database so that a commit in one process wakes the engine in
/// another to read the journal.
public enum DarwinNotification {
  public static func post(_ name: String) {
    notify_post(name)
  }

  /// Observes `name` until the returned token is cancelled.  The
  /// handler runs on `queue`.
  public static func observe(
    _ name: String,
    queue: DispatchQueue = .global(),
    handler: @escaping @Sendable () -> Void
  ) -> Int32? {
    var token: Int32 = 0
    let status = notify_register_dispatch(name, &token, queue) { _ in handler() }
    return status == UInt32(NOTIFY_STATUS_OK) ? token : nil
  }

  public static func cancel(_ token: Int32) {
    notify_cancel(token)
  }
}

/// Why the run loop woke.
enum Wake: Sendable {
  case sync
  case tail
}

extension SyncEngine {
  /// Asks the run loop, if one is running, for a sync pass soon.  Local
  /// writes call this; an app can too.
  public func requestSync() {
    syncRequested = true
    wake?.yield(())
  }

  func requestTail() {
    tailRequested = true
    wake?.yield(())
  }

  /// Emits change sets other processes committed since the last tail.
  /// The first call sets the cursor at the present, so history is not
  /// replayed; call it (or `run`) early.
  public func tailJournal() async throws {
    let processId = configuration.processId
    if !journalCursorSet {
      journalCursor = try await store.read { tx in try tx.latestJournalSeq() }
      journalCursorSet = true
      return
    }
    let cursor = journalCursor
    let entries = try await store.read { tx in try tx.journal(after: cursor) }
    for entry in entries {
      journalCursor = entry.seq
      if entry.processId != processId {
        emit(entry.changeSet)
      }
    }
  }

  /// Keeps the account in sync until the calling task is cancelled.
  ///
  /// Connects, listens for push notifications and reconnects when they
  /// drop, syncs after every local write and every notification with
  /// a short debounce, retries with backoff after a retryable failure,
  /// polls on `pollInterval` when given, and tails the journal when
  /// another process signals a commit.
  public func run(
    backoff: Backoff = Backoff(),
    debounce: Duration = .milliseconds(100),
    pollInterval: Duration? = nil
  ) async {
    let (wakeups, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    wake = continuation
    defer { wake = nil }
    try? await tailJournal()

    let pushTask = Task { [weak self] in await self?.listenForPush() }
    let pollTask = pollInterval.map { interval in
      Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: interval)
          await self?.requestSync()
        }
      }
    }
    var signalToken: Int32?
    if let name = configuration.signalName {
      signalToken = DarwinNotification.observe(name) { [weak self] in
        Task { await self?.requestTail() }
      }
    }
    defer {
      pushTask.cancel()
      pollTask?.cancel()
      if let signalToken { DarwinNotification.cancel(signalToken) }
    }

    var delays = backoff.delays().makeIterator()
    var retryTask: Task<Void, Never>?
    requestSync()
    for await _ in wakeups {
      if Task.isCancelled { break }
      if tailRequested {
        tailRequested = false
        try? await tailJournal()
      }
      guard syncRequested else { continue }
      syncRequested = false
      try? await Task.sleep(for: debounce)
      if Task.isCancelled { break }
      do {
        try await sync()
        delays = backoff.delays().makeIterator()
        status.lastFailure = nil
      } catch SyncError.retryable {
        let delay = delays.next() ?? backoff.maximum
        retryTask?.cancel()
        retryTask = Task { [weak self] in
          try? await Task.sleep(for: delay)
          guard !Task.isCancelled else { return }
          await self?.requestSync()
        }
      } catch {
        status.lastFailure = String(describing: error)
      }
      try? await tailJournal()
    }
    retryTask?.cancel()
  }

  /// Holds the push connection open and turns state changes into sync
  /// requests.  Runs until cancelled.
  private func listenForPush() async {
    var delays = Backoff().delays().makeIterator()
    while !Task.isCancelled {
      guard let session = try? await currentSession(),
            let url = EventSourceClient.url(from: session, types: orderedTypes.map(\.name))
      else {
        status.isConnected = false
        try? await Task.sleep(for: delays.next() ?? .seconds(60))
        continue
      }
      let client = EventSourceClient(transport: transport, url: url)
      for await event in client.events() {
        if Task.isCancelled { return }
        switch event {
        case .connected:
          status.isConnected = true
        case .stateChange(let change):
          guard let types = change.changed[accountId] else { continue }
          var any = false
          for (type, _) in types where descriptors[type] != nil {
            pullNeeded.insert(type)
            any = true
          }
          if any { requestSync() }
        case .ping:
          break
        case .disconnected:
          status.isConnected = false
        }
      }
    }
  }
}
