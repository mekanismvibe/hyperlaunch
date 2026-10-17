// The config file format, shared by the background tool and the settings app.
//
//   hyperkey capslock = cmd ctrl opt shift   (hold it and other keys get these modifiers)
//   remap mic = opt space                    (press it and this shortcut is pressed instead)
//   when-in-front = minimize                 (or hide, or nothing)
//   m = /Applications/Feishin.app            (Hyper + key opens the app)
//
// One entry per line; # starts a comment.

import Foundation

let configPath = NSHomeDirectory() + "/.config/hyperlaunch/config"

// macOS virtual key codes, by position on a US keyboard (like Karabiner's key_code).
let keyCodes: [String: Int64] = [
    "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
    "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
    "t": 0x11, "o": 0x1F, "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28,
    "n": 0x2D, "m": 0x2E,
    "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "5": 0x17, "6": 0x16, "7": 0x1A, "8": 0x1C,
    "9": 0x19, "0": 0x1D,
    "equal": 0x18, "-": 0x1B, "]": 0x1E, "[": 0x21, "'": 0x27, ";": 0x29, "\\": 0x2A,
    ",": 0x2B, "/": 0x2C, ".": 0x2F, "`": 0x32,
    "return": 0x24, "tab": 0x30, "space": 0x31, "delete": 0x33, "escape": 0x35,
    "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61,
    "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
    "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
    // The special top-row keys on recent Apple keyboards (where F4, F5 and F6 are).
    "spotlight": 0xB1, "mic": 0xB0, "dnd": 0xB2,
]
let keyNames = Dictionary(keyCodes.map { ($1, $0) }, uniquingKeysWith: { a, _ in a })

/// Caps Lock can't be caught as a key press, so the background tool has hidutil
/// turn it into F18 and watches for that instead.
let capsLockCode: Int64 = 0x4F

/// The code for a key name. Keys without a name are written `code176`.
func keyCode(_ name: String) -> Int64? {
    if let code = keyCodes[name] { return code }
    if name.hasPrefix("code"), let code = Int64(name.dropFirst(4)), (0..<0x400).contains(code) { return code }
    return nil
}

/// Like `keyCode`, plus `capslock`, which can only be remapped, not pressed with Hyper.
func sourceKeyCode(_ name: String) -> Int64? {
    name == "capslock" ? capsLockCode : keyCode(name)
}

func keyName(_ code: Int64) -> String {
    keyNames[code] ?? "code\(code)"
}

func sourceKeyName(_ code: Int64) -> String {
    code == capsLockCode ? "capslock" : keyName(code)
}

/// How a key name is shown to people: "M", "Space", "F5", "←", "=".
func keyLabel(_ name: String) -> String {
    switch name {
    case "equal": return "="
    case "left": return "←"
    case "right": return "→"
    case "up": return "↑"
    case "down": return "↓"
    case "capslock": return "Caps Lock"
    case "mic": return "Mic / Dictation"
    case "spotlight": return "Spotlight"
    case "dnd": return "Do Not Disturb"
    case "return", "tab", "space", "delete", "escape": return name.capitalized
    default:
        if name.hasPrefix("code") { return "Key \(name.dropFirst(4))" }
        return name.uppercased()
    }
}

/// Modifier keys, listed in the order macOS shows them: ⌃⌥⇧⌘.
struct Mods: OptionSet, Hashable {
    let rawValue: Int
    static let ctrl = Mods(rawValue: 1)
    static let opt = Mods(rawValue: 2)
    static let shift = Mods(rawValue: 4)
    static let cmd = Mods(rawValue: 8)
    static let hyper: Mods = [.ctrl, .opt, .shift, .cmd]
    static let each: [(mod: Mods, name: String, symbol: String)] =
        [(.ctrl, "ctrl", "⌃"), (.opt, "opt", "⌥"), (.shift, "shift", "⇧"), (.cmd, "cmd", "⌘")]

    init(rawValue: Int) { self.rawValue = rawValue }

