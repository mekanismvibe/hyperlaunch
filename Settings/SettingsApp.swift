// Hyperlaunch settings: set up Hyper keys, remapped keys and app shortcuts. It only
// edits the config file, and the background tool picks up changes as soon as it is saved.
// Nothing stays running: closing the window quits the app.
//
// Build:  swiftc -O -swift-version 5 -parse-as-library Shared/Config.swift Settings/SettingsApp.swift -o Hyperlaunch
//
// View state lives in ObservableObjects rather than @State, because @State is a
// macro whose plugin ships only with Xcode, and this builds with the Command Line Tools.

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

let agent = "gui/\(getuid())/local.hyperlaunch"
let agentPlist = NSHomeDirectory() + "/Library/LaunchAgents/local.hyperlaunch.plist"
let logPath = NSHomeDirectory() + "/Library/Logs/hyperlaunch.log"

@main
struct HyperlaunchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Hyperlaunch", id: "main") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@discardableResult
func run(_ tool: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

func recentLog() -> String {
    guard let handle = FileHandle(forReadingAtPath: logPath) else { return "" }
    defer { try? handle.close() }
    let end = (try? handle.seekToEnd()) ?? 0
    try? handle.seek(toOffset: end > 8192 ? end - 8192 : 0)
    return String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
}

struct AppInfo {
    let name: String
    let icon: NSImage
    let found: Bool

    init(_ app: String) {
        if let url = resolveApp(app), FileManager.default.fileExists(atPath: url.path) {
            name = url.deletingPathExtension().lastPathComponent
            icon = NSWorkspace.shared.icon(forFile: url.path)
            found = true
        } else {
            name = ((app as NSString).lastPathComponent as NSString).deletingPathExtension
            icon = NSWorkspace.shared.icon(for: .applicationBundle)
            found = false
        }
    }
}

// MARK: - Model

enum AgentStatus { case running, needsAccess, stopped }

final class Model: ObservableObject {
    struct Row: Identifiable {
        let key: String
        let app: String
        let info: AppInfo
        var id: String { key }
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var remaps: [KeyRemap] = []
    @Published private(set) var whenInFront = WhenInFront.minimize
    @Published private(set) var problems: [String] = []
    @Published private(set) var status = AgentStatus.running
    @Published var saveError: String?
    @Published var adding = false
    @Published var remapEditor: RemapEditor?
    private var file = ConfigFile(text: "")

    init() { reload() }

    func reload() {
        file = ConfigFile.load() ?? ConfigFile(text: "")
        refresh()
        checkStatus()
    }

    private func refresh() {
        let parsed = file.parse()
        rows = parsed.shortcuts.sorted { $0.key < $1.key }
            .map { Row(key: $0.key, app: $0.app, info: AppInfo($0.app)) }
        remaps = parsed.remaps
        whenInFront = parsed.whenInFront
        problems = parsed.problems
    }

    private func edit(_ change: (inout ConfigFile) -> Void) {
        file = ConfigFile.load() ?? file  // pick up hand edits made since the window opened
        change(&file)
        do {
            try file.save()
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
        refresh()
    }

    func remove(_ key: String) { edit { $0.remove(key: key) } }
    func set(key: String, app: String) { edit { $0.set(key: key, app: app) } }
    func setWhenInFront(_ value: WhenInFront) { edit { $0.set(whenInFront: value) } }
    func row(for key: String) -> Row? { rows.first { $0.key == key } }

    func setRemap(_ remap: KeyRemap, replacing old: String?) { edit { $0.set(remap: remap, replacing: old) } }
    func removeRemap(_ source: String) { edit { $0.remove(remapOf: source) } }
    func remap(for source: String) -> KeyRemap? { remaps.first { $0.source == source } }
    var hasHyperKey: Bool { remaps.contains { $0.action == .hold(.hyper) } }

    func checkStatus() {
        guard run("/bin/launchctl", ["print", agent]).contains("state = running") else {
            status = .stopped
            return
        }
        let last = recentLog().split(separator: "\n")
            .last { $0.contains("ready:") || $0.contains("waiting for Accessibility") }
        status = last?.contains("waiting") == true ? .needsAccess : .running
    }

    func start() {
        run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", agentPlist])
        run("/bin/launchctl", ["kickstart", agent])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.checkStatus() }
    }
}

// MARK: - Views

struct ContentView: View {
    @StateObject private var model = Model()
    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                if model.remaps.isEmpty {
                    Text("No keys set up yet.").foregroundStyle(.secondary)
                }
                ForEach(model.remaps, id: \.source) { remap in
                    RemapRow(remap: remap,
                             edit: { model.remapEditor = RemapEditor(existing: remap) },
                             remove: { model.removeRemap(remap.source) })
                }
            } header: {
                Text("Keys")
            } footer: {
                HStack(alignment: .top) {
                    Text(model.hasHyperKey
                         ? "A Hyper key adds ⌃⌥⇧⌘ to every key you press while holding it."
                         : "No key is a full Hyper key (⌃⌥⇧⌘), so app shortcuts only work by holding all four modifiers.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Key…") { model.remapEditor = RemapEditor(existing: nil) }
                }
            }

            Section {
                if model.rows.isEmpty {
                    Text("No shortcuts yet.").foregroundStyle(.secondary)
                }
                ForEach(model.rows) { row in
                    ShortcutRow(row: row) { model.remove(row.key) }
                }
            } header: {
                Text("App Shortcuts (Hyper + key)")
            } footer: {
                HStack {
                    Button("Edit Config File…") { run("/usr/bin/open", ["-t", configPath]) }
                        .buttonStyle(.link)
                    Spacer()
                    Button("Add Shortcut…") { model.adding = true }
                }
            }

            Section {
                Picker("If the app is already in front", selection: Binding(
                    get: { model.whenInFront },
                    set: { model.setWhenInFront($0) }
                )) {
                    Text("Minimize it").tag(WhenInFront.minimize)
                    Text("Hide it").tag(WhenInFront.hide)
                    Text("Leave it open").tag(WhenInFront.nothing)
                }
            } footer: {
                Text(model.whenInFront == .nothing
                     ? "The shortcut always just brings the app forward."
                     : "Press the shortcut again to bring the app back.")
                    .foregroundStyle(.secondary)
            }

            if !model.problems.isEmpty {
                Section("Problems in the config file") {
                    ForEach(model.problems, id: \.self) { Text($0).font(.callout) }
                }
            }

            Section {
                StatusRow(status: model.status, start: model.start)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, idealWidth: 460, minHeight: 420, idealHeight: 640)
        .sheet(isPresented: $model.adding) { AddShortcutSheet(model: model) }
        .sheet(item: $model.remapEditor) { editor in RemapSheet(model: model, existing: editor.existing) }
        .alert("Couldn't save the config file", isPresented: Binding(
            get: { model.saveError != nil },
            set: { if !$0 { model.saveError = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(model.saveError ?? "")
        }
        .onReceive(timer) { _ in model.checkStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.reload()
        }
    }
}

/// A key drawn like a keycap; ✦ marks Hyper + key.
struct KeyCap: View {
    let key: String
    var hyper = true

    var body: some View {
        HStack(spacing: 4) {
            if hyper { Text("✦").foregroundStyle(.secondary) }
            Text(keyLabel(key)).fontWeight(.semibold)
        }
        .font(.system(.body, design: .rounded))
        .padding(.horizontal, 6)
        .frame(minWidth: 56)
        .padding(.vertical, 3)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}

struct ShortcutRow: View {
    let row: Model.Row
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            KeyCap(key: row.key)
            Image(nsImage: row.info.icon)
                .resizable()
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.info.name)
                if !row.info.found {
                    Text("App not found").font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            Button(action: remove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove this shortcut")
        }
    }
}

struct StatusRow: View {
    let status: AgentStatus
    let start: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(status == .running ? .green : status == .needsAccess ? .orange : .red)
                .frame(width: 8, height: 8)
            switch status {
            case .running:
                Text("Hyperlaunch is running")
                Spacer()
            case .needsAccess:
                Text("Needs Accessibility access")
                Spacer()
                Button("Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            case .stopped:
                Text("Hyperlaunch isn't running")
                Spacer()
                Button("Start", action: start)
            }
        }
    }
}

/// The shortcut being set up in the Add sheet, including listening for its key.
final class Draft: ObservableObject {
    @Published var app: String?
    @Published var key: String?
    @Published private(set) var listening = false
    private var monitor: Any?

    func listen(_ on: Bool) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        listening = on
        guard on else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Escape (or a key hyperlaunch can't use) just stops listening.
            if let name = keyNames[Int64(event.keyCode)], name != "escape" { self?.key = name }
            self?.listen(false)
            return nil
        }
    }
}

struct AddShortcutSheet: View {
    @ObservedObject var model: Model
    @StateObject private var draft = Draft()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Shortcut").font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("App").gridColumnAlignment(.trailing)
                    Button(action: chooseApp) {
                        if let app = draft.app {
                            let info = AppInfo(app)
                            Label {
                                Text(info.name)
                            } icon: {
                                Image(nsImage: info.icon).resizable().frame(width: 16, height: 16)
                            }
                        } else {
                            Text("Choose…")
                        }
                    }
                }
                GridRow {
                    Text("Key")
                    VStack(alignment: .leading, spacing: 4) {
                        Button { draft.listen(!draft.listening) } label: {
                            Text(draft.listening ? "Press a key…" : draft.key.map { "✦ \(keyLabel($0))" } ?? "Click to set")
                                .frame(minWidth: 110)
                        }
                        Text("Just press the key. No need to hold your Hyper key.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let key = draft.key, let existing = model.row(for: key), existing.app != draft.app {
                Text("✦ \(keyLabel(key)) opens \(existing.info.name) right now. Adding this replaces it.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    if let key = draft.key, let app = draft.app { model.set(key: key, app: app) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.app == nil || draft.key == nil)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onDisappear { draft.listen(false) }
    }

    private func chooseApp() {
        draft.listen(false)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            draft.app = url.path
            if draft.key == nil { draft.listen(true) }  // straight on to picking the key
        }
    }
}

// MARK: - Keys (Hyper keys and remapped keys)

struct RemapRow: View {
    let remap: KeyRemap
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            KeyCap(key: remap.source, hyper: false)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            Text(remap.summary)
            Spacer()
            Button(action: edit) { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Change this key")
            Button(action: remove) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Stop remapping this key")
        }
    }
}

struct RemapEditor: Identifiable {
    let id = UUID()
    let existing: KeyRemap?
}

extension Mods {
    init(_ flags: NSEvent.ModifierFlags) {
        self.init()
        if flags.contains(.control) { insert(.ctrl) }
        if flags.contains(.option) { insert(.opt) }
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.command) { insert(.cmd) }
    }
}

