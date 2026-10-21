import JinxJSON

// The standard method shapes of RFC 8620 section 5, decoded from a
// response's arguments.  Each is lenient about optional members and
// strict about the ones the RFC makes mandatory.

private extension JSONValue {
  func string(_ key: String, in method: String) throws(JMAPError) -> String {
    guard let value = self[key]?.stringValue else {
      throw .malformed("\(method) response without \(key)")
    }
    return value
  }

  func ids(_ key: String) -> [String] {
    self[key]?.arrayValue?.compactMap(\.stringValue) ?? []
  }
}

/// A `Foo/get` response.
public struct GetResponse: Sendable, Hashable {
  public var accountId: String
  public var state: String
  public var list: [JSONValue]
  public var notFound: [String]

  public init(json: JSONValue) throws(JMAPError) {
    accountId = try json.string("accountId", in: "/get")
    state = try json.string("state", in: "/get")
    list = json["list"]?.arrayValue ?? []
    notFound = json.ids("notFound")
  }
}

/// A `Foo/changes` response.
public struct ChangesResponse: Sendable, Hashable {
  public var accountId: String
  public var oldState: String
  public var newState: String
  public var hasMoreChanges: Bool
  public var created: [String]
  public var updated: [String]
  public var destroyed: [String]

  public init(json: JSONValue) throws(JMAPError) {
    accountId = try json.string("accountId", in: "/changes")
    oldState = try json.string("oldState", in: "/changes")
    newState = try json.string("newState", in: "/changes")
    hasMoreChanges = json["hasMoreChanges"]?.boolValue ?? false
    created = json.ids("created")
    updated = json.ids("updated")
    destroyed = json.ids("destroyed")
  }
}

/// A `Foo/set` response.
public struct SetResponse: Sendable, Hashable {
  public var accountId: String
  public var oldState: String?
  public var newState: String
  /// Creation id to the server-set properties of the new object, which
  /// always include `id`.
  public var created: [String: JSONValue]
  /// Id to any server-set properties that changed, or `.null`.
  public var updated: [String: JSONValue]
  public var destroyed: [String]
  public var notCreated: [String: SetError]
  public var notUpdated: [String: SetError]
  public var notDestroyed: [String: SetError]

  public init(json: JSONValue) throws(JMAPError) {
    accountId = try json.string("accountId", in: "/set")
    oldState = json["oldState"]?.stringValue
    newState = try json.string("newState", in: "/set")
    created = json["created"]?.objectValue ?? [:]
    updated = json["updated"]?.objectValue ?? [:]
    destroyed = json.ids("destroyed")
    func errors(_ key: String) throws(JMAPError) -> [String: SetError] {
      var result: [String: SetError] = [:]
      for (id, errorJSON) in json[key]?.objectValue ?? [:] {
        result[id] = try SetError(json: errorJSON)
      }
      return result
    }
    notCreated = try errors("notCreated")
    notUpdated = try errors("notUpdated")
    notDestroyed = try errors("notDestroyed")
  }

  /// The server-assigned id for a creation id, when the create succeeded.
  public func createdId(for creationId: String) -> String? {
    created[creationId]?["id"]?.stringValue
  }
}

/// A `Foo/query` response.
public struct QueryResponse: Sendable, Hashable {
  public static let standardProperties: Set<String> = [
    "accountId", "queryState", "canCalculateChanges", "position", "ids", "total", "limit",
  ]

  public var accountId: String
  public var queryState: String
  public var canCalculateChanges: Bool
  public var position: Int
  public var ids: [String]
  public var total: Int?
  public var limit: Int?
  /// Every top-level property beyond the standard ones, which extensions
  /// add: Fastmail's category sort returns `groupByCounts`.
  public var extra: [String: JSONValue]

  public init(json: JSONValue) throws(JMAPError) {
    accountId = try json.string("accountId", in: "/query")
    queryState = try json.string("queryState", in: "/query")
    canCalculateChanges = json["canCalculateChanges"]?.boolValue ?? false
    position = json["position"]?.intValue ?? 0
    ids = json.ids("ids")
    total = json["total"]?.intValue
    limit = json["limit"]?.intValue
    extra = (json.objectValue ?? [:]).filter { !Self.standardProperties.contains($0.key) }
  }
}

/// A `Foo/queryChanges` response.
public struct QueryChangesResponse: Sendable, Hashable {
  public struct AddedItem: Sendable, Hashable {
    public var id: String
    public var index: Int
  }

