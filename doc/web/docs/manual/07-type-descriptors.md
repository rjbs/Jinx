# 7. Describing a type

Jinx is generic over JSON.  It has no `Email` struct and never will,
and the engine reads an object's properties only where a sync decision
depends on one.  That raises the question this unit answers: what
does the engine have to know about a type in order to sync it
correctly?  The answer is a `TypeDescriptor`, and it is short enough
that the standard types' descriptors are a few lines each.

The facts in a descriptor come from the RFCs, not from any app, and
they are the kind of thing that is easy to get subtly wrong.  That is
why `JinxTypes` ships descriptors for Mail and Tasks as data: so that
each fact is written down once, next to the section of the RFC it
came from, and tested.

## The fields

**`name`** and **`capability`**: the JMAP type name, as in `Email`,
and the capability URN its methods require in a request's `using`.
The engine collects the capabilities of every configured type into
each request.

**`mode`**: `full` or `windowed`.  Whether every object of the type
is held locally, or only what subscriptions, pins, pending changes, and
references retain.  Unit 10.

**`syncAfter`**: the types this one must sync after.  A sync-in fetches
types in dependency order within one request, and a sync-out sends its
`/set` calls in the same order.  Juke's Track must precede Playlist
because a playlist is a server-evaluated query over tracks.

**`references`**: which properties hold ids of which types, as a map
from property name to type name.  A property may hold one id,
an array of ids, or an object keyed by id, and `referencedIds(in:)`
reads all three shapes.  The engine uses this in two ways.  In
windowed mode, an object that is held keeps the objects it references
held, one level deep, and a pass fetches them if they are missing:
that is how a held Email keeps its Thread.  And it is how a
`/changes` for one type can know which held objects of another are
affected.

**`properties`**: the list to fetch, or `nil` for every property.  For
Email this is the summary set, everything but the body, and the app
asks for more by id when it needs it.

**`ownedProperties`**: the properties a replacement encoding may
change, from unit 4.  `nil` means the app owns every property, which
is right for a type the app defined, such as Track, and wrong for a
shared type such as Task, where other clients and the server set
properties the app never sees.

**`clientIdentity`**: a property whose value the client chooses at
creation and the server keeps unique, with the filter condition that
finds an object by it.  This is what makes a create idempotent, in
unit 9.  Task has `uid`; Email has nothing of the kind, and accepts
the duplicate risk.

**`blobProperties`**: properties that hold blob ids.  When a sync-in
changes one, the change set reports the old and new ids so that the
app's blob policy can act.  Juke's retagging case, in unit 11.

**`getArguments`**: extra arguments merged into every `/get` of the
type.  Standard types need this: `Email/get` takes `bodyProperties`,
`fetchHTMLBodyValues`, and `maxBodyValueBytes`, and no generic
mechanism can know that.

**`mayPatch`**: the veto from unit 4, a closure from a path to
whether the diff may descend into the object there.

## The Mail descriptors, line by line

`MailTypes` in `JinxTypes` declares the five types of RFC 8621 and
RFC 8621's submission extension.

```swift
public static let mailbox = TypeDescriptor(
  name: "Mailbox",
  capability: capability,
  references: ["parentId": "Mailbox"],
  ownedProperties: ["name", "parentId", "role", "sortOrder", "isSubscribed"]
)
```

Mailbox is full: every account's mailbox list fits on a phone.  The
owned set is the properties RFC 8621 section 2 lets a client set;
`totalEmails`, `unreadThreads`, and `myRights` are server-set and an
app's encoding must not be allowed to touch them.  A Mailbox
references its parent, so a held mailbox keeps its parent held, which
matters only if Mailbox were ever windowed and is recorded for
completeness.

```swift
public static let thread = TypeDescriptor(
  name: "Thread",
  capability: capability,
  mode: .windowed,
  references: ["emailIds": "Email"],
  ownedProperties: []
)
```

Thread is windowed, because a large account has nearly as many
Threads as Emails, and read-only: the server derives it from Emails,
so no property is owned.  It references its Emails.  The order of
declaration is Thread before Email, because Email carries `threadId`
and the engine wants the Thread fetched first; the reference the
other way, `emailIds`, is tolerated as dangling until the same pass
fetches the Email.

