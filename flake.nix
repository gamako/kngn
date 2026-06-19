{
  description = "video-proto: Zig 0.16 dev environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zls = {
      url = "github:zigtools/zls/0.16.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, zig-overlay, zls, ... }:
    let
      # 対応 system を明示列挙（flake-utils 等の追加依存は持たない）。
      darwin = "aarch64-darwin";
      linux = "x86_64-linux";
      pkgsFor = system: nixpkgs.legacyPackages.${system};
      zigFor = system: zig-overlay.packages.${system}."0.16.0";
      zlsFor = system: zls.packages.${system}.default;
    in {
      # macOS: 既存どおり（platform backend は objc/swift/metal、SDK は xcrun で解決）
      devShells.${darwin}.default = (pkgsFor darwin).mkShellNoCC {
        packages = [
          (zigFor darwin)
          (zlsFor darwin)
        ];
      };

      # Linux: x11 backend（TASK-28.2〜）+ ヘッドレス検証 + ファイルダイアログ用の依存を供給。
      devShells.${linux}.default =
        let
          pkgs = pkgsFor linux;
        in
        pkgs.mkShellNoCC {
          packages = [
            (zigFor linux)
            (zlsFor linux)
            # X11 backend (TASK-28.2): Xlib / Xext
            pkgs.xorg.libX11
            pkgs.xorg.libXext
            # Wayland backend build 依存 (TASK-28.5.1): libwayland-client / xkbcommon /
            # xdg-shell.xml(wayland-protocols) / wayland-scanner。
            # 注: wayland-scanner の属性名は shiso で要確認（独立 pkgs.wayland-scanner か pkgs.wayland.bin か）。
            # 検証用 compositor(weston/sway)・screenshot(grim)・入力(wtype) は TASK-28.5.5 で追加する。
            pkgs.wayland
            pkgs.wayland-protocols
            pkgs.wayland-scanner
            pkgs.libxkbcommon
            # ヘッドレス検証: Xvfb(xorgserver) → xwd → ffmpeg で PNG 撮影
            pkgs.xorg.xorgserver
            pkgs.xorg.xwd
            pkgs.ffmpeg
            # 入力の合成（TASK-28.3 検証）: Xvfb へキー/マウス/ホイールを送出
            pkgs.xdotool
            # ファイルダイアログ (TASK-28.4)
            pkgs.zenity
            # L1 オーディオ出力 (TASK-28.7): ALSA (libasound) を audio exe にリンク
            pkgs.alsa-lib
            # ネイティブライブラリ解決
            pkgs.pkg-config
          ];
          # nix の libasound は ALSA プラグイン (pipewire/pulse 等) を自前の plugin dir
          # からしか探さないため、PipeWire/Pulse 経由の `default` PCM を開くと
          # libasound_module_pcm_pipewire.so が見つからず NoDevice になる (TASK-28.7)。
          # system の ALSA プラグイン dir を ALSA_PLUGIN_DIR で補い、run-synth / run-example_15 が
          # 標準の nix フローで発音できるようにする (dir が無い環境では何もしない＝無害)。
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
