import Jinx
import JinxWire
import SwiftUI

/// Diagnostic tools for one sync engine: a store browser, a request
/// log, and a journal of committed change sets.
///
/// An app puts this behind a debug menu or a hidden gesture, in a
/// window on macOS or a sheet on iOS:
///
///     JinxInspectorView(engine: engine)
///
/// It only reads.  Requests are recorded while it is open, by a wire tap
/// it attaches to the engine, and forgotten when it closes; as with a
/// browser's network panel, what happened before it opened is not
/// shown.  It does show whatever the account holds, so it is no more
/// fit for a shipping build's ordinary UI than the store file is.
public struct JinxInspectorView: View {
  let engine: any SyncInspecting
  @State private var requests: RequestLogModel

  public init(engine: any SyncInspecting) {
    self.engine = engine
    _requests = State(initialValue: RequestLogModel(engine: engine))
  }

  public var body: some View {
    TabView {
      Tab("Store", systemImage: "cylinder.split.1x2") {
        StoreBrowser(engine: engine)
      }
      Tab("Requests", systemImage: "arrow.left.arrow.right") {
        RequestLogView(model: requests)
      }
      Tab("Journal", systemImage: "list.bullet.rectangle") {
        JournalView(engine: engine)
      }
    }
    .task { await requests.record() }
  }
}

/// Pretty JSON in a selectable monospaced block.
struct JSONText: View {
  let value: JSONValueText

  init(_ value: JSONValueText) {
    self.value = value
  }

  var body: some View {
    ScrollView(.horizontal) {
      Text(value.pretty)
        .font(.caption.monospaced())
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

/// A row of label and value, the value selectable.
struct Field: View {
  let label: String
  let value: String

  init(_ label: String, _ value: String?) {
    self.label = label
    self.value = value ?? "—"
  }

  var body: some View {
    LabeledContent(label) {
      Text(value)
        .font(.body.monospaced())
        .textSelection(.enabled)
        .multilineTextAlignment(.trailing)
    }
  }
}

/// A small capsule label.
struct Badge: View {
  let text: String
  let color: Color

  init(_ text: String, _ color: Color = .secondary) {
    self.text = text
    self.color = color
  }

  var body: some View {
    Text(text)
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 6)
      .padding(.vertical, 1)
      .foregroundStyle(color)
      .overlay(Capsule().stroke(color.opacity(0.6)))
  }
}

extension Date {
  var clockTime: String {
    formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3)))
  }
}

extension TimeInterval {
  var milliseconds: String {
    "\(Int((self * 1000).rounded())) ms"
  }
}
