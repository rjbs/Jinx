import Testing
import JinxJSON
@testable import JinxPatch

private func assertMerge(
  owned: Set<String>,
  encoding: JSONValue,
  into current: JSONValue,
  gives expected: JSONValue,
  sourceLocation: SourceLocation = #_sourceLocation
) throws {
  #expect(try current.mergingOwnedProperties(owned, from: encoding) == expected, sourceLocation: sourceLocation)
}

@Test func mergeTouchesOnlyOwnedKeys() throws {
  try assertMerge(
    owned: ["title", "progress"],
    encoding: ["title": "new", "progress": "completed", "ignored": 1],
    into: ["title": "old", "foreign": true],
    gives: ["title": "new", "progress": "completed", "foreign": true]
  )
}

@Test func mergeRemovesOwnedKeysAbsentFromTheEncoding() throws {
  try assertMerge(
    owned: ["title", "endedAt"],
    encoding: ["title": "t"],
    into: ["title": "t", "endedAt": "2026-01-01", "foreign": true],
    gives: ["title": "t", "foreign": true]
  )
}

@Test func mergedResultDiffsOnlyOverOwnedKeys() throws {
  let snapshot: JSONValue = ["title": "old", "foreign": ["a": 1]]
  let encoding: JSONValue = ["title": "new"]
  let merged = try snapshot.mergingOwnedProperties(["title"], from: encoding)
  #expect(try PatchObject.diff(from: snapshot, to: merged) == ["title": "new"])
}

@Test func mergeRefusesNonObjects() {
  #expect(throws: PatchError.notAnObject) { try JSONValue.array([]).mergingOwnedProperties([], from: [:]) }
  #expect(throws: PatchError.notAnObject) { try JSONValue.object([:]).mergingOwnedProperties([], from: 1) }
}
