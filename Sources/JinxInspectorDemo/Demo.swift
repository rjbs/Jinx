#if os(macOS)
import AppKit
import Foundation
import Jinx
import JinxInspector
import JinxJSON
import JinxScriptedServer
import JinxStore
import JinxWire
import SwiftUI

// A window onto the inspector, with an engine syncing against a scripted
// server that keeps changing underneath it.  Run with
// `swift run JinxInspectorDemo`.

let noteType = TypeDescriptor(name: "Note", capability: "urn:demo:notes")
let messageType = TypeDescriptor(
  name: "Message",
  capability: "urn:demo:mail",
  mode: .windowed,
  references: ["folderId": "Folder"],
  blobProperties: ["blobId"]
)
let folderType = TypeDescriptor(name: "Folder", capability: "urn:demo:mail", mode: .windowed)

final class Demo: Sendable {
  static let shared = try! Demo()

  let server: ScriptedServer
  let engine: SyncEngine<GRDBSyncStore>
  let blobDirectory: URL

  init() throws {
    let types = [noteType, messageType, folderType]
    server = ScriptedServer(capabilities: types.map(\.capability))
    engine = try SyncEngine(
      configuration: SyncConfiguration(accountId: "acct", types: types, processId: "demo"),
      transport: server,
      store: try GRDBSyncStore.inMemory()
    )
    blobDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("jinx-inspector-demo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: blobDirectory, withIntermediateDirectories: true)
  }

  func start() async {
    let inbox = server.create("Folder", ["name": "Inbox"])
    let archive = server.create("Folder", ["name": "Archive"])
    for n in 1...40 {
      let body = server.addBlob(Data("Message number \(n)\n".utf8), type: "text/plain")
      server.create("Message", [
        "subject": .string("Message \(n)"),
        "n": .number(Double(n)),
        "folderId": .string(n % 3 == 0 ? archive : inbox),
        "blobId": .string(body),
      ])
    }
    for n in 1...12 {
      server.create("Note", ["title": .string("Note \(n)"), "body": "…"])
    }

    try? await engine.subscribe(QuerySubscription(
      id: "inbox", accountId: "acct", type: "Message",
      filter: ["folderId": .string(inbox)],
      sort: [["property": "n", "isAscending": false]],
      limit: 10
    ))
    Task { await engine.run() }
    Task { await churn() }
  }

  /// Every couple of seconds, something changes: on the server, which
  /// pushes a state change, or locally, which the engine syncs out.
  private func churn() async {
    let blobs = await engine.makeBlobStore(.init(directory: blobDirectory))
    var tick = 0
    while !Task.isCancelled {
      try? await Task.sleep(for: .seconds(2))
      tick += 1
      switch tick % 4 {
      case 0:
        let body = server.addBlob(Data("A new arrival\n".utf8), type: "text/plain")
        let inbox = server.objects("Folder").first { $0.value["name"] == "Inbox" }!.key
        server.create("Message", [
          "subject": .string("New message \(tick)"),
          "n": .number(Double(100 + tick)),
          "folderId": .string(inbox),
          "blobId": .string(body),
        ])
        server.pushStateChange()
      case 1:
        if let note = server.objects("Note").keys.randomElement() {
          server.update("Note", note) { $0["body"] = .string("edited on the server at tick \(tick)") }
          server.pushStateChange()
        }
      case 2:
        if let note = try? await engine.objects(type: "Note").randomElement() {
          try? await engine.update(note.key, patch: ["title": .string("Edited locally at tick \(tick)")])
        }
      default:
        if let message = try? await engine.objects(in: "inbox").randomElement(),
           let blobId = message.value["blobId"]?.stringValue
        {
          _ = try? await blobs.download(blobId)
        }
      }
    }
  }
}

@main
struct JinxInspectorDemo: App {
  init() {
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.activate()
  }

  var body: some Scene {
    WindowGroup("Jinx Inspector") {
      JinxInspectorView(engine: Demo.shared.engine)
        .frame(minWidth: 700, minHeight: 600)
        .task { await Demo.shared.start() }
    }
  }
}
#else
// The demo is a macOS window; elsewhere it builds to nothing, so a build
// of every target for iOS still succeeds. -- claude, 2026-11-06
@main
enum JinxInspectorDemo {
  static func main() {}
}
#endif
