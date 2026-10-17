import Foundation
import JinxJSON

/// Persistent storage for the sync engine.  Jinx ships `GRDBSyncStore`;
/// the protocol is public so that an app with unusual needs can supply
/// its own, and its stability is part of Jinx's contract.
///
/// All access goes through transactions.  A `write` sees and makes a
/// consistent state; a `read` sees a snapshot.  The closures are
/// synchronous because the stores they wrap are, and they run wherever
/// the store runs them, which is never the main actor.
public protocol SyncStore: Sendable {
  associatedtype Transaction: SyncTransaction

  func read<T: Sendable>(_ body: @Sendable (Transaction) throws -> T) async throws -> T
  func write<T: Sendable>(_ body: @Sendable (Transaction) throws -> T) async throws -> T
}

/// One transaction's view of the store.
public protocol SyncTransaction {
  // MARK: Objects

  func object(key: LocalKey) throws -> StoredObject?
  func object(accountId: String, type: String, id: String) throws -> StoredObject?
  func objects(keys: [LocalKey]) throws -> [StoredObject]
  func objects(accountId: String, type: String, ids: [String]) throws -> [StoredObject]
  /// Every object of a type, in local key order.
  func objects(accountId: String, type: String) throws -> [StoredObject]
  /// The object whose local value has `value` at top-level `property`,
  /// for adoption by client identity.
  func object(accountId: String, type: String, property: String, equals value: JSONValue) throws -> StoredObject?
  func count(accountId: String, type: String) throws -> Int

  func insert(_ object: NewObject) throws -> StoredObject
  /// Stores id, snapshot, local and lastError for an existing key.
  /// The pending state is managed through the log methods below.
  func update(_ object: StoredObject) throws
  func delete(key: LocalKey) throws

  // MARK: Pending log

  /// Records that `key` needs `operation` sent, replacing any existing
  /// entry so the object moves to the end of the log.
  @discardableResult
  func setPending(key: LocalKey, operation: PendingOperation) throws -> PendingEntry
  func clearPending(key: LocalKey) throws
  func pending(key: LocalKey) throws -> PendingEntry?
  /// All entries for an account in log order.
  func pendingEntries(accountId: String) throws -> [PendingEntry]
  /// Claims every unclaimed entry for an account, and every entry whose
  /// claim is older than `staleAfter`, stamping them with `processId`
  /// and `now`.  Returns the claimed entries in log order.
  func claimPending(accountId: String, processId: String, now: Date, staleAfter: TimeInterval) throws -> [PendingEntry]
  func releaseClaims(processId: String) throws

  // MARK: Type state

  func state(accountId: String, type: String) throws -> String?
  func setState(_ state: String?, accountId: String, type: String) throws

  // MARK: Journal

  @discardableResult
  func appendJournal(_ changeSet: ChangeSet) throws -> Int64
  func journal(after seq: Int64) throws -> [JournalEntry]
  func latestJournalSeq() throws -> Int64

  // MARK: Reset

  /// Discards every object, log entry, state string and journal row
  /// for an account.
  func wipe(accountId: String) throws
}
