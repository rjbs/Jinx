import Foundation
import Testing
import JinxJSON
@testable import JinxWire

private func makeClient() -> JMAPClient {
  JMAPClient(
    sessionUrl: sessionBase,
    authenticator: BearerToken("tok"),
    urlSession: StubProtocol.makeSession()
  )
}

@Suite(.serialized) struct ClientSuite {
  @Test func sendPostsJSONWithHeaders() async throws {
    StubProtocol.install { request, body in
      #expect(request.httpMethod == "POST")
      #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
      #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
      #expect(body.flatMap { try? JSONValue(parsing: $0) }?["methodCalls"]?[0]?[0] == "Core/echo")
      return .init(body: Data("{\"methodResponses\":[[\"Core/echo\",{\"x\":1},\"c0\"]],\"sessionState\":\"s\"}".utf8))
    }
    var builder = RequestBuilder(using: [Session.coreCapability])
    let echo = builder.call("Core/echo", ["x": 1])
    let response = try await makeClient().send(builder.request, to: URL(string: "https://jmap.example.com/api")!)
    #expect(response.response(to: echo.callId)?.arguments == ["x": 1])
    #expect(response.sessionState == "s")
  }

  @Test func problemDetailsBecomeRequestErrors() async {
    StubProtocol.install { _, _ in
      .init(status: 400, headers: ["Content-Type": "application/problem+json"],
            body: Data("{\"type\":\"urn:ietf:params:jmap:error:limit\",\"limit\":\"maxCallsInRequest\",\"status\":400}".utf8))
    }
    await #expect(throws: JMAPError.self) {
      try await makeClient().send(Request(using: [], methodCalls: []), to: sessionBase)
    }
    do {
      _ = try await makeClient().send(Request(using: [], methodCalls: []), to: sessionBase)
    } catch JMAPError.request(let error) {
      #expect(error.kind == .limit)
      #expect(error.limit == "maxCallsInRequest")
    } catch {
      Issue.record("wrong error: \(error)")
    }
  }

  @Test func otherStatusesAreHTTPErrors() async {
    StubProtocol.install { _, _ in .init(status: 503, headers: [:], body: Data("down".utf8)) }
    do {
      _ = try await makeClient().fetchSession()
      Issue.record("expected a throw")
    } catch JMAPError.httpStatus(let status, let body) {
      #expect(status == 503)
      #expect(body == Data("down".utf8))
    } catch {
      Issue.record("wrong error: \(error)")
    }
  }

  @Test func sessionResolvesRelativeURLs() async throws {
    StubProtocol.install { _, _ in .init(body: Data(rfcSessionText.utf8)) }
    let session = try await makeClient().fetchSession()
    #expect(session.apiUrl.absoluteString == "https://jmap.example.com/jmap/api/")
    #expect(session.uploadUrl.expand(["accountId": "A"])?.absoluteString == "https://jmap.example.com/jmap/upload/A/")
  }

  @Test func uploadSendsBytesAndParsesTheReply() async throws {
    StubProtocol.install { request, body in
      #expect(request.value(forHTTPHeaderField: "Content-Type") == "audio/mpeg")
      #expect(body == Data([1, 2, 3]))
      return .init(body: Data("{\"accountId\":\"A\",\"blobId\":\"B\",\"type\":\"audio/mpeg\",\"size\":3}".utf8))
    }
    let upload = try await makeClient().upload(Data([1, 2, 3]), contentType: "audio/mpeg", to: sessionBase)
    #expect(upload.blobId == "B")
    #expect(upload.size == 3)
  }

  @Test func rangedDownloadReportsItsRange() async throws {
    StubProtocol.install { request, _ in
      #expect(request.value(forHTTPHeaderField: "Range") == "bytes=10-19")
      return .init(status: 206, headers: ["Content-Type": "audio/mpeg", "Content-Range": "bytes 10-19/100"], body: Data(repeating: 7, count: 10))
    }
    let download = try await makeClient().download(from: sessionBase, range: 10..<20)
    #expect(download.data.count == 10)
    #expect(download.range == 10..<20)
    #expect(download.totalLength == 100)
    #expect(download.contentType == "audio/mpeg")
  }

  @Test func wholeDownloadHasNoRange() async throws {
    StubProtocol.install { request, _ in
      #expect(request.value(forHTTPHeaderField: "Range") == nil)
      return .init(headers: ["Content-Length": "4"], body: Data([1, 2, 3, 4]))
    }
    let download = try await makeClient().download(from: sessionBase, range: nil)
    #expect(download.range == nil)
    #expect(download.totalLength == 4)
  }

  @Test func rawEventsStreamUntilTheBodyEnds() async throws {
    StubProtocol.install { request, _ in
      #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
      return .init(headers: ["Content-Type": "text/event-stream"], body: Data("event: ping\ndata: {}\n\nevent: state\ndata: {\"@type\":\"StateChange\",\"changed\":{}}\n\n".utf8))
    }
    var names: [String?] = []
    for try await event in makeClient().events(from: sessionBase) {
      names.append(event.event)
    }
    #expect(names == ["ping", "state"])
  }

  @Test func eventSourceClientReconnectsWithBackoff() async throws {
    let connections = Mutex(0)
    StubProtocol.install { _, _ in
      let n = connections.withLock { $0 += 1; return $0 }
      if n == 1 {
        return .init(headers: ["Content-Type": "text/event-stream"], body: Data("event: state\ndata: {\"@type\":\"StateChange\",\"changed\":{\"a\":{\"Email\":\"1\"}}}\n\n".utf8))
      }
      return .init(headers: ["Content-Type": "text/event-stream"], body: Data("event: ping\ndata: {}\n\n".utf8))
    }
    let client = EventSourceClient(transport: makeClient(), url: sessionBase, backoff: Backoff(initial: .milliseconds(1), maximum: .milliseconds(2)))
    var seen: [PushEvent] = []
    for await event in client.events() {
      seen.append(event)
      if seen.count == 6 { break }
    }
    #expect(seen[0] == .connected)
    #expect(seen[1] == .stateChange(StateChange(changed: ["a": ["Email": "1"]])))
    #expect(seen[2] == .disconnected(reason: nil, retryIn: .milliseconds(1)))
    #expect(seen[3] == .connected)
    #expect(seen[4] == .ping)
    #expect(seen[5] == .disconnected(reason: nil, retryIn: .milliseconds(1)))
  }
}

import Synchronization

private func assertContentRange(
  _ header: String,
  range: Range<Int>?,
  total: Int?,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  let parsed = JMAPClient.parseContentRange(header)
  #expect(parsed?.range == range, sourceLocation: sourceLocation)
  #expect(parsed?.total == total, sourceLocation: sourceLocation)
}

@Test func contentRangeParsing() {
  assertContentRange("bytes 0-99/1234", range: 0..<100, total: 1234)
  assertContentRange("bytes 5-5/*", range: 5..<6, total: nil)
  assertContentRange(" bytes 10-19/100 ", range: 10..<20, total: 100)
  assertContentRange("bytes */100", range: nil, total: nil)
  assertContentRange("bytes 9-5/100", range: nil, total: nil)
  assertContentRange("items 0-9/10", range: nil, total: nil)
}

@Test func backoffGrowsAndCaps() {
  let delays = Array(Backoff(initial: .seconds(1), maximum: .seconds(10), multiplier: 3).delays().prefix(5))
  #expect(delays == [.seconds(1), .seconds(3), .seconds(9), .seconds(10), .seconds(10)])
}
