import Foundation
import JinxJSON
import JinxWire

/// The stable local identity of a synced object.  It is assigned when
/// the object first appears locally, whether from the server or from a
/// local create, and never changes afterward, so an app's own tables
/// can reference an object before the server has named it.
public struct LocalKey: Sendable, Hashable, Codable, CustomStringConvertible {
  public var rawValue: Int64

  public init(_ rawValue: Int64) {
    self.rawValue = rawValue
  }

  /// The creation id used for this object in a `/set` create.
  public var creationId: String { "jinx\(rawValue)" }

  public init?(creationId: String) {
    guard creationId.hasPrefix("jinx"), let value = Int64(creationId.dropFirst(4)) else { return nil }
    self.init(value)
  }

  public var description: String { "#\(rawValue)" }
}

public enum PendingOperation: String, Sendable, Codable {
  case create
  case update
  case destroy
}

/// A synced object as the store holds it.
public struct StoredObject: Sendable, Hashable {
  public var key: LocalKey
  public var accountId: String
  public var type: String
  /// The JMAP id, or `nil` until the server assigns one.
  public var id: String?
  /// The object as the server last reported it, or `nil` if the server
  /// has never seen it.
  public var snapshot: JSONValue?
  /// The object as the app sees it: the snapshot plus any pending change.
  public var local: JSONValue
  public var pending: PendingOperation?
  /// The last permanent error a push produced for this object.
  public var lastError: SetError?

  public init(
    key: LocalKey,
    accountId: String,
    type: String,
    id: String?,
    snapshot: JSONValue?,
    local: JSONValue,
    pending: PendingOperation? = nil,
    lastError: SetError? = nil
  ) {
    self.key = key
    self.accountId = accountId
    self.type = type
    self.id = id
    self.snapshot = snapshot
    self.local = local
    self.pending = pending
    self.lastError = lastError
  }
}

/// What `insert` needs to make a `StoredObject`.
public struct NewObject: Sendable, Hashable {
  public var accountId: String
  public var type: String
  public var id: String?
  public var snapshot: JSONValue?
  public var local: JSONValue

  public init(accountId: String, type: String, id: String?, snapshot: JSONValue?, local: JSONValue) {
    self.accountId = accountId
    self.type = type
    self.id = id
    self.snapshot = snapshot
    self.local = local
  }
}

/// An entry in the to-send log.  There is at most one per object.
public struct PendingEntry: Sendable, Hashable {
  public var seq: Int64
  public var key: LocalKey
  public var accountId: String
  public var type: String
  public var operation: PendingOperation
  public var claimedBy: String?
  public var claimedAt: Date?

  public init(
    seq: Int64,
    key: LocalKey,
    accountId: String,
    type: String,
    operation: PendingOperation,
    claimedBy: String? = nil,
    claimedAt: Date? = nil
  ) {
    self.seq = seq
    self.key = key
    self.accountId = accountId
    self.type = type
    self.operation = operation
    self.claimedBy = claimedBy
    self.claimedAt = claimedAt
  }
}

/// What one commit changed, as the change stream reports it and the
/// journal records it.
public struct ChangeSet: Sendable, Hashable, Codable {
  public enum Source: String, Sendable, Codable {
    /// A local write through the engine.
    case local
    /// A `/set` response applied.
    case push
    /// A `/changes` or initial sync applied.
    case pull
  }

  public struct TypeChanges: Sendable, Hashable, Codable {
    public var created: [LocalKey] = []
    public var updated: [LocalKey] = []
    public var destroyed: [LocalKey] = []
    /// Objects whose JMAP id the server just assigned.
    public var idsAssigned: [LocalKey: String] = [:]

    public init() {}

    public var isEmpty: Bool {
      created.isEmpty && updated.isEmpty && destroyed.isEmpty && idsAssigned.isEmpty
    }
  }

  public var accountId: String
  public var source: Source
  public var types: [String: TypeChanges] = [:]
  /// Objects whose pending change failed permanently and was reverted.
  public var failed: [LocalKey: SetError] = [:]
  /// Subscriptions whose id list or total changed.
  public var subscriptions: [String] = []
  /// Blob-valued properties that now name a different blob.
  public var blobs: [BlobChange] = []

  public init(accountId: String, source: Source) {
    self.accountId = accountId
    self.source = source
  }

  public var isEmpty: Bool {
    types.values.allSatisfy(\.isEmpty) && failed.isEmpty && subscriptions.isEmpty && blobs.isEmpty
  }

  public mutating func noteCreated(_ key: LocalKey, type: String) {
    types[type, default: TypeChanges()].created.append(key)
  }

  public mutating func noteUpdated(_ key: LocalKey, type: String) {
    types[type, default: TypeChanges()].updated.append(key)
  }

  public mutating func noteDestroyed(_ key: LocalKey, type: String) {
    types[type, default: TypeChanges()].destroyed.append(key)
  }

  public mutating func noteIdAssigned(_ id: String, to key: LocalKey, type: String) {
    types[type, default: TypeChanges()].idsAssigned[key] = id
  }
}

