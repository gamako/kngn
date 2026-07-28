{
  description = "kngn: Zig 0.16 dev environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    # Extra pin so alsa-lib matches the host (nixos-unstable; NixOS reports 26.11) version.
    # Needed because the host pipewire ALSA plugins (/etc/alsa/conf.d absolute paths,
    # built against unstable alsa-lib 1.2.15.3) must be dlopen-able by the libasound the app links.
    # 25.11's 1.2.14 is too old: the plugin fails to open and yields NoDevice.
    # Take only alsa-lib version/src from this input; build with the 25.11 stdenv (glibc stays 25.11; see alsaLibFor). Other packages stay on 25.11.
    # If the host later moves to a newer alsa, this pin can go stale again (known constraint: bump the pin).
    nixpkgs-audio.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zls = {
      url = "github:zigtools/zls/0.16.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, nixpkgs-audio, zig-overlay, zls, ... }:
    let
      # Explicit system list (no extra deps such as flake-utils).
      darwin = "aarch64-darwin";
      linux = "x86_64-linux";
      pkgsFor = system: nixpkgs.legacyPackages.${system};
      zigFor = system: zig-overlay.packages.${system}."0.16.0";
      zlsFor = system: zls.packages.${system}.default;
      # alsa-lib uses the same version/src as the host (nixos-unstable) but builds with the 25.11 stdenv
      # (see the nixpkgs-audio input comments). Taking unstable alsa-lib wholesale would pull unstable
      # glibc (2.42) and break older system glibc distros (e.g. Ubuntu 24.04) with GLIBC_ABI_* mismatches.
      # So base the 25.11 alsa-lib derivation and swap only version/src to newer,
      # keeping glibc on 25.11 (legacy distro compatible) while raising alsa symbols to 1.2.15.3.
      alsaLibFor = system:
        let
          base = (pkgsFor system).alsa-lib; # Keep the 25.11 stdenv/glibc
          newer = nixpkgs-audio.legacyPackages.${system}.alsa-lib; # Same version/src as the host (src tarball only)
        in
        base.overrideAttrs (_old: {
          inherit (newer) version src;
        });
    in {
      # macOS: as before (platform backends objc/swift/metal; SDK via xcrun)
      devShells.${darwin}.default = (pkgsFor darwin).mkShellNoCC {
        packages = [
          (zigFor darwin)
          (zlsFor darwin)
        ];
      };

      # Linux: x11 backend + headless verification + file-dialog deps.
      devShells.${linux}.default =
        let
          pkgs = pkgsFor linux;
        in
        pkgs.mkShellNoCC {
          packages = [
            (zigFor linux)
            (zlsFor linux)
            # X11 backend: Xlib / Xext
            pkgs.xorg.libX11
            pkgs.xorg.libXext
            # Wayland backend build deps: libwayland-client / xkbcommon /
            # xdg-shell.xml(wayland-protocols) / wayland-scanner (confirmed as independent attrs via nix eval).
            pkgs.wayland
            pkgs.wayland-protocols
            pkgs.wayland-scanner
            pkgs.libxkbcommon
            # Wayland headless verification: headless compositor + screenshot + keyboard synthesis.
            # Default: sway(WLR_BACKENDS=headless)+grim; alternative: weston(headless backend)+weston-screenshooter
            # used by scripts/wayland-screenshot.sh. Keyboard synthesis via wtype. Attr names confirmed via nix eval,
            # but real headless startup/screenshot/input must be checked on a Linux host. mouse/scroll need ydotool (uinput
            # permissions are heavy) so they stay out of the devShell and in the manual-check range (see AGENT.md).
            pkgs.sway
            pkgs.grim
            pkgs.wtype
            pkgs.weston
            # Headless verification: Xvfb(xorgserver) → xwd → ffmpeg to PNG
            pkgs.xorg.xorgserver
            pkgs.xorg.xwd
            pkgs.ffmpeg
            # Input synthesis: send keys/mouse/wheel into Xvfb
            pkgs.xdotool
            # File dialog
            pkgs.zenity
            # Dynamic system font resolution: fc-match
            pkgs.fontconfig
            # L1 audio output: link ALSA (libasound) into audio executables.
            # Fetch only alsa-lib from unstable to match the host (nixos-unstable) pipewire plugin build
            # (25.11's 1.2.14 fails plugin dlopen with NoDevice; see nixpkgs-audio input comments).
            (alsaLibFor linux)
            # Native library resolution
            pkgs.pkg-config
          ];
          # nix libasound only searches its own plugin dir for ALSA plugins (pipewire/pulse etc.),
          # so opening the `default` PCM via PipeWire/Pulse fails to find
          # libasound_module_pcm_pipewire.so and yields NoDevice.
          # Point ALSA_PLUGIN_DIR at the system ALSA plugin dir so run-synth / run-example_15
          # can make sound under the standard nix flow (no-op and harmless when the dir is absent).
          shellHook = ''
            if [ -z "''${ALSA_PLUGIN_DIR:-}" ]; then
              for d in /usr/lib/x86_64-linux-gnu/alsa-lib /usr/lib/alsa-lib /usr/lib64/alsa-lib; do
                if [ -d "$d" ]; then export ALSA_PLUGIN_DIR="$d"; break; fi
              done
            fi
          '';
        };
    };
}
