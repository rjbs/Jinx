# Jinx: the plan

Proposed 2026-10-16.  This is a first design, written against
[consumers.md](consumers.md), and it is expected to be reworked.  When
code and this document disagree, fix one of them.

## What Jinx is

A Swift package that keeps a local, offline-usable copy of the JMAP data
in an account in sync with a server that implements standard JMAP
semantics, for standard types and for application-defined ones.  Jinx
owns the transport, the sync state machine, the local write queue and
the optimistic overlay, the blob cache, and (optionally) the storage.
Applications supply type declarations, policy (what to keep locally,
which blobs to pin), and the user interface.

Not in scope, now or by design: user interface, HTML sanitization, any
dependence on a particular server implementation's quirks, platforms
other than Apple's, and WebAssembly.  The specification and conformance
tests are meant to outlive the Swift implementation, so they are
expressed as data rather than as Swift tests wherever possible.

## Shape

One package, six library modules plus a test server.  Each lower module
is usable without the ones above it.

```
  App code: SwiftUI, a CLI, a playback engine
  ──────────────────────────────────────────────────────────────
  JinxTypes   sync facts about standard Mail and Tasks types, as data
  Jinx        SyncEngine: push, pull, resync, subscriptions,
              blob cache, change stream.  The public surface.
  JinxStore   SyncStore protocol and its GRDB implementation
  JinxPatch   diff, apply, rebase and owned-key merge, pure
  JinxWire    session, request builder, back-references, typed
              errors, HTTP transport, EventSource, blob transfer
  JinxJSON    JSONValue, the one JSON representation; JSON pointers

  JinxScriptedServer   an in-process JMAP server for tests, beside the
                       stack; depends on JinxWire and JinxPatch
```

All three consumers use the whole stack.  NerfJournal was going to
implement `SyncStore` over its own todo table, but that would mean
rewriting the GRDB store under different column names and owning the
bugs; decided 2026-10-17, it uses Jinx's GRDB store instead, co-located
in its own database file beside its client-only tables.

## The core model

Every synced object is a cell with three parts and a possible log entry.

- **Server snapshot.**  The last full JSON object the server is known to
  hold, exactly as fetched, including properties the app does not model.
  Null for an object the server has not yet seen.
- **Local value.**  What the app reads.  In Jinx's own store this is also
  JSON, and it equals the snapshot unless there is a pending change.  In
  an app-owned store it may be the app's row shape, encoded to JSON on
  demand.
- **Fetch level.**  Which property set the local copy holds: summary or
  full.  See "Partial fetch".
- **Pending entry**, at most one per object, in an ordered log: create,
  update or destroy, plus a claim (process id and time) while a push is
  in flight.  The entry stores no patch.

The patch is computed at push time as the diff between the server
snapshot and the local value.  Several edits collapse into one patch; an
edit that restores the server value produces an empty patch and drops
out; undo is just another edit.  This is NerfJournal's design, taken
from Fastmail's offline caching proxy, and it is adopted whole.

On pull, an object with a pending entry is **rebased**: compute the
patch from the old snapshot to the local value, apply it to the fetched
object, and store the fetched object as the new snapshot.  A pending
local property wins until it is pushed; every other property takes the
server's value.  If the rebased value equals the fetched object, the
server already has the change and the entry is dropped.  Rebase works at
JSON patch-path granularity, so it needs no per-type code, and it is the
whole of the default conflict policy.  It gives Juke its last-write-wins
and NerfJournal its property-level merge without either asking for
anything special.  A per-type resolver hook can be added later without
changing the model.

## Scope of the mirror

Each type is synced in one of two modes.

**Full.**  Every object of the type is held locally.  Initial sync pages
through `Foo/query` with no filter and fetches in chunks of
`maxObjectsInGet`; when the server allows it, `Foo/get` with `ids: null`
is a single step.  Each chunk commits on its own and is reported on the
change stream, and the engine's status marks the type as partial, with
a fetched-of-total count, until the last chunk lands, so an app can
draw what it has rather than wait for 45k tracks.  After that,
`Foo/changes` keeps the set current.  Juke's Track and Playlist and
NerfJournal's Task are full.

