#!/bin/bash
# Build claudepad and install it as a login LaunchAgent.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh

BIN="$PWD/bin/claudepad"
PLIST="$HOME/Library/LaunchAgents/com.katspaugh.claudepad.plist"
LOG="$HOME/.claude/claudepad/claudepad.log"
mkdir -p "$HOME/.claude/claudepad"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.katspaugh.claudepad</string>
  <key>ProgramArguments</key><array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>$LOG</string>
  <key>StandardOutPath</key><string>$LOG</string>
</dict>
</plist>
EOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
echo "installed and started: $PLIST"
echo "logs: $LOG"
echo
echo "NOTE: on first pad press, macOS will ask for Automation permission"
echo "(claudepad wants to control Ghostty) — approve it. Manage later under"
echo "System Settings → Privacy & Security → Automation."
