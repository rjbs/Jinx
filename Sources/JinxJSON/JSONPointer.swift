/// A JSON Pointer (RFC 6901), as JMAP uses them in `PatchObject` keys
/// and `ResultReference` paths.
///
/// JMAP writes patch paths without the leading slash (`"keywords/foo"`)
/// and result-reference paths with it (`"/ids"`).  Both forms parse and
/// print; `jmapPatchPath` is the former and `rfc6901` the latter.
public struct JSONPointer: Sendable, Hashable {
  /// The unescaped reference tokens, outermost first.
  public var tokens: [String]

  public init(tokens: [String]) {
    self.tokens = tokens
  }

  public init(_ tokens: String...) {
    self.tokens = tokens
  }

  /// Parses a path in JMAP patch form, with no leading slash.  An empty
  /// string is the whole document.
  public init(jmapPatchPath path: String) {
    tokens = path.isEmpty ? [] : path.split(separator: "/", omittingEmptySubsequences: false)
      .map { Self.unescape(String($0)) }
  }

  /// Parses an RFC 6901 pointer, with a leading slash.  An empty string
  /// is the whole document.
  public init(rfc6901 pointer: String) {
    guard pointer.hasPrefix("/") else {
      self.init(jmapPatchPath: pointer)
      return
    }
    self.init(jmapPatchPath: String(pointer.dropFirst()))
  }

  public var jmapPatchPath: String {
    tokens.map(Self.escape).joined(separator: "/")
  }

  public var rfc6901: String {
    tokens.isEmpty ? "" : "/" + jmapPatchPath
  }

  public var isRoot: Bool { tokens.isEmpty }

  public func appending(_ token: String) -> JSONPointer {
    JSONPointer(tokens: tokens + [token])
  }

  /// True when `self` addresses `other` or something inside it.
  public func isPrefix(of other: JSONPointer) -> Bool {
    other.tokens.count >= tokens.count && Array(other.tokens.prefix(tokens.count)) == tokens
  }

  public static func escape(_ token: String) -> String {
    token.replacingOccurrences(of: "~", with: "~0")
      .replacingOccurrences(of: "/", with: "~1")
  }

  public static func unescape(_ token: String) -> String {
    token.replacingOccurrences(of: "~1", with: "/")
      .replacingOccurrences(of: "~0", with: "~")
  }
}

extension JSONPointer: CustomStringConvertible {
  public var description: String { rfc6901 }
}

extension JSONValue {
  /// The value a pointer addresses, or `nil` if any step is missing.
  /// Numeric tokens index arrays.
  public func value(at pointer: JSONPointer) -> JSONValue? {
    var current = self
    for token in pointer.tokens {
      switch current {
      case .object(let members):
        guard let next = members[token] else { return nil }
        current = next
      case .array(let elements):
        guard let index = Int(token), elements.indices.contains(index) else { return nil }
        current = elements[index]
      default:
        return nil
      }
    }
    return current
  }

  /// A copy with `value` stored at `pointer`, or the member removed when
  /// `value` is `nil`.  Objects on the path are created as needed; the
  /// path may not pass through an array, because JMAP patches may not
  /// either (RFC 8620 section 5.3).
  public func setting(_ value: JSONValue?, at pointer: JSONPointer) throws -> JSONValue {
    try Self.set(value, tokens: pointer.tokens[...], in: self)
  }

  public enum PointerError: Error, Sendable, Equatable {
    case pathThroughArray(JSONPointer)
    case pathThroughScalar(JSONPointer)
    case cannotReplaceRootWithNothing
  }

  private static func set(
    _ value: JSONValue?,
    tokens: ArraySlice<String>,
    in target: JSONValue
  ) throws -> JSONValue {
    guard let token = tokens.first else {
      guard let value else { throw PointerError.cannotReplaceRootWithNothing }
      return value
    }
    let rest = tokens.dropFirst()
    switch target {
    case .object(var members):
      if rest.isEmpty {
        members[token] = value
      } else {
        members[token] = try set(value, tokens: rest, in: members[token] ?? .object([:]))
      }
      return .object(members)
    case .array:
      throw PointerError.pathThroughArray(JSONPointer(tokens: Array(tokens)))
    default:
      throw PointerError.pathThroughScalar(JSONPointer(tokens: Array(tokens)))
    }
  }
}
