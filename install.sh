#!/bin/bash
# Builds hyperlaunch and its settings app, installs your shortcuts, and starts it
# now and at every login.
set -euo pipefail
cd "$(dirname "$0")"

LABEL="local.hyperlaunch"
BIN="$HOME/.local/bin/hyperlaunch"
APP="$HOME/Applications/Hyperlaunch.app"
CONF="$HOME/.config/hyperlaunch/config"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/hyperlaunch.log"

# Karabiner's root service keeps running after Quit, but it only grabs the keyboard
# while this per-user piece is connected to it.
if pgrep -q -f karabiner_console_user_server; then
  echo "Note: Karabiner-Elements is still running. Quit it (menu bar icon > Quit Karabiner-Elements),"
  echo "      otherwise it keeps grabbing Caps Lock before hyperlaunch can see it."
  echo
fi

echo "Building the background tool..."
mkdir -p "$(dirname "$BIN")"
swiftc -O -swift-version 5 Shared/Config.swift Daemon/main.swift -o "$BIN"

echo "Building Hyperlaunch.app (settings)..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -parse-as-library Shared/Config.swift Settings/SettingsApp.swift \
  -o "$APP/Contents/MacOS/Hyperlaunch"
cp Settings/Info.plist "$APP/Contents/Info.plist"
cp Settings/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" 2>/dev/null

if [ -f "$CONF" ]; then
  echo "Keeping your existing $CONF"
else
  mkdir -p "$(dirname "$CONF")"
  cp config "$CONF"
fi

mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF

if launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1; then
  launchctl kickstart -k "gui/$UID/$LABEL"  # restart on the new build
else
  launchctl bootstrap "gui/$UID" "$PLIST"
fi

cat <<EOF

Installed and running.

1. Accessibility access: macOS asks for it the first time. After a rebuild like this
   one, macOS sees a new program, so in System Settings > Privacy & Security >
   Accessibility select hyperlaunch, remove it with -, then click +, press Cmd+Shift+G,
   paste  $BIN  and switch it on. Caps Lock becomes Hyper a couple of seconds later.

2. Manage shortcuts in Hyperlaunch.app (in your Applications folder), or edit
   $CONF by hand. Changes apply the next time you press Caps Lock.

Log: $LOG
Uninstall: ./uninstall.sh
EOF
