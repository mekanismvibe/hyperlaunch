// hyperlaunch: turns keys into Hyper keys (⌘⌃⌥⇧) or other shortcuts, and opens
// apps with Hyper + a key.
//
// How it works:
//   1. A keyboard event tap watches the keys the config remaps. A `hyperkey` adds
//      its modifiers to every key pressed while it's held; a `remap` key is
//      rewritten into its shortcut. Caps Lock can't be caught as a key press, so
//      when it's remapped, hidutil (built into macOS) turns it into F18 first.
//   2. With all four modifiers held, keys listed in the config open their app. If
//      that app is already in front, the shortcut minimizes or hides it instead
//      (the config's when-in-front setting).
//
// Build:   swiftc -O -swift-version 5 Shared/Config.swift Daemon/main.swift -o hyperlaunch
// Config:  ~/.config/hyperlaunch/config   (re-read automatically after you save it)
// Check:   hyperlaunch --check [config file]

import AppKit
import ApplicationServices
import IOKit.hid

let hyperOnly: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

/// Event flags for some modifiers, with the device bits for the *left* keys, the
/// same thing Karabiner sends.
func eventFlags(_ mods: Mods) -> CGEventFlags {
    var flags: CGEventFlags = []
    if mods.contains(.ctrl) { flags.formUnion([.maskControl, CGEventFlags(rawValue: 0x01)]) }
    if mods.contains(.shift) { flags.formUnion([.maskShift, CGEventFlags(rawValue: 0x02)]) }
    if mods.contains(.cmd) { flags.formUnion([.maskCommand, CGEventFlags(rawValue: 0x08)]) }
    if mods.contains(.opt) { flags.formUnion([.maskAlternate, CGEventFlags(rawValue: 0x20)]) }
    return flags
}

let timestamp: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

func log(_ message: String) {
    FileHandle.standardError.write(Data("\(timestamp.string(from: Date())) \(message)\n".utf8))
}

// MARK: - Config

/// An app a shortcut opens, plus what's needed to recognise it once it's running.
struct Target {
    let app: String  // what `open -a` gets
    let url: URL?
    let bundleID: String?

    init(_ app: String) {
        self.app = app
        url = resolveApp(app)
        bundleID = url.flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    var name: String { url?.deletingPathExtension().lastPathComponent ?? app }

    func matches(_ running: NSRunningApplication) -> Bool {
        if let bundleID, running.bundleIdentifier == bundleID { return true }
        guard let url, let other = running.bundleURL else { return false }
        return url.standardizedFileURL.path == other.standardizedFileURL.path
    }
}

enum Remap {
    case hold(CGEventFlags)
    case press(CGEventFlags, keyCode: Int64)
}

var targets: [Int64: Target] = [:]
var remaps: [Int64: Remap] = [:]
var whenInFront = WhenInFront.minimize
var configStamp: Date?

func loadConfig() {
    configStamp = (try? FileManager.default.attributesOfItem(atPath: configPath))?[.modificationDate] as? Date
    guard let file = ConfigFile.load() else {
        log("no config at \(configPath)")
        targets = [:]
        remaps = [:]
        return
    }
    let parsed = file.parse()
    parsed.problems.forEach { log("config \($0)") }
    targets = Dictionary(parsed.shortcuts.map { (keyCode($0.key)!, Target($0.app)) },
                         uniquingKeysWith: { a, _ in a })
    remaps = Dictionary(parsed.remaps.map { remap -> (Int64, Remap) in
        switch remap.action {
        case .hold(let mods): return (sourceKeyCode(remap.source)!, .hold(eventFlags(mods)))
        case .press(let mods, let key): return (sourceKeyCode(remap.source)!, .press(eventFlags(mods), keyCode: keyCode(key)!))
        }
    }, uniquingKeysWith: { a, _ in a })
    whenInFront = parsed.whenInFront

    // Keep held hyper keys in step with the new config.
    for code in held.keys {
        if case .hold(let flags) = remaps[code] { held[code] = flags } else { held[code] = nil }
    }
    if tap != nil { updateCapsLockMapping() }
    log("loaded \(targets.count) shortcuts and \(remaps.count) remapped keys (when in front: \(whenInFront.rawValue))")
}

func reloadConfigIfChanged() {
    let stamp = (try? FileManager.default.attributesOfItem(atPath: configPath))?[.modificationDate] as? Date
    if stamp != configStamp { loadConfig() }
}

var configWatcher: DispatchSourceFileSystemObject?

/// Reloads as soon as the config is saved. Watches the folder, since most editors
/// (and the settings app) save by replacing the file.
func watchConfig() {
    let folder = (configPath as NSString).deletingLastPathComponent
    let fd = open(folder, O_EVTONLY)
    guard fd >= 0 else {
        log("can't watch \(folder) for changes")
        return
    }
    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
    source.setEventHandler(handler: reloadConfigIfChanged)
    source.setCancelHandler { close(fd) }
    source.resume()
    configWatcher = source
}

// MARK: - Windows (Accessibility API)

func axWindows(_ pid: pid_t) -> [AXUIElement]? {
    var value: CFTypeRef?
    let app = AXUIElementCreateApplication(pid)
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success else { return nil }
    return value as? [AXUIElement]
}

func isMinimized(_ window: AXUIElement) -> Bool {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value)
    return value as? Bool ?? false
}

