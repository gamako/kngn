# ADR-011: The high-DPI (retina) coordinate model and framebuffer modes

**Status:** Accepted
**Date:** 2026-07-20
**Category:** platform / gui / gfx, coordinate systems, the drawing pipeline

## Context and problem

Every macOS backend (objc/swift/metal) currently allocates the framebuffer at
**logical resolution (points)** and, on retina (`backingScaleFactor=2`), **scales it
up 2x at display time**. No backend draws at true physical resolution. The only
difference between "blurry" and "crisp" is how that scaling happens:

| Backend | Scaling | Appearance |
|---|---|---|
| objc | A logical-size CGImage in `CALayer.contents`, with no `contentsScale` or filter set → the default **linear** upscale | blurry |
| swift | Almost identical to objc (no filter, no contentsScale) | should be blurry like objc (needs re-checking on hardware) |
| metal | The shader sampler uses `filter::nearest` (`platform_macos_metal.swift:82-84`) | crisp (but blocky nearest upscaling, not true 2x drawing) |

Hence the feedback from real hardware: "UI parts look coarse, as if 2x", "the font is
too small and soft", "the objc screenshots from the OS are blurry". **Crisp text can
only come from rasterising at physical pixels** — as long as a logical raster is
upscaled, the softness stays — so a real fix requires a physical-resolution
framebuffer. At the same time this project is a prototyping environment for games and
graphics, and wanting **a logical resolution scaled up by an integer factor with
nearest** (that is, *not* wanting a physical framebuffer), as retro pixel-art games
do, is a first-class use too.

## Decision (stated as rules)

### R1. The framebuffer mode is opt-in (the default keeps today's behaviour)

An application chooses the framebuffer mode when creating a `Window`. The default is
`.logical` — what happens today:

| Mode | What it is | Suits |
|---|---|---|
| `.logical` (default) | A logical framebuffer, scaled by the OS. **The framebuffer layout, the API and the crc stay bit-identical** (under the conditions in R9; note that the display *filter* may change under R8, so pixel-identical OS screenshots are not promised) | Retro and pixel-art games, quick prototypes. Text is soft but everything is simple |
| `.physical` (HiDPI) | Allocates a physical framebuffer (`w*scale × h*scale`) and sets `contentsScale=scale` | Crisp UI applications (the editor, the patch canvas), high-resolution games |

**Backends without a scale accept it too**: a backend with no notion of scale still
**accepts** `.physical`, reporting `contentScale()=1.0` (it is not rejected with
`Unsupported`). At scale 1 the physical framebuffer equals the logical one, so the
`.physical` code path always works on every backend — the fallback for non-retina
environments and backends that have not implemented it.

### R2. Separate logical size from framebuffer size in the API (the key premise)

Today `fb.width/height` is used directly as the GUI's logical size
(`pixie/main.zig:6668` calls `beginFrame(fb.width, fb.height)`, and
`patch/main.zig:2830` is the same shape). Continuing that under
`.physical` would double layout, clipping and hit testing, and break. To make the
chosen coordinate model work, platform gains this contract:

- `window.logicalSize()` (logical points) and `window.framebufferSize()` (physical
  pixels) are **separate APIs**. `Framebuffer` returns physical pixels, and under
  **`.physical`, `fb.width/height` is not used for GUI layout**.
- `window.contentScale() f32` is public.
- **Runtime scale changes** (moving between monitors, a resolution change) are part of
  the contract: the framebuffer size, the input coordinates and the GUI drawing must
  **all see the same scale within one frame**.
- **The per-frame scale snapshot (settled)**: the `Framebuffer` returned by
  `lockFramebuffer()` **carries `logical_size`, `framebuffer_size`, `content_scale`
  and `scale_epoch` (a version number incremented on every scale change) bundled as
  one snapshot**. The scale is **latched at `lockFramebuffer()`** (the start of the
  frame), and that frame's drawing, input handling and present all read the latched
  values. If the OS changes the scale mid-frame it does not affect that frame; the
  **new scale is latched at the next frame boundary** — the same "latch at a
  generation boundary" idiom used elsewhere in this project.
- **Who converts input coordinates, and when (settled)**: the loop order is
  `pollEvents()` (enqueue) → `lockFramebuffer()` (latch the scale) → `nextEvent()`
  (dequeue). At enqueue time this frame's latch does not exist yet, so **the backend
  only enqueues raw (native, physical) coordinates plus an event epoch**, and **the
  facade (`core/platform.zig`) normalises them to logical coordinates when
  `nextEvent()` dequeues them**, using the current frame's latched scale. The facade
  is the only thing that converts; backends do not. `nextEvent()` is expected to be
  called after `lockFramebuffer()`, but on the rare path where it comes first, **the
  most recently latched scale** is used (the content scale on the first frame).
  Derived coordinates such as `mouse_pressed_pos` are built from the
  facade-normalised values.