**Windowed.**  The type is too large to hold.  What is held is decided by
**subscriptions**, of two kinds:

- A **query subscription**: filter, sort, position and limit, with the
  result as an ordered id list and a total.  Refreshed with
  `/queryChanges` where the server reports `canCalculateChanges`, and
  otherwise by re-running `/query` and diffing the id lists locally,
  which is the common case and must be the well-trodden path.
- A **pin**: a set of ids the app wants held regardless of any query.

An object is **retained** while any live subscription references it, it
is pinned, it has a pending entry, or a retained object references it
through a declared id property.  That last rule is how a held Email
keeps its Thread: the engine fetches referenced objects in the same pass
as their referrer, and lets them go when nothing refers to them.  Everything else is evictable, and
a per-type policy (least recently read, under a count cap) decides when.
`Foo/changes` on a windowed type is applied as: updated ids that are held
are refetched, destroyed ids are removed, and created ids are ignored
because the query subscriptions will surface them, unless an unbounded
subscription exists (below), in which case they are fetched.  A full
mirror is the degenerate case of one unbounded query subscription with
no eviction, and the engine treats it that way internally.

### Moving between the modes

The mode is not fixed per type; it is a question of which subscriptions
exist, and an app can change it at runtime (decided 2026-10-17).  The
expected case is mail on a new device: Email starts windowed so work can
begin at once, and the app later adds the unbounded subscription so a
background fill makes the account fully available offline hours later.
The fill is the full-mode initial sync, chunked and committed per chunk
with partial status, and the app can pause it by policy, for example
off power or off wifi.  While a fill is in progress, created ids from
`/changes` are fetched rather than ignored, because the fill's paging
covers only what existed when it started, and `/changes` must cover
the rest; without this rule a message arriving during a long fill would
be lost.  Removing the unbounded subscription takes the type back to
windowed, and everything not otherwise retained becomes evictable.

Mail's Mailbox is full; Email and Thread are windowed, since a large
account has nearly as many Threads as Emails.  An app can begin work
after the first pass: the mailbox list is complete, and the inbox is as
complete as its first query subscription.

### Partial fetch

A type may declare a **summary** property set and a **full** one.  Query
and change handling fetch the summary set.  The app asks for the full
set by id when it needs it (an Email body), and the engine records the
fetch level so a later change to the object refetches at the same
level.  The level is part of the retention policy: a windowed object can
be demoted to summary before it is evicted.

### Sync order between types

A type descriptor may declare that it depends on other types.  Pulls
fetch in dependency order within one JMAP request, and pushes send in
that order too.  This satisfies Juke's Track-before-Playlist rule.  It
does not by itself give the mail document's "consistent views", because
Email and Thread reference each other.  That comes from applying every
type's changes from one pull pass in a single store transaction, so a
reader sees the state before the pass or after it, never between.  A
dangling reference, an id the store does not hold, is allowed at the
data level and is not an error; the next pass or a query refresh
resolves it.  Initial sync of a full type is the one exception to
the single-transaction rule, by design: it commits per chunk and says
so through status.

## The sync loop

A pass is triggered by an explicit request, a push notification, a timer
when push is unavailable, a connectivity change, or a local write.  All
triggers are debounced into one pass, and at most one pass runs per
process at a time.

**Push first, then pull**, always.  A resync should run against a server
that already has the client's changes.

### Push

1. Claim unclaimed log entries in one transaction.  Read the claimed
   entries in order and snapshot each object's local value and server
   snapshot in memory.
