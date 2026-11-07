// Launcher/LauncherWindowController.swift
// The launcher window: a borderless, transparent window just below the Dock (so the Dock
// stays usable and icons can be dragged onto it), on every Space, over full-screen apps.
// Full-screen mode covers the screen under the pointer; window mode is a centred panel.
//
// InteractionView sits on top of the SwiftUI view and turns AppKit events into model
// calls; it lets clicks through to the search field, folder title and dialogs.

import AppKit
import SwiftUI

final class LauncherWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class LauncherWindowController: NSObject, LauncherHost, NSWindowDelegate {
    let model: LauncherModel
    let prefs: Preferences
    private(set) var window: LauncherWindow!
    private var interaction: InteractionView!
    private var hosting: LauncherHostingView!
    private var keyMonitor: Any?
    private(set) var isVisible = false
    private var hideWork: DispatchWorkItem?
    private var dockDragActive = false
    var onOpenSettings: (() -> Void)?

    init(model: LauncherModel, prefs: Preferences = .shared) {
        self.model = model
        self.prefs = prefs
        super.init()
        model.host = self
        build()
    }

    private func build() {
        let w = LauncherWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                               styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none
        w.acceptsMouseMovedEvents = true
        w.delegate = self

        let container = NSView(frame: w.contentLayoutRect)
        container.wantsLayer = true
        container.autoresizingMask = [.width, .height]
        hosting = LauncherHostingView(rootView: LauncherView(model: model, prefs: prefs))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.sizingOptions = []
        container.addSubview(hosting)

        interaction = InteractionView(frame: container.bounds)
        interaction.autoresizingMask = [.width, .height]
        interaction.model = model
        interaction.host = self
        container.addSubview(interaction)

        w.contentView = container
        window = w
    }

    // MARK: - Show / hide

    func toggle() {
        isVisible ? dismissLauncher(launching: false) : show()
    }

    func show() {
        hideWork?.cancel()
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let s = prefs.settings
        let frame: NSRect
        if s.displayMode == .window {
            let vf = screen.visibleFrame
            let scale = min(max(s.windowScale, 0.4), 0.95)
            let size = NSSize(width: (vf.width * scale).rounded(), height: (vf.height * scale).rounded())
            frame = NSRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2, width: size.width, height: size.height)
        } else {
            frame = screen.frame
        }
        // Only when something changed: setting the frame (or the size) lays out the whole
        // SwiftUI tree synchronously, which cost ~30 ms on every open.
        if model.compact != (s.displayMode == .window) { model.compact = s.displayMode == .window }
        if model.size != frame.size { model.size = frame.size }
        if window.frame != frame { window.setFrame(frame, display: false) }
        // Icons are cached per size; the first scan ran before the screen size was known.
        IconCache.shared.preload(model.apps.values.map(\.url), points: model.metrics.iconSize)

        if s.background == .wallpaper {
            Wallpaper.shared.image(for: screen) { [weak self] img in
                guard let self, self.model.backgroundImage !== img else { return }
                self.model.backgroundImage = img
            }
        }

        model.willPresent()
        model.presented = false
        isVisible = true
        installKeyMonitor()

        if s.displayMode == .fullScreen {
            NSApp.presentationOptions = [.autoHideMenuBar]
        }
        window.alphaValue = 1
        NSApp.unhide(nil)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window.makeFirstResponder(hosting)
        #if DEBUG
        print("[LaunchApp] window \(window.windowNumber)")
        #endif
        DispatchQueue.main.async {
            withAnimation(.spring(duration: 0.32 / max(0.25, s.animationSpeed), bounce: 0.1)) { self.model.presented = true }
        }
        // Rescan once the open animation is over, so a catalog change doesn't land mid-animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 / max(0.25, s.animationSpeed)) { [weak self] in
            guard let self, self.isVisible else { return }
            self.model.refreshApps()
        }
    }

    func dismissLauncher(launching: Bool) {
        guard isVisible else { return }
        isVisible = false
        removeKeyMonitor()
        let speed = max(0.25, prefs.settings.animationSpeed)
        withAnimation(.easeIn(duration: 0.2 / speed)) { model.presented = false }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.window.orderOut(nil)
            NSApp.presentationOptions = []
            self.model.didDismiss()
            // Give focus back to the app that was in front, unless we launched one.
            if !launching, !NSApp.windows.contains(where: { $0.isVisible && $0 !== self.window && $0.level == .normal && $0.className != "NSStatusBarWindow" }) {
                NSApp.hide(nil)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 / speed, execute: work)
    }

    func openSettings() {
        dismissLauncher(launching: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.onOpenSettings?() }
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking another app or window closes the launcher (not while a Dock drag runs).
        guard isVisible, !dockDragActive else { return }
        DispatchQueue.main.async {
            if self.isVisible, !self.window.isKeyWindow, NSApp.modalWindow == nil, !self.dockDragActive,
               NSApp.keyWindow == nil || NSApp.keyWindow?.level == .normal {
                self.dismissLauncher(launching: true)
            }
        }
    }

    // MARK: - Keys

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.isVisible, event.window === self.window else { return event }
            if event.type == .flagsChanged {
                self.model.flagsChanged(event.modifierFlags)
                return event
            }
            // While a text field other than search (folder title, rename) is editing, leave
            // most keys alone.
            if self.model.folderTitleEditing || self.model.dialog != nil, event.keyCode != 53 {
                return event
            }
            let handled = self.model.keyDown(keyCode: event.keyCode, modifiers: event.modifierFlags,
                                             characters: event.charactersIgnoringModifiers)
            return handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    // MARK: - LauncherHost

    func showMenu(_ entries: [MenuEntry], at point: CGPoint) {
        guard !entries.isEmpty else { return }
        let menu = NSMenu.build(entries)
        menu.popUp(positioning: nil, at: NSPoint(x: point.x, y: point.y), in: interaction)
    }

    private var dockOrientation: String {
        (CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String) ?? "bottom"
    }

    func pointerIsOverDock() -> Bool {
        guard let screen = window.screen ?? NSScreen.main else { return false }
        let p = NSEvent.mouseLocation
        let f = screen.frame, v = screen.visibleFrame
        let bottom = v.minY - f.minY, left = v.minX - f.minX, right = f.maxX - v.maxX
        if bottom > 8 { return p.y < f.minY + bottom }
        if left > 8 { return p.x < f.minX + left }
        if right > 8 { return p.x > f.maxX - right }
        // Auto-hidden Dock: the very edge on its side reveals it.
        switch dockOrientation {
        case "left": return p.x < f.minX + 3
        case "right": return p.x > f.maxX - 4
        default: return p.y < f.minY + 3
        }
    }

    func dockSideInsets() -> (left: CGFloat, right: CGFloat) {
        guard model.settings.displayMode == .fullScreen, let screen = window.screen ?? NSScreen.main else { return (0, 0) }
        let f = screen.frame, v = screen.visibleFrame
        let left = v.minX - f.minX, right = f.maxX - v.maxX
        return (left > 8 ? left : 0, right > 8 ? right : 0)
    }

    func beginDockDrag(app: AppInfo) {
        guard let event = NSApp.currentEvent, event.type == .leftMouseDragged else { return }
        dockDragActive = true
        interaction.beginFileDrag(url: app.url, icon: IconCache.shared.icon(for: app.url, points: model.metrics.iconSize),
                                  size: model.metrics.iconSize, event: event) { [weak self] in
            guard let self else { return }
            self.dockDragActive = false
            // The drop may have activated another app; don't stay on screen without focus.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if self.isVisible, !self.window.isKeyWindow, !NSApp.isActive { self.dismissLauncher(launching: true) }
            }
        }
    }
}

