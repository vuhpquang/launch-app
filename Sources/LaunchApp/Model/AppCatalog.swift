// Model/AppCatalog.swift
// Finds the installed apps in the app sources (folders) and watches those folders, so the
// launcher refreshes by itself when an app is installed or removed.

import AppKit
import CoreServices

struct AppInfo: Identifiable, Hashable {
    let id: AppID
    let url: URL
    /// Localised name from Finder (no ".app").
    let name: String
    let bundleID: String?
    /// Under /System — can't be uninstalled.
    let isSystem: Bool
    /// In a Utilities folder — goes in the "Other" folder of a fresh layout.
    let isUtility: Bool
}

enum AppSources {
    static let defaults: [String] = [
        "/Applications",
        "/System/Applications",
        "~/Applications",
    ]

    static func expanded(_ paths: [String]) -> [URL] {
        var seen = Set<String>()
        return paths.map { NSString(string: $0).expandingTildeInPath }
            .filter { seen.insert($0).inserted }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}

enum AppScanner {

    /// Bundles we never show (helpers that live in /Applications on some systems).
    static let excludedBundleIDs: Set<String> = [
        "com.vuhpquang.launchapp",
    ]

    /// Walks the folders (up to `depth` levels, never into a bundle) and returns the apps,
    /// sorted by name. When two apps share a bundle id, the second is keyed by its path.
    static func scan(_ folders: [URL], depth: Int = 3) -> [AppInfo] {
        let fm = FileManager.default
        var urls: [URL] = []
        var seenPaths = Set<String>()

        func walk(_ dir: URL, level: Int) {
            // Not .skipsHiddenFiles: /Applications/Safari.app is a symlink flagged hidden
            // (Safari lives in a cryptex). Dot-files and hidden folders are still skipped.
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isHiddenKey],
                                                            options: []) else { return }
            for url in entries where !url.lastPathComponent.hasPrefix(".") {
                let resolved = url.resolvingSymlinksInPath()
                if url.pathExtension.lowercased() == "app" {
                    if seenPaths.insert(resolved.path).inserted { urls.append(url) }
                    continue
                }
                if (try? url.resourceValues(forKeys: [.isHiddenKey]))?.isHidden == true { continue }
                let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                if values?.isDirectory == true, values?.isPackage != true, level < depth {
                    walk(url, level: level + 1)
                }
            }
        }
        folders.forEach { walk($0, level: 1) }

        var usedIDs = Set<String>()
        var apps: [AppInfo] = []
        for url in urls {
            let bundle = Bundle(url: url)
            let bundleID = bundle?.bundleIdentifier
            if let bundleID, excludedBundleIDs.contains(bundleID) { continue }
            // Skip background-only agents that happen to sit in an app folder.
            if bundle?.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool == true { continue }
            var id = bundleID ?? url.path
            if !usedIDs.insert(id).inserted { id = url.path; usedIDs.insert(id) }
            let path = url.path
            apps.append(AppInfo(
                id: id,
                url: url,
                name: displayName(of: url),
                bundleID: bundleID,
                isSystem: path.hasPrefix("/System/"),
                isUtility: path.contains("/Utilities/")
            ))
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func displayName(of url: URL) -> String {
        var name = FileManager.default.displayName(atPath: url.path)
        if name.lowercased().hasSuffix(".app") { name = String(name.dropLast(4)) }
        return name
    }
}

/// Watches folders with FSEvents and calls `onChange` (debounced, on the main queue).
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void
    private var pending: DispatchWorkItem?

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func watch(_ folders: [URL]) {
        stop()
        let paths = folders.map(\.path).filter { FileManager.default.fileExists(atPath: $0) } as CFArray
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().changed()
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    deinit { stop() }
}
