# 8. Sync in

Unit 3 ended with a sync-in assembled by hand and a list of what it did
not do: check `oldState`, loop on `hasMoreChanges`, handle destroyed
ids, chunk the fetches, survive `cannotCalculateChanges`, notice
pending edits, and store anything.  This unit is the engine's sync-in,
which does all of them, and it is best read as that list worked
through in order.

## A pass

`sync()` is one pass, and a pass is a sync-out followed by a sync-in.  The
order is deliberate: a sync-in that runs against a server that already
has the client's changes has less to rebase.  A sync-out that fails for a
retryable reason does not skip the sync-in.  The pending entries are
kept, they will rebase onto whatever the sync-in brings, and the app gets
fresh data while its writes wait.  The sync-out's failure is rethrown
after the sync-in so the run loop can back off.

The sync-in itself begins by sorting the configured types, already in
dependency order, into three groups: windowed types, which unit 10
takes up; full types with no stored state, which need an initial
sync; and full types with a state, which get `/changes`.

## Incremental rounds

A round is one request for every type that still has changes to
fetch.  For each such type the request carries three calls, which are
the three from unit 3 with one addition:

```swift
let changes = builder.call("\(type)/changes",
  .changesArguments(accountId: accountId, sinceState: state, maxChanges: chunk))
let created = builder.call("\(type)/get", descriptor.getArguments(accountId: accountId, ids: []),
  references: ["ids": changes.reference("/created")])
let updated = builder.call("\(type)/get", descriptor.getArguments(accountId: accountId, ids: []),
  references: ["ids": changes.reference("/updated")])
```

The addition is `maxChanges`, set to the fetch chunk, which is the
server's `maxObjectsInGet` or a smaller configured value.  Because a
`/changes` returns at most that many ids, each back-referenced `/get`
asks for at most that many objects, and the request can never draw
`requestTooLarge` however large the delta.  Chunking falls out of the
protocol's own limit, with no second request to split.

<figure class="jinx-figure">
<svg viewBox="0 0 760 406" width="760" height="406" role="img" aria-labelledby="round-title">
<title id="round-title">One incremental round, repeated until no type has more changes</title>
<defs>
<marker id="round-tip" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="9" markerHeight="9" orient="auto-start-reverse"><path class="tip" d="M0,1 L10,5 L0,9 z"/></marker>
</defs>
<line class="life" x1="110" y1="56" x2="110" y2="396"/>
<line class="life" x1="380" y1="56" x2="380" y2="396"/>
<line class="life" x1="650" y1="56" x2="650" y2="396"/>
<rect class="blk" x="35" y="10" width="150" height="46" rx="6"/>
<text class="nm" x="110" y="38" text-anchor="middle">Store</text>
<rect class="blk" x="305" y="10" width="150" height="46" rx="6"/>
<text class="nm" x="380" y="38" text-anchor="middle">SyncEngine</text>
<rect class="blk" x="575" y="10" width="150" height="46" rx="6"/>
<text class="nm" x="650" y="38" text-anchor="middle">Server</text>
<rect class="ext" x="16" y="76" width="728" height="320" rx="6"/>
<path class="tab" d="M16,82 a6,6 0 0 1 6,-6 h252 l0,16 l-10,10 h-248 z"/>
<text class="tabt" x="26" y="94">LOOP <tspan class="tabc">until no type has more changes</tspan></text>
<rect class="act" x="373" y="118" width="14" height="262" rx="2"/>
<text class="lbl" x="245" y="138" text-anchor="middle">read each type's state</text>
<line class="msg" x1="373" y1="148" x2="112" y2="148" marker-end="url(#round-tip)"/>
<text class="lbl" x="515" y="176" text-anchor="middle">one request</text>
<text class="sub" x="515" y="192" text-anchor="middle">per type: /changes, /get created,</text>
<text class="sub" x="515" y="207" text-anchor="middle">/get updated</text>
<line class="msg" x1="387" y1="218" x2="648" y2="218" marker-end="url(#round-tip)"/>
<text class="lbl" x="515" y="248" text-anchor="middle">response</text>
<line class="ret" x1="650" y1="258" x2="389" y2="258" marker-end="url(#round-tip)"/>
<text class="lbl" x="245" y="288" text-anchor="middle">one transaction</text>
<text class="sub" x="245" y="304" text-anchor="middle">apply objects, remove destroyed,</text>
<text class="sub" x="245" y="319" text-anchor="middle">store states, append journal</text>
<line class="msg" x1="373" y1="330" x2="112" y2="330" marker-end="url(#round-tip)"/>
<rect class="blk" x="400" y="346" width="170" height="28" rx="14"/>
<text class="sub" x="485" y="364" text-anchor="middle">emit the change set</text>
</svg>
<figcaption>Every type with changes still to fetch shares one request and one transaction per round.</figcaption>
</figure>

