# 1. Orientation

Jinx is a Swift package that keeps a local copy of the JMAP data in one
account and keeps that copy in sync with the server.  An application
reads from and writes to the local copy.  Jinx synchronizes changes,
merging in changes from the server and sending local writes up to it.
The application layer never sees a JMAP request unless it wants to.

JMAP provides all the primitives needed for an efficient sync engine,
but leaves it to the client developer to understand how to put those
primitives together.  Jinx does that for you, and provides a record
synchronization platform to build on.

## What the protocol leaves to the client

RFC 8620 is exact about the wire protocol, but many complications
emerge when you put the protocol into use, especially in a
multi-writer scenario.  Here are the main complications, along with
where you'll find out how Jinx helps you deal with them.

- **State tracking must be exact.**  `Foo/changes` is only correct if
  the client stored the state from the last response and applied every
  change that came with it, and did both as one step.  A crash between
  the two leaves a client that believes it is further along than it
  is.  Units 6 and 8.
- **The server moves between requests.**  A `/changes` or `/set`
  response reports the state the server was at when it answered.  When
  that is not the state the client holds, something happened in
  between, and the client has to decide whether what it just received
  still applies.  Unit 8.
- **The client's own writes are in flight.**  Between sending a `/set`
  and reading its response, a `/changes` in another request, or a
  `StateChange` on the push channel, can describe the very change the
  client is making, or a different change to the same object.  The
  client has to tell those apart, while the user keeps editing.  Units
  5 and 9.
- **Objects are shared.**  An update is a patch, and a patch that names
  a whole map such as `keywords` replaces every entry in it, including
  the ones another client added.  A client that sends back every
  property it holds, rather than only the ones it changed, overwrites
  the server's newer values with its own stale ones.  Unit 4.
- **A lost response is not a failed request.**  A create whose response
  never arrived may or may not exist on the server.  Sending it again
  may make two.  Unit 9.
- **The server holds more than the client can.**  A mail account does
  not fit on a phone.  `/query` gives an ordered list of ids, and
  `/queryChanges` is optional.  Deciding which objects to hold, when to
  let them go, and how to keep a list current when the server cannot
  calculate changes is the client's problem.  Unit 10.
- **Blobs are immutable but large.**  Download must resume, the cache
  must have a ceiling, and an object whose `blobId` changes must
  invalidate what was cached under the old one.  Unit 11.

Jinx's answers to these are not independent features.  They rest on one
model of what a synced object is, described in unit 5, and most of the
rest of the library is consequences of that model.

## Our example applications

Three applications drove the design, and they recur as examples.  They
are real projects, so some details will lag behind their code; what
matters here is what each one demands of a sync library.

**NerfJournal** is a bullet-journal todo app for macOS, with a GUI and a
command-line tool that share one database file.  It syncs JMAP for
Tasks: hundreds to a few thousand Task objects, every one of them held
locally.  It is the full-mirror case.  It is also the case for two
processes on one database, for creates that must not duplicate when a
response is lost (Task has a `uid` for exactly this), and for leaving
alone the properties that other clients put on a Task.

**Juke** is a music server and an iOS player.  Its types, Track and
Playlist, are its own, not from any RFC.  About forty-five thousand
Tracks of metadata are held in full, and a Playlist is a server-side
query over Tracks, so Track must sync before Playlist.  The audio is
hundreds of gigabytes, of which the device holds a pinned subset plus a
cache.  Juke is the case for application-defined types, declared sync
order between types, blobs, and progress reporting over a long initial
sync.

**MailRoom** is a mail client experiment against Fastmail.  Mailbox is
held in full.  Email and Thread are windowed: held only while a query
the app is showing, or a pin the app has placed, wants them.  MailRoom
is the reason windowed mode exists, the reason an Email body is fetched
separately from its summary, and the reason Jinx has no opinion about
how an app models an Email.

