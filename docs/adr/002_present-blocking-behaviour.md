# ADR-002: The blocking behaviour of platform_present()

**Status:** Accepted, implemented. Revised 2026-06-27 — present stays non-blocking; the detailed contracts for frame pacing, buffer ownership and support tiers are delegated to [ADR-005](005_platform-support-tiers-and-frame-pacing.md)
**Date:** 2025-10-25
**Category:** Rendering, frame rate control

## Summary

Decides whether `platform_present()` blocks.

**Decision:**
`platform_present()` returns immediately (it does not block). The rendering system
(the window server or the GPU) swaps the screen at vblank internally, and rate
control of the game loop is the caller's responsibility.

## Revision summary (2026-06-27)

This ADR's core decision — **present is non-blocking (it returns immediately)** — is
**kept**. But alongside the work of organising frame pacing, vsync and buffer
ownership for game use, the following are updated. The detailed contract and the
backends' support tiers (first-class versus best-effort) are collected in
**[ADR-005](005_platform-support-tiers-and-frame-pacing.md)**, and this ADR remains as
its upstream premise: present is a non-blocking submit.

- **Present is positioned as "submit, and the frame commit point".** It still does not
  wait for display refresh. The verification harness also treats this moment as the
  frame commit point (advancing `frame_index`; the reference for snapshots and
  digests).
- **Frame pacing is not expressed by blocking in present.** Whether drawing is
  possible is expressed by a successful `lockFramebuffer()` (frame availability), and
  a game-oriented wait is handled by the future `beginFrame(wait)` /
  `waitFrame(timeout)` (replacing the old "future extension" idea of a
  `platform_present_sync()`).
- **`lockFramebuffer() == null`** means the retryable state "there is no drawable
  frame slot right now" (Wayland's frame callback and busy-buffer pacing are the
  worked example). Fatal conditions such as device lost or a destroyed window are
  handled through a separate path
  ([ADR-005](005_platform-support-tiers-and-frame-pacing.md)).
- **After present the framebuffer pixels are owned by the backend**, and the caller
  does not touch them until the next lock.
- The old unconditional claim that "tearing never occurs, whenever you call it" is
  weakened to **depend on the backend's support tier**. First-class backends (Metal,
  D3D11-DXGI, Wayland) guarantee freedom from tearing via fifo; best-effort backends
  (CALayer objc/swift, X11, GDI) do not.

## Context

### The original problem

Early in the project, `platform.h` said this:

```c
// Update the screen (synchronised to vsync)
// Displays what was written via platform_lock_framebuffer()
// This function waits for vsync
void platform_present(PlatformWindow* window);
```

Checking the implementations, however, `platform_present()` returned immediately on
every platform (macOS CALayer, Metal, Swift): the documentation and the
implementation disagreed.

### Two concepts that were being conflated

The discussion revealed that two different things were both being called "vsync":

1. **Vblank synchronisation (avoiding tearing)**
   - Swapping the screen during the display's vertical blanking interval
   - Handled automatically by the rendering system (the window server or the GPU)
   - Prevents tearing (a split image)

2. **Rate control of the game loop**
   - How many times per second the `while (running)` loop runs
   - Must be controlled explicitly on the CPU side
   - Implemented with `sleep()` and similar

### What prompted the discussion

Two questions:

> "What behaviour is expected from 'waiting for vsync'?"
> "In a single-threaded design, wouldn't you rather *not* wait automatically?"

They made it clear that the design intent needed stating.

## Comparison

### Option 1: blocking (wait until vsync)

```zig
platform_present(window);  // ← waits for the next vblank, then returns
// automatically 60fps (the display's refresh rate)
```

**Benefits**:
- ✅ Frame rate control is automatic
- ✅ Synchronises exactly to the display's refresh rate
- ✅ No `sleep()` needed

**Costs**:
- ❌ Hard to implement across platforms (especially with software rendering)
- ❌ In a single-threaded design, nothing can happen while waiting
- ❌ No variable frame rate
- ❌ Takes flexibility away from the user

