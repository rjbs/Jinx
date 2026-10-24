import Foundation
import GRDB
import JinxJSON
import JinxWire

/// The store most apps use: SQLite through GRDB, in tables prefixed
/// `jinx_`, inside whichever database the app provides.
///
/// Register the schema on the app's migrator with `registerMigrations`
/// before opening the store.  Two processes may share the file; the
/// store uses short transactions and claims rather than locks.
public struct GRDBSyncStore: SyncStore {
  public var writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  /// Opens a store in its own database file, with migrations applied.
  public init(path: String) throws {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    let pool = try DatabasePool(path: path, configuration: configuration)
    var migrator = DatabaseMigrator()
    Self.registerMigrations(in: &migrator)
    try migrator.migrate(pool)
    self.init(writer: pool)
  }

  /// Opens a store in memory, for tests.
  public static func inMemory() throws -> GRDBSyncStore {
    let queue = try DatabaseQueue()
    var migrator = DatabaseMigrator()
    registerMigrations(in: &migrator)
    try migrator.migrate(queue)
    return GRDBSyncStore(writer: queue)
  }

  /// Adds Jinx's schema migrations to an app's migrator.  Safe to call
  /// on every launch; GRDB runs each migration once.
  public static func registerMigrations(in migrator: inout DatabaseMigrator) {
    migrator.registerMigration("jinx-1") { db in
      try db.execute(sql: """
        CREATE TABLE jinx_object (
          key        INTEGER PRIMARY KEY AUTOINCREMENT,
          account    TEXT NOT NULL,
          type       TEXT NOT NULL,
          id         TEXT,
          snapshot   TEXT,
          local      TEXT NOT NULL,
          last_error TEXT
        );
        CREATE UNIQUE INDEX jinx_object_id ON jinx_object(account, type, id) WHERE id IS NOT NULL;
        CREATE INDEX jinx_object_type ON jinx_object(account, type);

        CREATE TABLE jinx_pending (
          seq        INTEGER PRIMARY KEY AUTOINCREMENT,
          key        INTEGER NOT NULL UNIQUE REFERENCES jinx_object(key) ON DELETE CASCADE,
          account    TEXT NOT NULL,
          type       TEXT NOT NULL,
          operation  TEXT NOT NULL,
          claimed_by TEXT,
          claimed_at REAL
        );
        CREATE INDEX jinx_pending_account ON jinx_pending(account, seq);

        CREATE TABLE jinx_state (
          account TEXT NOT NULL,
          type    TEXT NOT NULL,
          state   TEXT NOT NULL,
          PRIMARY KEY (account, type)
        );

        CREATE TABLE jinx_subscription (
          account    TEXT NOT NULL,
          id         TEXT NOT NULL,
          type       TEXT NOT NULL,
          definition TEXT NOT NULL,
          result     TEXT,
          PRIMARY KEY (account, id)
        );

        CREATE TABLE jinx_pin (
          account TEXT NOT NULL,
          type    TEXT NOT NULL,
          id      TEXT NOT NULL,
          PRIMARY KEY (account, type, id)
        );

        CREATE TABLE jinx_blob (
          account      TEXT NOT NULL,
          blob_id      TEXT NOT NULL,
          total_length INTEGER,
          ranges       TEXT NOT NULL,
          pinned       INTEGER NOT NULL DEFAULT 0,
          last_access  REAL NOT NULL,
          content_type TEXT,
          PRIMARY KEY (account, blob_id)
        );

        CREATE TABLE jinx_journal (
          seq        INTEGER PRIMARY KEY AUTOINCREMENT,
          account    TEXT NOT NULL,
          process    TEXT NOT NULL,
          created_at REAL NOT NULL,
          change_set TEXT NOT NULL
        );
        """)
    }
    // The column was called snapshot until the rename to serverVersion
    // on 2026-10-23; jinx-1 is history and must not change. -- claude, 2026-10-23
    migrator.registerMigration("jinx-2") { db in
      try db.execute(sql: "ALTER TABLE jinx_object RENAME COLUMN snapshot TO server_version")
    }
  }

