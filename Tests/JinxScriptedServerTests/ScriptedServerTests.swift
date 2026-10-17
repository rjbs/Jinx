import Foundation
import Testing
import JinxJSON
import JinxWire
@testable import JinxScriptedServer

private let api = URL(string: "jinx://server/api")!

private func send(_ server: ScriptedServer, _ build: (inout RequestBuilder) -> Void) async throws -> Response {
  var builder = RequestBuilder(using: [Session.coreCapability])
  build(&builder)
  return try await server.send(builder.request, to: api)
}

private func call(_ server: ScriptedServer, _ name: String, _ args: JSONValue) async throws -> JSONValue {
  let response = try await send(server) { $0.call(name, args) }
  return try #require(response.response(to: "c0")).arguments
}

@Test func sessionAdvertisesLimitsAndCapabilities() async throws {
  var limits = ScriptedServer.Limits()
  limits.maxObjectsInGet = 7
  let server = ScriptedServer(capabilities: ["urn:example:things"], limits: limits)
  let session = try await server.fetchSession()
  #expect(session.core?.maxObjectsInGet == 7)
  #expect(session.primaryAccountId(for: "urn:example:things") == "acct")
  #expect(session.accounts["acct"]?.isPersonal == true)
  #expect(session.apiUrl.absoluteString == "jinx://server/api")
}

@Test func getReturnsObjectsAndNotFound() async throws {
  let server = ScriptedServer()
  let id = server.create("Thing", ["n": 1])
  let all = try await call(server, "Thing/get", .getArguments(accountId: "acct", ids: nil))
  #expect(all["list"] == [["id": .string(id), "n": 1]])
  #expect(all["state"] == "1")

  let some = try await call(server, "Thing/get", .getArguments(accountId: "acct", ids: [id, "zz"], properties: ["n"]))
  #expect(some["list"] == [["id": .string(id), "n": 1]])
  #expect(some["notFound"] == ["zz"])

  var limits = ScriptedServer.Limits()
  limits.maxObjectsInGet = 1
  let small = ScriptedServer(limits: limits)
  small.create("Thing", [:])
  small.create("Thing", [:])
  let tooLarge = try await call(small, "Thing/get", .getArguments(accountId: "acct", ids: nil))
  #expect(tooLarge["type"] == "requestTooLarge")
}

@Test func changesTrackCreatesUpdatesAndDestroysWithPaging() async throws {
  let server = ScriptedServer()
  let a = server.create("Thing", ["n": 1])
  let b = server.create("Thing", ["n": 2])
  let s2 = server.state(of: "Thing")
  server.update("Thing", a) { $0["n"] = 10 }
  server.destroy("Thing", b)
  let c = server.create("Thing", ["n": 3])

  let changes = try await ChangesResponse(json: call(server, "Thing/changes", .changesArguments(accountId: "acct", sinceState: s2)))
  #expect(changes.oldState == s2)
  #expect(changes.newState == server.state(of: "Thing"))
  #expect(!changes.hasMoreChanges)
  #expect(changes.created == [c])
  #expect(changes.updated == [a])
  #expect(changes.destroyed == [b])

  let fromZero = try await ChangesResponse(json: call(server, "Thing/changes", .changesArguments(accountId: "acct", sinceState: "0")))
  #expect(Set(fromZero.created) == [a, c], "an object created and updated since the state is created")
  #expect(fromZero.destroyed == [b], "an object created and destroyed since the state is still reported destroyed")

  let page = try await ChangesResponse(json: call(server, "Thing/changes", .changesArguments(accountId: "acct", sinceState: "0", maxChanges: 2)))
  #expect(page.hasMoreChanges)
  #expect(page.created == [a])
  #expect(page.destroyed == [b])
  let next = try await ChangesResponse(json: call(server, "Thing/changes", .changesArguments(accountId: "acct", sinceState: page.newState)))
  #expect(!next.hasMoreChanges)
  #expect(next.created == [c])
  #expect(next.updated == [], "a was already reported, as created, on the first page")

  let bad = try await call(server, "Thing/changes", .changesArguments(accountId: "acct", sinceState: "garbage"))
  #expect(bad["type"] == "cannotCalculateChanges")
  let future = try await call(server, "Thing/changes", .changesArguments(accountId: "acct", sinceState: "999"))
  #expect(future["type"] == "cannotCalculateChanges")
}

