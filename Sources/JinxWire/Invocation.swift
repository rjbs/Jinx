import Foundation
import JinxJSON

/// One method call or method response: the `[name, arguments, callId]`
/// triple of RFC 8620 section 3.2.
public struct Invocation: Sendable, Hashable {
  public var name: String
  public var arguments: JSONValue
  public var callId: String

  public init(name: String, arguments: JSONValue = .object([:]), callId: String) {
    self.name = name
    self.arguments = arguments
    self.callId = callId
  }

  public init(json: JSONValue) throws(JMAPError) {
    guard let parts = json.arrayValue, parts.count == 3,
          let name = parts[0].stringValue,
          case .object = parts[1],
          let callId = parts[2].stringValue
    else {
      throw .malformed("invocation is not a [name, arguments, callId] triple")
    }
    self.init(name: name, arguments: parts[1], callId: callId)
  }

  public var json: JSONValue {
    .array([.string(name), arguments, .string(callId)])
  }

  /// True for an `error` response.
  public var isError: Bool { name == "error" }

  /// The method error, when this is an `error` response.
  public var methodError: MethodError? {
    guard isError else { return nil }
    return try? MethodError(json: arguments)
  }

  /// The arguments as a result, or the method error thrown.
  public func result() throws(MethodError) -> JSONValue {
    if let error = methodError { throw error }
    return arguments
  }
}

/// A reference to part of an earlier method call's response, placed in
/// a later call's arguments under a `#`-prefixed key (RFC 8620
/// section 3.7).
public struct ResultReference: Sendable, Hashable {
  public var resultOf: String
  public var name: String
  public var path: JSONPointer

  public init(resultOf: String, name: String, path: JSONPointer) {
    self.resultOf = resultOf
    self.name = name
    self.path = path
  }

  public var json: JSONValue {
    .object([
      "resultOf": .string(resultOf),
      "name": .string(name),
      "path": .string(path.rfc6901),
    ])
  }
}

extension JSONValue {
  /// Stores a result reference for `key`, under `#key`, removing any
  /// literal value for `key`, as the spec requires.
  public mutating func setReference(_ reference: ResultReference, for key: String) {
    self[key] = nil
    self["#" + key] = reference.json
  }
}

/// A request object (RFC 8620 section 3.3).
public struct Request: Sendable, Hashable {
  public var using: [String]
  public var methodCalls: [Invocation]
  public var createdIds: [String: String]?

  public init(using: [String], methodCalls: [Invocation], createdIds: [String: String]? = nil) {
    self.using = using
    self.methodCalls = methodCalls
    self.createdIds = createdIds
  }

  public var json: JSONValue {
    var members: [String: JSONValue] = [
      "using": .array(using.sorted().map(JSONValue.string)),
      "methodCalls": .array(methodCalls.map(\.json)),
    ]
    if let createdIds {
      members["createdIds"] = .object(createdIds.mapValues(JSONValue.string))
    }
    return .object(members)
  }
}

/// A response object (RFC 8620 section 3.4).
public struct Response: Sendable, Hashable {
  public var methodResponses: [Invocation]
  public var createdIds: [String: String]?
  public var sessionState: String

  public init(methodResponses: [Invocation], createdIds: [String: String]? = nil, sessionState: String) {
    self.methodResponses = methodResponses
    self.createdIds = createdIds
    self.sessionState = sessionState
  }

  public init(json: JSONValue) throws(JMAPError) {
    guard let responses = json["methodResponses"]?.arrayValue else {
      throw .malformed("response without methodResponses")
    }
    var methodResponses: [Invocation] = []
    for response in responses {
      methodResponses.append(try Invocation(json: response))
    }
    self.init(
      methodResponses: methodResponses,
      createdIds: json["createdIds"]?.objectValue?.compactMapValues(\.stringValue),
      sessionState: json["sessionState"]?.stringValue ?? ""
    )
  }

  /// Every response to the call with `callId`, in order.  A single call
  /// may produce several responses.
  public func responses(to callId: String) -> [Invocation] {
    methodResponses.filter { $0.callId == callId }
  }

  /// The first response to a call, or `nil` when there was none.
  public func response(to callId: String) -> Invocation? {
    methodResponses.first { $0.callId == callId }
  }
}