/// The key being set up in the Keys sheet, including listening for key presses.
final class RemapDraft: ObservableObject {
    enum Listening { case source, shortcut }

    @Published var source: String?
    @Published var isHyper = true
    @Published var holdMods = Mods.hyper
    @Published var pressMods = Mods()
    @Published var pressKey: String?
    @Published private(set) var listening: Listening?
    private var monitor: Any?

    init(_ existing: KeyRemap?) {
        guard let existing else { return }
        source = existing.source
        switch existing.action {
        case .hold(let mods):
            holdMods = mods
        case .press(let mods, let key):
            isHyper = false
            pressMods = mods
            pressKey = key
        }
    }

    var remap: KeyRemap? {
        guard let source else { return nil }
        if isHyper { return holdMods.isEmpty ? nil : KeyRemap(source: source, action: .hold(holdMods)) }
        return pressKey.map { KeyRemap(source: source, action: .press(pressMods, key: $0)) }
    }

    func listen(_ what: Listening?) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        listening = what
        guard let what else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = Int64(event.keyCode)
            switch what {
            case .source:
                if code != 0x35 { self?.source = keyName(code) }  // Escape just stops listening
            case .shortcut:
                self?.pressKey = keyName(code)
                self?.pressMods = Mods(event.modifierFlags)
            }
            self?.listen(nil)
            return nil
        }
    }
}

