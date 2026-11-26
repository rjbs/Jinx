# 2. One JSON

JSON crosses every boundary in a JMAP client.  It arrives from the
wire, it is stored, it is diffed and patched, it is handed to the
application, and it is sent back.  Foundation's `JSONSerialization`
gives you `[String: Any]` for that, and `Any` is the problem: it is not
`Equatable`, so you cannot ask whether two objects are the same; it is
not `Sendable`, so you cannot pass it between actors without a
compiler complaint; and it tells you nothing about what is inside until
you cast.

Jinx has one representation of JSON, `JSONValue`, and it is the only
one on any public surface.  Requests, responses, stored objects,
patches, and change sets all speak it.  This unit is short because the
type is small, but every later unit assumes it.

## The type

```swift
public enum JSONValue: Sendable, Hashable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])
}
```

An enum with associated values is Swift's tagged union, and this one
is the JSON grammar: six cases, the last two recursive.  Because it is
a value type built from value types, it is `Hashable` for free and
`Sendable` for free, which is what lets a `JSONValue` be read on the
engine's actor, stored, and later handed to a SwiftUI view with no
copying discipline to remember.

Numbers are `Double`.  JMAP's `Int` and `UnsignedInt` are bounded at
2^53, which `Double` represents exactly, so nothing JMAP can send is
lost.  An `intValue` accessor returns an `Int` only when the number
has no fractional part and fits.

## Writing JSON in Swift

Every JSON kind but null has a Swift literal, so a `JSONValue` can be
written the way it would appear on the wire:

```swift
let task: JSONValue = [
  "uid": "7d1c…",
  "title": "Write the manual",
  "keywords": ["manual": true],
  "due": .null,
]
```

Null is spelled `.null`, and that is deliberate.  The type has no
`ExpressibleByNilLiteral` conformance, because with one, a bare `nil`
in an expression of type `JSONValue?` would infer as `.some(.null)`
rather than `.none`.  Those mean different things throughout Jinx:
`nil` is "absent" and `.null` is "present, and null".  The comment in
`JSONValue.swift` records that the conformance was tried, and that it
turned "remove this member" into "store a null" twice in one afternoon
before it was removed.

That distinction shows up in the subscript.  Reading `value["due"]`
returns a `JSONValue?`: `nil` if the key is absent or the value is not
an object, `.null` if the key is present and null.  Writing `nil`
removes the key; writing `.null` stores a null.  There is a matching
accessor per kind, `stringValue`, `arrayValue`, and so on, each
returning `nil` for any other kind rather than crashing.

## Serialization

`JSONValue` is `Codable`, so it parses with `JSONDecoder` and encodes
with `JSONEncoder`, and it can appear as a field inside some other
`Codable` type, which is how the store's records carry it.  Two
conveniences wrap that: `JSONValue(parsing:)` from `Data` or `String`,
and `serialized()` to `Data`.

Serialization sorts object keys.  The store keeps every object's JSON
as text, and sorted keys mean two equal values produce identical text,
so a row comparison in SQL means what it looks like it means.

## JMAP's idea of equality

JMAP treats a property whose value is `null` and a property that is
absent as the same thing.  A server may send either; a client that
compares objects with plain `==` will see a difference where the
protocol sees none.  `isJMAPEquivalent(to:)` compares after stripping
null members from objects, recursively.  Array elements are left alone,
since `[null]` and `[]` are different arrays.

This is not a corner case in Jinx.  Three decisions rest on it:

- A local edit that leaves the value JMAP-equivalent to what it was is
  not recorded at all.
- A local edit that restores the server's value drops the pending
  entry, because there is nothing left to send.
- After a sync-in, a pending edit whose result is JMAP-equivalent to what
  the server now holds is dropped, because the server already has it.

Unit 5 returns to all three.

## JSON pointers

JMAP uses RFC 6901 JSON pointers in two places and spells them two
ways.  A `PatchObject` key, in a `/set` update, is a pointer without
the leading slash: `keywords/$seen`.  A `ResultReference` path, in a
back-reference between method calls, has the slash: `/ids`.
`JSONPointer` parses and prints both, and holds the tokens unescaped,
so `~1` and `~0` are handled once, in the right order, and never
thought about again.

```swift
let p = JSONPointer(jmapPatchPath: "keywords/$seen")
p.tokens          // ["keywords", "$seen"]
p.rfc6901         // "/keywords/$seen"
p.isPrefix(of: JSONPointer("keywords", "$seen", "x"))   // true
```

Two operations on `JSONValue` take a pointer.  `value(at:)` walks
objects by key and arrays by index and returns `nil` at the first
missing step.  `setting(_:at:)` returns a copy with a value stored at
the pointer, or with the member removed when the value is `nil`, and
it refuses a path that passes through an array or a scalar.  That
refusal is RFC 8620's rule for patch paths, section 5.3: a patch may
address a member of an object, however deeply nested, but never an
array element.  Jinx's own diff, in unit 4, never produces such a path,
and the check is what makes a patch from elsewhere safe to apply.

## Where to look

- `Sources/JinxJSON/JSONValue.swift` and `JSONPointer.swift` are the
  whole module.
- `swift test --filter JinxJSONTests` runs its tests.  The test named
  `jmapEquivalenceIgnoresNullMembers` is the equality rule in four
  lines, and `settingRefusesArraysAndScalarsOnThePath` is the pointer
  rule.

Next: [The wire](03-wire.md).