@Test func setCreatesUpdatesDestroysAndReportsErrors() async throws {
  let server = ScriptedServer()
  server.configure("Thing", .init(uniqueProperty: "uid"))
  let existing = server.create("Thing", ["uid": "u1", "n": 1])
  let before = server.state(of: "Thing")

  let response = try await SetResponse(json: call(server, "Thing/set", .setArguments(
    accountId: "acct",
    create: ["k1": ["uid": "u2", "n": 2], "k2": ["uid": "u1"], "k3": ["id": "forced"]],
    update: [existing: ["n": 11, "tags/x": true], "missing": ["n": 1]],
    destroy: ["nothere"]
  )))
  #expect(response.oldState == before)
  #expect(response.newState == server.state(of: "Thing"))
  let newId = try #require(response.createdId(for: "k1"))
  #expect(server.object("Thing", newId) == ["id": .string(newId), "uid": "u2", "n": 2])
  #expect(response.notCreated["k2"]?.type == "invalidProperties")
  #expect(response.notCreated["k2"]?.properties == ["uid"])
  #expect(response.notCreated["k3"]?.properties == ["id"])
  #expect(response.updated[existing] == .null)
  #expect(server.object("Thing", existing) == ["id": .string(existing), "uid": "u1", "n": 11, "tags": ["x": true]])
  #expect(response.notUpdated["missing"]?.type == "notFound")
  #expect(response.notDestroyed["nothere"]?.type == "notFound")

  let destroyed = try await SetResponse(json: call(server, "Thing/set", .setArguments(accountId: "acct", destroy: [existing])))
  #expect(destroyed.destroyed == [existing])
  #expect(server.object("Thing", existing) == nil)

  let mismatch = try await call(server, "Thing/set", .setArguments(accountId: "acct", ifInState: "0", destroy: [newId]))
  #expect(mismatch["type"] == "stateMismatch")
}

