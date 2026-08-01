# ADR-014: Networked concurrent editing — the wire, the authority, and NetworkPolicy

- Status: Accepted
- Date: 2026-07-27
- Scope: the decisions behind networked concurrent editing. The current contract —
  frame table, environment variables, probe output, the two-process procedure — is
  in [docs/netsync.md](../netsync.md) and is not restated here.

## Context

Several editor processes edit one document at once over a persistent TCP
connection. The frame format is an **external compatibility contract**: frame kind
numbers, payload layouts, endianness. `docs/netsync.md` states that contract
precisely, but a reader who wants to *change* it has no way to tell which parts are
load-bearing and which are arbitrary — and concurrent editing is a field with
several well-known architectures, so "why not one of those?" is the first question
anyone will ask.

This ADR records the decisions and what was rejected. Where the record of a
rejection does not exist, that is said plainly rather than reconstructed.

## Decision 1: the wire carries semantic commands, not pixel diffs

An action-carrying frame carries **an action-registry call — a name plus its
arguments** (`stroke 10 10 60 10`). It never carries the pixel diff that the editor's
undo machinery works with. The other kinds are the machinery around that: the
handshake, the join snapshot, rejections and peer metadata.

This is the decision the rest depends on. It buys three things:

- The unit of synchronisation is the unit the observation plane already speaks, so
  the harness, the recipe format and the copilot transport all address the same
  operations. Networking added no second vocabulary.
- Payloads are tiny, and bounded at the same scale as the local command-argument
  budget that dispatch already works within.
- An operation keeps its *meaning* far better than a pixel rectangle would, as long
  as the shared premises hold. Those premises are real: coordinates are validated
  against the receiver's canvas dimensions, and a layer reference must resolve to an
  existing id. A semantic command survives differences a raw diff could not express,
  but it is not size-agnostic.

The cost is a constraint on what may be relayed: **a synchronised operation must be
a deterministic function of the shared document and its own arguments**. Because the
host imposes a total order and every peer applies the same sequence to the same
starting state, an operation may be *relative* to the shared document — moving a
layer by ±1 relative to an id, or adding a layer with no arguments, both relay
correctly. What it may not depend on is **peer-local state**. Each peer has its own
selected layer, tool and colour, so an operation that reads them has two options,
both of which are used: bake the originator's context into the wire form at the relay
entry point — a canonicalised stroke carries its tool, paint parameters and target
layer id (pen, eraser, brush and fill each with their field set) — or be classified
as local, which is what `set_tool` and `set_color` are. That fork is what forces the
classification in Decision 3.

Canonicalisation is total for stroke operations at the relay boundary. A local
caller may still use the legacy form without `tool=`; the origin peer resolves
that form against its own active tool and emits a canonical wire form before the
router sees it. Therefore the legacy form is a local input syntax, not a wire
syntax.

Every accepted stroke wire form carries `tool=` and a stable `layer=#<id>`.
Pen, eraser and brush retain their existing canonical fields. Fill is encoded as
`layer=#<id> tool=fill color=RRGGBB tolerance=N`, so its paint parameters do not
come from the receiving peer's selected tool or colour. A fill operation with a
local selection active is rejected while synced because Canvas.selection is a
peer-local runtime field and is not part of the wire command. When applying a
relayed fill, the receiver's local selection is ignored.

A receiver rejects a stroke COMMIT without `tool=` before drawing. A host rejects
a PROPOSE that reaches the application in that form, and a client fails soft if
an older host sends such a COMMIT. This is deliberately fail-closed: an older
peer may reject the new `tool=fill` spelling or send the old no-tool spelling,
but no peer executes a missing tool from its own local state.

This closes the accepted gap for stroke commands. It does not make unrelated
relay actions safe if they later introduce their own peer-local implicit state;
each such action must still canonicalise or be refused under Decision 1.

## Decision 2: the host is the authority, over PROPOSE/COMMIT

A client sends `PROPOSE`; the host validates, applies, assigns a monotonic `seq`,
and broadcasts `COMMIT` to every client, or returns `REJECT` to the proposer alone.
The host applies its own operations directly and broadcasts, with no proposal round
trip.

The value is a **single serialisation point**. Every peer receives the same commit
sequence in the same order, so **ordering and ordinary conflict resolution become
trivial** and no peer has to reason about concurrent histories.

That is a claim about ordering, and it is worth not overstating it. Peers actually
converging needs more than a total order: the relayed actions must be deterministic
(Decision 1), the join snapshot must export and import cleanly, and an application
failure mid-sequence is handled by disabling networking rather than by repair — the
sequence is authoritative, but nothing reconciles a peer that failed to apply a member
of it. The undo model below adds conditions of its own (ownership, inverse retention,
the join boundary) that the commit order alone does not settle.

