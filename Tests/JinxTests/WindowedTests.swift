import Foundation
import Testing
import JinxJSON
import JinxStore
import JinxWire
import JinxScriptedServer
@testable import Jinx

let itemType = TypeDescriptor(name: "Item", capability: "urn:test:items", mode: .windowed, references: ["groupId": "Group"])
let groupType = TypeDescriptor(name: "Group", capability: "urn:test:items", mode: .windowed)

private func byN(_ ascending: Bool = true) -> [JSONValue] {
  [["property": "n", "isAscending": .bool(ascending)]]
}

@Test func windowedTypeHoldsOnlyTheWindow() async throws {
  let h = try Harness(types: [itemType])
  let ids = (1...10).map { h.server.create("Item", ["n": .number(Double($0))]) }
  try await h.engine.sync()
  #expect(try await h.engine.objects(type: "Item").isEmpty, "nothing is held without a subscription")
  #expect(try await h.engine.state(of: "Item") == h.server.state(of: "Item"))

  try await h.engine.subscribe(QuerySubscription(id: "top", accountId: "acct", type: "Item", sort: byN(false), limit: 3))
  try await h.engine.sync()
  let result = try #require(try await h.engine.result(of: "top"))
  #expect(result.ids == [ids[9], ids[8], ids[7]])
  #expect(result.total == 10)
  #expect(try await h.engine.objects(in: "top").map { $0.value["n"] } == [10, 9, 8])
  #expect(try await h.engine.objects(type: "Item").count == 3)
  #expect(try await h.journal().last?.subscriptions == ["top"])
}

@Test func windowFollowsServerChanges() async throws {
  let h = try Harness(types: [itemType])
  let ids = (1...5).map { h.server.create("Item", ["n": .number(Double($0))]) }
  try await h.engine.subscribe(QuerySubscription(id: "top", accountId: "acct", type: "Item", sort: byN(false), limit: 3))
  try await h.engine.sync()
  let heldKey = try #require(try await h.engine.object(type: "Item", id: ids[4])).key
  h.server.clearRequests()

  h.server.update("Item", ids[4]) { $0["note"] = "edited" }
  h.server.destroy("Item", ids[3])
  let big = h.server.create("Item", ["n": 100])
  h.server.update("Item", ids[0]) { $0["note"] = "not held, not fetched" }
  try await h.engine.sync()

  #expect(try await h.engine.result(of: "top")?.ids == [big, ids[4], ids[2]])
  #expect(try await h.engine.object(key: heldKey)?.value["note"] == "edited")
  #expect(try await h.engine.object(type: "Item", id: ids[3]) == nil)
  #expect(try await h.engine.object(type: "Item", id: ids[0]) == nil)
  #expect(try await h.engine.objects(type: "Item").count == 3, "the object that left the window was evicted")
  let fetchedIds = h.server.resolvedCalls(named: "Item/get").flatMap { $0.arguments["ids"]?.arrayValue ?? [] }.compactMap(\.stringValue)
  #expect(Set(fetchedIds) == [ids[4], big])

  h.server.clearRequests()
  try await h.engine.sync()
  #expect(methodNames(h.server) == ["Item/changes"], "an unchanged type costs one call and no re-query")
}

@Test func pinsAndPendingChangesAreNeverEvicted() async throws {
  let h = try Harness(types: [itemType])
  let ids = (1...4).map { h.server.create("Item", ["n": .number(Double($0))]) }
  try await h.engine.subscribe(QuerySubscription(id: "top", accountId: "acct", type: "Item", sort: byN(false), limit: 1))
  try await h.engine.pin("Item", ids: [ids[0]])
  try await h.engine.sync()
  #expect(Set(try await h.engine.objects(type: "Item").compactMap(\.id)) == [ids[3], ids[0]])

  let pinnedKey = try #require(try await h.engine.object(type: "Item", id: ids[0])).key
  try await h.engine.unpin("Item", ids: [ids[0]])
  try await h.engine.update(pinnedKey, patch: ["note": "mine"])
  h.server.enqueue(.methodError(method: "Item/set", MethodError(type: MethodError.serverUnavailable)))
  await #expect(throws: SyncError.self) { try await h.engine.sync() }
  #expect(try await h.engine.object(key: pinnedKey) != nil, "a pending change keeps an object held")

  try await h.engine.sync()
  #expect(try await h.engine.object(key: pinnedKey)?.pending == nil)
  try await h.engine.sync()
  #expect(try await h.engine.object(key: pinnedKey) == nil, "with the change pushed and nothing retaining it, it is evicted")
}