extension SetError: Codable {
  private enum CodingKeys: String, CodingKey {
    case type, description, properties, existingId, extra
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      type: try container.decode(String.self, forKey: .type),
      description: try container.decodeIfPresent(String.self, forKey: .description),
      properties: try container.decodeIfPresent([String].self, forKey: .properties),
      existingId: try container.decodeIfPresent(String.self, forKey: .existingId),
      extra: try container.decodeIfPresent([String: JSONValue].self, forKey: .extra) ?? [:]
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(type, forKey: .type)
    try container.encodeIfPresent(description, forKey: .description)
    try container.encodeIfPresent(properties, forKey: .properties)
    try container.encodeIfPresent(existingId, forKey: .existingId)
    if !extra.isEmpty { try container.encode(extra, forKey: .extra) }
  }
}

/// A journal row: one committed change set and its sequence number.
public struct JournalEntry: Sendable, Hashable {
  public var seq: Int64
  /// The process that committed it, so another process can skip its own.
  public var processId: String
  public var changeSet: ChangeSet

  public init(seq: Int64, processId: String, changeSet: ChangeSet) {
    self.seq = seq
    self.processId = processId
    self.changeSet = changeSet
  }
}

/// A live query the engine keeps current for a windowed type: a filter,
/// a sort, and a window.  The app names it, so it survives relaunch and
/// can be re-declared with new parameters under the same name.
///
/// A subscription with no filter and no limit covers the whole type, and
/// turns a windowed type into a full mirror while it exists.
public struct QuerySubscription: Sendable, Hashable, Codable {
  public var id: String
  public var accountId: String
  public var type: String
  public var filter: JSONValue?
  public var sort: [JSONValue]
  public var position: Int
  /// `nil` means no limit.
  public var limit: Int?

  public init(
    id: String,
    accountId: String,
    type: String,
    filter: JSONValue? = nil,
    sort: [JSONValue] = [],
    position: Int = 0,
    limit: Int? = nil
  ) {
    self.id = id
    self.accountId = accountId
    self.type = type
    self.filter = filter
    self.sort = sort
    self.position = position
    self.limit = limit
  }

  public var coversWholeType: Bool { filter == nil && limit == nil && position == 0 }
}

/// What the server last said a subscription's window contains.
public struct SubscriptionResult: Sendable, Hashable, Codable {
  /// The ids in the window, in the query's order.
  public var ids: [String]
  public var total: Int?
  public var queryState: String?
  public var canCalculateChanges: Bool

  public init(ids: [String], total: Int? = nil, queryState: String? = nil, canCalculateChanges: Bool = false) {
    self.ids = ids
    self.total = total
    self.queryState = queryState
    self.canCalculateChanges = canCalculateChanges
  }
}

/// The index entry for a blob on disk.
public struct BlobRecord: Sendable, Hashable, Codable {
  public var accountId: String
  public var blobId: String
  /// The blob's full length, once known.
  public var totalLength: Int?
  /// Byte ranges present on disk, sorted and non-overlapping.  A
  /// complete blob has one range covering everything.
  public var ranges: [Range<Int>]
  public var isPinned: Bool
  public var lastAccess: Date
  public var contentType: String?

  public init(
    accountId: String,
    blobId: String,
    totalLength: Int? = nil,
    ranges: [Range<Int>] = [],
    isPinned: Bool = false,
    lastAccess: Date = Date(),
    contentType: String? = nil
  ) {
    self.accountId = accountId
    self.blobId = blobId
    self.totalLength = totalLength
    self.ranges = ranges
    self.isPinned = isPinned
    self.lastAccess = lastAccess
    self.contentType = contentType
  }

  public var isComplete: Bool {
    guard let totalLength else { return false }
    return ranges == [0..<totalLength] || (totalLength == 0 && ranges.isEmpty)
  }

  public var bytesPresent: Int {
    ranges.reduce(0) { $0 + $1.count }
  }

  /// True when every byte of `range` is on disk.
  public func covers(_ range: Range<Int>) -> Bool {
    ranges.contains { $0.lowerBound <= range.lowerBound && $0.upperBound >= range.upperBound }
  }

  /// The parts of `range` not on disk.
  public func missing(in range: Range<Int>) -> [Range<Int>] {
    var gaps: [Range<Int>] = []
    var cursor = range.lowerBound
    for present in ranges where present.upperBound > range.lowerBound && present.lowerBound < range.upperBound {
      if present.lowerBound > cursor { gaps.append(cursor..<present.lowerBound) }
      cursor = max(cursor, present.upperBound)
    }
    if cursor < range.upperBound { gaps.append(cursor..<range.upperBound) }
    return gaps
  }

  /// Adds a range, merging with neighbors.
  public mutating func add(_ range: Range<Int>) {
    var merged = ranges + [range]
    merged.sort { $0.lowerBound < $1.lowerBound }
    var result: [Range<Int>] = []
    for next in merged {
      if let last = result.last, next.lowerBound <= last.upperBound {
        result[result.count - 1] = last.lowerBound..<max(last.upperBound, next.upperBound)
      } else {
        result.append(next)
      }
    }
    ranges = result
  }
}

/// A change to a blob-valued property seen on a pull: the object now
/// names a different blob.  The app's policy decides whether to fetch
/// the new one and drop the old.
public struct BlobChange: Sendable, Hashable, Codable {
  public var type: String
  public var key: LocalKey
  public var property: String
  public var oldBlobId: String?
  public var newBlobId: String?

  public init(type: String, key: LocalKey, property: String, oldBlobId: String?, newBlobId: String?) {
    self.type = type
    self.key = key
    self.property = property
    self.oldBlobId = oldBlobId
    self.newBlobId = newBlobId
  }
}
