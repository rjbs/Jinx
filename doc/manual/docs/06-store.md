# 6. The store

"A state string is a promise you must keep."  `Foo/changes` since
state `s41` returns everything that happened after `s41` and reports
`s42`.  If you store `s42` and then crash before applying the changes,
you will never ask for them again, and the objects they described are
wrong on your device until a full resync.  If you apply the changes
and crash before storing `s42`, you ask again and apply them twice,
which is harmless for a sync-in but not for the rebase of a pending
edit.  The only correct order is neither: the changes and the state go
into the database in one transaction, or not at all.

That is one of several things the store has to get right, and the
others are of the same shape.  The pending log and the object it
describes must never disagree.  Two processes sharing a file must not
sync out the same entry twice.  A reader must never see a pass half
applied.  This unit is about the storage layer that makes those
guarantees, and the schema it keeps them in.

## The protocol

`SyncStore` is a protocol with two methods, `read` and `write`, each
taking a closure that receives a `Transaction`.  Everything the engine
does to storage happens inside one of those closures.  A `write` sees
and produces a consistent state, a `read` sees a snapshot, and the
closures are synchronous because the databases they wrap are.  They
run wherever the store runs them, which is never the main actor.

`SyncTransaction` is the larger protocol, and its methods fall into
seven groups.

- **Objects**: get by key, by id, by a list of either, or every
  object of a type; find one by a top-level property value, which is
  how a client identity is looked up; insert, update, delete.
- **The pending log**: set an object's pending operation, which
  replaces any entry it has and moves it to the end of the log; clear
  it; claim every unclaimed entry for a process; release a process's
  claims.
- **Type state**: the state string per account and type.
- **The journal**: append a change set, read the entries after a
  sequence number, and report the latest sequence number.
- **Subscriptions and pins**, for windowed types in unit 10.
- **Blobs**, the index of what is on disk, in unit 11.
- **Wipe**, which discards everything for an account.

The protocol is public and its stability is part of Jinx's contract,
decided when the design settled.  No current consumer implements it;
all three use the GRDB store that ships with Jinx.  It exists so that
an app with unusual storage needs could supply its own without forking
the engine, and so that the engine's tests can be read as a
specification of what storage must do.

## The GRDB store

