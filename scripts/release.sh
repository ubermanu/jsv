#!/usr/bin/env bash
set -euo pipefail

version=${1:?usage: scripts/release.sh <version>}
version=${version#v}

cd "$(dirname "$0")/.."

if [[ -n $(git status --porcelain) ]]; then
  echo "working tree is not clean" >&2
  exit 1
fi

for manifest in packages/*/package.json; do
  jq --arg v "$version" '.version = $v' "$manifest" > "$manifest.tmp"
  mv "$manifest.tmp" "$manifest"
done
sed -i "s/^    .version = \".*\",/    .version = \"$version\",/" build.zig.zon

git commit -am "Release v$version"
git tag "v$version"
git push origin HEAD "v$version"
