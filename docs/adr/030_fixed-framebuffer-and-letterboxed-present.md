# ADR-030: A fixed-size framebuffer, presented with a letterboxed upscale

- Status: Accepted
- Date: 2026-08-10
- Scope: a third framebuffer mode on `WindowOptions`, the mapping `present` applies
  when it is selected, both directions of the coordinate transform that mapping
  implies, and what the per-frame snapshot means under it. It revises
  [002](002_present-blocking-behaviour.md) (present gains a mapping stage),
  [005](005_platform-support-tiers-and-frame-pacing.md) (a second capability axis)
  and [011](011_high-dpi-coordinates-and-fb-modes.md) (three coordinate spaces
  instead of two). Window creation is [019](019_window-creation-unification.md);
  the policy that governs the breaking change to `FramebufferMode` is
  [020](020_kit-versioning-and-maturity-gate.md).

> The per-backend tables below include the two macOS CALayer backends, which existed
> when this record was written. [ADR-031](031_metal-only-macos-backend.md) removed them,
> so on macOS only the Metal row is live; the CALayer rows are what the rule was reasoned
> from. Nothing else in this record changes: Metal implements the mapping through a
> viewport, exactly as its row states.

## Context and problem

The framebuffer is the size of the display area. Both existing modes say so:
`.logical` makes it the window's logical size and `.physical` multiplies that by the
content scale ([011](011_high-dpi-coordinates-and-fb-modes.md) R1). **Every
per-pixel cost an application pays is therefore proportional to the size of the
window the user happens to have opened**, and the application cannot decide
otherwise.

Four consequences, in the order they were run into.

**1. The cost is unbounded from the application's side.** An author writing against
this repository's published surface hit exactly this and worked around it outside the
library, keeping an internal 640x400 buffer and letting the presentation layer scale
it. The workaround is right; its absence from the library is the defect.

**2. Fullscreen at `.physical` is not viable.** A 5K display gives a 14.7 Mpx CPU
framebuffer. Clearing every pixel of one already accounts for about half of a
`.physical` 2x frame ([docs/performance-measurement.md](../performance-measurement.md)),
and 019 already records that the combination becomes usable only if the framebuffer
size is fixed and presentation scales it up. This ADR is that missing half.

**3. Verification is not reproducible.** A framebuffer snapshot is the primary way a
change is checked here, and its dimensions currently depend on the machine and the
window. Two runs of the same script on two machines produce two different images, so
resolution is a variable in every comparison that has nothing to do with what is being
compared.

**4. `resizable = false` is not a substitute.** It is advisory on X11 and Wayland and
a no-op on the web, and its own documentation says it "does not promise that the
framebuffer size never changes". A promise is what is needed.

### The capability is not uniform, and does not follow the support tiers

Every backend has the same two pieces of work to do regardless: place the destination
rectangle rather than covering the window, and paint the letterbox. Today none of them
does either, because the framebuffer covers the window by construction — the macOS
content layer's frame is the whole window, and the same holds elsewhere. **The column
below is what the magnification itself costs on top of that common work**, and it is
the only part that differs:

| Backend | Can it magnify while presenting? | Cost of the magnification |
|---|---|---|
| macOS objc / swift (CALayer) | **Already does.** `contents` is a `CGImage` of the framebuffer's size against a layer frame in logical points, and the nearest filter is already set, so Core Animation absorbs any ratio | none |
| Windows GDI | `StretchDIBits` takes a source rectangle | none |
| wasm | CSS; the browser's compositor magnifies | none |
| macOS Metal | a textured quad, which is what the renderer already draws | small |
| Windows D3D11 | `CopyResource` requires identical sizes, so a full-screen quad and a shader are needed | medium |
| Linux Wayland | `wl_surface_set_buffer_scale` is integer-only (it exists for device pixel ratio); arbitrary magnification needs `wp_viewporter` | medium |
| Linux X11 | `XPutImage` / `XShmPutImage` cannot magnify at all; XRender or a software upscale | medium to large |

