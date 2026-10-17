import Foundation
import Testing
import JinxJSON
@testable import JinxWire

@Test func parsesTheRFCSession() throws {
  let session = try Session(json: json(rfcSessionText), base: sessionBase)
  #expect(session.username == "john@example.com")
  #expect(session.state == "75128aab4b1b")
  #expect(session.apiUrl == URL(string: "https://jmap.example.com/jmap/api/"))
  #expect(session.primaryAccountId(for: "urn:ietf:params:jmap:mail") == "A13824")
  #expect(session.primaryAccountId(for: "urn:ietf:params:jmap:tasks") == nil)
  #expect(session.accounts.count == 2)
  #expect(session.accounts["A97813"]?.isReadOnly == true)
  #expect(session.accounts["A13824"]?.accountCapabilities["urn:ietf:params:jmap:mail"]?["maxMailboxDepth"] == 10)

  let core = try #require(session.core)
  #expect(core.maxObjectsInGet == 256)
  #expect(core.maxObjectsInSet == 128)
  #expect(core.maxCallsInRequest == 32)
  #expect(core.collationAlgorithms.count == 3)
}

@Test func expandsSessionTemplates() throws {
  let session = try Session(json: json(rfcSessionText), base: sessionBase)
  #expect(
    session.downloadUrl.expand(["accountId": "A1", "blobId": "b/2", "name": "a b.txt", "type": "text/plain"])
      == URL(string: "https://jmap.example.com/download/A1/b%2F2/a%20b.txt?accept=text%2Fplain")
  )
  #expect(session.uploadUrl.expand(["accountId": "A1"]) == URL(string: "https://jmap.example.com/jmap/upload/A1/"))
  #expect(
    session.eventSourceUrl.expand(["types": "*", "closeafter": "no", "ping": "30"])
      == URL(string: "https://jmap.example.com/jmap/eventsource/?types=%2A&closeafter=no&ping=30")
  )
}

private func assertSessionRejected(
  _ text: String,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  #expect(throws: JMAPError.self, sourceLocation: sourceLocation) {
    try Session(json: json(text), base: sessionBase)
  }
}

@Test func rejectsSessionsMissingEssentials() {
  assertSessionRejected("{}")
  assertSessionRejected("{\"capabilities\":{},\"accounts\":{}}")
  assertSessionRejected("{\"capabilities\":{},\"accounts\":{\"a\":{}},\"apiUrl\":\"/x\",\"downloadUrl\":\"\",\"uploadUrl\":\"\",\"eventSourceUrl\":\"\"}")
}

@Test func missingCoreCapabilityIsNil() throws {
  let session = try Session(
    json: json("{\"capabilities\":{},\"accounts\":{},\"apiUrl\":\"/a\",\"downloadUrl\":\"\",\"uploadUrl\":\"\",\"eventSourceUrl\":\"\"}"),
    base: sessionBase
  )
  #expect(session.core == nil)
}

private func assertTemplate(
  _ template: String,
  variables: [String],
  with values: [String: String],
  expands expected: String?,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  let t = URLTemplate(template)
  #expect(t.variables == variables, sourceLocation: sourceLocation)
  #expect(t.expand(values)?.absoluteString == expected, sourceLocation: sourceLocation)
}

@Test func templateEdgeCases() {
  assertTemplate("https://x/plain", variables: [], with: [:], expands: "https://x/plain")
  assertTemplate("https://x/{a}/{b}", variables: ["a", "b"], with: ["a": "1"], expands: "https://x/1/")
  assertTemplate("https://x/{a}{a}", variables: ["a", "a"], with: ["a": "~"], expands: "https://x/~~")
  assertTemplate("https://x/{unclosed", variables: [], with: [:], expands: nil)
}
