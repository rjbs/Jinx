import Foundation
import JinxJSON

/// Anything that can go wrong between building a request and having a
/// decoded response in hand.
public enum JMAPError: Error, Sendable {
  /// The network layer failed before any HTTP response arrived.
  case transport(any Error)
  /// The server answered with a non-success status and no JMAP
  /// problem-details body.
  case httpStatus(Int, body: Data)
  /// The server rejected the whole request (RFC 8620 section 3.6.1).
  case request(RequestError)
  /// The body was not the JSON shape the protocol requires.
  case malformed(String)
  /// The session resource names no API URL, or a template is unusable.
  case badSession(String)
}

/// A request-level error, in RFC 7807 problem-details form, as RFC 8620
/// section 3.6.1 specifies.  `type` is the full URN; `kind` classifies
/// the ones the RFC defines.
public struct RequestError: Error, Sendable, Hashable {
  public static let urnPrefix = "urn:ietf:params:jmap:error:"

  public enum Kind: String, Sendable {
    case unknownCapability
    case notJSON
    case notRequest
    case limit
    case other
  }

  public var type: String
  public var status: Int?
  public var detail: String?
  /// For `limit`, which limit was exceeded, such as `maxSizeRequest`.
  public var limit: String?

  public init(type: String, status: Int? = nil, detail: String? = nil, limit: String? = nil) {
    self.type = type
    self.status = status
    self.detail = detail
    self.limit = limit
  }

  public var kind: Kind {
    guard type.hasPrefix(Self.urnPrefix) else { return .other }
    return Kind(rawValue: String(type.dropFirst(Self.urnPrefix.count))) ?? .other
  }

  public init(problemDetails json: JSONValue) throws(JMAPError) {
    guard let type = json["type"]?.stringValue else {
      throw .malformed("problem details without a type")
    }
    self.init(
      type: type,
      status: json["status"]?.intValue,
      detail: json["detail"]?.stringValue,
      limit: json["limit"]?.stringValue
    )
  }
}

/// A method-level error: the `error` response to one method call
/// (RFC 8620 section 3.6.2).  `type` is the bare name, such as
/// `serverFail`; the well-known ones have constants below.
public struct MethodError: Error, Sendable, Hashable {
  public var type: String
  public var description: String?
  /// Every other member of the error object, for types that carry
  /// more, such as `limit`.
  public var extra: [String: JSONValue]

  public init(type: String, description: String? = nil, extra: [String: JSONValue] = [:]) {
    self.type = type
    self.description = description
    self.extra = extra
  }

  public init(json: JSONValue) throws(JMAPError) {
    guard case .object(var members) = json, let type = members["type"]?.stringValue else {
      throw .malformed("method error without a type")
    }
    members["type"] = nil
    let description = members.removeValue(forKey: "description")?.stringValue
    self.init(type: type, description: description, extra: members)
  }

  public var json: JSONValue {
    var members = extra
    members["type"] = .string(type)
    if let description { members["description"] = .string(description) }
    return .object(members)
  }

  // RFC 8620 section 3.6.2
  public static let serverUnavailable = "serverUnavailable"
  public static let serverFail = "serverFail"
  public static let serverPartialFail = "serverPartialFail"
  public static let unknownMethod = "unknownMethod"
  public static let invalidArguments = "invalidArguments"
  public static let invalidResultReference = "invalidResultReference"
  public static let forbidden = "forbidden"
  public static let accountNotFound = "accountNotFound"
  public static let accountNotSupportedByMethod = "accountNotSupportedByMethod"
  public static let accountReadOnly = "accountReadOnly"
  // RFC 8620 section 5
  public static let requestTooLarge = "requestTooLarge"
  public static let cannotCalculateChanges = "cannotCalculateChanges"
  public static let stateMismatch = "stateMismatch"
  public static let anchorNotFound = "anchorNotFound"
  public static let unsupportedSort = "unsupportedSort"
  public static let unsupportedFilter = "unsupportedFilter"
  public static let tooManyChanges = "tooManyChanges"
}

/// A per-object error inside a `/set` response (RFC 8620 section 5.3).
public struct SetError: Error, Sendable, Hashable {
  public var type: String
  public var description: String?
  /// For `invalidProperties`, the offending property paths.
  public var properties: [String]?
  /// For `alreadyExists`, the id of the object that already exists.
  public var existingId: String?
  public var extra: [String: JSONValue]

  public init(
    type: String,
    description: String? = nil,
    properties: [String]? = nil,
    existingId: String? = nil,
    extra: [String: JSONValue] = [:]
  ) {
    self.type = type
    self.description = description
    self.properties = properties
    self.existingId = existingId
    self.extra = extra
  }

  public init(json: JSONValue) throws(JMAPError) {
    guard case .object(var members) = json, let type = members["type"]?.stringValue else {
      throw .malformed("SetError without a type")
    }
    members["type"] = nil
    let description = members.removeValue(forKey: "description")?.stringValue
    let properties = members.removeValue(forKey: "properties")?.arrayValue?.compactMap(\.stringValue)
    let existingId = members.removeValue(forKey: "existingId")?.stringValue
    self.init(
      type: type,
      description: description,
      properties: properties,
      existingId: existingId,
      extra: members
    )
  }

  public static let forbidden = "forbidden"
  public static let overQuota = "overQuota"
  public static let tooLarge = "tooLarge"
  public static let rateLimit = "rateLimit"
  public static let notFound = "notFound"
  public static let invalidPatch = "invalidPatch"
  public static let willDestroy = "willDestroy"
  public static let invalidProperties = "invalidProperties"
  public static let singleton = "singleton"
  public static let alreadyExists = "alreadyExists"
}
