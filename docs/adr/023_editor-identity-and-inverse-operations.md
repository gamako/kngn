# ADR-023: Stable identity and the inverse-operation contract for editor applications

Status: accepted (contract); the migration of existing applications is deferred, see
"Migration"

## Context

An editor application built on this repository gets three parts. Two exist:

| Part | Where it lives |
|---|---|
| **Bookkeeping** — actor, command log, transactions, network relay, per-actor undo | `core/control/command.zig`. The pixel editor and the patch canvas both plug into it the same way |
| **Payload storage** — history as bytes, and somewhere to keep them | `core/control/command_io.zig`, `libs/paint/src/undo_io.zig`, `libs/appshell/src/history_journal.zig` (ADR-022) |
| **Identity and the inverse-operation contract** | this document |

The third is what the first two rest on, and it was the one left implicit. Bookkeeping can
record that an actor reverted step 7; storage can hand back the bytes of step 7. Neither can
say what step 7 *refers to*. If the answer is "the layer that is currently third", then the
record means something different the moment a layer is inserted — and something different
again in the next session.

### What the applications do today

The patch canvas already follows the rule. `NodeId` is monotonic, never reused, and kept
separate from the runtime handle, so the wire format, saved patches and probe output all
name nodes by an identity that outlives any rearrangement.

The pixel editor is half-way there, and the half that is missing is load-bearing:

- `LayerId` is a stable, never-reused `u64` ("Document allocates on create").
- `CelId` is also never reused: `next_cel_id` only increments, and a released slot becomes
  `null` rather than being handed out again.
- **A frame has no identity at all.** `Frame` is `{ duration_ms: u32 }`.
- **Undo payloads reference position, not identity.** `Op` carries `layer_idx` and
  `frame_idx` — around 110 references across `libs/paint/src/document.zig` and 33 in the
  Op codec.

This is not a stylistic observation; the consequence is written into the code. Reverting a
single step out of the middle of the stack (`Document.revertByHandle`) is gated by
`canRevertByHandle`, which **refuses every operation that is not a plain paint stroke** and,
even for a paint stroke, re-validates `layer_idx` and `frame_idx` against the current
document and checks that the grid cell still holds the expected cel. That guard is the exact
cost of position references: with them, out-of-order undo of a structural edit cannot be made
safe, so it is not offered.

Two further consequences show up now that history is stored (ADR-022):

- A stored payload holding `layer_idx = 2` does not mean "that layer" after a restart. It
  means "whatever is second now". The document digest binding in ADR-022 keeps that from
  being *wrong* today — history is only restored against the exact bytes it was recorded
  for — but it is a guard against the symptom, not a fix for the cause. Any future feature
  that relaxes the binding, such as recovering unsaved work, immediately needs identity.
- Redo entries have no stable identity of any kind (a re-push allocates a fresh handle), so
  the storage layer cannot recognise a redo payload it has already written and re-writes it
  on every save. That is a small, contained cost today, and it is the same defect in
  miniature.

## Decision

### 1. Identity discipline

A domain object that an operation can refer to — a layer, a frame, a node, a cel — **has a
stable id**:

- Allocated monotonically from a counter the document owns, and **never reused**, not even
  after the object is deleted. Reuse is what turns a stale reference into a silently wrong
  one instead of a detectably dead one.
- Distinct from position. An index is a *view* of the current ordering: it is correct for
  layout, drawing, keyboard traversal and anything the user sees, and it is meaningless the
  moment the ordering changes.
- Distinct from a runtime handle or slot, where one exists. The patch canvas keeps
  `NodeId` and `Handle` apart for exactly this reason; a slot is an allocation detail, an id
  is the thing a record names.

**Undo payloads, network relay and persistence reference ids. Only presentation references
position.** Deletion is by id and does not renumber anything.

Rejected: **generation-tagged indices** (an index plus a counter bumped on reuse). They
detect a stale reference, which is better than nothing, but they do not survive
rearrangement — the point is not only "is this still alive" but "is this still the same
thing" — and they add a validity rule to every call site. A never-reused id answers both
questions with an equality test.

Rejected: **content hashing as identity.** Two identical blank layers are not the same
layer, and a layer that is edited does not become a different one.

### 2. The inverse-operation contract

A command that participates in undo provides three things:

- **do** — apply the change.
- **inverse** — a value that reverses it, carrying whatever the reversal needs: the previous
  pixels, the previous ordering, the removed object itself. The inverse is data, not a
  re-computation, because re-computing it needs the state the operation already changed.
- **liveness** — whether the inverse can still be applied.

**Liveness is decided by asking whether the ids the operation names still exist. It is never
decided by asking whether an index still matches.** The distinction is the whole point: an
index test conflates "the target is gone" with "the target moved", and a user who reorders
layers has not destroyed their history.