The order is **inverted with respect to the support tiers of
[005](005_platform-support-tiers-and-frame-pacing.md)**: the best-effort backends
(CALayer, GDI) get it for free, and two of the three first-class ones (D3D11,
Wayland) need work. Whatever is decided cannot be phrased as "first-class backends
support it".

## Decision (stated as rules)

### R1. `.fixed` is a third framebuffer mode that carries its own size

`FramebufferMode` becomes a tagged union:

```zig
pub const FramebufferMode = union(enum) {
    logical,
    physical,
    fixed: WindowSize,
};
```

The alternative — keeping the enum and adding a separate `fb_size: ?WindowSize` to
`WindowOptions` — is rejected because it makes meaningless combinations expressible:
`.physical` with a size, `.fixed` without one. Each would then need a rule in
`validateWindowOptions`, splitting one contract across the type and a validator. With
the union, selecting `.fixed` makes the size mandatory and attaching a size to another
mode is not a program.

A zero width or height is refused by `validateWindowOptions`, in the facade, once for
every backend — the same place and the same reason as the option combinations 019 R4
refuses.

This changes an existing public type rather than extending it. That is permitted by
[020](020_kit-versioning-and-maturity-gate.md), and the alternative preserves a
weaker contract in exchange for nothing but the shape of the existing declaration.

### R2. Under `.fixed` the application sees one space, at scale 1.0

The four fields of `FramebufferSnapshot` take these values, for the whole life of the
window:

| Field | Value under `.fixed` |
|---|---|
| `framebuffer_size` | the size given to `.fixed` |
| `logical_size` | the same size |
| `content_scale` | `1.0` |
| `scale_epoch` | constant |

The magnification actually in effect belongs to the platform and is not published.
Three things follow, and all three are the point of the mode:

- **Layout and drawing coincide.** There is no logical/physical split to get wrong
  inside an application, which is what 011 R3 through R7 exist to manage.
- **Scale changes stop existing.** Moving the window between monitors of different
  densities does not change the framebuffer, so the epoch never advances and nothing
  keyed on it is rebuilt. An application under `.fixed` never handles a scale change.
- **A snapshot is reproducible.** Its dimensions are a property of the source code,
  not of the machine that ran it.

The cost is stated as a rule of its own in R9, because it is real.

### R3. The mapping: aspect preserved, arbitrary magnification, letterboxed, floored, computed in physical pixels

The destination rectangle inside the window is derived once per window size:

- **Aspect ratio is preserved.** The axis that runs out first sets the magnification
  and the other is derived from it.
- **The magnification is arbitrary** (not restricted to whole numbers) and sampling is
  **nearest neighbour wherever the filter can be chosen** — which is everywhere but one
  backend, as the end of this rule sets out. CALayer already magnifies by an arbitrary
  factor with a nearest filter, so requiring whole numbers would throw away the one path
  that costs nothing and force a computation where none is needed. An integer-only
  variant can be added later as an option; it cannot be removed later.
- **The remainder is a letterbox**, filled per R9.
- **A window smaller than the framebuffer minifies**, by the same rule with a factor
  below one. Nearest-neighbour minification drops source pixels and looks it, but the
  mode stays defined rather than acquiring a lower bound the application would have to
  know about; the framebuffer contract does not change with the size of the window,
  which is the whole point.
- **A window with no area presents nothing.** The mapping is defined for a window of at
  least one physical pixel on each axis; below that `present` does nothing for that
  frame. The framebuffer is unaffected either way — that is what fixing it means — so
  this is a statement about the window, not about the mode.
- **The destination is at least one pixel on each axis**, clamped after the floor, the
  same clamp-to-at-least-1 that 011 R11 applies when deriving a size by division.
  **This clamp is the one case where the aspect ratio is not preserved**: a window
  thinner than the ratio can express would otherwise need a zero-height destination,
  and a mapping that exists beats a rule that holds. The deviation is bounded by one
  pixel and only occurs at window sizes at which nothing is legible anyway.
- **Every value is floored**, matching the rule already used where logical coordinates
  meet physical ones.
- **The arithmetic is done in physical pixels**, never in logical points.

The last point is not cosmetic. It matters twice:

