// Model/LayoutStore.swift
// Saves the layout as JSON in ~/Library/Application Support/LaunchApp/layout.json.

import Foundation

enum LayoutStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LaunchApp", isDirectory: true)
    }

    static var fileURL: URL {
        #if DEBUG
        // LAUNCHAPP_LAYOUT_FILE: work on a copy (the bench drags icons around).
        if let path = ProcessInfo.processInfo.environment["LAUNCHAPP_LAYOUT_FILE"] { return URL(fileURLWithPath: path) }
        #endif
        return directory.appendingPathComponent("layout.json")
    }

    static func load(from url: URL = fileURL) -> Layout? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Layout.self, from: data)
    }

    static func save(_ layout: Layout, to url: URL = fileURL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(layout).write(to: url, options: .atomic)
        } catch {
            Log.error("LayoutStore: save failed: \(error.localizedDescription)")
        }
    }

    /// A fresh layout: everything alphabetical, with utilities gathered in an "Other"
    /// folder, as on a new Mac's Launchpad.
    static func defaultLayout(apps: [AppInfo], capacity: Int) -> Layout {
        let utilities = apps.filter(\.isUtility).map(\.id)
        var items: [LayoutItem] = apps.filter { !$0.isUtility }.map { .app($0.id) }
        if utilities.count > 1 {
            items.append(.folder(Folder(name: "Other", apps: utilities)))
        } else {
            items += utilities.map { .app($0) }
        }
        var layout = Layout(pages: [items])
        layout.reflow(capacity: capacity)
        return layout
    }
}
