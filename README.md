# Jinx

Jinx is a Swift library for keeping a local, offline-usable copy of JMAP
data in sync with a server that implements standard JMAP semantics
(RFC 8620).  It serves well-specified types such as JMAP for Mail and JMAP
for Tasks, and application-defined types such as a music library's Track
and Playlist.

The design is in `doc/`; phases 0 to 2 of the plan are implemented:
the wire, patch, store and engine modules, with a scripted in-process
JMAP server for tests.  Run `swift test` to see it all pass.

- [consumers.md](doc/consumers.md): the applications Jinx must serve and
  what each needs.
- [plan.md](doc/plan.md): the proposed architecture and the order of work.
