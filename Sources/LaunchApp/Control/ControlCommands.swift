// Control/ControlCommands.swift
// The commands an outside client (the MCP server, through ControlServer) can run against
// the live launcher: read the apps and the layout, rearrange it, make folders, change
// settings. Arguments and results are plain JSON values ([String: Any] etc.).
//
// Apps can be named by id (bundle id, or path) or by their exact display name; folders by
// id or name. Every change goes through the model, so the launcher updates live and the
// layout is saved as usual.

import AppKit
import SwiftUI

struct ControlError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

extension LauncherModel {

    static let controlCommands = [
        "status", "list_apps", "get_layout", "set_layout", "move_items", "create_folder", "update_folder",
        "disband_folder", "sort_alphabetically", "import_launchpad_layout", "reset_layout", "hide_apps",
        "unhide_apps", "rename_app", "get_settings", "update_settings", "apply_layout_preset", "search",
        "open_app", "go_to_page",
    ]

    /// Runs one command. `show`/`hide`/`open_settings` (window things) are handled by the app
    /// delegate before it gets here.
    func control(_ cmd: String, _ args: [String: Any]) throws -> Any {
        switch cmd {
        case "status":
            return [
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
                "apps": apps.count, "hiddenApps": settings.hiddenApps.count,
                "pages": layout.pages.count, "folders": layout.allItems.filter(\.isFolder).count,
                "grid": ["columns": settings.columns, "rows": settings.rows, "capacityPerPage": settings.capacity],
                "currentPage": page, "openFolder": openFolderID as Any,
            ] as [String: Any]

        case "list_apps":
            let q = (args["query"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let includeHidden = args["include_hidden"] as? Bool ?? false
            let hidden = Set(settings.hiddenApps)
            var ids = apps.keys.filter { includeHidden || !hidden.contains($0) }
            if !q.isEmpty {
                let ranked = rank(q, ids.compactMap { apps[$0] })
                ids = ranked
            } else {
                ids.sort { name(of: $0).localizedStandardCompare(name(of: $1)) == .orderedAscending }
            }
            return ids.map { appJSON($0, hidden: hidden.contains($0)) }

        case "get_layout":
            return layoutJSON()

        case "search":
            let q = try string(args, "query")
            let ids = rank(q, visibleApps())
            return ids.prefix(30).map { appJSON($0, hidden: false) }

        case "set_layout":
            guard let pages = args["pages"] as? [Any] else { throw ControlError("`pages` must be an array of pages") }
            return try setLayout(pages)

        case "move_items":
            let ids = try items(args, "items")
            let pageIndex = try int(args, "page")
            let index = (args["index"] as? Int) ?? Int.max
            guard pageIndex >= 0 else { throw ControlError("`page` must be ≥ 0") }
            var l = layout
            // Apps inside folders come out of them first.
            for id in ids where l.item(id: id) == nil {
                if let f = l.folderContaining(id) { l.updateFolder(f.id) { $0.apps.removeAll { $0 == id } } }
                l.insert([.app(id)], page: max(0, l.pages.count - 1), index: Int.max)
            }
            l.move(ids, toPage: min(pageIndex, l.pages.count), index: index)
            l.reflow(capacity: settings.capacity)
            commit(l)
            return layoutJSON()

        case "create_folder":
            let name = try string(args, "name")
            let ids = try apps(args, "apps")
            guard !ids.isEmpty else { throw ControlError("`apps` is empty") }
            var l = layout
            guard let fid = l.makeFolder(ids, name: name) else { throw ControlError("couldn't make the folder") }
            if let p = args["page"] as? Int { l.move([fid], toPage: max(0, min(p, l.pages.count)), index: (args["index"] as? Int) ?? Int.max) }
            l.reflow(capacity: settings.capacity)
            commit(l)
            return ["folder_id": fid, "layout": layoutJSON()]

        case "update_folder":
            let fid = try folder(args, "folder")
            var l = layout
            if let n = args["name"] as? String {
                let t = n.trimmingCharacters(in: .whitespacesAndNewlines)
                l.updateFolder(fid) { $0.name = t.isEmpty ? "Untitled" : t }
            }
            if args["apps"] != nil {
                let ids = try apps(args, "apps")
                for id in ids { pull(id, from: &l, except: fid) }
                let dropped = (l.item(id: fid)?.folder?.apps ?? []).filter { !ids.contains($0) }
                l.updateFolder(fid) { $0.apps = ids }
                // Apps no longer listed go back to the grid rather than disappearing.
                if !dropped.isEmpty { l.insert(dropped.map { .app($0) }, page: max(0, l.pages.count - 1), index: Int.max) }
            }
            if args["add"] != nil {
                let ids = try apps(args, "add")
                for id in ids { pull(id, from: &l, except: fid) }
                l.updateFolder(fid) { f in f.apps += ids.filter { !f.apps.contains($0) } }
            }
            if args["remove"] != nil {
                let ids = try apps(args, "remove")
                let pos = l.position(of: fid)
                l.updateFolder(fid) { f in f.apps.removeAll { ids.contains($0) } }
                l.insert(ids.map { .app($0) }, page: pos?.page ?? 0, index: (pos?.index ?? 0) + 1)
            }
            l.reflow(capacity: settings.capacity)
            commit(l)
            return layoutJSON()

        case "disband_folder":
            let fid = try folder(args, "folder")
            disbandFolder(fid)
            return layoutJSON()

        case "sort_alphabetically":
            sortAlphabetically()
            return layoutJSON()

        case "import_launchpad_layout":
            guard LaunchpadImporter.isAvailable else { throw ControlError("no Launchpad database on this Mac") }
            importLaunchpadLayout()
            return layoutJSON()

        case "reset_layout":
            resetLayout()
            return layoutJSON()

        case "hide_apps":
            let ids = try apps(args, "apps")
            hide(ids)
            return ["hidden": settings.hiddenApps]

        case "unhide_apps":
            let ids = try apps(args, "apps", allowHidden: true)
            prefs.settings.hiddenApps.removeAll { ids.contains($0) }
            return ["hidden": settings.hiddenApps]

        case "rename_app":
            let id = try apps(["a": [args["app"] as Any]], "a", allowHidden: true)[0]
            rename(id, to: args["name"] as? String)
            return appJSON(id, hidden: settings.hiddenApps.contains(id))

        case "get_settings":
            return try settingsJSON()

        case "update_settings":
            guard let changes = args["settings"] as? [String: Any] else { throw ControlError("`settings` must be an object") }
            return try updateSettings(changes)

        case "apply_layout_preset":
            let name = try string(args, "preset")
            guard let p = LayoutPreset(rawValue: name) else {
                throw ControlError("unknown preset; use one of \(LayoutPreset.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            p.apply(to: &prefs.settings)
            return try settingsJSON()

        case "open_app":
            let id = try apps(["a": [args["app"] as Any]], "a")[0]
            guard let app = apps[id] else { throw ControlError("unknown app") }
            AppActions.open(app)
            return ["opened": id]

        case "go_to_page":
            goToPage(try int(args, "page"))
            return ["page": page]

        default:
            throw ControlError("unknown command \(cmd)")
        }
    }

    // MARK: - JSON views

    private func appJSON(_ id: AppID, hidden: Bool) -> [String: Any] {
        var d: [String: Any] = ["id": id, "name": name(of: id)]
        if let a = apps[id] {
            d["path"] = a.url.path
            if a.name != name(of: id) { d["original_name"] = a.name }
        }
        if hidden { d["hidden"] = true }
        if let f = layout.folderContaining(id) { d["folder"] = f.name; d["folder_id"] = f.id }
        if let pos = layout.position(of: id) ?? layout.folderContaining(id).flatMap({ layout.position(of: $0.id) }) {
            d["page"] = pos.page; d["index"] = pos.index
        }
        return d
    }

    func layoutJSON() -> [String: Any] {
        [
            "capacity_per_page": settings.capacity,
            "pages": layout.pages.map { page in
                page.map { item -> [String: Any] in
                    switch item {
                    case .app(let id): return ["type": "app", "id": id, "name": name(of: id)]
                    case .folder(let f):
                        return ["type": "folder", "id": f.id, "name": f.name,
                                "apps": f.apps.map { ["id": $0, "name": name(of: $0)] }]
                    }
                }
            },
        ]
    }

    private func settingsJSON() throws -> [String: Any] {
        let data = try JSONEncoder().encode(settings)
        var d = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        d["_presets"] = LayoutPreset.allCases.map(\.rawValue)
        d["_current_preset"] = LayoutPreset.matching(settings)?.rawValue ?? "custom"
        return d
    }

    private func updateSettings(_ changes: [String: Any]) throws -> [String: Any] {
        let current = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any] ?? [:]
        let unknown = changes.keys.filter { current[$0] == nil && !Self.nullableSettings.contains($0) }
        guard unknown.isEmpty else {
            throw ControlError("unknown settings \(unknown.sorted()); valid keys: \(current.keys.sorted().joined(separator: ", "))")
        }
        var merged = current
        for (k, v) in changes { merged[k] = v }
        var s = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: merged))
        s.columns = min(12, max(3, s.columns)); s.rows = min(9, max(2, s.rows))
        s.folderColumns = min(9, max(3, s.folderColumns)); s.folderRows = min(6, max(1, s.folderRows))
        s.iconScale = min(1.6, max(0.5, s.iconScale)); s.labelSize = min(18, max(10, s.labelSize))
        s.windowScale = min(0.95, max(0.45, s.windowScale)); s.animationSpeed = min(2, max(0.5, s.animationSpeed))
        s.backgroundDim = min(0.7, max(0, s.backgroundDim))
        prefs.settings = s
        return try settingsJSON()
    }

    private static let nullableSettings: Set<String> = ["hotKey"]

    // MARK: - set_layout

    /// `pages`: [[item]] where item is an app (id or name), or {"folder": name, "apps": [...]}
    /// (optionally with "id" to keep an existing folder). Installed apps that aren't listed are
    /// appended at the end; unknown names are reported back.
    private func setLayout(_ pages: [Any]) throws -> [String: Any] {
        var used = Set<AppID>()
        var unknown: [String] = []
        var duplicates: [String] = []
        let visible = Set(visibleApps().map(\.id))
        func resolveAll(_ list: [Any]) -> [AppID] {
            list.compactMap { v -> AppID? in
                guard let s = v as? String else { unknown.append("\(v)"); return nil }
                guard let id = resolveApp(s), visible.contains(id) else { unknown.append(s); return nil }
                guard used.insert(id).inserted else { duplicates.append(s); return nil }
                return id
            }
        }
        var out: [[LayoutItem]] = []
        for (n, raw) in pages.enumerated() {
            guard let page = raw as? [Any] else { throw ControlError("page \(n) must be an array") }
            var items: [LayoutItem] = []
            for entry in page {
                if let obj = entry as? [String: Any] {
                    guard let name = (obj["folder"] ?? obj["name"]) as? String, let list = obj["apps"] as? [Any] else {
                        throw ControlError("a folder needs \"folder\" (name) and \"apps\"")
                    }
                    let ids = resolveAll(list)
                    if ids.count >= 2 {
                        let id = (obj["id"] as? String).flatMap { $0.hasPrefix("folder:") ? $0 : nil } ?? ("folder:" + UUID().uuidString)
                        items.append(.folder(Folder(id: id, name: name, apps: ids)))
                    } else if let only = ids.first {
                        items.append(.app(only))
                    }
                } else {
                    items += resolveAll([entry]).map { .app($0) }
                }
            }
            out.append(items)
        }
        var l = Layout(pages: out)
        let rest = visibleApps().map(\.id).filter { !used.contains($0) }
            .sorted { name(of: $0).localizedStandardCompare(name(of: $1)) == .orderedAscending }
        l.reconcile(installed: Array(used) + rest, capacity: settings.capacity)
        commit(l)
        var result = layoutJSON()
        if !unknown.isEmpty { result["unknown_apps"] = unknown }
        if !duplicates.isEmpty { result["duplicates_ignored"] = duplicates }
        if !rest.isEmpty { result["appended_unlisted_apps"] = rest.map { name(of: $0) } }
        return result
    }

    // MARK: - Helpers

    private func commit(_ l: Layout) {
        withAnimation(anim(0.35)) {
            layout = l
            if let id = openFolderID, layout.item(id: id) == nil { openFolderID = nil }
            clampPage()
        }
        scheduleSave()
    }

    private func rank(_ q: String, _ list: [AppInfo]) -> [AppID] {
        list.compactMap { app -> (AppID, Int)? in
            let display = name(of: app.id)
            return Search.score(name: display, query: q, extra: display == app.name ? [] : [app.name]).map { (app.id, $0) }
        }
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : name(of: $0.0).localizedStandardCompare(name(of: $1.0)) == .orderedAscending }
        .map(\.0)
    }

