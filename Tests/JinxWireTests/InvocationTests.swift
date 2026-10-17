import Foundation
import Testing
import JinxJSON
@testable import JinxWire

@Test func invocationRoundTrips() throws {
  let invocation = Invocation(name: "Core/echo", arguments: ["hello": true], callId: "c0")
  #expect(invocation.json == ["Core/echo", ["hello": true], "c0"])
  #expect(try Invocation(json: invocation.json) == invocation)
  #expect(!invocation.isError)
  #expect(try invocation.result() == ["hello": true])
}

@Test func errorInvocationsCarryMethodErrors() throws {
  let invocation = try Invocation(json: json("[\"error\", {\"type\": \"serverFail\", \"description\": \"boom\", \"detail\": 1}, \"c1\"]"))
  #expect(invocation.isError)
  let error = try #require(invocation.methodError)
  #expect(error.type == MethodError.serverFail)
  #expect(error.description == "boom")
  #expect(error.extra == ["detail": 1])
  #expect(throws: error) { try invocation.result() }
}

private func assertInvocationRejected(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
  #expect(throws: JMAPError.self, sourceLocation: sourceLocation) { try Invocation(json: json(text)) }
}

@Test func malformedInvocationsAreRejected() {
  assertInvocationRejected("[\"a\", {}]")
  assertInvocationRejected("[\"a\", [], \"c\"]")
  assertInvocationRejected("[1, {}, \"c\"]")
  assertInvocationRejected("{}")
}

@Test func requestEncodesWithSortedUsing() throws {
  let request = Request(
    using: ["urn:ietf:params:jmap:mail", "urn:ietf:params:jmap:core"],
    methodCalls: [Invocation(name: "Mailbox/get", arguments: ["accountId": "a", "ids": .null], callId: "c0")],
    createdIds: ["k": "v"]
  )
  #expect(
    try request.json.serializedString()
      == "{\"createdIds\":{\"k\":\"v\"},\"methodCalls\":[[\"Mailbox/get\",{\"accountId\":\"a\",\"ids\":null},\"c0\"]],\"using\":[\"urn:ietf:params:jmap:core\",\"urn:ietf:params:jmap:mail\"]}"
  )
}

@Test func responseParsesAndIndexesByCallId() throws {
  let response = try Response(json: json("""
  {
    "methodResponses": [
      ["Email/changes", {"accountId": "a", "oldState": "1", "newState": "2", "created": ["x"], "updated": [], "destroyed": []}, "c0"],
      ["Email/get", {"accountId": "a", "state": "2", "list": [{"id": "x"}], "notFound": []}, "c1"],
      ["Email/get", {"accountId": "a", "state": "2", "list": [], "notFound": []}, "c1"]
    ],
    "createdIds": {"new1": "serverId"},
    "sessionState": "s1"
  }
  """))
  #expect(response.sessionState == "s1")
  #expect(response.createdIds == ["new1": "serverId"])
  #expect(response.responses(to: "c1").count == 2)
  #expect(response.response(to: "c0")?.name == "Email/changes")
  #expect(response.response(to: "c9") == nil)
}

@Test func responseWithoutMethodResponsesIsMalformed() {
  #expect(throws: JMAPError.self) { try Response(json: json("{\"sessionState\": \"x\"}")) }
}

@Test func resultReferencesEncodeAndReplaceLiterals() {
  var args: JSONValue = ["accountId": "a", "ids": ["literal"]]
  args.setReference(ResultReference(resultOf: "c0", name: "Email/changes", path: JSONPointer("created")), for: "ids")
  #expect(args == [
    "accountId": "a",
    "#ids": ["resultOf": "c0", "name": "Email/changes", "path": "/created"],
  ])
}

@Test func builderAssignsIdsAndWiresReferences() {
  var builder = RequestBuilder(using: ["urn:ietf:params:jmap:core"])
  builder.use("urn:ietf:params:jmap:mail")
  let changes = builder.call("Email/changes", .changesArguments(accountId: "a", sinceState: "s"))
  let get = builder.call(
    "Email/get",
    .getArguments(accountId: "a", ids: [], properties: ["subject"]),
    references: ["ids": changes.reference("/created")]
  )
  #expect(changes.callId == "c0")
  #expect(get.callId == "c1")
  #expect(builder.count == 2)
  let request = builder.request
  #expect(Set(request.using) == ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"])
  #expect(request.methodCalls[1].arguments["#ids"]?["resultOf"] == "c0")
  #expect(request.methodCalls[1].arguments["#ids"]?["path"] == "/created")
  #expect(request.methodCalls[1].arguments["ids"] == nil)
  #expect(request.methodCalls[1].arguments["properties"] == ["subject"])
}
