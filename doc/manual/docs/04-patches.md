# 4. Patches

A `/set` update is a `PatchObject`: a map from a JSON pointer path to
the value to put there, with `null` meaning remove.  The RFC describes
the shape in half a page, section 5.3, and leaves the interesting
question alone: what should a client put in one?

The lazy answer is "the whole object", or "every property my model
knows about".  Both are wrong in the same way.  A Task on the server
may carry properties your app has never heard of, because another
client put them there, or because the type grew a property after you
shipped.  Send the whole object and you send those properties back as
you last saw them, or not at all, and either way you are writing over
someone else's data.  JMAP's patch format exists so that a client can
say only what it changed.  `JinxPatch` is the module that computes
what you changed, applies it, and works out what to do when the server
changed the same object in the meantime.  It is pure: functions over
`JSONValue` with no I/O and no state.

## PatchObject

`PatchObject` is the wire shape and nothing more: `entries` from path
string to `JSONValue`, with the path in JMAP's spelling, no leading
slash.  It encodes and decodes as the plain JSON object it is, and it
can be written as a dictionary literal.

```swift
let patch: PatchObject = [
  "title": "Write the manual",
  "keywords/manual": true,
  "due": .null,
]
```

`validate()` checks the two rules the RFC places on a patch: no empty
path, and no path that is a prefix of another, since `keywords` and
`keywords/manual` in one patch would be ambiguous.

## Diff

`PatchObject.diff(from:to:)` computes the patch that turns one object
into another, and its behavior on three kinds of value is the whole
design.

**Scalars** that differ are replaced, and a member present on one side
and absent on the other is an addition or a removal.  A member that is
`null` on one side and absent on the other is neither, because JMAP
treats them as the same, so no entry is emitted.

**Objects** are compared member by member, recursively.  A map such as
Task's `keywords` or Email's `mailboxIds` therefore yields one entry
per changed key, and the keys that did not change are not mentioned.
That is what lets two clients each add a keyword to the same Task
without either removing the other's.

**Arrays** are replaced whole.  There is no sensible per-element patch
for a JSON array under the RFC's rules, which forbid a path through an
array index, and the diff does not try.

The recursion into objects can be vetoed per path with a `MayPatch`
closure.  The case that needs it is CalendarEvent's
`recurrenceOverrides`, where each entry is itself a patch, so a patch
inside one would be a patch of a patch and its meaning is anyone's
guess.  `TaskTypes.jscalendarMayPatch` says: descend into
`recurrenceOverrides` far enough to add or remove an entry, but
replace an entry whole rather than patching inside it.  A type
descriptor carries its veto, and the engine passes it to every diff
and rebase of that type.

Here is the rule in action.  Another client has put a keyword and a
property on a Task that our app does not model:

```swift
let before: JSONValue = [
  "id": "t1", "uid": "7d1c", "title": "Draft",
  "keywords": ["urgent": true],
  "x-otherapp-color": "red",
]
var after = before
after["title"] = "Draft the manual"
after["keywords"] = ["urgent": true, "manual": true]

try PatchObject.diff(from: before, to: after)
// ["title": "Draft the manual", "keywords/manual": true]
```

Two entries.  The patch does not mention `x-otherapp-color`, because
it did not change, and it does not mention `keywords/urgent`, because
the diff descended into the map.  Sent to the server, this patch
cannot remove anything the app did not touch.

## Apply

`applying(_:)` returns a copy of an object with a patch applied, after
validating the patch.  It creates objects missing along a path, which
is more lenient than the RFC requires a server to be, and harmless for
a client applying its own patch to its own copy.  It refuses a path
through an array or a scalar, which is the pointer rule from unit 2.

## Owned properties

Diff needs two full objects.  An app with its own model has one full
object, the current local value, and an encoding of its model that
names only the properties the model has.  Diffing the one against the
other would emit a removal for every property the model lacks, which
is the whole-object mistake again by another road.

`mergingOwnedProperties(_:from:)` is the fix.  Given the set of
properties the app owns, it copies exactly those members from the
encoding into the full object, adding, replacing or removing each,
and leaves every other member as it was.  The result is a full object
that differs from the original only in owned properties, and the diff
of that against the snapshot names only owned properties.

```swift
let encoding: JSONValue = ["uid": "7d1c", "title": "Draft the manual", "due": "2026-10-24"]
let owned: Set<String> = ["title", "due", "keywords"]

let merged = try before.mergingOwnedProperties(owned, from: encoding)
// title replaced, due added, keywords removed because the encoding lacks it,
// id, uid and x-otherapp-color untouched
```

Note the third effect: an owned property absent from the encoding is
removed.  Owned means owned.  If the app's model does not carry
`keywords`, the app must not list it as owned, or every save will
clear it.  This is the detail that NerfJournal's agent caught on
2026-10-17 while reviewing the write API, and it is why the merge is
scoped to a declared set rather than to whatever the encoding happens
to mention.

## Rebase