### Option 2: non-blocking (return immediately) ✅ **chosen**

```zig
platform_present(window);  // ← returns straight away
std.Thread.sleep(16_666_666);  // ← control the frame rate manually
```

**Benefits**:
- ✅ Easy to implement across platforms
- ✅ The user controls the frame rate flexibly
- ✅ Consistent with a single-threaded design
- ✅ Simple and predictable

**Costs**:
- ⚠️ The user has to control the frame rate explicitly
- ⚠️ Slightly more complex for a beginner

### Single-threaded versus multi-threaded

| Execution model | Blocking behaviour | Fit |
|-----------|----------------|--------|
| **Multi-threaded** (a dedicated render thread) | waiting is fine | ✅ the main thread computes the next frame while waiting |
| **Single-threaded** (the usual game loop) | waiting is a problem | ❌ nothing can happen while waiting |

This project assumes a single-threaded design, so non-blocking is the right fit.

### Feasibility across platforms

#### Waiting for vsync with software rendering (the current design)

| Platform | How | Difficulty | Notes |
|--------------|---------|--------|------|
| **Windows** | `DwmFlush()` | 🟡 medium | possible via the Desktop Window Manager, but unusual |
| **Linux X11** | XSync plus a manual timer | 🔴 hard | vsync information is hard to obtain with software rendering |
| **Linux Wayland** | `wl_surface_frame()` | 🟢 possible | the frame callback synchronises to vsync |
| **macOS** | `CVDisplayLink` | 🟡 medium | the callback arrives **on another thread**, which conflicts with a single-threaded design |

#### Waiting for vsync with a GPU API (a future extension)

| API | Waiting for vsync | Difficulty |
|-----|----------|--------|
| **DirectX** | `Present(1, 0)` | 🟢 easy |
| **OpenGL** | `glSwapBuffers()` | 🟢 easy |
| **Metal** | `present()` + `waitUntilCompleted()` | 🟡 medium |
| **Vulkan** | `VK_PRESENT_MODE_FIFO_KHR` | 🟢 easy |

**Conclusion**: with software rendering, waiting for vsync is either difficult or
unnatural on most platforms. Non-blocking is the realistic design.

## Rationale

### The main reason

In a single-threaded design, having `platform_present()` wait for vsync automatically
causes two problems:
- Nothing else can happen while waiting
- Flexibility in frame rate control is lost

### Additional benefits

Investigation confirmed these as well:

1. **Easy to implement across platforms**
   - A consistent implementation everywhere
   - Works with software rendering too

2. **Flexibility for the user**
   - Fixed 60fps, a variable frame rate, or uncapped — freely chosen
   - Control that suits the purpose: a game, a tool, an animation

3. **Consistency with what already existed**
   - Every platform implementation was already non-blocking
   - Only the documentation needed fixing

## Consequences

### Avoiding tearing

> **Revised 2026-06-27**: the original claim that "tearing never occurs" assumed only
> the macOS backends (CALayer and Metal). X11 and GDI were added later (unguarded
> blits with no wait for vblank), so whether tearing is avoided **depends on the
> backend's support tier**. First-class backends (Metal, D3D11-DXGI, Wayland)
> guarantee freedom from tearing via fifo; best-effort backends (CALayer objc/swift,
> X11, GDI) do not guarantee strict freedom from tearing. Details in
> [ADR-005](005_platform-support-tiers-and-frame-pacing.md).

**The original conclusion (assuming macOS)**: on the macOS backends below, the vblank
swap means tearing does not occur.

**Why**:
- The rendering system (the window server or the GPU) swaps the screen internally at
  the next vblank
- The write buffer and the display buffer are separate (double or multiple buffering)
- It is safe to call `platform_present()` at any time

**Per platform**:

