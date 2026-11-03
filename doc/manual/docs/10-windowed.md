# 10. Windowed sync

A mail account does not fit on a phone, and even if it did, nobody
wants to wait for it.  The RFC's tools for this are `/query`, which
returns an ordered list of ids for a filter and sort, and
`/queryChanges`, which a server may or may not implement.  What they
do not give you is a policy: which objects to hold, when to let one
go, how to keep a list current on a server that cannot calculate
query changes, and how to do all of that while the user is reading
one message and starring another.

Jinx's answer is to make **retention** the model.  A windowed type has
no notion of "cached"; an object is either retained by something or
it is evicted at the end of the next pass.  The things that retain
are few and explicit.

<figure class="jinx-figure">
<svg viewBox="0 0 760 330" width="760" height="330" role="img" aria-labelledby="retain-title">
<title id="retain-title">What retains an object of a windowed type</title>
<rect class="ext" x="10" y="10" width="740" height="310" rx="6"/>
<text class="nm" x="24" y="34">Everything the server has</text>
<text class="sub" x="736" y="34" text-anchor="end">not held; fetched when something below wants it</text>
<rect class="blk" x="30" y="52" width="700" height="250" rx="6"/>
<text class="nm" x="44" y="76">Held locally</text>
<rect class="blk" x="50" y="92" width="330" height="60" rx="4"/>
<text class="nm" x="215" y="116" text-anchor="middle">subscription windows</text>
<text class="sub" x="215" y="136" text-anchor="middle">the ids each live query currently returns</text>
<rect class="blk" x="400" y="92" width="310" height="60" rx="4"/>
<text class="nm" x="555" y="116" text-anchor="middle">pins</text>
<text class="sub" x="555" y="136" text-anchor="middle">ids the app asked to keep, such as an open thread</text>
<rect class="blk" x="50" y="166" width="330" height="60" rx="4"/>
<text class="nm" x="215" y="190" text-anchor="middle">objects with a pending change</text>
<text class="sub" x="215" y="210" text-anchor="middle">never evicted until synced out</text>
<rect class="blk" x="400" y="166" width="310" height="60" rx="4"/>
<text class="nm" x="555" y="190" text-anchor="middle">referenced objects, one level</text>
<text class="sub" x="555" y="210" text-anchor="middle">the Thread of every held Email</text>
<text class="sub" x="380" y="266" text-anchor="middle">anything held that none of the four retains is deleted at the end of the pass</text>
</svg>
<figcaption>Retention is a union of four sets, recomputed every pass.</figcaption>
</figure>

## Subscriptions

A `QuerySubscription` is a live query the engine keeps current: an
`id` the app chooses, a type, a filter, a sort, a position, a limit,
and any extra arguments the type's `/query` takes.

```swift
try await engine.subscribe(QuerySubscription(
  id: "inbox",
  accountId: accountId,
  type: "Email",
  filter: ["inMailbox": inboxId],
  sort: [["property": "receivedAt", "isAscending": false]],
  limit: 50,
  arguments: ["collapseThreads": true]
))
```

The app names it, so it survives relaunch, and so it can be declared
again on every launch: an identical redefinition changes nothing and
triggers no pass.  Redefining it with different parameters starts it
over, and that includes the extra arguments, which are part of the
subscription's identity because they change what the server returns.
A subscription with no filter, no limit and position zero covers the
whole type, and while it exists the type behaves as a full mirror.

A query can depend on more than its type: a saved search kept in
another type, say, or the clock.  When the app knows such an answer
has gone stale, `refreshSubscriptions(of:)` runs the type's
subscriptions again on the next pass as if the type had moved, and
the results that stand are kept until the new ones arrive.

The result of a subscription, a `SubscriptionResult`, is what the
server last said its window holds: the ids in the query's order, the
total if the server reported one, the query state, whether the server
can calculate changes for it, and `extra`, every non-standard property
of the last response.  Fastmail's category sort returns section counts
there, and an app that draws section headers needs them.

A server caps every `/query` at a limit of its own, which it need not
advertise: Juke's answers at most 5,000 ids however many were asked
for.  An answer shorter than its total, and shorter than the
subscription asked for, is only a first page, so the engine fetches
the rest from the next position with the same filter and sort, and
the result is the whole list.  The window holds what the subscription
asked for, not what one answer could carry.  A page answered under a
different query state than the first cannot join it, so the paging
starts over; a server that keeps moving gets a few tries before the
pass is given up and retried.

The read API has a subtlety.  `result(of:)` returns the result, and
`objects(in:)` returns the window's objects in order, but a window
that is cut by numbers in `extra` must not be read in two calls,
because a commit can land between them and the counts would describe
a different id list.  `window(of:)` reads the subscription, its result
and its objects in one transaction and returns them as a `Window`.
It also reports `missingIds`, the ids in the result whose objects are
not held, which is normally empty and is not when a `/get` returned
`notFound` for an id the query had just listed.

## Pins and fetches

`pin(_:ids:)` keeps objects held regardless of any subscription and
fetches them on the next pass if they are missing.  An app pins what
it is showing outside a window: the messages of an open thread, say,
which may have scrolled out of the inbox window.  `unpin` releases
them.

