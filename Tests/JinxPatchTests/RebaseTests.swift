import Testing
import JinxJSON
@testable import JinxPatch

private func assertRebase(
  serverVersion: JSONValue,
  local: JSONValue,
  fetched: JSONValue,
  gives expected: JSONValue,
  redundant: Bool,
  sourceLocation: SourceLocation = #_sourceLocation
) throws {
  let rebase = try Rebase(serverVersion: serverVersion, local: local, fetched: fetched)
  #expect(rebase.local == expected, sourceLocation: sourceLocation)
  #expect(rebase.isRedundant == redundant, sourceLocation: sourceLocation)
}

@Test func pendingPropertyWinsOthersTakeTheServer() throws {
  try assertRebase(
    serverVersion: ["title": "a", "progress": "needs-action"],
    local: ["title": "a", "progress": "completed"],
    fetched: ["title": "renamed elsewhere", "progress": "needs-action"],
    gives: ["title": "renamed elsewhere", "progress": "completed"],
    redundant: false
  )
}

@Test func serverAlreadyHasTheChange() throws {
  try assertRebase(
    serverVersion: ["rating": 3],
    local: ["rating": 4],
    fetched: ["rating": 4, "playCount": 10],
    gives: ["rating": 4, "playCount": 10],
    redundant: true
  )
}

@Test func noPendingChangeIsRedundant() throws {
  try assertRebase(
    serverVersion: ["a": 1],
    local: ["a": 1],
    fetched: ["a": 2],
    gives: ["a": 2],
    redundant: true
  )
}

@Test func mapEntriesMergeAtPathGranularity() throws {
  try assertRebase(
    serverVersion: ["keywords": ["x": true]],
    local: ["keywords": ["x": true, "mine": true]],
    fetched: ["keywords": ["x": true, "theirs": true]],
    gives: ["keywords": ["x": true, "mine": true, "theirs": true]],
    redundant: false
  )
}

@Test func foreignPropertiesSurviveTheRebase() throws {
  try assertRebase(
    serverVersion: ["title": "a"],
    local: ["title": "b"],
    fetched: ["title": "a", "somebodyElses": ["deep": [1, 2]]],
    gives: ["title": "b", "somebodyElses": ["deep": [1, 2]]],
    redundant: false
  )
}

@Test func explicitNullFromTheServerIsStillRedundant() throws {
  try assertRebase(
    serverVersion: ["endedAt": "2026-01-01"],
    local: [:],
    fetched: ["endedAt": .null],
    gives: [:],
    redundant: true
  )
}