2. Build one request with a `/set` per type, in dependency order.
   Creates send the full local value under a client-chosen creation id;
   updates send a patch, and an empty patch means the entry is dropped;
   destroys send the id.  A create that references another pending
   create of the same type uses `#creationId` references within that
   `/set` call.

   References to a pending create of another type (an Email filed into a
   Mailbox that is itself pending) are represented from the start but
   not sent until a later phase, decided 2026-10-17.  The creation id
   is the local id of a pending create, so it can appear inside another
   object's properties and be rewritten when the real id arrives.  What
   is deferred is the engine work: ordering such creates across types
   in one request, and holding a dependent change back when the create
   it references fails or is retried.  Until then, a write that
   references a pending create of another type is refused with a clear
   error.  Mail is the likely first consumer, so this lands with the windowed-mode phase.
3. Send.  On transport failure or `serverUnavailable`, release the
   claims and retry with backoff.
4. Apply the response in one transaction: set ids for `created`, set the
   snapshot for `created` and `updated` to what was sent merged with any
   server-set properties returned, delete rows for `destroyed` and for
   `notDestroyed` with `notFound`, classify everything else as an error
   (below), advance the type's state only if `oldState` matches the
   stored one and otherwise flag a pull, and delete the sent entries.
   An entry re-added by an edit during the request has a later sequence
   number and is left for the next push.
5. Repeat while unclaimed entries remain.

### Pull

1. One request: for each type in dependency order, `/changes` with the
   stored state, then back-referenced `/get` calls for created and
   updated ids (full types), or `/get` for updated held ids plus a
   `/queryChanges` or `/query` per subscription and `/get` for ids not
   held (windowed types).  Chunk `/get` calls to `maxObjectsInGet`.
2. Discard the response and pull again if any `oldState` does not match.
3. Apply in one transaction across all types: insert new objects, replace
   unchanged ones, rebase pending ones, defer any object whose push is in
   flight in another process, remove destroyed objects along with their
   pending entries, update subscription id lists, advance states, and
   compute the change set.
4. Emit the change set after commit.  Loop while any `hasMoreChanges`,
   with a cap on passes after which the type is resynced instead.

### Resync

On `cannotCalculateChanges`, or any error the engine cannot interpret as
a state it knows: forget the type's state but do not wipe local data,
refetch (initial sync for full types; subscription refresh for windowed
ones), apply with rebase, and delete objects the server did not return
that have no pending create.  Objects the server has never seen are
never deleted by a resync.  The mirror is never half-updated from a
reader's point of view, because the apply is one transaction.

### Push notifications

An EventSource connection with reconnect and backoff, with a polling
interval as the fallback.  A `StateChange` sets a pull-needed flag per
type; the pass runs after a short quiet period.  Only one process per
database holds the connection, chosen by the app.  iOS background
refresh is the app's job, through the same "run a pass" entry point.

## Writes

The write API is small: create an object of a type from a JSON value,
update by id, destroy by id, and a transaction that groups any number
of these so a bulk operation such as NerfJournal's sweep becomes one
log batch and one `/set` per type.  Creates return a stable local key
immediately; the JMAP id arrives through the change stream when the
push succeeds.

An update takes one of three forms: a patch, applied to the current
local JSON; a closure that mutates the current local JSON in place; or
a **replacement encoding**, which merges only the type's declared
**owned properties** from the encoding into the current JSON, adding,
changing and removing those keys and touching nothing else.  The third
form is for apps with a codec from their own model to the wire shape.
It must be scoped to the owned set, because the local value is the full
server object; diffing it against an encoding that mentions only the
app's properties would emit a removal for every property the app does
not model and delete other clients' data on the server.  This was
caught by NerfJournal's agent on 2026-10-17.

Two bulk entry points sit beside these: **adopt**, which takes existing
local objects as pending creates for an import or a one-time migration;
and **wipe**, which discards every object, log entry and state string
for a factory reset.

