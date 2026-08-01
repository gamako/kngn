# ADR-022: Editor history persistence — a central append-only journal

Status: accepted

## Context

The pixel editor keeps two runtime structures that together are "the history":

- `CommandLog` plus `Executor` (`core/control/command.zig`) — who ran what, in what order,
  which entries have been reverted. This is what the history panel and `digest history`
  show, and it records the actor, so a human step and an agent step stay distinguishable.
- `UndoStack` (`libs/paint/src/document.zig`) — the payloads that make undo actually undo:
  up to 128 `Op` values, each owning the pixels or structure needed to reverse one edit.

Codecs already exist for both (`core/control/command_io.zig` and
`libs/paint/src/undo_io.zig`). They are container-independent: each produces
self-describing entries (kind, version, length) that a reader can skip without
understanding. What did not exist is a container — a place to put those bytes so that
history survives closing the application.

Everything below concerns that container. The document format is untouched.

## Decision

### 1. A central store, not a sidecar and not inside the document

The journal lives in the application-data directory
(`<app data>/history/<hash of the document path>.hjr`), not next to the document and not
inside it. This is the shape Vim's persistent undo and JetBrains' local history use.

The consequence that matters to a user: **"save" still means one document file**. Copying,
mailing, or version-controlling that file behaves exactly as before, and a project is still
a single file rather than a folder.

Rejected:

- **A sidecar file next to the document.** A graphical editor that permanently litters the
  user's folder with a second file per document has almost no precedent, and the two files
  come apart the moment the document is moved by any other tool.
- **A project directory or bundle.** A bundle only looks like a file where the desktop
  environment cooperates, which in practice means an application bundle on one platform;
  a plain executable gets a plain folder everywhere. It would also require directory
  selection in the file dialogs, and it contradicts the flat, directory-less store the
  browser build has. There is no asset story that would pay for it yet.
- **Inside the document.** The document container carries a trailing CRC over everything
  before it, so nothing can be appended in place: every history update would rewrite the
  whole document. That is the cost this design set out to avoid.

The storage interface below is container-agnostic, so this decision is reversible without
touching the composition layer.

### 2. Append-only framing with per-record CRC

`libs/appshell/src/history_journal.zig` frames opaque byte records:

```text
header:  magic "HJN1" | format_version u16 | flags u16 | path_len u32 | header_crc32 u32 | path bytes
record:  payload_len u32 | id u64 | kind u8 | version u16 | flags u8 | payload | record_crc32 u32
```

The record CRC covers the whole frame except itself, so a corrupted length is caught along
with corrupted payload bytes. On open the store walks the records and stops at the first
frame that does not verify, truncating the file there. Everything before it survives.

A corrupt **header** is treated differently: the store reports it and changes nothing,
because the start of the record region would only be a guess and truncating on a guess can
destroy an intact journal. The editor then starts that document with no history and lets
the next save replace the file.

The store never interprets a payload. `kind` and `version` are the caller's, mirroring the
entry headers the codecs already emit, so a record written by a newer version survives a
round trip through an older reader.

### 3. Binding a journal to a document: path, then content digest

A journal names the canonical document path in its header; opening it for a different path
fails rather than mixing two documents (the file name is a hash, so a collision is possible
and must be detected, not assumed away).

Content is matched by a 64-bit digest of the exact document bytes, stored in the index
record described below. When it does not match — the file was edited elsewhere, restored
from a backup, or produced by another tool — the document opens with **no history**. That
is the same path a document that never had a journal takes, so there is exactly one
behaviour to reason about, and a stale history can never be applied to content it does not
describe.

**The digest is deliberately not CRC-32.** The document container ends with the CRC-32 of
everything before it. Running CRC-32 over such a container — body plus its own checksum —
always yields the algorithm's residue constant, whatever the body was. A binding built on
it would accept every well-formed document, which is the exact opposite of a binding. This
was observed in practice before it was reasoned about: every document matched every
journal. A non-CRC hash has no such fixed point. `history_persist.documentDigest` is the
single place this is decided, and a test pins it by constructing two different
self-checked containers and asserting that CRC-32 collapses them while the digest does not.

