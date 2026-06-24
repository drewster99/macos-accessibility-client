#!/bin/bash
# Notarizes + staples the signed bundle. Requires the signed dist/MacControlMCP.app
# (run package.sh first) and the notarytool keychain profile.
set -euo pipefail
cd "$(dirname "$0")"

APP="dist/MacControlMCP.app"
ZIP="dist/MacControlMCP.zip"
PROFILE="${NOTARY_PROFILE:-ncc-cli-notarytool}"

echo "== zip =="
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "== notarytool submit --wait (profile: $PROFILE) =="
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "== staple =="
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "== gatekeeper assessment =="
spctl -a -vvv -t exec "$APP" 2>&1 || true
echo "== notarized -> $APP =="
