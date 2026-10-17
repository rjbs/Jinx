import Testing
import JinxJSON
@testable import JinxPatch

private func assertApply(
  _ patch: PatchObject,
  to object: JSONValue,
  gives expected: JSONValue,
  sourceLocation: SourceLocation = #_sourceLocation
) throws {
  #expect(try object.applying(patch) == expected, sourceLocation: sourceLocation)
}

private func assertApply(
  _ patch: PatchObject,
  to object: JSONValue,
  throws expected: PatchError,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  #expect(throws: expected, sourceLocation: sourceLocation) { try object.applying(patch) }
}

@Test func applySetsRemovesAndCreates() throws {
  try assertApply(["a": 2], to: ["a": 1], gives: ["a": 2])
  try assertApply(["a": .null], to: ["a": 1, "b": 2], gives: ["b": 2])
  try assertApply(["a": .null], to: ["b": 2], gives: ["b": 2])
  try assertApply(["m/k": true], to: [:], gives: ["m": ["k": true]])
  try assertApply(["m/k": .null, "m/j": 1], to: ["m": ["k": 1]], gives: ["m": ["j": 1]])
  try assertApply([:], to: ["a": 1], gives: ["a": 1])
}

@Test func applyRejectsInvalidPatches() {
  assertApply(["": ["x": 1]], to: [:], throws: .emptyPath)
  assertApply(["a": ["x": 1], "a/b": 2], to: [:], throws: .overlappingPaths(JSONPointer("a"), JSONPointer("a", "b")))
  assertApply(["list/0": 1], to: ["list": [9]], throws: .pointer(.pathThroughArray(JSONPointer("0"))))
  assertApply(["n/x": 1], to: ["n": 1], throws: .pointer(.pathThroughScalar(JSONPointer("x"))))
  assertApply(["a": 1], to: [1, 2], throws: .notAnObject)
}

@Test func siblingPathsAreNotOverlapping() throws {
  try assertApply(["ab": 1, "a": 2], to: [:], gives: ["ab": 1, "a": 2])
}

@Test func patchObjectCodesAsItsWireShape() throws {
  let patch: PatchObject = ["keywords/$seen": true, "mailboxIds/old": .null]
  let text = try JSONValue.object(patch.entries).serializedString()
  #expect(text == "{\"keywords/$seen\":true,\"mailboxIds/old\":null}")
  let decoded = try JSONDecoder().decode(PatchObject.self, from: Data(text.utf8))
  #expect(decoded == patch)
}

import Foundation
