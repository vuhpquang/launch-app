// Launcher/LauncherModel.swift
// State of the launcher and everything that changes it. The SwiftUI views only draw this
// state; the InteractionView feeds mouse, scroll and key events into the methods in
// LauncherModel+Input.swift.

import AppKit
import Combine
import SwiftUI

/// What the window controller does for the model.
protocol LauncherHost: AnyObject {
    func dismissLauncher(launching: Bool)
    func openSettings()
    func beginDockDrag(app: AppInfo)
    func showMenu(_ entries: [MenuEntry], at point: CGPoint)
    func pointerIsOverDock() -> Bool
    /// How far the Dock reaches in from the left/right window edges (0 when it's elsewhere).
    func dockSideInsets() -> (left: CGFloat, right: CGFloat)
}

struct MenuEntry {
    var title: String
    var symbol: String?
    var enabled = true
    var checked = false
    var children: [MenuEntry] = []
    var action: (() -> Void)?
    static let separator = MenuEntry(title: "-")
    var isSeparator: Bool { title == "-" }
}

enum Dialog: Identifiable, Equatable {
    case rename(AppID, String)
    case uninstall([AppID], leftovers: Int)
    case message(String, String)

    var id: String {
        switch self {
        case .rename(let id, _): return "rename:\(id)"
        case .uninstall(let ids, _): return "uninstall:\(ids.joined(separator: ","))"
        case .message(let t, _): return "message:\(t)"
        }
    }
}

struct DragState {
    var ids: [String]
    var fromFolder: String?
    var base: Layout
    var baseFolderApps: [AppID] = []
    var original: Layout
    var location: CGPoint
    var grab: CGSize
    var target: ItemPosition
    var edgeSince: Date?
    var mergeCandidate: String?
    var mergeSince: Date?
    var lastMove = Date.distantPast
    var pendingTarget: Int?           // gap slot under the dragged icon, waiting to settle
    var pendingSince: Date?
    var velocity: CGSize = .zero      // points/s, smoothed — tilts the glass while dragging
    var lastUpdate = Date()
}

final class LauncherModel: ObservableObject {
    let prefs: Preferences
    weak var host: LauncherHost?
    let input = InputState()

    @Published var layout: Layout = .empty
    @Published var apps: [AppID: AppInfo] = [:]
    @Published var query = "" {
        didSet { if query != oldValue { queryChanged(from: oldValue) } }
    }
    @Published private(set) var results: [AppID] = []
    @Published var page = 0
    @Published var pageOffset: CGFloat = 0
    @Published var scrollY: CGFloat = 0
    @Published var openFolderID: String?
    @Published var folderPage = 0
    @Published var editing = false
    @Published var optionHeld = false
    @Published var selection: [String] = []
    @Published var keyboardIndex: Int?
    @Published var drag: DragState?
    @Published var mergeTargetID: String?
    @Published var dialog: Dialog?
    @Published var toast: String?
    @Published var presented = false
    @Published var size = CGSize(width: 1440, height: 900)
    @Published var compact = false
    @Published var backgroundImage: CGImage?
    @Published var focusSearchToken = 0
    /// The open folder's name field is being edited (keys go to it, not to navigation).
    var folderTitleEditing = false

    private var mainPageBeforeSearch = 0
    private var saveWork: DispatchWorkItem?
    private var toastWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private var scanning = false
    private var hasLoaded = false

    var settings: Settings { prefs.settings }

    /// False in tests: never read or write the user's layout file.
    let persists: Bool

