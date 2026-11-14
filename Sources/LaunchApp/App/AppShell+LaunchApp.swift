// App/AppShell+LaunchApp.swift
// LaunchApp's values for the shared app shell (Vendor/app-shell): who it is, where its releases are,
// and where its update settings live (Preferences.settings — the keys stay as they were).

import AboutKit
import AppKit
import AppShellCore
import Combine
import UpdaterKit

extension AppIdentity {
    static let launchApp = AppIdentity(
        name: "LaunchApp",
        tagline: "The classic Launchpad, back on macOS 26+.",
        repo: "vuhpquang/launch-app",
        firstYear: 2026,
        whatsNew: .menuItem
    )
}

/// Update settings stored in `Preferences.settings` (`autoCheckUpdates`, `autoInstallUpdates`).
@MainActor
final class LaunchAppUpdateSettings: UpdateSettingsStore {
    private let prefs: Preferences
    init(prefs: Preferences) { self.prefs = prefs }

    var autoCheck: Bool {
        get { prefs.settings.autoCheckUpdates }
        set { prefs.settings.autoCheckUpdates = newValue }
    }

    var autoInstall: Bool {
        get { prefs.settings.autoInstallUpdates }
        set { prefs.settings.autoInstallUpdates = newValue }
    }

    var changes: AnyPublisher<Void, Never> {
        prefs.$settings
            .map { [$0.autoCheckUpdates, $0.autoInstallUpdates] }
            .removeDuplicates()
            .dropFirst()
            .map { _ in () }
            .eraseToAnyPublisher()
    }
}

extension Updater {
    /// LaunchApp's one updater. A relaunch after an update starts in the background, so an
    /// automatic install never pops the launcher up in front of the user.
    @MainActor static let shared: Updater = {
        let updater = Updater(app: .launchApp, matcher: .dmg, settings: LaunchAppUpdateSettings(prefs: .shared))
        updater.relaunchArguments = ["--background"]
        return updater
    }()
}

extension WhatsNewTracker {
    /// Offers "What's New in X" in LaunchApp's menus once after an update (it's a background app,
    /// so no window opens by itself).
    @MainActor static let shared = WhatsNewTracker(app: .launchApp)
}