An operation that names only live ids is reversible out of order. That is what unlocks
per-actor undo for structural edits, and what makes relaying a structural edit to another
process safe: the receiving side resolves the same ids, not the same positions.

The bookkeeping layer already supplies the surrounding machinery (`CommandAdapter`'s
`canUndo` / `applyUndo` are where liveness and inverse are plugged in). This ADR fixes what
those callbacks must be written in terms of.

### 3. How storage plugs in

ADR-022's journal stores an operation's payload verbatim and hands it back unchanged. It has
no opinion about what the bytes mean, which is what makes it reusable — and also what makes
this contract its precondition: the storage layer cannot repair a reference that was a
position when it was written.

Concretely, for an application on this rail:

- Encode each inverse as a self-describing entry (the shape of `command_io` and `undo_io`:
  kind, version, length), so an unknown record can be skipped rather than fatal.
- Give each entry a stable id from the store (`RecordId`, which survives compaction) and let
  the small mutable index name entries by that id — the split ADR-022 describes.
- Bind history to document content, and start empty when it does not match.
- Once payloads reference domain ids rather than positions, the binding can be relaxed
  deliberately (for instance, to recover work that was never saved) rather than being the
  only thing standing between a stale index and a wrong edit.

### 4. Contract, not shared code

This ADR defines a contract. It does not add a library that applications inherit from.

Extracting a shared undo container from the two existing applications was considered and
rejected on its own merits: their stores genuinely differ — a variable-length heap-owning
stack against a fixed-size array of plain data — and forcing them into one would change how
one of them behaves. Identity discipline is a different kind of thing. It is a rule about
what a record may contain, and it costs nothing to follow in either shape. Deciding a rule
from above is not the same question as extracting code from below, and it gets a different
answer.

What is shared is what already exists: the command model, the entry codecs, and the journal.

## Migration

**Decision: the contract is binding for new work, and existing applications move
opportunistically rather than in one pass.**

### The patch canvas

Already conforms. Nothing to do.

### The pixel editor

Not conforming, and the work is real. Broken into the pieces that can land separately:

| Step | Scope | Risk |
|---|---|---|
| Give `Frame` a stable id | A `FrameId` plus a counter on `Document`; the frame list gains a field | Low. **There is a worked precedent**: `LayerId` was added to the `LAYR` chunk in schema v3, and the loader assigns ids deterministically to older files that lack them. A `FrameId` in `FRAM` is the same change at schema v5, with v4 files getting ids on load the same way |
| Move undo payloads from position to id | Around 110 references in `document.zig` and 33 in the Op codec; every `Op` variant that names `layer_idx` or `frame_idx` | **The largest piece.** Mechanical but wide, and each variant needs its own resolution point (id to current index) at apply time |
| Widen `canRevertByHandle` | Drop the "paint only" restriction once liveness is an id lookup | Moderate. This is the payoff, and it is also where a mistake is most visible to a user |
| Op codec version | The entry version bumps; an older record is rejected by the reader | Low, and it is why the version field exists. The cost of rejecting one is losing stored history for that document, not corrupting it |

Explicitly **not** required: changing how the cel grid is stored. The grid is a fixed-length
array indexed by layer appearance order, and that is a document-format representation, not a
reference held by an operation. Positions inside a saved document are fine; positions inside
a *record about* a document are not. Keeping this out of scope is most of what keeps the
migration tractable.

Why not do it now: the change touches the undo path of every structural edit at once, and it
is the one part of the editor with no cheap external oracle — a mistake produces a document
that is subtly wrong rather than a build that fails. It wants its own task, with the widened
out-of-order undo as the acceptance test that proves it worked. Nothing in the current
behaviour is incorrect meanwhile; it is narrower than it could be, and `canRevertByHandle`
states that narrowness honestly in code.

## Where a new editor application starts

Read, in this order:

1. `docs/app-authoring.md` — the published surface, and how to build against it at all.
2. `core/control/command.zig` — the bookkeeping: actor, command log, transactions, the
   adapter callbacks. This is the rail's spine.
3. **This ADR** — what an id is, what an inverse is, and how liveness is decided. Follow it
   before writing the first operation; retrofitting it is the expensive path, as the
   migration table above shows.
4. ADR-022 and `libs/appshell/src/history_journal.zig` — persisting history, once operations
   reference ids.
5. `docs/netsync.md` and ADR-014 — relaying operations to another process, which the same
   id discipline makes safe.

Following 2 and 3 gets undo, per-actor undo, relay and persisted history from parts that
already exist.

## Consequences

- New editor code pays a small, constant cost: an id counter per object kind, and operations
  that resolve an id when they apply instead of storing a position.
- The pixel editor keeps its current, narrower out-of-order undo until it is migrated, and
  the reason is now recorded rather than folklore.
- The document-content binding in ADR-022 remains necessary while position references exist.
  It is not made redundant by this contract — it guards against a changed file, not against
  a stale index — but the class of problems it has to guard against shrinks.
