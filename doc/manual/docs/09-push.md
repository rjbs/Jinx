# 9. Push

A write in Jinx is a change to the local store, and nothing else
happens at the time of the write.  The server learns of it when the
next push runs, and the push is where every hard question about
writes is answered: what to send, in what order, what a failure means,
and what to do when the answer never arrives.  This unit covers the
write API briefly and the push in full.

## The write API

Every write goes through a `Writer`, inside one store transaction:

```swift
try await engine.write { writer in
  let key = try writer.create("Task", ["uid": uid, "title": "Write unit 9"])
  try writer.update(other, patch: ["keywords/done": true])
  try writer.replace(third, with: encodedTask)
  try writer.destroy(fourth)
}
```

The engine also exposes each operation as a one-line convenience,
`engine.create(...)`, `engine.update(...)` and so on, for the common
case of one write at a time.  The transaction form is for bulk
operations: NerfJournal's day-rollover sweep, which abandons or
migrates every open task at once, becomes one log batch and one
`Task/set` rather than one per task.

`Writer` is a non-copyable type, Swift's `~Copyable`, so a closure
cannot stash it and use it after the transaction has ended.  Its four
operations are the ones unit 5 described: `create` from a JSON value,
`update` by patch or by a transform of the current value, `replace`
from an encoding scoped to the type's owned properties, and
`destroy`.  `adopt` takes a list of existing values as pending creates,
for an import or a one-time migration.  `wipe`, on the engine, discards
everything for the account.

A create returns its `LocalKey` at once; the JMAP id arrives on the
change stream, in `idsAssigned`, when the push succeeds.  Every local
write commits a change set with source `local` and asks the run loop
for a pass.

## The push loop

`push()` repeats the following until the log is empty or something
needs a retry, with a cap of twenty rounds.

1. **Claim.**  In one transaction, claim every unclaimed entry for the
   account and every entry whose claim has gone stale, in log order,
   and read each entry's object as it stands now.  That pair, entry
   and object, is a `PushItem`, and the object in it is what this
   round will send.  An edit after this moment is an edit in flight.
2. **Build.**  Group the items by type, in dependency order, and chunk
   each type to the server's `maxObjectsInSet`, or to a smaller size if
   an earlier `requestTooLarge` lowered it.  For each item:
    - a create sends the whole local value, minus any `id`, under the
      creation id `jinx<key>`;
    - an update sends the diff from snapshot to local, with the type's
      veto, and if the diff is empty the entry is dropped here, since
      there is nothing to say;
    - a destroy sends the id, and a destroy of an object with no id is
      resolved locally by deleting the row.
3. **Send.**  One request, one `/set` per type.
4. **Apply.**  In one transaction, reconcile the response against what
   was sent.

The creation id is derived from the local key, so a create that
references another pending create of the same type can use the `#jinx42`
form the RFC provides, and so the response can be matched to its
object without a lookup table.

!!! info "Not yet as designed"
    A create that references a pending create of another type, such
    as an Email filed into a Mailbox that does not yet exist on the
    server, is refused by the write path with
    `crossTypeCreationReference`.  The plan has the design for ordering
    such creates across types in one request and holding the dependent
    back when the referenced create fails.  Thread 2026-10-16-ytf6zn.

## When the send fails

If the transport throws, no response exists and the claims are
released, so the next round, or another process, can try again.  The
error is classified as retryable or permanent and the pass fails
accordingly.

One more thing happens if the request carried any creates.  The
server may have applied them before the response was lost, and
resending them blind might make duplicates.  So the engine sets a
flag, `reconcileBeforePush`, and the next pass pulls before it pushes.
The pull brings down whatever the server made, and `applyFetched` in
unit 5 adopts any object whose client identity matches a local object
with no id.  By the time the push runs, the lost create has either
been matched and will not be resent, or genuinely never happened.

## Applying the response

The response is reconciled in one transaction.  For each batch, the
first question is whether the `/set` call itself failed.

| The `/set` response was | Effect |
|---|---|
| missing | Release the batch's claims.  Retry. |
| a retryable method error | Release.  Retry. |
| `requestTooLarge` | Release, halve this type's batch size, retry. |
| a permanent method error | Fan the error out to every item in the batch as a `SetError` and revert each one. |

Otherwise the call succeeded and each item is reconciled on its own.

