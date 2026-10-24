import Jinx
import JinxJSON
import JinxPatch

/// Sync facts about JMAP for Tasks (draft-ietf-jmap-tasks) and the
/// JSCalendar objects it carries (RFC 8984).
public enum TaskTypes {
  public static let capability = "urn:ietf:params:jmap:tasks"

  public static let taskList = TypeDescriptor(
    name: "TaskList",
    capability: capability,
    ownedProperties: ["name", "description", "color", "sortOrder", "isSubscribed"]
  )

  /// The patch veto JSCalendar needs: an entry of `recurrenceOverrides`
  /// is itself a patch, so patching inside one is ambiguous and the
  /// whole entry is replaced instead.  Adding or removing an entry is
  /// still a per-entry patch.
  public static let jscalendarMayPatch: MayPatch = { path in
    !(path.tokens.count == 2 && path.tokens[0] == "recurrenceOverrides")
  }

  /// Task, with `uid` as its client identity.  `ownedProperties` is the
  /// app's choice: the set its own encoding carries.  NerfJournal's is
  /// in its JMAP-SPEC.md.
  public static func task(ownedProperties: Set<String>? = nil) -> TypeDescriptor {
    TypeDescriptor(
      name: "Task",
      capability: capability,
      syncAfter: ["TaskList"],
      ownedProperties: ownedProperties,
      clientIdentity: .init(property: "uid"),
      mayPatch: jscalendarMayPatch
    )
  }

  public static var all: [TypeDescriptor] {
    [taskList, task()]
  }
}
