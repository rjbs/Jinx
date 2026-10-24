import JinxJSON

/// The result of rebasing a pending local change onto a newly fetched
/// server object.
public struct Rebase: Sendable, Hashable {
  /// The local value to store: the fetched object with the pending
  /// change re-applied on top.
  public var local: JSONValue

  /// The pending change itself, as a patch from the old snapshot to the
  /// old local value.
  public var patch: PatchObject

  /// True when re-applying the pending change to the fetched object
  /// changed nothing, which means the server already has it and the
  /// pending entry can be dropped.
  public var isRedundant: Bool
}

extension Rebase {
  /// Rebases a pending change.  This is the whole of the default
  /// conflict rule: a locally pending property wins until it is synced out,
  /// and every other property takes the server's value.  It works at
  /// patch-path granularity, so two clients editing different members
  /// of one map do not conflict.
  ///
  /// - Parameters:
  ///   - snapshot: the server object as last known before `fetched`.
  ///   - local: the local value, which differs from `snapshot` by the
  ///     pending change.
  ///   - fetched: the server object as just fetched.
  public init(
    snapshot: JSONValue,
    local: JSONValue,
    fetched: JSONValue,
    mayPatch: MayPatch = patchAnywhere
  ) throws(PatchError) {
    patch = try PatchObject.diff(from: snapshot, to: local, mayPatch: mayPatch)
    self.local = try fetched.applying(patch)
    isRedundant = self.local.isJMAPEquivalent(to: fetched)
  }
}
