#!/bin/bash
# Builds, assembles, and Developer-ID-signs (hardened runtime) the product bundle:
#   MacControlMCP.app/
#     Contents/MacOS/MacControlRegistrar     (SMAppService registrar — main exe, LSUIElement)
#     Contents/Helpers/MacControlHost         (privileged XPC host — the LaunchAgent program)
#     Contents/Helpers/MacControlRelay         (stdio relay MCP clients launch)
#     Contents/Library/LaunchAgents/com.nuclearcyborg.maccontrol.host.plist
# Run notarize.sh afterwards to notarize + staple.
set -euo pipefail
cd "$(dirname "$0")"

DID="Developer ID Application: Nuclear Cyborg Corp (P8MA38JTXY)"
APP="dist/MacControlMCP.app"

echo "== swift build -c release =="
swift build -c release
BIN="$(swift build -c release --show-bin-path)"

echo "== assemble bundle =="
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Library/LaunchAgents"
cp "$BIN/MacControlRegistrar" "$APP/Contents/MacOS/MacControlRegistrar"
cp "$BIN/MacControlHost"      "$APP/Contents/Helpers/MacControlHost"
cp "$BIN/MacControlRelay"     "$APP/Contents/Helpers/MacControlRelay"
cp packaging/Info.plist            "$APP/Contents/Info.plist"
cp packaging/host.launchagent.plist "$APP/Contents/Library/LaunchAgents/com.nuclearcyborg.maccontrol.host.plist"

echo "== sign (hardened runtime, timestamp; nested first, app last) =="
codesign --force --options runtime --timestamp -i com.nuclearcyborg.maccontrol.host  -s "$DID" "$APP/Contents/Helpers/MacControlHost"
codesign --force --options runtime --timestamp -i com.nuclearcyborg.maccontrol.relay -s "$DID" "$APP/Contents/Helpers/MacControlRelay"
codesign --force --options runtime --timestamp -s "$DID" "$APP/Contents/MacOS/MacControlRegistrar"
codesign --force --options runtime --timestamp -s "$DID" "$APP"

echo "== verify =="
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "Identifier|TeamIdentifier|Authority=Developer ID|flags|Runtime" | head
echo "== done -> $APP =="