struct RemapSheet: View {
    @ObservedObject var model: Model
    let existing: KeyRemap?
    @StateObject private var draft: RemapDraft
    @Environment(\.dismiss) private var dismiss

    // Keys that can't be picked by pressing them: Caps Lock doesn't send a key
    // press, and macOS may grab the top-row keys before the app sees them.
    private let specialKeys = ["capslock", "mic", "spotlight", "dnd"]
    private let typingKeys: Set<String> = ["space", "return", "tab", "delete"]

    /// Keys a shortcut can press, in menu order (plus the current one if it's unusual).
    private var pickableKeys: [String] {
        let keys = "abcdefghijklmnopqrstuvwxyz0123456789".map(String.init)
            + ["space", "return", "tab", "escape", "delete", "left", "right", "up", "down"]
            + (1...12).map { "f\($0)" }
            + ["-", "equal", "[", "]", ";", "'", ",", ".", "/", "\\", "`"]
        guard let current = draft.pressKey, !keys.contains(current) else { return keys }
        return keys + [current]
    }

    init(model: Model, existing: KeyRemap?) {
        self.model = model
        self.existing = existing
        _draft = StateObject(wrappedValue: RemapDraft(existing))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "New Key" : "Change Key").font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("Key").gridColumnAlignment(.trailing)
                    HStack {
                        Button { draft.listen(draft.listening == .source ? nil : .source) } label: {
                            Text(draft.listening == .source ? "Press a key…" : draft.source.map(keyLabel) ?? "Click, then press it")
                                .frame(minWidth: 130)
                        }
                        Menu("Special Keys") {
                            ForEach(specialKeys, id: \.self) { name in
                                Button(keyLabel(name)) {
                                    draft.listen(nil)
                                    draft.source = name
                                }
                            }
                        }
                        .fixedSize()
                    }
                }
                GridRow {
                    Text("Makes it")
                    Picker("", selection: $draft.isHyper) {
                        Text("A Hyper key").tag(true)
                        Text("A shortcut").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if draft.isHyper {
                    GridRow {
                        Text("Holds")
                        ModToggles(draft: draft, mods: \.holdMods)
                    }
                } else {
                    GridRow {
                        Text("Presses")
                        HStack(spacing: 6) {
                            ModToggles(draft: draft, mods: \.pressMods)
                            Picker("", selection: $draft.pressKey) {
                                Text("Key…").tag(String?.none)
                                ForEach(pickableKeys, id: \.self) { Text(keyLabel($0)).tag(Optional($0)) }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                    GridRow {
                        Text("")
                        Button(draft.listening == .shortcut ? "Press the shortcut…" : "Record by Pressing It") {
                            draft.listen(draft.listening == .shortcut ? nil : .shortcut)
                        }
                    }
                }
            }

            Text(draft.isHyper
                 ? "Hold it and press another key, and that key gets these modifiers. With all four (⌃⌥⇧⌘) it's a full Hyper key and opens your app shortcuts."
                 : "Pressing it presses this shortcut instead, and holding it holds the shortcut. A shortcut another app already uses, like ⌥Space, goes to that app when you press it, so pick its modifiers and key above instead of recording it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let source = draft.source {
                if let other = model.remap(for: source), other.source != existing?.source {
                    Text("\(keyLabel(source)) is already set up (\(other.summary)). Saving replaces it.")
                        .font(.callout).foregroundStyle(.orange)
                }
                if source.count == 1 || typingKeys.contains(source) {
                    Text("You won't be able to type \(keyLabel(source)) any more.")
                        .font(.callout).foregroundStyle(.orange)
                }
            }

            HStack {
                if let existing {
                    Button("Remove", role: .destructive) {
                        model.removeRemap(existing.source)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if let remap = draft.remap { model.setRemap(remap, replacing: existing?.source) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.remap == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { if existing == nil { draft.listen(.source) } }
        .onDisappear { draft.listen(nil) }
    }
}

/// ⌃ ⌥ ⇧ ⌘ as toggle buttons for one of the draft's sets of modifiers.
struct ModToggles: View {
    @ObservedObject var draft: RemapDraft
    let mods: ReferenceWritableKeyPath<RemapDraft, Mods>

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Mods.each, id: \.name) { each in
                Toggle(each.symbol, isOn: Binding(
                    get: { draft[keyPath: mods].contains(each.mod) },
                    set: { on in
                        if on { draft[keyPath: mods].insert(each.mod) } else { draft[keyPath: mods].remove(each.mod) }
                    }
                ))
                .toggleStyle(.button)
            }
        }
    }
}
