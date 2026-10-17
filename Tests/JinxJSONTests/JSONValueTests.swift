import Foundation
import Testing
@testable import JinxJSON

private func assertRoundTrip(
  _ text: String,
  is expected: JSONValue,
  serializesAs canonical: String? = nil,
  sourceLocation: SourceLocation = #_sourceLocation
) throws {
  let parsed = try JSONValue(parsing: text)
  #expect(parsed == expected, sourceLocation: sourceLocation)
  #expect(try parsed.serializedString() == (canonical ?? text), sourceLocation: sourceLocation)
}

@Test func parsesAndSerializesEveryKind() throws {
  try assertRoundTrip("null", is: .null)
  try assertRoundTrip("true", is: true)
  try assertRoundTrip("false", is: false)
  try assertRoundTrip("42", is: 42)
  try assertRoundTrip("1.5", is: 1.5)
  try assertRoundTrip("-0.25", is: -0.25)
  try assertRoundTrip("\"hi\"", is: "hi")
  try assertRoundTrip("[1,\"a\",null]", is: [1, "a", nil])
  try assertRoundTrip("{\"b\":1,\"a\":[true]}", is: ["a": [true], "b": 1], serializesAs: "{\"a\":[true],\"b\":1}")
  try assertRoundTrip("\"a/b\"", is: "a/b")
}

@Test func rejectsMalformedText() {
  #expect(throws: (any Error).self) { try JSONValue(parsing: "{") }
}

private func assertAccessors(
  _ value: JSONValue,
  bool: Bool? = nil,
  double: Double? = nil,
  int: Int? = nil,
  string: String? = nil,
  arrayCount: Int? = nil,
  objectCount: Int? = nil,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  #expect(value.boolValue == bool, sourceLocation: sourceLocation)
  #expect(value.doubleValue == double, sourceLocation: sourceLocation)
  #expect(value.intValue == int, sourceLocation: sourceLocation)
  #expect(value.stringValue == string, sourceLocation: sourceLocation)
  #expect(value.arrayValue?.count == arrayCount, sourceLocation: sourceLocation)
  #expect(value.objectValue?.count == objectCount, sourceLocation: sourceLocation)
}

@Test func accessorsReturnOnlyTheirOwnKind() {
  assertAccessors(.null)
  assertAccessors(true, bool: true)
  assertAccessors(3, double: 3, int: 3)
  assertAccessors(3.5, double: 3.5)
  assertAccessors(1e300, double: 1e300)
  assertAccessors("s", string: "s")
  assertAccessors([1, 2], arrayCount: 2)
  assertAccessors(["k": 1], objectCount: 1)
}

@Test func subscriptsReadAndWriteMembers() {
  var object: JSONValue = ["a": 1, "b": [10, 20]]
  #expect(object["a"] == 1)
  #expect(object["zzz"] == nil)
  #expect(object["b"]?[1] == 20)
  #expect(object["b"]?[2] == nil)
  #expect(object["a"]?["x"] == nil)

  object["c"] = "new"
  object["a"] = nil
  #expect(object == ["b": [10, 20], "c": "new"])

  var scalar: JSONValue = 5
  scalar["k"] = 1
  #expect(scalar == 5)
}

@Test func codableThroughOtherTypes() throws {
  struct Envelope: Codable, Equatable {
    var payload: JSONValue
  }
  let envelope = Envelope(payload: ["n": [1, nil, "x"]])
  let data = try JSONEncoder().encode(envelope)
  #expect(try JSONDecoder().decode(Envelope.self, from: data) == envelope)
}