1. **The forward and inverse transforms must agree exactly.** R4 makes the facade
   invert this mapping for input. If the mapping floors in logical points and the
   inverse divides in physical pixels, they disagree at the edges by up to one physical
   pixel, and the outermost column of the framebuffer becomes unaddressable by the
   mouse. Fixing the arithmetic in one space removes the class.
2. **Sampling happens once.** Magnifying into logical points and letting the device
   pixel ratio magnify again is two nearest-neighbour steps, which makes the width of a
   source pixel uneven on screen (a run of five destination pixels next to a run of
   six). One step from the framebuffer to physical pixels does not.

**A backend expresses the rectangle in its own unit, and may round; the physical
rectangle stays authoritative.** Not every presentation surface is addressed in
physical pixels:

| Backend | The unit it places the rectangle in | Rounding |
|---|---|---|
| macOS CALayer | logical points (`layer.frame`) | up to half a point |
| Linux Wayland | surface-local coordinates — `wp_viewport.set_destination` takes integers, and the buffer scale relating them to pixels is itself an integer | up to one surface unit |
| Metal, D3D11, GDI, X11, the software path | physical pixels | none |

Where rounding happens the on-screen rectangle differs from the ideal by less than one
unit of that backend's space. **That is a difference in where the image is drawn, never
in what a coordinate means**: R4 inverts the physical rectangle, not the rounded one, so
the exact agreement it needs is unaffected and the deviation is bounded and visual. A
backend that cannot tolerate even that has the software upscale of R6 available, which
places the rectangle in physical pixels by construction.

**What is guaranteed is the mapping, not the filter.** Nearest neighbour is required
wherever the presenting layer lets a filter be chosen: CALayer
(`magnificationFilter`), Metal and D3D11 (the sampler), CSS (`image-rendering`), and
the software path of R6. `wp_viewporter` on Wayland defines the source and destination
rectangles but **not** the filter, so there the result is whatever the compositor
applies and may be smoothed. That is a stated deviation rather than a hidden one; if it
turns out to matter, the software upscale of R6 is available on Wayland as it is on
X11, and it is the reason R6's implementation is not X11-specific.

### R4. The facade owns the mapping in **both** directions

**Where the mapping lives.** The origin and magnification of R3 are **internal state,
not a published field**: R2 fixes what the application sees, so the physical window
size and the real magnification are deliberately absent from `FramebufferSnapshot`.
The backend supplies them to the facade with the rest of the frame's snapshot, and the
facade latches them for the frame the way 011 R2 latches a single scale factor today —
this is that latch widened from one number to an origin and a magnification.
`.logical` and `.physical` are the case where the origin is zero and the magnification
is the content scale.

**A window moved between displays, or resized, updates the mapping and leaves
`scale_epoch` alone.** Under `.fixed` the epoch tracks the framebuffer, which did not
change; the mapping is not the epoch's subject. This is the one place the two could be
conflated, and doing so would restart the cache invalidation that R2 exists to
eliminate.

**An event is transformed with the mapping latched by the frame that dequeues it**, and
the pointer positions of a frame are therefore mutually consistent even if one of them
was generated before the mapping last changed. This is the rule 011 R2 already states
for the scale factor — the backend enqueues raw physical coordinates and the facade
converts at dequeue — and the tolerance it already accepts: a mapping change takes
effect at a frame boundary, so a position can be off by the difference between two
consecutive mappings, bounded by one frame.

What changes under `.fixed` is **how often that happens**, which is why it is written
down rather than left implied. Under `.logical` and `.physical` the conversion constant
is the content scale, which changes only when the display does — rarely. Under `.fixed`
it is the magnification, which changes on **every window resize**, so the tolerance that
used to apply to a rare event now applies throughout a live resize drag. It is accepted
rather than removed: carrying a mapping generation on every queued event, and keeping
superseded mappings alive to match, is real machinery for an error that lasts one frame
and only while the user is dragging a window edge. A backend that has a generation to
hand may stamp events with it, but nothing requires one.

