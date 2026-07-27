# ADR-003: Where events are translated — in the platform layer

**Status:** Accepted
**Date:** 2025-10-25
**Category:** Architecture, API design

## Summary

Decides which layer converts native events (`NSEvent`, `MSG` and so on) into the
unified event struct (`PlatformEvent`).

**Decision:**
Each platform implementation (Objective-C / Swift / Metal) converts native events
into a `PlatformEvent` struct and exposes them through one unified C API.

## Context

Implementing the keyboard input sample required designing the event system. The
open questions were:

1. **Where things stood**
   - `platform_poll_events()` existed, but only pumped events
   - `platform_get_event()` and the `PlatformEvent` type did not exist yet
   - Where event translation lives is a significant design decision

2. **The two architectures**
   - Translate in the platform layer
   - Translate once, in shared Zig code

## Comparison

### Architecture A: translate in the platform layer (chosen)

```
macOS NSEvent ─┐
               ├→ [platform layer (C/Swift)] → PlatformEvent → [Zig]
Windows MSG ───┘   · translation
                   · queue management
                   · the unified struct
```

**Benefits:**
- A simple FFI boundary (one struct crosses it)
- Easy to debug (self-contained on the platform side)
- Room for platform-specific optimisation
- Type-safe (an explicit C struct)

**Costs:**
- Translation logic duplicated per platform (roughly 540 lines)
- Tests needed per platform

### Architecture B: translate in Zig (rejected)

```
macOS NSEvent ─┐
               ├→ [thin platform layer] → RawEvent → [shared Zig] → PlatformEvent
Windows MSG ───┘   · minimal FFI          · translation (shared)
                                          · queue management (shared)
```

**Benefits:**
- Shared code (queue management, key code translation)
- One set of tests in Zig
- Fewer places to change when extending

**Costs:**
- A complex FFI boundary (raw data crosses it)
- Harder to debug (both sides must be inspected)
- Weaker type safety from generic parameters
- Possible performance cost (translation may happen twice)

## Rationale

**Why Architecture A:**

1. **A simple FFI boundary**
   - A well-defined struct crosses it, which makes debugging far easier
   - Failures are easy to localise

2. **Room for the complicated features to come**
   - Advanced features such as an IME are tightly coupled to OS-specific APIs
   - The platform layer is going to grow regardless
   - Chasing a perfect abstraction would make things more complex, not less

3. **A small number of platforms**
   - macOS now; Windows and Linux/Wayland later
   - Roughly 540 duplicated lines is acceptable at that scale

4. **Consistent with the project's principles**
   - Matches the project's "simplicity first" principle
   - Keeps each layer's responsibility separate, in the Unix tradition

## Implementation

### Division of responsibility

**The platform layer owns:**
- Receiving native events
- Translating to virtual key codes
- Managing the event queue (a ring buffer)
- Tracking modifier key state

**Zig owns:**
- Interpreting events and the application logic
- Deciding on key combinations
- Application-specific behaviour

### When to revisit

Revisit if any of these happens:
- The number of platforms grows past five
- Event handling becomes substantially more complex (gestures, a full IME)
- The same bug keeps recurring across platforms

The design allows a shared layer to be added later without breaking the existing
API.

## Consequences

- `platform.h` gains the `PlatformEvent` struct and `platform_get_event()`
- Each platform implementation gains an event queue and native translation
- Zig only needs a simple event loop

## Related