### 4. Immutable payloads plus a small mutable index

Two record kinds are composed on top of the journal
(`apps/editor/apps/pixie/history_persist.zig`):

- **op**: one `Op`, encoded by `undo_io.encodeOpPayload`. An `Op`'s bytes never change once
  it exists, so its record is written once and referenced by id afterwards.
- **index**: which op records form the undo and redo stacks, in order, with each undo
  entry's handle and owner tag; the next handle; the command-log snapshot from
  `command_io`; and the document digest.

An index is a few kilobytes even with a full 128-step stack. This split is what makes the
journal append-only in practice: an edit contributes its payload once, and a save
contributes one small index. Nothing already written is rewritten.

Rejected: **recording stack mutations and replaying them** (a seed state plus
`push`/`undo`/`redo` events). Replay is a second implementation of the stack's semantics,
kept in step with the first only by discipline; when the two disagree the user gets a
history that never existed. Naming the members of a state directly cannot drift.

Redo entries are re-written on each save rather than matched to existing records, because a
redo entry carries no handle — a re-push allocates a fresh one — and there is no other
stable identity to match on. The redo stack is short in practice and the superseded copies
are collected (see below).

### 5. Two levels of cap

- **Per document**: a byte budget (64MiB) spent newest-first. An ordinary stroke is a pixel
  diff of a few kilobytes, so this is unreachable in normal use; it exists for structural
  edits that carry whole layers. A merge-down on a maximum canvas (16M pixels) holds two
  full pixel arrays plus a cel snapshot — roughly 192MB in a single `Op`. Spending the
  budget from the newest end means the steps a user is most likely to undo are the ones
  that survive, and the steps beyond it stay in memory for the session and are simply not
  persisted. A save is never refused and never fails because one edit was large.
- **Per store**: a global budget (512MiB by default) enforced by a sweep at startup. It
  removes journals whose document is definitively gone, then journals nothing has touched
  in thirty days, then evicts least-recently-used ones until the directory is under budget.
  A journal is treated as orphaned **only** on a definite "not found": a permission failure
  or an unmounted volume leaves it alone, because "cannot see it right now" is not "gone".
  The sweep examines a bounded number of files per launch.

Rejected: **refusing to publish a history when one edit is too large**, which is what a
per-record threshold with an error message amounts to. It converts a size limit into a
visible failure and leaves the user with no history at all rather than with the most recent
steps.

Records the newest index does not reference are dropped by id after each save. Dropping by
id rather than only from the front is what keeps a superseded index from accumulating one
per save: it sits *after* the op records it replaced, where a front-only drop can never
reach it.

A drop only marks a record dead **in memory**; `compact` is what makes it stick. Skipping
the compaction leaves the dead frames on disk, where the next open indexes them as live
again — so the drops are undone by every restart and the file grows without bound.
Reclaiming therefore runs at the end of a save whenever anything was dropped and the
journal is small enough that rewriting it is cheap (the normal case, a few hundred
kilobytes); a large journal waits until the dead bytes are worth the copy. Compaction
copies frames verbatim, so **nothing is ever re-encoded** — the expensive part, turning a
possibly enormous `Op` into bytes, still happens exactly once, at the save where that `Op`
first appears.

Reuse depends on the editor keeping the map of which `Op` handles are already stored. The
journal is therefore rebound only when the document actually changes: re-binding on every
save would discard that map and write every payload again.

### 6. Durability boundary

`append` does not sync. `sync` is explicit and taken twice per save: once after the op
payloads, so they are durable before the index that names them, and once after the index,
which is the commit point.

What each crash costs, given that the document file is authoritative and the history is
auxiliary:

| Crash point | Result |
|---|---|
| During an append | The torn final frame is truncated at the next open; earlier records survive |
| After editing, before saving | The document is unchanged, and no index describes that state, so it opens with the history of the last save |
| After the document is written, before the index | The document is valid; history opens empty |
| After the index sync | Document and history both restore |
| During compaction | Either the previous journal or the new one, never a mixture |

