#!/usr/bin/env bash
# Builds the to-do app and installs it as an .app bundle (default ~/Applications), so
# Finder, Spotlight, the Dock and Login Items can start it. Finder passes no arguments
# and no shell PATH, so the bundle's Info.plist carries the kit, node and language.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
kit=$(cd "$here/../.." && pwd)
node=${SDLC_TODO_NODE:-$(command -v node || true)}
[ -n "$node" ] || { echo "install-macos.sh: node not found; set SDLC_TODO_NODE" >&2; exit 1; }
lang=${SDLC_TODO_LANG:-en}
name=${SDLC_TODO_APP_NAME:-sdlc To-do}
dir=${1:-$HOME/Applications}
app="$dir/$name.app"
[ "$(uname)" = Darwin ] || { echo "install-macos.sh: macOS only" >&2; exit 1; }
cargo build --release --manifest-path "$here/Cargo.toml"
xml() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<<"$1"; }
env_entry() { printf '    <key>%s</key><string>%s</string>\n' "$1" "$(xml "$2")"; }
mkdir -p "$app/Contents/MacOS"
cp "$here/target/release/sdlc-todo" "$app/Contents/MacOS/sdlc-todo"
{
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>sdlc-todo</string>
  <key>CFBundleIdentifier</key><string>dev.sdlc-kit.todo</string>
  <key>CFBundleName</key><string>$(xml "$name")</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$(cat "$kit/VERSION")</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSEnvironment</key>
  <dict>
PLIST
  env_entry SDLC_TODO_KIT "$kit"
  env_entry SDLC_TODO_NODE "$node"
  env_entry SDLC_TODO_LANG "$lang"
  [ -z "${SDLC_TODO:-}" ] || env_entry SDLC_TODO "$SDLC_TODO"
  printf '  </dict>\n</dict>\n</plist>\n'
} > "$app/Contents/Info.plist"
# LaunchServices caches Info.plist; re-register so a changed environment takes effect.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app" 2>/dev/null || true
echo "$app"
