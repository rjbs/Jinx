# 3. The wire

RFC 8620 is exact about what crosses the wire, and a client that only
had to send one method call could do it with a string template.  The
chores begin with the second call: call ids, back-references between
calls, three different places an error can appear, and a session
resource full of limits you are expected to honor.  `JinxWire` is the
module that does those chores.  It knows RFC 8620 and nothing about
sync: no state strings are stored here, no decisions are made about
what to fetch.  It takes a request you describe, sends it, and gives
you back something typed.

## The session

Everything starts with the session resource, section 2 of the RFC.
`Session` holds it decoded: the capabilities, the accounts, the primary
account per capability, the API URL, and the three URL templates for
download, upload and push.

Two things in it matter to the rest of Jinx.  The first is `core`, the
`urn:ietf:params:jmap:core` capability object, which carries the limits
a client must honor: `maxObjectsInGet`, `maxCallsInRequest`,
`maxSizeRequest` and the rest.  The engine chunks its `/get` calls to
`maxObjectsInGet` and its `/set` calls to `maxObjectsInSet`, and it
takes those numbers from here.  The second is the URL templates.
Download and upload URLs are RFC 6570 templates with variables such as
`{accountId}` and `{blobId}`, and `URLTemplate` implements the level
of that RFC the session needs, which is level 1: substitute a variable,
percent-encode it, and expand an undefined variable to nothing.

The URLs in a session may be relative.  `Session(json:base:)` takes
the URL the resource was fetched from and resolves against it, which
is why `JMAPClient.fetchSession` passes the final URL of the response
rather than the one it asked for, since a redirect may have moved it.

## A request

A method call is the triple `[name, arguments, callId]`, and
`Invocation` is exactly that, with the arguments as a `JSONValue`.  A
`Request` is a `using` list and an array of invocations.  You could
build one by hand, but call ids and back-references are where hand
assembly goes wrong, so `RequestBuilder` does it:

```swift
var builder = RequestBuilder(using: [Session.coreCapability, TaskTypes.capability])

let changes = builder.call("Task/changes", [
  "accountId": .string(accountId),
  "sinceState": .string(state),
])

builder.call(
  "Task/get",
  ["accountId": .string(accountId)],
  references: ["ids": changes.reference("/created")]
)

let request = builder.request
```

Each `call` appends an invocation, assigns it the next call id, and
returns a `Call` handle.  The handle's `reference(_:)` makes a
`ResultReference`, section 3.7 of the RFC, to a pointer within that
call's response.  Passing it in `references` stores it under the
`#`-prefixed key and removes any literal argument of the same name,
which is what the RFC requires: `ids` and `#ids` may not both appear.
The pointer uses the RFC 6901 spelling with the leading slash, and
`/list/*/id` works as the RFC describes, collecting one value from
each element of an array.

The request's JSON has `using` sorted, so that the same logical request
always serializes the same way; the scripted server in unit 13 relies
on that when it compares requests.

## A response

`Response` is the mirror: an array of invocations under
`methodResponses`, and the `sessionState` the server reported.
`responses(to:)` returns every response with a given call id, in
order, because the RFC allows one call to produce several responses.
`response(to:)` returns the first.

An invocation whose name is `error` is a method error.  `result()`
either returns the arguments or throws the `MethodError`, so the
usual reading of a response is one line:

```swift
let got = try GetResponse(json: try response.response(to: get.callId)!.result())
```

`GetResponse`, `ChangesResponse`, `SetResponse`, `QueryResponse` and
`QueryChangesResponse` are the standard method shapes of section 5,
decoded from the arguments.  Each is strict about the members the RFC
makes mandatory, so a `/changes` response without `newState` is a
`malformed` error rather than an empty string, and lenient about the
optional ones.  The query responses keep every property beyond the
standard set in `extra`, because servers extend them: Fastmail's
category sort returns a `groupByCounts` that a mail client wants and
the RFC does not know about.

Beside the decoders are argument builders, `getArguments`,
`changesArguments`, `setArguments` and so on, that omit what is not
set.  They exist so that the engine's requests are built in one place
and so that a hand-built request looks the same as an engine-built
one.

## Three kinds of error

A JMAP exchange can fail at three levels, and the RFC gives each its
own shape.  Jinx gives each its own type, and which one you catch tells
you how much of the request failed.

