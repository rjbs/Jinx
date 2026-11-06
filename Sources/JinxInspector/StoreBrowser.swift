import Jinx
import JinxJSON
import JinxStore
import SwiftUI

/// The store, as the engine sees it, reloaded after every commit.
@MainActor @Observable
final class StoreModel {
  let engine: any SyncInspecting
  var types: [InspectedType] = []
  var subscriptions: [InspectedSubscription] = []
  var pending: [PendingEntry] = []
  var blobs: [BlobRecord] = []
  var status: SyncStatus?
  var failure: String?
  /// Bumped on every commit, so that views showing a part of the store
  /// know to load it again.
  var generation = 0

  init(engine: any SyncInspecting) {
    self.engine = engine
  }

  func load() async {
    do {
      types = try await engine.inspectTypes()
      subscriptions = try await engine.inspectSubscriptions()
      pending = try await engine.inspectPending()
      blobs = try await engine.inspectBlobs()
      status = try await engine.inspectStatus()
      failure = nil
    } catch {
      failure = String(describing: error)
    }
  }

  func follow() async {
    await load()
    for await _ in await engine.inspectChanges() {
      await load()
      generation += 1
    }
  }
}

enum StoreRoute: Hashable {
  case type(String)
  case object(InspectedObject)
  case subscription(String)
  case blobs
}

struct StoreBrowser: View {
  @State private var model: StoreModel

  init(engine: any SyncInspecting) {
    _model = State(initialValue: StoreModel(engine: engine))
  }

  var body: some View {
    NavigationStack {
      List {
        if let failure = model.failure {
          Section { Text(failure).foregroundStyle(.red) }
        }
        if let status = model.status {
          Section("Status") {
            Field("Account", model.engine.inspectedAccountId)
            Field("Connected", status.isConnected ? "yes" : "no")
            Field("Last sync-in", status.lastSyncIn?.clockTime)
            Field("Last sync-out", status.lastSyncOut?.clockTime)
            if let failure = status.lastFailure { Field("Last failure", failure) }
            ForEach(status.initialSync.keys.sorted(), id: \.self) { type in
              let progress = status.initialSync[type]!
              Field("Initial sync \(type)", "\(progress.fetched) of \(progress.total.map(String.init) ?? "?")")
            }
          }
        }
        Section("Types") {
          ForEach(model.types) { type in
            NavigationLink(value: StoreRoute.type(type.name)) { TypeRow(type: type) }
          }
        }
        if !model.subscriptions.isEmpty {
          Section("Subscriptions") {
            ForEach(model.subscriptions) { sub in
              NavigationLink(value: StoreRoute.subscription(sub.id)) { SubscriptionRow(sub: sub) }
            }
          }
        }
        Section("Pending log (\(model.pending.count))") {
          ForEach(model.pending, id: \.seq) { entry in
            PendingRow(entry: entry)
          }
        }
        Section("Blobs") {
          NavigationLink(value: StoreRoute.blobs) {
            let bytes = model.blobs.reduce(0) { $0 + $1.bytesPresent }
            LabeledContent("\(model.blobs.count) cached", value: bytes.formatted(.byteCount(style: .file)))
          }
        }
      }
      .navigationTitle("Store")
      .navigationDestination(for: StoreRoute.self) { route in
        switch route {
        case .type(let name): ObjectList(model: model, type: name)
        case .object(let object): ObjectDetail(object: object)
        case .subscription(let id): SubscriptionDetail(model: model, id: id)
        case .blobs: BlobList(model: model)
        }
      }
      .refreshable { await model.load() }
    }
    .task { await model.follow() }
  }
}

struct TypeRow: View {
  let type: InspectedType

  var body: some View {
    HStack {
      VStack(alignment: .leading) {
        Text(type.name).font(.headline)
        Text("state \(type.serverState ?? "none")")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
      }
      Spacer()
      if type.mode == .windowed { Badge("windowed") }
      if type.pendingCount > 0 { Badge("\(type.pendingCount) pending", .orange) }
      if type.pinnedCount > 0 { Badge("\(type.pinnedCount) pinned", .blue) }
      Text("\(type.count)").monospacedDigit()
    }
  }
}

