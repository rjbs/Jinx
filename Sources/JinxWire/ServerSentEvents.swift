import Foundation
import JinxJSON

/// One event from a server-sent event stream.
public struct ServerSentEvent: Sendable, Hashable {
  public var event: String?
  public var data: String
  public var id: String?
  public var retry: Duration?

  public init(event: String? = nil, data: String, id: String? = nil, retry: Duration? = nil) {
    self.event = event
    self.data = data
    self.id = id
    self.retry = retry
  }
}

/// An incremental parser for the text/event-stream format.  Feed it
/// lines; it yields an event whenever a blank line ends one.  This is
/// the whole of the SSE grammar the JMAP push channel needs.
public struct ServerSentEventParser: Sendable {
  private var event: String?
  private var dataLines: [String] = []
  private var id: String?
  private var retry: Duration?

  public init() {}

  /// Consumes one line, without its terminator.  Returns the completed
  /// event when the line was the blank line that ends one.
  public mutating func feed(line: String) -> ServerSentEvent? {
    if line.isEmpty {
      return flush()
    }
    if line.hasPrefix(":") { return nil }
    let field: Substring
    let value: Substring
    if let colon = line.firstIndex(of: ":") {
      field = line[..<colon]
      var rest = line[line.index(after: colon)...]
      if rest.hasPrefix(" ") { rest = rest.dropFirst() }
      value = rest
    } else {
      field = line[...]
      value = ""
    }
    switch field {
    case "event": event = String(value)
    case "data": dataLines.append(String(value))
    case "id": id = String(value)
    case "retry":
      if let milliseconds = Int(value) { retry = .milliseconds(milliseconds) }
    default: break
    }
    return nil
  }

  private mutating func flush() -> ServerSentEvent? {
    defer {
      event = nil
      dataLines = []
      id = nil
      retry = nil
    }
    // A retry-only block carries no data but still matters, so it is
    // reported as an event with empty data. -- claude, 2026-10-17
    guard !dataLines.isEmpty || retry != nil else { return nil }
    return ServerSentEvent(event: event, data: dataLines.joined(separator: "\n"), id: id, retry: retry)
  }
}

/// A JMAP `StateChange` push object (RFC 8620 section 7.1).
public struct StateChange: Sendable, Hashable {
  /// Account id to type name to new state string.
  public var changed: [String: [String: String]]

  public init(changed: [String: [String: String]]) {
    self.changed = changed
  }

  public init(json: JSONValue) throws(JMAPError) {
    guard json["@type"]?.stringValue == "StateChange", let accounts = json["changed"]?.objectValue else {
      throw .malformed("not a StateChange")
    }
    changed = accounts.mapValues { $0.objectValue?.compactMapValues(\.stringValue) ?? [:] }
  }
}