<figure class="jinx-figure">
<svg viewBox="0 0 760 350" width="760" height="350" role="img" aria-labelledby="errors-title">
<title id="errors-title">Where each kind of error lives</title>
<rect class="ext" x="10" y="10" width="740" height="330" rx="6"/>
<text class="nm" x="24" y="34">HTTP exchange</text>
<text class="sub" x="736" y="34" text-anchor="end">JMAPError: transport, httpStatus, request (problem details), malformed</text>
<rect class="blk" x="30" y="52" width="700" height="270" rx="6"/>
<text class="nm" x="44" y="76">Response</text>
<text class="sub" x="716" y="76" text-anchor="end">methodResponses, sessionState</text>
<rect class="blk" x="50" y="94" width="660" height="210" rx="6"/>
<text class="nm" x="64" y="118">Invocation</text>
<text class="sub" x="696" y="118" text-anchor="end">MethodError when the name is "error": serverFail, stateMismatch, cannotCalculateChanges, …</text>
<rect class="blk" x="70" y="136" width="620" height="150" rx="6"/>
<text class="nm" x="84" y="160">Foo/set response</text>
<text class="sub" x="676" y="160" text-anchor="end">created, updated, destroyed</text>
<rect class="blk" x="90" y="178" width="580" height="90" rx="6"/>
<text class="nm" x="104" y="202">notCreated, notUpdated, notDestroyed</text>
<text class="sub" x="104" y="226">SetError per id: invalidProperties, notFound, forbidden, …</text>
<text class="sub" x="104" y="248">one object failed; the rest of the call succeeded</text>
</svg>
<figcaption>Each level of nesting is a smaller failure.  The engine handles the outer two by retrying and the innermost per object.</figcaption>
</figure>

**`JMAPError`** is anything that stops you getting a decoded response.
Its cases are the network failing before any HTTP response
(`transport`), a non-success status with no JMAP body (`httpStatus`),
the server rejecting the whole request with a problem-details object
in the form of RFC 7807 (`request`, carrying a `RequestError` whose
`kind` classifies the URNs of section 3.6.1), a body that is not the
shape the protocol requires (`malformed`), and a session resource
without a usable API URL (`badSession`).  Every transport method is
declared `throws(JMAPError)`.  That is a typed throw, a Swift feature
by which a function names the one error type it can throw, so the
caller can switch over the cases exhaustively instead of casting.

**`MethodError`** is the `error` response to one method call, section
3.6.2.  Its `type` is the bare name, and the well-known ones are
constants on the type: `serverUnavailable`, `stateMismatch`,
`cannotCalculateChanges`, `requestTooLarge`.  Other calls in the same
request may have succeeded.  Anything in the error object beyond
`type` and `description` is kept in `extra`, since `limit` and friends
live there.

**`SetError`** is the per-object failure inside a `/set` response,
section 5.3.  The call succeeded; this one create, update or destroy
did not.  `properties` is filled for `invalidProperties`, and
`existingId` for `alreadyExists`, which unit 9 uses to adopt an object
the server says it already has.

The engine's classification of all three into "retry later" and "give
up on this object" is the subject of unit 9.  Here the point is only
that the three are distinct types, so no code anywhere has to look at
a string and guess which level it came from.

## The transport

`JMAPTransport` is the protocol the engine speaks to the network
through, and it has five operations: fetch the session, send a
request to an API URL, upload a blob, download a blob with an optional
byte range, and open a server-sent event stream.  `JMAPClient`
implements it over `URLSession`, and the test harness implements it
over the in-process server, so every engine test runs with no network
and no mocking of HTTP.

`JMAPClient` takes an `Authenticator`, which adds credentials to a
`URLRequest`.  `BearerToken` and `BasicCredentials` are provided, and
the protocol is one async method so an app with a token that expires
can refresh it in place.

Of the five operations, two are about blobs and are covered in unit
11.  One detail belongs here: `download` sends a `Range` header when
asked, and parses the `Content-Range` of a 206 response into the range
actually returned and the total length, which is what makes a resumed
download possible.

A non-success HTTP status is tried as a problem-details body first and
becomes a `JMAPError.request` if it parses, and a `JMAPError.httpStatus`
otherwise.  That ordering is what makes `limit` errors, which arrive as
HTTP 400 with a JSON body, land in the typed path.

## Push

