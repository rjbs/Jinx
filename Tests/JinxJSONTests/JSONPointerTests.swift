import Testing
@testable import JinxJSON

private func assertPointer(
  patchPath: String,
  tokens: [String],
  rfc6901: String,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  let fromPatch = JSONPointer(jmapPatchPath: patchPath)
  #expect(fromPatch.tokens == tokens, sourceLocation: sourceLocation)
  #expect(fromPatch.jmapPatchPath == patchPath, sourceLocation: sourceLocation)
  #expect(fromPatch.rfc6901 == rfc6901, sourceLocation: sourceLocation)
  #expect(JSONPointer(rfc6901: rfc6901) == fromPatch, sourceLocation: sourceLocation)
  #expect(JSONPointer(tokens: tokens) == fromPatch, sourceLocation: sourceLocation)
}

@Test func pointerFormsAgree() {
  assertPointer(patchPath: "", tokens: [], rfc6901: "")
  assertPointer(patchPath: "title", tokens: ["title"], rfc6901: "/title")
  assertPointer(patchPath: "keywords/$seen", tokens: ["keywords", "$seen"], rfc6901: "/keywords/$seen")
  assertPointer(patchPath: "a~1b/c~0d", tokens: ["a/b", "c~d"], rfc6901: "/a~1b/c~0d")
  assertPointer(patchPath: "x//y", tokens: ["x", "", "y"], rfc6901: "/x//y")
}

@Test func unescapeOrderMatchesTheRFC() {
  #expect(JSONPointer.unescape("~01") == "~1")
  #expect(JSONPointer.escape("~1") == "~01")
}

@Test func prefixes() {
  let a = JSONPointer("a")
  #expect(a.isPrefix(of: JSONPointer("a", "b")))
  #expect(a.isPrefix(of: a))
  #expect(!a.isPrefix(of: JSONPointer("ab")))
  #expect(JSONPointer().isPrefix(of: a))
}

private func assertLookup(
  _ value: JSONValue,
  at path: String,
  is expected: JSONValue?,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  #expect(value.value(at: JSONPointer(jmapPatchPath: path)) == expected, sourceLocation: sourceLocation)
}

@Test func lookupWalksObjectsAndArrays() {
  let doc: JSONValue = ["a": ["b": [10, ["c": true]]], "n": 1]
  assertLookup(doc, at: "", is: doc)
  assertLookup(doc, at: "n", is: 1)
  assertLookup(doc, at: "a/b/0", is: 10)
  assertLookup(doc, at: "a/b/1/c", is: true)
  assertLookup(doc, at: "a/b/2", is: nil)
  assertLookup(doc, at: "a/b/x", is: nil)
  assertLookup(doc, at: "n/deeper", is: nil)
  assertLookup(doc, at: "missing", is: nil)
}

private func assertSetting(
  _ value: JSONValue,
  _ newValue: JSONValue?,
  at path: String,
  gives expected: JSONValue,
  sourceLocation: SourceLocation = #_sourceLocation
) throws {
  let result = try value.setting(newValue, at: JSONPointer(jmapPatchPath: path))
  #expect(result == expected, sourceLocation: sourceLocation)
}

@Test func settingCreatesReplacesAndRemoves() throws {
  try assertSetting(["a": 1], 2, at: "a", gives: ["a": 2])
  try assertSetting(["a": 1], 2, at: "b", gives: ["a": 1, "b": 2])
  try assertSetting(["a": 1], nil, at: "a", gives: [:])
  try assertSetting(["a": 1], nil, at: "zzz", gives: ["a": 1])
  try assertSetting(["a": 1], true, at: "x/y/z", gives: ["a": 1, "x": ["y": ["z": true]]])
  try assertSetting(["k": ["a": 1, "b": 2]], nil, at: "k/a", gives: ["k": ["b": 2]])
  try assertSetting(["a": 1], ["whole": "new"], at: "", gives: ["whole": "new"])
}

@Test func settingRefusesArraysAndScalarsOnThePath() {
  #expect(throws: JSONValue.PointerError.pathThroughArray(JSONPointer("0", "x"))) {
    try JSONValue.object(["list": [1]]).setting(1, at: JSONPointer("list", "0", "x"))
  }
  #expect(throws: JSONValue.PointerError.pathThroughScalar(JSONPointer("x"))) {
    try JSONValue.object(["n": 1]).setting(1, at: JSONPointer("n", "x"))
  }
  #expect(throws: JSONValue.PointerError.cannotReplaceRootWithNothing) {
    try JSONValue.object([:]).setting(nil, at: JSONPointer())
  }
}
