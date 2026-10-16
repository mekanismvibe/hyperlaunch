// The config file format, shared by the background tool and the settings app.
//
//   when-in-front = minimize        (or hide, or nothing)
//   m = /Applications/Feishin.app   (key = app, one per line; # starts a comment)

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
]
let keyNames = Dictionary(keyCodes.map { ($1, $0) }, uniquingKeysWith: { a, _ in a })

/// How a key name is shown to people: "M", "Space", "F5", "←", "=".
func keyLabel(_ name: String) -> String {
    switch name {
    case "equal": return "="
    case "left": return "←"
    case "right": return "→"
    case "up": return "↑"
    case "down": return "↓"
    case "return", "tab", "space", "delete", "escape": return name.capitalized
    default: return name.uppercased()
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

    func parse() -> (shortcuts: [Shortcut], whenInFront: WhenInFront, problems: [String]) {
        var shortcuts: [Shortcut] = []
        var whenInFront = WhenInFront.minimize
        var problems: [String] = []
        for (i, raw) in lines.enumerated() {
            guard let entry = ConfigFile.split(raw) else { continue }
            let (name, value) = entry
            if name == "when-in-front" {
                if let w = WhenInFront(rawValue: value.lowercased()) { whenInFront = w }
                else { problems.append("line \(i + 1): when-in-front should be minimize, hide or nothing") }
            } else if name.isEmpty {
                problems.append("line \(i + 1): expected `key = app`")
            } else if keyCodes[name] == nil {
                problems.append("line \(i + 1): unknown key \"\(name)\"")
            } else if value.isEmpty {
                problems.append("line \(i + 1): no app given for \"\(name)\"")
            } else if shortcuts.contains(where: { $0.key == name }) {
                problems.append("line \(i + 1): \"\(name)\" is already mapped, keeping the first one")
            } else {
                shortcuts.append(Shortcut(key: name, app: (value as NSString).expandingTildeInPath))
            }
        }
        return (shortcuts, whenInFront, problems)
    }

    private func index(of name: String) -> Int? {
        lines.firstIndex { ConfigFile.split($0)?.name == name }
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
        } else if let last = lines.lastIndex(where: { ConfigFile.split($0).map { keyCodes[$0.name] != nil } ?? false }) {
            lines.insert(line, at: last + 1)
        } else {
            lines.append(line)
        }
    }

    mutating func set(whenInFront: WhenInFront) {
        let line = "when-in-front = \(whenInFront.rawValue)"
        if let i = index(of: "when-in-front") {
            lines[i] = line
        } else {
            // Put it above the first shortcut, after the header comments.
            let first = lines.firstIndex { ConfigFile.split($0) != nil } ?? lines.count
            lines.insert(contentsOf: [line, ""], at: first)
        }
    }
}
