import JinxJSON

/// One method call and the responses it got, with short readings of
/// both for a request log.  The readings know the standard method
/// shapes of RFC 8620 section 5, and fall back to listing argument
/// names for anything else.
public struct CallExchange: Sendable, Hashable {
  public var call: Invocation
  /// Usually one; a call may produce several, and none if the request
  /// failed as a whole.
  public var responses: [Invocation]

  public init(call: Invocation, responses: [Invocation]) {
    self.call = call
    self.responses = responses
  }

  /// The arguments that refer to earlier calls' results, as `argument
  /// ← callId name path`.
  public var references: [String] {
    guard let arguments = call.arguments.objectValue else { return [] }
    return arguments.keys.sorted().compactMap { key in
      guard key.hasPrefix("#"), let ref = arguments[key],
            let resultOf = ref["resultOf"]?.stringValue,
            let name = ref["name"]?.stringValue,
            let path = ref["path"]?.stringValue
      else { return nil }
      return "\(key.dropFirst()) ← \(resultOf) \(name) \(path)"
    }
  }

  /// What was asked, in a few words.
  public var callSummary: String {
    let args = call.arguments
    var parts: [String] = []
    switch Self.method(call.name) {
    case "get":
      if args["#ids"] != nil { parts.append("ids by reference") }
      else if let ids = args["ids"]?.arrayValue { parts.append("\(ids.count) id(s)") }
      else { parts.append("all") }
      if let properties = args["properties"]?.arrayValue { parts.append("\(properties.count) properties") }
    case "changes":
      if let since = args["sinceState"]?.stringValue { parts.append("since \(since)") }
      if let max = args["maxChanges"]?.intValue { parts.append("max \(max)") }
    case "set":
      if let state = args["ifInState"]?.stringValue { parts.append("if in \(state)") }
      if let count = args["create"]?.objectValue?.count { parts.append("create \(count)") }
      if let count = args["update"]?.objectValue?.count { parts.append("update \(count)") }
      if let count = args["destroy"]?.arrayValue?.count { parts.append("destroy \(count)") }
    case "query":
      parts.append(args["filter"].map { $0.isNull ? "no filter" : "filtered" } ?? "no filter")
      if let position = args["position"]?.intValue, position != 0 { parts.append("from \(position)") }
      if let limit = args["limit"]?.intValue { parts.append("limit \(limit)") }
    case "queryChanges":
      if let since = args["sinceQueryState"]?.stringValue { parts.append("since \(since)") }
      if let upTo = args["upToId"]?.stringValue { parts.append("up to \(upTo)") }
    default:
      parts.append(contentsOf: (args.objectValue ?? [:]).keys.filter { $0 != "accountId" }.sorted())
    }
    parts.append(contentsOf: references.map { "ref \($0)" })
    return parts.joined(separator: ", ")
  }

  /// What came back, in a few words.
  public var responseSummary: String {
    if responses.isEmpty { return "no response" }
    return responses.map(Self.summarize).joined(separator: "; ")
  }

  private static func method(_ name: String) -> Substring {
    name.split(separator: "/", maxSplits: 1).last ?? ""
  }

  private static func summarize(_ response: Invocation) -> String {
    if let error = response.methodError {
      return ["error \(error.type)", error.description].compactMap(\.self).joined(separator: ": ")
    }
    let json = response.arguments
    switch method(response.name) {
    case "get":
      guard let get = try? GetResponse(json: json) else { break }
      var parts = ["\(get.list.count) returned"]
      if !get.notFound.isEmpty { parts.append("\(get.notFound.count) not found") }
      parts.append("state \(get.state)")
      return parts.joined(separator: ", ")
    case "changes":
      guard let changes = try? ChangesResponse(json: json) else { break }
      var parts = [
        "+\(changes.created.count) ~\(changes.updated.count) -\(changes.destroyed.count)",
        "\(changes.oldState) → \(changes.newState)",
      ]
      if changes.hasMoreChanges { parts.append("more") }
      return parts.joined(separator: ", ")
    case "set":
      guard let set = try? SetResponse(json: json) else { break }
      var parts: [String] = []
      if !set.created.isEmpty { parts.append("created \(set.created.count)") }
      if !set.updated.isEmpty { parts.append("updated \(set.updated.count)") }
      if !set.destroyed.isEmpty { parts.append("destroyed \(set.destroyed.count)") }
      for (label, errors) in [("notCreated", set.notCreated), ("notUpdated", set.notUpdated), ("notDestroyed", set.notDestroyed)]
      where !errors.isEmpty {
        let types = Set(errors.values.map(\.type)).sorted().joined(separator: "/")
        parts.append("\(label) \(errors.count) (\(types))")
      }
      parts.append("\(set.oldState ?? "?") → \(set.newState)")
      return parts.joined(separator: ", ")
    case "query":
      guard let query = try? QueryResponse(json: json) else { break }
      var parts = ["\(query.ids.count) id(s)"]
      if query.position != 0 { parts.append("at \(query.position)") }
      if let total = query.total { parts.append("of \(total)") }
      parts.append("queryState \(query.queryState)")
      if !query.extra.isEmpty { parts.append("+" + query.extra.keys.sorted().joined(separator: ",")) }
      return parts.joined(separator: ", ")
    case "queryChanges":
      guard let changes = try? QueryChangesResponse(json: json) else { break }
      return "removed \(changes.removed.count), added \(changes.added.count), \(changes.oldQueryState) → \(changes.newQueryState)"
    default:
      break
    }
    return (json.objectValue ?? [:]).keys.filter { $0 != "accountId" }.sorted().joined(separator: ", ")
  }
}