| Platform | Mechanism | Tearing |
|--------------|--------|------------|
| **macOS CALayer** | the window server swaps at vblank | ❌ none |
| **macOS Metal** | the GPU driver swaps at vblank | ❌ none |
| **DirectX (for reference)** | FIFO mode (the default) | ❌ none |
| **Linux X11** | `XPutImage`/`XShmPutImage` blit immediately (no wait for vblank) | ⚠️ possible (best-effort; a reduction is planned) |
| **Windows GDI** | `StretchDIBits` blits immediately (no wait for vblank) | ⚠️ possible (best-effort) |
| **Linux Wayland** | paced by the frame callback (the compositor composites) | ❌ none (compositor dependent) |

### Rate control of the game loop

**Responsibility**: the caller.

**How**:

```zig
// Basic control (a fixed sleep)
while (running) {
    update();
    render();
    platform_present();
    std.Thread.sleep(16_666_666); // 16.67ms = 60fps
}
```

```zig
// Recommended control (delta time)
const target_frame_time = 1.0 / 60.0; // 60fps

while (running) {
    const frame_start = platform_get_time();

    update();
    render();
    platform_present();

    const elapsed = platform_get_time() - frame_start;
    const sleep_time = target_frame_time - elapsed;

    if (sleep_time > 0) {
        std.Thread.sleep(@intFromFloat(sleep_time * 1e9));
    }
}
```

### Room to extend later

With non-blocking as the base, these extensions remain possible:

> **Revised 2026-06-27**: item 1 below (adding `platform_present_sync()`) is **not
> adopted**. A blocking wait is handled not by a second present function but by
> `beginFrame(wait)` / `waitFrame(timeout)`
> ([ADR-005](005_platform-support-tiers-and-frame-pacing.md)). Item 2 (a vsync control
> flag) is organised as ADR-005's `PresentMode` (fifo / immediate).

1. **Adding `platform_present_sync()`** (not adopted; replaced by
   `beginFrame`/`waitFrame`)
   ```c
   // A blocking version (the old idea, not adopted)
   void platform_present_sync(PlatformWindow* window);
   ```

2. **A vsync control flag**
   ```c
   void platform_set_vsync(PlatformWindow* window, bool enable);
   ```

3. **Providing a helper**
   ```zig
   // platform_helpers.zig
   pub const FrameRateLimiter = struct {
       target_fps: f64,
       last_frame_time: f64,

       pub fn waitForNextFrame(self: *FrameRateLimiter) void {
           // frame rate control
       }
   };
   ```

## Implementation

### The API in platform.h

> **Revised 2026-06-27**: the following is **the original comment (2025-10-25,
> assuming macOS)**. The current `platform/platform.h` is tier-aware: the
> unconditional claim that "tearing never occurs, whenever you call it" is gone, and
> it states that avoiding tearing depends on the backend's support tier (not
> guaranteed on best-effort backends). Details in
> [ADR-005](005_platform-support-tiers-and-frame-pacing.md).

```c
// The original text (2025-10-25, assuming macOS; the current comment is tier-aware)
// Update the screen
// Displays what was written via platform_lock_framebuffer()
//
// Behaviour:
// - This function returns immediately (it does not block)
// - The rendering system (the window server / GPU) swaps the screen at the next VBLANK internally
// - The write buffer and the display buffer are separate, so tearing never occurs whenever you call it
//
// Notes:
// - Rate control of the game loop (how often you call this) is the caller's responsibility
// - To limit the frame rate, use platform_get_time() and sleep()
void platform_present(PlatformWindow* window);
```

### The platform implementations

#### macOS CALayer (Objective-C)

```objc
void platform_present(PlatformWindow* platformWindow) {
    if (!platformWindow) return;
    @autoreleasepool {
        FramebufferView* view = platformWindow->view;
        [view presentManual];  // returns immediately
    }
}
```

Inside `presentManual`:
```objc
- (void)presentManual {
    // swap buffers
    uint32_t* temp = currentBuffer;
    currentBuffer = displayBuffer;
    displayBuffer = temp;

    // hand it to the CALayer (returns immediately)
    CGImageRef image = CGImageCreate(...);
    contentLayer.contents = (__bridge id)image;
    CGImageRelease(image);

    // the window server swaps at the next VBLANK (asynchronously)
}
```

#### macOS Metal (Swift)