**Inverse (operating system to application).** A pointer position becomes
`(physical − origin) / magnification`. This replaces, rather than composes with, the
device-pixel-ratio division: under `.fixed` there is no logical space in between (R2).
**Scroll deltas divide by the same magnification** — the facade already divides `dx`
and `dy` by the scale beside the position, and the reason carries over unchanged: the
content under the pointer has to stay under the pointer, which fails if a position and
a movement of that position are scaled differently.

**Forward (application to operating system).** The facade converts framebuffer
coordinates to **physical window pixels**, and every backend entry point that today
receives framebuffer coordinates receives physical window pixels instead, converting to
its own native unit (view points on macOS) from there. Stating the unit at the boundary
is what stops the conversion being applied twice — backends currently derive the ratio
from the framebuffer size themselves, which is correct only while the framebuffer
covers the window.

Three paths carry framebuffer coordinates today and all three are subject to this rule.
The first is an application-facing API; the other two are internal, which is why they
are easy to miss:

| Path | Direction | What breaks under `.fixed` without the mapping |
|---|---|---|
| `Window.setCompositionRect` | forward | The candidate window of an input method is anchored at the wrong place on screen |
| Click-through alpha sampling (macOS) | inverse | The pixel under the cursor is looked up as if the framebuffer covered the window, so the wrong pixel decides whether the click passes through |
| Click-through input region (X11 `XShapeCombineMask`, Wayland `set_input_region`) | forward | A region built at framebuffer size is applied to a window of a different size |

**The letterbox is never opaque to input.** Where a window uses click-through, the bars
count as alpha 0 and a click over them falls through, which is the same thing R9 says
they look like.

Any future API that accepts framebuffer coordinates joins this rule.

The forward direction is called out at length because it is the one that fails quietly.
The harness cannot drive an input method (injected key events do not pass through the
native input context) and cannot observe click-through at all, so both of those show up
only on real hardware.

**Events over the letterbox are delivered unchanged**, with coordinates that may be
negative or beyond the framebuffer. They are neither clamped nor dropped:

- Clamping would synthesise a position inside the content for a pointer that is not
  there, so a press on the bar would act on whatever occupies the nearest edge.
- Dropping would swallow a release that begins inside the content and ends over a bar,
  leaving a drag that never finishes ([025](025_gui-drag-position-on-the-release-frame.md)
  is about exactly this frame).
- Delivering unchanged is what already happens when a drag leaves the window, so
  consumers already tolerate out-of-range positions and no new obligation is created.

### R5. Every backend implements `.fixed`; what is uniform is the mapping, not the filter

A backend that cannot magnify while presenting performs the magnification itself, in
software, into a buffer of the window's size. `.fixed` is therefore available
everywhere, and what it guarantees everywhere is:

- the framebuffer's size and the snapshot's values (R2);
- **which framebuffer pixel lands where on screen** — the destination rectangle, the
  origin and the magnification of R3;
- the coordinate transforms in both directions (R4);
- the letterbox and what it does to input (R4, R9).

Two things are deliberately **not** uniform, and both are stated rather than implied.
**Sampling**: R3 requires nearest neighbour wherever the presenting layer accepts a
filter, and names Wayland's `wp_viewporter` as the case where it does not, so on that
backend the image may be smoothed rather than blocky. **Cost**: R7 tabulates which
processor pays, and it is not the same one everywhere. What an application gets
everywhere is the geometry and the coordinate contract above.

That line is drawn where it is because the alternative is worse in both directions.
Guaranteeing the filter would send Wayland — a first-class backend presenting through
the compositor — to a CPU pass every frame purely to control smoothing, which trades a
real cost for an appearance. Leaving the filter unstated would let a difference that is
visible on screen go unrecorded. The software upscale of R6 remains available on
Wayland for an application that needs the filter more than it needs the compositor
path, which is why R6's implementation is not written as X11-specific.

The rest follows the position 002 and 005 already take — declare the support tier, do
not fork the API — and the reason applies with more force here. The alternatives were:
expose the capability and let each application branch on the backend, which pushes
platform differences onto authors who chose this library to avoid them; or ship
`.fixed` only where it is free and decide later, which leaves the contract undefined
for as long as that takes and makes the eventual answer harder to change. Both are
recorded below.

