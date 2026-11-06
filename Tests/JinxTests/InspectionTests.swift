import Foundation
import Testing
import JinxJSON
import JinxPatch
import JinxStore
import JinxWire
import JinxScriptedServer
@testable import Jinx

private func assertInspected(
  _ object: InspectedObject?,
  pending: PendingOperation?,
  patch: PatchObject?,
  pinned: Bool = false,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  guard let object else {
    Issue.record("no such object", sourceLocation: sourceLocation)
    return
  }
  #expect(object.pendingEntry?.operation == pending, sourceLocation: sourceLocation)
  #expect(object.localPatch == patch, sourceLocation: sourceLocation)
  #expect(object.isPinned == pinned, sourceLocation: sourceLocation)
}

@Test func objectsShowTheirPendingStateAndLocalPatch() async throws {
  let h = try Harness()
  let synced = h.server.create("Thing", ["n": 1, "name": "a"])
  let edited = h.server.create("Thing", ["n": 1, "name": "b"])
  try await h.engine.sync()
  let editedKey = try #require(try await h.engine.object(type: "Thing", id: edited)?.key)
  try await h.engine.update(editedKey, patch: ["n": 2])
  let createdKey = try await h.engine.create("Thing", ["n": 3])

  let objects = try await h.engine.inspectObjects(type: "Thing")
  let byKey = Dictionary(uniqueKeysWithValues: objects.map { ($0.stored.key, $0) })
  assertInspected(objects.first { $0.stored.id == synced }, pending: nil, patch: PatchObject())
  assertInspected(byKey[editedKey], pending: .update, patch: ["n": 2])
  assertInspected(byKey[createdKey], pending: .create, patch: nil)
}

@Test func typesCountWhatTheStoreHolds() async throws {
  let h = try Harness(types: [itemType, groupType])
  let ids = (1...4).map { h.server.create("Item", ["n": .number(Double($0))]) }
  try await h.engine.subscribe(QuerySubscription(id: "two", accountId: "acct", type: "Item", sort: [["property": "n"]], limit: 2))
  try await h.engine.pin("Item", ids: [ids[3]])
  try await h.engine.sync()

  let types = try await h.engine.inspectTypes()
  #expect(types.map(\.name) == ["Item", "Group"])
  let item = try #require(types.first)
  #expect(item.mode == .windowed)
  #expect(item.serverState == h.server.state(of: "Item"))
  #expect(item.count == 3, "the window of two and the pinned one")
  #expect(item.pinnedCount == 1)
  #expect(item.pendingCount == 0)

  let subs = try await h.engine.inspectSubscriptions()
  #expect(subs.map(\.id) == ["two"])
  #expect(subs.first?.result?.ids == [ids[0], ids[1]])
  assertInspected(
    try await h.engine.inspectObjects(type: "Item").first { $0.stored.id == ids[3] },
    pending: nil, patch: PatchObject(), pinned: true
  )
}

@Test func journalShowsOnlyTheMostRecentEntries() async throws {
  let h = try Harness()
  for n in 1...5 { _ = try await h.engine.create("Thing", ["n": .number(Double(n))]) }
  let journal = try await h.engine.inspectJournal(limit: 2)
  #expect(journal.map(\.seq) == [4, 5])
  #expect(journal.allSatisfy { $0.changeSet.source == .local })
}
