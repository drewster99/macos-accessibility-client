#!/bin/bash
# TCC-attribution check. Run, grant Accessibility to the printed host path in
# System Settings, then run again. PASS = relay prints "axTrusted":true.
set -uo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"
HOST="$ROOT/build/P0AControl.app/Contents/Helpers/p0a-host"
SVC="P8MA38JTXY.com.nuclearcyborg.p0a.host"
LABEL="com.nuclearcyborg.p0a.host.test"
PLIST="$ROOT/build/$LABEL.plist"
U="$(id -u)"

if [ ! -x "$HOST" ]; then echo "Build first: ./build.sh"; exit 1; fi

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>Program</key><string>$HOST</string>
  <key>MachServices</key><dict><key>$SVC</key><true/></dict>
</dict></plist>
EOF

# Relaunch the host fresh so a just-granted TCC entry takes effect.
launchctl bootout "gui/$U/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$U" "$PLIST"

echo "Grant Accessibility to this host binary, then re-run this script:"
echo "  $HOST"
echo "open: System Settings ▸ Privacy & Security ▸ Accessibility ▸ +"
echo ""
echo "== probe =="
"$ROOT/build/p0a-relay"
echo ""
launchctl bootout "gui/$U/$LABEL" 2>/dev/null || true