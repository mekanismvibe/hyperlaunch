#!/bin/bash
# Stops hyperlaunch, gives Caps Lock back, and removes the program, settings app and login item.
LABEL="local.hyperlaunch"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null
hidutil property --set '{"UserKeyMapping":[]}' >/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$HOME/.local/bin/hyperlaunch"
rm -rf "$HOME/Applications/Hyperlaunch.app"

echo "hyperlaunch removed and Caps Lock restored."
echo "Your shortcuts are still in ~/.config/hyperlaunch/config if you want them."
echo "You can also remove hyperlaunch from System Settings > Privacy & Security > Accessibility."