@Test func creationIdsResolveWithinAndAcrossCalls() async throws {
  let server = ScriptedServer()
  let response = try await send(server) { b in
    b.call("Box/set", .setArguments(accountId: "acct", create: ["box": ["name": "b"]]))
    b.call("Thing/set", .setArguments(accountId: "acct", create: ["t": ["boxId": "#box", "boxIds": ["#box": true]]]))
  }
  let boxSet = try SetResponse(json: #require(response.response(to: "c0")).arguments)
  let thingSet = try SetResponse(json: #require(response.response(to: "c1")).arguments)
  let boxId = try #require(boxSet.createdId(for: "box"))
  let thingId = try #require(thingSet.createdId(for: "t"))
  #expect(server.object("Thing", thingId)?["boxId"] == .string(boxId))
  #expect(server.object("Thing", thingId)?["boxIds"] == [boxId: true])
  #expect(response.createdIds == ["box": boxId, "t": thingId])
}

@Test func resultReferencesFeedLaterCalls() async throws {
  let server = ScriptedServer()
  let a = server.create("Thing", ["n": 1])
  let response = try await send(server) { b in
    let changes = b.call("Thing/changes", .changesArguments(accountId: "acct", sinceState: "0"))
    b.call("Thing/get", .getArguments(accountId: "acct", ids: []), references: ["ids": changes.reference("/created")])
    b.call("Thing/get", .getArguments(accountId: "acct", ids: []), references: ["ids": changes.reference("/nonsense")])
    b.call("Thing/get", .getArguments(accountId: "acct", ids: []), references: ["ids": ResultReference(resultOf: "c9", name: "Thing/changes", path: JSONPointer("created"))])
  }
  let got = try GetResponse(json: #require(response.response(to: "c1")).arguments)
  #expect(got.list.map { $0["id"] } == [.string(a)])
  #expect(response.response(to: "c2")?.methodError?.type == "invalidResultReference")
  #expect(response.response(to: "c3")?.methodError?.type == "invalidResultReference")
}

@Test func wildcardPointerCollectsAcrossArrays() {
  let value: JSONValue = ["list": [["id": "a", "tags": ["x", "y"]], ["id": "b", "tags": ["z"]]]]
  #expect(ScriptedServer.evaluate(JSONPointer(rfc6901: "/list/*/id").tokens[...], in: value) == ["a", "b"])
  #expect(ScriptedServer.evaluate(JSONPointer(rfc6901: "/list/*/tags").tokens[...], in: value) == ["x", "y", "z"])
  #expect(ScriptedServer.evaluate(JSONPointer(rfc6901: "/list/1/id").tokens[...], in: value) == "b")
  #expect(ScriptedServer.evaluate(JSONPointer(rfc6901: "/list/*/missing").tokens[...], in: value) == nil)
}

@Test func queryFiltersSortsAndPages() async throws {
  let server = ScriptedServer()
  let a = server.create("Thing", ["n": 3, "kind": "x"])
  let b = server.create("Thing", ["n": 1, "kind": "x"])
  let c = server.create("Thing", ["n": 2, "kind": "y"])

  let sorted = try await QueryResponse(json: call(server, "Thing/query", .queryArguments(accountId: "acct", sort: [["property": "n", "isAscending": false]], calculateTotal: true)))
  #expect(sorted.ids == [a, c, b])
  #expect(sorted.total == 3)
  #expect(!sorted.canCalculateChanges)
  #expect(sorted.queryState == server.state(of: "Thing"))

  let filtered = try await QueryResponse(json: call(server, "Thing/query", .queryArguments(accountId: "acct", filter: ["kind": "x"], sort: [["property": "n"]])))
  #expect(filtered.ids == [b, a])

  let compound = try await QueryResponse(json: call(server, "Thing/query", .queryArguments(accountId: "acct", filter: ["operator": "NOT", "conditions": [["kind": "x"]]])))
  #expect(compound.ids == [c])

  let paged = try await QueryResponse(json: call(server, "Thing/query", .queryArguments(accountId: "acct", sort: [["property": "n"]], position: 1, limit: 1)))
  #expect(paged.ids == [c])
  #expect(paged.position == 1)

  let anchored = try await QueryResponse(json: call(server, "Thing/query", .queryArguments(accountId: "acct", sort: [["property": "n"]], anchor: c, anchorOffset: 1)))
  #expect(anchored.ids == [a])
  let missingAnchor = try await call(server, "Thing/query", .queryArguments(accountId: "acct", anchor: "zz"))
  #expect(missingAnchor["type"] == "anchorNotFound")

  let queryChanges = try await call(server, "Thing/queryChanges", .queryChangesArguments(accountId: "acct", sinceQueryState: "1"))
  #expect(queryChanges["type"] == "cannotCalculateChanges")
}

@Test func faultsFireOnceInOrder() async throws {
  let server = ScriptedServer()
  server.create("Thing", [:])
  server.enqueue(.transportFailure)
  server.enqueue(.methodError(method: "Thing/changes", MethodError(type: MethodError.cannotCalculateChanges)))
  server.enqueue(.rewrite(method: "Thing/get") { var r = $0; r["state"] = "lie"; return r })
  server.enqueue(.loseResponse)

  await #expect(throws: JMAPError.self) { try await call(server, "Core/echo", [:]) }

  let response = try await send(server) { b in
    b.call("Thing/changes", .changesArguments(accountId: "acct", sinceState: "0"))
    b.call("Thing/get", .getArguments(accountId: "acct", ids: nil))
  }
  #expect(response.response(to: "c0")?.methodError?.type == "cannotCalculateChanges")
  #expect(response.response(to: "c1")?.arguments["state"] == "lie")

  await #expect(throws: JMAPError.self) {
    try await call(server, "Thing/set", .setArguments(accountId: "acct", create: ["k": ["n": 1]]))
  }
  #expect(server.objects("Thing").count == 2, "a lost response was still applied")

  let fine = try await call(server, "Thing/changes", .changesArguments(accountId: "acct", sinceState: "0"))
  #expect(fine["type"] == nil)
  #expect(server.requests.count == 4)
  #expect(server.calls(named: "Thing/changes").count == 2)
}

@Test func pushDeliversStateChangesToSubscribers() async throws {
  let server = ScriptedServer()
  let session = try await server.fetchSession()
  let url = try #require(EventSourceClient.url(from: session))
  var events: [ServerSentEvent] = []
  let stream = server.events(from: url)
  server.create("Thing", [:])
  server.dropPushConnections()
  for try await event in stream { events.append(event) }
  #expect(events.count == 2)
  let change = try StateChange(json: JSONValue(parsing: events[1].data))
  #expect(change.changed == ["acct": ["Thing": "1"]])
}

@Test func blobsUploadAndDownloadWithRanges() async throws {
  let server = ScriptedServer()
  let session = try await server.fetchSession()
  let upload = try await server.upload(Data([1, 2, 3, 4, 5]), contentType: "application/octet-stream", to: session.uploadUrl.expand(["accountId": "acct"])!)
  let url = try #require(session.downloadUrl.expand(["accountId": "acct", "blobId": upload.blobId, "name": "x", "type": "application/octet-stream"]))
  let whole = try await server.download(from: url, range: nil)
  #expect(whole.data == Data([1, 2, 3, 4, 5]))
  let part = try await server.download(from: url, range: 1..<3)
  #expect(part.data == Data([2, 3]))
  #expect(part.range == 1..<3)
  #expect(part.totalLength == 5)
  server.removeBlob(upload.blobId)
  await #expect(throws: JMAPError.self) { try await server.download(from: url, range: nil) }
}
