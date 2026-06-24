#!/bin/bash
# P0a spike builder. THROWAWAY — compiled with swiftc on purpose (it is not the product;
# the product builds via xcode-mcp-server). Assembles a signed control app whose bundled
# LaunchAgent vends the host's Mach service on demand, plus a good relay and an ad-hoc
# "evil" relay to prove XPC admission rejects non-team callers.
set -euo pipefail
cd "$(dirname "$0")"

DID="Developer ID Application: Nuclear Cyborg Corp (P8MA38JTXY)"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos13.0"
BUILD="./build"
APP="$BUILD/P0AControl.app"

echo "== clean =="
rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Library/LaunchAgents"

echo "== compile (swiftc, target $TARGET) =="
swiftc -swift-version 5 -target "$TARGET" -O Shared.swift Host.swift  -o "$APP/Contents/Helpers/p0a-host"
swiftc -swift-version 5 -target "$TARGET" -O Control.swift            -o "$APP/Contents/MacOS/P0AControl"
swiftc -swift-version 5 -target "$TARGET" -O Shared.swift Relay.swift -o "$BUILD/p0a-relay"
cp "$BUILD/p0a-relay" "$BUILD/p0a-relay-evil"

echo "== assemble bundle =="
cp control-Info.plist     "$APP/Contents/Info.plist"
cp host.launchagent.plist "$APP/Contents/Library/LaunchAgents/com.nuclearcyborg.p0a.host.plist"

echo "== sign (hardened runtime; nested first, app last) =="
codesign --force --options runtime -i com.nuclearcyborg.p0a.host  -s "$DID" "$APP/Contents/Helpers/p0a-host"
codesign --force --options runtime -i com.nuclearcyborg.p0a.relay -s "$DID" "$BUILD/p0a-relay"
codesign --force -s - "$BUILD/p0a-relay-evil"            # ad-hoc: no team OU -> must be rejected
codesign --force --options runtime -s "$DID" "$APP"

echo "== verify =="
echo "--- app ---";        codesign -dvv "$APP" 2>&1 | grep -E "Identifier|TeamIdentifier|Authority=Developer ID" | head
echo "--- good relay ---"; codesign -dvv "$BUILD/p0a-relay" 2>&1 | grep -E "TeamIdentifier|Authority=Developer ID" | head -2
echo "--- evil relay ---"; codesign -dvv "$BUILD/p0a-relay-evil" 2>&1 | grep -E "Signature=adhoc|linker-signed|TeamIdentifier" | head -2

echo "== done -> $APP =="
