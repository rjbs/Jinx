import JinxJSON
import JinxPatch
import JinxWire

/// What the engine needs to know about a JMAP data type in order to sync
/// it.  Standard types ship with descriptors in JinxTypes; an app
/// declares its own types with the `@JMAPObject` macro or by hand.
public struct TypeDescriptor: Sendable {
  /// Whether every object of the type is held locally, or only what
  /// subscriptions, pins, pending changes and references retain.
  public enum Mode: Sendable, Hashable {
    case full
    case windowed
  }

  /// A property whose value the client chooses at creation and which
  /// the server keeps unique, such as a Task's `uid`.  It makes creates
  /// idempotent: a create whose response was lost can be matched to the
  /// object the server made.
  public struct ClientIdentity: Sendable, Hashable {
    public var property: String
    /// The `/query` filter condition that finds an object by this
    /// property, as a filter object with one placeholder value.
    /// Default: `{ property: value }`.
    public var filterProperty: String

    public init(property: String, filterProperty: String? = nil) {
      self.property = property
      self.filterProperty = filterProperty ?? property
    }
  }

  /// The JMAP type name, as in `Email` or `Track`.
  public var name: String
  /// The capability URN the type's methods require in `using`.
  public var capability: String
  public var mode: Mode
  /// Types this one references and therefore syncs after.
  public var syncAfter: [String]
  /// Properties holding ids of other types, property name to type
  /// name.  A property may hold one id, an array of ids, or an object
  /// keyed by id.  A retained object keeps the objects it references
  /// held, one level deep, and a pass fetches them if missing.
  public var references: [String: String]
  /// The properties to fetch, or `nil` for all of them.
  public var properties: [String]?
  /// Properties a replacement encoding may change.  `nil` means the
  /// app owns every property, which is right for a type the app
  /// defined and wrong for a shared one like Task.
  public var ownedProperties: Set<String>?
  public var clientIdentity: ClientIdentity?
  /// Properties that hold blob ids, for blob invalidation.
  public var blobProperties: [String]
  /// Extra arguments merged into every `/get` for the type, for types
  /// whose `/get` takes more than `ids` and `properties`, such as
  /// Email's `bodyProperties` and `fetchHTMLBodyValues`.
  public var getArguments: [String: JSONValue]
  public var mayPatch: MayPatch

  public init(
    name: String,
    capability: String,
    mode: Mode = .full,
    syncAfter: [String] = [],
    references: [String: String] = [:],
    properties: [String]? = nil,
    ownedProperties: Set<String>? = nil,
    clientIdentity: ClientIdentity? = nil,
    blobProperties: [String] = [],
    getArguments: [String: JSONValue] = [:],
    mayPatch: @escaping MayPatch = patchAnywhere
  ) {
    self.name = name
    self.capability = capability
    self.mode = mode
    self.syncAfter = syncAfter
    self.references = references
    self.properties = properties
    self.ownedProperties = ownedProperties
    self.clientIdentity = clientIdentity
    self.blobProperties = blobProperties
    self.getArguments = getArguments
    self.mayPatch = mayPatch
  }

  /// The arguments for a `/get` of `ids`, with the type's property list
  /// and extra arguments applied.
  public func getArguments(accountId: String, ids: [String]?) -> JSONValue {
    var args = JSONValue.getArguments(accountId: accountId, ids: ids, properties: properties)
    for (key, value) in getArguments where key != "accountId" && key != "ids" {
      args[key] = value
    }
    return args
  }
}

extension [TypeDescriptor] {
  /// The descriptors in an order where every type follows the types it
  /// depends on, and otherwise in the order given.
  public func inDependencyOrder() throws(SyncError) -> [TypeDescriptor] {
    let byName = Dictionary(map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    var ordered: [TypeDescriptor] = []
    var visiting: Set<String> = []
    var done: Set<String> = []

    func visit(_ name: String) throws(SyncError) {
      if done.contains(name) { return }
      guard let descriptor = byName[name] else { throw .unknownType(name) }
      guard visiting.insert(name).inserted else { throw .dependencyCycle(name) }
      for dependency in descriptor.syncAfter {
        try visit(dependency)
      }
      visiting.remove(name)
      done.insert(name)
      ordered.append(descriptor)
    }

    for descriptor in self {
      try visit(descriptor.name)
    }
    return ordered
  }
}

public enum SyncError: Error, Sendable {
  case unknownType(String)
  case dependencyCycle(String)
  case noSuchObject(String)
  case objectIsBeingDestroyed(String)
  /// A write referenced a pending create of another type; see the plan.
  case crossTypeCreationReference(String)
  case notConnected
  /// The operation failed in a way worth retrying later.
  case retryable(String)
  /// The operation failed in a way that will not get better by itself.
  case permanent(String)
}

extension TypeDescriptor {
  /// The ids of other types an object's value references, by type.
  public func referencedIds(in value: JSONValue) -> [String: Set<String>] {
    var result: [String: Set<String>] = [:]
    for (property, type) in references {
      guard let held = value[property] else { continue }
      switch held {
      case .string(let id):
        result[type, default: []].insert(id)
      case .array(let ids):
        result[type, default: []].formUnion(ids.compactMap(\.stringValue))
      case .object(let members):
        result[type, default: []].formUnion(members.keys)
      default:
        break
      }
    }
    return result
  }
}
