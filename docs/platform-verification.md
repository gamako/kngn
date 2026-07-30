# Verifying the platform backends on Linux and Windows

The tier definitions and the frame pacing contract for each backend are in
[ADR-005](adr/005_platform-support-tiers-and-frame-pacing.md). This document covers the
practical side: how to build and verify on Linux and Windows.

## Choosing a backend (it depends on the OS)

`core/platform.zig` (the facade) switches backend on `builtin.os.tag`, and
`build_options.platform_backend` picks the concrete implementation. On Linux,
`core/platform_linux.zig` (a dispatcher) chooses the x11 or wayland implementation from
`platform_backend` (`platform_linux_x11.zig` / `platform_linux_wayland.zig`, with the
shared `getTime` and dialogs in `platform_linux_common.zig`). Windows has the same shape:
`core/platform_windows.zig` (a dispatcher) chooses gdi or d3d11
(`platform_windows_gdi.zig` / `platform_windows_d3d11.zig`, with the shared window,
input, dialogs, `getTime` and CPU backing in `platform_windows_common.zig`). The valid
values of `-Dplatform` change by OS:

- **macOS**: `metal` (default), `swift`, `objc`
- **Linux**: `x11` (default), `wayland`. Wayland has display, input and the editor
  implemented and has been verified on Linux hardware (a busy loop's flood of presents
  is handled by pacing on the frame callback, which is effectively vsync).
- **Windows**: `gdi` (default, best-effort), `d3d11` (first-class frame pacing). Win32 is
  called directly from pure Zig with extern fn and hand-written COM vtables.

A mismatch (asking for `-Dplatform=objc` on Linux) is a clear build error. The shared
types (`KeyCode`, `Event` and so on) have `core/platform_types.zig` as their single
source.

### Confirming the selected backend from the application

External projects import the umbrella module (`@import("kit")`) and read the
build-selected backend name at runtime:

```zig
const kit = @import("kit");
const backend = kit.platform.activeBackend(); // e.g. "metal", "x11", "d3d11"
```

`activeBackend()` returns a static slice of the build option (`build_options.platform_backend`).
Do not free it. It is available before `platform.init()`. Typical uses:

```zig
// Snippet for code that already has `const kit = @import("kit");` and a
// `kit.platform.Window` bound as `window` (for example after createWindow).
const std = @import("std");

// Assert the build graph picked the backend the e2e script expects.
std.debug.assert(std.mem.eql(u8, kit.platform.activeBackend(), "d3d11"));

// Surface it in the window title (author-facing diagnostics only).
var title_buf: [64]u8 = undefined;
const title = try std.fmt.bufPrintZ(&title_buf, "demo ({s})", .{kit.platform.activeBackend()});
window.setTitle(title);

// Or in a HUD string with the same value.
```

Under `KNGN_HEADLESS=1` the null runtime is used, but `activeBackend()` still reports the
**build-selected** backend (so a gdi vs d3d11 build remains distinguishable). To tell whether
the native renderer is actually running, combine it with the harness capabilities fields
`backend` and `headless_active` (`digest capabilities`; see [harness.md](harness.md)):

```text
{"backend":"metal","headless_active":false,...}  # native metal runtime
{"backend":"metal","headless_active":true,...}   # metal build, null runtime
```

## Building and verifying on Linux (x86_64)

`flake.nix` provides two systems, `aarch64-darwin` and `x86_64-linux`. The Linux
devShell includes zig 0.16, zls, the X11 dev libraries (`libX11`, `libXext`), Xvfb
(`xorgserver`), `xwd`, `ffmpeg`, `zenity` and `xdotool` (for synthesising input).

> **Transferring sources**: the script that sends sources to Linux or Windows hardware
> to build natively there contains the machine names, so it lives in the private
> meta repository. Nothing in it is required to build: clone this repository on the
> target machine and build natively there (the script only saves a round trip).

Input (keys, mouse, scroll, modifiers) is translated from `XEvent`s by
`core/platform_linux_x11.zig`. Physical keys become a `KeyCode` through the evdev X
keycode table (layout independent; KeySym is not used). The pure translation logic is
separated into `core/platform_linux_input.zig` (pure Zig with no `@cImport`), so
`zig build test-platform-input` can **unit test it with no display at all** (it is part
of the aggregate `test`).

