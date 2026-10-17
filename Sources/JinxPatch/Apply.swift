import JinxJSON

extension JSONValue {
  /// A copy with `patch` applied.  The receiver must be an object and
  /// the patch must be valid (see `PatchObject.validate`).  Objects
  /// missing along a path are created, which is more lenient than a
  /// server is required to be, and harmless for a client applying its
  /// own patch to its own copy.
  public func applying(_ patch: PatchObject) throws(PatchError) -> JSONValue {
    guard case .object = self else { throw .notAnObject }
    try patch.validate()
    var result = self
    for (pathString, value) in patch.entries.sorted(by: { $0.key < $1.key }) {
      let path = JSONPointer(jmapPatchPath: pathString)
      do {
        result = try result.setting(value.isNull ? nil : value, at: path)
      } catch let error as PointerError {
        throw .pointer(error)
      } catch {
        // `setting` throws only PointerError; this arm satisfies the
        // compiler, which cannot see that. -- claude, 2026-10-17
        throw .notAnObject
      }
    }
    return result
  }
}
