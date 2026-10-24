# 13. Testing

A sync engine's bugs live in sequences: a change that arrives while a
sync-out is in flight, a response that was applied but never received, a
state the server forgot.  None of those can be tested against canned
responses, because a canned response is the test author's guess at
what a server would say, and the guess is what is usually wrong.  Jinx
tests the engine against a server instead: a small, correct JMAP
server that runs in the test process, holds real data, and computes
real answers.

## Three tiers

The design calls for three tiers.

1. **Unit tests** on the pure pieces: `JinxJSON`, `JinxPatch`, the
   request builder and the typed responses in `JinxWire`, and the GRDB
   store.  These are ordinary tests of functions, and the earlier
   units pointed at them.
2. **Scripted-server tests**, where the engine runs against the
   in-process server and a test is a sequence of server-side changes,
   client operations, injected faults, and assertions on what the
   client believes.  This is where every engine test lives.
3. **Conformance tests**, the same scenarios as data, run against a
   separately running reference server by any JMAP client that
   implements a small driver protocol.

The first two exist.  The third, and the data format the second and
third are meant to share, do not yet.

!!! info "Not yet as designed"
    The plan expected the script format to surface from writing real
    tests rather than from designing it first, and that is what has
    happened: the scripted-server tests are Swift, written against a
    harness, and the format that would let them be data has not been
    extracted.  Thread 2026-10-16-4rzk9f.

## The scripted server

`ScriptedServer` in `JinxScriptedServer` implements `JMAPTransport`,
so the engine cannot tell it from a network, and it is generic: any
`Foo/get`, `Foo/changes`, `Foo/set`, `Foo/query` and
`Foo/queryChanges` works on objects that are plain JSON, for whatever
type names a test uses.  It keeps a modification sequence per account
and type, tombstones for destroyed objects, and server versions of query
results, so that `/changes` between any two states it has held, and
`/queryChanges` where a type is configured to allow it, are computed
rather than scripted.  It resolves creation ids and result references,
enforces `maxCallsInRequest`, `maxObjectsInGet` and `maxObjectsInSet`
from its `Limits`, serves blobs with range requests, and delivers
`StateChange` events to push subscribers after every `/set`.

A test drives it two ways.  The first is directly: `create`, `update`
and `destroy` change the server's data as another client would, and
each one is a state transition the engine will see on its next sync-in.
The second is by **faults**, one-shot misbehaviors consumed in order,
for the things a correct server never does.

| Fault | What happens |
|---|---|
| `transportFailure` | The next request fails before the server sees it. |
| `loseResponse` | The next request is processed fully, then the reply is lost.  The client's lost-response path. |
| `methodError(method:error)` | The next call with that name is answered with the given error instead of being processed.  `cannotCalculateChanges` on the next `/changes` is the usual use. |
| `rewrite(method:transform)` | The next matching response is passed through a closure before it is sent.  A wrong `oldState`, say. |

Per-type options cover the two server behaviors that matter to the
engine and vary between real servers: a `uniqueProperty` that a
create may not duplicate, which is how Task's `uid` is modeled, and
whether `/query` reports `canCalculateChanges`.

Everything the client sends is logged.  `requests` is every request
in order; `calls(named:)` filters the method calls; and
`resolvedCalls(named:)` shows the calls as processed, with
back-references resolved, so a test can see which ids a
back-referenced `/get` actually asked for.

## What a test reads like

`Harness` in `Tests/JinxTests` wires a scripted server, an in-memory
GRDB store, and an engine together, with a few test types: `Thing`,
with no particular facts; `Task`, with a `uid` identity and an owned
set; and `Track` and `Playlist`, with a dependency.  Here is the
lost-create test from unit 9, in full:

```swift
@Test func lostCreateResponseIsAdoptedByIdentity() async throws {
  let h = try Harness(types: [taskType])
  h.server.configure("Task", .init(uniqueProperty: "uid"))
  try await h.engine.sync()
  let key = try await h.engine.create("Task", ["uid": "u1", "title": "t"])
  h.server.enqueue(.loseResponse)
  await #expect(throws: SyncError.self) { try await h.engine.sync() }
  #expect(h.server.objects("Task").count == 1, "the server applied the create")
  // The sync-in that follows the failed sync-out already adopts it by uid.
  let adopted = try #require(try await h.engine.object(key: key))
  #expect(adopted.id == h.server.objects("Task").keys.first)
  #expect(adopted.pending == nil)

  h.server.clearRequests()
  try await h.engine.sync()
  #expect(h.server.objects("Task").count == 1, "no duplicate")
  #expect(methodNames(h.server).first == "Task/changes", "the pass synced in before syncing out")
  #expect(h.server.calls(named: "Task/set").isEmpty)
}
```

Read it as a script.  Configure the server; sync once to get a state;
create locally; arrange for the next reply to be lost; sync, and
expect the pass to fail.  Then assert what the server has, what the
client believes, and, after another pass, what the client sent.  The
last two assertions are about the wire: the pass synced in before it
synced out, and no `/set` went at all.  Nothing in the test says what any
response contained.

## The hard cases

The design listed the scenarios a sync engine most often gets wrong,
and each has a test.

| Scenario | Test |
|---|---|
| The server forgot our state | `cannotCalculateChangesResyncsWithoutWiping` |
| A delta larger than one round | `pagedChangesLoopUntilDone` |
| A type too large for one `/get` | `initialSyncPagesWhenGetIsTooLarge` |
| A lost create response | `lostCreateResponseIsAdoptedByIdentity` |
| A create that collides on identity | `duplicateIdentityOnCreateAdoptsTheExistingObject` |
| A permanent error on one object of a batch | `permanentErrorRevertsOnlyThatObject` |
| A transport failure mid-sync-out | `retryableFailureKeepsEntriesAndReleasesClaims` |
| A server change to an object with a pending edit | `rebaseKeepsPendingPropertyAndTakesTheRest` |
| Two processes syncing out at once | `twoProcessesSyncOutWithoutSendingTwice` |
| A window on a server without `canCalculateChanges` | `windowFollowsServerChanges` |
| A window on a server with it | `queryChangesIsUsedWhenTheServerCanCalculate` |
| A changed blob id | `supersededBlobIsReportedOnPullAndGoneOnDownloadTriggersRefetch` |
| A push notification and a local write | `runLoopSyncsOnPushNotificationsAndLocalWrites` |

One case the design names is not yet tested: an edit made while its
entry is in flight.  The rule is implemented, in unit 5 and unit 9,
and the test is thread 2026-10-17-ncrmkw.

## Running them

```
swift test                                   # everything
swift test --filter JinxTests.SyncOutTests      # one suite
swift test --filter lostCreateResponse       # one test, by name fragment
```

The scripted-server tests take no network and no fixtures, and the
whole suite runs in a few seconds.  The server has its own tests in
`JinxScriptedServerTests`, which check that it is the correct server
the engine tests assume: that its `/changes` really does page, that
creation ids resolve across calls, that faults fire once and in order.

## Where to look

- `Sources/JinxScriptedServer/ScriptedServer.swift` is the transport,
  the state, and the test-facing API; `Methods.swift` is the five
  methods.
- `Tests/JinxTests/Harness.swift` is the harness; the suites beside it
  are the scripted-server tier.

Next: [Capstone](14-capstone.md).
