# 12. Running the engine

Everything so far has been one pass, called by hand.  An app does not
call passes by hand.  It wants a pass when the user edits something,
when the server says something changed, when the network comes back,
and now and then regardless, and it wants all of those collapsed so
that three triggers in a second make one pass.  It may also have two
processes on one database, only one of which should hold the push
connection.  This unit is the run loop that does those things, and
how an app consumes what it produces.

## The run loop

```swift
Task { await engine.run(pollInterval: .seconds(900)) }
```

`run()` runs until its task is cancelled.  It takes a `Backoff` for
retries, a debounce that defaults to a hundred milliseconds, and an
optional poll interval for when push is unavailable.  Inside, it does
this.

1. Set the journal cursor to the present, so that history is not
   replayed to this process, and start the push listener.  If a poll
   interval was given, start a timer that requests a pass on it.  If
   the configuration names a Darwin notification, observe it.
2. Request one pass, so a launch always syncs.
3. Wait for a wake-up.  Wake-ups arrive on an `AsyncStream` with a
   buffer of one, so any number of requests while a pass is running
   become exactly one more pass afterward.
4. On waking, tail the journal if another process signaled, and then,
   if a pass was requested, sleep for the debounce and run `sync()`.
5. If the pass succeeded, reset the backoff and clear `lastFailure`.
   If it failed with a retryable error, schedule another request after
   the next backoff delay.  Any other error is recorded in the status
   and waits for the next trigger.
6. Tail the journal again, since the pass may have committed, and go
   back to waiting.

The triggers all end in one method, `requestSync()`, which sets a flag
and yields a wake-up.  A local write calls it after its commit.  A
push notification calls it.  The poll timer and the retry timer call
it.  An app can call it, from a pull-to-refresh or its own network
monitor; Jinx does not watch the network itself, and treats a
transport failure as a retryable error with backoff rather than
waiting for a connectivity change.

## Push

`listenForPush` holds the EventSource connection from unit 3 for the
engine's lifetime.  It builds the URL from the session with the
configured type names, so the server sends state changes for those
types only, and consumes the `EventSourceClient` stream.  A `connected`
event sets `isConnected` in the status; a `disconnected` clears it; a
`stateChange` whose account is this one marks each named type as
needing a pull and requests a pass.  The state string in the
notification is not used for anything else, because the only way to
learn what changed is to ask `/changes`, which the pass will do.

Reconnection is the client's job, with backoff, and the listener never
exits on its own.  If the session cannot be fetched at all, the
listener backs off and tries again, so an app that launches offline
connects by itself when the network returns.

One EventSource connection per database is enough, and a reasonable
app with a GUI and a CLI gives the connection to the GUI.
That is a matter of which process calls `run()`.  NerfJournal's
command-line tool does not; after a write it calls `sync()` once and
exits, which pushes its change and pulls whatever is new, and the
GUI's engine learns of the CLI's commit through the journal.

## Two processes

The configuration's `signalName` names a Darwin notification, a
machine-local broadcast with no payload, and the convention is to
derive it from the database path.  Every non-empty commit posts it,
after the transaction.  An engine observing the name requests a tail,
and `tailJournal` reads every journal row after its cursor, skips the
rows its own process wrote, and emits the rest on its change stream.
Each process therefore sees every change set, its own as they commit
and the other's shortly after, and both see them in the same order.

Darwin notifications can be coalesced by the system, which is why the
loop also tails after every pass and why the cursor rather than the
notification is the source of truth: a missed signal delays delivery
until the next wake-up, and never loses anything.

## Consuming the change stream

```swift
@MainActor
final class TaskList {
  var tasks: [SyncedObject] = []

  func observe(_ engine: SyncEngine<GRDBSyncStore>) {
    Task {
      for await changeSet in engine.changes() {
        guard let changes = changeSet.types["Task"], !changes.isEmpty else { continue }
        tasks = try await engine.objects(type: "Task")
      }
    }
  }
}
```

`changes()` returns a new `AsyncStream<ChangeSet>` on each call, and
any number of consumers may hold one.  The elements are `Sendable`
values, so a `for await` on the main actor is correct without any
further ceremony, and this is the whole of Jinx's observation story:
no Combine, no NotificationCenter, no SwiftUI types.  A consumer that
wants to be finer than "something about Tasks changed" reads the keys
in `created`, `updated` and `destroyed`, and `idsAssigned` for creates
that just got their ids.

The engine itself is an actor and is never main-actor isolated.  Every
public method is `async`, every value it returns or accepts is
`Sendable`, and closures it takes are `@Sendable`.  Consumers in
Xcode's default main-actor isolation call it with `await` and nothing
else.

## Status

`currentStatus()` returns a `SyncStatus`: whether the push connection
is up, the time of the last pull and the last push, the number of
pending entries, the last failure as text, and the initial sync
progress per type.  It is meant for a settings pane and a debugging
view, and it changes only at pass boundaries, so an app polls it when
it draws rather than observing it.

On iOS, background refresh is the app's job.  A `BGAppRefreshTask`
handler that calls `sync()` and completes when it returns is the whole
integration; the run loop need not be running for a pass to work.

## Where to look

- `Sources/Jinx/Runner.swift`: `run`, `listenForPush`, `tailJournal`
  and the `DarwinNotification` wrapper over the `notify(3)` API, which
  needs the small `Cnotify` system library module in `Sources/Cnotify`.
- `swift test --filter JinxTests.RunnerTests`.
  `runLoopSyncsOnPushNotificationsAndLocalWrites` is the trigger list;
  `runLoopRetriesWithBackoff` is step 5; and
  `anotherProcessSeesCommitsThroughTheJournal` and
  `tailingSkipsHistoryAndOwnCommits` are the two-process section.

Next: [Testing](13-testing.md).
