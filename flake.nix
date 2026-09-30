{
  description = "Validate JSON files against their $schema automatically";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        jsv = pkgs.stdenv.mkDerivation {
          pname = "jsv";
          version = (builtins.fromJSON (builtins.readFile ./packages/jsv/package.json)).version;
          src = ./.;
          nativeBuildInputs = [ pkgs.zig_0_16 ];
        };
      in
      {
        packages.default = jsv;

        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.zig_0_16
            pkgs.nodejs
            pkgs.pnpm
          ];
        };
      }
    );
}
