#!/bin/bash
# Signs + notarizes the Xcode-built MacControlMCP.app (build it via xcode-mcp-server first).
# Re-signing without an entitlements file strips the debug get-task-allow, giving a clean
# hardened-runtime bundle that notarization accepts.
set -euo pipefail
cd "$(dirname "$0")"

DID="Developer ID Application: Nuclear Cyborg Corp (P8MA38JTXY)"
PROFILE="${NOTARY_PROFILE:-ncc-cli-notarytool}"

SRC=$(find "$HOME/Library/Developer/Xcode/DerivedData/MacControlMCP-"*/Build/Products/Release -maxdepth 1 -name "MacControlMCP.app" 2>/dev/null | head -1)
if [ -z "${SRC:-}" ]; then echo "No Release app found — build the 'Release' scheme via xcode-mcp-server first."; exit 1; fi
echo "source: $SRC"

APP="dist/MacControlMCP.app"
rm -rf dist && mkdir -p dist
cp -R "$SRC" "$APP"

# Strip stray top-level items left by incremental builds — everything must live under
# Contents/ for a valid, signable bundle.
find "$APP" -mindepth 1 -maxdepth 1 ! -name Contents -exec rm -rf {} +

echo "== deep sign (inside-out) =="
codesign --force --options runtime --timestamp -i com.nuclearcyborg.maccontrol.relay -s "$DID" "$APP/Contents/Helpers/MacControlRelay"
codesign --force --options runtime --timestamp -s "$DID" "$APP/Contents/Helpers/MacControlHost.app"
codesign --force --options runtime --timestamp -s "$DID" "$APP"

echo "== verify =="
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP/Contents/Helpers/MacControlHost.app" 2>&1 | grep -E "Identifier|TeamIdentifier" | head -2

echo "== notarize =="
rm -f dist/MacControlMCP.zip
ditto -c -k --keepParent "$APP" dist/MacControlMCP.zip
xcrun notarytool submit dist/MacControlMCP.zip --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vvv -t exec "$APP" 2>&1 || true
echo "== done -> $APP =="