The response is applied in one transaction across every type in the
round, and that transaction decides, per type, which of the following
happened.

- **No response to the `/changes`.**  The round failed; the pass
  throws a retryable error and nothing for this type is stored.
- **A method error.**  `cannotCalculateChanges` puts the type on the
  resync list.  Any other error is classified as unit 9 describes:
  permanent errors abort the pass, retryable ones end the round.
- **`oldState` is not the state we sent.**  The server's answer is
  about a different baseline than the one we hold.  This type's
  results are discarded and it stays in the round for another try.
  After five such rounds the pass gives up as retryable, with the
  message "state kept moving during sync-in", on the theory that
  something else is wrong.
- **Otherwise**, every fetched object goes through `applyFetched`,
  which is the table in unit 5: insert, replace, rebase, skip if
  another process holds the claim, or adopt by client identity.
  Every destroyed id goes through `applyDestroyed`, which deletes the
  row and, by cascade, its pending entry.  The new state is stored,
  in the same transaction.  If `hasMoreChanges` is false the type is
  done; otherwise it goes round again.

A pass runs at most two hundred rounds.  The cap exists so that a
server that reports `hasMoreChanges` forever cannot hold the engine
in a loop, and no server has come near it.

## Initial sync and resync

A full type with no state, and a full type whose `/changes` drew
`cannotCalculateChanges`, go through `fullFetch`.  It is the same code
in both cases, which is the first thing to know about resync: it is an
initial sync that happens to find objects already there.

The first attempt is a single `/get` with `ids: null`, which the RFC
allows a server to refuse with `requestTooLarge`.  Small types, such
as Mailbox or NerfJournal's Task, come back in one response.  When
the server refuses, the engine pages instead: `/query` with no filter,
a position and a limit of one chunk, back-referenced into a `/get`,
with `calculateTotal` on so the status can show a fraction.

Each chunk is committed on its own, and that is the one deliberate
exception to one-transaction-per-pass.  Juke has forty-five thousand
tracks, and an app should be able to draw the first chunk while the
rest arrive.  The engine's status carries an `initialSync` entry per
type with `fetched` and `total` while this is happening, and it is
removed when the fetch ends.

The state stored at the end is the one the first `/get` reported.
Anything that changed on the server during a long paged fetch is
therefore not lost: the next pass asks `/changes` since that state
and picks it up.

Resync never wipes.  Every fetched object goes through the same
`applyFetched` as a sync-in, so an object with a pending edit is rebased
rather than replaced, and the user's unpushed change survives a state
the server forgot.  After the last chunk, one more transaction deletes
every object of the type the server did not return, except those with
a pending create, which the server has never seen and cannot have
reported.  A reader of the store sees a type that is never
half-updated, only a sequence of consistent states that converge on
the server's.

## Status and what the app sees

Every committed round and chunk emits a change set with source
`sync-in`.  `currentStatus()` returns a `SyncStatus` with `lastSyncIn`,
`lastSyncOut`, `pendingCount`, `lastFailure`, and the `initialSync`
progress map.  There is no "syncing" boolean; an app that wants a
spinner watches `initialSync` for a long fetch and otherwise does not
need one, because a sync-in is a few hundred milliseconds and the change
stream says when it landed.

## Where to look

- `Sources/Jinx/SyncIn.swift`: `syncIn()` sorts the types, `syncInChanges`
  is the round loop, `fullFetch` is initial sync and resync, and
  `applyFetched` is the merge.
- `swift test --filter JinxTests.SyncInTests`.
  `incrementalSyncInAppliesCreatesUpdatesAndDestroys` is one round;
  `pagedChangesLoopUntilDone` is `hasMoreChanges`;
  `initialSyncPagesWhenGetIsTooLarge` is the `requestTooLarge` path;
  and `cannotCalculateChangesResyncsWithoutWiping` is the sentence
  "resync never wipes", with a pending edit that survives.

Next: [Sync out](09-sync-out.md).
