// App/AppDelegate.swift
// Wires everything together: the launcher window, the ways to open it (Dock icon, menu bar
// icon, hotkey, Launchpad key, trackpad pinch, hot corner), the Dock menu, the Settings
// window and updates.

import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let prefs = Preferences.shared
    private(set) var model: LauncherModel!
    private(set) var launcher: LauncherWindowController!
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var appWatcher: FolderWatcher!
    private let hotCorner = HotCornerMonitor()
    private let keyTap = LaunchpadKeyTap()
    private let pinch = TrackpadPinch()
    private var cancellables = Set<AnyCancellable>()
    private var launchedAt = Date()
    private var control: ControlServer?
    #if DEBUG
    private var bench: Bench?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = LauncherModel(prefs: prefs)
        launcher = LauncherWindowController(model: model, prefs: prefs)
        launcher.onOpenSettings = { [weak self] in self?.showSettings() }
        installMainMenu()

        appWatcher = FolderWatcher { [weak self] in
            IconCache.shared.invalidate()
            self?.model.refreshApps()
        }
        model.refreshApps()
        appWatcher.watch(prefs.appSources)

        hotCorner.onTrigger = { [weak self] in self?.launcher.toggle() }
        keyTap.onTrigger = { [weak self] in self?.launcher.toggle() }
        pinch.onPinchIn = { [weak self] in
            guard let self, !self.launcher.isVisible else { return }
            self.launcher.show()
        }
        pinch.onSpread = { [weak self] in
            guard let self, self.launcher.isVisible else { return }
            self.launcher.dismissLauncher(launching: false)
        }

        prefs.$settings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s in self?.apply(s) }
            .store(in: &cancellables)

        // A display added/removed or resized closes the launcher. Only real frame changes count:
        // hiding the menu bar while the launcher shows also posts this (visibleFrame changes).
        var screenFrames = NSScreen.screens.map(\.frame)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            let frames = NSScreen.screens.map(\.frame)
            defer { screenFrames = frames }
            guard let self, self.launcher.isVisible, frames != screenFrames else { return }
            self.launcher.dismissLauncher(launching: true)
        }

        UpdateManager.shared.startAutomaticChecks()

        // Control socket for the MCP server (`LaunchApp mcp`).
        control = ControlServer { [weak self] cmd, args in
            guard let self else { throw ControlError("shutting down") }
            switch cmd {
            case "show_launcher":
                if !self.launcher.isVisible { self.launcher.show() }
                return ["visible": true]
            case "hide_launcher":
                self.launcher.dismissLauncher(launching: false)
                return ["visible": false]
            case "status":
                var s = try self.model.control(cmd, args) as? [String: Any] ?? [:]
                s["launcherVisible"] = self.launcher.isVisible
                return s
            default:
                return try self.model.control(cmd, args)
            }
        }
        #if DEBUG
        let benching = ProcessInfo.processInfo.environment["LAUNCHAPP_BENCH"] != nil
        #else
        let benching = false
        #endif
        // A bench run must not take over the installed app's control socket.
        if benching { control = nil } else { control?.start() }

        #if DEBUG
        if benching {
            bench = Bench(model: model, launcher: launcher)
            bench?.run()
            return
        }
        // LAUNCHAPP_DEBUG="search:saf" | "folder" | "edit" | "settings:<pane>" — puts the UI in a
        // state for screenshots (`screencapture`) without clicking.
        let env = ProcessInfo.processInfo.environment
        if let state = env["LAUNCHAPP_DEBUG"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { self.debugState(state) }
        }
        // LAUNCHAPP_SNAPSHOT=/path.png — renders the launcher offscreen (works with the screen
        // locked; glass effects don't render there) and quits.
        if let out = env["LAUNCHAPP_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                let renderer = ImageRenderer(content: LauncherView(model: self.model, prefs: self.prefs))
                renderer.scale = 1
                if let cg = renderer.cgImage {
                    let rep = NSBitmapImageRep(cgImage: cg)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                    print("[LaunchApp] snapshot \(out)")
                }
                if env["LAUNCHAPP_SNAPSHOT_KEEP"] == nil { NSApp.terminate(nil) }
            }
        }
        #endif

        // Opened by hand (not at login): show the launcher right away, like clicking Launchpad.
        if !isLaunchedAtLogin, !CommandLine.arguments.contains("--background") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.launcher.show() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.saveNow()
        control?.stop()
    }

    private var isLaunchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    private var lastSettings: Settings?

    private func apply(_ s: Settings) {
        let old = lastSettings
        lastSettings = s

        let policy = prefs.activationPolicy
        if NSApp.activationPolicy() != policy, settingsWindow?.isVisible != true { NSApp.setActivationPolicy(policy) }
        if old?.showInDock != s.showInDock { syncDockTile(show: s.showInDock, firstApply: old == nil) }

        if s.showMenuBarIcon { installStatusItem() } else { removeStatusItem() }

        if old?.hotKeyEnabled != s.hotKeyEnabled || old?.hotKey != s.hotKey {
            if s.hotKeyEnabled, let combo = s.hotKey {
                GlobalHotKey.shared.register(combo) { [weak self] in self?.launcher.toggle() }
            } else {
                GlobalHotKey.shared.unregister()
            }
        }

        hotCorner.update(corner: s.hotCorner, delay: s.hotCornerDelay)

        if s.launchpadKeyEnabled { keyTap.start() } else { keyTap.stop() }

        if s.trackpadPinchEnabled != (old?.trackpadPinchEnabled ?? false) || old == nil {
            if s.trackpadPinchEnabled { pinch.start() } else { pinch.stop() }
        }

        if old?.extraSources != s.extraSources {
            appWatcher?.watch(prefs.appSources)
            if old != nil { model.refreshApps() }
        }
        if old != nil, old?.iconScale != s.iconScale || old?.columns != s.columns || old?.rows != s.rows {
            IconCache.shared.preload(model.apps.values.map(\.url), points: model.metrics.iconSize)
        }
    }

    /// Retries the event tap after the user grants Accessibility.
    func retryKeyTap() {
        if prefs.settings.launchpadKeyEnabled { keyTap.start() }
    }

    // MARK: - Dock icon

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Clicking the Dock icon toggles the launcher, like Launchpad's.
        if Date().timeIntervalSince(launchedAt) > 1 { launcher.toggle() }
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard prefs.settings.showAppsInDockMenu else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, page) in model.layout.pages.enumerated() {
            let pageItem = NSMenuItem(title: "Page \(index + 1)", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for item in page {
                switch item {
                case .app(let id):
                    if let entry = dockMenuItem(id) { sub.addItem(entry) }
                case .folder(let f):
                    let folderItem = NSMenuItem(title: f.name, action: nil, keyEquivalent: "")
                    folderItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                    let folderMenu = NSMenu()
                    f.apps.compactMap(dockMenuItem).forEach(folderMenu.addItem)
                    folderItem.submenu = folderMenu
                    sub.addItem(folderItem)
                }
            }
            pageItem.submenu = sub
            menu.addItem(pageItem)
        }
        return menu
    }

    private func dockMenuItem(_ id: AppID) -> NSMenuItem? {
        guard let app = model.apps[id] else { return nil }
        let item = NSMenuItem(title: model.name(of: id), action: #selector(openFromMenu(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = id
        let icon = IconCache.shared.icon(for: app.url, points: 16).copy() as? NSImage
        icon?.size = NSSize(width: 16, height: 16)
        item.image = icon
        return item
    }

    @objc private func openFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? AppID, let app = model.apps[id] else { return }
        AppActions.open(app)
    }

    // MARK: - Menu bar icon

    private func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: "LaunchApp")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    private func removeStatusItem() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            let menu = NSMenu.build([
                MenuEntry(title: "Open LaunchApp", symbol: "square.grid.3x3") { [weak self] in self?.launcher.show() },
                MenuEntry(title: "Settings…", symbol: "gearshape") { [weak self] in self?.showSettings() },
                MenuEntry(title: "Check for Updates…", symbol: "arrow.down.circle") { [weak self] in
                    self?.showSettings(pane: .about)
                    UpdateManager.shared.check(userInitiated: true)
                },
                .separator,
                MenuEntry(title: "Quit LaunchApp", symbol: nil) { NSApp.terminate(nil) },
            ])
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
        } else {
            launcher.toggle()
        }
    }

    // MARK: - Settings window

    func showSettings(pane: SettingsPane = .general) {
        if launcher.isVisible { launcher.dismissLauncher(launching: true) }
        SettingsState.shared.pane = pane
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "LaunchApp Settings"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(model: model, prefs: prefs, delegate: self))
            w.center()
            settingsWindow = w
        }
        // Stays a background (UI element) app even with Settings open, unless the user
        // chose to be in ⌘Tab.
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsClosed),
                                               name: NSWindow.willCloseNotification, object: settingsWindow)
    }

    @objc private func settingsClosed() {
        let policy = prefs.activationPolicy
        if policy != .regular { DispatchQueue.main.async { NSApp.setActivationPolicy(policy) } }
    }

    /// Outside ⌘Tab the app has no Dock icon of its own while running, so "Show in Dock" keeps
    /// a pinned tile instead (clicking it sends a reopen, which toggles the launcher).
    private func syncDockTile(show: Bool, firstApply: Bool) {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app", url.path.hasPrefix("/Applications/") else { return }
        let me = AppInfo(id: "com.vuhpquang.launchapp", url: url, name: "LaunchApp",
                         bundleID: Bundle.main.bundleIdentifier, isSystem: false, isUtility: false)
        let inDock = AppActions.isInDock(me)
        if show, !inDock {
            AppActions.addToDock(me)
        } else if !show, inDock, !firstApply {
            AppActions.removeFromDock(me)
        }
    }

    // MARK: - Main menu

    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About LaunchApp", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkUpdates), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide LaunchApp", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit LaunchApp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    #if DEBUG
    private func debugState(_ state: String) {
        let parts = state.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts[0] {
        case "search": model.query = parts.count > 1 ? parts[1] : ""
        case "folder":
            if let f = model.layout.pages[model.page].first(where: \.isFolder) { model.openFolder(f.id) }
        case "edit": model.editing = true
        case "drag":   // a folder held over the grid, for checking the glass while dragging
            let items = model.layout.pages[0]
            if let i = items.firstIndex(where: \.isFolder) {
                let c = model.metrics.iconCenter(slot: min(items.count - 1, i + 9))
                model.mouseDown(at: model.metrics.iconCenter(slot: i), modifiers: [], clickCount: 1)
                model.mouseDragged(to: CGPoint(x: model.metrics.iconCenter(slot: i).x + 30, y: model.metrics.iconCenter(slot: i).y))
                model.mouseDragged(to: CGPoint(x: c.x + 40, y: c.y + 25))
            }
        case "page": model.goToPage(Int(parts.count > 1 ? parts[1] : "1") ?? 1)
        case "settings": showSettings(pane: SettingsPane(rawValue: parts.count > 1 ? parts[1] : "general") ?? .general)
        default: break
        }
    }
    #endif

    @objc private func showAbout() { showSettings(pane: .about) }
    @objc private func openSettingsAction() { showSettings() }
    @objc private func checkUpdates() {
        showSettings(pane: .about)
        UpdateManager.shared.check(userInitiated: true)
    }
}
