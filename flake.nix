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
        pcre2 = pkgs.fetchurl {
          url = "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.49/pcre2-10.49.tar.gz";
          hash = "sha256-kp8LIOYoeSUqFYhrBsifHt72GjY8vVgm+wQQgKXlV64=";
        };
        # Unpacked under the hash zig expects, see build.zig.zon.
        zigDeps = pkgs.runCommand "jsv-zig-deps" { } ''
          mkdir -p $out/pcre2-10.49.0-IZ6r68cregBKN199ndY6AaKNyKJpNmnQVSm8-h0gp4sj
          tar xzf ${pcre2} --strip-components=1 -C $out/pcre2-10.49.0-IZ6r68cregBKN199ndY6AaKNyKJpNmnQVSm8-h0gp4sj
        '';
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
