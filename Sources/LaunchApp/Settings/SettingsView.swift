// Settings/SettingsView.swift
// The Settings window: General, Appearance, Activation, Apps, About & Updates.

import AppKit
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, activation, apps, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .activation: return "Activation"
        case .apps: return "Apps & Layout"
        case .about: return "About & Updates"
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .activation: return "hand.tap"
        case .apps: return "square.grid.3x3"
        case .about: return "info.circle"
        }
    }
}

final class SettingsState: ObservableObject {
    static let shared = SettingsState()
    @Published var pane: SettingsPane = .general
}

struct SettingsView: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject var prefs: Preferences
    weak var delegate: AppDelegate?
    @ObservedObject private var state = SettingsState.shared

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: Binding(get: { state.pane }, set: { if let p = $0 { state.pane = p } })) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            Form {
                switch state.pane {
                case .general: GeneralPane(prefs: prefs)
                case .appearance: AppearancePane(prefs: prefs)
                case .activation: ActivationPane(prefs: prefs, delegate: delegate)
                case .apps: AppsPane(model: model, prefs: prefs)
                case .about: AboutPane(prefs: prefs)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(state.pane.title)
        }
        .frame(minWidth: 680, minHeight: 500)
    }
}

// MARK: - General

struct GeneralPane: View {
    @ObservedObject var prefs: Preferences
    @State private var loginItem = LaunchAtLogin.isEnabled
    @State private var loginError: String?

    var body: some View {
        Section {
            Toggle("Open at login", isOn: Binding(get: { loginItem }, set: { on in
                loginError = LaunchAtLogin.set(on)
                loginItem = LaunchAtLogin.isEnabled
            }))
            if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            Toggle("Show in Dock", isOn: $prefs.settings.showInDock)
            Toggle("Show in App Switcher (⌘Tab)", isOn: $prefs.settings.showInAppSwitcher)
            Toggle("Show apps in the Dock icon's menu", isOn: $prefs.settings.showAppsInDockMenu)
                .disabled(!prefs.settings.showInDock || !prefs.settings.showInAppSwitcher)
            Toggle("Show menu bar icon", isOn: $prefs.settings.showMenuBarIcon)
        } footer: {
            Text("Click LaunchApp in the Dock to open or close it, like Launchpad. The app list in the Dock icon's menu needs App Switcher on (macOS only asks apps in ⌘Tab for a Dock menu).")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            Toggle("Close after opening an app", isOn: $prefs.settings.closeAfterLaunch)
            Toggle("Remove leftover files when uninstalling", isOn: $prefs.settings.removeLeftoversOnUninstall)
        }
        Section("Tips") {
            tip("Type to search; ↩ opens the highlighted app, arrow keys move around.")
            tip("Drag an app onto another to make a folder. Drag to a screen edge to change pages.")
            tip("Hold ⌥ or long-press an icon to edit; ⌘-click to select several apps.")
            tip("Drag an app down onto the Dock to keep it there.")
        }
    }

    private func tip(_ s: String) -> some View {
        Text(s).font(.callout).foregroundStyle(.secondary)
    }
}

// MARK: - Appearance

