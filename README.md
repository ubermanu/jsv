# jsv

Validate JSON files against the schema named in their own `$schema` field. No schema flag, no config.

## Install

```sh
npm install -g @ubermanu/jsv
```

With Nix:

```sh
nix profile install github:ubermanu/jsv
```

Or from source:

```sh
cargo install --git https://github.com/ubermanu/jsv jsv
```

## Usage

```sh
jsv package.json tsconfig.json
```

`$schema` can be a URL or a path relative to the file. Exits `1` if any file is invalid or has no `$schema`.
