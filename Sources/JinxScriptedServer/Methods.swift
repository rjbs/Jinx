import Foundation
import JinxJSON
import JinxPatch
import JinxWire

extension ScriptedServer.State {
  subscript(account: String, type: String) -> ScriptedServer.TypeData {
    get { types[account]?[type] ?? ScriptedServer.TypeData() }
    set { types[account, default: [:]][type] = newValue }
  }

  mutating func bump() -> Int64 {
    modseq += 1
    return modseq
  }

  mutating func store(_ account: String, _ type: String, id: String, value: JSONValue, created: Bool) {
    let seq = bump()
    var data = self[account, type]
    if created || data.objects[id] == nil {
      data.objects[id] = .init(value: value, createdAt: seq, updatedAt: seq)
    } else {
      data.objects[id]?.value = value
      data.objects[id]?.updatedAt = seq
    }
    data.tombstones[id] = nil
    data.state = seq
    self[account, type] = data
  }

  mutating func destroy(_ account: String, _ type: String, id: String) {
    guard self[account, type].objects[id] != nil else { return }
    let seq = bump()
    var data = self[account, type]
    data.objects[id] = nil
    data.tombstones[id] = seq
    data.state = seq
    self[account, type] = data
  }

  private func error(_ type: String, _ description: String? = nil) -> (name: String, arguments: JSONValue) {
    ("error", MethodError(type: type, description: description).json)
  }

  mutating func process(
    _ method: String,
    _ args: JSONValue,
    createdIds: inout [String: String],
    limits: ScriptedServer.Limits
  ) -> (name: String, arguments: JSONValue) {
    if method == "Core/echo" { return (method, args) }
    let parts = method.split(separator: "/", maxSplits: 1)
    guard parts.count == 2 else { return error(MethodError.unknownMethod) }
    let type = String(parts[0])
    guard let account = args["accountId"]?.stringValue else {
      return error(MethodError.invalidArguments, "no accountId")
    }
    switch parts[1] {
    case "get": return get(account, type, args, limits: limits)
    case "changes": return changes(account, type, args, limits: limits)
    case "set": return set(account, type, args, createdIds: &createdIds, limits: limits)
    case "query": return query(account, type, args)
    case "queryChanges": return error(MethodError.cannotCalculateChanges)
    default: return error(MethodError.unknownMethod)
    }
  }

  // MARK: get

  private func projected(_ value: JSONValue, to properties: [String]?) -> JSONValue {
    guard let properties, case .object(let members) = value else { return value }
    var kept: [String: JSONValue] = ["id": members["id"] ?? .null]
    for property in properties { kept[property] = members[property] }
    return .object(kept)
  }

  private func get(_ account: String, _ type: String, _ args: JSONValue, limits: ScriptedServer.Limits) -> (name: String, arguments: JSONValue) {
    let data = types[account]?[type] ?? ScriptedServer.TypeData()
    let properties = args["properties"]?.arrayValue?.compactMap(\.stringValue)
    let requested: [String]
    if let ids = args["ids"]?.arrayValue {
      requested = ids.compactMap(\.stringValue)
    } else {
      requested = data.objects.keys.sorted()
    }
    guard requested.count <= limits.maxObjectsInGet else {
      return error(MethodError.requestTooLarge)
    }
    var list: [JSONValue] = []
    var notFound: [JSONValue] = []
    for id in requested {
      if let stored = data.objects[id] {
        list.append(projected(stored.value, to: properties))
      } else {
        notFound.append(.string(id))
      }
    }
    return ("\(type)/get", [
      "accountId": .string(account),
      "state": .string(String(data.state)),
      "list": .array(list),
      "notFound": .array(notFound),
    ])
  }

  // MARK: changes