Now the hard case.  The app has a pending edit: the local value
differs from the snapshot of the server object by one patch, not yet
synced out.  A sync-in arrives with a newer version of the same object.  What
is the local value now?

`Rebase` answers with a square.

<figure class="jinx-figure">
<svg viewBox="0 0 760 300" width="760" height="300" role="img" aria-labelledby="rebase-title">
<title id="rebase-title">Rebasing a pending edit onto a fetched object</title>
<defs>
<marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse">
<path d="M 0 0 L 10 5 L 0 10 z" fill="var(--md-default-fg-color--light)"/>
</marker>
</defs>
<rect class="blk" x="40" y="30" width="220" height="60" rx="4"/>
<text class="nm" x="150" y="55" text-anchor="middle">snapshot</text>
<text class="sub" x="150" y="75" text-anchor="middle">the server object as last fetched</text>
<rect class="blk" x="500" y="30" width="220" height="60" rx="4"/>
<text class="nm" x="610" y="55" text-anchor="middle">local</text>
<text class="sub" x="610" y="75" text-anchor="middle">what the app has edited it to</text>
<rect class="blk" x="40" y="210" width="220" height="60" rx="4"/>
<text class="nm" x="150" y="235" text-anchor="middle">fetched</text>
<text class="sub" x="150" y="255" text-anchor="middle">the server object as just fetched</text>
<rect class="blk" x="500" y="210" width="220" height="60" rx="4"/>
<text class="nm" x="610" y="235" text-anchor="middle">new local</text>
<text class="sub" x="610" y="255" text-anchor="middle">fetched, with the patch applied</text>
<line x1="266" y1="60" x2="494" y2="60" stroke="var(--md-default-fg-color--light)" stroke-width="1.5" marker-end="url(#arrow)"/>
<text class="sub" x="380" y="50" text-anchor="middle">1. diff: the pending patch</text>
<line x1="150" y1="96" x2="150" y2="204" stroke="var(--md-default-fg-color--light)" stroke-width="1.5" marker-end="url(#arrow)"/>
<text class="sub" x="162" y="154">the server moved</text>
<line x1="266" y1="240" x2="494" y2="240" stroke="var(--md-default-fg-color--light)" stroke-width="1.5" marker-end="url(#arrow)"/>
<text class="sub" x="380" y="230" text-anchor="middle">2. apply the same patch</text>
<line x1="610" y1="96" x2="610" y2="204" stroke="var(--md-default-fg-color--light)" stroke-width="1.5" stroke-dasharray="5 4" marker-end="url(#arrow)"/>
<text class="sub" x="622" y="154">replaced</text>
</svg>
<figcaption>The pending patch is recomputed from the old pair and re-applied to the new server object.</figcaption>
</figure>

Three inputs: the snapshot, the local value and the fetched object.
Step one diffs snapshot to local, which recovers the pending patch.
Step two applies that patch to the fetched object, and the result is
the new local value.  The fetched object becomes the new snapshot.

The consequence is the whole of Jinx's default conflict rule, and it
is worth saying plainly: **a property with a pending local change
keeps its local value until it is synced out, and every other property
takes the server's.**  Because the patch is at path granularity, two
clients editing different members of one map do not conflict at all,
and two clients editing the same scalar resolve as last write wins
when the pending edit is eventually synced out.

```swift
let snapshot: JSONValue = ["title": "Draft", "keywords": ["urgent": true]]
let local: JSONValue    = ["title": "Draft the manual", "keywords": ["urgent": true]]
let fetched: JSONValue  = ["title": "Draft", "keywords": ["urgent": true, "waiting": true]]

let rebase = try Rebase(snapshot: snapshot, local: local, fetched: fetched)
rebase.patch        // ["title": "Draft the manual"]
rebase.local        // ["title": "Draft the manual", "keywords": ["urgent": true, "waiting": true]]
rebase.isRedundant  // false
```

The server added a keyword; the app changed the title; the new local
value has both.  Had the server instead changed the title to "Draft
the manual" itself, because the same user did it on another device,
applying the patch would change nothing, `isRedundant` would be true,
and the engine would drop the pending entry rather than sync out a no-op.
That check uses JMAP equivalence from unit 2, so a server that sends
an explicit `null` where the patch removed a property is still
recognized as already having the change.

`Rebase` does no I/O.  Unit 5 shows where the engine calls it and why
the snapshot it passes is always the one the local value was edited
against.

## Where to look

- `Sources/JinxPatch/`: `PatchObject.swift`, `Diff.swift`,
  `Apply.swift`, `OwnedProperties.swift` and `Rebase.swift`, about two
  hundred lines in all.
- `swift test --filter JinxPatchTests`.  `mapsPatchPerEntry` and
  `arraysAreReplacedWhole` are the diff rules; `vetoReplacesTheSubtree`
  is `MayPatch`; `mergeRemovesOwnedKeysAbsentFromTheEncoding` is the
  owned-means-owned rule; and `foreignPropertiesSurviveTheRebase` is
  the sentence in bold above, as a test.

Next: [The synced object](05-synced-object.md).