  public func read<T: Sendable>(_ body: @Sendable (GRDBTransaction) throws -> T) async throws -> T {
    try await writer.read { db in try body(GRDBTransaction(db: db)) }
  }

  public func write<T: Sendable>(_ body: @Sendable (GRDBTransaction) throws -> T) async throws -> T {
    try await writer.write { db in try body(GRDBTransaction(db: db)) }
  }
}

/// A transaction on a `GRDBSyncStore`.
public struct GRDBTransaction: SyncTransaction {
  public let db: Database

  init(db: Database) {
    self.db = db
  }

  // MARK: Objects

  private static let objectColumns = """
    o.key, o.account, o.type, o.id, o.server_version, o.local, o.last_error, p.operation AS pending
    """

  private static let objectFrom = """
    FROM jinx_object o LEFT JOIN jinx_pending p ON p.key = o.key
    """

  private func fetchObjects(where clause: String, arguments: StatementArguments) throws -> [StoredObject] {
    let rows = try Row.fetchAll(
      db,
      sql: "SELECT \(Self.objectColumns) \(Self.objectFrom) WHERE \(clause) ORDER BY o.key",
      arguments: arguments
    )
    return try rows.map(Self.object(from:))
  }

  private static func object(from row: Row) throws -> StoredObject {
    StoredObject(
      key: LocalKey(row["key"]),
      accountId: row["account"],
      type: row["type"],
      id: row["id"],
      serverVersion: try (row["server_version"] as String?).map { try JSONValue(parsing: $0) },
      local: try JSONValue(parsing: row["local"] as String),
      pending: (row["pending"] as String?).flatMap(PendingOperation.init(rawValue:)),
      lastError: try (row["last_error"] as String?).map { try JSONDecoder().decode(SetError.self, from: Data($0.utf8)) }
    )
  }

  public func object(key: LocalKey) throws -> StoredObject? {
    try fetchObjects(where: "o.key = ?", arguments: [key.rawValue]).first
  }

  public func object(accountId: String, type: String, id: String) throws -> StoredObject? {
    try fetchObjects(where: "o.account = ? AND o.type = ? AND o.id = ?", arguments: [accountId, type, id]).first
  }

  public func objects(keys: [LocalKey]) throws -> [StoredObject] {
    guard !keys.isEmpty else { return [] }
    let placeholders = databaseQuestionMarks(count: keys.count)
    return try fetchObjects(where: "o.key IN (\(placeholders))", arguments: StatementArguments(keys.map(\.rawValue)))
  }

  public func objects(accountId: String, type: String, ids: [String]) throws -> [StoredObject] {
    guard !ids.isEmpty else { return [] }
    let placeholders = databaseQuestionMarks(count: ids.count)
    return try fetchObjects(
      where: "o.account = ? AND o.type = ? AND o.id IN (\(placeholders))",
      arguments: StatementArguments([accountId, type] + ids)
    )
  }

  public func objects(accountId: String, type: String) throws -> [StoredObject] {
    try fetchObjects(where: "o.account = ? AND o.type = ?", arguments: [accountId, type])
  }

  public func object(accountId: String, type: String, property: String, equals value: JSONValue) throws -> StoredObject? {
    // json_extract returns SQL NULL for a JSON null and for an absent
    // key, so a null value cannot be matched; that is fine for an
    // identity property. -- claude, 2026-10-17
    let path = "$." + property.replacingOccurrences(of: "\"", with: "\\\"")
    let argument: DatabaseValueConvertible?
    switch value {
    case .string(let s): argument = s
    case .number(let n): argument = n
    case .bool(let b): argument = b ? 1 : 0
    default: return nil
    }
    return try fetchObjects(
      where: "o.account = ? AND o.type = ? AND json_extract(o.local, ?) = ?",
      arguments: [accountId, type, path, argument]
    ).first
  }

  public func count(accountId: String, type: String) throws -> Int {
    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM jinx_object WHERE account = ? AND type = ?", arguments: [accountId, type]) ?? 0
  }

