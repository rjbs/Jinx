import JinxJSON

/// Assembles a request, handing out call ids and typed handles that
/// later calls can reference.
///
///     var builder = RequestBuilder(using: [Session.coreCapability, mail])
///     let changes = builder.call("Email/changes", ["accountId": a, "sinceState": s])
///     builder.call("Email/get", ["accountId": a], references: ["ids": changes.reference("/created")])
///     let request = builder.request
public struct RequestBuilder: Sendable {
  /// A handle on a call already added to the request.
  public struct Call: Sendable, Hashable {
    public let name: String
    public let callId: String

    /// A reference to `path` within this call's response, for use as a
    /// later call's argument.  `path` is an RFC 6901 pointer such as
    /// `/created` or `/list/*/id`.
    public func reference(_ path: String) -> ResultReference {
      ResultReference(resultOf: callId, name: name, path: JSONPointer(rfc6901: path))
    }
  }

  public private(set) var using: Set<String>
  public private(set) var methodCalls: [Invocation] = []
  public var createdIds: [String: String]?
  private var nextIndex = 0

  public init(using: some Sequence<String>) {
    self.using = Set(using)
  }

  /// Adds a capability to `using`, for a builder shared across types.
  public mutating func use(_ capability: String) {
    using.insert(capability)
  }

  /// Adds a method call.  `references` are stored under `#`-prefixed
  /// keys and override any literal argument of the same name.
  @discardableResult
  public mutating func call(
    _ name: String,
    _ arguments: JSONValue = .object([:]),
    references: [String: ResultReference] = [:]
  ) -> Call {
    var arguments = arguments
    for (key, reference) in references {
      arguments.setReference(reference, for: key)
    }
    let callId = "c\(nextIndex)"
    nextIndex += 1
    methodCalls.append(Invocation(name: name, arguments: arguments, callId: callId))
    return Call(name: name, callId: callId)
  }

  public var request: Request {
    Request(using: Array(using), methodCalls: methodCalls, createdIds: createdIds)
  }

  public var isEmpty: Bool { methodCalls.isEmpty }
  public var count: Int { methodCalls.count }
}
