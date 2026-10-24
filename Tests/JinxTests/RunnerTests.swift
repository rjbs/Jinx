import Foundation
import Testing
import JinxJSON
import JinxStore
import JinxWire
import JinxScriptedServer
@testable import Jinx

/// The first change set matching `predicate`, or a thrown timeout.
func nextChange(
  _ stream: AsyncStream<ChangeSet>,
  timeout: Duration = .seconds(5),
  where predicate: @escaping @Sendable (ChangeSet) -> Bool
) async throws -> ChangeSet {
  try await withThrowingTaskGroup(of: ChangeSet?.self) { group in
    group.addTask {
      for await change in stream where predicate(change) { return change }
      return nil
    }
    group.addTask {
      try await Task.sleep(for: timeout)
      return nil
    }
    let first = try await group.next() ?? nil
    group.cancelAll()
    guard let first else { throw TimeoutError() }
    return first
  }
}

struct TimeoutError: Error {}

@Test func runLoopSyncsOnPushNotificationsAndLocalWrites() async throws {
  let h = try Harness()
  let changes = await h.engine.changes()
  let runner = Task { await h.engine.run(debounce: .milliseconds(10)) }
  defer { runner.cancel() }

  let id = h.server.create("Thing", ["n": 1])
  let syncedIn = try await nextChange(changes) { $0.source == .syncIn && $0.types["Thing"]?.created.isEmpty == false }
  #expect(syncedIn.types["Thing"]?.created.count == 1)
  #expect(try await h.engine.object(type: "Thing", id: id)?.value["n"] == 1)

  let key = try await h.engine.create("Thing", ["n": 2])
  let syncedOut = try await nextChange(changes) { $0.source == .syncOut && $0.types["Thing"]?.idsAssigned[key] != nil }
  #expect(h.server.object("Thing", syncedOut.types["Thing"]!.idsAssigned[key]!)?["n"] == 2)
  #expect(try await h.engine.currentStatus().isConnected)
}

@Test func runLoopRetriesWithBackoff() async throws {
  let h = try Harness()
  let changes = await h.engine.changes()
  let runner = Task { await h.engine.run(backoff: Backoff(initial: .milliseconds(5), maximum: .milliseconds(20)), debounce: .milliseconds(5)) }
  defer { runner.cancel() }
  h.server.enqueue(.transportFailure)
  h.server.enqueue(.transportFailure)
  let key = try await h.engine.create("Thing", ["n": 1])
  let syncedOut = try await nextChange(changes) { $0.source == .syncOut && $0.types["Thing"]?.idsAssigned[key] != nil }
  #expect(syncedOut.accountId == "acct")
  #expect(h.server.objects("Thing").count == 1)
}

@Test func anotherProcessSeesCommitsThroughTheJournal() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jinx-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let path = directory.appendingPathComponent("store.sqlite").path
  let signal = "org.rjbs.jinx.test.\(UUID().uuidString)"
  let server = ScriptedServer(capabilities: ["urn:test:things"])

  func makeEngine(_ processId: String) throws -> SyncEngine<GRDBSyncStore> {
    try SyncEngine(
      configuration: SyncConfiguration(accountId: "acct", types: [thingType], processId: processId, signalName: signal),
      transport: server,
      store: try GRDBSyncStore(path: path)
    )
  }
  let app = try makeEngine("app")
  let cli = try makeEngine("cli")
  let appChanges = await app.changes()
  let runner = Task { await app.run(debounce: .milliseconds(10)) }
  defer { runner.cancel() }
  try await app.tailJournal()

  let key = try await cli.create("Thing", ["from": "cli"])
  let seen = try await nextChange(appChanges) { $0.source == .local }
  #expect(seen.types["Thing"]?.created == [key])
  #expect(try await app.object(key: key)?.value["from"] == "cli")
}

@Test func tailingSkipsHistoryAndOwnCommits() async throws {
  let h = try Harness(processId: "me")
  _ = try await h.engine.create("Thing", ["before": true])
  let changes = await h.engine.changes()
  try await h.engine.tailJournal()
  let other = try h.anotherProcess("other")
  let theirs = try await other.create("Thing", ["theirs": true])
  _ = try await h.engine.create("Thing", ["mine": true])
  try await h.engine.tailJournal()
  let seen = try await nextChange(changes, timeout: .seconds(1)) { $0.types["Thing"]?.created == [theirs] }
  #expect(seen.source == .local)
}
