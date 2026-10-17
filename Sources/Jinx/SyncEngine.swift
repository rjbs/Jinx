import Foundation
import JinxJSON
import JinxPatch
import JinxStore
import JinxWire

/// How an engine is set up.
public struct SyncConfiguration: Sendable {
  public var accountId: String
  public var types: [TypeDescriptor]
  /// Identifies this process in pending-log claims.
  public var processId: String
  /// A claim older than this belongs to a pusher that died.
  public var claimStaleAfter: TimeInterval
  /// Upper bound on objects fetched per `/get`, below the server's.
  public var fetchChunk: Int?
  /// A Darwin notification name shared by every process on this store,
  /// so each learns of the others' commits.  `nil` disables it.
  public var signalName: String?

  public init(
    accountId: String,
    types: [TypeDescriptor],
    processId: String = UUID().uuidString,
    claimStaleAfter: TimeInterval = 120,
    fetchChunk: Int? = nil,
    signalName: String? = nil
  ) {
    self.accountId = accountId
    self.types = types
    self.processId = processId
    self.claimStaleAfter = claimStaleAfter
    self.fetchChunk = fetchChunk
    self.signalName = signalName
  }
}

/// What an app shows in a settings pane.
public struct SyncStatus: Sendable, Hashable {
  public var isConnected = false
  public var lastPull: Date?
  public var lastPush: Date?
  public var pendingCount = 0
  public var lastFailure: String?
  /// Types whose initial sync is still running: fetched so far, and
  /// the total when known.
  public var initialSync: [String: InitialSyncProgress] = [:]

  public init() {}
}

public struct InitialSyncProgress: Sendable, Hashable {
  public var fetched: Int
  public var total: Int?
}

/// An object as the engine hands it out.
public struct SyncedObject: Sendable, Hashable {
  public var key: LocalKey
  public var type: String
  public var id: String?
  public var value: JSONValue
  public var pending: PendingOperation?
  public var lastError: SetError?

  init(_ stored: StoredObject) {
    key = stored.key
    type = stored.type
    id = stored.id
    value = stored.local
    pending = stored.pending
    lastError = stored.lastError
  }
}

