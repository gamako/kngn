# ADR-015: The real-time audio contract

- Status: Accepted
- Date: 2026-07-27
- Scope: why the callback region forbids what it forbids, and how state crosses
  between the GUI and the audio thread. The layer structure and the per-backend
  prerequisites are in [docs/audio-and-synth.md](../audio-and-synth.md); the rules
  that new code must follow are in `AGENT.md`.

## Context

`docs/audio-and-synth.md` states the rule: **inside the callback, malloc, locking,
IO and panic are forbidden**, and notes that backend IO outside the callback may
block. It states it as an axiom, with no reason attached.

That is enough for someone who already works on audio and not enough for anyone
else, because the interesting cases are not in the list. Is a spin lock "locking"
when it never blocks? Is a lock-free allocator "malloc"? Is an `assert` a "panic"?
Why is IO acceptable a few microseconds earlier, outside the callback? A reader who
cannot derive the rule cannot answer those, and will either over-apply it or find a
loophole. This ADR records the derivation.

## Where the rule comes from

The callback has a **deadline**. It is handed a buffer of *n* frames at a sample
rate, and the hardware will consume that buffer whether or not it was filled. The
budget is therefore fixed and small — a few milliseconds — and, crucially, **the
consequence of missing it is not slowness but an artefact**: a gap, a click, or
repeated stale samples. A dropped frame cannot be made up later, which is what
separates this from every other performance concern in the project, where being late
merely costs frame rate.

Three of the four prohibitions follow directly: they are not banned for being slow,
but for having **no guaranteed worst-case duration**.

- **Allocation** may take a lock, may fault a page, and may enter the kernel. Its
  worst case is not a property of the audio code but of every other thread that
  shares the heap.
- **Locking** admits *priority inversion*: with an ordinary lock — one without
  priority inheritance or a priority ceiling — the audio thread can end up waiting on
  a lower-priority thread that holds the lock and is not currently scheduled. The
  audio thread's own priority buys nothing, and the wait lasts until the scheduler
  runs the holder.
- **IO** may enter an operating-system or device operation whose worst case the
  callback has no way to guarantee. Not every syscall is slow; the point is that the
  callback cannot bound the ones that are.

**Panic is banned for a different reason**, and it is worth not forcing it into the
same frame: it does not overrun the deadline at all. It destroys the process from the
one thread that had a hard deadline, turning a recoverable glitch into a crash. The
rule is therefore two rules — no operation without a bounded worst case, and no
fatal exit — that happen to govern the same region.

### The boundary cases this settles

- **A spin lock is still forbidden**, even though it never blocks. It can exhibit the
  same priority-inversion failure mode, and on a single core it makes matters worse:
  a high-priority audio thread spinning is precisely what stops the holder from being
  scheduled to release the lock. When the holder does run on another core the wait is
  bounded by the critical section — but that is a property of the machine, not of the
  code, and the code has to be correct either way.
- **A lock-free allocator is still allocation.** Lock freedom removes blocking on a
  lock; it does not bound an individual operation's retries or duration. And with a
  general-purpose allocator the page fault and the syscall can still be there.
- **An unvalidated `@alignCast` is a potential panic**, so the precondition is checked
  and given a defined fallback instead. The Windows backend needs an aligned pointer
  and **tests the alignment explicitly rather than relying on the cast's safety
  check** — the test is the cheap part, and the point is to have a defined response
  where a safety-enabled build would otherwise trap. That is the shape of "no panic"
  in practice: validate, then degrade.
- **IO outside the callback is fine** because "real time" is a property of the
  deadline window, not of the subsystem. Opening a device, negotiating a format, or
  logging a failure all happen where nothing is waiting on a buffer.

## The contract is backend-independent by construction

The backends do not agree on who drives the callback:

| Backend | Who calls the callback |
|---|---|
| macOS (CoreAudio/AUHAL) | an OS-managed real-time thread **pulls** it |
| Linux (ALSA), Windows (WASAPI) | the backend spawns its own playback thread and **pushes** |
| Headless null device | a backend-owned thread pulls it, paced by sleeping one period |
| wasm | an AudioWorklet's `process()` push-drives it in shared memory |

