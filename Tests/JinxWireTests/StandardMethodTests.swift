import Testing
import JinxJSON
@testable import JinxWire

@Test func getResponse() throws {
  let response = try GetResponse(json: json("{\"accountId\":\"a\",\"state\":\"s\",\"list\":[{\"id\":\"1\"}],\"notFound\":[\"2\"]}"))
  #expect(response.state == "s")
  #expect(response.list == [["id": "1"]])
  #expect(response.notFound == ["2"])
  #expect(throws: JMAPError.self) { try GetResponse(json: json("{\"accountId\":\"a\"}")) }
}

@Test func changesResponse() throws {
  let response = try ChangesResponse(json: json("{\"accountId\":\"a\",\"oldState\":\"1\",\"newState\":\"2\",\"hasMoreChanges\":true,\"created\":[\"c\"],\"updated\":[\"u\"],\"destroyed\":[\"d\"]}"))
  #expect(response.oldState == "1")
  #expect(response.newState == "2")
  #expect(response.hasMoreChanges)
  #expect(response.created == ["c"])
  #expect(response.updated == ["u"])
  #expect(response.destroyed == ["d"])
}

@Test func setResponseWithEveryOutcome() throws {
  let response = try SetResponse(json: json("""
  {
    "accountId": "a", "oldState": "1", "newState": "2",
    "created": {"new1": {"id": "x1", "updated": "2026-01-01T00:00:00Z"}},
    "updated": {"u1": null, "u2": {"updated": "2026-01-01T00:00:00Z"}},
    "destroyed": ["d1"],
    "notCreated": {"new2": {"type": "invalidProperties", "properties": ["uid"], "description": "dup"}},
    "notUpdated": {"u3": {"type": "notFound"}},
    "notDestroyed": {"d2": {"type": "alreadyExists", "existingId": "zz"}}
  }
  """))
  #expect(response.oldState == "1")
  #expect(response.createdId(for: "new1") == "x1")
  #expect(response.createdId(for: "nope") == nil)
  #expect(response.updated["u1"] == .null)
  #expect(response.updated["u2"]?["updated"] == "2026-01-01T00:00:00Z")
  #expect(response.destroyed == ["d1"])
  #expect(response.notCreated["new2"] == SetError(type: SetError.invalidProperties, description: "dup", properties: ["uid"]))
  #expect(response.notUpdated["u3"]?.type == SetError.notFound)
  #expect(response.notDestroyed["d2"]?.existingId == "zz")
}

@Test func queryAndQueryChangesResponses() throws {
  let query = try QueryResponse(json: json("{\"accountId\":\"a\",\"queryState\":\"q\",\"canCalculateChanges\":true,\"position\":5,\"ids\":[\"x\"],\"total\":9,\"limit\":50}"))
  #expect(query.position == 5)
  #expect(query.total == 9)
  #expect(query.limit == 50)
  #expect(query.canCalculateChanges)

  let changes = try QueryChangesResponse(json: json("{\"accountId\":\"a\",\"oldQueryState\":\"q\",\"newQueryState\":\"r\",\"removed\":[\"x\"],\"added\":[{\"id\":\"y\",\"index\":0},{\"id\":\"bad\"}]}"))
  #expect(changes.removed == ["x"])
  #expect(changes.added == [.init(id: "y", index: 0)])
}

@Test func argumentBuildersOmitWhatIsNotSet() {
  #expect(JSONValue.getArguments(accountId: "a", ids: nil) == ["accountId": "a", "ids": .null])
  #expect(JSONValue.getArguments(accountId: "a", ids: ["1"]) == ["accountId": "a", "ids": ["1"]])
  #expect(JSONValue.changesArguments(accountId: "a", sinceState: "s", maxChanges: 10) == ["accountId": "a", "sinceState": "s", "maxChanges": 10])
  #expect(JSONValue.setArguments(accountId: "a") == ["accountId": "a"])
  #expect(
    JSONValue.setArguments(accountId: "a", ifInState: "s", create: ["k": ["t": 1]], update: ["i": ["p": .null]], destroy: ["d"])
      == ["accountId": "a", "ifInState": "s", "create": ["k": ["t": 1]], "update": ["i": ["p": .null]], "destroy": ["d"]]
  )
  #expect(JSONValue.queryArguments(accountId: "a") == ["accountId": "a"])
  #expect(
    JSONValue.queryArguments(accountId: "a", filter: ["inMailbox": "m"], sort: [["property": "receivedAt", "isAscending": false]], position: 10, limit: 50, calculateTotal: true)
      == ["accountId": "a", "filter": ["inMailbox": "m"], "sort": [["property": "receivedAt", "isAscending": false]], "position": 10, "limit": 50, "calculateTotal": true]
  )
  #expect(
    JSONValue.queryChangesArguments(accountId: "a", sinceQueryState: "q", maxChanges: 5, upToId: "z")
      == ["accountId": "a", "sinceQueryState": "q", "maxChanges": 5, "upToId": "z"]
  )
}
