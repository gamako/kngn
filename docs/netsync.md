# Networked concurrent editing (netsync)

Several editor processes edit the same document at once over a persistent TCP
connection, with the host as the authority (propose/commit). The implementation is
`core/control/netsync.zig` plus `action_registry.NetworkPolicy`. With its environment
variables unset it passes through completely.

## Environment variables

| Variable | Meaning |
|---|---|
| `KNGN_NETSYNC_HOST=1` | listen as the host (`KNGN_NETSYNC_PORT` required) |
| `KNGN_NETSYNC_PORT` | the host's listen port |
| `KNGN_NETSYNC_CONNECT=ip:port` | connect as a client |
| `KNGN_NETSYNC_ACTOR=human\|agent` | the actor kind in the client's HELLO (default `human`; an invalid value warns and falls back to human) |
| `KNGN_NETSYNC_LABEL=<display name>` | the display label in the client's HELLO (default `client`, at most 200 bytes) |

Specifying `HOST` and `CONNECT` together disables netsync. A failure to listen or
connect is fail-soft (the application continues without netsync).

**Starting the client first is allowed.** A client whose connect is refused retries with an
exponential backoff (100/200/400/800/1600 ms), bounded both by that ladder and by a 10 s
wall-clock backstop for attempts that block rather than return, so the two processes can be
launched by hand in either order. Once either bound is reached it is the same fail-soft as any
other connect failure. On Windows the retry is entered on a coarser signal than elsewhere,
because the standard library reports a refused connection as `error.Unexpected` there;
`connectFailureIsRetryable` in `core/control/netsync.zig` records why that is the safe direction
to be imprecise in, and the backstop is what keeps the imprecision from being expensive.

**Relationship with the copilot transport**: during a netsync session, the copilot
transport's operate commands (`action`, `begin_tx`, `end_tx`, `cancel_tx`) are
rejected (observe — digest and snapshot — is still allowed). An agent's operations go
through a dedicated peer connection with `KNGN_NETSYNC_ACTOR=agent`.

**The teardown contract**: the `Executor` is a borrow owned by the caller, and
`platform.shutdown` drops the netsync and copilot borrows before the teardown that
follows freeing App.

## The frame format

```
Frame = { kind: u8, len: u32 LE, payload: [len]u8 }
```

| kind | Value | Payload |
|---|---|---|
| HELLO | `0x01` | text: client→host `client {ver} {kind} {label}`; host→client `host {ver} {peer_id}` |
| PROPOSE | `0x02` | `u32 LE proposal_id` ++ `"<name> <args>"` (client→host) |
| COMMIT | `0x03` | `u64 LE seq` ++ `u32 LE origin_peer` ++ `"<name> <args>"` (host→clients; not sent to the host itself) |
| SYNC | `0x04` | `u64 LE seq` ++ state bytes (host→client, once on join; an empty state means no snapshot) |
| REJECT | `0x05` | `u32 LE proposal_id` ++ `"<reason>"` (host→the proposer only) |
| PROPOSE_REVERT | `0x06` | `u32 LE proposal_id` ++ `u64 LE target_seq` (client→host) |
| COMMIT_REVERT | `0x07` | `u64 LE seq` ++ `u64 LE target_seq` (host→clients) |
| PEER_INFO | `0x08` | `u32 LE peer_id ++ u8 kind ++ label` (see peer info distribution below) |
| GROUP | `0x0A` | `u8 subtype` ++ a per-subtype body (see undo groups below). `0x01` BEGIN and `0x02` END are client→host and carry nothing else; `0x03` DECLARE is host→clients and carries `u16 LE count ++ u64 LE[count] seq` |

The limit for action frames is `MAX_ACTION_FRAME_BYTES` (4096). SYNC uses a big entry
(on the heap) up to `MAX_SYNC_BYTES` (16MiB). Exceeding either closes that connection.

## SYNC on join

1. Host: HELLO succeeds → a ClientJoined (an internal kind carrying the peer id and
   generation) goes onto the inbound queue → the pump exports state → a
   SYNC(seq=`wire_seq`) is enqueued as a big entry on the outbound FIFO → `synced=true`.
   Broadcasts go only to synced slots.
2. If no exporter is registered, an empty SYNC with a state of zero bytes is sent and
   `snapshot_valid=false`. A registered exporter returning zero bytes is treated as a
   failure (the connection is closed).
3. Client: on connecting, `awaiting_sync=true`. Until it clears, the pump does not
   enter the inbound dequeue loop (COMMITs accumulate in the queue). A SYNC goes to the
   heap-allocated `pending_sync` (a later one replaces it). An empty SYNC clears the
   flag with no import. An import failure is fail-soft, leaving the pending COMMITs
   unapplied.
