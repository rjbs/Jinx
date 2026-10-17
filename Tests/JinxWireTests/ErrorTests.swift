import Testing
import JinxJSON
@testable import JinxWire

private func assertRequestError(
  _ text: String,
  kind: RequestError.Kind,
  status: Int? = nil,
  limit: String? = nil,
  sourceLocation: SourceLocation = #_sourceLocation
) throws {
  let error = try RequestError(problemDetails: json(text))
  #expect(error.kind == kind, sourceLocation: sourceLocation)
  #expect(error.status == status, sourceLocation: sourceLocation)
  #expect(error.limit == limit, sourceLocation: sourceLocation)
}

@Test func requestErrorsClassify() throws {
  try assertRequestError("{\"type\":\"urn:ietf:params:jmap:error:limit\",\"status\":400,\"limit\":\"maxSizeRequest\"}", kind: .limit, status: 400, limit: "maxSizeRequest")
  try assertRequestError("{\"type\":\"urn:ietf:params:jmap:error:notJSON\"}", kind: .notJSON)
  try assertRequestError("{\"type\":\"urn:ietf:params:jmap:error:notRequest\"}", kind: .notRequest)
  try assertRequestError("{\"type\":\"urn:ietf:params:jmap:error:unknownCapability\"}", kind: .unknownCapability)
  try assertRequestError("{\"type\":\"about:blank\",\"status\":500}", kind: .other, status: 500)
  #expect(throws: JMAPError.self) { try RequestError(problemDetails: json("{\"status\":500}")) }
}

@Test func methodErrorJSONRoundTrips() throws {
  let error = MethodError(type: MethodError.cannotCalculateChanges, description: "too old", extra: ["x": 1])
  #expect(try MethodError(json: error.json) == error)
  #expect(error.json == ["type": "cannotCalculateChanges", "description": "too old", "x": 1])
}

@Test func setErrorKeepsUnknownMembers() throws {
  let error = try SetError(json: json("{\"type\":\"tooLarge\",\"maxSize\":100}"))
  #expect(error.type == SetError.tooLarge)
  #expect(error.extra == ["maxSize": 100])
  #expect(throws: JMAPError.self) { try SetError(json: json("{\"description\":\"no type\"}")) }
}
