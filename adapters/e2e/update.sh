#!/usr/bin/env bash
# Refresh the vendored e2e agent guide from the npm package, pinned by version.
# Usage: adapters/e2e/update.sh [e2e-version]   (default: the version in adapters/e2e/VERSION)
# Needs npm and tar only while updating; using the vendored guide needs neither.
set -eu
DIR=$(cd "$(dirname "$0")" && pwd)
case "${1:-}" in -h|--help) sed -n '2,4p' "$0" | sed 's/^# //'; exit 0;; esac
current=$(awk -F': *' '$1=="e2e"{print $2}' "$DIR/VERSION")
version=${1:-$current}
[ -n "$version" ] || { echo 'update.sh: no e2e version given or pinned' >&2; exit 2; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
( cd "$tmp" && npm pack --silent "e2e@$version" >/dev/null )
tar -xzf "$tmp"/e2e-*.tgz -C "$tmp"
src=$tmp/package
[ -f "$src/skills/e2e/SKILL.md" ] || { echo "update.sh: e2e@$version has no skills/e2e/SKILL.md" >&2; exit 1; }
dest=$DIR/vendor/e2e-skill
rm -rf "$dest.new"; mkdir -p "$dest.new"
cp -R "$src/skills/e2e/." "$dest.new/"
cp "$src/LICENSE" "$src/NOTICE" "$dest.new/"
rm -rf "$dest"; mv "$dest.new" "$dest"
# @e2e-dev/web declares a peer range on e2e; record the latest web release to install beside it.
web=$(npm view @e2e-dev/web version 2>/dev/null || true)
node=$(awk -F'"' '/"node"/{print $4; exit}' "$src/package.json")
cat > "$DIR/VERSION" <<V
e2e: $version
web: ${web:-unknown}
node: ${node:-unknown}
source: https://www.npmjs.com/package/e2e (skills/e2e, LICENSE, NOTICE)
updated: $(date +%Y-%m-%d)
V
echo "vendored e2e@$version guide into $dest"
