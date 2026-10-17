import JinxJSON

extension JSONValue {
  /// A copy of this object with the members named in `owned` taken from
  /// `encoding`: each owned member is set to the encoding's value, or
  /// removed when the encoding lacks it.  Every other member is left
  /// exactly as it was.
  ///
  /// This is how an app with its own model replaces an object: it
  /// encodes its model to JSON, naming only the properties it owns, and
  /// the merge keeps the properties it does not model.  Diffing the
  /// result against the server snapshot then names only owned
  /// properties, so other clients' data on the server survives.
  public func mergingOwnedProperties(
    _ owned: Set<String>,
    from encoding: JSONValue
  ) throws(PatchError) -> JSONValue {
    guard case .object(var members) = self, case .object(let incoming) = encoding else {
      throw .notAnObject
    }
    for key in owned {
      members[key] = incoming[key]
    }
    return .object(members)
  }
}