  private func changes(_ account: String, _ type: String, _ args: JSONValue, limits: ScriptedServer.Limits) -> (name: String, arguments: JSONValue) {
    let data = types[account]?[type] ?? ScriptedServer.TypeData()
    guard let sinceText = args["sinceState"]?.stringValue, let since = Int64(sinceText), since <= data.state else {
      return error(MethodError.cannotCalculateChanges)
    }
    let maxChanges = args["maxChanges"]?.intValue ?? limits.maxChangesDefault
    guard maxChanges > 0 else { return error(MethodError.invalidArguments, "maxChanges") }

    // Every change after `since`, in modseq order, so paging is stable.
    var events: [(seq: Int64, id: String, kind: String)] = []
    for (id, stored) in data.objects where stored.updatedAt > since {
      events.append((stored.updatedAt, id, stored.createdAt > since ? "created" : "updated"))
    }
    for (id, seq) in data.tombstones where seq > since {
      events.append((seq, id, "destroyed"))
    }
    events.sort { $0.seq < $1.seq }
    let page = events.prefix(maxChanges)
    let hasMore = events.count > maxChanges
    let newState = page.last?.seq ?? data.state
    func ids(_ kind: String) -> JSONValue {
      .array(page.filter { $0.kind == kind }.map { .string($0.id) })
    }
    return ("\(type)/changes", [
      "accountId": .string(account),
      "oldState": .string(sinceText),
      "newState": .string(String(hasMore ? newState : data.state)),
      "hasMoreChanges": .bool(hasMore),
      "created": ids("created"),
      "updated": ids("updated"),
      "destroyed": ids("destroyed"),
    ])
  }

  // MARK: set

  private mutating func set(
    _ account: String,
    _ type: String,
    _ args: JSONValue,
    createdIds: inout [String: String],
    limits: ScriptedServer.Limits
  ) -> (name: String, arguments: JSONValue) {
    var data = self[account, type]
    let oldState = String(data.state)
    if let ifInState = args["ifInState"]?.stringValue, ifInState != oldState {
      return error(MethodError.stateMismatch)
    }
    let creates = args["create"]?.objectValue ?? [:]
    let updates = args["update"]?.objectValue ?? [:]
    let destroys = args["destroy"]?.arrayValue?.compactMap(\.stringValue) ?? []
    guard creates.count + updates.count + destroys.count <= limits.maxObjectsInSet else {
      return error(MethodError.requestTooLarge)
    }

    var created: [String: JSONValue] = [:]
    var notCreated: [String: JSONValue] = [:]
    var updated: [String: JSONValue] = [:]
    var notUpdated: [String: JSONValue] = [:]
    var destroyed: [JSONValue] = []
    var notDestroyed: [String: JSONValue] = [:]

    for creationId in creates.keys.sorted() {
      var value = creates[creationId]!
      value = resolveCreationIds(in: value, createdIds)
      if value["id"] != nil {
        notCreated[creationId] = SetError(type: SetError.invalidProperties, description: "id is server-set", properties: ["id"]).jsonForSet
        continue
      }
      if let unique = data.options.uniqueProperty, let uniqueValue = value[unique],
         data.objects.values.contains(where: { $0.value[unique] == uniqueValue })
      {
        notCreated[creationId] = SetError(type: SetError.invalidProperties, description: "an object with this \(unique) already exists", properties: [unique]).jsonForSet
        continue
      }
      let id = "s\(nextId)"
      nextId += 1
      value["id"] = .string(id)
      let seq = bump()
      data.objects[id] = .init(value: value, createdAt: seq, updatedAt: seq)
      data.state = seq
      created[creationId] = ["id": .string(id)]
      createdIds[creationId] = id
    }

    for id in updates.keys.sorted() {
      guard let stored = data.objects[id] else {
        notUpdated[id] = SetError(type: SetError.notFound).jsonForSet
        continue
      }
      guard case .object(let patchMembers) = resolveCreationIds(in: updates[id]!, createdIds) else {
        notUpdated[id] = SetError(type: SetError.invalidPatch).jsonForSet
        continue
      }
      if patchMembers.keys.contains("id") || patchMembers.keys.contains(where: { $0.hasPrefix("id/") }) {
        notUpdated[id] = SetError(type: SetError.invalidProperties, properties: ["id"]).jsonForSet
        continue
      }
      do {
        let newValue = try stored.value.applying(PatchObject(patchMembers))
        let seq = bump()
        data.objects[id] = .init(value: newValue, createdAt: stored.createdAt, updatedAt: seq)
        data.state = seq
        updated[id] = .null
      } catch {
        notUpdated[id] = SetError(type: SetError.invalidPatch, description: "\(error)").jsonForSet
      }
    }

    for id in destroys {
      guard data.objects[id] != nil else {
        notDestroyed[id] = SetError(type: SetError.notFound).jsonForSet
        continue
      }
      let seq = bump()
      data.objects[id] = nil
      data.tombstones[id] = seq
      data.state = seq
      destroyed.append(.string(id))
    }

    self[account, type] = data
    var response: JSONValue = [
      "accountId": .string(account),
      "oldState": .string(oldState),
      "newState": .string(String(data.state)),
    ]
    if !created.isEmpty { response["created"] = .object(created) }
    if !updated.isEmpty { response["updated"] = .object(updated) }
    if !destroyed.isEmpty { response["destroyed"] = .array(destroyed) }
    if !notCreated.isEmpty { response["notCreated"] = .object(notCreated) }
    if !notUpdated.isEmpty { response["notUpdated"] = .object(notUpdated) }
    if !notDestroyed.isEmpty { response["notDestroyed"] = .object(notDestroyed) }
    return ("\(type)/set", response)
  }

