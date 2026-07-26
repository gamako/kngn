# ADR-006: OOM policy for `apps/editor/core` (keep `@panic`)

**Status:** Accepted
**Date:** 2026-07-03
**Category:** Editor, error handling, API design

## Summary

Allocation failure (OOM) in `apps/editor/core` — `Canvas`, `UndoStack`,
`StrokeRecorder`, `Selection`, `Path` — **keeps the existing policy of stopping
immediately via `catch @panic("…: OOM")`**.

**The decision, in short:**

- The core's public API does **not** propagate OOM as an error union. An
  allocation failure stops the process.
- The exception is initialisation and construction, where the caller can `try`
  naturally (`Canvas.init`, `allocBlankLayer`, `encodeGpl` and others that already
  return `!T`). Those keep returning errors.
- New code added to the core follows the same policy: no error union is
  introduced part-way through event handling or drawing. Panic messages use the
  form `"<site>: OOM"`.

## Context

- The core is positioned as an application-independent reusable core, but its
  only real consumer is the pixel editor, and there is no realistic way to
  recover from OOM in the middle of an edit — while committing a stroke, pushing
  an undo entry, or applying a selection. Propagating halfway means having to
  unwind inconsistent states such as a half-applied stroke, which adds complexity
  and regression risk rather than removing it.
- The `Tool.onEvent` → `StrokeRecorder.finish` path is designed around "finish
  does not return an error" (an event-driven state machine is not interrupted by
  errors). Propagating would force that design to be revisited.
- Propagating errors changes the signatures of the core's public API across a
  wide surface: every call site in the editor plus the input adapters. If an
  external consumer ever needs it, the design can be revisited then (YAGNI).

## Options considered

1. **Keep `@panic` (chosen)** — as above. When the core is embedded in an
   application, treating OOM as unrecoverable matches reality.
2. **Propagate errors** — more idiomatic Zig for a library, but it requires the
   signature churn above plus a design for unwinding partially applied state. The
   cost does not pay for itself yet.

## Consequences

- The `catch @panic("…: OOM")` sites in `undo.zig`, `path.zig`, `bezier.zig`,
  `selection.zig` and `canvas.zig` (`moveLayer`) are intentional and are not
  review findings.
- If error propagation is ever needed — for use as an external library, say — a
  new ADR superseding this one comes first.

## Related

- The policy comment at the top of `apps/editor/core/undo.zig` refers to this ADR
- `apps/editor/core/README.md` carries a summary of the policy