struct PendingRow: View {
  let entry: PendingEntry

  var body: some View {
    HStack {
      Text("\(entry.seq)").monospacedDigit().foregroundStyle(.secondary)
      Text("\(entry.type) \(entry.key.description)").font(.body.monospaced())
      Spacer()
      if let claimedBy = entry.claimedBy {
        Badge("claimed by \(claimedBy)", .purple)
      }
      Badge(entry.operation.rawValue, .orange)
    }
  }
}

// MARK: - Objects

struct ObjectList: View {
  let model: StoreModel
  let type: String
  @State private var objects: [InspectedObject] = []
  @State private var search = ""
  @State private var onlyChanged = false

  private var shown: [InspectedObject] {
    objects.filter { object in
      (!onlyChanged || object.pendingEntry != nil || object.stored.lastError != nil)
        && (search.isEmpty
          || object.stored.id?.localizedCaseInsensitiveContains(search) == true
          || object.stored.key.description.contains(search)
          || object.stored.local.description.localizedCaseInsensitiveContains(search))
    }
  }

  var body: some View {
    List {
      Toggle("Only pending or failed", isOn: $onlyChanged)
      ForEach(shown) { object in
        NavigationLink(value: StoreRoute.object(object)) { ObjectRow(object: object) }
      }
    }
    .searchable(text: $search, prompt: "id, key or content")
    .navigationTitle("\(type) (\(objects.count))")
    .task(id: model.generation) {
      objects = (try? await model.engine.inspectObjects(type: type)) ?? []
    }
  }
}

struct ObjectRow: View {
  let object: InspectedObject

  var body: some View {
    HStack {
      VStack(alignment: .leading) {
        Text(object.stored.id ?? "(no id yet)").font(.body.monospaced())
        Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer()
      Text(object.stored.key.description).font(.caption.monospaced()).foregroundStyle(.secondary)
      if object.isPinned { Badge("pinned", .blue) }
      if let pending = object.pendingEntry { Badge(pending.operation.rawValue, .orange) }
      if object.stored.lastError != nil { Badge("error", .red) }
    }
  }

  /// A few scalar members, for telling objects apart in a list.
  private var preview: String {
    guard let members = object.stored.local.objectValue else { return "" }
    return members.keys.sorted()
      .filter { $0 != "id" }
      .compactMap { key -> String? in
        switch members[key]! {
        case .string(let s): "\(key): \(s)"
        case .number(let n): "\(key): \(n.formatted())"
        case .bool(let b): "\(key): \(b)"
        default: nil
        }
      }
      .prefix(4)
      .joined(separator: " · ")
  }
}

struct ObjectDetail: View {
  let object: InspectedObject

  var body: some View {
    List {
      Section("Identity") {
        Field("Type", object.stored.type)
        Field("Id", object.stored.id)
        Field("Local key", object.stored.key.description)
        Field("Creation id", object.stored.key.creationId)
        Field("Pinned", object.isPinned ? "yes" : "no")
      }
      Section("Sync") {
        if let entry = object.pendingEntry {
          Field("Pending", "\(entry.operation.rawValue), log seq \(entry.seq)")
          if let claimedBy = entry.claimedBy {
            Field("Claimed by", "\(claimedBy) at \(entry.claimedAt?.clockTime ?? "?")")
          }
        } else {
          Field("Pending", "nothing")
        }
        if let error = object.stored.lastError {
          Field("Last error", [error.type, error.description].compactMap(\.self).joined(separator: ": "))
        }
      }
      Section("Local changes") {
        if let patch = object.localPatch {
          if patch.isEmpty {
            Text("Local value matches the server version.").foregroundStyle(.secondary)
          } else {
            ForEach(patch.entries.keys.sorted(), id: \.self) { path in
              LabeledContent(path) {
                Text(patch.entries[path]!.description)
                  .font(.caption.monospaced())
                  .textSelection(.enabled)
              }
            }
          }
        } else {
          Text("The server has never seen this object.").foregroundStyle(.secondary)
        }
      }
      Section("Local value") { JSONText(JSONValueText(object.stored.local)) }
      if let server = object.stored.serverVersion {
        Section("Server version") { JSONText(JSONValueText(server)) }
      }
    }
    .navigationTitle(object.stored.id ?? object.stored.key.description)
  }
}

// MARK: - Subscriptions

struct SubscriptionRow: View {
  let sub: InspectedSubscription