  public static let standardProperties: Set<String> = [
    "accountId", "oldQueryState", "newQueryState", "total", "removed", "added",
  ]

  public var accountId: String
  public var oldQueryState: String
  public var newQueryState: String
  public var total: Int?
  public var removed: [String]
  public var added: [AddedItem]
  /// Every top-level property beyond the standard ones.
  public var extra: [String: JSONValue]

  public init(json: JSONValue) throws(JMAPError) {
    extra = (json.objectValue ?? [:]).filter { !Self.standardProperties.contains($0.key) }
    accountId = try json.string("accountId", in: "/queryChanges")
    oldQueryState = try json.string("oldQueryState", in: "/queryChanges")
    newQueryState = try json.string("newQueryState", in: "/queryChanges")
    total = json["total"]?.intValue
    removed = json.ids("removed")
    added = (json["added"]?.arrayValue ?? []).compactMap { item in
      guard let id = item["id"]?.stringValue, let index = item["index"]?.intValue else { return nil }
      return AddedItem(id: id, index: index)
    }
  }
}

/// A `Foo/copy` response is not modeled; no consumer needs it yet.

// MARK: - Argument builders

extension JSONValue {
  /// Arguments for `Foo/get`.  `ids: nil` asks for every object, which
  /// a server may refuse with `requestTooLarge`.
  public static func getArguments(
    accountId: String,
    ids: [String]?,
    properties: [String]? = nil
  ) -> JSONValue {
    var args: JSONValue = ["accountId": .string(accountId)]
    args["ids"] = ids.map { .array($0.map(JSONValue.string)) } ?? .null
    if let properties { args["properties"] = .array(properties.map(JSONValue.string)) }
    return args
  }

  /// Arguments for `Foo/changes`.
  public static func changesArguments(
    accountId: String,
    sinceState: String,
    maxChanges: Int? = nil
  ) -> JSONValue {
    var args: JSONValue = ["accountId": .string(accountId), "sinceState": .string(sinceState)]
    if let maxChanges { args["maxChanges"] = .number(Double(maxChanges)) }
    return args
  }

  /// Arguments for `Foo/set`.
  public static func setArguments(
    accountId: String,
    ifInState: String? = nil,
    create: [String: JSONValue] = [:],
    update: [String: JSONValue] = [:],
    destroy: [String] = []
  ) -> JSONValue {
    var args: JSONValue = ["accountId": .string(accountId)]
    if let ifInState { args["ifInState"] = .string(ifInState) }
    if !create.isEmpty { args["create"] = .object(create) }
    if !update.isEmpty { args["update"] = .object(update) }
    if !destroy.isEmpty { args["destroy"] = .array(destroy.map(JSONValue.string)) }
    return args
  }

  /// Arguments for `Foo/query`.
  public static func queryArguments(
    accountId: String,
    filter: JSONValue? = nil,
    sort: [JSONValue]? = nil,
    position: Int = 0,
    anchor: String? = nil,
    anchorOffset: Int? = nil,
    limit: Int? = nil,
    calculateTotal: Bool = false
  ) -> JSONValue {
    var args: JSONValue = ["accountId": .string(accountId)]
    if let filter { args["filter"] = filter }
    if let sort { args["sort"] = .array(sort) }
    if position != 0 { args["position"] = .number(Double(position)) }
    if let anchor { args["anchor"] = .string(anchor) }
    if let anchorOffset { args["anchorOffset"] = .number(Double(anchorOffset)) }
    if let limit { args["limit"] = .number(Double(limit)) }
    if calculateTotal { args["calculateTotal"] = true }
    return args
  }

  /// Arguments for `Foo/queryChanges`.
  public static func queryChangesArguments(
    accountId: String,
    filter: JSONValue? = nil,
    sort: [JSONValue]? = nil,
    sinceQueryState: String,
    maxChanges: Int? = nil,
    upToId: String? = nil,
    calculateTotal: Bool = false
  ) -> JSONValue {
    var args: JSONValue = ["accountId": .string(accountId), "sinceQueryState": .string(sinceQueryState)]
    if let filter { args["filter"] = filter }
    if let sort { args["sort"] = .array(sort) }
    if let maxChanges { args["maxChanges"] = .number(Double(maxChanges)) }
    if let upToId { args["upToId"] = .string(upToId) }
    if calculateTotal { args["calculateTotal"] = true }
    return args
  }
}