```swift
func platform_present(platformWindow: UnsafeMutableRawPointer?) {
    guard let platformWindow = platformWindow else { return }
    let handle = Unmanaged<PlatformWindowHandle>.fromOpaque(platformWindow).takeUnretainedValue()
    guard let renderer = handle.metalView.getRenderer() else { return }
    renderer.presentManual(view: handle.metalView)  // returns immediately
}
```

Inside `presentManual`:
```swift
func presentManual(view: MTKView) {
    // swap buffers
    let temp = currentBuffer
    currentBuffer = displayBuffer
    displayBuffer = temp

    // submit the Metal commands (returns immediately)
    commandBuffer.present(drawable)
    commandBuffer.commit()

    // the GPU swaps at the next VBLANK (asynchronously)
}
```

## Terminology

The definitions this discussion settled:

| Term | Meaning | Who controls it |
|------|------|--------------|
| **refresh rate** | the display's update frequency (usually 60Hz, fixed) | the hardware |
| **vblank synchronisation** | swapping the screen during the vblank interval (avoiding tearing) | the window server / GPU (automatic) |
| **game loop rate** | how many times per second `while(running)` runs | user code (manual) |
| **frame rate control** | limiting how often the game loop runs | user code (`sleep` and similar) |

**The important realisation**:
- "vsync" is ambiguous: it can mean either avoiding tearing or controlling the frame
  rate
- This project separates them explicitly:
  - **Vblank synchronisation**: handled automatically by the rendering system
    (preventing tearing)
  - **Game loop rate control**: the user's responsibility (with `sleep` and similar)

## The design principle behind it

### Separation of responsibility

```
┌─────────────────────────────────┐
│  user code                      │
│  - game logic                   │
│  - frame rate control (sleep)   │ ← the user's responsibility
└─────────────────────────────────┘
           ↓ platform_present()
┌─────────────────────────────────┐
│  the platform API               │
│  - swap buffers                 │
│  - submit to the rendering system│ ← the platform layer's responsibility
└─────────────────────────────────┘
           ↓ asynchronously
┌─────────────────────────────────┐
│  the window server / GPU        │
│  - wait for VBLANK              │
│  - swap the screen              │ ← the system's responsibility
└─────────────────────────────────┘
```

## Revision history

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2025-10-25 | First recorded; documentation corrected |
| 1.1 | 2026-06-27 | Present organised as submit and the frame commit point. The detailed contracts for frame pacing, buffer ownership and support tiers delegated to [ADR-005](005_platform-support-tiers-and-frame-pacing.md). Added the distinction between `lockFramebuffer()==null` (frame slot unavailable) and fatal, and made the unconditional tearing claim tier-dependent. |

### Files changed by the original decision

1. **platform/platform.h**
   - The API comment expanded
   - The non-blocking behaviour stated
   - An explanation of game loop rate control added

2. **examples/01_timed_window/main.zig**
   - Wording corrected from "frame rate control" to "game loop rate control"
   - Comments clarified

3. **platform/macos/platform_macos.m**
   - A duplicated comment removed

4. **The project plan document** (since removed; superseded by this ADR)
   - The vsync design decision recorded
   - "Decision pending" changed to "decided"

## Related

- `platform/platform.h` — the API
- `platform/macos/platform_macos.m` — macOS Objective-C implementation
- `platform/macos-swift/platform_macos_swift.swift` — macOS Swift implementation
- `platform/macos-metal/platform_macos_metal.swift` — macOS Metal implementation
- `examples/01_timed_window/main.zig` — sample usage (an example of frame rate control)
- [ADR-001](001_monotonic-clock-choice.md) — the related timer API decision

## Reference

### Consistency with the wider industry

| Library / engine | Behaviour of `present()` | Notes |
|------------------|-----------------|------|
| **GLFW** | non-blocking | `glfwSwapBuffers()` returns immediately; vsync is a driver setting |
| **SDL3** | non-blocking | the recent trend is a polling-only design |
| **Unity** | main-thread only | every API call is restricted to the main thread |

This project's design is consistent with the industry.
