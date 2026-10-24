# 5. The synced object

Unit 1 listed "your own writes are in flight" as a problem the
protocol leaves to the client.  Here is why it is the central one.

The obvious design for an offline-capable client is a queue of
requests.  The user edits a task; the app appends a `Task/set` to the
queue; when the network is back, the queue drains.  It is simple and
it fails in every direction at once.  Edit the same task three times
and three requests go, each racing the last.  Change your mind and
there is no way to cancel the first without replaying the queue.  A
sync-in that arrives while the queue holds a change to the same object
either overwrites the user's edit or has to be held back.  And when a
request fails permanently, there is no record of what the object
looked like before it, so nothing can be reverted.

Jinx does not queue requests.  It records, for each object, what the
server has and what the app wants, and derives the request from the
difference at the last possible moment.  Everything in units 6 to 10
is built on this, so it gets a unit of its own.

## The parts

A synced object in the store is a `StoredObject`, and it has six
parts.

- **`key`**, a `LocalKey`.  An `Int64` assigned when the object first
  exists locally, whether it came from the server or from a local
  create, and never changed afterward.  An app's own tables reference
  objects by this, so nothing in them moves when the server later
  assigns an id.
- **`id`**, the JMAP id, or `nil` until the server assigns one.
- **`snapshot`**, the object as the server last reported it, exactly
  as fetched, including properties the app does not model.  `nil` if
  the server has never seen this object.
- **`local`**, the object as the app sees it.  Equal to the snapshot
  unless there is a pending change.
- **`pending`**, which is `nil` or one of `create`, `update` and
  `destroy`.  When it is not `nil`, there is exactly one matching
  entry in the pending log.
- **`lastError`**, the `SetError` from the last permanent failure to
  sync out this object, or `nil`.

<figure class="jinx-figure">
<svg viewBox="0 0 760 236" width="760" height="236" role="img" aria-labelledby="states-title">
<title id="states-title">Three synced objects in three states</title>
<rect class="blk" x="20" y="16" width="220" height="200" rx="4"/>
<text class="nm" x="130" y="42" text-anchor="middle">fetched, unchanged</text>
<text class="sub" x="36" y="74"><tspan>id</tspan><tspan x="112">"t1"</tspan></text>
<text class="sub" x="36" y="98"><tspan>snapshot</tspan><tspan x="112">{title: "Draft"}</tspan></text>
<text class="sub" x="36" y="122"><tspan>local</tspan><tspan x="112">{title: "Draft"}</tspan></text>
<text class="sub" x="36" y="146"><tspan>pending</tspan><tspan x="112">nil</tspan></text>
<text class="sub" x="36" y="186">what the app reads is what the</text>
<text class="sub" x="36" y="202">server has</text>
<rect class="blk" x="270" y="16" width="220" height="200" rx="4"/>
<text class="nm" x="380" y="42" text-anchor="middle">edited locally</text>
<text class="sub" x="286" y="74"><tspan>id</tspan><tspan x="362">"t1"</tspan></text>
<text class="sub" x="286" y="98"><tspan>snapshot</tspan><tspan x="362">{title: "Draft"}</tspan></text>
<text class="sub" x="286" y="122"><tspan>local</tspan><tspan x="362">{title: "Draft 2"}</tspan></text>
<text class="sub" x="286" y="146"><tspan>pending</tspan><tspan x="362">update</tspan></text>
<text class="sub" x="286" y="186">the sync-out will send the diff of</text>
<text class="sub" x="286" y="202">snapshot to local</text>
<rect class="blk" x="520" y="16" width="220" height="200" rx="4"/>
<text class="nm" x="630" y="42" text-anchor="middle">created locally</text>
<text class="sub" x="536" y="74"><tspan>id</tspan><tspan x="612">nil</tspan></text>
<text class="sub" x="536" y="98"><tspan>snapshot</tspan><tspan x="612">nil</tspan></text>
<text class="sub" x="536" y="122"><tspan>local</tspan><tspan x="612">{title: "New"}</tspan></text>
<text class="sub" x="536" y="146"><tspan>pending</tspan><tspan x="612">create</tspan></text>
<text class="sub" x="536" y="186">the sync-out will send local whole,</text>
<text class="sub" x="536" y="202">under creation id "jinx42"</text>
</svg>
<figcaption>The key is constant across all three; the id and snapshot arrive when the server has seen the object.</figcaption>
</figure>

The log entry, a `PendingEntry`, carries the key, the operation, a
sequence number, and a claim: the id of the process that is currently
syncing it out and when it claimed it.  The entry stores no patch.  That
omission is the design.

## The patch is computed at sync-out time

When the sync-out runs, it diffs the snapshot against the local value,
with the type's `MayPatch` veto, and that diff is what goes in the
`/set`.  Nothing is recorded at edit time except that the object is
pending.  Four things follow.

