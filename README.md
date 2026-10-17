# Jinx

Jinx is a Swift library for keeping a local, offline-usable copy of JMAP
data in sync with a server that implements standard JMAP semantics
(RFC 8620).  It serves well-specified types such as JMAP for Mail and JMAP
for Tasks, and application-defined types such as a music library's Track
and Playlist.

Nothing is implemented yet.  The design is in `doc/`:

- [consumers.md](doc/consumers.md): the applications Jinx must serve and
  what each needs.
- [plan.md](doc/plan.md): the proposed architecture and the order of work.
