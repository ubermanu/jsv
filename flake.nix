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
        quickjs = pkgs.fetchFromGitHub {
          owner = "quickjs-ng";
          repo = "quickjs";
          rev = "v0.17.0";
          hash = "sha256-TmKpLIrGeTSYk77hfuIQtxT/k9cxUo30bICqFumgDrY=";
        };
        # Laid out under the hash zig expects, see build.zig.zon.
        zigDeps = pkgs.linkFarm "jsv-zig-deps" {
          "N-V-__8AAHXdRAAredjqGKa2uZcnUUzmDSajEa9AQDETVRYW" = quickjs;
        };
        jsv = pkgs.stdenv.mkDerivation {
          pname = "jsv";
          version = (builtins.fromJSON (builtins.readFile ./packages/jsv/package.json)).version;
          src = ./.;
          nativeBuildInputs = [ pkgs.zig_0_16 ];
          zigBuildFlags = [
            "--system"
            "${zigDeps}"
          ];
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