Paying an fsync per edit would add latency to every stroke to protect data that is by
construction recoverable-or-not-needed. It is not worth it.

One limit is inherited rather than chosen: the atomic-write helper syncs the replacement
file but not the parent directory, because Zig 0.16's portable directory API has no
directory-sync operation. So "either generation, complete" is guaranteed against a process
crash; against sudden power loss the rename itself is weaker. The guarantee is stated that
way rather than overclaimed.

### 7. Main-thread I/O

Appends, the open-time scan, and restore all run on the main thread.

`Document`, `UndoStack`, `CommandLog` and `Executor` are not thread-safe, and undo has a
synchronous interaction contract — a background write would need a snapshot of exactly the
state a foreground edit is mutating. The work does not justify that: a save appends one
small index plus whatever payloads are new, against an autosave that already re-encodes the
entire document on the main thread every second while a document is dirty. Compaction is
the only expensive case, and it runs at a save that has crossed a size threshold, not per
edit.

### 8. Module placement

The store lives in `libs/appshell` and imports nothing but `std` and the atomic-write
helper. The composition — what a record means — lives with the editor. The dependency
direction (`apps → kit → libs → core → platform`) forbids a library reaching up into the
editor's command model, and a store that frames opaque bytes is the more useful component
anyway: the same journal serves any caller with an append-mostly record stream.

## Storage interface

```zig
append(kind, version, payload) -> RecordId   // event time: an edit, a save
read(gpa, id)                   -> OwnedRecord
tail(out: []RecordInfo)         -> []RecordInfo
scan(ctx, visit)                             // framing only; no payload, no allocation
drop(id) / dropOldest()                      // cap enforcement
compact()                                    // reclaim dropped space, ids preserved
sync()                                       // the durability boundary
stats()                          -> Stats
```

`RecordId` is an opaque, monotonically increasing `u64` assigned on append. It is not a file
offset, and it **survives compaction**, which is what lets one record reference another by
id. Dropped ids read back as `error.NotFound` and are never reissued.

Two implementations exist and both are exercised by the same contract test: `MemoryStore`
(tests, and any run without a writable application-data directory) and `NativeStore` (the
append-only file). `scan` and `tail` deliberately expose framing only, so opening a journal
never loads payloads it will not use.

**The browser build holds no store.** There, `paths.openAppDataDir` fails with
`error.PersistenceUnsupported` because the filesystem shim is a flat, directory-less
in-memory store. Absence is modelled as `?Store` rather than as a "null store", so
unavailable persistence cannot be mistaken for successful persistence.

### What this interface does not commit to

A database-backed implementation is not excluded: an insert, a lookup by the same explicit
id, a delete plus vacuum, and a commit cover the surface. It is not adopted — it would put
a C dependency into a pure-Zig-plus-platform-API project and would additionally need a
virtual filesystem layer for the browser target, to solve a problem that does not exist at
128 records per document.

**A remote store is out of scope, deliberately and not merely for now.** If `read(id)` went
to a network, undo would become asynchronous and able to fail, and the interaction contract
would change with it: progress indication, retries, and a way to show that undo did not
work. That is a different application, not a different storage backend, and building the
whole undo path around the possibility would leave that complexity in place permanently.
The related use — several processes sharing one history — is already networked concurrent
editing's job, and its authority model is settled in ADR-014; treating it as a storage
concern would give the same question two answers.

## Consequences

- History is restored as of the **last save**. Undo and redo performed after a save and
  before the next one are session state; they are not persisted, because the index is what
  binds a history to document bytes and only a save produces new bytes.
- A document opened after its file changed behind the editor's back loses its history
  rather than acquiring a wrong one.
- Visual metadata for the history panel (thumbnails, bounding boxes) is runtime-only and
  is not restored; the entries themselves, with actor and revert state, are.
- The existing autosave envelope is unchanged. This journal does not yet absorb crash
  recovery of unsaved work: doing so needs records written between saves, which the index
  format allows but the editor does not yet emit.
