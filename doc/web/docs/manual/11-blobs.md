# 11. Blobs

A blob in JMAP is immutable bytes with an id, uploaded before the
object that references it is created and downloaded through a URL
template from the session.  Immutability makes the client's job
simpler in one way, since a cached blob can never go stale, and the
sizes make it harder in every other: a download must resume after an
interruption, the cache must have a ceiling, a partial download should
be readable before it is complete, and an object whose `blobId`
changes must invalidate what was cached under the old one.

Juke is the consumer that drove this.  Its library is hundreds of
gigabytes of audio, the device holds a pinned subset plus a cache,
and playback wants to start before the file is complete.  Mail uses
blobs only for attachments; bodies come through `Email/get`, which is
why a mail client can ignore this unit until it needs one.

## The record

The blob store's index is `jinx_blob`, one `BlobRecord` per blob:
the total length once known, the byte `ranges` present on disk, a
`isPinned` flag, `lastAccess`, and the content type.  The bytes live
in one file per blob under a directory the app chooses, and ranges
are written at their offsets, so a partial blob is a file with holes.
The file is named for the blob id, plus the extension the content
type implies when there is one, so a Track downloaded as `audio/mpeg`
is `<blobId>.mp3`, because AVFoundation will not open a file without
an extension.
A blob is absent when it has no record, partial while its ranges do
not cover its length, and complete when one range covers everything.

<figure class="jinx-figure">
<svg viewBox="0 0 760 150" width="760" height="150" role="img" aria-labelledby="ranges-title">
<title id="ranges-title">A partial blob and a ranged read</title>
<rect class="ext" x="40" y="40" width="680" height="36" rx="3"/>
<rect class="blk" x="40" y="40" width="200" height="36" rx="3"/>
<rect class="blk" x="420" y="40" width="200" height="36" rx="3"/>
<text class="sub" x="140" y="63" text-anchor="middle">0 ..&lt; 4096 on disk</text>
<text class="sub" x="330" y="63" text-anchor="middle">gap</text>
<text class="sub" x="520" y="63" text-anchor="middle">8192 ..&lt; 12288 on disk</text>
<text class="sub" x="670" y="63" text-anchor="middle">not yet</text>
<line x1="164" y1="96" x2="455" y2="96" stroke="var(--md-primary-fg-color)" stroke-width="3"/>
<text class="sub" x="350" y="118" text-anchor="middle">read(range: 3000..&lt;10000) fetches only 4096..&lt;8192, then serves the bytes</text>
<text class="sub" x="40" y="26">totalLength 16384</text>
</svg>
<figcaption>The index tracks ranges, so a read fetches only its gaps and a download resumes where it stopped.</figcaption>
</figure>

## The store

`BlobStore` is an actor made from an engine with `makeBlobStore`,
which wires it to the engine's transport, store, and session and
installs the gone-blob handler described below.  Its configuration
is a directory, a cache limit in bytes with a default of half a
gigabyte, and whether to exclude the directory from backup, which
defaults to true since everything in it can be fetched again.

The reads and writes are these.

- **`status(_:)`** returns the record, or `nil` for a blob never
  touched.
- **`url(for:)`** returns the file of a complete blob, or `nil`.  An
  app hands this to a player or a share sheet.
- **`read(_:range:)`** returns bytes from a range, first downloading
  whatever parts of the range are missing.  This is the entry point
  for an `AVAssetResourceLoaderDelegate`, which asks for byte ranges
  as the player seeks, and the delegate itself stays in the app.
- **`download(_:contentType:pin:)`** fetches the whole blob, resuming
  from whatever ranges are present, and returns its file.  With
  `pin: true` the blob is marked pinned first.  A content type is
  recorded and names the file; given for a blob already held under
  another type or none, it renames the file, since the bytes cannot
  have changed.
- **`pin(_:)`** and **`unpin(_:)`** mark blobs; `pin` also downloads
  any that are incomplete.
- **`evict(_:)`** removes a blob's file and record, pinned or not.
- **`enforceCacheLimit()`** deletes least recently used unpinned blobs
  until the cached bytes fit the limit.  `download` calls it after
  every completion, so a cache that is only ever filled through
  downloads stays under the limit by itself.
- **`upload(_:contentType:)`** posts bytes to the session's upload
  URL and returns the `UploadResponse` with the new blob id, for use
  in a later create.

A download expands the session's `downloadUrl` template with the
account id, the blob id, a name, and a content type, and sends a
`Range` header for anything less than the whole.  The transport in
unit 3 parses the `Content-Range` of the 206 that comes back, and the
record adds the range it received.  A whole-blob response with no
range sets the total length from the byte count.

The content type in that template is the one the app gave, or
`application/octet-stream`, and the RFC has the server send it back
as the response's `Content-Type`.  The response header therefore says
nothing about the blob, and the store does not record it.  A type
comes only from the app, which usually has it in the object that
named the blob.

Every lookup squares the record with the disk.  A record whose file is
missing, as when iOS purges a cache directory, loses its ranges and is
fetched again rather than read as holes.

## Superseded blobs

Juke's retagging case is this: the server rewrites a track's tags,
the audio file's bytes change, and because blobs are immutable that
means the Track now has a new `blobId`.  The old blob is still cached
and still plays, but it is the old file.

Two things catch this.  The first is on sync-in.  A type descriptor
names its blob properties, Track's `blobId` and Email's `blobId`,
and when `applyFetched` sees one change, the change set carries a
`BlobChange` with the type, key, property, old id, and new id.  The
app's policy decides what to do: evict the old blob and download the
new one if the old was pinned, or just evict.

The second is on download.  A server that no longer has a blob
answers 404, and the blob store turns that into `BlobError.gone`:
it evicts the record and calls the gone handler, which the engine
installs as `refetchReferrers(of:)`.  That finds every held object
whose blob properties name the gone id and fetches them again, so
the next read of the object has the successor id.  This covers the
case where the app learned of the change before the sync-in did, such
as a push notification that arrived while a download was in flight.

## Where to look

- `Sources/Jinx/BlobStore.swift` is the actor, with the engine
  extension at the bottom.  `BlobRecord` and its range arithmetic are
  in `Sources/JinxStore/Records.swift`.
- `swift test --filter JinxTests.BlobTests`.
  `rangedReadsFetchOnlyTheGapsAndResumeIntoAWholeDownload` is the
  figure above; `typedDownloadNamesTheFileWithTheTypesExtension` and
  `aTypeGivenLaterRenamesTheFileWithoutFetchingAgain` are the file
  names; `cacheEvictsLeastRecentlyUsedButNeverPinned` is the
  limit; and `supersededBlobIsReportedOnPullAndGoneOnDownloadTriggersRefetch`
  is both halves of the last section.

Next: [Running the engine](12-running.md).
