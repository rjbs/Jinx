import Foundation
import Synchronization
import JinxJSON
import JinxPatch
import JinxWire

/// An in-process JMAP server for testing clients.  It holds real data
/// and computes real responses, including `/changes` between any two
/// states it has held, for whatever type names it is asked about.  It
/// is deliberately generic: any `Foo/get`, `Foo/changes`, `Foo/set`,
/// `Foo/query` works on objects that are plain JSON.
///
/// Tests drive it two ways: by mutating its data directly, which is a
/// server state transition, and by enqueueing faults, which make it
/// misbehave in ways a correct server never does.  Every request the
/// client sends is logged for assertions.
public final class ScriptedServer: JMAPTransport, Sendable {
  /// Limits the server advertises and enforces.
  public struct Limits: Sendable, Hashable {
    public var maxObjectsInGet = 256
    public var maxObjectsInSet = 128
    public var maxCallsInRequest = 32
    public var maxChangesDefault = 1000

    public init() {}
  }

  /// A one-shot misbehavior, consumed in order of enqueueing.
  public enum Fault: Sendable {
    /// Fail the next request before processing it.
    case transportFailure
    /// Process the next request fully, then fail instead of replying.
    /// The client's lost-response path.
    case loseResponse
    /// Answer the next call whose name matches with this error instead
    /// of processing it.
    case methodError(method: String, MethodError)
    /// Rewrite the next matching response however the test likes.
    case rewrite(method: String, @Sendable (JSONValue) -> JSONValue)
  }

  /// Per-type behavior a test can configure.
  public struct TypeOptions: Sendable, Hashable {
    /// A property that must be unique across objects of the type; a
    /// create that duplicates it fails with `invalidProperties` naming
    /// the property, as the NerfJournal prototype does.
    public var uniqueProperty: String?
    /// Whether `/query` reports `canCalculateChanges`.
    public var canCalculateChanges = false

    public init(uniqueProperty: String? = nil, canCalculateChanges: Bool = false) {
      self.uniqueProperty = uniqueProperty
      self.canCalculateChanges = canCalculateChanges
    }
  }

  struct Stored: Sendable {
    var value: JSONValue
    var createdAt: Int64
    var updatedAt: Int64
  }

  struct TypeData: Sendable {
    var objects: [String: Stored] = [:]
    var tombstones: [String: Int64] = [:]
    var state: Int64 = 0
    var options = TypeOptions()
  }

  struct State: Sendable {
    var modseq: Int64 = 0
    var types: [String: [String: TypeData]] = [:]  // accountId -> type -> data
    var nextId = 1
    var faults: [Fault] = []
    var requests: [Request] = []
    var resolved: [Invocation] = []
    var blobs: [String: (data: Data, type: String)] = [:]
    var nextBlob = 1
    var sessionState = 1
    var pushSubscribers: [AsyncThrowingStream<ServerSentEvent, any Error>.Continuation] = []
  }

  public let accountId: String
  public let limits: Limits
  public let capabilities: [String]
  private let state: Mutex<State>

  public static let baseUrl = URL(string: "jinx://server/")!

  public init(accountId: String = "acct", capabilities: [String] = [], limits: Limits = Limits()) {
    self.accountId = accountId
    var unique: [String] = []
    for capability in capabilities where !unique.contains(capability) { unique.append(capability) }
    self.capabilities = unique
    self.limits = limits
    self.state = Mutex(State())
  }

  // MARK: - Driving the server from a test

  /// Configures a type's behavior.
  public func configure(_ type: String, _ options: TypeOptions) {
    state.withLock { $0[accountId, type].options = options }
  }

  /// The server-side state string of a type.
  public func state(of type: String) -> String {
    state.withLock { String($0[accountId, type].state) }
  }

  /// Creates an object with a server-chosen id and returns the id.
  @discardableResult
  public func create(_ type: String, _ value: JSONValue) -> String {
    state.withLock { s in
      let id = "s\(s.nextId)"
      s.nextId += 1
      s.store(accountId, type, id: id, value: value.merging(["id": .string(id)]), created: true)
      return id
    }.alsoPush(self)
  }

  /// Replaces an object's value.
  public func update(_ type: String, _ id: String, _ transform: (inout JSONValue) -> Void) {
    state.withLock { s in
      guard var value = s[accountId, type].objects[id]?.value else { return }
      transform(&value)
      value["id"] = .string(id)
      s.store(accountId, type, id: id, value: value, created: false)
    }
    pushStateChange()
  }

  public func destroy(_ type: String, _ id: String) {
    state.withLock { s in s.destroy(accountId, type, id: id) }
    pushStateChange()
  }

  public func object(_ type: String, _ id: String) -> JSONValue? {
    state.withLock { $0[accountId, type].objects[id]?.value }
  }

  public func objects(_ type: String) -> [String: JSONValue] {
    state.withLock { $0[accountId, type].objects.mapValues(\.value) }
  }

  public func enqueue(_ fault: Fault) {
    state.withLock { $0.faults.append(fault) }
  }

