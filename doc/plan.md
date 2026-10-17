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

One package, five modules.  Each lower module is usable without the ones
above it.

```
  App code: SwiftUI, a CLI, a playback engine
  ──────────────────────────────────────────────────────────────
  JinxTypes   @JMAPObject macro; standard Mail and Tasks types
  Jinx        SyncEngine: push, pull, resync, subscriptions,
              blob cache, change stream.  The public surface.
  JinxStore   SyncStore protocol and its GRDB implementation
  JinxPatch   JSONValue; diff, apply and rebase as pure functions
  JinxWire    session, request builder, back-references, typed
              errors, HTTP transport, EventSource, blob transfer
```

NerfJournal uses JinxWire, JinxPatch and the engine with its own
`SyncStore`, because its local row shape is its own.  Juke and the mail
experiments use the whole stack.

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
`maxObjectsInGet`, reporting progress as (fetched, total); when the
server allows it, `Foo/get` with `ids: null` is a single step.  After
that, `Foo/changes` keeps the set current.  Juke's Track and Playlist and
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
is pinned, or it has a pending entry.  Everything else is evictable, and
a per-type policy (least recently read, under a count cap) decides when.
`Foo/changes` on a windowed type is applied as: updated ids that are held
are refetched, destroyed ids are removed, and created ids are ignored
because the query subscriptions will surface them.  A full mirror is the
degenerate case of one unbounded query subscription with no eviction,
and the engine treats it that way internally.

Mail's Mailbox and Thread are full; Email is windowed.

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
resolves it.

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
   object.s properties and be rewritten when the real id arrives.  What
   is deferred is the engine work: ordering such creates across types
   in one request, and holding a dependent change back when the create
   it references fails or is retried.  Until then, a write that
   references a pending create of another type is refused with a clear
   error.  Mail is the likely first consumer, so this lands with phase 5.
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
update by id with either a patch or a closure over the current value,
destroy by id, and a transaction that groups any number of these so a
bulk operation such as NerfJournal's sweep becomes one log batch.
Creates return a local handle immediately; the JMAP id arrives through
the change stream when the push succeeds.

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
same answer.  A type with no client identity accepts the duplicate risk,
and the documentation says so.

**Foreign properties survive** because the patch is a diff between two
encodings that mention only the properties the app models, and the
snapshot is the object as fetched.  A `mayPatch(path)` veto per type
falls back to replacing a whole subtree where patching inside it would
be ambiguous.

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
Handles are opaque to the engine, so an app can key by Int64 rowid and
a nullable remote id, as NerfJournal does.  The protocol is public from
the first release, decided 2026-10-17, since NerfJournal implements it
in phase 2; its stability is part of the library.s contract.

**`GRDBSyncStore`** is the implementation most apps will use.  It owns
tables with a `jinx_` prefix, stores JSON as text, and registers its
schema as a migration on a migrator the app supplies, so it can share
the app's database file or have one of its own.  It is safe for two
processes on one WAL-mode file: short transactions, claims rather than
locks.  Apps may run read-only SQL against the `jinx_` tables, and that
layout is documented and versioned.

Reads from the engine are by id, by id set, and by subscription (an
ordered id list plus total).  Beyond that, queries are the app's
business.  The engine also exposes a status value for a settings pane:
connected or offline, last pull, pending count, and per-object errors.

**Change stream.**  An `AsyncStream` of change sets, emitted after each
commit.  A change set names created, updated and destroyed ids per type,
subscriptions whose id lists changed, pending entries that failed, and
blob events.  There are no SwiftUI types anywhere in Jinx.

## Types

A **type descriptor** carries: the JMAP type name, the capability URN,
the account type it lives in, the sync mode, dependencies, the summary
and full property sets, which properties hold ids of which types, which
hold blobIds, the client identity property and its filter, and the
`mayPatch` veto.

JSON is represented by a `JSONValue` enum that is `Sendable`,
`Equatable` and `Codable`, never `[String: Any]`.  Every object the
engine hands out is a `JSONValue` wrapped in a type that knows its
descriptor.

The `@JMAPObject("Track")` macro on a struct generates the descriptor
from the struct's stored properties and attributes, plus typed accessors
over the underlying JSON, so unknown properties are preserved rather than
dropped by `Codable`.  JinxTypes ships descriptors for Mail (Mailbox,
Thread, Email, Identity, EmailSubmission) and Tasks (Task, TaskList).
Everything a consumer needs to declare a type should fit on one screen.

## Concurrency and platform

Swift 6 language mode with strict concurrency.  The engine is an actor;
store and transport calls are async; the change stream is consumed off
the actor.  Jinx is consumable from Swift 5-mode code, which NerfJournal
is.

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

0. Package skeleton, modules, CI, the documents above.
1. **JinxWire and JinxPatch** with unit tests.  NerfJournal can start
   consuming these for its codec work.
2. **SyncStore, the engine in full mode, GRDBSyncStore**: push, pull,
   resync, state handling, EventSource, error classification, claims.
   This completes NerfJournal's needs and Juke's metadata sync.
3. **JinxTypes**: the macro, Mail and Tasks descriptors.
4. **Blobs**: the blob store, ranged download and resume, invalidation.
   Juke's phase 1 (pinned downloads) is possible here.
5. **Windowed mode**: query subscriptions, retention and eviction,
   partial fetch.  The mail experiments start here.
6. **Scripted-server tier**, then the conformance tier against the
   reference server.  The scripted tier should begin alongside phase 2
   rather than after it, since it is how phase 2 gets tested.

## Decisions needed

- [ ] The test script format and driver protocol, to be designed next.