Writes live in Jinx rather than in a separate layer, decided 2026-10-17.
Optimistic overlay needs the sync layer to know what is pending, so a
write path outside it cannot work.  What the mail document wanted from
its read-only split survives in two forms: mail verbs such as move, flag
and archive are a thin module of named functions over this API, which is
the small auditable thing; and a read-only handle type exposes reads and
the change stream with no write methods, so an experiment that only
reads is checked by the compiler rather than by convention.

**Errors** are classified per item after fanning any method-level error
out to every item in the call.  Retryable (`serverFail`,
`serverUnavailable`, `stateMismatch`, `rateLimit`, transport): keep the
entry, back off.  Permanent (`invalidProperties`, `notFound`,
`forbidden`, `invalidPatch`): revert that object alone to its snapshot,
record the error on it, delete its entry, and report it.  Edits made
after the failed request was sent are never reverted, which is the place
NerfJournal's study found Fastmail's in-memory layer gets wrong.

**Idempotent creates.**  A create whose response is lost would be sent
twice.  A type descriptor may name a **client identity** property, such
as Task's `uid`, and a filter that finds an object by it.  Before
resending a create after an ambiguous failure, the engine queries by
that property and adopts the existing id if found, and it treats
`alreadyExists` and an `invalidProperties` naming that property as the
same answer.  Adoption fills in the JMAP id on the existing row; the
local key never changes, so nothing in the app's tables or UI moves.  A type with no client identity accepts the duplicate risk,
and the documentation says so.

**Foreign properties survive** because every write form above changes
only what it names, the snapshot is the object as fetched, and the diff
between them therefore mentions only what the app changed.  The diff
recurses into objects and emits per-entry patches, so a map such as
Task's `keywords` or `links` keeps entries other clients put there; it
never recurses into arrays.  A `mayPatch(path)` veto per type falls
back to replacing a whole subtree where patching inside it would be
ambiguous.

## Blobs

A blob store keyed by blobId, separate from the object store, with its
own policy.

- A blob is absent, partial (a set of byte ranges on disk), or complete,
  and is flagged pinned or cached.  Eviction is least recently used
  under a byte cap, over cached blobs only.  Files live in Application
  Support with do-not-back-up set, both configurable.
- Download uses range requests and resumes partial files, which is safe
  because blobs are immutable.  Upload returns the blobId for use in a
  later create.
- A type descriptor declares which properties hold blobIds.  When a pull
  changes one, the change set carries a blob-superseded event with the
  old and new ids, and the app's policy decides whether to re-pin.  This
  is Juke's retagging case.
- A not-found on download is reported as blob-gone, and the engine
  schedules a refetch of the objects that referenced it.
- Ranged reads of a partial blob are exposed so that an app can feed an
  `AVAssetResourceLoaderDelegate`, which stays in the app.

## Storage

**`SyncStore`** is an async protocol with one transactional entry point
and these responsibilities: objects (get, put, delete; snapshot, local
value, fetch level, last error), the pending log (append, claim with a
staleness timeout, release, delete), per-type state strings, subscription
definitions and their id lists, retention metadata, and the blob index.
Handles are opaque to the engine.  The protocol is public from the
first release, decided 2026-10-17; its stability is part of the
library's contract, and no current consumer implements it.

**`GRDBSyncStore`** is the implementation every current consumer uses.
It owns tables with a `jinx_` prefix, stores JSON as text, and registers
its schema as a migration on a migrator the app supplies, so it can
share the app's database file or have one of its own.  Sharing a file
is the recommended shape for an app with client-only data: its own
tables and Jinx's commit in one transaction.  Every object row has a
stable Int64 local key that never changes, with the JMAP id as a
nullable column filled in when the server assigns it, so an app's own
tables can reference an object from the moment it is created with no
rewriting when the create succeeds; lookup by JMAP id is also available.  It is safe for two
processes on one WAL-mode file: short transactions, claims rather than
locks.  Apps may run read-only SQL against the `jinx_` tables, and that
layout is documented and versioned.