The session's `eventSourceUrl` is a template with `types`, `closeafter`
and `ping` variables.  `EventSourceClient.url(from:types:closeAfter:ping:)`
expands it, and the client then holds the connection open:

```swift
let client = EventSourceClient(transport: transport, url: url)
for await event in client.events() {
  switch event {
  case .stateChange(let change):  // change.changed[accountId]?["Task"] is a state string
  case .connected, .ping, .disconnected: break
  }
}
```

Three pieces make this up.  `ServerSentEventParser` is an incremental
parser for the `text/event-stream` format, fed one line at a time, and
it implements exactly as much of the SSE grammar as JMAP push uses:
`event`, `data`, `id`, `retry` and comments.  `JMAPClient.events(from:)`
reads bytes from `URLSession`, splits lines, and yields parsed events
until the connection ends.  `EventSourceClient` wraps that in a loop
that never ends on its own: when the connection drops it yields
`.disconnected` with the delay it will wait, sleeps, and reconnects.
The delay comes from a server-sent `retry` hint when there was one,
and otherwise from `Backoff`, which grows by a multiplier up to a cap.
A connection that delivered any event resets the backoff; one that
failed outright keeps climbing.

A `state` event carries a `StateChange`, section 7.1: a map from
account id to type name to the new state string.  The engine in unit
12 turns that into a flag that a type needs syncing in and does nothing
else with the string itself, because the only way to learn what
changed is to ask `/changes`.

## Assembling a sync-in by hand

Here is the request the engine will build for you in unit 8, written
out, so you can see that there is nothing in it but the RFC.  The goal
is one round trip that learns what changed since the last state and
fetches the created and updated objects.

```swift
var builder = RequestBuilder(using: [Session.coreCapability, TaskTypes.capability])
let args: JSONValue = ["accountId": .string(accountId)]

let changes = builder.call("Task/changes", .changesArguments(accountId: accountId, sinceState: state))
let created = builder.call("Task/get", args, references: ["ids": changes.reference("/created")])
let updated = builder.call("Task/get", args, references: ["ids": changes.reference("/updated")])

let response = try await transport.send(builder.request, to: session.apiUrl)

let delta = try ChangesResponse(json: try response.response(to: changes.callId)!.result())
let new = try GetResponse(json: try response.response(to: created.callId)!.result())
let changed = try GetResponse(json: try response.response(to: updated.callId)!.result())
```

On the wire, the request is this:

```json
{
  "using": ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:tasks"],
  "methodCalls": [
    ["Task/changes", {"accountId": "a1", "sinceState": "s41"}, "c0"],
    ["Task/get", {"accountId": "a1",
                  "#ids": {"resultOf": "c0", "name": "Task/changes", "path": "/created"}}, "c1"],
    ["Task/get", {"accountId": "a1",
                  "#ids": {"resultOf": "c0", "name": "Task/changes", "path": "/updated"}}, "c2"]
  ]
}
```

Now consider what this code does not do, because each omission is a
unit of this manual.  It does not check that `delta.oldState` equals
the state it sent, and if it does not, the server moved on between
your requests and you are about to apply changes against the wrong
baseline.  It does not loop on `delta.hasMoreChanges`.  It does not
notice that `delta.destroyed` names objects you hold.  It does not
chunk the `/get` calls to `maxObjectsInGet`, so a large delta will
draw `requestTooLarge`.  It does not handle `cannotCalculateChanges`,
which means throwing the state away and starting over.  It does not
know that one of the updated objects has a local edit waiting to be
synced out.  And it does not store anything.  The wire is the easy part.

## Where to look

- `Sources/JinxWire/`: `Session.swift`, `RequestBuilder.swift` and
  `Invocation.swift` are the request and response shapes;
  `StandardMethods.swift` the typed method responses and argument
  builders; `Errors.swift` the three error types; `Transport.swift`
  the protocol and `JMAPClient`; `ServerSentEvents.swift` and
  `EventSourceClient.swift` the push channel; `URLTemplate.swift` the
  templates.
- `swift test --filter JinxWireTests`.  The test named
  `builderAssignsIdsAndWiresReferences` shows the builder;
  `setResponseWithEveryOutcome` decodes a `/set` response with a
  success and a failure of each kind; and
  `eventSourceClientReconnectsWithBackoff` drives the push loop
  through a dropped connection.

Next: [Patches](04-patches.md).