  /// Replaces `#creationId` strings anywhere in a value with the id
  /// created earlier in this request.  A real server does this only in
  /// Id-typed properties; a generic one has to guess.
  private func resolveCreationIds(in value: JSONValue, _ createdIds: [String: String]) -> JSONValue {
    switch value {
    case .string(let s) where s.hasPrefix("#"):
      return createdIds[String(s.dropFirst())].map(JSONValue.string) ?? value
    case .array(let elements):
      return .array(elements.map { resolveCreationIds(in: $0, createdIds) })
    case .object(let members):
      var resolved: [String: JSONValue] = [:]
      for (key, inner) in members {
        let newKey = key.hasPrefix("#") ? (createdIds[String(key.dropFirst())] ?? key) : key
        resolved[newKey] = resolveCreationIds(in: inner, createdIds)
      }
      return .object(resolved)
    default:
      return value
    }
  }

  // MARK: query

  private func query(_ account: String, _ type: String, _ args: JSONValue) -> (name: String, arguments: JSONValue) {
    let data = types[account]?[type] ?? ScriptedServer.TypeData()
    var matching = data.objects.filter { Self.matches($0.value.value, args["filter"]) }.map { ($0.key, $0.value) }
    let sort = args["sort"]?.arrayValue ?? []
    matching.sort { a, b in
      for comparator in sort {
        guard let property = comparator["property"]?.stringValue else { continue }
        let ascending = comparator["isAscending"]?.boolValue ?? true
        let left = a.1.value[property] ?? .null
        let right = b.1.value[property] ?? .null
        if left == right { continue }
        let less = Self.less(left, right)
        return ascending ? less : !less
      }
      return a.0 < b.0
    }
    let ids = matching.map(\.0)
    var position = args["position"]?.intValue ?? 0
    if let anchor = args["anchor"]?.stringValue {
      guard let index = ids.firstIndex(of: anchor) else { return error(MethodError.anchorNotFound) }
      position = max(0, index + (args["anchorOffset"]?.intValue ?? 0))
    }
    if position < 0 { position = max(0, ids.count + position) }
    let limit = args["limit"]?.intValue
    let page = Array(ids.dropFirst(position).prefix(limit ?? ids.count))
    var response: JSONValue = [
      "accountId": .string(account),
      "queryState": .string(String(data.state)),
      "canCalculateChanges": .bool(data.options.canCalculateChanges),
      "position": .number(Double(position)),
      "ids": .array(page.map(JSONValue.string)),
    ]
    if args["calculateTotal"]?.boolValue == true { response["total"] = .number(Double(ids.count)) }
    if let limit { response["limit"] = .number(Double(limit)) }
    return ("\(type)/query", response)
  }

  /// The filter language: an object of property to required value, or
  /// a FilterOperator with AND, OR or NOT over conditions.
  static func matches(_ object: JSONValue, _ filter: JSONValue?) -> Bool {
    guard let filter, case .object(let members) = filter else { return true }
    if let op = members["operator"]?.stringValue {
      let conditions = members["conditions"]?.arrayValue ?? []
      switch op {
      case "AND": return conditions.allSatisfy { matches(object, $0) }
      case "OR": return conditions.contains { matches(object, $0) }
      case "NOT": return !conditions.contains { matches(object, $0) }
      default: return false
      }
    }
    return members.allSatisfy { key, value in (object[key] ?? .null) == value }
  }

  static func less(_ a: JSONValue, _ b: JSONValue) -> Bool {
    switch (a, b) {
    case (.number(let x), .number(let y)): return x < y
    case (.string(let x), .string(let y)): return x < y
    case (.bool(let x), .bool(let y)): return !x && y
    case (.null, _): return true
    case (_, .null): return false
    default: return a.description < b.description
    }
  }
}

extension SetError {
  var jsonForSet: JSONValue {
    var members = extra
    members["type"] = .string(type)
    if let description { members["description"] = .string(description) }
    if let properties { members["properties"] = .array(properties.map(JSONValue.string)) }
    if let existingId { members["existingId"] = .string(existingId) }
    return .object(members)
  }
}
