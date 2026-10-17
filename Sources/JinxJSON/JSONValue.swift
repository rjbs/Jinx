import Foundation

/// A JSON value.  This is the one representation of JSON on every Jinx
/// boundary: wire requests and responses, stored objects, patches, and
/// change sets.  It is a value type and `Sendable`, so it crosses actor
/// boundaries freely, unlike `[String: Any]`.
///
/// Numbers are held as `Double`.  JMAP's `Int` and `UnsignedInt` are
/// bounded at 2^53, which `Double` represents exactly.
public enum JSONValue: Sendable, Hashable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])
}

// MARK: - Accessors

extension JSONValue {
  public var isNull: Bool {
    if case .null = self { return true }
    return false
  }

  public var boolValue: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  public var doubleValue: Double? {
    if case .number(let value) = self { return value }
    return nil
  }

  /// The value as an `Int`, when it is a number with no fractional part
  /// that fits.
  public var intValue: Int? {
    guard case .number(let value) = self,
          value.rounded() == value,
          let int = Int(exactly: value)
    else { return nil }
    return int
  }

  public var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public var arrayValue: [JSONValue]? {
    if case .array(let value) = self { return value }
    return nil
  }

  public var objectValue: [String: JSONValue]? {
    if case .object(let value) = self { return value }
    return nil
  }

  /// Member access on an object.  Reading a key that is absent, or
  /// reading any key on a non-object, yields `nil`.  Writing on a
  /// non-object is a no-op; writing `nil` removes the key.
  public subscript(key: String) -> JSONValue? {
    get {
      guard case .object(let members) = self else { return nil }
      return members[key]
    }
    set {
      guard case .object(var members) = self else { return }
      members[key] = newValue
      self = .object(members)
    }
  }

  /// Element access on an array; out-of-range or non-array yields `nil`.
  public subscript(index: Int) -> JSONValue? {
    guard case .array(let elements) = self, elements.indices.contains(index) else {
      return nil
    }
    return elements[index]
  }
}

// MARK: - Literals
//
// There is deliberately no ExpressibleByNilLiteral conformance.  With it,
// a bare `nil` in any expression typed `JSONValue?` infers as
// `.some(.null)` rather than `.none`, which turned "remove this member"
// into "store a null" twice in one afternoon.  JSON null is spelled
// `.null`. -- claude, 2026-10-17

extension JSONValue: ExpressibleByBooleanLiteral {
  public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
  public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension JSONValue: ExpressibleByFloatLiteral {
  public init(floatLiteral value: Double) { self = .number(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
  public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
  public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
  public init(dictionaryLiteral elements: (String, JSONValue)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
  }
}

// MARK: - Codable

extension JSONValue: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "not a JSON value"
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}

// MARK: - Serialization

extension JSONValue {
  public enum SerializationError: Error, Sendable {
    case notUTF8
  }

  /// Parses JSON text.
  public init(parsing data: Data) throws {
    self = try JSONDecoder().decode(JSONValue.self, from: data)
  }

  /// Parses JSON text.
  public init(parsing string: String) throws {
    guard let data = string.data(using: .utf8) else {
      throw SerializationError.notUTF8
    }
    try self.init(parsing: data)
  }

  /// Serializes to compact JSON text with object keys sorted, so that
  /// equal values serialize identically.
  public func serialized() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }

  /// `serialized()` as a `String`.
  public func serializedString() throws -> String {
    String(decoding: try serialized(), as: UTF8.self)
  }
}

extension JSONValue: CustomStringConvertible {
  public var description: String {
    (try? serializedString()) ?? "<unserializable JSONValue>"
  }
}

// MARK: - JMAP equivalence

extension JSONValue {
  /// A copy with every `null` object member removed, recursively.  JMAP
  /// treats a property that is `null` and one that is absent as the
  /// same, so two objects are the same JMAP object when their stripped
  /// forms are equal.  Array elements are never removed.
  public func strippingNullMembers() -> JSONValue {
    switch self {
    case .object(let members):
      return .object(members.compactMapValues { $0.isNull ? nil : $0.strippingNullMembers() })
    case .array(let elements):
      return .array(elements.map { $0.strippingNullMembers() })
    default:
      return self
    }
  }

  /// Equality under JMAP's rule that `null` and absent are the same.
  public func isJMAPEquivalent(to other: JSONValue) -> Bool {
    strippingNullMembers() == other.strippingNullMembers()
  }
}