Reads from the engine are by local key or JMAP id, by id set, by
subscription (an ordered id list plus total), and all objects of a type
in one call, for apps small enough to filter in memory.  Every read
returns the local value with its sync metadata: JMAP id if known,
pending state, and last error.  Beyond that, queries are the app.s
business.  The engine also exposes a status value for a settings pane:
connected or offline, last pull, pending count, and per-object errors.

**Change stream.**  An `AsyncStream` of change sets, emitted after each
commit.  Each commit also appends its change set to a journal table and
posts a Darwin notification named for the database file, so an engine
in another process wakes, reads the journal rows it has not yet seen,
and emits them on its own stream.  Both processes see identical change
sets, and an app with a CLI and a GUI on one file needs no signaling of
its own.  A change set names created, updated and destroyed ids per type,
subscriptions whose id lists changed, pending entries that failed, and
blob events.  There are no SwiftUI types anywhere in Jinx.

## Types

A **type descriptor** carries: the JMAP type name, the capability URN,
the account type it lives in, the sync mode, dependencies, the summary
and full property sets, which properties hold ids of which types, which
hold blobIds, the client identity property and its filter, the owned property set
that a replacement encoding may touch, and the `mayPatch` veto.

JSON is represented by a `JSONValue` enum that is `Sendable`,
`Equatable` and `Codable`, never `[String: Any]`.  Every object the
engine hands out is a `JSONValue` wrapped in a type that knows its
descriptor.

A descriptor also carries extra `/get` arguments merged into every fetch
of the type, because standard types have them: Email's `bodyProperties`,
`fetchHTMLBodyValues` and `maxBodyValueBytes` are the reason.

