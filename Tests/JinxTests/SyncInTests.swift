import Foundation
import Testing
import JinxJSON
import JinxStore
import JinxWire
import JinxScriptedServer
@testable import Jinx

@Test func initialSyncFetchesEverythingAndSetsState() async throws {
  let h = try Harness()
  let a = h.server.create("Thing", ["n": 1])
  let b = h.server.create("Thing", ["n": 2])
  try await h.engine.sync()

  #expect(try await h.localById("Thing") == [a: ["id": .string(a), "n": 1], b: ["id": .string(b), "n": 2]])
  #expect(try await h.engine.state(of: "Thing") == h.server.state(of: "Thing"))
  #expect(methodNames(h.server) == ["Thing/get"])
  let journal = try await h.journal()
  #expect(journal.count == 1)
  #expect(journal[0].source == .syncIn)
  #expect(journal[0].types["Thing"]?.created.count == 2)
  let object = try #require(try await h.engine.object(type: "Thing", id: a))
  #expect(object.pending == nil)
  #expect(try await h.stored(object.key)?.snapshot == ["id": .string(a), "n": 1])
}

@Test func incrementalSyncInAppliesCreatesUpdatesAndDestroys() async throws {
  let h = try Harness()
  let a = h.server.create("Thing", ["n": 1])
  let b = h.server.create("Thing", ["n": 2])
  try await h.engine.sync()
  let keyA = try #require(try await h.engine.object(type: "Thing", id: a)).key
  let keyB = try #require(try await h.engine.object(type: "Thing", id: b)).key
  h.server.clearRequests()

  h.server.update("Thing", a) { $0["n"] = 10 }
  h.server.destroy("Thing", b)
  let c = h.server.create("Thing", ["n": 3])
  try await h.engine.sync()

  #expect(try await h.localById("Thing") == [a: ["id": .string(a), "n": 10], c: ["id": .string(c), "n": 3]])
  #expect(try await h.engine.object(key: keyB) == nil)
  #expect(methodNames(h.server) == ["Thing/changes", "Thing/get", "Thing/get"])
  let last = try #require(try await h.journal().last)
  #expect(last.types["Thing"]?.updated == [keyA])
  #expect(last.types["Thing"]?.destroyed == [keyB])
  #expect(last.types["Thing"]?.created.count == 1)

  h.server.clearRequests()
  try await h.engine.sync()
  #expect(methodNames(h.server) == ["Thing/changes", "Thing/get", "Thing/get"])
  let gets = h.server.resolvedCalls(named: "Thing/get")
  #expect(gets.allSatisfy { $0.arguments["ids"] == [] }, "nothing changed, so nothing was fetched")
}

@Test func pagedChangesLoopUntilDone() async throws {
  let h = try Harness(fetchChunk: 2)
  try await h.engine.sync()
  for n in 1...5 { h.server.create("Thing", ["n": .number(Double(n))]) }
  h.server.clearRequests()
  try await h.engine.sync()
  #expect(try await h.localById("Thing").count == 5)
  #expect(h.server.calls(named: "Thing/changes").count == 3)
}

@Test func initialSyncPagesWhenGetIsTooLarge() async throws {
  var limits = ScriptedServer.Limits()
  limits.maxObjectsInGet = 2
  let server = ScriptedServer(capabilities: ["urn:test:things"], limits: limits)
  for n in 1...5 { server.create("Thing", ["n": .number(Double(n))]) }
  let store = try GRDBSyncStore.inMemory()
  let engine = try SyncEngine(configuration: SyncConfiguration(accountId: "acct", types: [thingType]), transport: server, store: store)
  try await engine.sync()
  #expect(try await engine.objects(type: "Thing").count == 5)
  #expect(methodNames(server) == ["Thing/get", "Thing/query", "Thing/get", "Thing/query", "Thing/get", "Thing/query", "Thing/get"])
  #expect(try await engine.state(of: "Thing") == server.state(of: "Thing"))
  let journal = try await store.read { tx in try tx.journal(after: 0) }
  #expect(journal.count == 3, "one commit per page")
}

@Test func cannotCalculateChangesResyncsWithoutWiping() async throws {
  let h = try Harness()
  let a = h.server.create("Thing", ["n": 1])
  let b = h.server.create("Thing", ["n": 2])
  try await h.engine.sync()
  let keyB = try #require(try await h.engine.object(type: "Thing", id: b)).key

  let pendingKey = try await h.engine.create("Thing", ["n": 99])
  h.server.enqueue(.transportFailure)
  await #expect(throws: SyncError.self) { try await h.engine.sync() }

  h.server.destroy("Thing", b)
  h.server.update("Thing", a) { $0["n"] = 11 }
  h.server.enqueue(.methodError(method: "Thing/changes", MethodError(type: MethodError.cannotCalculateChanges)))
  h.server.clearRequests()
  try await h.engine.sync()

  let names = methodNames(h.server)
  #expect(names.contains("Thing/changes") && names.contains("Thing/get"))
  #expect(try await h.engine.object(key: keyB) == nil, "an object the server no longer has is removed")
  #expect(try await h.localById("Thing")[a]?["n"] == 11)
  let created = try #require(try await h.engine.object(key: pendingKey))
  #expect(created.id != nil, "the pending create was synced out, not wiped")
  #expect(h.server.objects("Thing").count == 2)
}

@Test func typesSyncInDependencyOrder() async throws {
  let h = try Harness(types: [playlistType, trackType])
  h.server.create("Track", ["title": "t"])
  h.server.create("Playlist", ["name": "p"])
  try await h.engine.sync()
  #expect(methodNames(h.server) == ["Track/get", "Playlist/get"])
  h.server.clearRequests()
  try await h.engine.sync()
  #expect(methodNames(h.server) == ["Track/changes", "Track/get", "Track/get", "Playlist/changes", "Playlist/get", "Playlist/get"])

  #expect(throws: SyncError.self) {
    try [TypeDescriptor(name: "A", capability: "c", syncAfter: ["B"]), TypeDescriptor(name: "B", capability: "c", syncAfter: ["A"])].inDependencyOrder()
  }
}

@Test func onlyRequestedPropertiesAreFetched() async throws {
  let narrow = TypeDescriptor(name: "Thing", capability: "urn:test:things", properties: ["n"])
  let h = try Harness(types: [narrow])
  let a = h.server.create("Thing", ["n": 1, "big": "x"])
  try await h.engine.sync()
  #expect(try await h.localById("Thing")[a] == ["id": .string(a), "n": 1])
}
