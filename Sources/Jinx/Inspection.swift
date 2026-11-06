import Foundation
import JinxJSON
import JinxPatch
import JinxStore
import JinxWire

/// A read-only look inside a sync engine and its store, for diagnostic
/// tools.  Nothing here changes anything, and nothing here is needed to
/// use the engine; an app's own code should stay on the ordinary API.
///
/// The protocol is not generic over the store, so a tool can hold any
/// engine as `any SyncInspecting`.
public protocol SyncInspecting: Sendable {
  var inspectedAccountId: String { get }
  /// Every configured type, in dependency order, with its counts.
  func inspectTypes() async throws -> [InspectedType]
  /// Every object of a type the store holds, in local key order.
  func inspectObjects(type: String) async throws -> [InspectedObject]
  /// The pending log, in log order.
  func inspectPending() async throws -> [PendingEntry]
  func inspectSubscriptions() async throws -> [InspectedSubscription]
  func inspectBlobs() async throws -> [BlobRecord]
  /// The most recent journal entries, oldest first.
  func inspectJournal(limit: Int) async throws -> [JournalEntry]
  func inspectStatus() async throws -> SyncStatus
  /// Every change set committed from now on, to know when to look again.
  func inspectChanges() async -> AsyncStream<ChangeSet>
  /// Attaches a tap that sees every exchange with the server from now
  /// on, until the token is cancelled or released.
  func addWireTap(_ tap: any WireTap) -> WireTapToken
}

public struct InspectedType: Sendable, Hashable, Identifiable {
  public var name: String
  public var mode: TypeDescriptor.Mode
  public var serverState: String?
  public var count: Int
  public var pendingCount: Int
  public var pinnedCount: Int

  public var id: String { name }
}

public struct InspectedObject: Sendable, Hashable, Identifiable {
  public var stored: StoredObject
  /// The pending log entry, with its claim, when there is one.
  public var pendingEntry: PendingEntry?
  public var isPinned: Bool
  /// What the local value changes from the server version, as the
  /// sync-out would send it; `nil` when the server has never seen the
  /// object, and empty when the two agree.
  public var localPatch: PatchObject?

  public var id: LocalKey { stored.key }
}

public struct InspectedSubscription: Sendable, Hashable, Identifiable {
  public var subscription: QuerySubscription
  public var result: SubscriptionResult?

  public var id: String { subscription.id }
}

extension SyncEngine: SyncInspecting {
  public nonisolated var inspectedAccountId: String { configuration.accountId }

  public func inspectTypes() async throws -> [InspectedType] {
    let accountId = accountId
    let types = orderedTypes.map { ($0.name, $0.mode) }
    return try await store.read { tx in
      let pending = try tx.pendingEntries(accountId: accountId)
      return try types.map { name, mode in
        InspectedType(
          name: name,
          mode: mode,
          serverState: try tx.serverState(accountId: accountId, type: name),
          count: try tx.count(accountId: accountId, type: name),
          pendingCount: pending.count { $0.type == name },
          pinnedCount: try tx.pins(accountId: accountId, type: name).count
        )
      }
    }
  }

  public func inspectObjects(type: String) async throws -> [InspectedObject] {
    let accountId = accountId
    let mayPatch = descriptors[type]?.mayPatch ?? patchAnywhere
    return try await store.read { tx in
      let pins = try tx.pins(accountId: accountId, type: type)
      let pending = Dictionary(
        try tx.pendingEntries(accountId: accountId).filter { $0.type == type }.map { ($0.key, $0) },
        uniquingKeysWith: { _, last in last }
      )
      return try tx.objects(accountId: accountId, type: type).map { object in
        InspectedObject(
          stored: object,
          pendingEntry: pending[object.key],
          isPinned: object.id.map(pins.contains) ?? false,
          localPatch: object.serverVersion.flatMap { try? PatchObject.diff(from: $0, to: object.local, mayPatch: mayPatch) }
        )
      }
    }
  }

  public func inspectPending() async throws -> [PendingEntry] {
    let accountId = accountId
    return try await store.read { tx in try tx.pendingEntries(accountId: accountId) }
  }

  public func inspectSubscriptions() async throws -> [InspectedSubscription] {
    let accountId = accountId
    return try await store.read { tx in
      try tx.subscriptions(accountId: accountId).map { sub in
        InspectedSubscription(subscription: sub, result: try tx.subscriptionResult(accountId: accountId, id: sub.id))
      }
    }
  }

  public func inspectBlobs() async throws -> [BlobRecord] {
    let accountId = accountId
    return try await store.read { tx in try tx.blobs(accountId: accountId) }
  }

  public func inspectJournal(limit: Int) async throws -> [JournalEntry] {
    try await store.read { tx in
      let latest = try tx.latestJournalSeq()
      return try tx.journal(after: max(0, latest - Int64(limit)))
    }
  }

  public func inspectStatus() async throws -> SyncStatus {
    try await currentStatus()
  }

  public func inspectChanges() async -> AsyncStream<ChangeSet> {
    changes()
  }
}