### What was rejected

**CRDTs and operational transformation.** These were considered and set aside as a
three-way choice — CRDT, OT, or locking — to be settled by building a two-client
proof of concept first. The proof of concept made the single-authority design work,
and it was kept. The honest form of this record is that CRDT and OT were **never
evaluated in depth**: the simplest design that satisfied the requirement was built,
not the best of three implementations. If document-level concurrency ever needs
offline editing or peer-to-peer topology, that comparison still has to be made.

**A single-writer token.** Because authority is already centralised, restricting
writes to one peer is a *policy* on the same mechanism rather than a different
design: a `writer_peer_id` on the host and one check before accepting a `PROPOSE`.
It was specified as an available fallback and deliberately not built — no such
field exists in the implementation — because unrestricted proposals were judged
sufficient for the current scope. That judgement rests on use, not on measurement.

**Client authority.** Not adopted: it would require each peer to resolve
conflicting histories, which is the cost the single serialisation point exists to
avoid.

**UDP was never evaluated.** The design assumed a persistent stream from the
outset, and no record of weighing a datagram transport exists. Ordered, reliable
delivery of a commit sequence is what the model needs, so TCP is a defensible fit,
but it was not a comparison — it was an assumption.

## Decision 3: NetworkPolicy classifies every action, and the default refuses

Each registered action carries a `NetworkPolicy`. The six values and their
per-role behaviour are tabulated in `docs/netsync.md`; what matters here is the
shape and the default.

**The default is `.reject_when_synced`** — an unclassified action *fails* during a
session rather than doing something plausible. The safe direction for an unclassified
state change is refusal, because the alternative is silent divergence, and
divergence is discovered late and cannot be repaired by retrying.

### Why a policy enum, and not a boolean

An earlier design had `relay_safe: bool`, where `false` meant "apply locally,
immediately". That is wrong in a way worth recording, because it looks adequate:
under it, every destructive-but-unclassified operation — clearing the canvas, adding
or deleting a layer — keeps being applied locally on whichever peer invoked it, and
the documents diverge at once. The flaw was initially read as being about file I/O
(`save`, `open`) only; it was in fact about **every unclassified state change**. A
boolean cannot express "refuse", and refusal is the value the default needs.

### Why the router is symmetric

Both roles consult the policy *before* branching. An earlier revision let the host
skip that check and go straight to apply-and-broadcast, on the reasoning that the
host is the authority and therefore always allowed. The consequence was that
invoking `undo`, `open` or a layer operation **on the host** would apply it locally
and broadcast it despite those actions being classified as refused, and that `save`
— explicitly `.local_only` — could be broadcast. Authority decides *who serialises*,
not *which operations are permitted*.

`open` cannot be softened to `.local_only` for the same reason: it replaces the
whole document, so making it local would diverge the peers rather than isolate them.

## Decision 4: undo is a revert applied forward

Undo does not rewind history. It appends **a new commit that undoes an earlier
one**, in the manner of `git revert` (`PROPOSE_REVERT` / `COMMIT_REVERT`), and only
for the proposer's own operations (`.undo_own`).

Two reasons, and the second is the structural one:

- **It preserves the invariant.** Every peer's state stays "the result of applying
  the commit sequence in order", so a revert needs no special ordering rules.
- **It works for a peer that has no undo stack.** A client joining mid-session
  receives a document snapshot through `SYNC` and no undo history at all. Rewinding
  history is not something such a peer can participate in; a forward revert is just
  another commit to apply, against the commits it has received and recorded **since
  joining**.

That last qualifier is a real boundary, not a formality. A join snapshot contains the
*effects* of the commits that preceded it, but neither the log nor their inverses, so
a peer cannot revert anything that predates its own join. The host enforces this
explicitly: a target at or below the newest connected peer's join point is refused
with `before peer join`. And if a peer is nonetheless asked to revert a target absent
from its log, the application **fails** — the client's response to a failed
`COMMIT_REVERT` is to disable networking fail-soft, not to skip the frame and carry
on. Failing conspicuously is the deliberate choice: a revert that some peers apply
and others quietly ignore is exactly the divergence the whole design exists to
prevent.

This is the form that works under these constraints, not the only conceivable one.
Sending an explicit inverse as a new semantic command, or including the command log
and its inverses in the join snapshot, would also be coherent designs; they were not
needed, and each costs more than it buys here.

**Why undo is not relayed.** Marking `undo` as `.relay` would make it a *global*
undo, where anyone's reflexive Ctrl+Z removes whoever's operation happened to be
last — an "undo war", and the reason collaborative editors converge on per-user
undo. `.undo_own` exists so the type system distinguishes the two.

