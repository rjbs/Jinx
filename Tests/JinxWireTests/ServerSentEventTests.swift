import Testing
import JinxJSON
@testable import JinxWire

private func parse(_ text: String) -> [ServerSentEvent] {
  var parser = ServerSentEventParser()
  var events: [ServerSentEvent] = []
  for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
    if let event = parser.feed(line: String(line)) {
      events.append(event)
    }
  }
  return events
}

@Test func parsesEventsFieldsAndComments() {
  let events = parse("""
  : a comment
  event: state
  data: {"@type":"StateChange"}
  id: 7
  retry: 5000

  data:one
  data: two

  event: ping
  data: {"interval": 30}

  """)
  #expect(events == [
    ServerSentEvent(event: "state", data: "{\"@type\":\"StateChange\"}", id: "7", retry: .milliseconds(5000)),
    ServerSentEvent(data: "one\ntwo"),
    ServerSentEvent(event: "ping", data: "{\"interval\": 30}"),
  ])
}

@Test func blankLinesWithoutDataYieldNothing() {
  #expect(parse("\n\n\nevent: state\n\n").isEmpty)
}

@Test func retryAloneIsReported() {
  #expect(parse("retry: 250\n\n") == [ServerSentEvent(data: "", retry: .milliseconds(250))])
  #expect(parse("retry: soon\n\n").isEmpty)
}

@Test func fieldWithoutColonIsItsOwnName() {
  #expect(parse("data\n\n") == [ServerSentEvent(data: "")])
}

@Test func stateChangeParses() throws {
  let change = try StateChange(json: json("""
  {"@type": "StateChange", "changed": {"a1": {"Email": "s1", "Mailbox": "s2"}, "a2": {"Task": "t"}}}
  """))
  #expect(change.changed == ["a1": ["Email": "s1", "Mailbox": "s2"], "a2": ["Task": "t"]])
  #expect(throws: JMAPError.self) { try StateChange(json: json("{\"changed\": {}}")) }
}

private func split(_ text: String) -> [String] {
  var splitter = LineSplitter()
  return Array(text.utf8).compactMap { splitter.feed($0) }
}

@Test func lineSplitterHonorsEveryTerminatorAndEmptyLines() {
  #expect(split("a\nb\n\n") == ["a", "b", ""])
  #expect(split("a\r\nb\r\n\r\n") == ["a", "b", ""])
  #expect(split("a\rb\r\r") == ["a", "b", ""])
  #expect(split("a\r\n\nb") == ["a", ""])
  #expect(split("unterminated") == [])
  #expect(split("é\n") == ["é"])
}