**Edits collapse.**  Three edits to one object before a sync-out are one
entry and one patch, from the snapshot to wherever the edits ended up.

**Reverting drops the entry.**  If an edit brings the local value back
to JMAP equivalence with the snapshot, the write path clears the
pending entry.  There is nothing to send.  Undo is not a feature of
Jinx; it is just another edit, and it works because the baseline is
still there.

**A no-op edit is not an edit.**  An update whose result is JMAP
equivalent to the current local value changes nothing, records
nothing, and emits nothing on the change stream.

**The baseline is always right.**  The snapshot is, by construction,
the server state the local value was edited against.  That is what
rebase in unit 4 needs, and it needs nothing else.

Here is the write path for an update, from `Writer.update`, reduced
to its decisions:

```swift
var newValue = try transform(object.local)
guard !newValue.isJMAPEquivalent(to: object.local) else { return }
object.local = newValue
object.lastError = nil
switch object.pending {
case .create:
  break                       // the create will send the current value
case .update, nil:
  if let snapshot = object.snapshot, newValue.isJMAPEquivalent(to: snapshot) {
    try tx.clearPending(key: key)
  } else {
    try tx.setPending(key: key, operation: .update)
  }
case .destroy:
  throw SyncError.objectIsBeingDestroyed(key.description)
}
```

A create sends the whole local value, so an edit to a pending create
changes nothing about the entry.  Destroying an object the server has
never seen, and that no sync-out is currently sending, simply deletes the
row: there is nothing to tell the server.  Destroying any other object
sets the entry to `destroy`, and a later update to it is refused.

## What a sync-in does to each state

When a sync-in fetches an object that is already held, what happens
depends on `pending`.  This is `applyFetched` in `SyncIn.swift`.

| `pending` | Effect |
|---|---|
| `nil` | Snapshot and local both become the fetched object. |
| `update` or `create` | Rebase: the pending patch is recomputed from the old snapshot and local, the snapshot becomes the fetched object, and local becomes the fetched object with the patch applied.  If the result equals the fetched object, the server already has the change and the entry is cleared. |
| `destroy` | The snapshot becomes the fetched object; local is untouched; the destroy still goes. |
| any, claimed by another process | Skipped.  The process holding the claim will reconcile when its sync-out completes, and touching the object now would race it. |

A `create` can be rebased because a lost create response, in unit 9,
can leave an object with a snapshot and a `create` entry at once.

There is one more branch.  If the fetched object's id is not held but
the type declares a client identity, such as Task's `uid`, and a local
object with no id has the same value for it, the fetched object is the
server's answer to a create whose response was lost.  The local
object adopts the id, the local value is rebased onto the fetched
one, and the change stream reports the id assignment.  The key does
not change.

## What a sync-out does to each state

A successful create or update sets the snapshot to what was sent,
merged with any server-set properties the response returned, and sets
local to match.  A successful destroy deletes the row.  A permanent
failure, in the classification of unit 9, reverts local to the
snapshot, records the error in `lastError`, and clears the entry; the
app's next read sees the server's value and the reason.

Unless the object was edited while the request was in flight.  An
edit during a sync-out appends a new entry with a later sequence number,
and the sync-out response confirms only the entry it sent.  The new
local value is kept and the new entry waits for the next sync-out.  On a
permanent failure the same rule holds: the edit made after the send
is never reverted, because the user made it against what they saw,
and what they saw was not wrong.

!!! info "Not yet as designed"
    The plan describes a fetch level per object, summary or full, so
    that a later change refetches at the level the object was last
    fetched at.  The code has no such field; a windowed object fetched
    with extra properties by `fetch(_:ids:arguments:)` is refetched
    with the type's summary properties on the next change.  Thread
    2026-10-17-pm2sqs.

## What the app sees

The engine never hands out a `StoredObject`.  Reads return a
`SyncedObject`: the key, the type, the id if there is one, `value`,
which is the local value, `pending`, and `lastError`.  The snapshot
is not there, because no app has needed it and exposing it invites an
app to do its own conflict handling against it.  `pending` is there
so that a list row can show that an item has not reached the server
yet, and `lastError` so that it can say why.

## Where to look

- `Sources/JinxStore/Records.swift` defines `StoredObject`,
  `PendingEntry` and `LocalKey`.  `Sources/Jinx/Writes.swift` is the
  write path, and `applyFetched` in `Sources/Jinx/SyncIn.swift` is the
  table above as code.
- `swift test --filter JinxTests.SyncOutTests`.
  `editsCollapseAndRevertingDropsTheEntry` is the second consequence
  above; `rebaseKeepsPendingPropertyAndTakesTheRest` and
  `pendingChangeTheServerAlreadyHasIsDropped` are the sync-in table's
  second row; `destroyOfUnsentObjectIsLocalOnly` is the row deletion.

Next: [The store](06-store.md).