@Test func referencedObjectsAreFetchedAndHeldOneLevel() async throws {
  let h = try Harness(types: [groupType, itemType])
  let g1 = h.server.create("Group", ["name": "g1"])
  let g2 = h.server.create("Group", ["name": "g2"])
  h.server.create("Group", ["name": "lonely"])
  h.server.create("Item", ["n": 1, "groupId": .string(g1)])
  h.server.create("Item", ["n": 2, "groupId": .string(g2)])
  try await h.engine.subscribe(QuerySubscription(id: "top", accountId: "acct", type: "Item", sort: byN(false), limit: 1))
  try await h.engine.sync()
  #expect(Set(try await h.engine.objects(type: "Group").compactMap(\.id)) == [g2], "only the held item's group")

  h.server.create("Item", ["n": 3, "groupId": .string(g1)])
  try await h.engine.sync()
  #expect(Set(try await h.engine.objects(type: "Group").compactMap(\.id)) == [g1], "the group follows the window")
}

@Test func wholeTypeSubscriptionActsAsAFullMirror() async throws {
  let h = try Harness(types: [itemType])
  let ids = (1...3).map { h.server.create("Item", ["n": .number(Double($0))]) }
  try await h.engine.subscribe(QuerySubscription(id: "window", accountId: "acct", type: "Item", sort: byN(false), limit: 1))
  try await h.engine.sync()
  #expect(try await h.engine.objects(type: "Item").count == 1)

  try await h.engine.subscribe(QuerySubscription(id: "everything", accountId: "acct", type: "Item"))
  try await h.engine.sync()
  #expect(try await h.engine.objects(type: "Item").count == 3)

  let created = h.server.create("Item", ["n": 0])
  try await h.engine.sync()
  #expect(try await h.engine.object(type: "Item", id: created) != nil, "created ids are fetched while a whole-type subscription exists")

  try await h.engine.unsubscribe("everything")
  try await h.engine.sync()
  #expect(try await h.engine.objects(type: "Item").compactMap(\.id) == [ids[2]], "back to the window")
}

@Test func queryChangesIsUsedWhenTheServerCanCalculate() async throws {
  let h = try Harness(types: [itemType])
  h.server.configure("Item", .init(canCalculateChanges: true))
  let ids = (1...5).map { h.server.create("Item", ["n": .number(Double($0))]) }
  try await h.engine.subscribe(QuerySubscription(id: "all", accountId: "acct", type: "Item", filter: ["kind": .null], sort: byN()))
  try await h.engine.sync()
  #expect(try await h.engine.result(of: "all")?.canCalculateChanges == true)
  h.server.clearRequests()

  h.server.destroy("Item", ids[1])
  let newId = h.server.create("Item", ["n": 2.5])
  h.server.update("Item", ids[4]) { $0["n"] = 0 }
  try await h.engine.sync()
  #expect(methodNames(h.server).contains("Item/queryChanges"))
  #expect(!methodNames(h.server).contains("Item/query"))
  #expect(try await h.engine.result(of: "all")?.ids == [ids[4], ids[0], newId, ids[2], ids[3]])
  #expect(try await h.engine.objects(in: "all").map { $0.value["n"] } == [0, 1, 2.5, 3, 4])
}

@Test func windowedResyncKeepsPinsAndPendingAndRequeries() async throws {
  let h = try Harness(types: [itemType])
  let ids = (1...3).map { h.server.create("Item", ["n": .number(Double($0))]) }
  try await h.engine.subscribe(QuerySubscription(id: "top", accountId: "acct", type: "Item", sort: byN(false), limit: 2))
  try await h.engine.pin("Item", ids: [ids[0]])
  try await h.engine.sync()
  let key = try await h.engine.create("Item", ["n": 50])
  h.server.enqueue(.transportFailure)
  await #expect(throws: SyncError.self) { try await h.engine.sync() }

  h.server.update("Item", ids[2]) { $0["note"] = "changed while away" }
  h.server.enqueue(.methodError(method: "Item/changes", MethodError(type: MethodError.cannotCalculateChanges)))
  try await h.engine.sync()
  #expect(try await h.engine.object(type: "Item", id: ids[2])?.value["note"] == "changed while away")
  #expect(try await h.engine.object(type: "Item", id: ids[0]) != nil, "pinned survives")
  #expect(try await h.engine.object(key: key)?.id != nil, "pending create survived and was pushed")
  #expect(try await h.engine.result(of: "top")?.ids.count == 2)
}

