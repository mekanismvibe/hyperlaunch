# hyperlaunch

A tiny macOS tool that turns **Caps Lock into a Hyper key** (⌘⌃⌥⇧) and lets you
**open apps with Hyper + a key**. It replaces a common two-rule Karabiner-Elements
setup while using about 4 MB of memory.

- **Caps Lock → Hyper.** Hold Caps Lock and every key you press gets ⌘⌃⌥⇧, so
  Hyper shortcuts in other apps (Raycast, Rectangle and so on) keep working. Caps
  Lock on its own does nothing, and its light never comes on.
- **Hyper + key opens an app.** For example, Caps Lock + T opens Terminal.
- **Toggle.** If the app is already in front, the same shortcut minimizes it (or
  hides it). Press it again and the app comes back.
- **Settings app.** Hyperlaunch.app lets you add and remove shortcuts with a
  window instead of editing a file. It only runs while its window is open.

| Part | What it is | Memory |
|---|---|---|
| `hyperlaunch` | Background tool, started at login | ~4 MB |
| `Hyperlaunch.app` | Settings window | ~37 MB, only while open |

## Install

You need macOS 14 or later and the Xcode Command Line Tools (`xcode-select --install`).
Full Xcode isn't needed.

```bash
git clone https://github.com/mekanismvibe/hyperlaunch.git
```

```bash
cd hyperlaunch && ./install.sh
```

If you use Karabiner-Elements, quit it first from its menu bar icon. Otherwise
it keeps grabbing Caps Lock.

macOS then asks you to give **hyperlaunch** Accessibility access. Switch it on in
System Settings > Privacy & Security > Accessibility, and Caps Lock becomes Hyper a
couple of seconds later.

The installer puts:

- the background tool in `~/.local/bin/hyperlaunch`,
- the settings app in `~/Applications/Hyperlaunch.app`,
- your shortcuts in `~/.config/hyperlaunch/config` (starting from the example
  [`config`](config)),
- a login item in `~/Library/LaunchAgents/local.hyperlaunch.plist`.

> **Rebuilt it?** macOS ties Accessibility access to the exact build. After
> running `install.sh` again, remove hyperlaunch from the Accessibility list with
> **–**, then add `~/.local/bin/hyperlaunch` back with **+** (press ⌘⇧G in the file
> picker to paste the path).

## Use

Open **Hyperlaunch.app** from Spotlight, or press Caps Lock + , (comma). In the
app you can:

- add a shortcut: click **Add Shortcut…**, pick an app, then press a key,
- remove a shortcut with its trash button,
- choose what happens when the app is already in front: **Minimize it**,
  **Hide it**, or **Leave it open**.

Or edit `~/.config/hyperlaunch/config` directly:

```
when-in-front = minimize

t = Terminal
b = /Applications/Safari.app
e = /System/Library/CoreServices/Finder.app
```

Keys are matched by position on a US keyboard, like Karabiner's `key_code`.
Changes take effect the next time you press Caps Lock. To check the file for
mistakes, run `~/.local/bin/hyperlaunch --check`.

## Uninstall

```bash
./uninstall.sh
```

This stops the tool, gives you your normal Caps Lock back, and removes the program,
the settings app and the login item. Your config file is kept.

## How it works

1. `hidutil`, built into macOS, remaps Caps Lock to F18 at the keyboard-driver
   level, so the caps-lock toggle never fires. The mapping is applied again when a
   keyboard connects.
2. A `CGEventTap` watches F18. While it's held, each key event gets the ⌘⌃⌥⇧
   flags, or opens the app the config assigns to that key.
3. To minimize, hide and restore apps it uses the Accessibility API and
   `NSRunningApplication`, and it opens apps with `open -a`.

Logs go to `~/Library/Logs/hyperlaunch.log`, one line per shortcut press.

## Layout

```
Shared/Config.swift        config file format (used by both programs)
Daemon/main.swift          background tool
Settings/SettingsApp.swift settings window (SwiftUI)
Settings/Info.plist, AppIcon.icns
config                     example shortcuts
install.sh, uninstall.sh
```