  /// Every request received so far, oldest first.
  public var requests: [Request] {
    state.withLock { $0.requests }
  }

  public func clearRequests() {
    state.withLock {
      $0.requests = []
      $0.resolved = []
    }
  }

  /// Method calls as processed, with result references resolved, so a
  /// test can see which ids a back-referenced `/get` actually asked for.
  public func resolvedCalls(named name: String) -> [Invocation] {
    state.withLock { $0.resolved.filter { $0.name == name } }
  }

  /// Method calls received so far whose name matches, oldest first.
  public func calls(named name: String) -> [Invocation] {
    requests.flatMap(\.methodCalls).filter { $0.name == name }
  }

  /// Sends a StateChange to every connected push subscriber.
  public func pushStateChange() {
    let (subscribers, changed) = state.withLock { s -> ([AsyncThrowingStream<ServerSentEvent, any Error>.Continuation], JSONValue) in
      let changed = JSONValue.object(s.types.mapValues { types in
        .object(types.mapValues { .string(String($0.state)) })
      })
      return (s.pushSubscribers, changed)
    }
    let payload: JSONValue = ["@type": "StateChange", "changed": changed]
    let event = ServerSentEvent(event: "state", data: (try? payload.serializedString()) ?? "{}")
    for subscriber in subscribers { subscriber.yield(event) }
  }

  /// Ends every push connection, as a server restart would.
  public func dropPushConnections() {
    let subscribers = state.withLock { s -> [AsyncThrowingStream<ServerSentEvent, any Error>.Continuation] in
      defer { s.pushSubscribers = [] }
      return s.pushSubscribers
    }
    for subscriber in subscribers { subscriber.finish() }
  }

  // MARK: - JMAPTransport

  public func fetchSession() async throws(JMAPError) -> Session {
    var caps: [String: JSONValue] = [
      Session.coreCapability: [
        "maxSizeUpload": 50_000_000,
        "maxConcurrentUpload": 4,
        "maxSizeRequest": 10_000_000,
        "maxConcurrentRequests": 4,
        "maxCallsInRequest": .number(Double(limits.maxCallsInRequest)),
        "maxObjectsInGet": .number(Double(limits.maxObjectsInGet)),
        "maxObjectsInSet": .number(Double(limits.maxObjectsInSet)),
        "collationAlgorithms": ["i;unicode-casemap"],
      ],
    ]
    for capability in capabilities { caps[capability] = [:] }
    let json: JSONValue = [
      "capabilities": .object(caps),
      "accounts": [
        accountId: [
          "name": "test@example.com",
          "isPersonal": true,
          "isReadOnly": false,
          "accountCapabilities": .object(Dictionary(uniqueKeysWithValues: capabilities.map { ($0, JSONValue.object([:])) })),
        ],
      ],
      "primaryAccounts": .object(Dictionary(uniqueKeysWithValues: capabilities.map { ($0, JSONValue.string(accountId)) })),
      "username": "test@example.com",
      "apiUrl": "jinx://server/api",
      "downloadUrl": "jinx://server/download/{accountId}/{blobId}/{name}?type={type}",
      "uploadUrl": "jinx://server/upload/{accountId}",
      "eventSourceUrl": "jinx://server/events?types={types}&closeafter={closeafter}&ping={ping}",
      "state": .string(String(state.withLock { $0.sessionState })),
    ]
    return try Session(json: json, base: Self.baseUrl)
  }

  public func send(_ request: Request, to apiUrl: URL) async throws(JMAPError) -> Response {
    let outcome = state.withLock { s -> Result<Response, JMAPError> in
      s.requests.append(request)
      if case .transportFailure? = s.faults.first {
        s.faults.removeFirst()
        return .failure(.transport(URLError(.networkConnectionLost)))
      }
      var loseResponse = false
      if case .loseResponse? = s.faults.first {
        s.faults.removeFirst()
        loseResponse = true
      }
      guard request.methodCalls.count <= limits.maxCallsInRequest else {
        return .failure(.request(RequestError(type: RequestError.urnPrefix + "limit", status: 400, limit: "maxCallsInRequest")))
      }
      var responses: [Invocation] = []
      var createdIds = request.createdIds ?? [:]
      for call in request.methodCalls {
        let resolved: JSONValue
        do throws(MethodError) {
          resolved = try Self.resolveReferences(in: call.arguments, against: responses)
        } catch {
          responses.append(Invocation(name: "error", arguments: error.json, callId: call.callId))
          continue
        }
        if let index = s.faults.firstIndex(where: { if case .methodError(let m, _) = $0 { return m == call.name } else { return false } }),
           case .methodError(_, let error) = s.faults.remove(at: index)
        {
          responses.append(Invocation(name: "error", arguments: error.json, callId: call.callId))
          continue
        }
        s.resolved.append(Invocation(name: call.name, arguments: resolved, callId: call.callId))
        var reply = s.process(call.name, resolved, createdIds: &createdIds, limits: limits)
        if let index = s.faults.firstIndex(where: { if case .rewrite(let m, _) = $0 { return m == call.name } else { return false } }),
           case .rewrite(_, let rewrite) = s.faults.remove(at: index)
        {
          reply = (reply.name, rewrite(reply.arguments))
        }
        responses.append(Invocation(name: reply.name, arguments: reply.arguments, callId: call.callId))
      }
      if loseResponse {
        return .failure(.transport(URLError(.networkConnectionLost)))
      }
      return .success(Response(methodResponses: responses, createdIds: createdIds.isEmpty ? nil : createdIds, sessionState: String(s.sessionState)))
    }
    if request.methodCalls.contains(where: { $0.name.hasSuffix("/set") }) {
      pushStateChange()
    }
    return try outcome.get()
  }