- The window and `Framebuffer` types in `platform_types.zig` and `platform.zig` gain
  the framebuffer mode and the four snapshot fields above (no such contract exists
  today).

### R3. The coordinate model: applications and the GUI stay in logical coordinates, and scale is applied once at the output edge

Even under `.physical`, application and GUI logic is written in **logical coordinates
(points)**. Layout, hit testing and mouse input all work in logical coordinates, and
the conversion to physical pixels is applied only at the drawing exit.
`Context.beginFrame()` receives the logical size, and the root clip in
`DrawList.reset()` is the logical size too.

**The per-backend input contract** (macOS alone is not enough):
- The unit of each backend's OS event coordinates is documented (macOS already
  converts view coordinates to logical points — `platform_macos.m:336-343`; Linux and
  Windows may be returning client pixels and need checking).
- **There is exactly one place that converts to logical coordinates** (as settled in
  R2: the backend passes raw coordinates plus an event epoch, and **the facade is the
  sole normaliser at `nextEvent()` dequeue time**; backends do not convert).
- Derived coordinates such as `mouse_pressed_pos` and `mouse_released_pos` **go
  through the same conversion**, so none is missed.

Rejected: having applications and the GUI think in physical pixels and sprinkle
`×scale` across every layout constant. Reasons below.

### R4. Scale injection for the UI is concentrated in `gui.render`, with the conversion rules written down

A draw list holds logical coordinates, and `gui.render` (`libs/gui/src/render.zig`)
takes a physical target plus a scale and bakes them. Rendering is currently 1:1
(`render.zig:17-28`), so
the following **conversion rules are settled** (a precondition for the GUI stage, all
pinned by unit tests in `libs/gui`):

- **Rectangles tile perfectly by flooring both edges** (a mixed `floor/ceil` makes
  adjacent rectangles overlap by 1px, so it is not used): `x0 = floor(x*s)`,
  `x1 = floor((x+w)*s)`, width `= x1 - x0` (and likewise for y). Adjacent rectangles
  `[0,10),[10,20)` become `[0,15),[15,30)` at s=1.5 — **no gap and no
  overlap**. **Clipping uses the same rule.** Negative coordinates also use `floor`
  (towards -∞) consistently (`floor(-1.5*2) = -3`).
- **Lines**: endpoints are `floor(p*s)` and the width is
  `thickness_phys = max(1, round(t*s))`. So a **1-logical-pixel rule is 2px at s=2**
  (`round(1*2)=2`) and 1px at s=1.
  - ⚠️ **An existing bug, older than high DPI**: `render.zig:23` does not pass the
    line's thickness through to `drawLine` (`render.zig:123`), even though
    `draw.zig:15` has it. That is
    **fixed first, as a precondition for this work**.
- **Images**: nearest upscaling. For each destination pixel `(dx,dy)` (physical, local
  to the rect), the source is `sx = floor(dx * src_w / dst_w)`,
  `sy = floor(dy * src_h / dst_h)` (integer nearest). The current 1:1 blit, which
  assumes `rect.w == src_w` (`draw.zig:96-113`), is generalised to this.
- **Minimum test cases**: at s ∈ {1.0, 1.5, 2.0}, pin bit-exactly ① adjacent
  rectangles tiling perfectly (zero gaps, zero overlap) ② clip boundaries agreeing
  ③ the physical width of a 1px rule ④ the source-to-destination mapping of an image.

### R5. GUI fonts separate logical measurement from physical rasterisation

`Font` currently has `measure()` and `drawTo()` on the same instance
(`libs/font/src/font.zig:30-66`). The chosen model
needs `measure()` to be logical width and `drawTo()` to rasterise at physical pixels.
**The API adopted (settled)**:

- **`Font` stays a logical definition** (it does not carry a scale). `measure()` and
  `metrics()` return **logical pixel units**, independent of scale. Vertical centring
  uses the logical `ascent` and `descent`.
- **Rasterisation takes the scale as an argument to `drawTo` (settled)**:
  `drawTo(target, pos, text, color, clip, scale)`, which internally generates glyphs
  at **logical px × scale, in physical pixels**. This shape was chosen because it
  preserves the existing `Font` vtable contract; the alternative of having the
  renderer pass a scale separately was rejected. **The glyph cache is keyed by the
  physical pixel size** (`(codepoint, px_size)`).
- **Bitmap fonts are not rejected under `.physical`**: `default_font` (the spleen
  bitmap, `gui/font.zig:208-215`) still works under `.physical`, but **nearest
  upscaling will not make it crisp**. UI that
  needs crispness switches to an **outline default font** — recommended, and the real
  answer for crisp text.

