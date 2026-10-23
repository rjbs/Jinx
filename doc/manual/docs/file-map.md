# File map

Every source file, by module, with what it holds.  Modules are in
stack order from the bottom.

## JinxJSON

| File | Holds |
|---|---|
| `JSONValue.swift` | The `JSONValue` enum, accessors, literals, `Codable`, serialization, JMAP equivalence. |
| `JSONPointer.swift` | `JSONPointer` in both JMAP spellings; `value(at:)` and `setting(_:at:)`. |

## JinxWire

| File | Holds |
|---|---|
| `Session.swift` | The decoded session resource and core capabilities. |
| `URLTemplate.swift` | RFC 6570 level 1 templates for download, upload and push URLs. |
| `Invocation.swift` | `Invocation`, `ResultReference`, `Request`, `Response`. |
| `RequestBuilder.swift` | Call ids and back-references. |
| `StandardMethods.swift` | Typed `/get`, `/changes`, `/set`, `/query`, `/queryChanges` responses and argument builders. |
| `Errors.swift` | `JMAPError`, `RequestError`, `MethodError`, `SetError`. |
| `Transport.swift` | `JMAPTransport`, `JMAPClient`, authenticators, blob upload and download. |
| `ServerSentEvents.swift` | The SSE parser, line splitter, and `StateChange`. |
| `EventSourceClient.swift` | The reconnecting push client and `Backoff`. |

## JinxPatch

| File | Holds |
|---|---|
| `PatchObject.swift` | The patch type and its validation rules. |
| `Diff.swift` | `diff(from:to:mayPatch:)` and the `MayPatch` veto. |
| `Apply.swift` | `applying(_:)`. |
| `Rebase.swift` | `Rebase`. |
| `OwnedProperties.swift` | `mergingOwnedProperties(_:from:)`. |

## JinxStore

| File | Holds |
|---|---|
| `SyncStore.swift` | The `SyncStore` and `SyncTransaction` protocols. |
| `Records.swift` | `LocalKey`, `StoredObject`, `PendingEntry`, `ChangeSet`, `JournalEntry`, `QuerySubscription`, `SubscriptionResult`, `BlobRecord`. |
| `GRDBSyncStore.swift` | The schema, the store, and `GRDBTransaction`. |

## Jinx

| File | Holds |
|---|---|
| `SyncEngine.swift` | The actor, configuration, status, reads, the change stream, `commit`, `sync()`. |
| `TypeDescriptor.swift` | `TypeDescriptor`, dependency order, `SyncError`. |
| `Writes.swift` | `Writer` and the engine's write methods. |
| `Pull.swift` | `pull()`, the incremental rounds, `fullFetch`, `applyFetched`. |
| `Push.swift` | `push()`, batching, sending, reconciling, adoption by identity. |
| `Classification.swift` | The retry policy. |
| `Windowed.swift` | Subscriptions, pins, fetch, the windowed pass, eviction, resync. |
| `BlobStore.swift` | The blob store actor and the engine's blob extensions. |
| `Runner.swift` | `run()`, the push listener, journal tailing, Darwin notifications. |

`Sources/Cnotify` is a two-file system library module that exposes
`notify(3)` to Swift for `Runner.swift`.

## JinxTypes

| File | Holds |
|---|---|
| `MailTypes.swift` | Mailbox, Thread, Email, Identity, EmailSubmission. |
| `TaskTypes.swift` | TaskList, Task, and the JSCalendar veto. |

## JinxScriptedServer

| File | Holds |
|---|---|
| `ScriptedServer.swift` | The transport implementation, state, faults, the test-facing API, push and blobs. |
| `Methods.swift` | `/get`, `/changes`, `/set`, `/query`, `/queryChanges` over plain JSON. |

## Tests

One target per module, under `Tests/`.  `JinxTests` holds the
engine suites, `PullTests`, `PushTests`, `WindowedTests`, `BlobTests`,
`RunnerTests` and `ClassificationTests`, and `Harness.swift`, which
wires a scripted server, an in-memory store and an engine together.
`JinxTypesTests` runs the standard descriptors against the scripted
server.
