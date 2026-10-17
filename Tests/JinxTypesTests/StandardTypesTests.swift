import Foundation
import Testing
import Jinx
import JinxJSON
import JinxPatch
import JinxStore
import JinxWire
import JinxScriptedServer
@testable import JinxTypes

@Test func mailTypesOrderResolves() throws {
  let ordered = try MailTypes.all.inDependencyOrder().map(\.name)
  #expect(ordered == ["Mailbox", "Thread", "Email", "Identity", "EmailSubmission"])
  #expect(try TaskTypes.all.inDependencyOrder().map(\.name) == ["TaskList", "Task"])
}

@Test func emailGetArgumentsCarryBodyOptions() {
  let email = MailTypes.email(bodyProperties: ["partId", "type"], fetchHTMLBodyValues: true, maxBodyValueBytes: 100_000)
  let args = email.getArguments(accountId: "a", ids: ["e1"])
  #expect(args["ids"] == ["e1"])
  #expect(args["properties"] == .array(MailTypes.emailSummaryProperties.map(JSONValue.string)))
  #expect(args["bodyProperties"] == ["partId", "type"])
  #expect(args["fetchHTMLBodyValues"] == true)
  #expect(args["fetchTextBodyValues"] == nil)
  #expect(args["maxBodyValueBytes"] == 100000)

  let plain = MailTypes.email(properties: nil).getArguments(accountId: "a", ids: nil)
  #expect(plain == ["accountId": "a", "ids": .null])
}

private func assertTaskDiff(from old: JSONValue, to new: JSONValue, is expected: PatchObject, sourceLocation: SourceLocation = #_sourceLocation) throws {
  #expect(try PatchObject.diff(from: old, to: new, mayPatch: TaskTypes.jscalendarMayPatch) == expected, sourceLocation: sourceLocation)
}

@Test func taskVetoReplacesWholeOverridesButPatchesTheMap() throws {
  try assertTaskDiff(
    from: ["recurrenceOverrides": ["2026-01-01T00:00:00": ["title": "a"]]],
    to: ["recurrenceOverrides": ["2026-01-01T00:00:00": ["title": "b"]]],
    is: ["recurrenceOverrides/2026-01-01T00:00:00": ["title": "b"]]
  )
  try assertTaskDiff(
    from: ["recurrenceOverrides": ["2026-01-01T00:00:00": ["title": "a"]]],
    to: ["recurrenceOverrides": ["2026-01-01T00:00:00": ["title": "a"], "2026-01-02T00:00:00": ["excluded": true]]],
    is: ["recurrenceOverrides/2026-01-02T00:00:00": ["excluded": true]]
  )
  try assertTaskDiff(
    from: ["keywords": ["a": true]],
    to: ["keywords": ["a": true, "b": true]],
    is: ["keywords/b": true]
  )
}

/// A mail-shaped scenario end to end: mailbox and emails sync, a
/// keyword patch goes out as a `keywords/$seen` entry, and body options
/// reach the server's `/get`.
@Test func mailScenarioAgainstTheScriptedServer() async throws {
  let server = ScriptedServer(capabilities: [MailTypes.capability])
  let inbox = server.create("Mailbox", ["name": "Inbox", "role": "inbox", "totalEmails": 1])
  let email = server.create("Email", ["subject": "hi", "mailboxIds": [inbox: true], "keywords": [:], "threadId": "t1", "bodyValues": ["1": ["value": "big"]]])
  server.create("Thread", ["emailIds": [.string(email)]])
  let types = [MailTypes.mailbox, MailTypes.thread, MailTypes.email(properties: ["subject", "mailboxIds", "keywords", "threadId"], fetchHTMLBodyValues: true)]
  let store = try GRDBSyncStore.inMemory()
  let engine = try SyncEngine(configuration: SyncConfiguration(accountId: "acct", types: types), transport: server, store: store)
  try await engine.sync()

  #expect(server.requests.flatMap(\.methodCalls).map(\.name) == ["Mailbox/get", "Thread/get", "Email/get"])
  let emailGet = try #require(server.calls(named: "Email/get").first)
  #expect(emailGet.arguments["fetchHTMLBodyValues"] == true)
  let local = try #require(try await engine.object(type: "Email", id: email))
  #expect(local.value == ["id": .string(email), "subject": "hi", "mailboxIds": [inbox: true], "keywords": [:], "threadId": "t1"])

  server.clearRequests()
  try await engine.update(local.key, patch: ["keywords/$seen": true])
  try await engine.sync()
  let set = try #require(server.calls(named: "Email/set").first)
  #expect(set.arguments["update"] == [email: ["keywords/$seen": true]])
  #expect(server.object("Email", email)?["keywords"] == ["$seen": true])

  // A replacement encoding that names an immutable property leaves it
  // alone, because only the owned properties are merged.
  server.clearRequests()
  try await engine.replace(local.key, with: ["subject": "changed", "keywords": ["$seen": true, "$flagged": true], "mailboxIds": [inbox: true]])
  try await engine.sync()
  let second = try #require(server.calls(named: "Email/set").first)
  #expect(second.arguments["update"] == [email: ["keywords/$flagged": true]])
  #expect(server.object("Email", email)?["subject"] == "hi")
}