The consequence is that presenting is no longer uniformly cheap, so R7 makes that
visible instead of hiding it.

**On the web the host page is part of the backend, so the contract reaches it.** The
canvas bitmap is already the framebuffer, but the page stretches it to fill the
viewport, which magnifies without preserving the aspect ratio and so is not R3's
mapping. The delivered host has three obligations, all of them in its stylesheet and
its context creation:

- present the bitmap inside the viewport with the aspect ratio preserved, so that the
  mapping is R3's;
- select nearest-neighbour magnification, per R3;
- show the letterbox per R9, from the element's background.

R9's transparent case does not arise on the web and this mode does not make it arise:
`transparent` is a documented no-op there (019 R4 — a DOM canvas has no window to see
through), so a web window is always opaque and its bars always take the opaque colour.
No option has to reach the host for that, and nothing here decides how `transparent`
would work on the web if it were ever implemented — that belongs to whatever implements
it, together with the drawing context's alpha channel.

**The host does not invert the mapping**, and needs no change to go on not doing so.
R4 puts the inverse in the facade, and what the host produces today is already the
right input for it: a pointer position in physical pixels relative to the viewport,
from the CSS position and the device pixel ratio. Deriving that ratio from the canvas
bitmap instead would be wrong for reasons that predate this mode and are recorded at
the function that does it. Having the host convert all the way to framebuffer
coordinates would apply the mapping twice and would make the web the one backend where
R4's owner is not the facade.

### R6. The software upscale reuses rows, and the obvious implementation is rejected on measurement

**Measured** with `zig build bench-upscale` on aarch64-macos, ReleaseFast, from a
fixed 640x400 framebuffer. The benchmark reports an average and a minimum over its
iterations; each figure below is **the best of those minima over three separate runs of
the command**, run one at a time on an otherwise idle machine. Before anything is
timed, each magnifying candidate is filled over a destination set to a value no
candidate writes, compared pixel by pixel against an independent nearest-neighbour
reference, and checked to have written nothing outside the destination rectangle — so a
candidate cannot look fast by leaving pixels to a previous one. The ratio is against
one write pass over the same destination rectangle (`pixelops.fillRect32`), the floor
for any implementation, since every candidate writes every destination pixel.

| Destination | one write pass | naive (a division per pixel) | column table | **row reuse** |
|---|---|---|---|---|
| 4608x2880 (13.3 Mpx, 7.20x) | 0.79 ms | 8.49 ms (10.7x) | 4.12 ms (5.2x) | **1.27 ms (1.6x)** |
| 3456x2160 (7.5 Mpx, 5.40x) | 0.58 ms | 4.74 ms (8.2x) | 2.31 ms (4.0x) | **1.03 ms (1.8x)** |
| 2560x1600 (4.1 Mpx, 4x) | 0.21 ms | 2.60 ms (12.2x) | 1.27 ms (6.0x) | **0.52 ms (2.5x)** |
| 1920x1200 (2.3 Mpx, 3x) | 0.11 ms | 1.46 ms (13.1x) | 0.72 ms (6.5x) | **0.34 ms (3.0x)** |
| 1280x800 (1.0 Mpx, 2x) | 0.05 ms | 0.65 ms (13.1x) | 0.32 ms (6.5x) | **0.20 ms (4.1x)** |

The absolute values repeat to within a few percent, but the anchor itself varies by
about 10% between runs, so **the ratios are good to about one significant figure** and
the argument below is built on the absolute times rather than on the ratios.

**The table covers the destination rectangle only; the letterbox is extra.** At the 5K
figure above the bars are 1.47 Mpx — 10% of the window — and filling them measures
**0.28 ms**, which is well below the bandwidth a fill reaches over a whole framebuffer
because the bars are two narrow vertical strips and the cost of a fill scales with the
length of each contiguous run rather than with the area. One present at 5K is therefore
about **1.55 ms** in total, not 1.27. The bars are also the one part that does not have
to be repainted every frame: their content never changes while the mapping does not, so
an implementation repaints them when the mapping changes, once per buffer the backend
cycles through.