  var body: some View {
    HStack {
      VStack(alignment: .leading) {
        Text(sub.id).font(.headline)
        Text(sub.subscription.type).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if let result = sub.result {
        Text("\(result.ids.count) of \(result.total.map(String.init) ?? "?")").monospacedDigit()
      } else {
        Badge("no result", .orange)
      }
    }
  }
}

struct SubscriptionDetail: View {
  let model: StoreModel
  let id: String

  var body: some View {
    if let sub = model.subscriptions.first(where: { $0.id == id }) {
      List {
        Section("Definition") {
          Field("Type", sub.subscription.type)
          Field("Position", String(sub.subscription.position))
          Field("Limit", sub.subscription.limit.map(String.init))
          Field("Covers whole type", sub.subscription.coversWholeType ? "yes" : "no")
        }
        if let filter = sub.subscription.filter {
          Section("Filter") { JSONText(JSONValueText(filter)) }
        }
        Section("Sort") { JSONText(JSONValueText(.array(sub.subscription.sort))) }
        if !sub.subscription.arguments.isEmpty {
          Section("Arguments") { JSONText(JSONValueText(.object(sub.subscription.arguments))) }
        }
        if let result = sub.result {
          Section("Result") {
            Field("Total", result.total.map(String.init))
            Field("Query state", result.queryState)
            Field("Can calculate changes", result.canCalculateChanges ? "yes" : "no")
          }
          if !result.extra.isEmpty {
            Section("Extra") { JSONText(JSONValueText(.object(result.extra))) }
          }
          Section("Ids (\(result.ids.count))") {
            ForEach(Array(result.ids.enumerated()), id: \.offset) { index, id in
              LabeledContent("\(sub.subscription.position + index)") {
                Text(id).font(.body.monospaced()).textSelection(.enabled)
              }
            }
          }
        } else {
          Section("Result") { Text("Not yet queried.").foregroundStyle(.secondary) }
        }
      }
      .navigationTitle(id)
    } else {
      ContentUnavailableView("Subscription \(id) is gone", systemImage: "questionmark.folder")
    }
  }
}

// MARK: - Blobs

struct BlobList: View {
  let model: StoreModel

  var body: some View {
    List(model.blobs.sorted { $0.lastAccess > $1.lastAccess }, id: \.blobId) { blob in
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text(blob.blobId).font(.body.monospaced()).textSelection(.enabled).lineLimit(1)
          Spacer()
          if blob.isPinned { Badge("pinned", .blue) }
          Badge(blob.isComplete ? "complete" : "partial", blob.isComplete ? .green : .orange)
        }
        HStack {
          Text(blob.contentType ?? "no type")
          Spacer()
          Text(sizeText(blob))
          Text("used \(blob.lastAccess.formatted(.relative(presentation: .named)))")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        if !blob.isComplete, !blob.ranges.isEmpty {
          Text(blob.ranges.map { "\($0.lowerBound)..<\($0.upperBound)" }.joined(separator: ", "))
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
      }
    }
    .overlay {
      if model.blobs.isEmpty { ContentUnavailableView("No cached blobs", systemImage: "doc") }
    }
    .navigationTitle("Blobs")
  }

  private func sizeText(_ blob: BlobRecord) -> String {
    let present = blob.bytesPresent.formatted(.byteCount(style: .file))
    guard let total = blob.totalLength else { return present }
    return blob.isComplete ? present : "\(present) of \(total.formatted(.byteCount(style: .file)))"
  }
}
