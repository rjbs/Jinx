# Glossary

The words this manual uses are the words the code uses.  Each entry
names the type or function where there is one.

**Change set** (`ChangeSet`).  What one commit changed: created,
updated and destroyed objects by type and local key, ids assigned,
objects whose push failed, subscriptions whose result changed, and
blob changes.  Emitted on the change stream and stored in the journal.
Unit 6.

**Change stream** (`changes()`).  An `AsyncStream` of change sets,
one per commit, in commit order.  Unit 12.

**Claim** (`PendingEntry.claimedBy`).  A mark on a pending entry
naming the process that is currently syncing out it.  Stale after
`claimStaleAfter`.  Unit 6.

**Classification** (`Classification`).  The sorting of every error
into retryable, too large, or permanent.  Unit 9.

**Client identity** (`TypeDescriptor.ClientIdentity`).  A property
the client sets at creation and the server keeps unique, such as
Task's `uid`, used to match a create whose response was lost.
Units 7 and 9.

**Descriptor** (`TypeDescriptor`).  What the engine knows about a
type.  Unit 7.

**Dependency order** (`dependsOn`, `inDependencyOrder()`).  The order
types are fetched and synced out in, so that a referenced type precedes
its referrer.  Unit 7.

**Eviction** (`evict`).  Deleting objects of a windowed type that
nothing retains, at the end of a pass.  Unit 10.

**Fault** (`ScriptedServer.Fault`).  A one-shot misbehavior injected
into the scripted server.  Unit 13.

**Fetch** (`fetch(_:ids:arguments:)`).  An on-demand `/get` with extra
arguments, for an Email body.  Unit 10.

**Fetch chunk** (`fetchChunk`).  The most ids in one `/get`: the
server's `maxObjectsInGet` or a configured smaller number.  Unit 8.

**Full** (`TypeDescriptor.Mode.full`).  A type every object of which
is held locally.  Unit 1.

**Id**.  The JMAP id of an object; `nil` until the server assigns
one.  Distinct from the local key.  Unit 5.

**Initial sync** (`fullFetch`).  Fetching every object of a full type
for the first time, or again after a resync.  Unit 8.

**Invocation** (`Invocation`).  One method call or response, the
`[name, arguments, callId]` triple.  Unit 3.

**JMAP equivalence** (`isJMAPEquivalent(to:)`).  Equality that treats
a null member and an absent one as the same.  Unit 2.

**Journal** (`jinx_journal`).  The table of committed change sets
that another process tails.  Units 6 and 12.

**Local key** (`LocalKey`).  The stable `Int64` identity of a synced
object, assigned when it first exists locally and never changed.
Unit 5.

**Local value** (`StoredObject.local`, `SyncedObject.value`).  The
object as the app sees it: the snapshot plus any pending change.
Unit 5.

**Owned properties** (`ownedProperties`).  The properties a
replacement encoding may change.  Unit 4.

**Pass** (`sync()`).  One sync-out followed by one sync-in.  Unit 8.

**Patch** (`PatchObject`).  A `/set` update: path to value, null to
remove.  Unit 4.

**Pending entry** (`PendingEntry`).  The log record that an object has
a create, update or destroy waiting to be synced out.  At most one per
object; stores no patch.  Unit 5.

**Pin** (`pin(_:ids:)`, `BlobStore.pin`).  For objects, ids the app
wants held regardless of any subscription.  For blobs, files exempt
from cache eviction.  Units 10 and 11.

**Rebase** (`Rebase`).  Re-applying a pending change to a newly
fetched object.  Unit 4.

**References** (`TypeDescriptor.references`).  Properties holding ids
of other types, for retention and fetching.  Unit 7.

**Resync**.  Forgetting a type's state after `cannotCalculateChanges`
and fetching again without wiping.  Units 8 and 10.

**Retention**.  The rule for what a windowed type holds: subscription
windows, pins, pending objects, and one level of references.  Unit 10.

**Result reference** (`ResultReference`).  A back-reference from one
method call's arguments to an earlier call's response.  Unit 3.

**Scripted server** (`ScriptedServer`).  The in-process JMAP server
the engine tests run against.  Unit 13.

**Session** (`Session`).  The decoded session resource, with the
limits and URL templates.  Unit 3.

**Snapshot** (`StoredObject.snapshot`).  The object as the server
last reported it; `nil` if the server has never seen it.  Unit 5.

**Subscription** (`QuerySubscription`).  A live query the engine keeps
current for a windowed type; its result is a `SubscriptionResult`.
Unit 10.

**Sync-in** (`syncIn()`).  Bringing every type up to date from the server.
Unit 8.

**Sync-out** (`syncOut()`).  Sending every pending entry to the server.
Unit 9.

**Synced object** (`SyncedObject`, `StoredObject`).  One JMAP object
as Jinx holds it, with its metadata.  Unit 5.

**Transport** (`JMAPTransport`, `JMAPClient`).  The five network
operations the engine needs, and their URLSession implementation.
Unit 3.

**Veto** (`MayPatch`).  A per-type closure that stops the diff from
descending into an object at a path.  Unit 4.

**Window** (`Window`, `window(of:)`).  A subscription's result and
its objects, read in one transaction.  Unit 10.

**Windowed** (`TypeDescriptor.Mode.windowed`).  A type of which only
the retained objects are held.  Unit 10.

**Wipe** (`wipe()`).  Discarding every object, entry and state for an
account.  Unit 9.