`GRDBSyncStore` implements the protocol over
[GRDB](https://github.com/groue/GRDB.swift), a Swift SQLite toolkit.
It is a value type holding a `DatabaseWriter`, and there are three
ways to make one.

```swift
// Its own file.  Opens a WAL-mode pool and runs Jinx's migrations.
let store = try GRDBSyncStore(path: path)

// In memory, for tests.
let store = try GRDBSyncStore.inMemory()

// Inside the app's own database.
var migrator = DatabaseMigrator()
GRDBSyncStore.registerMigrations(in: &migrator)
// ... the app's own migrations ...
try migrator.migrate(pool)
let store = GRDBSyncStore(writer: pool)
```

The third is the recommended shape for an app with client-only data,
and it is what NerfJournal does.  Jinx's tables live in the app's file
beside the app's tables, so a row in the app's table that references a
synced object by key, and the object itself, commit in one
transaction.  Jinx's migrations are registered under names with a
`jinx-` prefix and GRDB runs each once, so registering them on every
launch is the right thing to do.

## The tables

Every table has a `jinx_` prefix, every JSON column is text, and the
layout is documented and versioned so that an app may read it with
SQL.

| Table | What it holds |
|---|---|
| `jinx_object` | One row per synced object: `key`, `account`, `type`, nullable `id`, nullable `server_version`, `local`, nullable `last_error`. |
| `jinx_pending` | The log: `seq`, `key`, `operation`, `claimed_by`, `claimed_at`.  One row per object at most. |
| `jinx_server_state` | The server state string per `(account, type)`. |
| `jinx_subscription` | A query subscription's definition and, separately, its last result. |
| `jinx_pin` | Pinned ids per `(account, type)`. |
| `jinx_blob` | The blob index: total length, the byte ranges on disk, pinned flag, last access. |
| `jinx_journal` | One row per committed change set, with the process that committed it. |

Three details of `jinx_object` carry design weight.

The key is `INTEGER PRIMARY KEY AUTOINCREMENT`.  With `AUTOINCREMENT`,
SQLite never reuses a key after its row is deleted, so a stale
reference in an app's own table can dangle but can never point at a
different object than it meant.

The unique index on `(account, type, id)` is partial, `WHERE id IS NOT
NULL`, so any number of locally created objects can wait for their
ids without colliding.

And the pending operation is not a column of `jinx_object` at all.  A
`StoredObject` is read with a `LEFT JOIN` to `jinx_pending`, so the
`pending` field the engine sees and the log entry the sync-out will claim
are the same row and cannot disagree.  The log's `key` column
references the object with `ON DELETE CASCADE`, so deleting an object
takes its entry with it.

## The log and its claims

`setPending` deletes any entry for the key and inserts a new one, so
the entry gets a fresh `seq` and the object moves to the end of the
log.  That is the mechanism behind the edited-in-flight rule of unit
5: a sync-out claims entries by `seq`, an edit during the sync-out re-adds the
entry with a later `seq`, and when the response arrives the sync-out
confirms the entry it sent and finds the newer one still waiting.

A claim is one SQL statement:

```sql
UPDATE jinx_pending SET claimed_by = ?, claimed_at = ?
WHERE account = ? AND (claimed_by IS NULL OR claimed_at < ?)
```

Because it is one statement in one transaction, two processes that
both try to sync out at the same moment cannot both claim the same entry.
The second condition handles a process that claimed entries and then
died: after `claimStaleAfter`, two minutes by default, its claims are
treated as abandoned and another process may take them.  Claims are
how Jinx gets two-process safety without a lock, and they are the
reason the write path in unit 5 checks whether a pending create is
claimed before deciding a destroy can be local.

## One transaction per commit

Everything the engine writes goes through one method, `commit` on
`SyncEngine`:

```swift
let (result, changeSet) = try await store.write { tx in
  var changeSet = ChangeSet(accountId: accountId, source: source)
  let result = try body(tx, &changeSet)
  if !changeSet.isEmpty { try tx.appendJournal(changeSet, processId: processId) }
  return (result, changeSet)
}
emit(changeSet)
if !changeSet.isEmpty, let name = configuration.signalName { DarwinNotification.post(name) }
```

The body is a local write, the application of a `/set` response, or
the application of an entire sync-in across every type.  Whatever it
does, it does in one SQLite transaction along with the journal row
that describes it.  A reader of the database sees the state before
the commit or after it.  The state strings advance in the same
transaction as the objects they describe, which is the promise this
unit opened with.  Only after the commit succeeds is the change set
handed to the change stream and the other process signaled.

Initial sync of a full type is the one deliberate exception, in unit
8: it commits per chunk, so that an app can draw forty thousand
tracks as they arrive, and it says so through the engine's status.

## The change set

A `ChangeSet` is what one commit changed.

```swift
public struct ChangeSet: Sendable, Hashable, Codable {
  public var accountId: String
  public var source: Source                       // .local, .syncOut or .syncIn
  public var types: [String: TypeChanges]         // created, updated, destroyed keys; idsAssigned
  public var failed: [LocalKey: SetError]         // reverted after a permanent sync-out error
  public var subscriptions: [String]              // whose id list or total changed
  public var blobs: [BlobChange]                  // blob-valued properties that now name a different blob
}
```

Objects are named by local key, never by id, because a locally created
object has no id until `idsAssigned` says so.  `source` lets an app
tell its own write echoing back from a server change.  The change set
is `Codable` because it is stored: the journal keeps it as JSON, and
an engine in another process reads it from there.  A comment at the
top of `Records.swift` records the rule that follows: a field added
to any stored record must decode as optional with a default, or every
database written before the field existed stops opening.

## Two processes, one file

NerfJournal has a GUI and a command-line tool on one database, and
each runs its own `SyncEngine` with its own process id.  Four things
make that safe.

1. The file is opened as a `DatabasePool` in WAL mode, so readers do
   not block the writer and transactions are short.
2. Claims, above, keep the two from syncing out the same entry.
3. Every commit appends to the journal and posts a Darwin
   notification named for the file.  The other engine wakes, reads the
   journal rows after the last one it saw, skips any it committed
   itself, and emits the rest on its own change stream.  Both
   processes see identical change sets.
4. A sync-in in one process skips any object whose entry is claimed by
   the other, as unit 5 described, and leaves it for that process to
   reconcile.

Unit 12 covers the wake-up side.  The point here is that the store
needs nothing beyond SQLite's own locking, because every cross-process
question is answered by a row.

## Reading

The engine's reads return `SyncedObject` values: by key, by id, by a
list of keys, or every object of a type in key order, for an app small
enough to filter in memory.  For anything else, the app runs SQL.
The `local` column is the value the app would see through the engine,
pending edits included, and SQLite's JSON functions work on it:

```sql
SELECT key, json_extract(local, '$.title')
FROM jinx_object
WHERE account = ? AND type = 'Task'
  AND json_extract(local, '$.keywords.urgent') = 1
```

Reads of this kind must stay read-only.  A write that bypasses the
engine leaves no pending entry, so it would never be synced out, and it
could not be rebased.

## Where to look

- `Sources/JinxStore/SyncStore.swift` is the protocol;
  `GRDBSyncStore.swift` the implementation, with the schema at the top;
  `Records.swift` the value types the protocol speaks.
- `swift test --filter JinxStoreTests`.  `pendingLogReplacesAndOrders`
  is the moving-to-the-end rule; `claimsSkipFreshClaimsAndTakeStaleOnes`
  is the claim statement; `twoStoresOnOneFileSeeEachOther` opens the
  same file twice.  In `JinxTests`, `twoProcessesSyncOutWithoutSendingTwice`
  runs two engines against one store and one server.

Next: [Describing a type](07-type-descriptors.md).