// MARK: - Interaction view

/// The SwiftUI host. While anything animates, AppKit refreshes the tracking areas every
/// frame and each refresh ends in `NSCursor.set()` for the arrow. With a customised pointer
/// (Accessibility → Pointer size/colour) every `set()` re-renders the cursor image on the
/// main thread — over a second of CPU across a few opens and folder animations. The
/// launcher only ever shows the arrow here (text fields set their own I-beam), so only set
/// it when it isn't already the current cursor.
final class LauncherHostingView: NSHostingView<LauncherView> {
    override func cursorUpdate(with event: NSEvent) {
        if NSCursor.current != NSCursor.arrow { NSCursor.arrow.set() }
    }
}

final class InteractionView: NSView, NSDraggingSource {
    weak var model: LauncherModel?
    weak var host: LauncherWindowController?
    private var dragEnded: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Let clicks through to SwiftUI controls (search field, folder title, dialogs).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let model else { return nil }
        if model.dialog != nil { return nil }
        let p = convert(point, from: superview)
        if model.openFolderID == nil {
            if model.metrics.searchFieldFrame.insetBy(dx: -4, dy: -4).contains(p) { return nil }
        } else if let fm = model.folderMetrics, fm.titleFrame.contains(p) {
            return nil
        }
        return super.hitTest(point)
    }

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    override func mouseDown(with e: NSEvent) {
        if e.modifierFlags.contains(.control) { rightMouseDown(with: e); return }
        // Clicking off the folder title ends its editing.
        if let tv = window?.firstResponder as? NSTextView, tv.isFieldEditor, model?.openFolderID != nil {
            window?.makeFirstResponder(nil)
        }
        model?.mouseDown(at: point(e), modifiers: e.modifierFlags, clickCount: e.clickCount)
    }
    override func mouseDragged(with e: NSEvent) { model?.mouseDragged(to: point(e)) }
    override func mouseUp(with e: NSEvent) { model?.mouseUp(at: point(e), modifiers: e.modifierFlags) }
    override func rightMouseDown(with e: NSEvent) { model?.rightMouseDown(at: point(e)) }
    override func otherMouseDown(with e: NSEvent) {}
    override func scrollWheel(with e: NSEvent) {
        model?.scrollWheel(dx: e.scrollingDeltaX, dy: e.scrollingDeltaY, precise: e.hasPreciseScrollingDeltas,
                           phase: e.phase, momentum: e.momentumPhase)
    }

    // MARK: File drag (to the Dock / Finder)

    func beginFileDrag(url: URL, icon: NSImage, size: CGFloat, event: NSEvent, ended: @escaping () -> Void) {
        dragEnded = ended
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let p = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size), contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragEnded?()
        dragEnded = nil
        model?.input.press = nil
    }
}

// MARK: - Menus from MenuEntry

private final class ClosureMenuItem: NSMenuItem {
    var handler: (() -> Void)?
    @objc func fire() { handler?() }
}

extension NSMenu {
    static func build(_ entries: [MenuEntry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for e in entries {
            if e.isSeparator { menu.addItem(.separator()); continue }
            let item = ClosureMenuItem(title: e.title, action: #selector(ClosureMenuItem.fire), keyEquivalent: "")
            item.target = item
            item.handler = e.action
            item.isEnabled = e.enabled
            item.state = e.checked ? .on : .off
            if let symbol = e.symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            if !e.children.isEmpty { item.submenu = build(e.children) }
            menu.addItem(item)
        }
        return menu
    }
}