The requirements of all three are gathered in
[`doc/consumers.md`](https://github.com/rjbs/Jinx/blob/main/doc/consumers.md).

## What Jinx is not

Jinx has no user interface and no SwiftUI types.  It does not sanitize
HTML.  It does not know about any particular server's quirks, and a
server that implements the RFCs is the only server it targets.  It does
not ship typed Swift models of Email or Task; those belong to the apps,
and Jinx is generic over JSON.  It has no query language of its own: an
app small enough to filter in memory reads every object of a type, and
a larger one runs SQL against Jinx's tables, whose layout is documented.
And it runs only on Apple platforms, iOS 27 and macOS 27 or later.

## The stack

Jinx is one package with six library modules and a test server.  The
modules form a stack: each one uses only what sits below it, and each
lower module is usable without the ones above.  Type definitions sit on
top and belong to the application.  JinxTypes, the sixth module,
supplies reference definitions for the standard Mail and Tasks types,
with the facts from their RFCs that are easy to get wrong; an app may
use them or write its own.

<figure class="jinx-figure">
<svg viewBox="0 0 760 456" width="760" height="456" role="img" aria-labelledby="stack-title">
<title id="stack-title">The Jinx module stack</title>
<rect class="ext" x="20" y="20" width="460" height="56" rx="4"/>
<text class="nm" x="250" y="43" text-anchor="middle">Application</text>
<text class="sub" x="250" y="63" text-anchor="middle">SwiftUI, a CLI, a playback engine: not part of Jinx</text>
<rect class="ext" x="20" y="92" width="460" height="56" rx="4"/>
<text class="nm" x="250" y="115" text-anchor="middle">Type definitions</text>
<text class="sub" x="250" y="135" text-anchor="middle">the app's; JinxTypes ships reference descriptors for Mail and Tasks</text>
<rect class="blk" x="20" y="164" width="460" height="56" rx="4"/>
<text class="nm" x="250" y="187" text-anchor="middle">Jinx</text>
<text class="sub" x="250" y="207" text-anchor="middle">SyncEngine: sync, writes, subscriptions, blobs, change stream</text>
<rect class="blk" x="20" y="236" width="300" height="56" rx="4"/>
<text class="nm" x="170" y="259" text-anchor="middle">JinxStore</text>
<text class="sub" x="170" y="279" text-anchor="middle">SyncStore protocol, GRDB implementation</text>
<rect class="blk" x="20" y="308" width="300" height="56" rx="4"/>
<text class="nm" x="170" y="331" text-anchor="middle">JinxWire</text>
<text class="sub" x="170" y="351" text-anchor="middle">session, requests, errors, HTTP, EventSource</text>
<rect class="blk" x="336" y="236" width="144" height="128" rx="4"/>
<text class="nm" x="408" y="295" text-anchor="middle">JinxPatch</text>
<text class="sub" x="408" y="315" text-anchor="middle">diff, apply, rebase</text>
<rect class="blk" x="20" y="380" width="460" height="56" rx="4"/>
<text class="nm" x="250" y="403" text-anchor="middle">JinxJSON</text>
<text class="sub" x="250" y="423" text-anchor="middle">JSONValue and JSON pointers</text>
<rect class="ext" x="520" y="236" width="220" height="128" rx="4"/>
<text class="nm" x="630" y="285" text-anchor="middle">JinxScriptedServer</text>
<text class="sub" x="630" y="305" text-anchor="middle">an in-process JMAP server</text>
<text class="sub" x="630" y="321" text-anchor="middle">for tests, beside the stack;</text>
<text class="sub" x="630" y="337" text-anchor="middle">uses JinxWire and JinxPatch</text>
</svg>
<figcaption>A module may use anything drawn below it and nothing beside or above it.</figcaption>
</figure>

| Module | What it holds | Size |
|---|---|---|
| `JinxJSON` | `JSONValue`, the one JSON representation, and JSON pointers | small |
| `JinxWire` | The session, request building, back-references, typed errors, the URLSession transport, EventSource | medium |
| `JinxPatch` | Diff, apply, rebase, owned properties; pure functions over `JSONValue` | small |
| `JinxStore` | The `SyncStore` protocol, the records it stores, and `GRDBSyncStore` | medium |
| `Jinx` | The `SyncEngine` actor: sync-in, sync-out, writes, windowed sync, blobs, the run loop | the largest |
| `JinxTypes` | Reference type descriptors for Mail and Tasks, optional | tiny |
| `JinxScriptedServer` | A small, correct JMAP server that lives in the test process | medium |

The division is not decoration.  An app that only wants to send a
hand-built request can use `JinxWire` alone, and a test of the patch
algebra links nothing but `JinxPatch` and `JinxJSON`.  The test server
sits beside the stack rather than on top of it, so that it can be
reimplemented later without depending on the engine it tests.

## A sync from the outside

Here is the shape of a program that uses the whole stack.  Every line
is expanded somewhere later in the manual; for now, read it for what
it does not contain.

```swift
import GRDB
import Jinx
import JinxStore
import JinxTypes
import JinxWire

let store = try GRDBSyncStore(path: databasePath)

let transport = JMAPClient(
  sessionUrl: URL(string: "https://api.fastmail.com/jmap/session")!,
  authenticator: BearerToken(token)
)

let configuration = SyncConfiguration(accountId: accountId, types: TaskTypes.all)
let engine = try SyncEngine(configuration: configuration, transport: transport, store: store)

Task { await engine.run() }

Task {
  for await changeSet in engine.changes() {
    // created, updated and destroyed objects, by type and local key
  }
}

let key = try await engine.create("Task", [
  "uid": .string(UUID().uuidString),
  "title": "Write the manual",
])
```

There is no request in it.  There is no state string, no `/changes`
call, no `/set`, no response handling.  The app names the account and
the types, opens a database, and says what it wants to happen.

What happens is this.  The run loop fetches the session resource and
runs a first pass.  There is nothing to sync out.  Task has no stored
state, so the sync-in is an initial sync: page through `Task/query` and
fetch the pages with `Task/get`, committing each chunk as it lands and
reporting it on the change stream, until the state string from the
last `/get` can be stored and `Task/changes` can take over.  The create
writes a row to the local store, appends a pending entry to a log,
emits a change set with a `local` source, and asks the run loop for a
pass.  After a short debounce, the sync-out reads the entry, builds
`Task/set` with one create, sends it, and on success writes the server's
id into the row and emits a change set that says so.  If the device is
offline, the entry waits.  If the user edits the task three times
before the sync-out, one patch goes.  If the server has changed the task in
the meantime, the pending edit is rebased onto what the server sent.

None of that is visible in the code above, which is the point.  The
rest of this manual makes it visible.

## Vocabulary

This manual uses the names the code uses.  The ones that recur most:

- A **synced object** is one JMAP object as Jinx holds it, with its
  metadata.  The type is `SyncedObject`.
- A **local key** is the stable `Int64` identity Jinx assigns to an
  object the moment it exists locally.  The **id** is the JMAP id,
  which an object may not yet have.  The type is `LocalKey`.
- A **pending entry** is the record that an object has a local change
  the server has not accepted.  There is at most one per object.
- A **sync pass**, or just `sync()`, is one sync-out followed by one sync-in.
- A **change set** is what the engine emits after each commit: which
  objects changed, from what source.  The type is `ChangeSet`.
- A **type descriptor** is what an app tells Jinx about a type.  The
  type is `TypeDescriptor`.
- A **subscription** is a query the engine keeps current for a windowed
  type.  The type is `QuerySubscription`, and its result is a `Window`.

The [glossary](glossary.md) collects these and the rest.

## Where things live

- The source is under `Sources/`, one directory per module.  The
  [file map](file-map.md) lists every file.
- The tests are under `Tests/`, one target per module.  `swift test`
  runs them all, and most units of this manual name a test that shows
  the behavior described.
- The design is `doc/plan.md`.  Where it describes something not yet
  built, the unit concerned says so in a callout headed "Not yet
  built", with the Loose Thread that tracks it.

Next: [One JSON](02-json.md).
