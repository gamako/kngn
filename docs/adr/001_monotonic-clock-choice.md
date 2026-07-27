# ADR-001: Timer API design — choosing a monotonic (RAW) clock

**Status:** Accepted, implemented
**Date:** 2025-10-25
**Category:** Timers and timing control

## Summary

Decides the return type and the characteristics of `platform_get_time()`.

**Decision:**
A single API returning a `double` from an unadjusted (RAW) monotonic clock. Per
platform:
- **macOS**: `CLOCK_UPTIME_RAW`
- **Windows**: `QueryPerformanceCounter()`
- **Linux**: `CLOCK_MONOTONIC_RAW`

## Context

The project's main uses are game frame control and video animation control.
Choosing a timer API meant deciding three things:

1. **Data type**
   - `double` (seconds, floating point)
   - `uint64_t` (nanoseconds or microseconds, integer)

2. **Kind of clock**
   - Absolute time (wall clock): the system clock, adjusted by NTP
   - Monotonic clock: guaranteed to increase
     - Adjusted: frequency is slewed by NTP
     - Unadjusted (RAW): the hardware clock directly

3. **Resolution across platforms**
   - macOS: `CFAbsoluteTimeGetCurrent()` (absolute time, double)
   - Every platform offers a different API

## Comparison

### `double` vs `uint64_t`

| Aspect | double | uint64_t |
|------|--------|----------|
| Intuitive | ✅ arithmetic in seconds | ❌ needs ns/µs conversion |
| Resolution at 60fps | ✅ ~119ns (enough) | ✅ nanosecond |
| 32bit/64bit | ✅ always 8 bytes | ❌ platform dependent |
| Existing code | ✅ stays compatible | ❌ everything rewritten |
| Arithmetic | ✅ simple | ❌ unit conversions |

**Why `double` was chosen**

1. Frame interval arithmetic reads directly: `dt = current - last` (in seconds)
2. Minimal impact on existing code
3. A 52-bit mantissa keeps nanosecond resolution for 30 years
4. The same choice made by standard libraries such as GLFW

### Kind of clock

#### Absolute time (`CFAbsoluteTimeGetCurrent`)
**Behaviour**: the system wall clock, seconds elapsed since 2001
- **Problem**: an NTP adjustment can move it backwards
- **Unsuitable**: `dt = current_time - last_time` can go negative
- **Wrong fit**: in-game timing does not need wall-clock meaning

#### Monotonic clock (adjusted)
**Behaviour**: guaranteed to increase, frequency slewed by NTP
- **Behaviour**: the rate changes (slew) but never goes backwards
- **Effect**: a few milliseconds of divergence per hour (acceptable for games)
- **Why not chosen**: complexity that game and animation work does not need

#### Monotonic clock (unadjusted / RAW) ✅ **chosen**
**Behaviour**: the hardware clock directly, unaffected by NTP
- **Resolution**: consistently high (sub-microsecond)
- **Predictability**: hardware only, so behaviour is predictable
- **Benefits**:
  - Best fit for frame control, where short-interval accuracy matters most
  - No variation from NTP adjustment
  - Reproducible while debugging

**Rationale**:
- Game and video control require short-interval accuracy above all
- Removes NTP adjustment from the picture entirely
- Reading hardware directly makes behaviour predictable

## Resolution across platforms

### Resolution of each API

| Platform | API | Resolution | Adjusted | Notes |
|----------|-----|------|------|------|
| Windows | `QueryPerformanceCounter()` | ~100ns | no | depends on hardware such as HPET |
| macOS | `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` | ~1ns | no | nanosecond, macOS 10.12+ |
| Linux | `clock_gettime(CLOCK_MONOTONIC_RAW, ...)` | ~1ns | no | standard API |

### What this means for frame control

Against 60fps = 16.67ms per frame:

```
Windows QPC:   100ns = 0.0001ms (error: 0.0006%)  ✅ enough
macOS/Linux:     1ns = 0.000001ms (error: 0.000006%) ✅ far more than enough
```

**Conclusion:** every platform delivers sub-microsecond resolution, which is far
more than 60fps or 120fps control requires.

## Room for networked games later

The intended shape if network synchronisation is ever needed:

### Principle: separation of concerns

```zig
// Game state
const GameState = struct {
    // Local time (frame control)
    local_time: f64,           // from platform_get_time()

    // Server time (synchronisation)
    server_frame: u32,         // the server's frame counter
    server_time: f64,          // received from the server
    time_offset: f64,          // offset: server time - local time
};
```

### Synchronisation options

1. **Frame counter (simple)**
   - Server and client guarantee the same frame rate
   - Synchronise per frame

2. **Interpolation (standard)**
   - Interpolate between the last server update and the current state
   - Hides network latency

3. **Extrapolation (advanced)**
   - Predict using velocity received from the server
   - Looks smoothest, at the risk of mispredicting

### Why this shape works

- **Locally**: `platform_get_time()` (the RAW clock) drives accurate frame control
- **For synchronisation**: a separate layer owns `time_offset`
- **Benefit**: each layer's responsibility is clear, and existing code is untouched

## Consequences

### ✅ Benefits

1. **Consistent high resolution**
   - Sub-microsecond on every platform
   - No NTP adjustment

