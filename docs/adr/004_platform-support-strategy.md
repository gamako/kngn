# ADR-004: Platform support strategy — excluding Linux/X11

**Status:** Superseded (2026-06-27) by [ADR-005](005_platform-support-tiers-and-frame-pacing.md)
**Date:** 2025-10-25
**Category:** Platform strategy

> **⚠️ Superseded (2026-06-27)**: this ADR's decision to leave Linux/X11 out has
> been reversed by the implementation — the X11, Wayland and Windows GDI backends
> all exist. Platform support tiers and the frame pacing strategy are now defined
> by **[ADR-005](005_platform-support-tiers-and-frame-pacing.md)**. This ADR remains
> as the historical record of the original reasoning: excluding X11 because key
> repeat detection differs across platforms.

## Summary

Records the priority order of supported platforms, and in particular the decision
to leave X11 out on Linux.

**Decision:**
- The initial implementation supports macOS only
- Windows and Linux/Wayland come next
- Linux/X11 is not supported for now (revisit if there is demand)

## Context

While designing the event system, key repeat detection was investigated on each
platform, and the platforms turned out to differ substantially.

### Key repeat detection per platform

| Platform | Repeat detection API | Difficulty | Accuracy |
|----------------|--------------|-----------|------|
| macOS | `[event isARepeat]` | easy | exact |
| Windows | `lParam & 0x40000000` | easy | exact |
| Linux/X11 | none (workarounds exist) | hard | approximate |
| Linux/Wayland | a dedicated callback | moderate | exact |

## Options considered

### Option 1: support every platform (rejected)

**What it means:** support all major platforms, X11 included.

**Benefits:**
- Maximum compatibility
- Reaches existing X11 users
- SSH X forwarding works

**Costs:**
- Key repeat detection on X11 is unreliable (needs workarounds such as comparing
  timestamps)
- A more complex codebase
- A larger test matrix
- Higher maintenance cost

### Option 2: exclude X11 (chosen)

**What it means:** on Linux, support Wayland only.

**Benefits:**
- A simpler codebase
- Key repeat detection can be treated as a guaranteed feature
- A smaller test matrix
- Lower maintenance cost

**Costs:**
- Existing X11 users are cut off
- SSH X forwarding does not work
- Some Linux distributions will not run it
- WSL1 will not run it (it depends on X11)

## Rationale

**Why X11 was excluded:**

1. **Technical complexity**
   - X11 has no direct API for deciding whether a key event is a repeat
   - Workarounds such as `XkbSetDetectableAutoRepeat` exist but are not complete
   - That complexity runs against the project's "simplicity first" principle

2. **Direction of travel**
   - Wayland has been in development since 2008 and is becoming the mainstream
   - Ubuntu 22.04 LTS defaults to Wayland
   - Many distributions are migrating to Wayland

3. **Limited resources**
   - Keeping quality high with limited development capacity
   - Linux support does not exist at all yet
   - Waiting for clear demand costs nothing

4. **A better API**
   - Key repeat detection can be guaranteed on every platform
   - The API documentation stays simple
   - Behaviour is consistent

## Phased support plan

### Phase 1: core platform (current)
```yaml
required:
  - macOS (Metal/Swift/ObjC)
```

### Phase 2: desktop expansion (later)
```yaml
required:
  - macOS
  - Windows (Win32/DirectX)

experimental:
  - Linux/Wayland
```

### Phase 3: on demand (much later)
```yaml
under consideration:
  - Linux/X11  # if there is demand
  - Web (WebAssembly)  # a new possibility
```

## Consequences

1. **API design**
   - The `is_repeat` flag can be guaranteed on every platform
   - Fewer platform-specific branches

2. **Documentation**
   - "Key repeat detection is guaranteed on all supported platforms"
   - "Linux support requires Wayland (X11 support may be added in future)"

3. **Implementation**
   - `platform_linux_x11.c` does not need implementing
   - Only `platform_linux_wayland.c` is implemented later

## What other projects do

| Project | X11 | Wayland | Strategy |
|-------------|---------|------------|------|
| GLFW 3.4 | ✅ | ✅ | full compatibility |
| SDL3 | ✅ | ✅ preferred | Wayland-first |
| winit (Rust) | ✅ | ✅ | both |
| Raylib | ✅ | ❌ | X11 only (simplicity) |

Following "simplicity first", this project adopts a Wayland-first strategy.

## When to revisit

Revisit X11 support if all of these hold:
- There is clear user demand
- A reliable way to detect key repeat on X11 is found
- Development capacity allows it

## Related

