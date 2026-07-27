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

- **macOS**: `objc` (default), `swift`, `metal`
- **Linux**: `x11` (default), `wayland`. Wayland has display, input and the editor
  implemented and has been verified on Linux hardware (a busy loop's flood of presents
  is handled by pacing on the frame callback, which is effectively vsync).
- **Windows**: `gdi` (default, best-effort), `d3d11` (first-class frame pacing). Win32 is
  called directly from pure Zig with extern fn and hand-written COM vtables.

A mismatch (asking for `-Dplatform=objc` on Linux) is a clear build error. The shared
types (`KeyCode`, `Event` and so on) have `core/platform_types.zig` as their single
source.

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
nix develop --command bash scripts/xvfb-screenshot.sh out.png -- zig-out/bin/video_proto  # capture the application

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
nix develop --command bash scripts/wayland-screenshot.sh out.png -- zig-out/bin/video_proto        # capture the main program (a smoke test of the rainbow display)
WAYLAND_SHOT_COMPOSITOR=weston nix develop --command bash scripts/wayland-screenshot.sh out.png -- zig-out/bin/video_proto
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
