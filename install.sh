#!/usr/bin/env bash
set -euo pipefail

LABEL="com.claudetokencounter.menubar"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST_PATH="$HOME/Library/LaunchAgents/${LABEL}.plist"

# Claude Tracker is compiled on this Mac by Apple's Swift compiler, which
# comes with Xcode's Command Line Tools. Without them, /usr/bin/swift still
# exists but only prints an error, so run it rather than just looking for it.
if ! SWIFT_VERSION_TEXT="$(swift --version 2>&1)"; then
    echo "Swift not found. Run this in Terminal to install Xcode's Command Line Tools, then run ./install.sh again:" >&2
    echo "    xcode-select --install" >&2
    exit 1
fi
SWIFT_VERSION="$(printf '%s\n' "$SWIFT_VERSION_TEXT" \
    | sed -n 's/.*Swift version \([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1.\2/p' | head -n 1)"
SWIFT_MAJOR="${SWIFT_VERSION%%.*}"
SWIFT_MINOR="${SWIFT_VERSION#*.}"
if [ -z "$SWIFT_VERSION" ] || [ "$SWIFT_MAJOR" -lt 5 ] || { [ "$SWIFT_MAJOR" -eq 5 ] && [ "$SWIFT_MINOR" -lt 9 ]; }; then
    echo "Claude Tracker needs Swift 5.9 or newer (this Mac has: ${SWIFT_VERSION:-unknown})." >&2
    echo "Update Xcode's Command Line Tools in Software Update, or run: xcode-select --install" >&2
    exit 1
fi

echo "Building Claude Tracker.app (the first build takes a minute or two)..."
if ! APP_EXEC="$("$SCRIPT_DIR/build.sh" | tail -n 1)" || [ ! -x "$APP_EXEC" ]; then
    echo "Building the app failed." >&2
    exit 1
fi

# launchd can't open log files in a folder macOS protects (Desktop,
# Documents, Downloads) and then won't start the app (exit 78), so the logs
# live in ~/Library/Logs, not next to the project.
LOG_DIR="$HOME/Library/Logs/ClaudeTracker"
mkdir -p "$LOG_DIR"
mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${APP_EXEC}</string>
        <string>--foreground</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/agent.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/agent.err.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
# bootout returns before the old copy has fully stopped; wait for it, or
# bootstrap fails with "5: Input/output error".
for _ in $(seq 1 50); do
    launchctl print "gui/$(id -u)/${LABEL}" >/dev/null 2>&1 || break
    sleep 0.1
done
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"

APP_BUNDLE="${APP_EXEC%/Contents/MacOS/*}"
# The LaunchAgent starts it now, unless start at login was turned off in
# Settings (launchd then skips it): open the app itself instead.
sleep 1
if ! launchctl print "gui/$(id -u)/${LABEL}" 2>/dev/null | grep -q "state = running"; then
    open "$APP_BUNDLE"
fi
echo "Installed and started. Look for the coin icon (🪙) in your menu bar."
echo "Claude Tracker is also in Finder at: ${APP_BUNDLE}"
echo "It will start automatically the next time you log in."