**Where row reuse is worth nothing**, and why that is acceptable: when the window is
smaller than the framebuffer, every destination row comes from a different source row,
so there is nothing to replicate and row reuse measures exactly as the column table does
(0.033 ms against 0.033 ms at 400x250). Minification is the cheap direction by
definition — the destination is small — so the technique losing its advantage there
costs nothing worth recovering.

The rule that produces the last column: **nearest-neighbour magnification maps several
destination rows onto one source row, so a destination row that has been built once is
replicated with `@memcpy` rather than built again.** The per-row work drops from the
destination row count to the source row count; at 7.20x that is 2880 rows of work
becoming 400. Horizontally, the source column index is hoisted into a table computed
once per window size — never per frame, and never per pixel, which is the same rule the
performance section of `AGENT.md` states for all-pixel loops. When the magnification is
a whole number the horizontal step becomes one vector store per source pixel, measured
at 0.36 ms against 0.52 ms for the table at 4x.

**The decision this measurement settles.** The premise behind R5 — that one
magnification pass costs less than the passes a full-resolution application makes —
holds, but **only for the row-reusing implementation**. Against a 60 fps budget at 5K,
row reuse plus the bars takes 9.3% of the frame and the naive form alone takes 51%. The
naive form is therefore not an acceptable fallback, and R5's uniform contract is
accepted on the condition that the implementation is the one described here.

**Where the break-even sits.** Drawing into the fixed framebuffer costs 1/52 of the
full-resolution area at 5K, which is close enough to nothing to ignore, so `.fixed`
costs roughly one upscale pass plus the bars: 1.55 ms. A full-resolution application
pays at least one write pass — 0.79 ms — for every pass it makes, and clearing plus
content plus a composited interface is already three. `.fixed` therefore wins at 5K
from about two full-resolution passes onward, which every real application is past. It
does **not** win for an application that draws almost nothing, and R9 says so.

The implementation belongs in `libs/pixelops`, which is where this repository's shared
pixel primitives live and where the bit-identical SIMD-versus-scalar test that the
performance rules require has its model. `core` reaching `libs/pixelops` is an
exception that already exists in the build graph for the wasm swizzle; this joins it
rather than opening a new one.

### R7. Support tiers gain a second axis: who pays for the magnification

005 ranks backends by frame pacing. `.fixed` introduces an independent property, and
conflating the two would misread both. Note especially that it is **not** the same as
the implementation cost tabulated in the context section:

| Backend | Frame pacing (005) | Who pays for the magnification |
|---|---|---|
| macOS Metal | first-class | GPU |
| Windows D3D11 | first-class | GPU |
| Linux Wayland | first-class | the compositor |
| macOS objc / swift | best-effort | Core Animation (the compositor) |
| wasm | — | the browser's compositor |
| Windows GDI | best-effort | **CPU**, every frame |
| Linux X11 | best-effort | **CPU**, every frame (software upscale) |

GDI is the case that shows why the two axes are separate: it is nearly free to
implement and is one of the two that pays the most at run time, because
`StretchDIBits` reads less but still writes the whole window from the CPU.

D3D11 is the opposite case, and it is worth stating because the implementation table
reads as if `.fixed` penalises it. Its present today uploads a CPU buffer the size of
the back buffer (`UpdateSubresource`) before copying it. Under `.fixed` **the upload
shrinks to the framebuffer's size** — 14.7 Mpx to 0.26 Mpx at 5K — and the quad is
what buys that. `.fixed` makes D3D11 cheaper, not dearer.

### R8. Order the work by implementation cost, not by tier

Every backend does the common work of the context section — place the destination
rectangle, paint the letterbox — and the order below is set by what the magnification
costs on top of it: CALayer, GDI and wasm first (nothing, given the host obligations in
R5); then Metal (a quad the renderer already draws); then D3D11 and Wayland
(a shader, and `wp_viewporter`); X11 last, with the software upscale of R6. The
click-through paths of R4 belong to whichever backend's step they fall in, not to a
step of their own. Nothing about the published contract changes as the sequence
progresses, because R5 already fixed it.