```bash
# Enter the devShell (use nix develop where direnv is absent)
nix develop --command zig build -Dplatform=x11   # build the x11 backend

# Unit test the input translation (no X server needed, OS independent)
nix develop --command zig build test-platform-input

# Headless verification (for an SSH environment with no GUI session): run under Xvfb and take a PNG
nix develop --command bash scripts/xvfb-screenshot.sh out.png                 # capture the root window (a smoke test)
nix develop --command bash scripts/xvfb-screenshot.sh out.png -- zig-out/bin/kngn_demo  # capture the application

# Synthesising input with xdotool: send keys, mouse and wheel to the application under Xvfb
#   DISPLAY=:99 xdotool key a / mousemove X Y / click 1 / click 4 (wheel up)
```

## The Wayland backend (`-Dplatform=wayland`)

The Wayland backend (`core/platform_linux_wayland.zig`: wl_shm, xdg-shell,
wl_keyboard/pointer and xkbcommon) **needs Linux, the Wayland libraries and a real
session to compile, display and take input**, so it cannot be verified on macOS (it was
confirmed on Linux hardware). The pure input translation is separated into
`core/platform_wayland_input.zig` (pure Zig with no `@cImport`), so
`zig build test-platform-wayland-input` can **unit test it with no display** (it runs on
macOS and is part of the aggregate `test`). Physical keys use the same evdev+8 table as
X11 (layout independent).

```bash
nix develop --command zig build -Dplatform=wayland          # build the wayland backend
nix develop --command zig build run-pixie -Dplatform=wayland # run the editor on Wayland
nix develop --command zig build test-platform-wayland-input  # unit test the input translation (no compositor, OS independent)
```

**Headless verification** (for an SSH environment with no GUI session):
`scripts/wayland-screenshot.sh` runs the application on a headless compositor and takes a
PNG — the Wayland counterpart of `xvfb-screenshot.sh`. The default is sway
(`WLR_BACKENDS=headless`) plus `grim`; `WAYLAND_SHOT_COMPOSITOR=weston` switches to
weston (its headless backend) plus `weston-screenshooter`.

```bash
nix develop --command bash scripts/wayland-screenshot.sh out.png                                  # capture the compositor output (a smoke test)
nix develop --command bash scripts/wayland-screenshot.sh out.png -- zig-out/bin/kngn_demo        # capture the main program (a smoke test of the rainbow display)
WAYLAND_SHOT_COMPOSITOR=weston nix develop --command bash scripts/wayland-screenshot.sh out.png -- zig-out/bin/kngn_demo
```

> How a compositor starts headless, its output name, and the screenshooter's permissions
> all **depend on the Linux machine**, so the final adjustment happens there (Wayland
> cannot run on macOS; the script can only be syntax-checked with `bash -n`).

### Synthesising input, and how far it can be automated

There is no unified equivalent of X11's `xdotool` on Wayland.

- **Keyboard**: `wtype` (the Wayland virtual-keyboard protocol). It depends on
  compositor support (whether it works on a headless sway or weston has to be confirmed
  on Linux hardware). If the compositor's socket lives under a dedicated
  `XDG_RUNTIME_DIR`, pass that too:
  `XDG_RUNTIME_DIR=<dir> WAYLAND_DISPLAY=wayland-N wtype a` (in a real session, the
  existing environment variables are enough: `wtype a`).
- **Mouse and scroll**: either a compositor-specific mechanism or `ydotool`. `ydotool`
  needs permission on `/dev/uinput` (root, the `input` group, or a systemd service),
  which is too risky for CI-style automation, so **it is not in the devShell and stays in
  the manual range**.
- **What can be automated**: starting a headless compositor, a screenshot smoke test of
  the main program, and — if the compositor supports it — a keyboard smoke test with
  `wtype`.
- **What stays manual**: mouse move, click and scroll; the editor's canvas drawing, GUI
  hover, press and drag, and undo; and the zenity dialog appearing in a real Wayland
  session. These are checked by eye in an ordinary user Wayland session (GNOME, KDE,
  Sway).

### When the zenity file dialog appears on Wayland

`saveFileDialog` and `openFileDialog` use the zenity subprocess in
`core/platform_linux_common.zig` on both X11 and Wayland (backend independent). zenity is
a GTK application, so whether it appears depends on the session:

- In an ordinary Wayland desktop session (GNOME, KDE, Sway), GTK and zenity run under
  `WAYLAND_DISPLAY` and the file chooser appears.