func setMinimized(_ window: AXUIElement, _ minimized: Bool) -> Bool {
    var settable: DarwinBoolean = false
    guard AXUIElementIsAttributeSettable(window, kAXMinimizedAttribute as CFString, &settable) == .success,
          settable.boolValue else { return false }
    let value = minimized ? kCFBooleanTrue : kCFBooleanFalse
    return AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, value!) == .success
}

func hasVisibleWindow(_ pid: pid_t) -> Bool {
    guard let windows = axWindows(pid) else { return true }  // can't tell, so assume it does
    return windows.contains { !isMinimized($0) }
}

/// After minimizing, hand focus to the app whose window is now on top, like Cmd+H does.
func focusAppBelow(_ pid: pid_t) {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return }
    for info in list {
        guard (info[kCGWindowLayer as String] as? Int) == 0,
              let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner != pid,
              let app = NSRunningApplication(processIdentifier: owner), app.activationPolicy == .regular
        else { continue }
        let element = AXUIElementCreateApplication(owner)
        if AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue) != .success,
           let url = app.bundleURL {
            launch(url.path)
        }
        return
    }
}

// MARK: - Actions

let actions = DispatchQueue(label: "hyperlaunch.actions")  // keeps slow apps off the keyboard thread

func launch(_ app: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-a", app]
    do { try p.run() } catch { log("couldn't run open for \(app): \(error)") }
}

/// Brings the app forward, or puts it away if it's already in front.
func toggle(_ target: Target, _ mode: WhenInFront) {
    if mode != .nothing, let front = NSWorkspace.shared.frontmostApplication,
       target.matches(front), hasVisibleWindow(front.processIdentifier) {
        let pid = front.processIdentifier
        let minimized = mode == .minimize
            ? (axWindows(pid) ?? []).filter { !isMinimized($0) }.map { setMinimized($0, true) }.filter { $0 }.count
            : 0
        if minimized > 0 {
            focusAppBelow(pid)
            log("\(target.name): minimized \(minimized) window(s)")
        } else {
            front.hide()  // asked to hide, or nothing could be minimized
            log("\(target.name): hidden")
        }
        return
    }
    // Coming back: if we minimized everything last time, un-minimize it first.
    var restored = 0
    if mode == .minimize, let running = NSWorkspace.shared.runningApplications.first(where: target.matches),
       let windows = axWindows(running.processIdentifier), !windows.isEmpty, windows.allSatisfy(isMinimized) {
        restored = windows.map { setMinimized($0, false) }.filter { $0 }.count
    }
    launch(target.app)
    log("\(target.name): opened\(restored > 0 ? ", restored \(restored) window(s)" : "")")
}

var capsLockMapped = false

func mapCapsLockToF18(_ on: Bool) {
    // HID usages: 0x700000039 is Caps Lock, 0x70000006D is F18.
    let mapping = on
        ? #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x700000039,"HIDKeyboardModifierMappingDst":0x70000006D}]}"#
        : #"{"UserKeyMapping":[]}"#
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
    p.arguments = ["property", "--set", mapping]
    p.standardOutput = FileHandle.nullDevice
    do {
        try p.run()
        p.waitUntilExit()
    } catch {
        log("hidutil failed: \(error)")
    }
}

/// Turns the Caps Lock → F18 remap on or off to match the config.
func updateCapsLockMapping() {
    let wanted = remaps[capsLockCode] != nil
    if wanted != capsLockMapped {
        mapCapsLockToF18(wanted)
        capsLockMapped = wanted
    }
}

// MARK: - Keyboard handling

var tap: CFMachPort?
var held: [Int64: CGEventFlags] = [:]  // hyper keys held right now, and the modifiers they add
var keyStateWorks: [Int64: Bool] = [:]
var swallowed = Set<Int64>()  // keys whose keyDown opened an app; drop their keyUp too
var noticed = Set<Int64>()  // special keys already written to the log

let systemDefined: UInt32 = 14  // NX_SYSDEFINED: media keys and other special keys

func isHeld(_ code: Int64) -> Bool {
    CGEventSource.keyState(.hidSystemState, key: CGKeyCode(code))
}

/// Logs each special top-row key once, so you can tell what a key sends if it
/// can't be picked in the settings app. Ordinary typing is never logged.
func notice(_ type: CGEventType, _ event: CGEvent) {
    if type.rawValue == systemDefined {
        guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return }  // 8: special keys
        let keyType = Int64((ns.data1 & 0xFFFF_0000) >> 16)
        if noticed.insert(0x10000 + keyType).inserted { log("noticed system key type \(keyType)") }
    } else {
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if key >= 0x80, noticed.insert(key).inserted { log("noticed special key \"\(keyName(key))\"") }
    }
}