2. **Right fit for frame control**
   - `dt = current - last` is always positive
   - No negative deltas, so simulation stays stable

3. **Simple implementation**
   - Per-platform differences are absorbed
   - Callers just do arithmetic on a `double`

4. **Room to grow**
   - Networking can add synchronisation logic in a layer above
   - The existing frame control layer is unaffected

5. **Debuggable**
   - No NTP adjustment, so behaviour reproduces
   - Frame control is easy to debug

### ⚠️ Things to keep in mind

1. **Drift over long runs**
   - The RAW clock has no relation to system time
   - After days of running it may diverge from an NTP-adjusted system clock
   - **Mitigation**: use it only inside the application; manage synchronisation
     with the outside world separately

2. **Suspend and sleep**
   - `CLOCK_UPTIME_RAW` stops while the machine sleeps
   - **Assessment**: natural for a game (the game stops too)

3. **Older operating systems**
   - Requires macOS 10.12 (Sierra) or later
   - **Assessment**: rarely a problem on current systems

## Implementation

### The API in platform.h

```c
// Read a high-resolution monotonic time (in seconds, as a double).
//
// Characteristics:
// - Monotonic: the value only increases and never goes backwards.
// - Unadjusted (RAW): unaffected by NTP and other system clock adjustments.
// - High resolution: sub-microsecond, platform dependent.
//   - Windows: ~100ns (QueryPerformanceCounter)
//   - macOS: ~1ns (CLOCK_UPTIME_RAW)
//   - Linux: ~1ns (CLOCK_MONOTONIC_RAW)
//
// Returns:
// - Seconds elapsed since system boot or process start.
// - The absolute value carries no meaning; use it only for differences.
// - Behaviour across suspend and sleep is platform dependent.
//
// Uses:
// - Measuring frame intervals: dt = current_time - last_time
// - Animation control
// - Benchmarking and profiling
//
// Notes:
// - This time bears no relation to the system wall clock.
// - Network synchronisation needs its own server-time handling.
// - Over long runs the divergence from system time accumulates.
double platform_get_time(void);
```

### Where it lives today

The decision (double + RAW monotonic) is unchanged. The implementation files have
moved with the platform backends:

#### macOS (Objective-C)

`platform/macos/platform_macos.m` — `platform_get_time` via
`clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`.

#### macOS (Swift / Metal)

`platform_get_time` is defined once in the shared Swift layer
`platform/macos-shared/platform_macos_shared.swift` (same `CLOCK_UPTIME_RAW`). The
Swift and Metal backends (`platform/macos-swift/platform_macos_swift.swift`,
`platform/macos-metal/platform_macos_metal.swift`) do not redefine it.

#### Windows (pure Zig)

`core/platform_windows_common.zig` — `getTime()` via `QueryPerformanceCounter` /
`QueryPerformanceFrequency` (no `platform/windows/platform_windows.c`; Windows is
pure Zig).

#### Linux (pure Zig)

`core/platform_linux_common.zig` — `getTime()` via
`clock_gettime(CLOCK_MONOTONIC_RAW, …)` with a `CLOCK_MONOTONIC` fallback (no
`platform/linux/platform_linux.c`; Linux is pure Zig).

## Reference

### Timer APIs surveyed per platform

#### Linux

| API | Kind | Adjusted | Use |
|-----|------|------|------|
| `CLOCK_MONOTONIC` | monotonic | frequency slewed | cooperates with NTP |
| `CLOCK_MONOTONIC_RAW` | monotonic | **no** | frame control ← chosen |
| `CLOCK_BOOTTIME` | monotonic | yes | includes time suspended |
| `CLOCK_REALTIME` | absolute | can jump | logging, external sync |

#### macOS / iOS

| API | Kind | Adjusted | Use |
|-----|------|------|------|
| `CFAbsoluteTimeGetCurrent()` | absolute | can jump | system time |
| `CACurrentMediaTime()` | monotonic | possibly | media control |
| `mach_absolute_time()` | monotonic | **no** | tick counter |
| `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` | monotonic | **no** | frame control ← chosen |

#### Windows

| API | Kind | Resolution | Use |
|-----|------|------|------|
| `GetTickCount64()` | monotonic | 15.6ms | timeout checks |
| `QueryPerformanceCounter()` | monotonic | **~100ns** | frame control ← chosen |
| `QueryInterruptTimePrecise()` | monotonic | <1µs | Windows 10+ |
| `GetSystemTimePreciseAsFileTime()` | absolute | can jump | external sync |

## Revision history

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2025-10-25 | First recorded, implementation complete |
| 1.1 | 2026-07-27 | Implementation / Related paths corrected to the current tree (macOS shared Swift; Windows/Linux pure Zig under `core/`). The decision itself is unchanged. |

## Related

- `platform/platform.h` — the C ABI declaration of `platform_get_time`
- `platform/macos/platform_macos.m` — macOS Objective-C implementation
- `platform/macos-shared/platform_macos_shared.swift` — macOS Swift/Metal shared `platform_get_time`
- `core/platform_windows_common.zig` — Windows `getTime` (QueryPerformanceCounter)
- `core/platform_linux_common.zig` — Linux `getTime` (CLOCK_MONOTONIC_RAW)
- `examples/01_timed_window/` — sample usage