**Accepted limitation.** Reverting an operation restores the pixels it covered,
including any later strokes by other peers that overlapped it. Removing that
requires replaying the log after a rollback instead of applying a snapshot inverse,
which is a larger change and was deliberately deferred.

### Undo groups: grouping is metadata, not a new kind of commit

An operation whose arguments exceed the command-argument budget has to be sent as several
relayed actions, and those must still undo as one. The decision is that **grouping is
advisory metadata carried out of band, and the document-mutating frames do not change**:
the members stay ordinary `COMMIT`s, a group undo is broadcast as one ordinary
`COMMIT_REVERT` per member, and a single additive kind (`GROUP`) says which seqs form one
unit.

That shape is chosen for one property. A peer that does not know the new kind discards it
and carries on — which is already how an unknown kind is handled — so it still applies
every member commit and every member revert, in the same order, and **its document
converges exactly as before**. All it loses is the grouping in its own history. Had the
group's members or its reverts travelled on new kinds instead, an older peer would have
skipped document changes and diverged, which is precisely what Decision 5's compatibility
argument does not permit. This is why adding the kind kept the protocol version at 1.

Three consequences worth stating, because each was a live alternative:

- **The group id is the smallest member seq**, not a counter. A counter would have to be
  agreed between peers, and reusing the process-local `transaction_id` for it would put a
  wire-assigned value into a namespace each peer allocates from independently — a
  collision there silently merges two unrelated bundles. A seq is already unique across
  the session and never reused.
- **Undo needs no client→host frame of its own.** The client proposes an ordinary
  `PROPOSE_REVERT` naming any one member and the host expands it, because the host is the
  only participant that knows the group in the first place. Validation is all-or-nothing
  over the members, on the same per-target checks a single revert uses.
- **A group revert is not atomic on the wire.** The host validates the whole group before
  applying any of it, but the members reach a peer as separate frames; a peer that fails
  to apply one of them disables networking fail-soft, which is the existing contract for a
  single `COMMIT_REVERT`. Making it atomic would mean either a new document-carrying kind
  (which breaks the compatibility argument above) or buffering a declared group before
  applying it, and neither was worth the cost for a failure that already ends that peer's
  participation.

**What the grouping does not survive.** Group membership lives on the command record and
is not part of the record's persisted form, so a command log that is saved and reloaded
comes back with its members individually undoable. That is acceptable because a session's
peer identities do not survive a reload either.

**Rejected: inferring undoability from stack depth.** Whether a committed operation
can be reverted is established by tagging the undo entry with the commit `seq`
during dispatch and asking the application afterwards whether such an entry was
pushed. Comparing undo-stack depth before and after was rejected because a depth
change is indistinguishable from a redo-stack clear or a no-op. Actions that push no
undo entry, such as selecting a tool or a colour, are correctly marked
non-undoable by the tagging scheme and would have been misread by the depth
heuristic.

## Decision 5: framing, size bounds, and how the wire may evolve

A frame is `{ kind: u8, len: u32 LE, payload: [len]u8 }` — a tag, an explicit
length, little-endian throughout, matching the byte order of every platform this
project targets and of the rest of its serialisation.

**The length is bounded before anything is allocated.** A reader that has parsed
`len` checks it against a per-kind ceiling — 4096 bytes for action-carrying frames,
16 MiB for a state snapshot — and on excess **closes that one connection** instead
of failing the process. The premise is a trusted network, and this is still worth
doing: the cost of not doing it is that one broken or hostile peer decides how much
this process allocates, and dropping a single connection is a proportionate
response. The action ceiling is not a round number picked for tidiness: it is set at
the same scale as the buffer local dispatch already works within, and every canonical
action in use fits inside it. It is not derived from that buffer with headroom
proved — a frame also carries a kind, a length and identifiers — so the two bounds
being equal is a coincidence of scale, not a guarantee.

**Extension happens through new frame kinds, not new fields.** `HELLO` places its
free-text label last, as "the rest of the payload", precisely so that no field can
be appended after it. Adding a capability therefore means adding a frame kind rather
than lengthening an existing payload, which an older peer would misparse. Peer
distribution (`PEER_INFO`) was added this way, and the copilot presence layer
occupies its own kind alongside the document frames.

The compatibility this buys is **conditional, and the condition is the size bound
above**: an unrecognised kind falls under the action-frame ceiling, so a new kind
that stays small is skipped by an older peer, while one exceeding that ceiling is
treated as a protocol error and costs the connection. Additive frames must therefore
stay small. Keeping the protocol version at `1` is likewise a judgement that each
addition met that bar — not an automatic consequence of adding a kind.