| Operation | Outcome | Effect |
|---|---|---|
| create | in `created` | Confirm: set the id, set the snapshot to what was sent merged with the server-set properties returned, report the id on the change stream. |
| create | `notCreated` with `alreadyExists` | Confirm with the `existingId` the server supplied, and flag the type for a pull to fetch the rest of that object. |
| create | `notCreated` with `invalidProperties` naming the client identity property | The server has an object with this `uid` already.  Query for it by the identity filter, adopt its id, and mark the object `update` so any local differences are pushed next round.  If the query finds nothing, record a permanent error. |
| create | any other `notCreated` | Retryable: release.  Permanent: revert. |
| update | in `updated` | Confirm: snapshot becomes what was sent merged with server-set properties. |
| update | `notUpdated` | Retryable: release.  Permanent: revert, and if the error is `notFound`, flag a pull, since the server has destroyed something we hold. |
| destroy | in `destroyed`, or `notDestroyed` with `notFound` | Delete the row.  Either way the server does not have it. |
| destroy | any other `notDestroyed` | Retryable: release.  Permanent: revert. |
| any | not mentioned in the response | Release and retry; a response that omits an item is not an answer. |

Two things are checked after the items.  If `created` names a creation
id whose object no longer exists locally, the user destroyed it while
the create was in flight; the server has it and we do not want it, so
a row is inserted with a pending `destroy`.  And the type's state
advances to `newState` only if the stored state equals the response's
`oldState`; otherwise the server moved between our last pull and this
push, and the type is flagged for a pull rather than have its state
jump over changes it has not seen.

Confirming and reverting both honor the edited-in-flight rule from
unit 5.  `confirmCreate` and `confirmUpdate` set the snapshot and
clear the entry only if the entry is still the one that was sent; if
an edit re-added the entry with a later sequence number, the local
value keeps the edit and the new entry waits.  `revert` sets
`lastError` either way, but puts the snapshot back as the local value
only if there was no edit in flight.

## Classification

Every error met during a push is sorted into three classes by
`Classification`, and the sorting is the whole of Jinx's retry policy.

| Error | Retryable | Too large | Permanent |
|---|---|---|---|
| Transport failure | all | | |
| HTTP status | 5xx, 429 | | anything else |
| Request-level error | | `limit` | anything else |
| Method error | `serverUnavailable`, `serverFail`, `serverPartialFail`, `stateMismatch` | `requestTooLarge` | anything else |
| `SetError` | `rateLimit` | | anything else |

Retryable keeps the entry and releases the claim.  Too large halves
the batch.  Permanent reverts the object: local value back to the
snapshot, error recorded, entry cleared, and the change set names the
key in `failed` so the app can tell the user.  `invalidProperties`,
`notFound`, `forbidden` and `invalidPatch` are permanent because
sending the same thing again would draw the same answer.
`stateMismatch` is retryable because Jinx never sends `ifInState`;
if a server reports it anyway, a pull and another try are the right
response.

## Idempotent creates

The RFC says nothing about a create whose response was lost, and a
client that resends it may make two objects.  Jinx handles this with
the three mechanisms already described, and it is worth seeing them
together.

1. A lost response with creates in flight makes the next pass pull
   first, and the pull adopts by client identity.
2. A resent create that the server refuses with `alreadyExists` is
   confirmed with the id the server names.
3. A resent create that the server refuses with `invalidProperties`
   on the identity property is matched by a query on that property.

All three need a client identity, which Task has in `uid`.  A type
with none, such as Email, accepts the risk of a duplicate after a lost
response, and the descriptor's documentation says so.  Adoption
through any of the three fills in the id on the existing row; the
local key never changes, so nothing in the app's tables or on screen
moves.

## Where to look

- `Sources/Jinx/Writes.swift` is the write API; `Push.swift` is the
  loop, with `applySetResponses` as the two tables above;
  `Classification.swift` is the third table.
- `swift test --filter JinxTests.PushTests`.
  `updateSendsOnlyTheDiffAndKeepsForeignProperties` and
  `bulkWritesBecomeOneSet` are the build step;
  `lostCreateResponseIsAdoptedByIdentity` and
  `duplicateIdentityOnCreateAdoptsTheExistingObject` are mechanisms
  1 and 3; `permanentErrorRevertsOnlyThatObject` is revert;
  `tooLargeSetShrinksTheBatch` is the halving; and
  `twoProcessesPushWithoutSendingTwice` is claims under contention.

Next: [Windowed sync](10-windowed.md).