func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    if type.rawValue == systemDefined {
        notice(type, event)
        return Unmanaged.passUnretained(event)
    }
    let key = event.getIntegerValueField(.keyboardEventKeycode)
    let isDown = type == .keyDown
    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

    switch remaps[key] {
    case .hold(let flags):
        if isDown && held[key] == nil {
            held[key] = flags
            keyStateWorks[key] = isHeld(key)
            reloadConfigIfChanged()
        } else if !isDown {
            held[key] = nil
        }
        return nil  // the hyper key itself never reaches apps
    case .press(let flags, let target):
        event.setIntegerValueField(.keyboardEventKeycode, value: target)
        event.flags = flags.union(event.flags.intersection(.maskNonCoalesced))
        return Unmanaged.passUnretained(event)
    case nil:
        break
    }
    if isDown && !isRepeat { notice(type, event) }

    if !isDown && swallowed.remove(key) != nil { return nil }

    // Password fields hide key events from taps, so a hyper key's release can go
    // missing. Where the system's key state is readable, use it to un-stick it.
    for code in held.keys where keyStateWorks[code] == true && !isHeld(code) {
        held[code] = nil
    }

    let added = held.values.reduce(CGEventFlags()) { $0.union($1) }
    let flags = event.flags.union(added)

    // All four modifiers, from hyper keys or real ones like the Karabiner rule, open apps.
    if isDown, flags.isSuperset(of: hyperOnly), let target = targets[key] {
        swallowed.insert(key)
        if !isRepeat {
            let mode = whenInFront
            actions.async { toggle(target, mode) }
        }
        return nil
    }

    if !added.isEmpty { event.flags = flags }
    return Unmanaged.passUnretained(event)
}

var askedForAccess = false

func startTap() {
    let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        | (CGEventMask(1) << systemDefined)
    guard let newTap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                         options: .defaultTap, eventsOfInterest: mask,
                                         callback: { _, type, event, _ in handle(type, event) },
                                         userInfo: nil) else {
        if !askedForAccess {
            askedForAccess = true
            log("waiting for Accessibility access (System Settings > Privacy & Security > Accessibility)")
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: startTap)
        return
    }
    tap = newTap
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, newTap, 0), .commonModes)
    CGEvent.tapEnable(tap: newTap, enable: true)
    updateCapsLockMapping()
    reapplyWhenKeyboardsConnect()
    let names = remaps.keys.map { keyLabel(sourceKeyName($0)) }.sorted()
    log("ready: \(names.isEmpty ? "no keys remapped yet" : "remapped " + names.joined(separator: ", "))")
}

// MARK: - Keyboards connecting later

var keyboardPort: IONotificationPortRef?
var keyboardIterator: io_iterator_t = 0

// Re-apply the Caps Lock remap whenever a keyboard connects (say, a Bluetooth
// keyboard reconnecting after sleep), in case it doesn't pick up the mapping itself.
func reapplyWhenKeyboardsConnect() {
    keyboardPort = IONotificationPortCreate(kIOMainPortDefault)
    CFRunLoopAddSource(CFRunLoopGetMain(),
                       IONotificationPortGetRunLoopSource(keyboardPort).takeUnretainedValue(),
                       .defaultMode)
    let match: [String: Any] = [kIOProviderClassKey: kIOHIDDeviceKey,
                                kIOHIDPrimaryUsagePageKey: kHIDPage_GenericDesktop,
                                kIOHIDPrimaryUsageKey: kHIDUsage_GD_Keyboard]
    IOServiceAddMatchingNotification(keyboardPort, kIOFirstMatchNotification, match as CFDictionary,
                                     { _, iterator in
                                         drain(iterator)
                                         DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                             if capsLockMapped { mapCapsLockToF18(true) }
                                         }
                                     }, nil, &keyboardIterator)
    drain(keyboardIterator)  // these are the keyboards already connected; draining arms the notification
}

func drain(_ iterator: io_iterator_t) {
    var service = IOIteratorNext(iterator)
    while service != 0 {
        IOObjectRelease(service)
        service = IOIteratorNext(iterator)
    }
}

// MARK: - Main

if CommandLine.arguments.dropFirst().first == "--check" {
    let path = CommandLine.arguments.dropFirst(2).first ?? configPath
    guard let file = ConfigFile.load(path) else {
        print("no config at \(path)")
        exit(1)
    }
    let parsed = file.parse()
    var missing = 0
    for remap in parsed.remaps {
        print("\(keyLabel(remap.source))  ->  \(remap.summary)")
    }
    print("when in front: \(parsed.whenInFront.rawValue)")
    for shortcut in parsed.shortcuts {
        let found = resolveApp(shortcut.app).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        if !found { missing += 1 }
        print("hyper + \(keyLabel(shortcut.key))  ->  \(shortcut.app)\(found ? "" : "   (NOT FOUND)")")
    }
    parsed.problems.forEach { print("warning: \($0)") }
    exit(parsed.problems.isEmpty && missing == 0 ? 0 : 1)
}

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        if capsLockMapped { mapCapsLockToF18(false) }  // give Caps Lock back
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)  // don't wait long on a frozen app
loadConfig()
watchConfig()
startTap()
CFRunLoopRun()
