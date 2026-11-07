// Settings/Preferences.swift
// All user settings, stored as one JSON blob in UserDefaults. Every field decodes with a
// default, so settings written by an older version always load.

import AppKit
import Combine

enum BackgroundStyle: String, Codable, CaseIterable, Identifiable {
    case wallpaper, glass, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .wallpaper: return "Blurred Wallpaper"
        case .glass: return "Liquid Glass"
        case .dark: return "Dark"
        }
    }
}

enum ScrollMode: String, Codable, CaseIterable, Identifiable {
    case paged, vertical
    var id: String { rawValue }
    var title: String { self == .paged ? "Pages" : "Vertical Scroll" }
}

enum DisplayMode: String, Codable, CaseIterable, Identifiable {
    case fullScreen, window
    var id: String { rawValue }
    var title: String { self == .fullScreen ? "Full Screen" : "Window" }
}

/// How one page gives way to the next.
enum PageTransition: String, Codable, CaseIterable, Identifiable {
    case slide, parallax, fade, zoom, cube, cards, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .slide: return "Slide"
        case .parallax: return "Parallax"
        case .fade: return "Fade"
        case .zoom: return "Zoom"
        case .cube: return "Cube"
        case .cards: return "Cards"
        case .none: return "None"
        }
    }
}

enum HotCorner: String, Codable, CaseIterable, Identifiable {
    case none, topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "Off"
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }
}

/// Ready-made grid/icon combinations, picked from Settings → Appearance or the launcher's
/// right-click menu.
enum LayoutPreset: String, CaseIterable, Identifiable {
    case classic, compact, dense, spacious, big
    var id: String { rawValue }
    var title: String {
        switch self {
        case .classic: return "Classic (7 × 5)"
        case .compact: return "Compact (8 × 6)"
        case .dense: return "Dense (10 × 6)"
        case .spacious: return "Spacious (6 × 4)"
        case .big: return "Big Icons (5 × 3)"
        }
    }
    var columns: Int { [.classic: 7, .compact: 8, .dense: 10, .spacious: 6, .big: 5][self]! }
    var rows: Int { [.classic: 5, .compact: 6, .dense: 6, .spacious: 4, .big: 3][self]! }
    var iconScale: Double { [.classic: 1.0, .compact: 1.0, .dense: 0.95, .spacious: 1.0, .big: 1.0][self]! }

    func apply(to s: inout Settings) {
        s.columns = columns; s.rows = rows; s.iconScale = iconScale
    }

    static func matching(_ s: Settings) -> LayoutPreset? {
        allCases.first { $0.columns == s.columns && $0.rows == s.rows && abs($0.iconScale - s.iconScale) < 0.001 }
    }
}

struct Settings: Codable, Equatable {
    // General
    var showInDock = true
    /// Off (default): LaunchApp stays out of ⌘Tab, like Launchpad; the Dock icon is a pinned
    /// tile. On: a regular app (in ⌘Tab, with the app list in its Dock menu).
    var showInAppSwitcher = false
    var showMenuBarIcon = true
    var closeAfterLaunch = true
    var showAppsInDockMenu = true
    var autoCheckUpdates = true
    var autoInstallUpdates = false

    // Activation
    var hotKeyEnabled = true
    var hotKey: KeyCombo? = KeyCombo(key: "l", modifiers: NSEvent.ModifierFlags([.option, .command]).rawValue)
    var launchpadKeyEnabled = false
    var trackpadPinchEnabled = false
    var hotCorner: HotCorner = .none
    var hotCornerDelay: Double = 0.25

    // Appearance
    var columns = 7
    var rows = 5
    var iconScale: Double = 1.0
    var labelSize: Double = 13
    var showLabels = true
    var background: BackgroundStyle = .wallpaper
    var backgroundDim: Double = 0.25
    var scrollMode: ScrollMode = .paged
    var displayMode: DisplayMode = .fullScreen
    var windowScale: Double = 0.72
    var animationSpeed: Double = 1.0
    var showPageDots = true
    var liquidGlass = true
    var glassFollowsSystem = true
    var glassTint: Double = 0      // 0 clear … 1 tinted, when not following the system
    var pageTransition: PageTransition = .slide
    var folderColumns = 6
    var folderRows = 3

