import Foundation
import JinxJSON
import JinxPatch
import JinxStore
import JinxWire

/// The write API inside one transaction.  Every mutation goes through
/// here, so the pending log is always right.
public struct Writer<Transaction: SyncTransaction>: ~Copyable {
  let tx: Transaction
  let accountId: String
  let descriptors: [String: TypeDescriptor]
  var changeSet: ChangeSet

  init(tx: Transaction, accountId: String, descriptors: [String: TypeDescriptor], changeSet: ChangeSet) {
    self.tx = tx
    self.accountId = accountId
    self.descriptors = descriptors
    self.changeSet = changeSet
  }

  /// Creates an object locally.  The server sees it on the next sync-out;
  /// its JMAP id arrives on the change stream.
  public mutating func create(_ type: String, _ value: JSONValue) throws -> LocalKey {
    guard descriptors[type] != nil else { throw SyncError.unknownType(type) }
    try Self.checkNoForeignCreationReferences(value, type: type, descriptors: descriptors)
    var value = value
    value["id"] = nil
    let object = try tx.insert(NewObject(accountId: accountId, type: type, id: nil, snapshot: nil, local: value))
    try tx.setPending(key: object.key, operation: .create)
    changeSet.noteCreated(object.key, type: type)
    return object.key
  }

  /// Applies a patch to an object.
  public mutating func update(_ key: LocalKey, patch: PatchObject) throws {
    try update(key) { try $0.applying(patch) }
  }

  /// Replaces an object from the app's own encoding, touching only the
  /// type's owned properties.
  public mutating func replace(_ key: LocalKey, with encoding: JSONValue) throws {
    let object = try existing(key)
    let owned = descriptors[object.type]?.ownedProperties
    try update(key) { current in
      if let owned {
        return try current.mergingOwnedProperties(owned, from: encoding)
      }
      var replaced = encoding
      replaced["id"] = current["id"]
      return replaced
    }
  }

  /// Transforms an object's current value.
  public mutating func update(_ key: LocalKey, _ transform: (JSONValue) throws -> JSONValue) throws {
    var object = try existing(key)
    if object.pending == .destroy { throw SyncError.objectIsBeingDestroyed(key.description) }
    var newValue = try transform(object.local)
    newValue["id"] = object.id.map(JSONValue.string)
    try Self.checkNoForeignCreationReferences(newValue, type: object.type, descriptors: descriptors)
    guard !newValue.isJMAPEquivalent(to: object.local) else { return }
    object.local = newValue
    object.lastError = nil
    try tx.update(object)
    switch object.pending {
    case .create:
      break  // the create will send the current value
    case .update, nil:
      if let snapshot = object.snapshot, newValue.isJMAPEquivalent(to: snapshot) {
        try tx.clearPending(key: key)
      } else {
        try tx.setPending(key: key, operation: .update)
      }
    case .destroy:
      break  // unreachable; guarded above
    }
    changeSet.noteUpdated(key, type: object.type)
  }

  /// Destroys an object.  One the server has never seen is simply
  /// forgotten; otherwise the destroy is queued.
  public mutating func destroy(_ key: LocalKey) throws {
    let object = try existing(key)
    let entry = try tx.pending(key: key)
    if object.id == nil, entry?.claimedBy == nil {
      try tx.delete(key: key)
    } else {
      try tx.setPending(key: key, operation: .destroy)
    }
    changeSet.noteDestroyed(key, type: object.type)
  }

  /// Takes objects the app already has, from an import or a one-time
  /// migration, as pending creates.  Returns their keys in order.
  public mutating func adopt(_ type: String, _ values: [JSONValue]) throws -> [LocalKey] {
    try values.map { try create(type, $0) }
  }

  public func object(_ key: LocalKey) throws -> SyncedObject? {
    try tx.object(key: key).map(SyncedObject.init)
  }

  private func existing(_ key: LocalKey) throws -> StoredObject {
    guard let object = try tx.object(key: key) else { throw SyncError.noSuchObject(key.description) }
    return object
  }

  /// A creation id of another type inside a value is the cross-type
  /// reference the plan defers; refuse it clearly rather than send it.
  static func checkNoForeignCreationReferences(_ value: JSONValue, type: String, descriptors: [String: TypeDescriptor]) throws {
    switch value {
    case .string(let s) where s.hasPrefix("#jinx"):
      throw SyncError.crossTypeCreationReference(s)
    case .array(let elements):
      for element in elements { try checkNoForeignCreationReferences(element, type: type, descriptors: descriptors) }
    case .object(let members):
      for (key, inner) in members {
        if key.hasPrefix("#jinx") { throw SyncError.crossTypeCreationReference(key) }
        try checkNoForeignCreationReferences(inner, type: type, descriptors: descriptors)
      }
    default:
      break
    }
  }
}

extension SyncEngine {
  /// Runs any number of writes in one transaction and one log batch.
  public func write<T: Sendable>(_ body: @Sendable (inout Writer<Store.Transaction>) throws -> T) async throws -> T {
    let accountId = accountId
    let descriptors = descriptors
    return try await commit({ tx, changeSet in
      var writer = Writer(tx: tx, accountId: accountId, descriptors: descriptors, changeSet: changeSet)
      let result = try body(&writer)
      changeSet = writer.changeSet
      return result
    }, source: .local)
  }

  public func create(_ type: String, _ value: JSONValue) async throws -> LocalKey {
    try await write { try $0.create(type, value) }
  }

  public func update(_ key: LocalKey, patch: PatchObject) async throws {
    try await write { try $0.update(key, patch: patch) }
  }

  public func update(_ key: LocalKey, _ transform: @Sendable @escaping (JSONValue) throws -> JSONValue) async throws {
    try await write { try $0.update(key, transform) }
  }

  public func replace(_ key: LocalKey, with encoding: JSONValue) async throws {
    try await write { try $0.replace(key, with: encoding) }
  }

  public func destroy(_ key: LocalKey) async throws {
    try await write { try $0.destroy(key) }
  }

  /// Discards every local object, pending change and state string for
  /// the account.  For a factory reset.
  public func wipe() async throws {
    let accountId = accountId
    try await store.write { tx in try tx.wipe(accountId: accountId) }
    needsSyncIn = []
    status = SyncStatus()
  }
}
