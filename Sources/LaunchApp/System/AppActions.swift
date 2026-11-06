// System/AppActions.swift
// Things you can do to an app from the launcher: open it, show it in Finder, add it to the
// Dock, and uninstall it (the app plus the files it left in ~/Library).

import AppKit

enum AppActions {

    static func open(_ app: AppInfo) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: config) { _, error in
            if let error { Log.error("open \(app.name): \(error.localizedDescription)") }
        }
    }

    static func revealInFinder(_ app: AppInfo) {
        NSWorkspace.shared.activateFileViewerSelecting([app.url])
    }

    static func isRunning(_ app: AppInfo) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.standardizedFileURL == app.url.standardizedFileURL }
    }

    // MARK: - Folder names

    /// A folder name from the apps' App Store category, the way Launchpad named new folders.
    static func folderName(for apps: [AppInfo]) -> String {
        let names = apps.compactMap { app -> String? in
            guard let raw = Bundle(url: app.url)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
            else { return nil }
            return categoryName(raw)
        }
        let counts = Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { a, b in a.value == b.value ? a.key > b.key : a.value < b.value }?.key ?? "Folder"
    }

    static func categoryName(_ uti: String) -> String? {
        guard uti.hasPrefix("public.app-category.") else { return nil }
        let tail = String(uti.dropFirst("public.app-category.".count))
        let special: [String: String] = [
            "developer-tools": "Developer Tools", "graphics-design": "Graphics & Design",
            "photography": "Photo & Video", "video": "Photo & Video", "social-networking": "Social Networking",
            "healthcare-fitness": "Health & Fitness", "lifestyle": "Lifestyle", "reference": "Reference",
            "productivity": "Productivity", "utilities": "Utilities", "business": "Business",
            "entertainment": "Entertainment", "music": "Music", "news": "News", "finance": "Finance",
            "education": "Education", "games": "Games", "travel": "Travel", "weather": "Weather",
            "medical": "Medical", "sports": "Sports",
        ]
        if let s = special[tail] { return s }
        if tail.hasSuffix("-games") { return "Games" }
        return tail.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }

    // MARK: - Dock

    static func isInDock(_ app: AppInfo) -> Bool {
        dockApps().contains { $0.standardizedFileURL.path == app.url.standardizedFileURL.path }
    }

    private static func dockApps() -> [URL] {
        let tiles = CFPreferencesCopyAppValue("persistent-apps" as CFString, "com.apple.dock" as CFString) as? [[String: Any]] ?? []
        return tiles.compactMap { tile in
            guard let data = tile["tile-data"] as? [String: Any],
                  let file = data["file-data"] as? [String: Any],
                  let s = file["_CFURLString"] as? String else { return nil }
            return URL(string: s) ?? URL(fileURLWithPath: s)
        }
    }

    /// Appends the app to the Dock's app section and restarts the Dock to pick it up.
    static func addToDock(_ app: AppInfo) {
        guard !isInDock(app) else { return }
        var tiles = CFPreferencesCopyAppValue("persistent-apps" as CFString, "com.apple.dock" as CFString) as? [[String: Any]] ?? []
        tiles.append([
            "tile-type": "file-tile",
            "tile-data": [
                "file-data": ["_CFURLString": app.url.absoluteString, "_CFURLStringType": 15],
                "file-label": app.name,
                "bundle-identifier": app.bundleID ?? "",
            ] as [String: Any],
        ])
        CFPreferencesSetAppValue("persistent-apps" as CFString, tiles as CFArray, "com.apple.dock" as CFString)
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        restartDock()
    }

    static func removeFromDock(_ app: AppInfo) {
        let path = app.url.standardizedFileURL.path
        let tiles = (CFPreferencesCopyAppValue("persistent-apps" as CFString, "com.apple.dock" as CFString) as? [[String: Any]] ?? [])
            .filter { tile in
                guard let data = tile["tile-data"] as? [String: Any],
                      let file = data["file-data"] as? [String: Any],
                      let s = file["_CFURLString"] as? String else { return true }
                let url = URL(string: s) ?? URL(fileURLWithPath: s)
                return url.standardizedFileURL.path != path
            }
        CFPreferencesSetAppValue("persistent-apps" as CFString, tiles as CFArray, "com.apple.dock" as CFString)
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        restartDock()
    }

    private static func restartDock() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["Dock"]
        try? p.run()
    }

    // MARK: - Uninstall

    static func canUninstall(_ app: AppInfo) -> Bool {
        !app.isSystem && !app.url.path.hasPrefix("/System/")
    }

    /// Files the app keeps in ~/Library, found by bundle id and by name.
    static func leftovers(of app: AppInfo) -> [URL] {
        let fm = FileManager.default
        let lib = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        var candidates: [String] = []
        if let id = app.bundleID, !id.isEmpty {
            candidates += [
                "Application Support/\(id)", "Caches/\(id)", "Preferences/\(id).plist",
                "Containers/\(id)", "Saved Application State/\(id).savedState", "HTTPStorages/\(id)",
                "HTTPStorages/\(id).binarycookies", "WebKit/\(id)", "Cookies/\(id).binarycookies",
                "Logs/\(id)", "Application Scripts/\(id)", "Caches/com.crashlytics.data/\(id)",
            ]
            // Launch agents named after the bundle id.
            if let agents = try? fm.contentsOfDirectory(atPath: lib.appendingPathComponent("LaunchAgents").path) {
                candidates += agents.filter { $0.hasPrefix(id) }.map { "LaunchAgents/\($0)" }
            }
            if let prefs = try? fm.contentsOfDirectory(atPath: lib.appendingPathComponent("Preferences").path) {
                candidates += prefs.filter { $0.hasPrefix(id + ".") && $0 != "\(id).plist" }.map { "Preferences/\($0)" }
            }
        }
        let name = app.name
        if name.count >= 3 {
            candidates += ["Application Support/\(name)", "Caches/\(name)", "Logs/\(name)"]
        }
        var seen = Set<String>()
        return candidates.map { lib.appendingPathComponent($0) }
            .filter { fm.fileExists(atPath: $0.path) && seen.insert($0.path).inserted }
    }

    /// Quits the app if it runs, then moves it (and `extra` files) to the Trash.
    /// Falls back to Finder (which asks for an administrator password) when the app is
    /// owned by root. Calls back on the main queue with an error message or nil.
    static func uninstall(_ app: AppInfo, extra: [URL], completion: @escaping (String?) -> Void) {
        for running in NSWorkspace.shared.runningApplications
        where running.bundleURL?.standardizedFileURL == app.url.standardizedFileURL {
            running.terminate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSWorkspace.shared.recycle([app.url]) { _, error in
                if error != nil {
                    // Root-owned app: let Finder do it (it shows the password prompt).
                    let script = "tell application \"Finder\" to delete (POSIX file \"\(app.url.path.replacingOccurrences(of: "\"", with: "\\\""))\")"
                    var err: NSDictionary?
                    NSAppleScript(source: script)?.executeAndReturnError(&err)
                    if FileManager.default.fileExists(atPath: app.url.path) {
                        DispatchQueue.main.async { completion("Couldn't move \(app.name) to the Trash.") }
                        return
                    }
                }
                if !extra.isEmpty { NSWorkspace.shared.recycle(extra, completionHandler: nil) }
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }
}
