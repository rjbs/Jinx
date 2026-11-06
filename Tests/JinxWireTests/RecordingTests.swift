import Foundation
import Testing
import JinxJSON
@testable import JinxWire

private let apiUrl = URL(string: "https://jmap.example.com/api/")!

private func exchange(_ id: Int, finished: Bool = false) -> TransportExchange {
  TransportExchange(
    id: id,
    kind: .api(Request(using: [], methodCalls: [Invocation(name: "Thing/get", arguments: ["ids": ["a"]], callId: "c0")]), url: apiUrl),
    finished: finished ? Date() : nil,
    outcome: finished ? .api(Response(methodResponses: [], sessionState: "s1")) : .pending
  )
}

@Test func recorderReplacesAnExchangeByIdWhenItEnds() {
  let recorder = TransportRecorder()
  recorder.observe(exchange(1))
  recorder.observe(exchange(2))
  recorder.observe(exchange(1, finished: true))
  #expect(recorder.exchanges.map(\.id) == [1, 2])
  #expect(recorder.exchanges.map { $0.finished != nil } == [true, false])
}

@Test func recorderKeepsOnlyItsCapacity() {
  let recorder = TransportRecorder(capacity: 2)
  for id in 1...5 { recorder.observe(exchange(id)) }
  #expect(recorder.exchanges.map(\.id) == [4, 5])
  recorder.clear()
  #expect(recorder.exchanges.isEmpty)
}

@Test func recorderStreamsWhatItObserves() async {
  let recorder = TransportRecorder()
  let updates = recorder.updates()
  recorder.observe(exchange(1))
  recorder.observe(exchange(1, finished: true))
  var seen: [Bool] = []
  for await exchange in updates {
    seen.append(exchange.finished != nil)
    if seen.count == 2 { break }
  }
  #expect(seen == [false, true])
}

@Test func recorderWritesOneJSONObjectPerLine() throws {
  let recorder = TransportRecorder()
  recorder.observe(exchange(1, finished: true))
  recorder.observe(TransportExchange(id: 2, kind: .session))
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("jinx-recording-\(UUID().uuidString).jsonl")
  defer { try? FileManager.default.removeItem(at: url) }
  try recorder.write(to: url)

  let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
  #expect(lines.count == 2)
  let first = try JSONValue(parsing: String(lines[0]))
  #expect(first["title"] == "Thing/get")
  #expect(first["request"]?["methodCalls"]?[0]?[1]?["ids"] == ["a"])
  #expect(first["response"]?["sessionState"] == "s1")
}

@Test func tokenDetachesOnceWhetherCancelledOrReleased() {
  let count = Counter()
  let token = WireTapToken { count.bump() }
  token.cancel()
  token.cancel()
  #expect(count.value == 1)
  do { _ = WireTapToken { count.bump() } }
  #expect(count.value == 2)
}

private final class Counter: @unchecked Sendable {
  var value = 0
  func bump() { value += 1 }
}

// MARK: - Call summaries

private func assertSummaries(
  _ name: String,
  call arguments: JSONValue,
  response: JSONValue,
  responseName: String? = nil,
  callSummary: String,
  responseSummary: String,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  let exchange = CallExchange(
    call: Invocation(name: name, arguments: arguments, callId: "c0"),
    responses: [Invocation(name: responseName ?? name, arguments: response, callId: "c0")]
  )
  #expect(exchange.callSummary == callSummary, sourceLocation: sourceLocation)
  #expect(exchange.responseSummary == responseSummary, sourceLocation: sourceLocation)
}

@Test func standardMethodsAreSummarized() {
  assertSummaries(
    "Email/get",
    call: ["accountId": "a", "ids": ["1", "2", "3"], "properties": ["id", "subject"]],
    response: ["accountId": "a", "state": "s9", "list": [[:], [:]], "notFound": ["3"]],
    callSummary: "3 id(s), 2 properties",
    responseSummary: "2 returned, 1 not found, state s9"
  )
  assertSummaries(
    "Email/get",
    call: ["accountId": "a", "#ids": ["resultOf": "c0", "name": "Email/changes", "path": "/created"]],
    response: ["accountId": "a", "state": "s9", "list": []],
    callSummary: "ids by reference, ref ids ← c0 Email/changes /created",
    responseSummary: "0 returned, state s9"
  )
  assertSummaries(
    "Mailbox/changes",
    call: ["accountId": "a", "sinceState": "s1", "maxChanges": 100],
    response: [
      "accountId": "a", "oldState": "s1", "newState": "s2", "hasMoreChanges": true,
      "created": ["x"], "updated": [], "destroyed": ["y", "z"],
    ],
    callSummary: "since s1, max 100",
    responseSummary: "+1 ~0 -2, s1 → s2, more"
  )
  assertSummaries(
    "Thing/set",
    call: ["accountId": "a", "ifInState": "s2", "create": ["k1": [:]], "update": ["x": [:], "y": [:]]],
    response: [
      "accountId": "a", "oldState": "s2", "newState": "s3",
      "created": ["k1": ["id": "z"]], "updated": ["x": .null],
      "notUpdated": ["y": ["type": "notFound"]],
    ],
    callSummary: "if in s2, create 1, update 2",
    responseSummary: "created 1, updated 1, notUpdated 1 (notFound), s2 → s3"
  )
  assertSummaries(
    "Email/query",
    call: ["accountId": "a", "filter": ["inMailbox": "m"], "position": 50, "limit": 50],
    response: [
      "accountId": "a", "queryState": "q1", "canCalculateChanges": true, "position": 50,
      "ids": ["1", "2"], "total": 52, "groupByCounts": [:],
    ],
    callSummary: "filtered, from 50, limit 50",
    responseSummary: "2 id(s), at 50, of 52, queryState q1, +groupByCounts"
  )
  assertSummaries(
    "Email/queryChanges",
    call: ["accountId": "a", "sinceQueryState": "q1"],
    response: [
      "accountId": "a", "oldQueryState": "q1", "newQueryState": "q2",
      "removed": ["1"], "added": [["id": "3", "index": 0]],
    ],
    callSummary: "since q1",
    responseSummary: "removed 1, added 1, q1 → q2"
  )
}

@Test func errorsAndUnknownMethodsAreSummarized() {
  assertSummaries(
    "Thing/set",
    call: ["accountId": "a", "ifInState": "s1"],
    response: ["type": "stateMismatch", "description": "nope"],
    responseName: "error",
    callSummary: "if in s1",
    responseSummary: "error stateMismatch: nope"
  )
  assertSummaries(
    "Core/echo",
    call: ["hello": true, "accountId": "a"],
    response: ["hello": true],
    callSummary: "hello",
    responseSummary: "hello"
  )
}
