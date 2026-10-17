import Foundation
import Testing
import JinxJSON
import JinxPatch
import JinxStore
import JinxWire
import JinxScriptedServer
@testable import Jinx

@Test func createIsPushedAndGetsAnId() async throws {
  let h = try Harness()
  try await h.engine.sync()
  let key = try await h.engine.create("Thing", ["n": 1])
  #expect(try await h.engine.object(key: key)?.pending == .create)
  #expect(try await h.journal().last?.types["Thing"]?.created == [key])
  h.server.clearRequests()

  try await h.engine.sync()
  let object = try #require(try await h.engine.object(key: key))
  let id = try #require(object.id)
  #expect(object.pending == nil)
  #expect(object.value == ["id": .string(id), "n": 1])
  #expect(h.server.object("Thing", id) == ["id": .string(id), "n": 1])
  #expect(try await h.stored(key)?.snapshot == object.value)
  #expect(try await h.pending() == [])
  let pushed = try #require(try await h.journal().first { $0.source == .push })
  #expect(pushed.types["Thing"]?.idsAssigned == [key: id])
  #expect(methodNames(h.server).first == "Thing/set")
  #expect(try await h.engine.state(of: "Thing") == h.server.state(of: "Thing"), "the set's newState advanced the stored state")
  let gets = h.server.resolvedCalls(named: "Thing/get")
  #expect(gets.allSatisfy { $0.arguments["ids"] == [] }, "the pull after the push had nothing to fetch")
}

@Test func updateSendsOnlyTheDiffAndKeepsForeignProperties() async throws {
  let h = try Harness(types: [taskType])
  let id = h.server.create("Task", ["uid": "u1", "title": "a", "progress": "needs-action", "foreign": ["x": 1]])
  try await h.engine.sync()
  let key = try #require(try await h.engine.object(type: "Task", id: id)).key
  h.server.clearRequests()

  try await h.engine.update(key, patch: ["progress": "completed"])
  try await h.engine.sync()
  let set = try #require(h.server.calls(named: "Task/set").first)
  #expect(set.arguments["update"] == [id: ["progress": "completed"]])
  #expect(h.server.object("Task", id) == ["id": .string(id), "uid": "u1", "title": "a", "progress": "completed", "foreign": ["x": 1]])
  #expect(try await h.engine.object(key: key)?.pending == nil)
}

@Test func replaceTouchesOnlyOwnedProperties() async throws {
  let h = try Harness(types: [taskType])
  let id = h.server.create("Task", ["uid": "u1", "title": "a", "progress": "needs-action", "foreign": true])
  try await h.engine.sync()
  let key = try #require(try await h.engine.object(type: "Task", id: id)).key
  try await h.engine.replace(key, with: ["uid": "u1", "title": "b", "keywords": ["k": true]])
  try await h.engine.sync()
  let set = try #require(h.server.calls(named: "Task/set").first)
  #expect(set.arguments["update"] == [id: ["title": "b", "progress": .null, "keywords": ["k": true]]])
  #expect(h.server.object("Task", id) == ["id": .string(id), "uid": "u1", "title": "b", "keywords": ["k": true], "foreign": true])
}

@Test func editsCollapseAndRevertingDropsTheEntry() async throws {
  let h = try Harness()
  let id = h.server.create("Thing", ["n": 1, "m": 1])
  try await h.engine.sync()
  let key = try #require(try await h.engine.object(type: "Thing", id: id)).key
  h.server.clearRequests()

  try await h.engine.update(key, patch: ["n": 2])
  try await h.engine.update(key, patch: ["m": 2])
  try await h.engine.update(key, patch: ["n": 3])
  try await h.engine.sync()
  let sets = h.server.calls(named: "Thing/set")
  #expect(sets.count == 1)
  #expect(sets[0].arguments["update"] == [id: ["n": 3, "m": 2]])

  h.server.clearRequests()
  try await h.engine.update(key, patch: ["n": 4])
  try await h.engine.update(key, patch: ["n": 3])
  #expect(try await h.pending() == [], "an edit back to the server value drops out")
  try await h.engine.sync()
  #expect(h.server.calls(named: "Thing/set").isEmpty)
}

@Test func destroyOfUnsentObjectIsLocalOnly() async throws {
  let h = try Harness()
  try await h.engine.sync()
  let key = try await h.engine.create("Thing", ["n": 1])
  try await h.engine.destroy(key)
  #expect(try await h.engine.object(key: key) == nil)
  #expect(try await h.pending() == [])
  h.server.clearRequests()
  try await h.engine.sync()
  #expect(h.server.calls(named: "Thing/set").isEmpty)
}

