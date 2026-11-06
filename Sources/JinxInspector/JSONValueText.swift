import Foundation
import JinxJSON
import JinxPatch

/// A JSON value rendered once for display.  `JSONValue` serializes
/// compactly, which is right on the wire and unreadable in a viewer.
struct JSONValueText: Hashable {
  let pretty: String

  init(_ value: JSONValue) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    pretty = (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? value.description
  }

  init(_ patch: PatchObject) {
    self.init(.object(patch.entries))
  }
}