    /// One word from the config: "cmd", "option", "⌥" and so on.
    init?(word: String) {
        switch word {
        case "cmd", "command", "⌘": self = .cmd
        case "ctrl", "control", "⌃": self = .ctrl
        case "opt", "option", "alt", "⌥": self = .opt
        case "shift", "⇧": self = .shift
        default: return nil
        }
    }

    var symbols: String { Mods.each.filter { contains($0.mod) }.map(\.symbol).joined() }
    var names: [String] { Mods.each.filter { contains($0.mod) }.map(\.name) }
}

/// A key that does something else: acts as modifiers while held, or presses a shortcut.
struct KeyRemap: Equatable {
    enum Action: Equatable {
        case hold(Mods)
        case press(Mods, key: String)
    }

    var source: String
    var action: Action

    var configLine: String {
        switch action {
        case .hold(let mods): return "hyperkey \(source) = \(mods.names.joined(separator: " "))"
        case .press(let mods, let key): return "remap \(source) = \((mods.names + [key]).joined(separator: " "))"
        }
    }

    var summary: String {
        switch action {
        case .hold(let mods): return mods == .hyper ? "Hyper key (⌃⌥⇧⌘)" : "Holds \(mods.symbols)"
        case .press(let mods, let key): return "Presses \(mods.symbols)\(keyLabel(key))"
        }
    }

    /// Reads `hyperkey <key> = <mods>` or `remap <key> = <mods> <key>`; nil if the line is neither.
    static func parse(name: String, value: String) -> (remap: KeyRemap?, problem: String?)? {
        guard let source = ConfigFile.remapSource(name: name) else { return nil }
        guard sourceKeyCode(source) != nil else { return (nil, "unknown key \"\(source)\"") }
        var mods = Mods()
        var keys: [String] = []
        for word in value.lowercased().split(whereSeparator: { $0 == " " || $0 == "+" }).map(String.init) {
            if let mod = Mods(word: word) { mods.insert(mod) } else { keys.append(word) }
        }
        if name.hasPrefix("hyperkey") {
            guard keys.isEmpty, !mods.isEmpty else {
                return (nil, "a hyperkey takes modifiers, like `cmd ctrl opt shift`")
            }
            return (KeyRemap(source: source, action: .hold(mods)), nil)
        }
        guard keys.count == 1, keyCode(keys[0]) != nil else {
            return (nil, "a remap takes one key and any modifiers, like `opt space`")
        }
        return (KeyRemap(source: source, action: .press(mods, key: keys[0])), nil)
    }
}

/// What a shortcut does when its app is already in front.
enum WhenInFront: String, CaseIterable {
    case minimize, hide, nothing
}

struct Shortcut {
    var key: String
    var app: String  // a path, or an app name for `open -a`
}

struct ParsedConfig {
    var shortcuts: [Shortcut] = []
    var remaps: [KeyRemap] = []
    var whenInFront = WhenInFront.minimize
    var problems: [String] = []
}

/// Finds the .app an entry points to: a path as-is, or a name in the usual folders.
func resolveApp(_ app: String) -> URL? {
    if app.hasPrefix("/") { return URL(fileURLWithPath: app) }
    let file = app.hasSuffix(".app") ? app : app + ".app"
    let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                "/Applications/Utilities", NSHomeDirectory() + "/Applications", "/System/Library/CoreServices"]
    for dir in dirs where FileManager.default.fileExists(atPath: dir + "/" + file) {
        return URL(fileURLWithPath: dir + "/" + file)
    }
    return nil
}

/// The config file as lines, so edits from the settings app keep your comments.
struct ConfigFile {
    var lines: [String]

    init(text: String) {
        lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
    }

    static func load(_ path: String = configPath) -> ConfigFile? {
        (try? String(contentsOfFile: path, encoding: .utf8)).map(ConfigFile.init(text:))
    }

    var text: String { lines.joined(separator: "\n") + "\n" }

