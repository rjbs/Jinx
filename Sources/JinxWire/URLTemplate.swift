import Foundation

/// A URL template at RFC 6570 level 1, which is all the session resource
/// uses: `{accountId}`, `{blobId}`, `{type}`, `{name}`, `{types}`,
/// `{closeafter}`, `{ping}`.  Expansion percent-encodes each value.
public struct URLTemplate: Sendable, Hashable {
  public var template: String
  public var base: URL?

  public init(_ template: String, relativeTo base: URL? = nil) {
    self.template = template
    self.base = base
  }

  /// The variable names the template mentions.
  public var variables: [String] {
    var names: [String] = []
    var rest = template[...]
    while let open = rest.firstIndex(of: "{") {
      guard let close = rest[open...].firstIndex(of: "}") else { break }
      names.append(String(rest[rest.index(after: open)..<close]))
      rest = rest[rest.index(after: close)...]
    }
    return names
  }

  /// Expands the template.  Variables not in `values` expand to nothing,
  /// as RFC 6570 specifies for undefined variables.  A template with an
  /// unclosed brace is malformed and expands to `nil`.
  public func expand(_ values: [String: String]) -> URL? {
    var result = ""
    var rest = template[...]
    while let open = rest.firstIndex(of: "{") {
      result += rest[..<open]
      guard let close = rest[open...].firstIndex(of: "}") else { return nil }
      let name = String(rest[rest.index(after: open)..<close])
      if let value = values[name] {
        result += value.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? value
      }
      rest = rest[rest.index(after: close)...]
    }
    result += rest
    return URL(string: result, relativeTo: base)?.absoluteURL
  }

  private static let unreserved: CharacterSet = {
    var set = CharacterSet.alphanumerics
    set.insert(charactersIn: "-._~")
    return set
  }()
}