  public func upload(_ data: Data, contentType: String, to uploadUrl: URL) async throws(JMAPError) -> UploadResponse {
    let blobId = state.withLock { s in
      let id = "blob\(s.nextBlob)"
      s.nextBlob += 1
      s.blobs[id] = (data, contentType)
      return id
    }
    return try UploadResponse(json: [
      "accountId": .string(accountId),
      "blobId": .string(blobId),
      "type": .string(contentType),
      "size": .number(Double(data.count)),
    ])
  }

  /// Stores a blob directly, as server-side data would be, and returns its id.
  public func addBlob(_ data: Data, type: String = "application/octet-stream") -> String {
    state.withLock { s in
      let id = "blob\(s.nextBlob)"
      s.nextBlob += 1
      s.blobs[id] = (data, type)
      return id
    }
  }

  public func removeBlob(_ blobId: String) {
    state.withLock { $0.blobs[blobId] = nil }
  }

  public func download(from url: URL, range: Range<Int>?) async throws(JMAPError) -> BlobDownload {
    let parts = url.pathComponents
    guard parts.count >= 4, parts[1] == "download", let blob = state.withLock({ $0.blobs[parts[3]] }) else {
      throw .httpStatus(404, body: Data())
    }
    if let range {
      let clamped = range.clamped(to: 0..<blob.data.count)
      return BlobDownload(data: blob.data.subdata(in: clamped), contentType: blob.type, range: clamped, totalLength: blob.data.count)
    }
    return BlobDownload(data: blob.data, contentType: blob.type, range: nil, totalLength: blob.data.count)
  }

  public func events(from url: URL) -> AsyncThrowingStream<ServerSentEvent, any Error> {
    AsyncThrowingStream { continuation in
      state.withLock { $0.pushSubscribers.append(continuation) }
      continuation.yield(ServerSentEvent(event: "state", data: "{\"@type\":\"StateChange\",\"changed\":{}}"))
    }
  }

  // MARK: - Result references

  static func resolveReferences(in arguments: JSONValue, against responses: [Invocation]) throws(MethodError) -> JSONValue {
    guard case .object(var members) = arguments else { return arguments }
    for (key, value) in members where key.hasPrefix("#") {
      guard let resultOf = value["resultOf"]?.stringValue,
            let name = value["name"]?.stringValue,
            let path = value["path"]?.stringValue
      else { throw MethodError(type: MethodError.invalidResultReference, description: "malformed reference \(key)") }
      guard let source = responses.first(where: { $0.callId == resultOf && $0.name == name }) else {
        throw MethodError(type: MethodError.invalidResultReference, description: "no response \(name) for \(resultOf)")
      }
      guard let resolved = Self.evaluate(JSONPointer(rfc6901: path).tokens[...], in: source.arguments) else {
        throw MethodError(type: MethodError.invalidResultReference, description: "path \(path) not found")
      }
      members[key] = nil
      members[String(key.dropFirst())] = resolved
    }
    return .object(members)
  }

  /// RFC 8620 section 3.7 pointer evaluation, with `*` over arrays.
  static func evaluate(_ tokens: ArraySlice<String>, in value: JSONValue) -> JSONValue? {
    guard let token = tokens.first else { return value }
    let rest = tokens.dropFirst()
    if token == "*", case .array(let elements) = value {
      var collected: [JSONValue] = []
      for element in elements {
        guard let resolved = evaluate(rest, in: element) else { return nil }
        if case .array(let inner) = resolved { collected += inner } else { collected.append(resolved) }
      }
      return .array(collected)
    }
    switch value {
    case .object(let members):
      guard let next = members[token] else { return nil }
      return evaluate(rest, in: next)
    case .array(let elements):
      guard let index = Int(token), elements.indices.contains(index) else { return nil }
      return evaluate(rest, in: elements[index])
    default:
      return nil
    }
  }
}

private extension JSONValue {
  func merging(_ other: [String: JSONValue]) -> JSONValue {
    guard case .object(var members) = self else { return self }
    for (key, value) in other { members[key] = value }
    return .object(members)
  }
}

private extension String {
  func alsoPush(_ server: ScriptedServer) -> String {
    server.pushStateChange()
    return self
  }
}
