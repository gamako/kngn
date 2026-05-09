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
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};
      zig = zig-overlay.packages.${system};
    in {
      devShells.${system}.default = pkgs.mkShellNoCC {
        packages = [
          zig."0.16.0"
          zls.packages.${system}.default
        ];
      };
    };
}
