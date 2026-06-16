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
            # ヘッドレス検証: Xvfb(xorgserver) → xwd → ffmpeg で PNG 撮影
            pkgs.xorg.xorgserver
            pkgs.xorg.xwd
            pkgs.ffmpeg
            # 入力の合成（TASK-28.3 検証）: Xvfb へキー/マウス/ホイールを送出
            pkgs.xdotool
            # ファイルダイアログ (TASK-28.4)
            pkgs.zenity
            # ネイティブライブラリ解決
            pkgs.pkg-config
          ];
        };
    };
}
