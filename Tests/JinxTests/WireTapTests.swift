import Foundation
import Testing
import JinxJSON
import JinxWire
import JinxScriptedServer
import JinxStore
@testable import Jinx

private struct CannedTransport: JMAPTransport {
  var responses: [String: JSONValue] = [:]
  var failSends = false

  func fetchSession() async throws(JMAPError) -> Session {
    try Session(json: json(sessionText), base: URL(string: "https://jmap.example.com/")!)
  }

  func send(_ request: Request, to apiUrl: URL) async throws(JMAPError) -> Response {
    if failSends { throw .malformed("canned failure") }
    return Response(
      methodResponses: request.methodCalls.map { call in
        Invocation(name: call.name, arguments: responses[call.name] ?? [:], callId: call.callId)
      },
      sessionState: "s1"
    )
  }

  func upload(_ data: Data, contentType: String, to uploadUrl: URL) async throws(JMAPError) -> UploadResponse {
    try UploadResponse(json: ["accountId": "a", "blobId": "B1", "type": .string(contentType), "size": .number(Double(data.count))])
  }

  func download(from url: URL, range: Range<Int>?) async throws(JMAPError) -> BlobDownload {
    BlobDownload(data: Data(count: 10), contentType: "text/plain")
  }

  func events(from url: URL) -> AsyncThrowingStream<ServerSentEvent, any Error> {
    AsyncThrowingStream { continuation in
      continuation.yield(ServerSentEvent(event: "ping", data: "{}"))
      continuation.yield(ServerSentEvent(event: "ping", data: "{}"))
      continuation.finish()
    }
  }
}

private let apiUrl = URL(string: "https://jmap.example.com/api/")!

private func call(_ name: String, _ arguments: JSONValue = [:], id: String = "c0") -> Request {
  Request(using: [], methodCalls: [Invocation(name: name, arguments: arguments, callId: id)])
}

private let sessionText = """
{
  "capabilities": {},
  "accounts": {"a": {"name": "a", "isPersonal": true, "isReadOnly": false, "accountCapabilities": {}}},
  "primaryAccounts": {},
  "username": "u",
  "apiUrl": "/api/",
  "downloadUrl": "/d/{accountId}/{blobId}/{name}?type={type}",
  "uploadUrl": "/u/{accountId}/",
  "eventSourceUrl": "/e/?types={types}&closeafter={closeafter}&ping={ping}",
  "state": "st1"
}
"""

private func json(_ text: String) -> JSONValue {
  try! JSONValue(parsing: text)
}

/// Runs `body` against a canned transport with the given taps attached,
/// then returns what each tap recorded.
private func tapped(
  _ transport: CannedTransport = CannedTransport(),
  taps: Int = 1,
  _ body: (EngineTransport) async throws -> Void
) async rethrows -> [[TransportExchange]] {
  let registry = WireTaps()
  let recorders = (0..<taps).map { _ in TransportRecorder() }
  let tokens = recorders.map(registry.add)
  try await body(EngineTransport(inner: transport, taps: registry))
  withExtendedLifetime(tokens) {}
  return recorders.map(\.exchanges)
}

@Test func tapsSeeEveryKindOfExchange() async throws {
  let exchanges = try await tapped { transport in
    _ = try await transport.fetchSession()
    try await TransportContext.$purpose.withValue("sync-in Thing") {
      _ = try await transport.send(call("Thing/get"), to: apiUrl)
    }
    _ = try await transport.upload(Data(count: 3), contentType: "text/plain", to: apiUrl)
    _ = try await transport.download(from: apiUrl, range: 0..<10)
    for try await _ in transport.events(from: apiUrl) {}
  }[0]

  #expect(exchanges.map(\.id) == [1, 2, 3, 4, 5])
  #expect(exchanges.map(\.purpose) == [nil, "sync-in Thing", nil, nil, nil])
  #expect(exchanges.map(\.title) == [
    "session", "Thing/get", "upload text/plain, 3 bytes", "download api [0..<10]", "event stream",
  ])
  #expect(exchanges.map(\.outcomeSummary) == [
    "state st1, 1 account(s)",
    "1 response(s)",
    "blob B1, 3 bytes",
    "10 bytes text/plain",
    "closed after 2 event(s)",
  ])
  #expect(exchanges.allSatisfy { $0.finished != nil })
}

@Test func tapsSeeFailuresAndTheErrorIsRethrown() async throws {
  let exchanges = await tapped(CannedTransport(failSends: true)) { transport in
    await #expect(throws: JMAPError.self) { try await transport.send(call("Thing/get"), to: apiUrl) }
  }[0]
  let exchange = try #require(exchanges.first)
  #expect(exchange.isFailure)
  #expect(exchange.calls.map(\.responseSummary) == ["no response"])
}

@Test func everyTapSeesTheSameExchanges() async throws {
  let seen = try await tapped(taps: 2) { transport in
    for _ in 0..<3 { _ = try await transport.send(call("Thing/get"), to: apiUrl) }
  }
  #expect(seen.map { $0.map(\.id) } == [[1, 2, 3], [1, 2, 3]])
}

@Test func exchangesAreNumberedOnlyWhileTapped() async throws {
  let registry = WireTaps()
  let transport = EngineTransport(inner: CannedTransport(), taps: registry)
  _ = try await transport.send(call("Thing/get"), to: apiUrl)

  let recorder = TransportRecorder()
  let token = registry.add(recorder)
  _ = try await transport.send(call("Thing/get"), to: apiUrl)
  token.cancel()
  _ = try await transport.send(call("Thing/get"), to: apiUrl)
  #expect(recorder.exchanges.map(\.id) == [1], "untapped requests are not counted, and a cancelled tap hears nothing")

  do { _ = registry.add(recorder) }
  _ = try await transport.send(call("Thing/get"), to: apiUrl)
  #expect(recorder.exchanges.map(\.id) == [1], "a released token detaches its tap")
}

@Test func engineHandsItsTapsEveryRequest() async throws {
  let server = ScriptedServer(capabilities: [thingType.capability])
  let engine = try SyncEngine(
    configuration: SyncConfiguration(accountId: "acct", types: [thingType]),
    transport: server,
    store: try GRDBSyncStore.inMemory()
  )
  try await engine.sync()
  let recorder = TransportRecorder()
  let token = engine.addWireTap(recorder)
  server.create("Thing", ["n": 1])
  try await engine.sync()
  token.cancel()
  try await engine.sync()
  #expect(recorder.exchanges.map(\.title) == ["Thing/changes, Thing/get, Thing/get"])
}