struct AppearancePane: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        Section("Layout") {
            Picker("Mode", selection: $prefs.settings.displayMode) {
                ForEach(DisplayMode.allCases) { Text($0.title).tag($0) }
            }
            if prefs.settings.displayMode == .window {
                slider("Window size", value: $prefs.settings.windowScale, range: 0.45...0.95, format: { "\(Int($0 * 100))%" })
            }
            Picker("Scrolling", selection: $prefs.settings.scrollMode) {
                ForEach(ScrollMode.allCases) { Text($0.title).tag($0) }
            }
            if prefs.settings.scrollMode == .paged {
                Picker("Page transition", selection: $prefs.settings.pageTransition) {
                    ForEach(PageTransition.allCases) { Text($0.title).tag($0) }
                }
            }
            Picker("Preset", selection: Binding<LayoutPreset?>(
                get: { LayoutPreset.matching(prefs.settings) },
                set: { if let p = $0 { p.apply(to: &prefs.settings) } })) {
                ForEach(LayoutPreset.allCases) { Text($0.title).tag(Optional($0)) }
                if LayoutPreset.matching(prefs.settings) == nil { Text("Custom").tag(LayoutPreset?.none) }
            }
            Stepper("Columns: \(prefs.settings.columns)", value: $prefs.settings.columns, in: 3...12)
            Stepper("Rows: \(prefs.settings.rows)", value: $prefs.settings.rows, in: 2...9)
            Stepper("Folder columns: \(prefs.settings.folderColumns)", value: $prefs.settings.folderColumns, in: 3...9)
            Stepper("Folder rows: \(prefs.settings.folderRows)", value: $prefs.settings.folderRows, in: 1...6)
        }
        Section("Icons") {
            slider("Icon size", value: $prefs.settings.iconScale, range: 0.5...1.6, format: { "\(Int($0 * 100))%" })
            Text("In the launcher: ⌘+ / ⌘− change the icon size, ⌘0 resets it.").font(.callout).foregroundStyle(.secondary)
            Toggle("Show names", isOn: $prefs.settings.showLabels)
            if prefs.settings.showLabels {
                slider("Name size", value: $prefs.settings.labelSize, range: 10...18, format: { "\(Int($0)) pt" })
            }
            Toggle("Show page dots", isOn: $prefs.settings.showPageDots)
            Toggle("Liquid Glass folders", isOn: $prefs.settings.liquidGlass)
            if prefs.settings.liquidGlass {
                Picker("Glass", selection: $prefs.settings.glassFollowsSystem) {
                    Text("Same as System").tag(true)
                    Text("Custom").tag(false)
                }
                if !prefs.settings.glassFollowsSystem {
                    LabeledContent("Transparency") {
                        HStack {
                            Text("Clear").font(.caption).foregroundStyle(.secondary)
                            Slider(value: $prefs.settings.glassTint, in: 0...1)
                            Text("Tinted").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("Follows System Settings → Appearance → Liquid Glass (Clear ↔ Tinted).")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        Section("Background") {
            Picker("Style", selection: $prefs.settings.background) {
                ForEach(BackgroundStyle.allCases) { Text($0.title).tag($0) }
            }
            slider("Dimming", value: $prefs.settings.backgroundDim, range: 0...0.7, format: { "\(Int($0 * 100))%" })
            slider("Animation speed", value: $prefs.settings.animationSpeed, range: 0.5...2, format: { String(format: "%.1f×", $0) })
        }
        Section {
            Button("Restore Defaults") {
                var s = prefs.settings
                let d = Settings()
                s.columns = d.columns; s.rows = d.rows; s.iconScale = d.iconScale; s.labelSize = d.labelSize
                s.showLabels = d.showLabels; s.background = d.background; s.backgroundDim = d.backgroundDim
                s.scrollMode = d.scrollMode; s.displayMode = d.displayMode; s.windowScale = d.windowScale
                s.animationSpeed = d.animationSpeed; s.showPageDots = d.showPageDots
                s.folderColumns = d.folderColumns; s.folderRows = d.folderRows
                s.liquidGlass = d.liquidGlass; s.pageTransition = d.pageTransition
                s.glassFollowsSystem = d.glassFollowsSystem; s.glassTint = d.glassTint
                prefs.settings = s
            }
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: @escaping (Double) -> String) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range)
                Text(format(value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary).frame(width: 54, alignment: .trailing)
            }
        }
    }
}

// MARK: - Activation

struct ActivationPane: View {
    @ObservedObject var prefs: Preferences
    weak var delegate: AppDelegate?
    @State private var trusted = LaunchpadKeyTap.hasPermission
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Section("Keyboard") {
            Toggle("Global shortcut", isOn: $prefs.settings.hotKeyEnabled)
            if prefs.settings.hotKeyEnabled {
                LabeledContent("Shortcut") {
                    ShortcutRecorder(combo: $prefs.settings.hotKey)
                }
            }
            Toggle("Launchpad key (F4)", isOn: $prefs.settings.launchpadKeyEnabled)
            if prefs.settings.launchpadKeyEnabled && !trusted {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Needs Accessibility access to catch the key.").font(.callout)
                    Spacer()
                    Button("Grant Access…") { LaunchpadKeyTap.requestPermission() }
                }
            }
        }
        Section {
            Toggle("Pinch with thumb and three fingers", isOn: $prefs.settings.trackpadPinchEnabled)
        } header: {
            Text("Trackpad")
        } footer: {
            Text("Pinch in to open, spread out to close. If macOS also reacts to this gesture, turn off “Show Apps”/Launchpad under System Settings → Trackpad → More Gestures.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Hot corner") {
            Picker("Corner", selection: $prefs.settings.hotCorner) {
                ForEach(HotCorner.allCases) { Text($0.title).tag($0) }
            }
            if prefs.settings.hotCorner != .none {
                LabeledContent("Delay") {
                    HStack {
                        Slider(value: $prefs.settings.hotCornerDelay, in: 0...1)
                        Text(String(format: "%.2f s", prefs.settings.hotCornerDelay)).monospacedDigit()
                            .foregroundStyle(.secondary).frame(width: 54, alignment: .trailing)
                    }
                }
            }
        }
        .onReceive(timer) { _ in
            let now = LaunchpadKeyTap.hasPermission
            if now != trusted {
                trusted = now
                delegate?.retryKeyTap()
            }
        }
    }
}

struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Type a shortcut…" : (combo?.display ?? "None"))
                    .frame(minWidth: 120)
            }
            if recording { Button("Cancel") { stop() } }
        }
    }

    private func start() {
        recording = true
        GlobalHotKey.shared.paused = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            guard let key = KeyCodes.name(for: CGKeyCode(e.keyCode)) else { return nil }
            let isFunctionKey = key.hasPrefix("F") && key.count > 1
            guard !mods.isEmpty || isFunctionKey else { NSSound.beep(); return nil }
            combo = KeyCombo(key: key, modifiers: mods.rawValue)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        GlobalHotKey.shared.paused = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - Apps

struct AppsPane: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject var prefs: Preferences
    @State private var confirmReset = false

    var body: some View {
        Section("Layout") {
            HStack {
                Button("Import Launchpad Layout") { model.importLaunchpadLayout() }
                    .disabled(!LaunchpadImporter.isAvailable)
                Button("Sort by Name") { model.sortAlphabetically() }
                Spacer()
                Button("Reset Layout…", role: .destructive) { confirmReset = true }
            }
            if !LaunchpadImporter.isAvailable {
                Text("No classic Launchpad database was found on this Mac.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Reset the layout?", isPresented: $confirmReset) {
            Button("Reset Layout", role: .destructive) { model.resetLayout() }
        } message: {
            Text("Folders are removed and apps are put back in alphabetical order.")
        }

        Section("App folders") {
            ForEach(AppSources.defaults, id: \.self) { path in
                Label(path, systemImage: "lock").foregroundStyle(.secondary)
            }
            ForEach(prefs.settings.extraSources, id: \.self) { path in
                HStack {
                    Label(path, systemImage: "folder")
                    Spacer()
                    Button { prefs.settings.extraSources.removeAll { $0 == path } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            Button("Add Folder…") { addSource() }
        }

        Section("Hidden apps (\(prefs.settings.hiddenApps.count))") {
            if prefs.settings.hiddenApps.isEmpty {
                Text("Right-click an app in LaunchApp and choose Hide.").foregroundStyle(.secondary)
            }
            ForEach(prefs.settings.hiddenApps, id: \.self) { id in
                HStack {
                    appIcon(id)
                    Text(model.name(of: id))
                    Spacer()
                    Button("Show") { model.unhide(id) }
                }
            }
        }

        Section("Renamed apps") {
            if prefs.settings.renamedApps.isEmpty {
                Text("Right-click an app and choose Rename… to give it your own name.").foregroundStyle(.secondary)
            }
            ForEach(prefs.settings.renamedApps.keys.sorted(), id: \.self) { id in
                HStack {
                    appIcon(id)
                    Text(prefs.settings.renamedApps[id] ?? "")
                    Text("(\(model.apps[id]?.name ?? id))").foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset") { model.rename(id, to: nil) }
                }
            }
        }
    }

    @ViewBuilder private func appIcon(_ id: AppID) -> some View {
        if let app = model.apps[id] {
            Image(nsImage: IconCache.shared.icon(for: app.url, points: 20)).resizable().frame(width: 20, height: 20)
        } else {
            Image(systemName: "app.dashed").frame(width: 20, height: 20)
        }
    }

    private func addSource() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !prefs.settings.extraSources.contains(url.path) {
            prefs.settings.extraSources.append(url.path)
        }
    }
}

// MARK: - About

struct AboutPane: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject private var updater = UpdateManager.shared

    var body: some View {
        Section {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("LaunchApp").font(.title2.bold())
                    Text("Version \(updater.currentVersion)").foregroundStyle(.secondary)
                    Text("The classic Launchpad, back on macOS 26+.").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
        }
        Section("Updates") {
            HStack {
                status
                Spacer()
                switch updater.state {
                case .available:
                    Button("Install Update") { updater.install() }.buttonStyle(.borderedProminent)
                case .checking, .downloading, .installing:
                    ProgressView().controlSize(.small)
                default:
                    Button("Check Now") { updater.check(userInitiated: true) }
                }
            }
            if case .available = updater.state, !updater.releaseNotes.isEmpty {
                ScrollView { Text(updater.releaseNotes).font(.callout).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 140)
            }
            Toggle("Check for updates automatically", isOn: $prefs.settings.autoCheckUpdates)
            Toggle("Install updates automatically", isOn: $prefs.settings.autoInstallUpdates)
                .disabled(!prefs.settings.autoCheckUpdates)
        }
        Section {
            Link("GitHub — vuhpquang/launch-app", destination: URL(string: "https://github.com/\(UpdateManager.repo)")!)
            Link("Release notes", destination: URL(string: "https://github.com/\(UpdateManager.repo)/releases")!)
        }
    }

    @ViewBuilder private var status: some View {
        switch updater.state {
        case .idle: Text("Not checked yet").foregroundStyle(.secondary)
        case .checking: Text("Checking…")
        case .upToDate: Label("LaunchApp is up to date", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .available(let v): Label("Version \(v) is available", systemImage: "arrow.down.circle.fill").foregroundStyle(.blue)
        case .downloading: Text("Downloading…")
        case .installing: Text("Installing…")
        case .failed(let msg): Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}