### R9. What `.fixed` does not promise, and the letterbox colour

**It does not promise a sharp result.** `content_scale` is 1.0 (R2), so an application
has no way to render at the display's resolution: glyphs are rasterised at the fixed
size and magnified along with everything else, blocky where R3's filter applies and
smoothed where R5 says it may not. That is the intended appearance for pixel art and
for anything with a deliberate low resolution, and it is the wrong choice for a
text-heavy interface. `.fixed` buys a bounded frame
cost with the resolution of the result; an application that wants the display's
resolution wants `.physical`.

**The letterbox is black in an opaque window and fully transparent in a window created
with `transparent`** — on the backends where `transparent` does something; where it is
a documented no-op, as on the web, the window is opaque and so are its bars.
The combination is not refused: refusing it would remove the
mode from exactly the applications — a shaped, borderless overlay — that have the most
to gain from a small fixed framebuffer, and the only real problem is that black bars
around a transparent window are wrong. To input the bars are transparent in both cases,
per R4.

The bars are repainted when the mapping changes rather than every frame, and because a
backend cycles through several buffers, that means once per buffer (R6 measures what
one repaint costs). Stating both the colour and the moment here is what stops the
backends from diverging over them.

**A backend that presents through a GPU render target clears the whole target every
frame, and that is not a departure.** Metal, D3D11 and the like begin a render pass by
clearing the drawable or the back buffer, which is work the frame already does and which
the letterbox rides along with at no extra cost; a discard swap chain does not even retain
the previous frame's bars to preserve. The rule exists to stop a backend from repainting
the bars **on the CPU** once per frame, and these do not.

**One backend departs from the moment in the sense the rule means: the opaque GDI present.** It
draws straight into the window's device context and retains no surface of its own, so
there is nowhere for a painted bar to persist and the bars are filled every frame. The
alternative is a retained client-sized DIB plus a memory DC, painted once and blitted
per frame; it would honour the rule, and it is not taken because a best-effort backend
would carry a second full-window buffer for good to save filling the area the
framebuffer does *not* cover — on the backend that already writes the whole window from
the CPU every frame (R7). The transparent GDI present is **not** part of the departure:
`UpdateLayeredWindow` needs a client-sized surface anyway, so it clears that surface
when the destination rectangle moves and leaves the bars alone otherwise, exactly as the
rule says. A bar that is alpha 0 stays alpha 0, because writing the destination never
reaches it.

### R10. What this changes in 002, 005 and 011

- **002 (present)**: present is defined as submitting the drawn frame to the display
  queue. Under `.fixed` it also **maps**: it magnifies the framebuffer into the
  destination rectangle and fills the letterbox. The blocking behaviour, the ownership
  of the pixels after the call, and the meaning of a `null` from `lockFramebuffer` are
  unchanged. On a backend performing the magnification in software, the CPU cost of
  R6's pass is part of `present`.
- **005 (support tiers)**: the tiers are unchanged, and R7 adds the second axis above.
  A backend's tier does not predict what it pays to magnify.
- **011 (coordinates and framebuffer modes)**: the coordinate model gains a third
  space. `.logical` and `.physical` relate a logical space to a physical one; `.fixed`
  relates a framebuffer space to a physical one, with no logical space between them,
  and R2 sets what the snapshot reports. R11 of 011 — that a fullscreen backend
  resolving its own size in physical pixels derives the logical size by division — does
  not apply under `.fixed`, where the framebuffer size is an input rather than a
  derivation. The advice in 011 that an application follows `fb.width`/`fb.height`
  still holds; under `.fixed` those values simply never change.

## Rejected alternatives

**A fixed *logical* size with a device-pixel-ratio-scaled framebuffer.** The
framebuffer would be the fixed size multiplied by the display's scale — 1280x800 on a
2x display for a 640x400 request — with the application laying out in the fixed space
and drawing into the larger one. Text would stay sharp, and the frame cost would still
be bounded (1.0 Mpx against 14.7 Mpx at 5K).

