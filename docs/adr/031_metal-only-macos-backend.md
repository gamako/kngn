# ADR-031: Metal is the only macOS backend

- Status: Accepted
- Date: 2026-08-13
- Category: Platform, build

## Context

macOS carried three backends behind the same C ABI (`platform/platform.h`):

| Backend | Implementation | Present |
|---|---|---|
| Objective-C | `platform/macos/platform_macos.m`, 2,993 lines, the whole 35-function C ABI | a logical-size `CGImage` in `CALayer.contents` |
| Swift | `platform/macos-swift/platform_macos_swift.swift`, 1,035 lines | the same CALayer present, driven by `CADisplayLink` |
| Metal | `platform/macos-metal/platform_macos_metal.swift` | a textured quad through an `MTKView` drawable |

Metal has been the default since it became the only backend meeting the first-class
frame pacing contract of [ADR-005](005_platform-support-tiers-and-frame-pacing.md).
The other two were kept as a second opinion on the platform seam: three
implementations of one C ABI make the seam falsifiable on the machine where the work
happens, and the framebuffer capture of the harness was measured bit-identical across
them.

The cost of keeping them is that **every macOS feature is implemented twice**. The
letterboxed fixed framebuffer of [ADR-030](030_fixed-framebuffer-and-letterboxed-present.md)
landed as two separate pieces of work — one for the CALayer backends, one for Metal —
and the same split applied to fullscreen, transparency, cursor shapes and the text
input path. The pacing work told the same story from the other side: the investigations
into a frame period 14–20% longer than the target, and into which display refresh the
pacing target comes from, were both symptoms of the CALayer backends alone.

The question this record answers is whether the second opinion is worth that, and what
is actually lost by dropping it.

## The measurement

The application-facing contract does not distinguish the backends: a caller locks a CPU
framebuffer, writes every pixel and presents, and what happens after that is behind the
seam. The one thing that could differ is cost — Metal must upload the CPU framebuffer
to a texture every frame, where a CALayer present can hand the buffer over directly.

An earlier pair of numbers suggested Metal was the more expensive of the two (a frame
body of 6.93 ms against 3.86 ms), but they came from separate runs with different
framebuffer sizes on different displays. Measured properly — one machine, one window,
one display, `pixie`, `ReleaseFast`, `digest frameprof` over 10 s windows, framebuffer
2644x1764 on a ProMotion built-in display:

| Section | Objective-C (CALayer) | Metal |
|---|---:|---:|
| `frame_ms` (period) | 34.20 | **16.52** (the 16.67 target) |
| `body_ms` (work in a frame) | 5.39 | **5.14** |
| `clear` (fill every pixel) | 1.90 | **0.31** |
| `canvas_blit` | 1.54 | 1.51 |
| `gui_render` | 0.93 | 0.78 |
| `present` | 0.52 | 2.09 |

Metal's present is 1.6 ms more expensive, and its `clear` is 1.6 ms cheaper, so the
frame body comes out slightly **ahead**. The CALayer backing pays a first-touch cost on
every write to the framebuffer, which shows up in the section that writes all of it.
Frame pacing is not close: the CALayer backend ran at 29 fps where Metal hit the target
period on the same window.

So the trade-off that would have justified keeping a CPU present path does not exist on
this hardware. Nothing measurable is given up.

## Decision

**macOS has one backend, Metal.** The Objective-C and Swift implementations are removed,
along with their native archives (`platform_native_objc`, `platform_native_swift`) and
their `-Dplatform` values.

`-Dplatform` stays a typed option with the set `{metal}` on macOS, so an unimplemented
value is a build error and `zig build -h` lists what is valid. A stale `-Dplatform=objc`
in a script fails loudly instead of quietly building something else.

**macOS therefore requires a Metal-capable device, and states so when it does not have
one.** `MTLCreateSystemDefaultDevice()` returning nil makes window creation fail: the C
ABI returns NULL, the facade reports `error.WindowCreationFailed`, and the log line says
that macOS has no fallback backend. There is no silent degradation, because there is
nothing to degrade to. A run without a device is `KNGN_HEADLESS=1`, which selects the
null runtime — the display-less path the harness already uses.

The surviving sources are one Swift module split by subject, in one directory:

| File | Contents |
|---|---|
| `platform/macos/platform_macos_appkit.swift` | the C ABI, the event queue, input, the IME, gamepads, the menu bridge, window creation |
| `platform/macos/platform_macos_metal.swift` | the Metal renderer (a triple slot ring) and the drawable present |
| `platform/macos/platform_macos_menu.{h,m}` | NSMenu, compiled only under the menu opt-in |

The split is by subject rather than by linkage: both files are compiled as one module
under whole-module optimisation. The AppKit half owns the queue, the shared IME state and
the C ABI; the renderer file owns drawing and, because the `NSView` subclass lives there,
the view-level overrides that forward mouse, scroll and `NSTextInputClient` calls into
that shared state.

## Consequences

**What is lost.** Switching backends on the development machine was how a
backend-dependent regression got caught early; that particular tool is gone. The
replacements are the ones already in the tree: `bench-fill` attributes an unexpected
memory-bandwidth number to the machine rather than to a backend, Linux X11 exercises a
CPU present path, and `KNGN_HEADLESS=1` isolates everything above the platform seam.
Discovery moves from the development machine to the Linux and Windows hardware, which
is slower but not blind.

**What is not lost.** The application-facing contract is unchanged — the same
`lockFramebuffer` / `present` shape, the same CPU framebuffer. The harness `fb` probe
still captures that buffer, so `snapshot fb` and `digest fb` work as before. Transparent
windows, per-pixel click-through, cursor shapes, native menus, the IME and fullscreen all
exist in the Metal backend already.

**The tier framework of ADR-005 stands**, with macOS now entirely on the first-class
side. X11 and GDI remain the best-effort examples, so the distinction still has
implementations behind it.

**A defect survives this removal**: `platform_display_refresh_hz` reads
`NSScreen.mainScreen`, which AppKit defines as the screen holding the focused window
rather than the screen the application's window is on, reports
`maximumFramesPerSecond` (an upper bound, not the effective rate on a variable-refresh
display), and is read once at startup rather than when a window moves between displays.
Metal uses the same function, so this belongs to the pacing target and not to the
backends that were removed.

## Alternatives rejected

**Keep the Objective-C backend as a CPU-present fallback.** The measurement removes its
performance rationale, and the fallback would have to be maintained through every
future platform feature to stay usable — the two-implementations cost that motivated
this record in the first place. A backend that is not exercised is not a fallback.

**Keep the Swift (CALayer) backend as the "pure Swift, no GPU" variant.** It has no
capability of its own: the AppKit half it shared with Metal is exactly what survives,
and its only distinguishing part was the CALayer present that measured worse.

**Fall back to the null runtime automatically when no Metal device exists.** Rejected
because it turns a missing device into a silently blank window. The null runtime is
useful when a caller asks for it (`KNGN_HEADLESS=1`); reaching it by accident would
hide the reason nothing is drawn.
