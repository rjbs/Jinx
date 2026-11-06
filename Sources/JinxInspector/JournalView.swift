import Jinx
import JinxStore
import SwiftUI

/// The tail of the journal, newest first: what each commit changed, by
/// which process, from which source.
struct JournalView: View {
  let engine: any SyncInspecting
  @State private var entries: [JournalEntry] = []
  @State private var failure: String?

  var body: some View {
    NavigationStack {
      List {
        if let failure { Text(failure).foregroundStyle(.red) }
        ForEach(entries.reversed(), id: \.seq) { entry in
          JournalRow(entry: entry)
        }
      }
      .overlay {
        if entries.isEmpty { ContentUnavailableView("Nothing journaled", systemImage: "list.bullet.rectangle") }
      }
      .navigationTitle("Journal")
    }
    .task {
      await load()
      for await _ in await engine.inspectChanges() { await load() }
    }
  }

  private func load() async {
    do {
      entries = try await engine.inspectJournal(limit: 300)
      failure = nil
    } catch {
      failure = String(describing: error)
    }
  }
}

struct JournalRow: View {
  let entry: JournalEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text("\(entry.seq)").monospacedDigit().foregroundStyle(.secondary)
        Badge(entry.changeSet.source.rawValue, sourceColor)
        Text(entry.processId).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
      }
      ForEach(entry.changeSet.types.keys.sorted(), id: \.self) { type in
        Text("\(type): \(summary(entry.changeSet.types[type]!))").font(.callout.monospaced())
      }
      if !entry.changeSet.failed.isEmpty {
        Text("failed: " + entry.changeSet.failed.map { "\($0.key) \($0.value.type)" }.sorted().joined(separator: ", "))
          .font(.callout)
          .foregroundStyle(.red)
      }
      if !entry.changeSet.subscriptions.isEmpty {
        Text("subscriptions: " + entry.changeSet.subscriptions.joined(separator: ", ")).font(.callout)
      }
      if !entry.changeSet.blobs.isEmpty {
        Text("\(entry.changeSet.blobs.count) blob change(s)").font(.callout)
      }
    }
  }

  private var sourceColor: Color {
    switch entry.changeSet.source {
    case .local: .orange
    case .syncOut: .purple
    case .syncIn: .blue
    }
  }

  private func summary(_ changes: ChangeSet.TypeChanges) -> String {
    [
      changes.created.isEmpty ? nil : "+\(changes.created.count)",
      changes.updated.isEmpty ? nil : "~\(changes.updated.count)",
      changes.destroyed.isEmpty ? nil : "-\(changes.destroyed.count)",
      changes.idsAssigned.isEmpty ? nil : "\(changes.idsAssigned.count) id(s) assigned",
    ].compactMap(\.self).joined(separator: " ")
  }
}