    init(prefs: Preferences = .shared, persists: Bool = true) {
        self.prefs = prefs
        self.persists = persists
        if persists, let saved = LayoutStore.load() { layout = saved }
        prefs.$settings
            .map { ($0.columns, $0.rows) }
            .removeDuplicates { $0 == $1 }
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.gridSizeChanged() }
            }
            .store(in: &cancellables)
        prefs.$settings
            .map(\.hiddenApps)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.applyCatalog() } }
            .store(in: &cancellables)
    }

    // MARK: - Geometry

    var metrics: GridMetrics {
        GridMetrics(size: size, columns: settings.columns, rows: settings.rows, iconScale: settings.iconScale,
                    showLabels: settings.showLabels, labelSize: settings.labelSize, compact: compact)
    }

    var folderMetrics: FolderMetrics? {
        guard let f = openFolder else { return nil }
        return FolderMetrics(grid: metrics, columns: settings.folderColumns, rows: settings.folderRows, count: f.apps.count)
    }

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    var isVertical: Bool { settings.scrollMode == .vertical }
    var isEditing: Bool { editing || optionHeld }

    /// The pages currently on screen (search results or the layout).
    var displayPages: [[LayoutItem]] {
        if isSearching {
            let cap = settings.capacity
            let items = results.map { LayoutItem.app($0) }
            guard !items.isEmpty else { return [[]] }
            return stride(from: 0, to: items.count, by: cap).map { Array(items[$0..<min($0 + cap, items.count)]) }
        }
        return layout.pages
    }

    var pageCount: Int { max(1, displayPages.count) }

    var openFolder: Folder? {
        guard let id = openFolderID else { return nil }
        return layout.item(id: id)?.folder
    }

    // MARK: - Names

    func name(of appID: AppID) -> String {
        settings.renamedApps[appID] ?? apps[appID]?.name ?? (appID as NSString).lastPathComponent
    }

    func name(of item: LayoutItem) -> String {
        switch item {
        case .app(let id): return name(of: id)
        case .folder(let f): return f.name
        }
    }

    // MARK: - Loading apps

    /// Rescans the app folders (off the main thread) and merges the result into the layout.
    func refreshApps() {
        guard !scanning else { return }
        scanning = true
        let sources = prefs.appSources
        DispatchQueue.global(qos: .userInitiated).async {
            let found = AppScanner.scan(sources)
            DispatchQueue.main.async {
                self.scanning = false
                let old = self.apps
                self.apps = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                if Set(old.keys) != Set(self.apps.keys) || !self.hasLoaded { self.applyCatalog(sorted: found) }
                IconCache.shared.preload(found.map(\.url), points: self.metrics.iconSize)
            }
        }
    }

    private func applyCatalog(sorted: [AppInfo]? = nil) {
        let list = sorted ?? apps.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !list.isEmpty else { return }
        let hidden = Set(settings.hiddenApps)
        let visible = list.filter { !hidden.contains($0.id) }
        if !hasLoaded {
            hasLoaded = true
            if !persists || LayoutStore.load() == nil {
                firstRunLayout(visible)
                return
            }
        }
        var l = layout
        l.reconcile(installed: visible.map(\.id), capacity: settings.capacity)
        if l != layout { layout = l; scheduleSave() }
        recomputeResults()
        clampPage()
    }

    private func firstRunLayout(_ apps: [AppInfo]) {
        if LaunchpadImporter.isAvailable, let imported = try? LaunchpadImporter.readSystemLayout(), imported.appCount > 0 {
            var l = LaunchpadImporter.layout(from: imported, apps: apps)
            l.reconcile(installed: apps.map(\.id), capacity: settings.capacity)
            layout = l
            showToast("Imported your Launchpad layout")
        } else {
            layout = LayoutStore.defaultLayout(apps: apps, capacity: settings.capacity)
        }
        scheduleSave()
    }

    func importLaunchpadLayout() {
        do {
            let imported = try LaunchpadImporter.readSystemLayout()
            let hidden = Set(settings.hiddenApps)
            let list = apps.values.filter { !hidden.contains($0.id) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            var l = LaunchpadImporter.layout(from: imported, apps: list)
            l.reconcile(installed: list.map(\.id), capacity: settings.capacity)
            withAnimation(anim(0.35)) { layout = l; page = 0 }
            scheduleSave()
            showToast("Imported \(imported.appCount) items from Launchpad")
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func resetLayout() {
        let hidden = Set(settings.hiddenApps)
        let list = apps.values.filter { !hidden.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        withAnimation(anim(0.35)) {
            layout = LayoutStore.defaultLayout(apps: list, capacity: settings.capacity)
            page = 0
        }
        scheduleSave()
    }

    func sortAlphabetically() {
        withAnimation(anim(0.4)) {
            layout.sortAlphabetically(capacity: settings.capacity, name: { self.name(of: $0) }, appName: { self.name(of: $0) })
            page = 0
        }
        scheduleSave()
    }

    private func gridSizeChanged() {
        layout.repack(capacity: settings.capacity)
        clampPage()
        IconCache.shared.preload(apps.values.map(\.url), points: metrics.iconSize)
        scheduleSave()
    }

    func scheduleSave() {
        guard persists else { return }
        saveWork?.cancel()
        let snapshot = layout
        let work = DispatchWorkItem { LayoutStore.save(snapshot) }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Writes a pending save right away (on quit).
    func saveNow() {
        guard persists, let work = saveWork, !work.isCancelled else { return }
        work.cancel()
        LayoutStore.save(layout)
    }

    func clampPage() {
        page = min(max(0, page), pageCount - 1)
        if isVertical {
            let count = displayPages.flatMap { $0 }.count
            scrollY = min(max(0, scrollY), metrics.maxScrollY(count: count))
        }
    }

    // MARK: - Presenting

    func anim(_ duration: Double) -> Animation {
        .spring(duration: duration / max(0.25, settings.animationSpeed), bounce: 0.12)
    }

    func willPresent() {
        query = ""
        openFolderID = nil
        editing = false
        selection = []
        keyboardIndex = nil
        cancelItemDrag()
        dialog = nil
        pageOffset = 0
        clampPage()
        focusSearchToken += 1
    }

    func didDismiss() {
        openFolderID = nil
        editing = false
        optionHeld = false
        cancelItemDrag()
        mergeTargetID = nil
        query = ""
    }

    // MARK: - Search

    private func queryChanged(from old: String) {
        let wasSearching = !old.trimmingCharacters(in: .whitespaces).isEmpty
        if isSearching {
            if !wasSearching {
                mainPageBeforeSearch = page
                openFolderID = nil
                editing = false
            }
            recomputeResults()
            page = 0
            scrollY = 0
            keyboardIndex = results.isEmpty ? nil : 0
        } else {
            results = []
            if wasSearching { page = mainPageBeforeSearch; keyboardIndex = nil }
            clampPage()
        }
    }

    /// Search results for the current query (also after apps are hidden or removed).
    func recomputeResults() {
        guard isSearching else { results = []; return }
        do {
            let hidden = Set(settings.hiddenApps)
            let scored: [(AppID, Int)] = apps.values.compactMap { app in
                guard !hidden.contains(app.id) else { return nil }
                let display = name(of: app.id)
                let extra = display == app.name ? [] : [app.name]
                return Search.score(name: display, query: query, extra: extra).map { (app.id, $0) }
            }
            results = scored.sorted { a, b in
                a.1 != b.1 ? a.1 > b.1 : name(of: a.0).localizedStandardCompare(name(of: b.0)) == .orderedAscending
            }.map(\.0)
        }
        if let k = keyboardIndex, k >= results.count { keyboardIndex = results.isEmpty ? nil : results.count - 1 }
        clampPage()
    }

    // MARK: - Opening things

    func launch(_ appID: AppID) {
        guard let app = apps[appID] else { return }
        AppActions.open(app, activate: settings.closeAfterLaunch)
        if settings.closeAfterLaunch { host?.dismissLauncher(launching: true) }
    }

    func open(_ item: LayoutItem) {
        switch item {
        case .app(let id): launch(id)
        case .folder(let f): openFolder(f.id)
        }
    }

    /// Where the open folder's icon is, as a unit point of the screen (the panel grows from it).
    var folderOrigin: UnitPoint {
        guard let id = openFolderID, let pos = layout.position(of: id), size.width > 0, size.height > 0 else { return .center }
        let c = isVertical ? metrics.verticalIconCenter(flat: layout.flatIndex(of: pos), scrollY: scrollY)
                           : metrics.iconCenter(slot: pos.index)
        return UnitPoint(x: c.x / size.width, y: c.y / size.height)
    }

    func openFolder(_ id: String) {
        withAnimation(.smooth(duration: 0.34 / max(0.25, settings.animationSpeed))) {
            openFolderID = id
            folderPage = 0
            keyboardIndex = nil
        }
    }

    func closeFolder() {
        guard openFolderID != nil else { return }
        withAnimation(.smooth(duration: 0.28 / max(0.25, settings.animationSpeed))) { openFolderID = nil }
        keyboardIndex = nil
        scheduleSave()
    }

    func renameFolder(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        layout.updateFolder(id) { $0.name = trimmed.isEmpty ? "Untitled" : trimmed }
        scheduleSave()
    }

    /// Page slides: a calm ease-out with no overshoot (bounce made icons jiggle at the end).
    func pageAnimation() -> Animation? {
        settings.pageTransition == .none ? nil : .spring(duration: 0.62 / max(0.25, settings.animationSpeed), bounce: 0)
    }

    func goToPage(_ p: Int) {
        let target = min(max(0, p), pageCount - 1)
        withAnimation(pageAnimation()) {
            page = target
            pageOffset = 0
        }
    }

    // MARK: - App commands

    func hide(_ appIDs: [AppID]) {
        var s = prefs.settings
        for id in appIDs where !s.hiddenApps.contains(id) { s.hiddenApps.append(id) }
        withAnimation(anim(0.3)) {
            prefs.settings = s
            selection.removeAll()
        }
        showToast(appIDs.count == 1 ? "\(name(of: appIDs[0])) is hidden" : "\(appIDs.count) apps hidden")
    }

    func unhide(_ appID: AppID) {
        prefs.settings.hiddenApps.removeAll { $0 == appID }
    }

    func rename(_ appID: AppID, to newName: String?) {
        let trimmed = newName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty || trimmed == apps[appID]?.name {
            prefs.settings.renamedApps.removeValue(forKey: appID)
        } else {
            prefs.settings.renamedApps[appID] = trimmed
        }
        objectWillChange.send()
    }

    func makeFolder(from ids: [String]) {
        let appIDs = ids.filter { layout.item(id: $0).map { !$0.isFolder } ?? true }
        guard appIDs.count >= 1 else { return }
        let name = AppActions.folderName(for: appIDs.compactMap { apps[$0] })
        withAnimation(anim(0.35)) {
            layout.makeFolder(appIDs, name: name)
            layout.reflow(capacity: settings.capacity)
            selection.removeAll()
            clampPage()
        }
        scheduleSave()
    }

    func disbandFolder(_ id: String) {
        withAnimation(anim(0.35)) {
            layout.disband(id)
            layout.reflow(capacity: settings.capacity)
            if openFolderID == id { openFolderID = nil }
        }
        scheduleSave()
    }

    func removeFromFolder(_ appID: AppID) {
        guard let f = layout.folderContaining(appID), let pos = layout.position(of: f.id) else { return }
        withAnimation(anim(0.35)) {
            layout.remove([appID])
            layout.insert([.app(appID)], page: pos.page, index: (layout.pages[pos.page].firstIndex { $0.id == f.id || f.apps.contains($0.id) } ?? pos.index) + 1)
            layout.reflow(capacity: settings.capacity)
            if layout.item(id: f.id) == nil { openFolderID = nil }
        }
        scheduleSave()
    }

    func requestUninstall(_ appIDs: [AppID]) {
        let ids = appIDs.filter { apps[$0].map(AppActions.canUninstall) ?? false }
        guard !ids.isEmpty else {
            showToast("System apps can't be uninstalled")
            return
        }
        let leftovers = settings.removeLeftoversOnUninstall
            ? ids.compactMap { apps[$0] }.reduce(0) { $0 + AppActions.leftovers(of: $1, otherApps: Array(apps.values)).count } : 0
        withAnimation(anim(0.25)) { dialog = .uninstall(ids, leftovers: leftovers) }
    }

    func confirmUninstall(_ appIDs: [AppID]) {
        dialog = nil
        // Finder's password prompt opens below the launcher, so step aside first.
        if appIDs.compactMap({ apps[$0] }).contains(where: AppActions.needsAdmin) {
            host?.dismissLauncher(launching: true)
        }
        for id in appIDs {
            guard let app = apps[id] else { continue }
            let extra = settings.removeLeftoversOnUninstall ? AppActions.leftovers(of: app, otherApps: Array(apps.values)) : []
            AppActions.uninstall(app, extra: extra) { [weak self] error in
                guard let self else { return }
                if let error { self.showToast(error); return }
                withAnimation(self.anim(0.3)) {
                    self.layout.remove([id])
                    self.layout.reflow(capacity: self.settings.capacity)
                    self.apps.removeValue(forKey: id)
                    self.selection.removeAll { $0 == id }
                    self.recomputeResults()
                    self.clampPage()
                }
                self.scheduleSave()
                self.showToast("\(app.name) moved to the Trash")
            }
        }
    }

    func showToast(_ text: String) {
        toastWork?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { toast = text }
        let work = DispatchWorkItem { [weak self] in withAnimation(.easeIn(duration: 0.25)) { self?.toast = nil } }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: work)
    }

    // MARK: - Selection

    func toggleSelection(_ id: String) {
        if let i = selection.firstIndex(of: id) { selection.remove(at: i) } else { selection.append(id) }
    }

    /// Selected items in layout order.
    var orderedSelection: [String] {
        let set = Set(selection)
        var out: [String] = []
        for item in layout.allItems {
            if set.contains(item.id) { out.append(item.id) }
            if let f = item.folder { out += f.apps.filter { set.contains($0) } }
        }
        return out
    }
}