4. All four applications just call their existing serialisation
   (the editor's `document_io`, the synth's `patch_io`, the modular engine's
   `pattern_io`, the patch canvas's `graph_io`) through a thin `registerStateSync`.

## NetworkPolicy

| Value | Host | Client |
|---|---|---|
| `.relay` | apply locally → fan out a COMMIT | PROPOSE only (the response is `"proposed <id>"`; application follows in the COMMIT) |
| `.local_only` | local only (no broadcast) | local only (no PROPOSE) |
| `.reject_when_synced` | immediately `RejectedWhileSynced` | the same |
| `.undo_own` / `.redo_own` | revert your own latest undoable / re-commit the most recent revert | PROPOSE_REVERT / a PROPOSE of the original command |
| `.ephemeral` | apply locally as presence (no COMMIT / seq) | enqueue PRESENCE only (the response is `"sent"`; no PROPOSE / seq) |

The default is `.reject_when_synced`. In the editor: `stroke` is `.relay` (the
originator's tool, colour, size, opacity, hardness and fill tolerance plus
`layer=#<id>` are made canonical). Every accepted stroke on the wire carries
`tool=` — pen, eraser and brush keep their existing field sets; fill is
`layer=#<id> tool=fill color=RRGGBB tolerance=N`. A stroke COMMIT or PROPOSE
without `tool=` is rejected (`ToolRequired`); local callers may still omit it
and the origin peer resolves against its own active tool before the router.
`set_color` and `set_tool` are `.local_only` (per-peer UI state); `save` is
`.local_only`. The layer structure operations (add, delete, visible, opacity, move and
so on) have been promoted to `.relay`.

## The propose/commit/reject flow

1. A client runs a `.relay` action → `proposed <id>` is returned immediately and a
   PROPOSE is sent to the host (nothing is applied locally).
2. The host re-verifies `network_policy == .relay` → applies it → sends a COMMIT to
   every client (on failure, a REJECT to the proposer).
3. Each client applies the COMMIT it receives (including ones it originated; this does
   not go through the router).
4. A REJECT warns and is stored in `last_rejected_proposal` and `last_reject_reason`
   (the data source for the observation probe).

**Applying remote commands**: every wire commit is recorded in the `CommandLog` with
`source=.remote_commit{seq}`. Local recording during a session is suppressed by
`wire_session`.

## The two-process procedure (deterministic waiting via probes)

```bash
# Start up (sleeping is acceptable only while waiting for the port file to appear;
# netsync is on 9110 and the port files live in the workspace's .e2e)
mkdir -p .e2e
KNGN_HEADLESS=1 KNGN_HARNESS_LISTEN= KNGN_HARNESS_PORT_FILE=./.e2e/host.port \
  KNGN_NETSYNC_HOST=1 KNGN_NETSYNC_PORT=9110 zig build run-pixie &
KNGN_HEADLESS=1 KNGN_HARNESS_LISTEN= KNGN_HARNESS_PORT_FILE=./.e2e/client.port \
  KNGN_NETSYNC_CONNECT=127.0.0.1:9110 zig build run-pixie &

# The client has finished joining. In free-run no step needs injecting into the host;
# await holds one connection and waits.
scripts/kngn ctl --port-file ./.e2e/client.port 'await netsync awaiting_sync=0 600'

# Add one shared layer and have the host and client select different ones
# (select_layer is local_only).
scripts/kngn ctl --port-file ./.e2e/host.port 'action add_layer'
until scripts/kngn ctl --port-file ./.e2e/host.port 'step 1; digest netsync' | grep -E 'last_seq=[1-9][0-9]*' | grep -q 'pending=0'; do sleep 0.05; done
until scripts/kngn ctl --port-file ./.e2e/client.port 'step 1; digest netsync' | grep -q 'awaiting_sync=0'; do sleep 0.05; done
scripts/kngn ctl --port-file ./.e2e/host.port 'action select_layer 0; action set_tool brush; action set_color FF0000'
scripts/kngn ctl --port-file ./.e2e/client.port 'action select_layer 1; action set_tool pen; action set_color 0000FF'

# Strokes from both sides. The canonical wire carries the origin's layer=#id, colour and tool.
scripts/kngn ctl --port-file ./.e2e/host.port 'action stroke 10 10 60 10'
scripts/kngn ctl --port-file ./.e2e/client.port 'action stroke 20 20 70 20'  # → "proposed <id>"

# The relay is done: mix in a host step to advance the COMMIT, then re-check
# last_seq>=3 && pending=0 on both sides.
until scripts/kngn ctl --port-file ./.e2e/host.port 'step 1; digest netsync' | grep -E 'last_seq=[3-9][0-9]*' | grep -q 'pending=0'; do sleep 0.05; done
until scripts/kngn ctl --port-file ./.e2e/client.port 'step 1; digest netsync' | grep -E 'last_seq=[3-9][0-9]*' | grep -q 'pending=0'; do sleep 0.05; done

scripts/kngn ctl --port-file ./.e2e/host.port 'digest canvas'    # the crcs of l0 and l1
scripts/kngn ctl --port-file ./.e2e/client.port 'digest canvas'  # the same l0/l1 crcs, with selected still per peer

# Take the measured values and assert that the l0/l1 crcs match and that tool, colour
# and selected are peer-local.
# Always terminate with `kngn ctl`'s quit (never pkill).
scripts/kngn ctl --port-file ./.e2e/host.port 'quit'
scripts/kngn ctl --port-file ./.e2e/client.port 'quit'
```

### When a peer needs a manual clock

The procedure above is free-run: each process advances frames on its own, and `step N`
is a barrier that waits for N presents. That is enough whenever the assertion is about a
state that netsync reaches on its own.

Add `KNGN_HARNESS_MANUAL_CLOCK=1` to **both** processes when the property under test is
per-frame rather than eventual:

- one injected point per frame — the editor's canvas input reads the mouse position once
  a frame, so several `inject mouse_move` inside one step collapse to the last
  coordinate;
- freezing one peer — leaving a peer unstepped keeps a COMMIT from reaching it while the
  other peer keeps working, which free-run cannot express.

Under a manual clock a peer advances only through `step`, so every wait loop must step
**both** peers; stepping only the one being asserted on deadlocks the relay. The three
netsync scripts in `tests/e2e/` are the worked examples.

## The netsync observation probe

`platform.init` registers a custom probe named `netsync` only when netsync is enabled
(it is not a reserved name).

| Item | Content |
|---|---|
| digest | one line of `k=v` (a live response is prefixed `netsync `): `role=<host\|client> peers=<n> agents=<n> peer_id=<n> last_seq=<n> pending=<n> awaiting_sync=<0\|1> last_reject=<id\|none> reject_reason=<str\|none> [log=<seq:origin:name,...>]` |
| snapshot | one JSON object: a `peers` array `[{peer_id,kind,label}]` plus `agents` plus the whole `log` (ext=json). For a host it is every entry of `slots[]`; for a client it is every active entry of the PEER_INFO catalogue (including the host itself, itself, and other peers) |
| last_seq | host: the wire commit counter. client: the seq of the last COMMIT applied |
| reject_reason | ASCII whitespace and control characters become `_`, truncated to 64 bytes |
| the log summary | the last few entries. A revert reads `seq:origin:revert->target`. **`origin` remains a number or a tag** (a peer is its numeric peer id; kind and label never appear — that is the public contract) |
| agents | the number of connected peers with `kind=agent` (a host counts `slots[]`, a client counts the active agents in its catalogue) |

## PEER_INFO distribution and peer origin

- **Wire**: frame kind `0x08`, payload = `u32 LE peer_id ++ u8 kind ++ label`
  (kind: 0=human, 1=agent, 0xFF=left). The protocol version stays 1. `0x09` is the
  copilot presence layer (pointer, highlight and suggestion sharing) and is not part of
  the document synchronisation described here.
- **On join** (the host's `handleHello`): a new client receives (1) the host's fixed
  identity (peer_id=0, kind=human, label `"host"`) and (2) a PEER_INFO for every
  existing active peer. Existing active clients receive a PEER_INFO for the new peer.
  All of them go onto the same outbound FIFO ahead of ClientJoined → SYNC.
- **On leave**: the remaining clients receive `PEER_INFO_KIND_LEFT` plus the label
  from just before. A client's catalogue does not delete the entry but keeps kind and
  label as an `active=false` tombstone (so history keeps displaying after a peer has
  left).
- **The client catalogue**: fixed length `MAX_PEERS+1`. When full, only inactive
  tombstones are reused (an active entry is never evicted). There is one
  `peer_metadata_revision` for the whole module (no per-entry revision).
- **The origin resolution API**: `resolvePeerOrigin` and `peerMetadataRevision`
  (through the platform facade). **The `log=` field of `digest netsync` and
  `log[].origin` in the snapshot stay numeric or tagged** — a label may contain `:`, so
  the public contract is not broken. The history UI and the additive
  `last_origin_kind` and `last_origin_label` of `digest history` are the authority for
  displaying kind and label.
- **The host itself**: peer_id 0 is a fixed identity (`HOST_ACTOR_KIND=.human`,
  `HOST_LABEL="host"`). No host-side environment variable (a
  `KNGN_NETSYNC_HOST_ACTOR` and the like) is provided.
- **Compatibility with an older peer**: with no PEER_INFO received, the history display
  falls back to `#<peer_id>` (it does not freeze).

### Checking the history panel's origin display end to end (two processes)

```bash
mkdir -p .e2e
KNGN_HEADLESS=1 KNGN_HARNESS_LISTEN= KNGN_HARNESS_PORT_FILE=./.e2e/host.port \
  KNGN_NETSYNC_HOST=1 KNGN_NETSYNC_PORT=9110 zig build run-pixie &
KNGN_HEADLESS=1 KNGN_HARNESS_LISTEN= KNGN_HARNESS_PORT_FILE=./.e2e/client.port \
  KNGN_NETSYNC_CONNECT=127.0.0.1:9110 KNGN_NETSYNC_ACTOR=agent KNGN_NETSYNC_LABEL=bot \
  zig build run-pixie &
scripts/kngn ctl --port-file ./.e2e/client.port 'await netsync awaiting_sync=0 600'
scripts/kngn ctl --port-file ./.e2e/host.port 'action stroke 10 10 60 10'
scripts/kngn ctl --port-file ./.e2e/client.port 'action stroke 20 20 70 20'
until scripts/kngn ctl --port-file ./.e2e/host.port 'digest history' | grep -q 'last_origin_kind=agent.*last_origin_label=bot'; do sleep 0.05; done
# The host's history shows AI:bot, the client's shows H:host, and the client's own row is starred
scripts/kngn ctl --port-file ./.e2e/host.port 'quit'
scripts/kngn ctl --port-file ./.e2e/client.port 'quit'
```

## Undo and redo during a session

- Only your own wire commits can be undone (`.undo_own`). The host verifies: unknown,
  not yours, not undoable, already reverted, transaction unsupported, too old, and
  before the peer joined.
- An undo applies a revert going forward (`PROPOSE_REVERT` / `COMMIT_REVERT`). Pixels
  caught in an overlapping region are accepted as a limitation.
- A redo is an ordinary propose/commit of the original command (there is no redo_of on
  the wire; the issuer's local pending metadata protects the epoch).
- Undoing a transaction is not supported during a session.
- Cmd+Z from the keyboard goes through `routeAction("undo"/"redo")` while
  `netsyncActive()`.

### Undo groups (one operation split across several actions)

An operation whose arguments do not fit in one action — `MAX_CMD_ARGS` is 4096 bytes, the same
scale as the action frame limit — has to be sent as several relayed actions. An **undo group**
makes those actions one undo unit on every peer.

Bracket them with `beginActionGroup()` / `endActionGroup()` (`group begin` / `group end` from the
harness). The host is the only participant that knows which `seq` each proposal received, so the
host collects them: a client's BEGIN opens a collector for that peer, every seq the host assigns to
its later proposals is appended, and END makes the host adopt the group locally and broadcast a
DECLARE naming those seqs. The host groups its own operations the same way, without frames.

- **The group id is the smallest member seq.** It needs no counter to be kept in step between
  peers, and it shares no namespace with the process-local `transaction_id`.
- **A group is formed only if it has at least two members and no more than 32.** Fewer, more, or a
  peer that disconnects before its END all leave the members individually undoable — the behaviour
  of a peer that never sent a GROUP frame at all.
- **Undo needs no new client→host frame.** A client proposes an ordinary `PROPOSE_REVERT` naming
  any one member; the host expands it to the whole group, validates every member with the usual
  checks (all or nothing), applies them newest-first, and broadcasts one `COMMIT_REVERT` per member
  plus a DECLARE that groups the revert records.
- **Redo re-issues every member as a new group**, so a redone group stays one undo unit.
- **The members are ordinary COMMIT and COMMIT_REVERT frames**, so a peer that does not know kind
  `0x0A` discards the DECLARE, applies every member in the same order, and converges on the same
  document; all it loses is the grouping in its own history. That is why adding this kind kept the
  protocol version at 1.
- **A group revert is not atomic on the wire.** A peer that fails to apply one member disables
  networking fail-soft, exactly as it does for a single `COMMIT_REVERT`.
- A group naming a record a peer never recorded — one lost to the command-log ring, or one that
  predates its join snapshot — is dropped whole on that peer rather than partially applied.

Wait deterministically by re-checking `kngn ctl 'digest netsync'` in an until loop (do not
retry on a fixed sleep; sleeping is acceptable only while waiting for a process's port
file).

## Constraints and retrying during a session

- Opening a PNG is not possible during a session (rejected by default). Layer structure
  operations are `.relay` and apply the same stable `#id` to every peer.
- Only `save` is allowed locally (during a session it is not recorded in the command
  log, so it consumes no wire seq).
- **Retry only when `clientSend` fails** (an error response). Once `"proposed"` or
  `"revert proposed"` has come back, never resend; from then on, wait deterministically
  on `digest netsync`.
- An action before the connection is established can fail → retry after the join
  completes (`awaiting_sync=0`), under the retry condition above.
