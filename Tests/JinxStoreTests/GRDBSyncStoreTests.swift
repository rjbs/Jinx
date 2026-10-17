import Foundation
import Testing
import JinxJSON
import JinxWire
@testable import JinxStore

private let account = "acct"

private func makeStore() throws -> GRDBSyncStore {
  try GRDBSyncStore.inMemory()
}

@discardableResult
private func insert(
  _ store: GRDBSyncStore,
  type: String = "Thing",
  id: String? = nil,
  snapshot: JSONValue? = nil,
  local: JSONValue
) async throws -> StoredObject {
  try await store.write { tx in
    try tx.insert(NewObject(accountId: account, type: type, id: id, snapshot: snapshot, local: local))
  }
}

@Test func insertAssignsIncreasingKeysAndRoundTrips() async throws {
  let store = try makeStore()
  let a = try await insert(store, id: "a", snapshot: ["t": 1], local: ["t": 1])
  let b = try await insert(store, local: ["t": 2])
  #expect(a.key.rawValue < b.key.rawValue)
  #expect(a.key.creationId == "jinx\(a.key.rawValue)")
  #expect(LocalKey(creationId: a.key.creationId) == a.key)
  #expect(LocalKey(creationId: "nope") == nil)

  let fetched = try await store.read { tx in try tx.object(key: a.key) }
  #expect(fetched == a)
  #expect(try await store.read { tx in try tx.object(accountId: account, type: "Thing", id: "a") } == a)
  #expect(try await store.read { tx in try tx.object(key: b.key) }?.snapshot == nil)
  #expect(try await store.read { tx in try tx.objects(accountId: account, type: "Thing") } == [a, b])
  #expect(try await store.read { tx in try tx.objects(keys: [b.key, a.key]) } == [a, b])
  #expect(try await store.read { tx in try tx.objects(accountId: account, type: "Thing", ids: ["a", "zz"]) } == [a])
  #expect(try await store.read { tx in try tx.count(accountId: account, type: "Thing") } == 2)
  #expect(try await store.read { tx in try tx.count(accountId: account, type: "Other") } == 0)
}

@Test func updateStoresEveryMutableColumn() async throws {
  let store = try makeStore()
  var object = try await insert(store, local: ["t": 1])
  object.id = "assigned"
  object.snapshot = ["t": 1, "server": true]
  object.local = ["t": 2]
  object.lastError = SetError(type: SetError.invalidProperties, properties: ["t"], extra: ["n": 1])
  let expected = object
  try await store.write { tx in try tx.update(expected) }
  #expect(try await store.read { tx in try tx.object(key: expected.key) } == expected)
}

@Test func duplicateIdsAreRejectedButNilIdsAreNot() async throws {
  let store = try makeStore()
  try await insert(store, id: "dup", local: [:])
  try await insert(store, local: [:])
  try await insert(store, local: [:])
  await #expect(throws: (any Error).self) {
    try await insert(store, id: "dup", local: [:])
  }
}

@Test func deleteRemovesObjectAndItsPendingEntry() async throws {
  let store = try makeStore()
  let object = try await insert(store, local: [:])
  try await store.write { tx in _ = try tx.setPending(key: object.key, operation: .create) }
  try await store.write { tx in try tx.delete(key: object.key) }
  #expect(try await store.read { tx in try tx.object(key: object.key) } == nil)
  #expect(try await store.read { tx in try tx.pendingEntries(accountId: account) } == [])
}

@Test func lookupByPropertyFindsClientIdentity() async throws {
  let store = try makeStore()
  let object = try await insert(store, local: ["uid": "u-1", "n": 5])
  try await insert(store, local: ["uid": "u-2"])
  #expect(try await store.read { tx in try tx.object(accountId: account, type: "Thing", property: "uid", equals: "u-1") } == object)
  #expect(try await store.read { tx in try tx.object(accountId: account, type: "Thing", property: "n", equals: 5) } == object)
  #expect(try await store.read { tx in try tx.object(accountId: account, type: "Thing", property: "uid", equals: "u-9") } == nil)
  #expect(try await store.read { tx in try tx.object(accountId: account, type: "Thing", property: "uid", equals: .null) } == nil)
}

@Test func pendingLogReplacesAndOrders() async throws {
  let store = try makeStore()
  let a = try await insert(store, local: [:])
  let b = try await insert(store, local: [:])
  try await store.write { tx in
    try tx.setPending(key: a.key, operation: .create)
    try tx.setPending(key: b.key, operation: .update)
    try tx.setPending(key: a.key, operation: .update)
  }
  let entries = try await store.read { tx in try tx.pendingEntries(accountId: account) }
  #expect(entries.map(\.key) == [b.key, a.key])
  #expect(entries.map(\.operation) == [.update, .update])
  #expect(try await store.read { tx in try tx.object(key: a.key) }?.pending == .update)
  #expect(try await store.read { tx in try tx.pending(key: a.key) }?.operation == .update)

  try await store.write { tx in try tx.clearPending(key: a.key) }
  #expect(try await store.read { tx in try tx.pending(key: a.key) } == nil)
  #expect(try await store.read { tx in try tx.object(key: a.key) }?.pending == nil)

  await #expect(throws: StoreError.noSuchObject(LocalKey(999))) {
    try await store.write { tx in try tx.setPending(key: LocalKey(999), operation: .create) }
  }
}

