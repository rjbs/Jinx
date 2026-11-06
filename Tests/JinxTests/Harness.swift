import Foundation
import Testing
import JinxJSON
import JinxPatch
import JinxStore
import JinxWire
import JinxScriptedServer
@testable import Jinx

let thingType = TypeDescriptor(name: "Thing", capability: "urn:test:things")
let taskType = TypeDescriptor(
  name: "Task",
  capability: "urn:test:tasks",
  ownedProperties: ["title", "progress", "keywords"],
  clientIdentity: .init(property: "uid")
)
let trackType = TypeDescriptor(name: "Track", capability: "urn:test:music")
let playlistType = TypeDescriptor(name: "Playlist", capability: "urn:test:music", syncAfter: ["Track"])

struct Harness {
  let server: ScriptedServer
  let store: GRDBSyncStore
  let engine: SyncEngine<GRDBSyncStore>
  let tap: WireTapToken?

  init(types: [TypeDescriptor] = [thingType], limits: ScriptedServer.Limits = .init(), fetchChunk: Int? = nil, processId: String = "test", recorder: TransportRecorder? = nil) throws {
    server = ScriptedServer(capabilities: types.map(\.capability), limits: limits)
    store = try GRDBSyncStore.inMemory()
    engine = try SyncEngine(
      configuration: SyncConfiguration(accountId: "acct", types: types, processId: processId, fetchChunk: fetchChunk),
      transport: server,
      store: store
    )
    tap = recorder.map(engine.addWireTap)
  }

  /// A second engine on the same store, as another process would have.
  func anotherProcess(_ processId: String) throws -> SyncEngine<GRDBSyncStore> {
    try SyncEngine(
      configuration: SyncConfiguration(accountId: "acct", types: engine.configuration.types, processId: processId),
      transport: server,
      store: store
    )
  }

  func journal() async throws -> [ChangeSet] {
    try await store.read { tx in try tx.journal(after: 0).map(\.changeSet) }
  }

  func stored(_ key: LocalKey) async throws -> StoredObject? {
    try await store.read { tx in try tx.object(key: key) }
  }

  func pending() async throws -> [PendingEntry] {
    try await store.read { tx in try tx.pendingEntries(accountId: "acct") }
  }

  /// Objects of a type as the app sees them, keyed by JMAP id.
  func localById(_ type: String) async throws -> [String: JSONValue] {
    var result: [String: JSONValue] = [:]
    for object in try await engine.objects(type: type) {
      if let id = object.id { result[id] = object.value }
    }
    return result
  }
}

/// The names of every method call sent so far, in order.
func methodNames(_ server: ScriptedServer) -> [String] {
  server.requests.flatMap(\.methodCalls).map(\.name)
}