    func save(_ path: String = configPath) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Splits `key = value`, or returns nil for blank lines and comments.
    static func split(_ raw: String) -> (name: String, value: String)? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty || line.hasPrefix("#") { return nil }
        guard let eq = line.firstIndex(of: "=") else { return ("", line) }
        var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let q = value.first, q == value.last, q == "'" || q == "\"" {
            value = String(value.dropFirst().dropLast())
        }
        return (line[..<eq].trimmingCharacters(in: .whitespaces).lowercased(), value)
    }

    /// The key a `hyperkey <key>` or `remap <key>` name is about.
    static func remapSource(name: String) -> String? {
        let words = name.split(separator: " ")
        guard words.count == 2, words[0] == "hyperkey" || words[0] == "remap" else { return nil }
        return String(words[1])
    }

    private static func remapSource(line: String) -> String? {
        split(line).flatMap { remapSource(name: $0.name) }
    }

    func parse() -> ParsedConfig {
        var config = ParsedConfig()
        for (i, raw) in lines.enumerated() {
            guard let entry = ConfigFile.split(raw) else { continue }
            let (name, value) = entry
            let problem = { (text: String) in config.problems.append("line \(i + 1): \(text)") }
            if let parsed = KeyRemap.parse(name: name, value: value) {
                if let issue = parsed.problem {
                    problem(issue)
                } else if let remap = parsed.remap, config.remaps.contains(where: { $0.source == remap.source }) {
                    problem("\(keyLabel(remap.source)) is already set up, keeping the first one")
                } else if let remap = parsed.remap {
                    config.remaps.append(remap)
                }
            } else if name == "when-in-front" {
                if let w = WhenInFront(rawValue: value.lowercased()) { config.whenInFront = w }
                else { problem("when-in-front should be minimize, hide or nothing") }
            } else if name.isEmpty {
                problem("expected `key = app`")
            } else if keyCode(name) == nil {
                problem("unknown key \"\(name)\"")
            } else if value.isEmpty {
                problem("no app given for \"\(name)\"")
            } else if config.shortcuts.contains(where: { $0.key == name }) {
                problem("\"\(name)\" is already mapped, keeping the first one")
            } else {
                config.shortcuts.append(Shortcut(key: name, app: (value as NSString).expandingTildeInPath))
            }
        }
        return config
    }

    private func index(of name: String) -> Int? {
        lines.firstIndex { ConfigFile.split($0)?.name == name }
    }

    /// Where a new entry goes when there are none of its kind yet: above the first
    /// entry of any kind, after the header comments.
    private var firstEntry: Int {
        lines.firstIndex { ConfigFile.split($0) != nil } ?? lines.count
    }

    mutating func remove(key: String) {
        lines.removeAll { ConfigFile.split($0)?.name == key }
    }

    /// Adds a shortcut, or replaces the app if the key is already used.
    mutating func set(key: String, app: String) {
        let home = NSHomeDirectory()
        let shown = app.hasPrefix(home + "/") ? "~" + app.dropFirst(home.count) : app
        let line = "\(key) = \(shown)"
        if let i = index(of: key) {
            lines[i] = line
        } else if let last = lines.lastIndex(where: { ConfigFile.split($0).map { keyCode($0.name) != nil } ?? false }) {
            lines.insert(line, at: last + 1)
        } else {
            lines.append(line)
        }
    }

    mutating func remove(remapOf source: String) {
        lines.removeAll { ConfigFile.remapSource(line: $0) == source }
    }

    /// Adds a remapped key, or replaces the one for the same key. Pass `replacing`
    /// when an edit changed which key is remapped.
    mutating func set(remap: KeyRemap, replacing old: String? = nil) {
        if let old, old != remap.source { remove(remapOf: old) }
        if let i = lines.firstIndex(where: { ConfigFile.remapSource(line: $0) == remap.source }) {
            lines[i] = remap.configLine
        } else if let last = lines.lastIndex(where: { ConfigFile.remapSource(line: $0) != nil }) {
            lines.insert(remap.configLine, at: last + 1)
        } else {
            lines.insert(contentsOf: [remap.configLine, ""], at: firstEntry)
        }
    }

    mutating func set(whenInFront: WhenInFront) {
        let line = "when-in-front = \(whenInFront.rawValue)"
        if let i = index(of: "when-in-front") {
            lines[i] = line
        } else {
            lines.insert(contentsOf: [line, ""], at: firstEntry)
        }
    }
}