    // Apps
    var hiddenApps: [AppID] = []
    var renamedApps: [AppID: String] = [:]
    var extraSources: [String] = []
    var removeLeftoversOnUninstall = true

    var capacity: Int { max(1, columns * rows) }
    var folderCapacity: Int { max(1, folderColumns * folderRows) }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        showInDock = v(.showInDock, d.showInDock)
        showInAppSwitcher = v(.showInAppSwitcher, d.showInAppSwitcher)
        showMenuBarIcon = v(.showMenuBarIcon, d.showMenuBarIcon)
        closeAfterLaunch = v(.closeAfterLaunch, d.closeAfterLaunch)
        showAppsInDockMenu = v(.showAppsInDockMenu, d.showAppsInDockMenu)
        autoCheckUpdates = v(.autoCheckUpdates, d.autoCheckUpdates)
        autoInstallUpdates = v(.autoInstallUpdates, d.autoInstallUpdates)
        hotKeyEnabled = v(.hotKeyEnabled, d.hotKeyEnabled)
        hotKey = c.contains(.hotKey) ? (try? c.decodeIfPresent(KeyCombo.self, forKey: .hotKey)) ?? nil : d.hotKey
        launchpadKeyEnabled = v(.launchpadKeyEnabled, d.launchpadKeyEnabled)
        trackpadPinchEnabled = v(.trackpadPinchEnabled, d.trackpadPinchEnabled)
        hotCorner = v(.hotCorner, d.hotCorner)
        hotCornerDelay = v(.hotCornerDelay, d.hotCornerDelay)
        columns = v(.columns, d.columns)
        rows = v(.rows, d.rows)
        iconScale = v(.iconScale, d.iconScale)
        labelSize = v(.labelSize, d.labelSize)
        showLabels = v(.showLabels, d.showLabels)
        background = v(.background, d.background)
        backgroundDim = v(.backgroundDim, d.backgroundDim)
        scrollMode = v(.scrollMode, d.scrollMode)
        displayMode = v(.displayMode, d.displayMode)
        windowScale = v(.windowScale, d.windowScale)
        animationSpeed = v(.animationSpeed, d.animationSpeed)
        showPageDots = v(.showPageDots, d.showPageDots)
        liquidGlass = v(.liquidGlass, d.liquidGlass)
        glassFollowsSystem = v(.glassFollowsSystem, d.glassFollowsSystem)
        glassTint = v(.glassTint, d.glassTint)
        pageTransition = v(.pageTransition, d.pageTransition)
        folderColumns = v(.folderColumns, d.folderColumns)
        folderRows = v(.folderRows, d.folderRows)
        hiddenApps = v(.hiddenApps, d.hiddenApps)
        renamedApps = v(.renamedApps, d.renamedApps)
        extraSources = v(.extraSources, d.extraSources)
        removeLeftoversOnUninstall = v(.removeLeftoversOnUninstall, d.removeLeftoversOnUninstall)
    }
}

final class Preferences: ObservableObject {
    static let shared = Preferences()
    private static let key = "settings.v1"

    @Published var settings: Settings {
        didSet {
            revision &+= 1
            if settings != oldValue { save() }
        }
    }
    /// Bumped on every write to `settings`: a cheap key for values derived from them.
    private(set) var revision = 0

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let s = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = s
        } else {
            settings = Settings()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.key) }
    }

    /// Regular (⌘Tab + Dock menu) or accessory (neither; the Dock shows a pinned tile).
    var activationPolicy: NSApplication.ActivationPolicy {
        settings.showInAppSwitcher ? .regular : .accessory
    }

    var appSources: [URL] { AppSources.expanded(AppSources.defaults + settings.extraSources) }
}
