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
        jsv = pkgs.rustPlatform.buildRustPackage {
          pname = "jsv";
          version = "0.1.0";
          src = ./.;
          cargoLock.lockFile = ./Cargo.lock;
        };
      in
      {
        packages.default = jsv;

        devShells.default = pkgs.mkShell {
          inputsFrom = [ jsv ];
          packages = [
            pkgs.cargo
            pkgs.rustc
            pkgs.rustfmt
            pkgs.clippy
            pkgs.nodejs
            pkgs.pnpm
          ];
        };
      }
    );
}