- The file chooser is affected by whether `xdg-desktop-portal` (and a backend service) is
  present.
- Over SSH, on a headless compositor, or on a minimal weston, there is no portal and no
  desktop integration, so **the window itself appears but the dialog does not** — or GTK
  fails to initialise (`error.DialogFailed`). Check dialogs in an ordinary user Wayland
  session.
- When a dialog does not appear, do not immediately call it a failure: check whether
  `zenity` exists, and check `WAYLAND_DISPLAY`, `DISPLAY` (XWayland),
  `XDG_CURRENT_DESKTOP` and whether `xdg-desktop-portal` is running.

## Windows

Install zig 0.16 on the machine and build natively (`flake.nix` does not cover Windows).

**A known limitation, unaddressed**: git on Windows does not materialise symbolic links
by default (`core.symlinks=false`, developer mode off) and instead expands them as a
**text file containing the link target**. So `examples/*/build_helpers` and
`apps/editor/build_helpers` are broken on Windows, and **building a sample on its own
(`cd examples/<NAME> && zig build`) fails there**. A `zig build` from the top of the
repository works on Windows, because `build.zig` references real paths and never goes
through a symlink. To build a sample standalone on Windows, either check out again with
developer mode on and `core.symlinks=true` to restore real symlinks, or change
`build.zig` to remove the symlink dependency of `build_helpers` (neither is done today).

### Confirming the selected backend

On a Windows desktop session, the same checks as in
[Confirming the selected backend from the application](#confirming-the-selected-backend-from-the-application)
apply. Build each backend into a separate prefix so stale artifacts cannot mask a miss,
then assert via `digest capabilities` (not a temporary window-title patch):

```powershell
# Build each backend to its own prefix (do not reuse %errorlevel% — use $LASTEXITCODE).
Remove-Item -Recurse -Force out-gdi,out-d3d11 -ErrorAction SilentlyContinue
zig build -Dplatform=gdi -p out-gdi
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
zig build -Dplatform=d3d11 -p out-d3d11
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# Replay script (two lines): digest capabilities / quit
$env:KNGN_HARNESS_SCRIPT = "backend-capabilities.txt"
& .\out-gdi\bin\kngn_demo.exe *> out-gdi-harness.log
& .\out-d3d11\bin\kngn_demo_d3d11.exe *> out-d3d11-harness.log
# Expect: "backend":"gdi","headless_active":false  and  "backend":"d3d11","headless_active":false
```

`kit.platform.activeBackend()` returns the build-selected name (`"gdi"` or `"d3d11"`) for
in-process asserts or a HUD. Under `KNGN_HEADLESS=1`, pair it with
`"headless_active":true` from capabilities so a null-runtime run is not mistaken for a
native GDI/D3D11 session.

### RDP keyboard input and physical keys

Remote Desktop's default **Unicode keyboard mode** does not deliver physical key events
for character keys. Mouse input was observed to work normally. `WM_CHAR` still arrives in
both Unicode and scancode modes, so the text-input path stays alive; only the physical
`KeyCode` path is affected.

| RDP mode | Observed raw values | Result |
|---|---|---|
| Unicode/default | `vk=0xE7 sc=0x00 ext=0 keycode=-1` | `VK_PACKET` (Unicode character injection); physical key unknown |
| Scancode | `vk=0x10 sc=0x2A keycode=340` | left Shift translated normally |

`VK_PACKET` is Unicode character injection, not a physical key. A scancode of `0` has no
physical key identity. The Windows backend's `keyFromMessage` prefers the scancode, and
`vkToKeyCode` deliberately does **not** synthesise letter keys from the virtual-key code.
That is an intentional contract, not a bug to paper over:

- Reporting a non-physical source as a physical key would invent identity the OS did not
  provide.
- Synthesising letters from VK would make Windows alone layout-dependent and break the
  shared physical-position contract with X11 and Wayland.

Therefore **no code change** is made for this; verification of physical keys on RDP must
switch the RDP client to **scancode mode**. The same missing-physical-key behaviour can
appear with the on-screen keyboard and with `SendInput`-style automation that injects
Unicode rather than scancodes.

**Diagnostics**: a Windows GUI-subsystem binary has no usable stderr, and an SSH session
typically lands in session 0 where the desktop window is not visible. In practice the only
reliable on-box check was to print the raw `vk` / `sc` / `keycode` values into the window
title and read them by eye on the interactive desktop session.
