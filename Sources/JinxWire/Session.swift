import Foundation
import JinxJSON

/// The JMAP Session resource (RFC 8620 section 2).
public struct Session: Sendable, Hashable {
  public static let coreCapability = "urn:ietf:params:jmap:core"

  public struct Account: Sendable, Hashable {
    public var name: String
    public var isPersonal: Bool
    public var isReadOnly: Bool
    public var accountCapabilities: [String: JSONValue]

    public init(name: String, isPersonal: Bool, isReadOnly: Bool, accountCapabilities: [String: JSONValue]) {
      self.name = name
      self.isPersonal = isPersonal
      self.isReadOnly = isReadOnly
      self.accountCapabilities = accountCapabilities
    }
  }

  /// The core capability object, with the limits a client must honor.
  public struct CoreCapabilities: Sendable, Hashable {
    public var maxSizeUpload: Int
    public var maxConcurrentUpload: Int
    public var maxSizeRequest: Int
    public var maxConcurrentRequests: Int
    public var maxCallsInRequest: Int
    public var maxObjectsInGet: Int
    public var maxObjectsInSet: Int
    public var collationAlgorithms: [String]
  }

  public var capabilities: [String: JSONValue]
  public var accounts: [String: Account]
  public var primaryAccounts: [String: String]
  public var username: String
  public var apiUrl: URL
  public var downloadUrl: URLTemplate
  public var uploadUrl: URLTemplate
  public var eventSourceUrl: URLTemplate
  public var state: String

  public var core: CoreCapabilities? {
    guard let json = capabilities[Self.coreCapability] else { return nil }
    guard let maxSizeUpload = json["maxSizeUpload"]?.intValue,
          let maxConcurrentUpload = json["maxConcurrentUpload"]?.intValue,
          let maxSizeRequest = json["maxSizeRequest"]?.intValue,
          let maxConcurrentRequests = json["maxConcurrentRequests"]?.intValue,
          let maxCallsInRequest = json["maxCallsInRequest"]?.intValue,
          let maxObjectsInGet = json["maxObjectsInGet"]?.intValue,
          let maxObjectsInSet = json["maxObjectsInSet"]?.intValue
    else { return nil }
    return CoreCapabilities(
      maxSizeUpload: maxSizeUpload,
      maxConcurrentUpload: maxConcurrentUpload,
      maxSizeRequest: maxSizeRequest,
      maxConcurrentRequests: maxConcurrentRequests,
      maxCallsInRequest: maxCallsInRequest,
      maxObjectsInGet: maxObjectsInGet,
      maxObjectsInSet: maxObjectsInSet,
      collationAlgorithms: json["collationAlgorithms"]?.arrayValue?.compactMap(\.stringValue) ?? []
    )
  }

  /// The id of the primary account for a capability, such as
  /// `urn:ietf:params:jmap:mail`.
  public func primaryAccountId(for capability: String) -> String? {
    primaryAccounts[capability]
  }

  /// Parses a session resource.  URLs in the resource may be relative;
  /// `base` is the URL the resource was fetched from.
  public init(json: JSONValue, base: URL) throws(JMAPError) {
    guard let capabilities = json["capabilities"]?.objectValue else {
      throw .malformed("session without capabilities")
    }
    guard let accountsJSON = json["accounts"]?.objectValue else {
      throw .malformed("session without accounts")
    }
    var accounts: [String: Account] = [:]
    for (id, accountJSON) in accountsJSON {
      guard let name = accountJSON["name"]?.stringValue else {
        throw .malformed("account \(id) without a name")
      }
      accounts[id] = Account(
        name: name,
        isPersonal: accountJSON["isPersonal"]?.boolValue ?? false,
        isReadOnly: accountJSON["isReadOnly"]?.boolValue ?? false,
        accountCapabilities: accountJSON["accountCapabilities"]?.objectValue ?? [:]
      )
    }
    guard let apiString = json["apiUrl"]?.stringValue, let apiUrl = URL(string: apiString, relativeTo: base)?.absoluteURL else {
      throw .badSession("no usable apiUrl")
    }
    func template(_ key: String) throws(JMAPError) -> URLTemplate {
      guard let string = json[key]?.stringValue else { throw .badSession("no \(key)") }
      return URLTemplate(string, relativeTo: base)
    }
    self.capabilities = capabilities
    self.accounts = accounts
    self.primaryAccounts = json["primaryAccounts"]?.objectValue?.compactMapValues(\.stringValue) ?? [:]
    self.username = json["username"]?.stringValue ?? ""
    self.apiUrl = apiUrl
    self.downloadUrl = try template("downloadUrl")
    self.uploadUrl = try template("uploadUrl")
    self.eventSourceUrl = try template("eventSourceUrl")
    self.state = json["state"]?.stringValue ?? ""
  }
}