/// The sync engine: one per account per process.  It owns the pending
/// log, runs push and pull, and reports every committed change on its
/// change stream.  It is an actor and never runs on the main actor;
/// everything it hands out is a `Sendable` value.
public actor SyncEngine<Store: SyncStore> {
  public nonisolated let configuration: SyncConfiguration
  let transport: any JMAPTransport
  let store: Store
  let descriptors: [String: TypeDescriptor]
  let orderedTypes: [TypeDescriptor]

  var session: Session?
  var status = SyncStatus()
  /// Types a push response or push notification said have moved on.
  var pullNeeded: Set<String> = []
  /// Set after a lost response, so the next pass pulls before it
  /// resends creates; see `Push`.
  var reconcileBeforePush = false
  /// Per-type cap on `/set` batch size, lowered after `requestTooLarge`.
  var setChunk: [String: Int] = [:]
  private var subscribers: [UUID: AsyncStream<ChangeSet>.Continuation] = [:]
  var journalCursor: Int64 = 0
  var journalCursorSet = false
  var wake: AsyncStream<Void>.Continuation?
  var syncRequested = false
  var tailRequested = false

  public init(configuration: SyncConfiguration, transport: any JMAPTransport, store: Store) throws(SyncError) {
    self.configuration = configuration
    self.transport = transport
    self.store = store
    self.orderedTypes = try configuration.types.inDependencyOrder()
    self.descriptors = Dictionary(uniqueKeysWithValues: orderedTypes.map { ($0.name, $0) })
  }

  var accountId: String { configuration.accountId }

  // MARK: - Session

  /// Fetches the session resource.  Called by the first sync; call it
  /// early to surface connection problems.
  @discardableResult
  public func connect() async throws(JMAPError) -> Session {
    let session = try await transport.fetchSession()
    self.session = session
    status.isConnected = true
    return session
  }

  func currentSession() async throws(JMAPError) -> Session {
    if let session { return session }
    return try await connect()
  }

  var capabilities: Set<String> {
    Set(orderedTypes.map(\.capability)).union([Session.coreCapability])
  }

  // MARK: - Reads

  public func object(key: LocalKey) async throws -> SyncedObject? {
    try await store.read { tx in try tx.object(key: key).map(SyncedObject.init) }
  }

  public func object(type: String, id: String) async throws -> SyncedObject? {
    let accountId = accountId
    return try await store.read { tx in try tx.object(accountId: accountId, type: type, id: id).map(SyncedObject.init) }
  }

  public func objects(keys: [LocalKey]) async throws -> [SyncedObject] {
    try await store.read { tx in try tx.objects(keys: keys).map(SyncedObject.init) }
  }

  /// Every object of a type, in local key order.
  public func objects(type: String) async throws -> [SyncedObject] {
    let accountId = accountId
    return try await store.read { tx in try tx.objects(accountId: accountId, type: type).map(SyncedObject.init) }
  }

  public func currentStatus() async throws -> SyncStatus {
    var status = self.status
    let accountId = accountId
    status.pendingCount = try await store.read { tx in try tx.pendingEntries(accountId: accountId).count }
    return status
  }

  public func state(of type: String) async throws -> String? {
    let accountId = accountId
    return try await store.read { tx in try tx.state(accountId: accountId, type: type) }
  }

  // MARK: - Change stream

  /// A stream of every change set committed from now on, by this
  /// process or, once cross-process delivery is wired, another.
  public func changes() -> AsyncStream<ChangeSet> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<ChangeSet>.makeStream()
    subscribers[id] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeSubscriber(id) }
    }
    return stream
  }

  private func removeSubscriber(_ id: UUID) {
    subscribers[id] = nil
  }

  func emit(_ changeSet: ChangeSet) {
    guard !changeSet.isEmpty else { return }
    for continuation in subscribers.values {
      continuation.yield(changeSet)
    }
  }

  /// Runs a store write, journals its change set, and emits it.
  func commit<T: Sendable>(
    _ body: @Sendable (Store.Transaction, inout ChangeSet) throws -> T,
    source: ChangeSet.Source
  ) async throws -> T {
    let accountId = accountId
    let processId = configuration.processId
    let (result, changeSet) = try await store.write { tx -> (T, ChangeSet) in
      var changeSet = ChangeSet(accountId: accountId, source: source)
      let result = try body(tx, &changeSet)
      if !changeSet.isEmpty {
        try tx.appendJournal(changeSet, processId: processId)
      }
      return (result, changeSet)
    }
    emit(changeSet)
    if !changeSet.isEmpty {
      if let name = configuration.signalName { DarwinNotification.post(name) }
      if source == .local { requestSync() }
    }
    return result
  }

  // MARK: - Sync

  /// One full pass: push pending changes, then pull.  Throws
  /// `SyncError.retryable` for a failure worth retrying, and lets other
  /// errors through.
  public func sync() async throws {
    if reconcileBeforePush {
      try await pull()
      reconcileBeforePush = false
    }
    // A push that fails for a retryable reason still leaves the pull
    // worth running: the pending entries are kept and will rebase onto
    // whatever arrives, and the app gets fresh data while its writes
    // wait. -- claude, 2026-10-17
    var pushFailure: (any Error)?
    do {
      try await push()
    } catch SyncError.retryable(let reason) {
      pushFailure = SyncError.retryable(reason)
    }
    try await pull()
    if let pushFailure { throw pushFailure }
  }
}

extension SyncEngine {
  func descriptor(_ type: String) throws(SyncError) -> TypeDescriptor {
    guard let descriptor = descriptors[type] else { throw .unknownType(type) }
    return descriptor
  }
}
