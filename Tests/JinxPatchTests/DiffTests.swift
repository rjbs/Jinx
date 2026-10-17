import Testing
import JinxJSON
@testable import JinxPatch

private func assertDiff(
  from old: JSONValue,
  to new: JSONValue,
  is expected: PatchObject,
  vetoing vetoed: Set<String> = [],
  sourceLocation: SourceLocation = #_sourceLocation
) throws {
  let patch = try PatchObject.diff(from: old, to: new) { !vetoed.contains($0.jmapPatchPath) }
  #expect(patch == expected, sourceLocation: sourceLocation)
  #expect(
    try old.applying(patch).isJMAPEquivalent(to: new),
    "applying the diff must reproduce the target",
    sourceLocation: sourceLocation
  )
}

@Test func scalarsAndAdditionsAndRemovals() throws {
  try assertDiff(from: [:], to: [:], is: [:])
  try assertDiff(from: ["a": 1], to: ["a": 1], is: [:])
  try assertDiff(from: ["a": 1], to: ["a": 2], is: ["a": 2])
  try assertDiff(from: ["a": 1], to: ["a": 1, "b": "x"], is: ["b": "x"])
  try assertDiff(from: ["a": 1, "b": "x"], to: ["a": 1], is: ["b": .null])
  try assertDiff(from: ["a": 1], to: ["a": "1"], is: ["a": "1"])
}

@Test func nullAndAbsentAreTheSame() throws {
  try assertDiff(from: ["a": .null], to: [:], is: [:])
  try assertDiff(from: [:], to: ["a": .null], is: [:])
  try assertDiff(from: ["a": 1], to: ["a": .null], is: ["a": .null])
}

@Test func mapsPatchPerEntry() throws {
  try assertDiff(
    from: ["keywords": ["nerfjournal:category:Work": true, "$flagged": true]],
    to: ["keywords": ["nerfjournal:category:Home": true, "$flagged": true]],
    is: ["keywords/nerfjournal:category:Work": .null, "keywords/nerfjournal:category:Home": true]
  )
  try assertDiff(
    from: ["links": ["ext": ["href": "a", "rel": "related"]]],
    to: ["links": ["ext": ["href": "b", "rel": "related"]]],
    is: ["links/ext/href": "b"]
  )
  try assertDiff(from: ["m": [:]], to: ["m": ["k": 1]], is: ["m/k": 1])
  try assertDiff(from: [:], to: ["m": ["k": 1]], is: ["m": ["k": 1]])
  try assertDiff(from: ["m": ["k": 1]], to: [:], is: ["m": .null])
}

@Test func arraysAreReplacedWhole() throws {
  try assertDiff(from: ["ids": ["a", "b"]], to: ["ids": ["a", "b", "c"]], is: ["ids": ["a", "b", "c"]])
  try assertDiff(from: ["ids": ["a"]], to: ["ids": ["a"]], is: [:])
}

@Test func vetoReplacesTheSubtree() throws {
  try assertDiff(
    from: ["recurrenceOverrides": ["2026-01-01T00:00:00": ["title": "a"]]],
    to: ["recurrenceOverrides": ["2026-01-01T00:00:00": ["title": "b"]]],
    is: ["recurrenceOverrides": ["2026-01-01T00:00:00": ["title": "b"]]],
    vetoing: ["recurrenceOverrides"]
  )
  try assertDiff(
    from: ["a": ["b": ["c": 1]]],
    to: ["a": ["b": ["c": 2]]],
    is: ["a/b": ["c": 2]],
    vetoing: ["a/b"]
  )
}

@Test func keysNeedingEscapesRoundTrip() throws {
  try assertDiff(from: ["a/b": ["x~y": 1]], to: ["a/b": ["x~y": 2]], is: ["a~1b/x~0y": 2])
}

@Test func diffRefusesNonObjects() {
  #expect(throws: PatchError.notAnObject) { try PatchObject.diff(from: [1], to: [2]) }
  #expect(throws: PatchError.notAnObject) { try PatchObject.diff(from: ["a": 1], to: 5) }
}