The vertical-centring work is already done and covers only centring within a line. The
**physical-pixel font work here (the logical-measure / physical-raster `Font` API, the
glyph cache, the outline default font) is separate, new work** (adding a 2x bitmap
font was rejected because it copes badly with arbitrary scales). It builds on the
existing font foundation (outline fonts, AA coverage, the font interface).

### R6. For games, scale is kept out of the camera; "logical viewport → physical target" is a separate contract

Games draw straight into the framebuffer without going through the GUI (`33_camera`
does `@memset(fb.pixels)` plus `drawSpriteEx(pixels, fb_w, fb_h, …)`, with positions
coming from `gfx.camera`). But it is not only `camera.worldToScreen()` that
needs a scale contract: `screenToWorld()`, `visibleRect()`, `clampToWorld()`, the
physical drawing size of tiles and sprites, and both the logical and physical size of
the viewport all do (`camera.zig:59-88` treats the viewport as screen coordinates).

**Mixing scale into the camera would change how much of the world is visible** once
retina is involved. To avoid that, scale is separated out as a **drawing transform**
rather than living inside the camera, and the camera's field-of-view arithmetic stays
logical and unchanged.

**Ownership (settled)**: `libs/gfx` gains **`gfx.ScreenTransform`**, which
**centralises** the logical-to-physical conversion **for drawing** (so that each
application does not reinvent its own):
- `logicalPointToPhysical` / `logicalRectToPhysical` (sharing the same floor-tiling
  rule as R4)
- `logicalViewportToTarget` (the camera's logical viewport → the physical target)
- `spriteDestRect` (a sprite's physical destination rect)

**The inverse transform for input is implemented in the facade (core) alone**, to
respect the layering and R2: the dependency direction is
`apps → kit → libs → core → platform`, so **`core/platform.zig` cannot import
`libs/gfx`**. The physical-to-logical inverse for input therefore does not live in
`gfx.ScreenTransform` but in **the facade itself** (a trivial division by the scale).
`gfx.ScreenTransform` is limited to a **drawing-only helper** and owns no input queue,
no latch and no input inverse (the facade is the sole normaliser of input — R2). The
camera handles only the logical viewport, and `gfx.ScreenTransform` makes it physical
at the drawing exit. That is the choke point for games.

### R7. Each application absorbs the seams where it draws into the framebuffer directly

Places that write into `fb.pixels` without going through `gui.render` or a drawing
transform weave in the scale individually:

- **The editor's canvas** (pixel art, where nearest blitting is correct): the `×scale`
  of "logical layout rect → physical blit rect" is folded into the existing `Zoom`,
  `screenToCanvas` and `canvasToScreen` conversions. It **becomes crisper automatically
  just from the larger framebuffer**, and there is no re-rasterisation problem.
- **The patch canvas's visualisation strip** (`spec.draw`, `osc.draw` and `meter.draw`
  write straight into `fb.pixels`; `patch/main.zig:2643-2665`): simply multiplying
  `VIS_H` by the scale does **not** increase the resolution of the visualisation buffers themselves (the
  `Spectrogram(width,height)` and `Scope(width,height)` in `libs/viz` are
  comptime-sized). **The drawing order is split into two layers (settled)**:
  1. **Layer A (below)**: draw the visualisation data into a **logical-resolution
     bitmap and nearest-upscale the strip region** into the physical framebuffer (so
     the comptime-sized visualisation buffers are not rebuilt per scale; memory and
     performance stay as they are, accepting that nearest upscaling is good enough in
     practice).
  2. **Layer B (above)**: **labels are drawn onto the physical framebuffer as outlines
     after layer A's nearest upscale** (if they were part of the logical strip and then
     upscaled, the labels would be nearest-upscaled and go soft, so they must be drawn
     at physical pixels after the upscale).
  3. **`VIS_H` and the logical/physical boundary of the canvas are managed on the
     logical side**, and made physical only at the exit — via
     `gfx.ScreenTransform` or layer A's nearest upscale — so boundary arithmetic is
     never scaled twice.

### R8. The nearest-filter stopgap goes in first, independently

Set `magnificationFilter = kCAFilterNearest` (plus minification) on the objc
`contentLayer` so it matches metal to the eye (**the CPU framebuffer crc is
unchanged** — this is a display-layer change only). It trades blocky AA on fonts for
crisp pixel art, and **it becomes unnecessary once `.physical` from R1 lands**, since
the upscale disappears. It is a bridge to stop the blurriness on real hardware before
the full work is done. Alongside it, the blurriness of swift alone is re-checked on
hardware (its settings are identical to objc in the code).