  public func insert(_ object: NewObject) throws -> StoredObject {
    try db.execute(
      sql: "INSERT INTO jinx_object (account, type, id, server_version, local) VALUES (?, ?, ?, ?, ?)",
      arguments: [
        object.accountId,
        object.type,
        object.id,
        try object.serverVersion?.serializedString(),
        try object.local.serializedString(),
      ]
    )
    return StoredObject(
      key: LocalKey(db.lastInsertedRowID),
      accountId: object.accountId,
      type: object.type,
      id: object.id,
      serverVersion: object.serverVersion,
      local: object.local
    )
  }

  public func update(_ object: StoredObject) throws {
    try db.execute(
      sql: "UPDATE jinx_object SET id = ?, server_version = ?, local = ?, last_error = ? WHERE key = ?",
      arguments: [
        object.id,
        try object.serverVersion?.serializedString(),
        try object.local.serializedString(),
        try object.lastError.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) },
        object.key.rawValue,
      ]
    )
  }

  public func delete(key: LocalKey) throws {
    try db.execute(sql: "DELETE FROM jinx_object WHERE key = ?", arguments: [key.rawValue])
  }

  // MARK: Pending log

  private static func entry(from row: Row) -> PendingEntry {
    PendingEntry(
      seq: row["seq"],
      key: LocalKey(row["key"]),
      accountId: row["account"],
      type: row["type"],
      operation: PendingOperation(rawValue: row["operation"]) ?? .update,
      claimedBy: row["claimed_by"],
      claimedAt: (row["claimed_at"] as Double?).map(Date.init(timeIntervalSince1970:))
    )
  }

  @discardableResult
  public func setPending(key: LocalKey, operation: PendingOperation) throws -> PendingEntry {
    guard let row = try Row.fetchOne(db, sql: "SELECT account, type FROM jinx_object WHERE key = ?", arguments: [key.rawValue]) else {
      throw StoreError.noSuchObject(key)
    }
    try db.execute(sql: "DELETE FROM jinx_pending WHERE key = ?", arguments: [key.rawValue])
    try db.execute(
      sql: "INSERT INTO jinx_pending (key, account, type, operation) VALUES (?, ?, ?, ?)",
      arguments: [key.rawValue, row["account"] as String, row["type"] as String, operation.rawValue]
    )
    return PendingEntry(
      seq: db.lastInsertedRowID,
      key: key,
      accountId: row["account"],
      type: row["type"],
      operation: operation
    )
  }

  public func clearPending(key: LocalKey) throws {
    try db.execute(sql: "DELETE FROM jinx_pending WHERE key = ?", arguments: [key.rawValue])
  }

  public func pending(key: LocalKey) throws -> PendingEntry? {
    try Row.fetchOne(db, sql: "SELECT * FROM jinx_pending WHERE key = ?", arguments: [key.rawValue]).map(Self.entry(from:))
  }

  public func pendingEntries(accountId: String) throws -> [PendingEntry] {
    try Row.fetchAll(db, sql: "SELECT * FROM jinx_pending WHERE account = ? ORDER BY seq", arguments: [accountId]).map(Self.entry(from:))
  }

  public func claimPending(accountId: String, processId: String, now: Date, staleAfter: TimeInterval) throws -> [PendingEntry] {
    let cutoff = now.timeIntervalSince1970 - staleAfter
    try db.execute(
      sql: """
        UPDATE jinx_pending SET claimed_by = ?, claimed_at = ?
        WHERE account = ? AND (claimed_by IS NULL OR claimed_at < ?)
        """,
      arguments: [processId, now.timeIntervalSince1970, accountId, cutoff]
    )
    return try Row.fetchAll(
      db,
      sql: "SELECT * FROM jinx_pending WHERE account = ? AND claimed_by = ? AND claimed_at = ? ORDER BY seq",
      arguments: [accountId, processId, now.timeIntervalSince1970]
    ).map(Self.entry(from:))
  }

  public func releaseClaims(processId: String) throws {
    try db.execute(sql: "UPDATE jinx_pending SET claimed_by = NULL, claimed_at = NULL WHERE claimed_by = ?", arguments: [processId])
  }

  // MARK: Type state

  public func state(accountId: String, type: String) throws -> String? {
    try String.fetchOne(db, sql: "SELECT state FROM jinx_state WHERE account = ? AND type = ?", arguments: [accountId, type])
  }

  public func setState(_ state: String?, accountId: String, type: String) throws {
    if let state {
      try db.execute(
        sql: "INSERT INTO jinx_state (account, type, state) VALUES (?, ?, ?) ON CONFLICT DO UPDATE SET state = excluded.state",
        arguments: [accountId, type, state]
      )
    } else {
      try db.execute(sql: "DELETE FROM jinx_state WHERE account = ? AND type = ?", arguments: [accountId, type])
    }
  }

  // MARK: Journal

  @discardableResult
  public func appendJournal(_ changeSet: ChangeSet, processId: String) throws -> Int64 {
    let encoded = String(decoding: try JSONEncoder().encode(changeSet), as: UTF8.self)
    try db.execute(
      sql: "INSERT INTO jinx_journal (account, process, created_at, change_set) VALUES (?, ?, ?, ?)",
      arguments: [changeSet.accountId, processId, Date().timeIntervalSince1970, encoded]
    )
    return db.lastInsertedRowID
  }

  public func journal(after seq: Int64) throws -> [JournalEntry] {
    try Row.fetchAll(db, sql: "SELECT seq, process, change_set FROM jinx_journal WHERE seq > ? ORDER BY seq", arguments: [seq]).map { row in
      JournalEntry(
        seq: row["seq"],
        processId: row["process"],
        changeSet: try JSONDecoder().decode(ChangeSet.self, from: Data((row["change_set"] as String).utf8))
      )
    }
  }

  public func latestJournalSeq() throws -> Int64 {
    try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(seq), 0) FROM jinx_journal") ?? 0
  }

  // MARK: Subscriptions and pins

  private static func decodeSubscription(_ row: Row) throws -> QuerySubscription {
    try JSONDecoder().decode(QuerySubscription.self, from: Data((row["definition"] as String).utf8))
  }

  public func subscriptions(accountId: String) throws -> [QuerySubscription] {
    try Row.fetchAll(db, sql: "SELECT definition FROM jinx_subscription WHERE account = ? ORDER BY id", arguments: [accountId]).map(Self.decodeSubscription)
  }

  public func subscription(accountId: String, id: String) throws -> QuerySubscription? {
    try Row.fetchOne(db, sql: "SELECT definition FROM jinx_subscription WHERE account = ? AND id = ?", arguments: [accountId, id]).map(Self.decodeSubscription)
  }

  public func setSubscription(_ subscription: QuerySubscription) throws {
    let definition = String(decoding: try JSONEncoder().encode(subscription), as: UTF8.self)
    try db.execute(
      sql: """
        INSERT INTO jinx_subscription (account, id, type, definition) VALUES (?, ?, ?, ?)
        ON CONFLICT DO UPDATE SET type = excluded.type, definition = excluded.definition
        """,
      arguments: [subscription.accountId, subscription.id, subscription.type, definition]
    )
  }

  public func removeSubscription(accountId: String, id: String) throws {
    try db.execute(sql: "DELETE FROM jinx_subscription WHERE account = ? AND id = ?", arguments: [accountId, id])
  }

  public func subscriptionResult(accountId: String, id: String) throws -> SubscriptionResult? {
    guard let text = try String.fetchOne(db, sql: "SELECT result FROM jinx_subscription WHERE account = ? AND id = ? AND result IS NOT NULL", arguments: [accountId, id]) else {
      return nil
    }
    return try JSONDecoder().decode(SubscriptionResult.self, from: Data(text.utf8))
  }

  public func setSubscriptionResult(_ result: SubscriptionResult?, accountId: String, id: String) throws {
    let text = try result.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
    try db.execute(sql: "UPDATE jinx_subscription SET result = ? WHERE account = ? AND id = ?", arguments: [text, accountId, id])
  }

  public func pins(accountId: String, type: String) throws -> Set<String> {
    Set(try String.fetchAll(db, sql: "SELECT id FROM jinx_pin WHERE account = ? AND type = ?", arguments: [accountId, type]))
  }

  public func setPinned(_ pinned: Bool, accountId: String, type: String, ids: [String]) throws {
    for id in ids {
      if pinned {
        try db.execute(sql: "INSERT OR IGNORE INTO jinx_pin (account, type, id) VALUES (?, ?, ?)", arguments: [accountId, type, id])
      } else {
        try db.execute(sql: "DELETE FROM jinx_pin WHERE account = ? AND type = ? AND id = ?", arguments: [accountId, type, id])
      }
    }
  }

  public func ids(accountId: String, type: String) throws -> Set<String> {
    Set(try String.fetchAll(db, sql: "SELECT id FROM jinx_object WHERE account = ? AND type = ? AND id IS NOT NULL", arguments: [accountId, type]))
  }

  // MARK: Blobs

  private static func blobRecord(_ row: Row) throws -> BlobRecord {
    let pairs = try JSONDecoder().decode([[Int]].self, from: Data((row["ranges"] as String).utf8))
    return BlobRecord(
      accountId: row["account"],
      blobId: row["blob_id"],
      totalLength: row["total_length"],
      ranges: pairs.map { $0[0]..<$0[1] },
      isPinned: (row["pinned"] as Int) != 0,
      lastAccess: Date(timeIntervalSince1970: row["last_access"]),
      contentType: row["content_type"]
    )
  }

  public func blob(accountId: String, blobId: String) throws -> BlobRecord? {
    try Row.fetchOne(db, sql: "SELECT * FROM jinx_blob WHERE account = ? AND blob_id = ?", arguments: [accountId, blobId]).map(Self.blobRecord)
  }

  public func blobs(accountId: String) throws -> [BlobRecord] {
    try Row.fetchAll(db, sql: "SELECT * FROM jinx_blob WHERE account = ? ORDER BY last_access", arguments: [accountId]).map(Self.blobRecord)
  }

  public func setBlob(_ record: BlobRecord) throws {
    let ranges = String(decoding: try JSONEncoder().encode(record.ranges.map { [$0.lowerBound, $0.upperBound] }), as: UTF8.self)
    try db.execute(
      sql: """
        INSERT INTO jinx_blob (account, blob_id, total_length, ranges, pinned, last_access, content_type)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT DO UPDATE SET total_length = excluded.total_length, ranges = excluded.ranges,
          pinned = excluded.pinned, last_access = excluded.last_access, content_type = excluded.content_type
        """,
      arguments: [record.accountId, record.blobId, record.totalLength, ranges, record.isPinned ? 1 : 0, record.lastAccess.timeIntervalSince1970, record.contentType]
    )
  }

  public func deleteBlob(accountId: String, blobId: String) throws {
    try db.execute(sql: "DELETE FROM jinx_blob WHERE account = ? AND blob_id = ?", arguments: [accountId, blobId])
  }

  // MARK: Reset

  public func wipe(accountId: String) throws {
    try db.execute(sql: "DELETE FROM jinx_blob WHERE account = ?", arguments: [accountId])
    try db.execute(sql: "DELETE FROM jinx_subscription WHERE account = ?", arguments: [accountId])
    try db.execute(sql: "DELETE FROM jinx_pin WHERE account = ?", arguments: [accountId])
    try db.execute(sql: "DELETE FROM jinx_pending WHERE account = ?", arguments: [accountId])
    try db.execute(sql: "DELETE FROM jinx_object WHERE account = ?", arguments: [accountId])
    try db.execute(sql: "DELETE FROM jinx_state WHERE account = ?", arguments: [accountId])
    try db.execute(sql: "DELETE FROM jinx_journal WHERE account = ?", arguments: [accountId])
  }
}

public enum StoreError: Error, Sendable, Equatable {
  case noSuchObject(LocalKey)
}
