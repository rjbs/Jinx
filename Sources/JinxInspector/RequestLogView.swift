import JinxJSON
import JinxWire
import SwiftUI

import Jinx

/// The engine's exchanges, recorded while the inspector is open.
@MainActor @Observable
final class RequestLogModel {
  let engine: any SyncInspecting
  let recorder = TransportRecorder()
  var exchanges: [TransportExchange] = []

  init(engine: any SyncInspecting) {
    self.engine = engine
  }

  /// Taps the engine and keeps `exchanges` current until cancelled,
  /// then detaches.
  func record() async {
    let updates = recorder.updates()
    let token = engine.addWireTap(recorder)
    defer { token.cancel() }
    for await exchange in updates {
      if let index = exchanges.lastIndex(where: { $0.id == exchange.id }) {
        exchanges[index] = exchange
      } else {
        exchanges.append(exchange)
        if exchanges.count > 2000 { exchanges.removeFirst(exchanges.count - 2000) }
      }
    }
  }

  func clear() {
    recorder.clear()
    exchanges.removeAll()
  }
}

struct RequestLogView: View {
  let model: RequestLogModel
  @State private var search = ""
  @State private var failuresOnly = false

  private var shown: [TransportExchange] {
    model.exchanges.reversed().filter { exchange in
      (!failuresOnly || exchange.isFailure || exchange.calls.contains { $0.responses.contains(where: \.isError) })
        && (search.isEmpty
          || exchange.title.localizedCaseInsensitiveContains(search)
          || exchange.purpose?.localizedCaseInsensitiveContains(search) == true)
    }
  }

  var body: some View {
    NavigationStack {
      List {
        Toggle("Failures and method errors only", isOn: $failuresOnly)
        ForEach(shown) { exchange in
          NavigationLink(value: exchange.id) { ExchangeRow(exchange: exchange) }
        }
      }
      .overlay {
        if model.exchanges.isEmpty { ContentUnavailableView("No requests yet", systemImage: "arrow.left.arrow.right") }
      }
      .searchable(text: $search, prompt: "method or step")
      .navigationTitle("Requests")
      .navigationDestination(for: Int.self) { id in
        if let exchange = model.exchanges.first(where: { $0.id == id }) {
          ExchangeDetail(exchange: exchange)
        } else {
          ContentUnavailableView("No longer kept", systemImage: "clock.arrow.circlepath")
        }
      }
      .toolbar {
        Button("Clear", systemImage: "trash") { model.clear() }
      }
    }
  }
}

struct ExchangeRow: View {
  let exchange: TransportExchange

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text("\(exchange.id)").monospacedDigit().foregroundStyle(.secondary)
        Text(exchange.title).font(.body.monospaced()).lineLimit(2)
        Spacer()
        if let duration = exchange.duration {
          Text(duration.milliseconds).monospacedDigit().foregroundStyle(.secondary)
        } else {
          ProgressView().controlSize(.small)
        }
      }
      HStack {
        Text(exchange.purpose ?? "no step").foregroundStyle(.secondary)
        Spacer()
        Text(outcome).foregroundStyle(outcomeColor).lineLimit(1)
      }
      .font(.caption)
    }
  }

  /// For an API exchange that got an answer, what each call got;
  /// otherwise the exchange's own summary.
  private var outcome: String {
    guard case .api = exchange.outcome else { return exchange.outcomeSummary }
    return exchange.calls.map(\.responseSummary).joined(separator: " · ")
  }

  private var outcomeColor: Color {
    if exchange.isFailure { return .red }
    if exchange.calls.contains(where: { $0.responses.contains(where: \.isError) }) { return .orange }
    return .secondary
  }
}

struct ExchangeDetail: View {
  let exchange: TransportExchange

  var body: some View {
    List {
      Section("Exchange") {
        Field("Step", exchange.purpose)
        Field("Started", exchange.started.clockTime)
        Field("Duration", exchange.duration?.milliseconds)
        Field("Outcome", exchange.outcomeSummary)
        if let url = url { Field("URL", url) }
      }
      ForEach(exchange.calls, id: \.call.callId) { call in
        Section {
          LabeledContent("Asked", value: call.callSummary)
          LabeledContent("Answer", value: call.responseSummary)
            .foregroundStyle(call.responses.contains(where: \.isError) ? .red : .primary)
          DisclosureGroup("Arguments") { JSONText(JSONValueText(call.call.arguments)) }
          ForEach(Array(call.responses.enumerated()), id: \.offset) { _, response in
            DisclosureGroup("Response: \(response.name)") { JSONText(JSONValueText(response.arguments)) }
          }
        } header: {
          Text("\(call.call.callId)  \(call.call.name)").font(.body.monospaced())
        }
      }
      if case .session(let session) = exchange.outcome {
        Section("Session") {
          Field("Username", session.username)
          Field("State", session.state)
          Field("API URL", session.apiUrl.absoluteString)
          ForEach(session.capabilities.keys.sorted(), id: \.self) { capability in
            Text(capability).font(.caption.monospaced())
          }
        }
      }
    }
    .navigationTitle("#\(exchange.id) \(exchange.title)")
  }

  private var url: String? {
    switch exchange.kind {
    case .session: nil
    case .api(_, let url), .upload(_, _, let url), .download(let url, _), .events(let url): url.absoluteString
    }
  }
}