@Test func destroyOfSentObjectIsPushed() async throws {
  let h = try Harness()
  let id = h.server.create("Thing", ["n": 1])
  try await h.engine.sync()
  let key = try #require(try await h.engine.object(type: "Thing", id: id)).key
  try await h.engine.destroy(key)
  #expect(try await h.engine.object(key: key)?.pending == .destroy)
  try await h.engine.sync()
  #expect(try await h.engine.object(key: key) == nil)
  #expect(h.server.object("Thing", id) == nil)
  #expect(try await h.journal().last { $0.source == .push }?.types["Thing"]?.destroyed == [key])
}

@Test func bulkWritesBecomeOneSet() async throws {
  let h = try Harness()
  let ids = (1...3).map { h.server.create("Thing", ["n": .number(Double($0))]) }
  try await h.engine.sync()
  var keys: [LocalKey] = []
  for id in ids { keys.append(try #require(try await h.engine.object(type: "Thing", id: id)).key) }
  h.server.clearRequests()
  let keysNow = keys
  try await h.engine.write { w in
    for key in keysNow { try w.update(key, patch: ["done": true]) }
    _ = try w.create("Thing", ["n": 4])
  }
  #expect(try await h.journal().last?.types["Thing"]?.updated == keys)
  try await h.engine.sync()
  let sets = h.server.calls(named: "Thing/set")
  #expect(sets.count == 1)
  #expect(sets[0].arguments["update"]?.objectValue?.count == 3)
  #expect(sets[0].arguments["create"]?.objectValue?.count == 1)
}

@Test func rebaseKeepsPendingPropertyAndTakesTheRest() async throws {
  let h = try Harness()
  let id = h.server.create("Thing", ["n": 1, "m": 1])
  try await h.engine.sync()
  let key = try #require(try await h.engine.object(type: "Thing", id: id)).key

  try await h.engine.update(key, patch: ["n": 2])
  h.server.update("Thing", id) { $0["m"] = 50 }
  h.server.enqueue(.transportFailure)
  await #expect(throws: SyncError.self) { try await h.engine.sync() }

  // The push failed, so the next pass pulls the server's change under
  // the pending edit.
  h.server.enqueue(.methodError(method: "Thing/set", MethodError(type: MethodError.serverUnavailable)))
  await #expect(throws: SyncError.self) { try await h.engine.sync() }
  let object = try #require(try await h.engine.object(key: key))
  #expect(object.value == ["id": .string(id), "n": 2, "m": 50])
  #expect(object.pending == .update)
  #expect(try await h.stored(key)?.snapshot == ["id": .string(id), "n": 1, "m": 50])

  try await h.engine.sync()
  #expect(h.server.object("Thing", id) == ["id": .string(id), "n": 2, "m": 50])
  #expect(try await h.engine.object(key: key)?.pending == nil)
}

@Test func pendingChangeTheServerAlreadyHasIsDropped() async throws {
  let h = try Harness()
  let id = h.server.create("Thing", ["n": 1])
  try await h.engine.sync()
  let key = try #require(try await h.engine.object(type: "Thing", id: id)).key
  try await h.engine.update(key, patch: ["n": 2])
  h.server.update("Thing", id) { $0["n"] = 2 }
  h.server.enqueue(.methodError(method: "Thing/set", MethodError(type: MethodError.serverUnavailable)))
  await #expect(throws: SyncError.self) { try await h.engine.sync() }
  #expect(try await h.engine.object(key: key)?.pending == nil)
  #expect(try await h.pending() == [])
}

@Test func lostCreateResponseIsAdoptedByIdentity() async throws {
  let h = try Harness(types: [taskType])
  h.server.configure("Task", .init(uniqueProperty: "uid"))
  try await h.engine.sync()
  let key = try await h.engine.create("Task", ["uid": "u1", "title": "t"])
  h.server.enqueue(.loseResponse)
  await #expect(throws: SyncError.self) { try await h.engine.sync() }
  #expect(h.server.objects("Task").count == 1, "the server applied the create")
  // The pull that follows the failed push already adopts it by uid.
  let adopted = try #require(try await h.engine.object(key: key))
  #expect(adopted.id == h.server.objects("Task").keys.first)
  #expect(adopted.pending == nil)

  h.server.clearRequests()
  try await h.engine.sync()
  #expect(h.server.objects("Task").count == 1, "no duplicate")
  #expect(methodNames(h.server).first == "Task/changes", "the pass pulled before pushing")
  #expect(h.server.calls(named: "Task/set").isEmpty)
}

@Test func duplicateIdentityOnCreateAdoptsTheExistingObject() async throws {
  let h = try Harness(types: [taskType])
  h.server.configure("Task", .init(uniqueProperty: "uid"))
  let existing = h.server.create("Task", ["uid": "u1", "title": "server"])
  let key = try await h.engine.create("Task", ["uid": "u1", "title": "local"])
  // Push runs before pull, so the create collides.
  try await h.engine.sync()
  let object = try #require(try await h.engine.object(key: key))
  #expect(object.id == existing)
  #expect(try await h.engine.objects(type: "Task").count == 1)
  #expect(methodNames(h.server).contains("Task/query"))
}

@Test func permanentErrorRevertsOnlyThatObject() async throws {
  let h = try Harness()
  let a = h.server.create("Thing", ["n": 1])
  let b = h.server.create("Thing", ["n": 2])
  try await h.engine.sync()
  let keyA = try #require(try await h.engine.object(type: "Thing", id: a)).key
  let keyB = try #require(try await h.engine.object(type: "Thing", id: b)).key
  try await h.engine.update(keyA, patch: ["n": 10])
  try await h.engine.update(keyB, patch: ["n": 20])
  h.server.enqueue(.rewrite(method: "Thing/set") { response in
    var r = response
    r["updated"] = [b: .null]
    r["notUpdated"] = [a: ["type": "forbidden"]]
    return r
  })
  try await h.engine.sync()
  let objectA = try #require(try await h.engine.object(key: keyA))
  #expect(objectA.value["n"] == 1, "reverted to the snapshot")
  #expect(objectA.lastError?.type == "forbidden")
  #expect(objectA.pending == nil)
  let objectB = try #require(try await h.engine.object(key: keyB))
  #expect(objectB.value["n"] == 20)
  #expect(objectB.pending == nil)
  let pushed = try #require(try await h.journal().first { $0.source == .push })
  #expect(pushed.failed[keyA]?.type == "forbidden")
}

@Test func retryableFailureKeepsEntriesAndReleasesClaims() async throws {
  let h = try Harness()
  try await h.engine.sync()
  let key = try await h.engine.create("Thing", ["n": 1])
  h.server.enqueue(.methodError(method: "Thing/set", MethodError(type: MethodError.serverFail)))
  await #expect(throws: SyncError.self) { try await h.engine.sync() }
  let entries = try await h.pending()
  #expect(entries.map(\.key) == [key])
  #expect(entries[0].claimedBy == nil)
  #expect(try await h.engine.currentStatus().lastFailure == "Thing/set: serverFail")
  try await h.engine.sync()
  #expect(try await h.engine.object(key: key)?.id != nil)
}

@Test func tooLargeSetShrinksTheBatch() async throws {
  let h = try Harness()
  try await h.engine.sync()
  for n in 1...4 { _ = try await h.engine.create("Thing", ["n": .number(Double(n))]) }
  h.server.enqueue(.methodError(method: "Thing/set", MethodError(type: MethodError.requestTooLarge)))
  await #expect(throws: SyncError.self) { try await h.engine.sync() }
  h.server.clearRequests()
  try await h.engine.sync()
  let sets = h.server.calls(named: "Thing/set")
  #expect(sets.count == 2)
  #expect(sets.allSatisfy { $0.arguments["create"]?.objectValue?.count == 2 })
  #expect(h.server.objects("Thing").count == 4)
}

@Test func crossTypeCreationReferencesAreRefused() async throws {
  let h = try Harness(types: [playlistType, trackType])
  let track = try await h.engine.create("Track", ["title": "t"])
  await #expect(throws: SyncError.self) {
    try await h.engine.create("Playlist", ["trackIds": [.string("#" + track.creationId)]])
  }
}

@Test func writesToUnknownOrMissingObjectsThrow() async throws {
  let h = try Harness()
  await #expect(throws: SyncError.self) { try await h.engine.create("Nope", [:]) }
  await #expect(throws: SyncError.self) { try await h.engine.update(LocalKey(999), patch: [:]) }
  let id = h.server.create("Thing", [:])
  try await h.engine.sync()
  let key = try #require(try await h.engine.object(type: "Thing", id: id)).key
  try await h.engine.destroy(key)
  await #expect(throws: SyncError.self) { try await h.engine.update(key, patch: ["n": 1]) }
}

@Test func twoProcessesPushWithoutSendingTwice() async throws {
  let h = try Harness(processId: "app")
  try await h.engine.sync()
  let cli = try h.anotherProcess("cli")
  _ = try await h.engine.create("Thing", ["from": "app"])
  _ = try await cli.create("Thing", ["from": "cli"])
  h.server.clearRequests()
  try await cli.sync()
  try await h.engine.sync()
  #expect(h.server.objects("Thing").count == 2)
  #expect(h.server.calls(named: "Thing/set").count == 1, "the first pusher took both entries")
  #expect(try await h.pending() == [])
}