    private func visibleApps() -> [AppInfo] {
        let hidden = Set(settings.hiddenApps)
        return apps.values.filter { !hidden.contains($0.id) }
    }

    /// An app by id, or by display name / original name (case-insensitive).
    func resolveApp(_ s: String) -> AppID? {
        if apps[s] != nil { return s }
        let lower = s.lowercased()
        if let id = apps.keys.first(where: { $0.lowercased() == lower }) { return id }
        if let id = apps.keys.sorted().first(where: { name(of: $0).lowercased() == lower }) { return id }
        if let id = apps.keys.sorted().first(where: { apps[$0]?.name.lowercased() == lower }) { return id }
        return nil
    }

    private func pull(_ id: AppID, from l: inout Layout, except fid: String) {
        if let f = l.folderContaining(id), f.id != fid { l.updateFolder(f.id) { $0.apps.removeAll { $0 == id } } }
        if l.item(id: id) != nil { l.remove([id]) }
    }

    private func string(_ a: [String: Any], _ k: String) throws -> String {
        guard let s = a[k] as? String, !s.isEmpty else { throw ControlError("`\(k)` (string) is required") }
        return s
    }

    private func int(_ a: [String: Any], _ k: String) throws -> Int {
        if let i = a[k] as? Int { return i }
        if let d = a[k] as? Double { return Int(d) }
        throw ControlError("`\(k)` (integer) is required")
    }