A contract phrased per backend would therefore have to be four contracts, and code
written against one would be wrong on the others. So the contract is deliberately
the **intersection**: it assumes only that the callback runs on some thread with a
deadline, and forbids the same operations regardless of who is driving.

The two non-device paths are held to it for different reasons. **wasm is a real audio
path** — the worklet node is connected to the audio context's destination, so a missed
deadline there is as audible as on any device. **The null device is the only case
where nothing can glitch**, since there is no output at all; it is still held to the
full contract, because code verified headless has to be valid on a real device.

## How state crosses the boundary

There is no single mechanism, and the choice is determined by what the consumer must
not observe. Four are in use:

| What is handed over | Mechanism | Why |
|---|---|---|
| One scalar parameter | an `f32` bitcast into an atomic `u32`, store-release / load-acquire | A single word needs no protocol. Atomicising a large struct wholesale is explicitly not done |
| Several values that must agree | a triple-buffer mailbox, latest-wins, non-blocking | Below |
| A stream of events | a single-producer/single-consumer ring, may drop | Events are independent and a bounded queue must be allowed to refuse |
| A signal that must not be lost to a full queue | a monotonic generation counter the consumer compares against what it last saw | Independent of queue space, so a full ring cannot swallow it |

**Why three slots and not two.** With two, a producer that publishes twice while the
consumer is still copying can write back into the slot being read. The invariant that
removes it is that `{write, read, published}` is always a permutation of `{0,1,2}`,
which makes "the producer never writes the slot the consumer holds" structural rather
than timing-dependent. This was a theoretical window rather than an observed failure —
the honest reason for spending the third buffer is that the failure it prevents is
silent, rare, and would be attributed to anything but its cause.

**The drop policy is per message, not per queue.** In the note queue, a `note_on`
is dropped once the ring is nearly full, while a `note_off` may use the reserved
window that the `note_on` was refused. The asymmetry is about which loss is worse:
losing a `note_on` loses a note, whereas losing a `note_off` can leave a voice
sustaining until something else ends it — the envelope running out, the voice being
stolen, or an all-notes-off. All-notes-off does not go through the ring at all, for
the same reason taken to its conclusion: **the escape hatch must not be droppable by
the condition it exists to escape.**

That last mechanism is a generation counter rather than a queue, so its guarantee has
a precise shape: repeated requests **coalesce into one**, because the consumer only
asks whether the generation differs from what it last saw. For an idempotent
all-notes-off that is exactly right, and it is why the pattern suits this message and
not a stream of distinct events. The counter is a `u32`, so the guarantee is
"cannot be crowded out by a full ring", not "holds across wraparound".

Where a producer and consumer touch separate atomics, those atomics are placed on
separate cache lines; where only the audio thread touches a field, no atomic is
introduced at all. Both halves of that are deliberate — false sharing is a real cost,
and so is an atomic that exists for no reader.

## Consequences

**This is the project's strongest cross-cutting rule, and it is unenforced.** No
build step checks it. The counterweight is that the properties are pinned by
executable tests rather than by prose — zero allocation on the real-time path is
measured with a failing allocator, and the recomputation rate of filter coefficients
has an asserted upper bound. `AGENT.md` lists that policy under the performance
rules and points at the implementations; this ADR does not restate it.

**Being late is not the failure mode; being unbounded is.** A change that makes the
callback slower on average but keeps its worst case bounded is acceptable. One that
improves the average by introducing an unbounded step is not, and average-case
benchmarks will not show the difference.

## Relationship to the performance rules

`AGENT.md`'s performance rules and this contract are the two halves of the same
discipline, carry the same weight, and both contain absolute prohibitions — no
per-pixel division on one side, no unbounded operation on the other. What differs is
what counts as evidence. The all-pixel rules protect a **frame budget**, so a
measurement can settle a question: a before-and-after comparison shows whether a
change is acceptable, and `docs/performance-measurement.md` holds those procedures.
This contract protects **a deadline whose miss is audible and unrecoverable**, where
an average-case measurement settles nothing — an operation without a bounded worst
case is inadmissible however well it benchmarks.

## Hot-path declaration

This ADR describes the per-sample real-time path itself; it changes no code. The
region it governs is every audio render callback and everything reachable from one.
