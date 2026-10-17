import JinxJSON

/// A JMAP `PatchObject` (RFC 8620 section 5.3): a map from JSON pointer
/// path, written without its leading slash, to the value to store there.
/// A `null` value removes the property.  The wire shape and this type
/// are the same, so it encodes and decodes directly.
public struct PatchObject: Sendable, Hashable {
  /// Path to value.  Keys are in JMAP patch form, as on the wire.
  public var entries: [String: JSONValue]

  public init(_ entries: [String: JSONValue] = [:]) {
    self.entries = entries
  }

  public var isEmpty: Bool { entries.isEmpty }

  public var paths: [JSONPointer] {
    entries.keys.map { JSONPointer(jmapPatchPath: $0) }
  }

  public subscript(path: JSONPointer) -> JSONValue? {
    get { entries[path.jmapPatchPath] }
    set { entries[path.jmapPatchPath] = newValue }
  }

  /// Checks the rules RFC 8620 places on a patch: no empty path, and no
  /// path that is a prefix of another, since the two would be ambiguous.
  public func validate() throws(PatchError) {
    let sorted = paths.sorted { $0.tokens.lexicographicallyPrecedes($1.tokens) }
    for (index, path) in sorted.enumerated() {
      if path.isRoot { throw .emptyPath }
      if index + 1 < sorted.count, path.isPrefix(of: sorted[index + 1]) {
        throw .overlappingPaths(path, sorted[index + 1])
      }
    }
  }
}

extension PatchObject: ExpressibleByDictionaryLiteral {
  public init(dictionaryLiteral elements: (String, JSONValue)...) {
    entries = Dictionary(elements, uniquingKeysWith: { _, last in last })
  }
}

extension PatchObject: Codable {
  public init(from decoder: any Decoder) throws {
    entries = try [String: JSONValue](from: decoder)
  }

  public func encode(to encoder: any Encoder) throws {
    try entries.encode(to: encoder)
  }
}

extension PatchObject: CustomStringConvertible {
  public var description: String { JSONValue.object(entries).description }
}

public enum PatchError: Error, Sendable, Equatable {
  /// Diff and apply work on JSON objects, never on arrays or scalars.
  case notAnObject
  case emptyPath
  case overlappingPaths(JSONPointer, JSONPointer)
  case pointer(JSONValue.PointerError)
}
