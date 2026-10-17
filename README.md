# hyperlaunch

A tiny macOS tool that turns **Caps Lock (or any key) into a Hyper key** (⌃⌥⇧⌘),
can **remap keys to shortcuts**, and lets you **open apps with Hyper + a key**. It
replaces a common Karabiner-Elements setup while using about 4 MB of memory.

- **Hyper keys.** Hold Caps Lock and every key you press gets ⌃⌥⇧⌘, so Hyper
  shortcuts in other apps (Raycast, Rectangle and so on) keep working. You can
  make any other key a Hyper key too, or pick fewer modifiers (for example ⌃⌥⇧).
  The key on its own does nothing, and the Caps Lock light never comes on.
- **Remapped keys.** Make a key press a shortcut instead. For example, the
  🎤 Dictation key can press ⌥Space to start a voice-to-text app instead of
  macOS Dictation. Holding the key holds the shortcut, so push-to-talk works.
- **Hyper + key opens an app.** For example, Caps Lock + T opens Terminal.
- **Toggle.** If the app is already in front, the same shortcut minimizes it (or
  hides it). Press it again and the app comes back.
- **Settings app.** Hyperlaunch.app lets you set all of this up in a window. It
  only runs while its window is open.

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
it keeps grabbing your keys.

macOS then asks you to give **hyperlaunch** Accessibility access. Switch it on in
System Settings > Privacy & Security > Accessibility, and Caps Lock becomes Hyper a
couple of seconds later.

The installer puts:

- the background tool in `~/.local/bin/hyperlaunch`,
- the settings app in `~/Applications/Hyperlaunch.app`,
- your settings in `~/.config/hyperlaunch/config` (starting from the example
  [`config`](config)),
- a login item in `~/Library/LaunchAgents/local.hyperlaunch.plist`.

> **Rebuilt it?** macOS ties Accessibility access to the exact build. After
> running `install.sh` again, remove hyperlaunch from the Accessibility list with
> **–**, then add `~/.local/bin/hyperlaunch` back with **+** (press ⌘⇧G in the file
> picker to paste the path).

## Use

Open **Hyperlaunch.app** from Spotlight, or press Caps Lock + , (comma). It has
three sections.

**Keys**: click **Add Key…**, press the key you want to change (or pick Caps Lock,
🎤 Dictation, Spotlight or Do Not Disturb from **Special Keys**), then choose:

- **A Hyper key**, and which modifiers it holds. All four make a full Hyper key,
  which also opens your app shortcuts.
- **A shortcut**, and record the shortcut it should press.

Use the pencil to change a key or the trash to put it back to normal.

**App Shortcuts**: click **Add Shortcut…**, pick an app, then press a key. Remove
one with its trash button.

**If the app is already in front**: choose **Minimize it**, **Hide it** or
**Leave it open**.

Or edit `~/.config/hyperlaunch/config` directly:

```
hyperkey capslock = ctrl opt shift cmd
remap mic = opt space

when-in-front = minimize

t = Terminal
b = /Applications/Safari.app
e = /System/Library/CoreServices/Finder.app
```

Keys are matched by position on a US keyboard, like Karabiner's `key_code`. Keys
without a name can be written as `codeN` with their key code. Changes take effect
as soon as you save. To check the file for mistakes, run
`~/.local/bin/hyperlaunch --check`.

## Uninstall

```bash
./uninstall.sh
```

This stops the tool, gives you your normal Caps Lock back, and removes the program,
the settings app and the login item. Your config file is kept.

## How it works

1. A `CGEventTap` watches the keys in the config. A Hyper key's own presses are
   swallowed, and while it's held, every other key event gets its modifiers. A
   remapped key's events are rewritten into the shortcut, key down and key up.
2. Caps Lock doesn't send a normal key press, so when it's set up, `hidutil`
   (built into macOS) first remaps it to F18 at the keyboard-driver level. The
   mapping is applied again when a keyboard connects.
3. To minimize, hide and restore apps it uses the Accessibility API and
   `NSRunningApplication`, and it opens apps with `open -a`.

Logs go to `~/Library/Logs/hyperlaunch.log`: one line per app shortcut, and a
line the first time each special top-row key is pressed, to help set it up. It
never logs ordinary typing.

## Layout

```
Shared/Config.swift        config file format (used by both programs)
Daemon/main.swift          background tool
Settings/SettingsApp.swift settings window (SwiftUI)
Settings/Info.plist, AppIcon.icns
config                     example config
install.sh, uninstall.sh
```
