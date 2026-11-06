import Foundation
import Testing
import JinxJSON
import JinxStore
import JinxWire
import JinxScriptedServer
@testable import Jinx

/// Runs `actions` against a fresh harness with a recorder, then checks
/// the exchanges the recorder saw, as `purpose: title` lines.
private func assertTrace(
  types: [TypeDescriptor],
  _ actions: (Harness) async throws -> Void,
  _ expected: [String],
  sourceLocation: SourceLocation = #_sourceLocation
) async throws {
  let recorder = TransportRecorder()
  let h = try Harness(types: types, recorder: recorder)
  try await actions(h)
  let lines = recorder.exchanges.map { "\($0.purpose ?? "-"): \($0.title)" }
  #expect(lines == expected, sourceLocation: sourceLocation)
}

@Test func passStepsNameTheirRequests() async throws {
  try await assertTrace(types: [thingType], { h in
    h.server.create("Thing", ["n": 1])
    try await h.engine.sync()
    _ = try await h.engine.create("Thing", ["n": 2])
    try await h.engine.sync()
  }, [
    "sync-out › session: session",
    "sync-in › full fetch Thing: Thing/get",
    "sync-out › set Thing: Thing/set",
    "sync-in › changes: Thing/changes, Thing/get, Thing/get",
  ])
}

@Test func windowedStepsNameTheirRequests() async throws {
  try await assertTrace(types: [itemType, groupType], { h in
    let group = h.server.create("Group", ["name": "g"])
    for n in 1...3 { h.server.create("Item", ["n": .number(Double(n)), "groupId": .string(group)]) }
    try await h.engine.subscribe(QuerySubscription(
      id: "top", accountId: "acct", type: "Item", sort: [["property": "n"]], limit: 2
    ))
    try await h.engine.sync()
  }, [
    "sync-out › session: session",
    "sync-in › windowed › initial states: Item/get, Group/get",
    "sync-in › windowed › changes: Item/changes, Group/changes",
    "sync-in › windowed › refresh: Item/query",
    "sync-in › windowed › references: Item/get",
    "sync-in › windowed › references: Group/get",
  ])
}