```swift
public static func email(
  properties: [String]? = emailSummaryProperties,
  bodyProperties: [String]? = nil,
  fetchTextBodyValues: Bool = false,
  fetchHTMLBodyValues: Bool = false,
  fetchAllBodyValues: Bool = false,
  maxBodyValueBytes: Int? = nil
) -> TypeDescriptor
```

Email is a function rather than a constant, because the property list
and body arguments are the app's choice and vary between a list view
and a reader.  What it returns is windowed, depends on Mailbox and
Thread, references `threadId` and `mailboxIds`, names `blobId` as a
blob property, and owns exactly `keywords` and `mailboxIds`.  That
last fact is RFC 8621 section 4.6: an Email is immutable except for
those two properties, so those two are all an app may ever change,
and both are maps, so the diff from unit 4 patches them per entry.
Moving a message between mailboxes is a patch with two entries,
`mailboxIds/old: null` and `mailboxIds/new: true`, and marking it read
is `keywords/$seen: true`.

Identity and EmailSubmission round out the set.

!!! info "Not yet built"
    `EmailSubmission/set` takes `onSuccessUpdateEmail` and
    `onSuccessDestroyEmail`, which patch the sent Email in the same
    call.  Jinx's write API has no way to express a `/set` argument
    that is not an object, so sending mail through Jinx cannot yet
    move the draft to Sent in one step.  Thread 2026-10-17-cqyp66.

## The Task descriptors

```swift
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
```

Two facts here are the reason `JinxTypes` exists.  The client identity
is `uid`, which JSCalendar, RFC 8984, requires to be set by the
creator and unique; this is what lets NerfJournal resend a create
without making two tasks.  And the veto, `jscalendarMayPatch`, refuses
to descend into an entry of `recurrenceOverrides`, because each entry
is itself a patch: the diff may add or remove an entry, but replaces
a changed entry whole.  Both are easy to not know, and both are wrong
in ways that show up only in production.

The owned set is a parameter, because it depends on the app's model.
NerfJournal's encoding carries the properties in its `JMAP-SPEC.md`,
and that is what it passes.

## Dependency order

`inDependencyOrder()` on an array of descriptors is a topological
sort: every type follows the types it depends on, and the order is
otherwise as given.  A type that depends on one not configured is
`SyncError.unknownType`, and a cycle is `SyncError.dependencyCycle`.
The engine sorts once, at initialization, and uses the result for
every sync-in and sync-out.

Mutual references are not cycles.  Email depends on Thread and Thread
references Email, which is fine, because `references` is about
retention and `syncAfter` is about order.  What makes the mutual
reference safe is the rule from unit 6 that a sync-in applies every
type in one transaction: a reader sees both sides of the reference or
neither, never one.

## What JinxTypes is not

It is not a type library.  Typed Swift models of Task or Email belong
to the apps, along with their lenient-read rules and codecs, because
no part of the engine needs one and an app's model is its own
business.  What ships is reference data, the sync-relevant facts of
each standard type, and that is the thing a conformance suite can
check a client against.

!!! info "Not yet built"
    A `@JMAPObject` macro for declaring app-defined types is deferred
    until a consumer, probably Juke declaring Track, feels the pain of
    writing accessors over JSON by hand.  A descriptor for an
    app-defined type is a five-line initializer call, as above.

## Where to look

- `Sources/Jinx/TypeDescriptor.swift` is the descriptor and the
  dependency sort.  `Sources/JinxTypes/MailTypes.swift` and
  `TaskTypes.swift` are the standard types, and the RFC sections are
  cited in their comments.
- `swift test --filter JinxTypesTests`.  `mailTypesOrderResolves`
  checks the sort; `emailGetArgumentsCarryBodyOptions` the extra
  arguments; `taskVetoReplacesWholeOverridesButPatchesTheMap` the
  veto; and `mailScenarioAgainstTheScriptedServer` runs the Mail
  descriptors through a windowed sync against the test server.

Next: [Sync in](08-sync-in.md).
