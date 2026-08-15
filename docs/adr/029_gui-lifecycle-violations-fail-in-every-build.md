# ADR-029: GUI lifecycle violations fail in every build

Status: Accepted

## Context

[ADR-028](028_gui-input-staging-outside-a-frame.md) settled how `libs/gui` treats input handed
over outside a frame: it is accepted and staged. It deliberately left the other half alone —
the structural contracts of a frame — and named the reason they could not be answered the same
way: input can be *accepted*, structure can only be *rejected*.

Those contracts are: a frame is opened once and closed once; widgets are built only while one is
open; the post-frame APIs (popups, the menu bar dropdown) are called only while none is; and
every `beginBox`, `beginDisabled`, `beginSliderGroup` and collapsible body is closed before the
frame ends.

They were written with `std.debug.assert`, which compiles to `unreachable` and is therefore
removed under `ReleaseFast` and `ReleaseSmall`. What happens next is not a check that quietly
passes: with the check gone, the code carries on into state it was written to exclude. Building
a widget with no frame open dereferences a layout tree that does not exist yet. Measured by
reverting one check and running the guard below, an optimised build segfaults instead of
reporting the contract.

So the contract was enforced exactly where a developer is looking (a debug build) and absent
exactly where a user is (a shipped one).

## Decision

**The structural contracts are checked in every optimisation mode.** The checks do not use
`std.debug.assert`; they panic with a message that names the contract that broke.

Only the failure handling is shared, in `Context.requireContract`. The predicates stay where a
reader meets them:

| Kind | Where the predicate lives | Example message |
|---|---|---|
| Phase: a frame must be open | `Context.requireFrame` | `gui: endBox requires an open frame` |
| Phase: no frame may be open | `Context.requireNoFrame` | `gui: menuBarPopup must be called with no frame open` |
| State: a scope must be closed | the call site | `gui: endFrame with a box still open` |

This deliberately does not aggregate the state predicates: `disabled_depth == 0` and
`slider_group == null` are not the same question, and hiding them behind a shared name would
cost the reader more than the duplication saves.

**Scope.** Phase and lifecycle contracts only — including the pairing rules a caller is
responsible for, such as `endBox` finding a box to close rather than the layout root. Those are
part of the published begin/end contract, so they are checked at run time.

What keeps `std.debug.assert` is the other class: value-validity assertions — a non-zero widget
id, a positive size, a coherent slider range — and invariants internal to the layout tree that no
caller can address. They are the ordinary "this cannot happen", and violating one does not leave
the Context in a state where the next frame is meaningless.

## Verification

A predicate can be correct and never called, and a unit test cannot follow a violation into the
process exit it causes. So the checks are verified from outside: `zig build check-gui-contract`
builds `tests/gui-contract-guard/` — a program that breaks one contract on purpose, selected by
argument — and runs each case as its own process, in `ReleaseFast` and `ReleaseSmall`, asserting
on the exit code and the message. The guard reports through an exit code from its own panic
handler rather than through the default abort, because the signal an abort raises differs by
platform while an exit code does not. A gate that asserts on a failure needs the failure to be
the same shape everywhere it runs.

The gate is on `zig build test`, and the gui module is rebuilt at each guard optimisation mode
rather than reused from the test build — the claim is about what `libs/gui` compiles to with
optimisation on, and a module carries its own optimize setting.

Cost, measured with `zig build bench-gui-frame` on aarch64-macos (ReleaseFast, minimum of 1000
iterations): 500 rows 249042 → 248417 ns, 1000 rows 393208 → 394334 ns, and at 2x scale 550291 →
549709 ns and 781417 → 781792 ns. The spread is ±0.3%, which is the run-to-run noise of the
benchmark. The pixel editor's `ReleaseSmall` binary moves from 1874312 to 1874264 bytes. The
checked paths run once per widget, never per pixel or per sample, and the success path is one
bool test.

## Alternatives rejected

**Leave them as `std.debug.assert` and document the ordering rules.** The rule would be written
down and unenforced in the configuration that ships. That is the state this decision exists to
end.

**Return an error instead of panicking.** A caller cannot recover: the layout tree is already
inconsistent, and the frame under construction has no meaning. An error type would make every
call site handle a case where the only correct handling is to stop.

**Test the predicates as pure functions instead of running a child process.** That verifies the
predicates and not the call sites — precisely the half that was broken here, where the check
existed and evaporated. Pure-function tests would have passed against the old code.

**Inject a violation sink the tests can observe.** It puts a test-only branch in the shipped API
to avoid spawning a process, which is the more invasive of the two.