`fetch(_:ids:arguments:)` fetches objects now, in one request, with
extra `/get` arguments merged over the type's own, and stores what
comes back.  This is how an Email body arrives: the summary came with
the window, and when the user opens the message the app fetches it
again with `fetchHTMLBodyValues`.  A fetched object stays held only
while something retains it, so an app that wants the body to survive
the next pass pins the message.

!!! info "Not yet built"
    Nothing records that an object was fetched at the full level: a
    changed Email is refetched with the summary properties, and the app
    fetches the body again if it is still open.  Planned: a fetch level
    per object, so a later change refetches at the same level, and
    demotion to summary before eviction.  Thread 2026-10-17-pm2sqs.

## The windowed pass

`syncInWindowed` runs after the full types have been handled, and it
loops in rounds, at most fifty, until no type reports more changes.
A windowed type with no state yet first gets one from an empty
`/get`, since there is nothing to fetch and the state is all that is
needed to ask `/changes` next time.  Each round has five steps.

**1. Changes.**  One request with a `/changes` per windowed type,
with `maxChanges` set to the fetch chunk.  `cannotCalculateChanges`
marks the type for resync; a mismatched `oldState` leaves the type for
the next round, as in unit 8.

**2. Refresh.**  Every subscription whose type moved, or that has no
result yet, or whose type this process just changed with a sync-out, is
refreshed.  The refresh uses `/queryChanges` when the last result
said the server can calculate changes, there is a query state, and
the subscription is unlimited or starts at position zero, passing the
window's last id as `upToId` so the server need not report changes
below the window.  Otherwise, and that is the common case against
most servers, it re-runs `/query` and the engine diffs the id lists
itself.  An answer the server cut short is completed by paging, as
described under Subscriptions.  A `/queryChanges` that comes back
`cannotCalculateChanges` or `tooManyChanges` is retried as a `/query`
in the same round.  In
the same request, every id the `/changes` listed as updated and that
is held is refetched with the type's summary properties.  Created
ids are not fetched, because a subscription that should show them
will list them when it refreshes, unless some subscription covers
the whole type, in which case they are.

**3. Fill.**  Every id in a refreshed window, and every pinned id,
that is not held and was not just destroyed is fetched.

**4. References.**  For everything fetched so far, one level of
declared references is followed: a fetched Email names a Thread and
some Mailboxes, and any of those not held is fetched too.  That is
why `MailTypes` lists Thread before Email, and why a Thread with
`emailIds` that are not held is not an error.

**5. Commit and evict.**  One transaction applies every fetched
object through `applyFetched`, removes every destroyed id, stores
the new states and the new subscription results, names the
subscriptions whose result changed in the change set, and then runs
eviction.

Eviction computes the retained set as the figure above shows: the
ids in every subscription result, every pin, every object with a
pending change, and every id referenced from a retained object,
where the referrers are every object of a full type and the retained
plus pending objects of a windowed one.  Every held object of a
windowed type with an id and no pending change that is not in that
set is deleted, in the same transaction.

!!! info "Not yet built"
    Eviction is immediate: the moment nothing retains an object it is
    deleted, which is simple and means an app must pin anything it is
    still showing.  Planned: least-recently-read eviction under a
    count cap, so that an object the user just scrolled past stays a
    while.  Thread 2026-10-17-2zbr8g.

## Resync and moving between modes

A windowed type's resync after `cannotCalculateChanges` deletes every
held object with no pending change, clears every subscription result
for the type, and forgets the state.  Pins and pending objects
survive.  The next round gets a fresh state, re-queries every
subscription, and fills the windows again.

The mode in a descriptor is fixed, but what is held is a question of
which subscriptions exist, and that is decided at runtime.  Mail on a
new device starts with an inbox subscription so work can begin at
once; later, on power and wifi, the app can add a subscription with
no filter and no limit, and the type fills in the background, with
created ids now fetched as they arrive so that nothing that lands
during the fill is lost.  Removing that subscription takes the type
back to windowed, and everything not otherwise retained is evicted
on the next pass.

Subscriptions also work on full types, with a smaller job.  Every
object is already held, so a refresh asks `/query` only for the
ordered id list and total, and fetches nothing.  That is how an app
gets a server-side sort of Tasks without implementing the sort
itself.

## Where to look

- `Sources/Jinx/Windowed.swift`: the public API at the top,
  `syncInWindowed` as the five steps, `evict`, and `resyncWindowed`.
  `refreshFullTypeSubscriptions` is the full-type case.
- `swift test --filter JinxTests.WindowedTests`.
  `windowedTypeHoldsOnlyTheWindow` and `windowFollowsServerChanges`
  are the basic loop; `pinsAndPendingChangesAreNeverEvicted` and
  `referencedObjectsAreFetchedAndHeldOneLevel` are two of the four
  retainers; `queryChangesIsUsedWhenTheServerCanCalculate` is step 2;
  `wholeTypeSubscriptionActsAsAFullMirror` is moving between modes;
  and `windowReadsResultAndObjectsTogether` is `window(of:)`.

Next: [Blobs](11-blobs.md).