Action arguments have the same fail-closed compatibility rule: existing
pen/eraser/brush canonical forms remain readable by older peers, while the new
fill spelling is not backwards-compatible with a peer whose stroke parser does
not know `tool=fill`.

Consistent with that, a redo currently travels as an ordinary propose-and-commit of
the original command. There is no `redo_of` on the wire, so in another peer's
history a redo appears as a plain new commit. That is a known gap, left for an
additive frame if the history display ever needs to distinguish it.

## Non-goals

- **No authentication and no encryption.** Nothing in the implementation checks who
  connected beyond the protocol version. The host currently binds the **loopback**
  address, so the reachable envelope today is a single machine; should that ever widen
  to a LAN, this decision does not widen with it — authentication and encryption stay
  out of scope, and the trusted-network premise would then be load-bearing rather
  than incidental.
- **Hub topology only.** One host, up to a fixed number of clients. There is no
  peer-to-peer path and no host migration.
- **No automatic resynchronisation on reconnect.** Failing to listen or connect is
  fail-soft — the application keeps running without networking — but a dropped
  client rejoins as a new peer.

## Consequences

**A client's relay response is asynchronous.** Invoking a `.relay` action on a
client returns `proposed <id>` immediately; the application happens later, when the
`COMMIT` arrives. A `REJECT` is not delivered as a failed call — it surfaces through
the observation probe. Anything needing to wait for an outcome must poll that probe,
which is why the procedure in `docs/netsync.md` waits on digests rather than
sleeping. A synchronous variant would need a design change, not a flag.

**Peer identity is scoped to a connection.** Reconnecting yields a new peer id, so a
peer cannot undo operations it committed under a previous connection. Persistent
identity is future work.

**Some operations stay unavailable during a session.** Layer structure operations
were promoted to `.relay` once layers gained stable ids; opening a PNG remains
refused, because it replaces the document wholesale.

**A late joiner is a first-class case, not an edge case.** `SYNC`-on-join plus
forward revert is what makes it work, and any change to the undo model has to keep
it working.

## Relationship to the rest of the documentation

`docs/netsync.md` is the contract: frames, policies, probe fields, procedures. This
ADR is the reasoning, and deliberately does not duplicate the tables — a frame kind
number is documented in exactly one place.

The command model that netsync serialises (the action registry, the command log,
actor identity) is shared with the harness and the copilot transport rather than
being netsync's own.

### An explicit exception to ADR-007 R7

R7 says heavy or optional capabilities — it lists GPU compute, video decode and
networking — belong in independent modules rather than in core, so that only the
applications linking them pay. `core/control/netsync.zig` is networking inside core,
so **this ADR takes a deliberate exception to R7, rather than claiming to comply with
it.** R7 is amended with a pointer here so the two do not contradict each other.

The exception is granted on two grounds and is narrow:

- **The cost R7 guards against does not arise.** R7's concern is an executable paying
  for a capability it never calls. netsync adds **no framework or library link
  dependency** — it reaches the OS sockets through `std`, so there is nothing extra
  to link. What does remain is the compiled code itself, present in every executable,
  plus the I/O context that initialisation sets up before it reads its environment
  variables. Those costs are real, and they are the price of the exception.
- **It is control plane, not data plane.** netsync serialises the same semantic
  commands the harness and the copilot transport already carry, over the same
  registry and command log. Extracting it would split one plane across two layers.
  It also follows the discipline R3 sets for that plane, in the sense that matters
  to an ordinary run: **no socket, no thread, no router and no application state are
  touched unless the environment asks for them**, so behaviour passes through
  unchanged.

The exception is bounded by exactly those grounds. **If netsync ever needs an
additional framework or library link dependency, or grows past being a transport for
the control plane, the correction is to move it out of core and gate it as a
capability** in the manner of ADR-013 — which is what R7 asks for in the first place.

## Hot-path declaration

Event-driven plus network I/O. Frame receive, parse, apply, and the
propose/commit/reject exchange all happen when a command or a frame arrives. The
accept, reader and writer threads exist only for blocking socket I/O and handing
frames to and from queues; **application state is touched solely by the main
thread's drain step**.

Two costs have to be kept apart. **netsync's own work** — waiting, framing, queue
handling, dispatch bookkeeping — is proportional to the number of queued commits and
to payload size, never to pixel or sample count. **The work an action does** is
whatever that action costs locally: a stroke or a revert touches an area of pixels,
exactly as it would when invoked from the keyboard. Relaying does not add per-pixel
cost, and it does not remove it either.

What matters for the performance rules is the last clause: **no synchronisation,
allocation, lock or panic is added to any all-pixel loop or to the audio callback**.
netsync sits entirely outside both, so those rules have nothing to bind here.