Typed Swift models of standard types belong to the apps, decided
2026-10-17: Task's lenient-read rules and codec are NerfJournal's, an
`Email` struct is the mail client's.  Jinx is generic over JSON and no
part of the engine needs a typed wrapper.  What JinxTypes ships is the
sync-relevant facts about standard types as data, a few lines each:
name, capability, dependency order, owned properties, client identity,
the patch veto.  Those come from the RFCs rather than from any app, are
easy to get subtly wrong (CalendarEvent must veto patches inside
`recurrenceOverrides`; Task's `uid` is its identity), and are what a
conformance suite checks a client against.  JinxTypes is reference
data, not a type library.

The `@JMAPObject` macro is deferred, same decision.  With models
downstream and a descriptor five lines by hand, the macro would only
generate accessors over JSON for an app's own types, at the cost of a
swift-syntax dependency on every build.  It returns when a consumer,
probably Juke declaring Track, feels the pain.

## Concurrency and platform

Swift 6 language mode with strict concurrency.  The engine is an actor;
store and transport calls are async; the change stream is consumed off
the actor.  Jinx is also consumable from Swift 5-mode code.

Consumers will use Xcode 27's default-MainActor isolation, so Jinx is
written to be called from MainActor-isolated code without forcing the
caller elsewhere (decided with NerfJournal's agent, 2026-10-17):

- Every public type that crosses the boundary is a `Sendable` value
  type: change sets, read results, patches, encodings, descriptors.
  `JSONValue` is the only JSON representation on the public surface;
  `[String: Any]` never appears there.
- Public API that runs off the main actor is marked `nonisolated`
  explicitly, so a MainActor-default module reads it correctly.
- The change stream is an `AsyncSequence` of `Sendable` elements, meant
  for `for await` from a MainActor task.  There is no Combine, and no
  NotificationCenter as a primary API.
- The engine and the GRDB store are never MainActor-isolated; an app
  holds one engine per process and injects it into its stores.
- Closure-form updates take a `@Sendable` closure from `JSONValue` to
  `JSONValue`, never one that mutates captured state.
- No API asks the app for a class type, so no consumer needs
  `@unchecked Sendable`.
- Migration registration is a synchronous call on the app's GRDB
  migrator from its own setup code.

The platform floor is iOS 27 and macOS 27, decided 2026-10-17.  RJBS is
the whole user base, and NerfJournal is raising its own floor to match.
Nothing in sync strictly needs an OS that new, but the floor means no
availability annotations, and it makes `ProgressManager` and
`Subprogress` available for reporting initial sync and blob download
progress.

## Testing

Three tiers, sharing one script format wherever two tiers can.

1. **Unit tests** on the pure pieces: patch and rebase, request building
   and back-references, error classification, the store.
2. **Scripted server tier.**  A test is data: a sequence of server states
   and client operations, with assertions on the store and the change
   stream after each step.  An in-process server holds the data and
   computes real responses, including `/changes` between any two states
   it has held.  It is a small but correct JMAP server, and it gets its
   own specification so that it can be reimplemented later.  To keep it
   small it serves generic test types (a few scalar properties, a
   reference between types, a blob property, a trivial filter and sort
   vocabulary) rather than Mail or Tasks.  This tier is fast and
   deterministic.
3. **Conformance tier.**  The same scripts run against a separately
   running reference server, a later reimplementation of the tier 2
   server in a portable language, probably Go.  A driver protocol the
   client under test implements lets other JMAP clients run the corpus.

The hard cases the mail document lists are the first scripts: lost or
invalid state, changes arriving mid-sync, destroy and recreate, an Email
moving between Mailboxes, interrupted syncs.  To those add: a lost create
response, a push and pull racing in two processes, a changed blobId, and
a query subscription on a server without `canCalculateChanges`.

Scripts never contain canned responses.  A script step is one of four
kinds: a server state transition, a fault, a client operation, or an
assertion about what the client believes.  Faults are named behaviors
with parameters, applied as interceptors on the stateful server, for
misbehavior a correct server never produces: `cannotCalculateChanges` on
the next `/changes`, a `/set` response dropped after it was applied, a
wrong `oldState`, a tiny `maxObjectsInGet`.  Client operations are a
small JSON instruction set, roughly "write this to the local store",
"process the pending event stream", "synchronize type X".

The test script format and the driver protocol are their own design,
still to be worked out with RJBS, and will live in `doc/testing.md`.  The exact
format is expected to surface from writing the first concrete tests,
not from designing it in advance, so it waits until phase 2 (decided
2026-10-17).

## Order of work

Each phase ends with something a consumer can use.

0. Package skeleton, modules, CI, the documents above.  Done 2026-10-17,
   except CI, which waits for a remote.
1. **JinxWire and JinxPatch** with unit tests.  NerfJournal can start
   consuming these for its codec work.  Done 2026-10-17.
2. **SyncStore, the engine in full mode, GRDBSyncStore**: push, pull,
   resync, state handling, EventSource, error classification, claims.
   This completes NerfJournal's needs and Juke's metadata sync.  Done
   2026-10-17, including the run loop and cross-process delivery; the
   scripted server exists but the script format does not yet.
3. **JinxTypes**: per-type `/get` arguments on the descriptor, and the
   Mail and Tasks descriptors as data, tested against the scripted
   server.  No macro.  Done 2026-10-17.
4. **Windowed mode**: query subscriptions, retention and eviction,
   partial fetch.  Moved ahead of blobs on 2026-10-17 because a mail
   client against Fastmail is the likely first consumer, and a real
   account is far too big for full-mirror Email.  Bodies come through
   `Email/get`, so mail does not need blobs to start.
5. **Blobs**: the blob store, ranged download and resume, invalidation.
   Juke's phase 1 (pinned downloads) is possible here.
6. **Scripted-server tier**, then the conformance tier against the
   reference server.  The scripted tier should begin alongside phase 2
   rather than after it, since it is how phase 2 gets tested.

## Decisions needed

- [ ] The test script format and driver protocol, to be designed next.
