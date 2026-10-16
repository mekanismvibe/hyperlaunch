// hyperlaunch: Caps Lock becomes a Hyper key (⌘⌃⌥⇧), and Hyper+key opens apps.
//
// How it works:
//   1. hidutil (built into macOS) remaps Caps Lock to F18 below the OS, so the
//      caps-lock toggle and its light never fire.
//   2. A keyboard event tap watches F18. While it's held, every key gets ⌘⌃⌥⇧
//      added (so Hyper shortcuts in other apps keep working), and keys listed in
//      the config open their app instead. If that app is already in front, the
//      shortcut minimizes or hides it (the config's when-in-front setting).
//
// Build:   swiftc -O -swift-version 5 Shared/Config.swift Daemon/main.swift -o hyperlaunch
// Config:  ~/.config/hyperlaunch/config   (re-read automatically after you save it)
// Check:   hyperlaunch --check [config file]

import AppKit
import ApplicationServices
import IOKit.hid

let f18: Int64 = 0x4F  // kVK_F18, what Caps Lock turns into

// ⌘⌃⌥⇧ plus the device bits for the *left* keys, the same thing Karabiner sends.
let hyperFlags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift,
                                CGEventFlags(rawValue: 0x2B)]
let hyperOnly: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

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

var targets: [Int64: Target] = [:]
var whenInFront = WhenInFront.minimize
var configStamp: Date?

func loadConfig() {
    configStamp = (try? FileManager.default.attributesOfItem(atPath: configPath))?[.modificationDate] as? Date
    guard let file = ConfigFile.load() else {
        log("no config at \(configPath)")
        targets = [:]
        return
    }
    let parsed = file.parse()
    parsed.problems.forEach { log("config \($0)") }
    targets = Dictionary(parsed.shortcuts.map { (keyCodes[$0.key]!, Target($0.app)) },
                         uniquingKeysWith: { a, _ in a })
    whenInFront = parsed.whenInFront
    log("loaded \(targets.count) shortcuts (when in front: \(whenInFront.rawValue))")
}

func reloadConfigIfChanged() {
    let stamp = (try? FileManager.default.attributesOfItem(atPath: configPath))?[.modificationDate] as? Date
    if stamp != configStamp { loadConfig() }
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

// MARK: - Keyboard handling

var tap: CFMachPort?
var hyperDown = false
var swallowed = Set<Int64>()  // keys whose keyDown opened an app; drop their keyUp too
var keyStateWorks = false

func f18IsHeld() -> Bool {
    CGEventSource.keyState(.hidSystemState, key: CGKeyCode(f18))
}

func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    let key = event.getIntegerValueField(.keyboardEventKeycode)
    let isDown = type == .keyDown

    if key == f18 {
        if isDown && !hyperDown {
            hyperDown = true
            keyStateWorks = f18IsHeld()
            reloadConfigIfChanged()
        } else if !isDown {
            hyperDown = false
        }
        return nil  // Caps Lock itself never reaches apps
    }

    if !isDown && swallowed.remove(key) != nil { return nil }

    // Password fields hide key events from taps, so a Caps Lock release can go
    // missing. If the system's key state is readable, use it to un-stick Hyper.
    if hyperDown && keyStateWorks && !f18IsHeld() { hyperDown = false }

    // Like the Karabiner rule, a real ⌘⌃⌥⇧ held down also counts as Hyper for launching.
    guard hyperDown || event.flags.isSuperset(of: hyperOnly) else {
        return Unmanaged.passUnretained(event)
    }

    if isDown, let target = targets[key] {
        swallowed.insert(key)
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            let mode = whenInFront
            actions.async { toggle(target, mode) }
        }
        return nil
    }

    if hyperDown { event.flags.formUnion(hyperFlags) }
    return Unmanaged.passUnretained(event)
}

var askedForAccess = false

func startTap() {
    let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
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
    mapCapsLockToF18(true)
    reapplyWhenKeyboardsConnect()
    log("ready: Caps Lock is Hyper")
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
                                             mapCapsLockToF18(true)
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
        mapCapsLockToF18(false)  // give Caps Lock back
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)  // don't wait long on a frozen app
loadConfig()
startTap()
CFRunLoopRun()
