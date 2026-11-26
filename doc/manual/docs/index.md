# The Jinx Manual

Jinx is a Swift library that keeps a local, offline-usable copy of the
JMAP data in an account and keeps that copy in sync with the server.
This manual walks through its components, its layers, and the way they
fit together.

It is written for someone who knows JMAP well as a protocol and has not
implemented a client.  It assumes you can read RFC 8620 without help,
and it does not repeat it.  What it does instead is take each problem
the protocol leaves to the client and show what Jinx does about it.

It is not reference documentation.  The public API is documented in the
source, and the design that preceded the code is in
[`doc/plan.md`](https://github.com/rjbs/jinx/blob/main/doc/plan.md).
When this manual and the code disagree, the code is right and the
manual has a bug.

## How to read it

The units are in order and build on one another.  The first five are
the foundation: what Jinx is, how it represents JSON, what a request
looks like, how it computes and applies patches, and the model of a
synced object that everything else rests on.  The next four are the
machinery: the store, type descriptors, sync-in, and sync-out.  Then come the
extensions for large accounts and large files, the run loop, the
tests, and a capstone that builds a small client end to end.

Start with [Orientation](01-orientation.md).