@Test func claimsSkipFreshClaimsAndTakeStaleOnes() async throws {
  let store = try makeStore()
  let a = try await insert(store, local: [:])
  let b = try await insert(store, local: [:])
  try await store.write { tx in
    try tx.setPending(key: a.key, operation: .create)
    try tx.setPending(key: b.key, operation: .create)
  }
  let t0 = Date(timeIntervalSince1970: 1000)
  let first = try await store.write { tx in try tx.claimPending(accountId: account, processId: "p1", now: t0, staleAfter: 60) }
  #expect(first.map(\.key) == [a.key, b.key])
  #expect(first.allSatisfy { $0.claimedBy == "p1" && $0.claimedAt == t0 })

  let second = try await store.write { tx in try tx.claimPending(accountId: account, processId: "p2", now: t0 + 10, staleAfter: 60) }
  #expect(second.isEmpty, "fresh claims belong to p1")

  let third = try await store.write { tx in try tx.claimPending(accountId: account, processId: "p2", now: t0 + 61, staleAfter: 60) }
  #expect(third.map(\.key) == [a.key, b.key], "stale claims are taken over")

  try await store.write { tx in try tx.releaseClaims(processId: "p2") }
  let fourth = try await store.write { tx in try tx.claimPending(accountId: account, processId: "p1", now: t0 + 62, staleAfter: 60) }
  #expect(fourth.count == 2)
}

@Test func stateIsPerAccountAndType() async throws {
  let store = try makeStore()
  try await store.write { tx in
    try tx.setState("s1", accountId: account, type: "Thing")
    try tx.setState("s2", accountId: account, type: "Other")
    try tx.setState("s3", accountId: account, type: "Thing")
  }
  #expect(try await store.read { tx in try tx.state(accountId: account, type: "Thing") } == "s3")
  #expect(try await store.read { tx in try tx.state(accountId: account, type: "Other") } == "s2")
  #expect(try await store.read { tx in try tx.state(accountId: "elsewhere", type: "Thing") } == nil)
  try await store.write { tx in try tx.setState(nil, accountId: account, type: "Thing") }
  #expect(try await store.read { tx in try tx.state(accountId: account, type: "Thing") } == nil)
}

@Test func journalRoundTripsAndPages() async throws {
  let store = try makeStore()
  var first = ChangeSet(accountId: account, source: .pull)
  first.noteCreated(LocalKey(1), type: "Thing")
  first.noteIdAssigned("x", to: LocalKey(1), type: "Thing")
  first.failed[LocalKey(2)] = SetError(type: SetError.notFound)
  var second = ChangeSet(accountId: account, source: .local)
  second.noteDestroyed(LocalKey(3), type: "Thing")

  let seqs = try await store.write { [first, second] tx in
    [try tx.appendJournal(first), try tx.appendJournal(second)]
  }
  #expect(seqs == [1, 2])
  #expect(try await store.read { tx in try tx.latestJournalSeq() } == 2)
  #expect(try await store.read { tx in try tx.journal(after: 0) } == [JournalEntry(seq: 1, changeSet: first), JournalEntry(seq: 2, changeSet: second)])
  #expect(try await store.read { tx in try tx.journal(after: 1) }.map(\.seq) == [2])
}

@Test func wipeClearsOnlyTheAccount() async throws {
  let store = try makeStore()
  let mine = try await insert(store, local: [:])
  let theirs = try await store.write { tx in
    try tx.insert(NewObject(accountId: "other", type: "Thing", id: "o", snapshot: nil, local: [:]))
  }
  try await store.write { tx in
    try tx.setPending(key: mine.key, operation: .create)
    try tx.setState("s", accountId: account, type: "Thing")
    try tx.setState("s", accountId: "other", type: "Thing")
    try tx.appendJournal(ChangeSet(accountId: account, source: .local))
    try tx.wipe(accountId: account)
  }
  #expect(try await store.read { tx in try tx.object(key: mine.key) } == nil)
  #expect(try await store.read { tx in try tx.object(key: theirs.key) } == theirs)
  #expect(try await store.read { tx in try tx.state(accountId: account, type: "Thing") } == nil)
  #expect(try await store.read { tx in try tx.state(accountId: "other", type: "Thing") } == "s")
  #expect(try await store.read { tx in try tx.journal(after: 0) } == [])
}

@Test func twoStoresOnOneFileSeeEachOther() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jinx-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let path = directory.appendingPathComponent("store.sqlite").path

  let app = try GRDBSyncStore(path: path)
  let cli = try GRDBSyncStore(path: path)
  let object = try await insert(app, id: "shared", local: ["from": "app"])
  try await cli.write { tx in
    var updated = try #require(try tx.object(key: object.key))
    updated.local = ["from": "cli"]
    try tx.update(updated)
    try tx.setPending(key: updated.key, operation: .update)
  }
  let seen = try await app.read { tx in try tx.object(key: object.key) }
  #expect(seen?.local == ["from": "cli"])
  #expect(seen?.pending == .update)
}