**Consistency with R1 (a deliberate display change)**: this filter change
**deliberately changes what `.logical` looks like** (the default, and today the only
mode): linear blur becomes crisp nearest, correcting the blur bug. So R1's
"`.logical` keeps today's behaviour" means **the framebuffer layout, the API and the
CPU framebuffer crc are unchanged**, and **pixel-identical OS screenshots are not
promised** (as the table note says). Once `.physical` exists, drawing is 1:1, the
upscale is gone, and the filter choice becomes moot.

### R9. Bit-identical framebuffer crc is guaranteed conditionally, and pinned by regression tests

"The framebuffer crc is unchanged under the default `.logical`" holds only under the
following conditions. It is **pinned by tests** rather than promised by this ADR:
- The `.logical` framebuffer width and height are exactly as before.
- **The logical path branches away from the physical path** (the physical branch does
  not change the logical path's allocation, clear or resize order).
- The order of init, resize and clear is unchanged.
- The nearest filter (R8) applies to **the display layer only**, not to the CPU
  framebuffer.
- The regression covers not only macOS objc but **the harness, the null backend and
  every backend**.

### R10. Measure and pin the hot-path impact (extend the benchmark matrix)

A `.physical` framebuffer has 4x the pixels (2x by 2x), plus more double-buffer
memory, more background clearing, more rectangle and image compositing, physical font
rasterisation, more visualisation work, and more cache misses and memory bandwidth. It
is therefore **subject to the performance rules in `AGENT.md`** (the SIMD trio,
clip hoisting, row-contiguous access), and more than `bench-canvas` must be compared before and after
and recorded in the notes: `gui.render` logical versus physical, font drawing, the
editor's canvas blit, and the patch visualisation — at **1x, 1.5x and 2x**, measuring
**both frame time and peak memory**. Font coverage and the visualisation are audited
separately.

**The performance ceiling (an acceptance criterion)**: at `.physical` 2x, the editor
and the patch canvas **hold 60fps** (within a 16.6ms frame budget). Peak memory stays
within the **increment** of the framebuffer double buffer relative to `.logical`
(roughly `w*h*(scale²-1)*4*2` bytes) plus the glyph cache increment — no unbounded
temporary allocation. Exceeding the ceiling is the input for deciding between
optimisation and cutting scope.

## Staged plan

- **Stage 0**: the objc nearest filter, as an independent stopgap (R8).
- **Stage 1**: the platform contract — `logicalSize()`, `framebufferSize()`,
  `contentScale()`, **runtime scale changes**, the framebuffer mode (default
  `.logical`), and **normalising input to logical coordinates** (R2, R3; objc first).
- **Stage 2**: the GUI conversion rules — inject the scale into `gui.render`, plus
  **the half-open rounding, clipping, images and line thickness** (R4, including fixing
  the existing `drawLine` thickness bug).
- **Stage 3**: fonts — separate logical measurement from physical rasterisation, plus
  outline-font physical-pixel rasterisation (R5).
- **Stage 4**: switching the applications — the editor (the canvas seam), the patch
  canvas (the visualisation strip, R7) and `gfx.camera` (the logical viewport →
  physical target conversion, R6) move to `.physical`.
- **Stage 5**: rolling out swift and metal, then Linux (x11/wayland) and Windows
  (gdi/d3d11), plus the performance regression (R10).

## Alternatives and why they were rejected

- **Applications and the GUI thinking in physical pixels**: it needs `×scale`
  sprinkled across the large surface of GUI widgets, every layout constant, hit
  testing and mouse handling, where one missed spot becomes a bug that only skews on
  real retina hardware and is only noticeable by eye. The chosen model confines the
  friction to `gui.render`, the drawing transform, and the small seams in the editor
  canvas and the patch visualisation.
- **Upscaling the whole logical framebuffer to physical**: that is exactly the current
  blur. It cannot produce crisp text.
- **Forcing every application onto a physical framebuffer**: retro and pixel-art games
  want a logical resolution upscaled by an integer factor with nearest, so it breaks
  them. → solved by making it opt-in (R1).
- **Adding a 2x bitmap font**: weak at scales other than 2x or 3x, and at variable
  sizes. Outlines (R5) are the general answer.
- **Mixing scale straight into the camera**: retina would change how much of the world
  is visible. Avoided by separating the drawing transform (R6).

## Consequences

- Existing applications, examples and the harness: **unchanged, with a bit-identical
  framebuffer crc** under the default `.logical` (under R9's conditions, pinned by
  regression tests).
- The editor and the patch canvas: crisp UI by opting into `.physical` (stage 4). The
  patch visualisation's resolution policy is settled by R7 (draw logical, nearest
  upscale, then draw labels as outlines after the upscale).
- Game authors: `.logical` behaves as before (retro work naturally keeps
  nearest-upscaling its own back buffer), and `.physical` plus `contentScale()` plus
  the drawing transform is available for high-resolution crispness.
- The existing bug where `gui.render` does not pass line thickness through is fixed
  first, as a precondition for stage 2.