Rejected on two grounds. First, it gives up the guarantee: the framebuffer size again
depends on the machine, so snapshots stop being reproducible and the scale epoch starts
advancing again, bringing back every mechanism 011 introduced to survive a scale change.
Second, it re-introduces a coordinate space — the application's logical space, the
framebuffer, and the screen — where this decision has two. **The value of a thin layer
is in how few mappings it defines**, and this one defines the extra mapping to buy
sharpness that the mode's intended users do not want.

The ordering matters as well: `.fixed` as decided here can be extended with an opt-in
that follows the device pixel ratio, and the guarantee survives for everyone who does
not ask for it. Starting from the scaled form gives no way back, because the guarantee
would never have existed.

**Exposing the capability and letting applications branch.** Publish which backends
magnify while presenting and let each application decide. Rejected: it moves a platform
difference into every application, which is the opposite of what this library is for,
and each author would then reimplement R6 — the part that turns out to need care.

**Shipping `.fixed` only where the magnification is free, and deciding later.** Enable
it on CALayer, GDI and wasm first and defer the uniform contract until the measurement
existed.
Rejected: the measurement is in R6 and it supports the uniform contract, so the delay
buys nothing; and during the delay `.fixed` would mean different things on different
backends, which is a worse starting point than not having it.

**Restricting the magnification to whole numbers.** Sharper in the sense that every
source pixel gets the same number of destination pixels, and the fastest software path
(R6). Rejected as a *requirement* because CALayer — the path whose magnification is free —
magnifies by an arbitrary factor already, so mandating whole numbers would mean
computing and applying a smaller rectangle by hand on the backend that otherwise needs
no magnification code at all. It
remains available as a future option, which is the direction that can be added without
breaking anything.

**Clamping pointer positions to the framebuffer.** Rejected in R4: it invents input
that did not happen, and out-of-range positions already occur when a drag leaves the
window.

## Consequences

- **X11 loses its zero-copy path under `.fixed`.** Its framebuffer is the `XImage`'s
  own storage today, so presenting is a single `XShmPutImage` with no per-frame
  conversion. Under `.fixed` the drawing target and the image handed to X are different
  buffers, so an intermediate of the window's size is allocated — about 59 MB at 5K —
  in addition to R6's per-frame cost. Both are properties of `.fixed` on X11 alone and
  neither affects the other modes.
- **D3D11's upload shrinks** to the framebuffer's size, as set out in R7.
- **GDI reads less and writes the same**, so it gains least.
- **A framebuffer snapshot becomes reproducible** across machines and window sizes for
  any application that selects `.fixed`, which removes resolution as a variable from
  every visual comparison.
- **Live resizing gets simpler, not harder.** The framebuffer does not change size, so
  a resize updates the mapping and nothing else; the application does not need to be
  re-entered to redraw at a new size.
- **`present` is no longer uniformly cheap.** On GDI and X11 it carries a
  full-destination write. R7 states where, and the frame section profiler attributes it
  to the frame body like any other work.
- **Click-through stops being a framebuffer-sized operation.** The alpha sample and the
  input region of R4 are the two places a backend currently equates the framebuffer with
  the window; under `.fixed` they go through the mapping, and the bars are transparent
  to input.
- **The delivered web host gains a contract.** Its stylesheet is no longer free to
  present the canvas however it likes: R5 fixes what it must do, which makes the page
  part of the backend rather than an example. Its pointer conversion already satisfies
  R4 and stays as it is.

## Related

- [002](002_present-blocking-behaviour.md) — the present contract that gains a mapping
  stage
- [005](005_platform-support-tiers-and-frame-pacing.md) — the support tiers, and the
  second axis R7 adds
- [011](011_high-dpi-coordinates-and-fb-modes.md) — the logical/physical model this
  adds a third space to
- [019](019_window-creation-unification.md) — window creation, which records that
  fullscreen at `.physical` needs this mode
- [020](020_kit-versioning-and-maturity-gate.md) — the policy permitting R1's change to
  a published type
- [docs/performance-measurement.md](../performance-measurement.md) — the frame budget
  measurements the context section draws on