    private func apps(_ a: [String: Any], _ k: String, allowHidden: Bool = false) throws -> [AppID] {
        let list: [Any] = (a[k] as? [Any]) ?? (a[k] as? String).map { [$0] } ?? []
        guard !list.isEmpty else { throw ControlError("`\(k)` (array of app ids or names) is required") }
        let hidden = Set(settings.hiddenApps)
        return try list.map { v in
            guard let s = v as? String, let id = resolveApp(s) else { throw ControlError("unknown app \(v)") }
            if !allowHidden, hidden.contains(id) { throw ControlError("\(s) is hidden; unhide it first") }
            return id
        }
    }

    /// Items to move: app ids/names or folder ids/names.
    private func items(_ a: [String: Any], _ k: String) throws -> [String] {
        guard let list = a[k] as? [Any], !list.isEmpty else { throw ControlError("`\(k)` (array) is required") }
        return try list.map { v in
            guard let s = v as? String else { throw ControlError("bad item \(v)") }
            if let f = findFolder(s) { return f }
            if let id = resolveApp(s) { return id }
            throw ControlError("unknown app or folder \(s)")
        }
    }

    private func folder(_ a: [String: Any], _ k: String) throws -> String {
        let s = try string(a, k)
        guard let f = findFolder(s) else { throw ControlError("unknown folder \(s)") }
        return f
    }

    private func findFolder(_ s: String) -> String? {
        let folders = layout.allItems.compactMap(\.folder)
        return folders.first { $0.id == s }?.id ?? folders.first { $0.name.lowercased() == s.lowercased() }?.id
    }
}
