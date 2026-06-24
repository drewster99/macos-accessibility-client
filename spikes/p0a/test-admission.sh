#!/bin/bash
# Autonomous portion of P0a: on-demand launch + XPC admission (no TCC grant needed).
# Registers the host's Mach service via launchctl (bypassing SMAppService login-item
# approval, which is human-gated), then connects a team-signed relay (expect ACCEPT)
# and an ad-hoc relay (expect REJECT by setConnectionCodeSigningRequirement).
set -uo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"
HOST="$ROOT/build/P0AControl.app/Contents/Helpers/p0a-host"
SVC="P8MA38JTXY.com.nuclearcyborg.p0a.host"
LABEL="com.nuclearcyborg.p0a.host.test"
PLIST="$ROOT/build/$LABEL.plist"
U="$(id -u)"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>Program</key><string>$HOST</string>
  <key>MachServices</key><dict><key>$SVC</key><true/></dict>
</dict></plist>
EOF

launchctl bootout "gui/$U/$LABEL" 2>/dev/null || true
echo "== bootstrap on-demand agent =="
if launchctl bootstrap "gui/$U" "$PLIST"; then echo "bootstrap ok"; else echo "bootstrap FAILED ($?)"; fi

echo ""; echo "== good relay (team-signed) -> expect host JSON, connection ACCEPTED =="
"$ROOT/build/p0a-relay"; echo "(relay exit $?)"

echo ""; echo "== evil relay (ad-hoc) -> expect REJECTED (error/invalidation) =="
"$ROOT/build/p0a-relay-evil"; echo "(relay exit $?)"

echo ""; echo "== host log tail =="
tail -8 ~/Library/Logs/p0a-host.log 2>/dev/null || echo "(no host log)"

echo ""; echo "== cleanup =="
launchctl bootout "gui/$U/$LABEL" 2>/dev/null && echo "booted out" || echo "(already gone)"