@Test func fetchOnDemandStoresAndIsEvictedUnlessPinned() async throws {
  let h = try Harness(types: [itemType])
  let id = h.server.create("Item", ["n": 1, "body": "long"])
  try await h.engine.sync()
  let fetched = try await h.engine.fetch("Item", ids: [id], arguments: ["fetchBody": true])
  #expect(fetched.map(\.id) == [id])
  #expect(h.server.calls(named: "Item/get").last?.arguments["fetchBody"] == true)
  #expect(try await h.engine.object(type: "Item", id: id)?.value["body"] == "long")
  try await h.engine.sync()
  #expect(try await h.engine.object(type: "Item", id: id) == nil, "nothing retained it")

  try await h.engine.pin("Item", ids: [id])
  try await h.engine.fetch("Item", ids: [id])
  try await h.engine.sync()
  #expect(try await h.engine.object(type: "Item", id: id) != nil)
}

@Test func redefiningASubscriptionStartsOver() async throws {
  let h = try Harness(types: [itemType])
  for n in 1...4 { h.server.create("Item", ["n": .number(Double(n))]) }
  try await h.engine.subscribe(QuerySubscription(id: "s", accountId: "acct", type: "Item", sort: byN(false), limit: 1))
  try await h.engine.sync()
  #expect(try await h.engine.objects(in: "s").map { $0.value["n"] } == [4])
  try await h.engine.subscribe(QuerySubscription(id: "s", accountId: "acct", type: "Item", sort: byN(true), limit: 2))
  #expect(try await h.engine.result(of: "s") == nil)
  try await h.engine.sync()
  #expect(try await h.engine.objects(in: "s").map { $0.value["n"] } == [1, 2])
  try await h.engine.subscribe(QuerySubscription(id: "s", accountId: "acct", type: "Item", sort: byN(true), limit: 2))
  #expect(try await h.engine.result(of: "s") != nil, "an identical redefinition keeps the result")
}

@Test func subscriptionOnAFullTypeOrdersWithoutFetching() async throws {
  let h = try Harness(types: [thingType])
  for n in 1...3 { h.server.create("Thing", ["n": .number(Double(n))]) }
  try await h.engine.sync()
  try await h.engine.subscribe(QuerySubscription(id: "desc", accountId: "acct", type: "Thing", sort: byN(false)))
  h.server.clearRequests()
  try await h.engine.sync()
  #expect(try await h.engine.objects(in: "desc").map { $0.value["n"] } == [3, 2, 1])
  #expect(try await h.engine.objects(type: "Thing").count == 3)
}

@Test func subscriptionArgumentsReachQueryAndQueryChangesAndEngineKeysWin() async throws {
  let h = try Harness(types: [itemType])
  h.server.configure("Item", .init(canCalculateChanges: true))
  for n in 1...3 { h.server.create("Item", ["n": .number(Double(n))]) }
  let extras: [String: JSONValue] = ["collapseThreads": true, "limit": 999, "calculateTotal": false]
  try await h.engine.subscribe(QuerySubscription(id: "conv", accountId: "acct", type: "Item", sort: byN(), limit: 2, arguments: extras))
  try await h.engine.sync()
  let query = try #require(h.server.calls(named: "Item/query").first)
  #expect(query.arguments["collapseThreads"] == true)
  #expect(query.arguments["limit"] == 2, "the engine's own arguments win")
  #expect(query.arguments["calculateTotal"] == true)

  h.server.create("Item", ["n": 0])
  try await h.engine.sync()
  let changes = try #require(h.server.calls(named: "Item/queryChanges").first)
  #expect(changes.arguments["collapseThreads"] == true)
  #expect(changes.arguments["sinceQueryState"] != nil)

  try await h.engine.subscribe(QuerySubscription(id: "conv", accountId: "acct", type: "Item", sort: byN(), limit: 2, arguments: ["collapseThreads": false]))
  #expect(try await h.engine.result(of: "conv") == nil, "changed arguments start the subscription over")
}
