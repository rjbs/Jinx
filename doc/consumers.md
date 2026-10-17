# Consumers and what each needs

Jinx exists to serve three applications now and more later.  This records
what each needs, gathered on 2026-10-16 from their design documents and
from the agents working on them, so that the design serves all of them
rather than only the first.  When a consumer's own documents change, this
file is the one to update.

Sources:

- **Mail experiments:** the Claude Doc "JMAP Sync Library: Requirements"
  (2026-10-16).
- **Juke**, a music server and iOS player: `/Users/rjbs/code/hub/Juke`,
  `DESIGN.md` and `doc/*.md` (2026-10-13).
- **NerfJournal**, a todo journal: `/Users/rjbs/code/hub/nerfjournal`,
  `JMAP-SPEC.md` and `SYNC-DESIGN.md` on branch `jmap-storage`
  (2026-10-04).

## At a glance

| | Mail experiments | Juke | NerfJournal |
|---|---|---|---|
| Types | Mailbox, Thread, Email; Identity and EmailSubmission later | Track, Playlist, both app-defined | Task (JMAP for Tasks); one TaskList read once |
| Object mirror | Windowed: the account far exceeds the device | Full: about 45k Tracks, under 100 MB of metadata | Full: hundreds to low thousands of Tasks |
| Blobs | Bodies and attachments on demand | Audio: 259 GB in the library, a pinned subset plus an LRU cache on device | None |
| Writes | Through a separate "actions" layer | playCount, lastPlayed, rating, plain playlist edits; offline | Everything, offline, including a bulk day-rollover sweep |
| Conflict policy | Unspecified | Last-write-wins per property | Last-write-wins per property; pending local edits win until pushed |
| Creates that reference other pending creates | Rare | None: playlists reference existing Tracks | None |
| `/queryChanges` | Open question | Not planned | Server reports `canCalculateChanges` false |
| Push | EventSource, polling fallback | Unspecified | EventSource, held by the app only; the CLI pushes once after a write |
| Storage | Open; must persist across launches | Undecided; Application Support for files | Jinx's GRDB store in the app's own database file beside client-only tables; two processes (decided 2026-10-17) |
| Platform floor | iOS and macOS 27 | iOS 27 | macOS 27 (raised from 14 on 2026-10-17); Swift 5 language mode |
| Observation | Created, updated, destroyed by type and id; async sequences | Unspecified | A "rows changed" signal; no SwiftUI types in the library |
| Distinctive need | Coherent cross-type snapshots; raw HTML handed out unsanitized | A changed `blobId` invalidates cached audio; Track syncs before Playlist | Foreign properties preserved; idempotent creates by `uid`; per-row errors |

## What each adds that the others do not

**Mail** is the reason the library must be windowed, UI-free, and small
enough that coding agents can write glue against it reliably.  It is
also the source of the requirement that the specification and
conformance tests be language-neutral data, so that the library could be
ported.  "Message bodies on demand" is a partial-property fetch: metadata
first, bodies later, for the same object.

**Juke** is the reason the library must support app-defined types with
full `/changes` semantics, a declared sync order between types (Track
before Playlist, because playlists are server-evaluated queries over
tracks), blob invalidation driven by object changes, chunked initial sync
with progress over tens of thousands of objects, and the rule that
`cannotCalculateChanges` means a full refetch of one type.  Ids and
blobIds are opaque strings.

**NerfJournal** has already worked out the overlay model from a study of
Fastmail's web client, and its design is the one Jinx generalizes: a
server snapshot and a local value per object, a to-send log that stores
no patch, patches computed by diffing at push time, and rebase on pull.
It adds requirements the others do not state: two processes sharing one
database and both pushing, the app owning the row shape, preservation of
properties the client does not model, a classification of `/set` errors
into retryable and permanent, and idempotent creates keyed by a
client-chosen property.

## Where they pull against each other

1. **Who owns the store.**  The mail document leaves it open.  Juke has
   not decided.  NerfJournal planned to own its `todo` table and run the
   engine over a storage protocol, but that meant rewriting the GRDB
   store under other column names.  Decided 2026-10-17: Jinx's GRDB
   store owns the JMAP data for every consumer, living in whichever
   database file the app provides, beside the app's own tables.
2. **Read-only versus writes.**  The mail document makes sync read-only
   and puts writes in an "actions" layer.  Optimistic overlay, which RJBS
   wants, only works if the sync layer knows about pending writes, and
   the other two consumers need writes anyway.  The plan: writes live in
   Jinx, and mail actions become named verbs built on Jinx's write API.
   An experiment that never calls the write API still gets a read-only
   mirror.
3. **Full mirror versus windowed.**  Mail needs windows.  Juke's object
   metadata and NerfJournal's tasks are full mirrors.  The plan: windowed
   is the core model, and a full mirror is one unbounded subscription.
   Juke's "the library exceeds the device" is about blobs, not objects.
4. **Platform floor.**  RJBS targets iOS and macOS 27.  NerfJournal shipped
   on macOS 14 and is being raised to 27 to match.  Decided 2026-10-17:
   Jinx requires iOS and macOS 27.
5. **Identity.**  NerfJournal keys rows by Int64 rowid with a nullable
   `remoteID`, so that client-only tables can reference a task before
   the server has named it.  Jinx's GRDB store adopts that scheme for
   everyone: a stable Int64 local key per object, the JMAP id as a
   nullable column, lookup by either.
