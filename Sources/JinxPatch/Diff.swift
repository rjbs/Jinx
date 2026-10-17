import JinxJSON

/// Decides whether a diff may descend into the object at a path and
/// emit per-member patches, or must replace the whole object.  Default
/// is to descend everywhere.  A type vetoes paths where patching inside
/// would be ambiguous; CalendarEvent's `recurrenceOverrides` is the
/// classic case, since its values are themselves patches.
public typealias MayPatch = @Sendable (JSONPointer) -> Bool

public let patchAnywhere: MayPatch = { _ in true }

extension PatchObject {
  /// The patch that turns `old` into `new`.
  ///
  /// Objects are compared member by member and the diff descends into
  /// nested objects where `mayPatch` allows, so a map such as
  /// `keywords` yields one entry per changed key and leaves the others
  /// alone.  Arrays and scalars are replaced whole.  A member that is
  /// `null` and one that is absent are treated as the same, as JMAP
  /// does, so no patch is emitted between them.
  ///
  /// Because the diff mentions only what differs, properties present
  /// in both objects and unchanged are never named; that is how an
  /// object edited by one client keeps properties only another client
  /// knows about.
  public static func diff(
    from old: JSONValue,
    to new: JSONValue,
    mayPatch: MayPatch = patchAnywhere
  ) throws(PatchError) -> PatchObject {
    guard case .object(let oldMembers) = old, case .object(let newMembers) = new else {
      throw .notAnObject
    }
    var patch = PatchObject()
    diffMembers(oldMembers, newMembers, at: JSONPointer(), mayPatch: mayPatch, into: &patch)
    return patch
  }

  private static func diffMembers(
    _ old: [String: JSONValue],
    _ new: [String: JSONValue],
    at path: JSONPointer,
    mayPatch: MayPatch,
    into patch: inout PatchObject
  ) {
    for key in Set(old.keys).union(new.keys) {
      let oldValue = old[key] ?? .null
      let newValue = new[key] ?? .null
      if oldValue == newValue { continue }
      let memberPath = path.appending(key)
      if case .object(let oldInner) = oldValue,
         case .object(let newInner) = newValue,
         mayPatch(memberPath)
      {
        diffMembers(oldInner, newInner, at: memberPath, mayPatch: mayPatch, into: &patch)
      } else {
        patch[memberPath] = newValue
      }
    }
  }
}
