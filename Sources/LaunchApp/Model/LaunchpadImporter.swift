// Model/LaunchpadImporter.swift
// Reads the classic Launchpad database (still on disk after upgrading to macOS 26) and turns
// it into a Layout: same pages, same folders, same order.
//
// Database: $(getconf DARWIN_USER_DIR)/com.apple.dock.launchpad/db/db (SQLite, WAL mode).
//   items(rowid, type, parent_id, ordering)   type 1 root · 2 folder · 3 page · 4 app
//   apps(item_id, title, bundleid)            groups(item_id, title)
//   dbinfo(key, value)                        'launchpad_root' → rowid of the visible root
// Pages hang off the root; apps and folders hang off pages; a folder holds its own pages.
// The file is copied (with -wal/-shm) before reading so we never touch Dock's live copy.

import Foundation
import SQLite3

enum LaunchpadImporter {

    struct Imported {
        var pages: [[Entry]]
        enum Entry: Equatable {
            case app(title: String, bundleID: String?)
            case folder(title: String, apps: [(title: String, bundleID: String?)])

            static func == (a: Entry, b: Entry) -> Bool {
                switch (a, b) {
                case let (.app(t1, b1), .app(t2, b2)): return t1 == t2 && b1 == b2
                case let (.folder(t1, a1), .folder(t2, a2)):
                    return t1 == t2 && a1.map(\.title) == a2.map(\.title) && a1.map(\.bundleID) == a2.map(\.bundleID)
                default: return false
                }
            }
        }
        var appCount: Int {
            pages.flatMap { $0 }.reduce(0) { n, e in
                if case .folder(_, let apps) = e { return n + apps.count }
                return n + 1
            }
        }
    }

    static var databaseURL: URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_DIR, &buffer, buffer.count) > 0 else { return nil }
        let dir = String(cString: buffer)
        let url = URL(fileURLWithPath: dir).appendingPathComponent("com.apple.dock.launchpad/db/db")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var isAvailable: Bool { databaseURL != nil }

    /// Copies the database to a temp folder and reads it.
    static func readSystemLayout() throws -> Imported {
        guard let source = databaseURL else { throw ImportError("No Launchpad database was found on this Mac.") }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("LaunchAppImport-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: source.path + suffix)
            if fm.fileExists(atPath: from.path) {
                try fm.copyItem(at: from, to: work.appendingPathComponent("db" + suffix))
            }
        }
        return try read(databaseAt: work.appendingPathComponent("db"))
    }

    struct ImportError: LocalizedError {
        let errorDescription: String?
        init(_ m: String) { errorDescription = m }
    }

    static func read(databaseAt url: URL) throws -> Imported {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            throw ImportError("Couldn't open the Launchpad database.")
        }
        defer { sqlite3_close(db) }

        func query(_ sql: String, _ row: (OpaquePointer) -> Void) throws {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw ImportError("The Launchpad database has an unexpected format.")
            }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
        }
        func text(_ s: OpaquePointer, _ i: Int32) -> String? {
            guard let c = sqlite3_column_text(s, i) else { return nil }
            return String(cString: c)
        }

        var root: Int64 = 1
        try? query("SELECT value FROM dbinfo WHERE key='launchpad_root'") { s in
            if let v = text(s, 0), let n = Int64(v) { root = n }
        }

        struct Row { let id: Int64; let type: Int; let parent: Int64; let ordering: Int; let title: String?; let bundleID: String? }
        var rows: [Row] = []
        try query("""
            SELECT i.rowid, i.type, i.parent_id, i.ordering, COALESCE(a.title, g.title), a.bundleid
            FROM items i LEFT JOIN apps a ON a.item_id = i.rowid LEFT JOIN groups g ON g.item_id = i.rowid
            """) { s in
            rows.append(Row(id: sqlite3_column_int64(s, 0), type: Int(sqlite3_column_int(s, 1)),
                            parent: sqlite3_column_int64(s, 2), ordering: Int(sqlite3_column_int(s, 3)),
                            title: text(s, 4), bundleID: text(s, 5)))
        }
        let children = Dictionary(grouping: rows, by: \.parent).mapValues { $0.sorted { $0.ordering < $1.ordering } }

        func apps(inFolder id: Int64) -> [(title: String, bundleID: String?)] {
            (children[id] ?? []).filter { $0.type == 3 }.flatMap { page in
                (children[page.id] ?? []).filter { $0.type == 4 || $0.type == 5 }
                    .map { (title: $0.title ?? "", bundleID: $0.bundleID) }
            }
        }

        var pages: [[Imported.Entry]] = []
        for page in (children[root] ?? []) where page.type == 3 {
            var entries: [Imported.Entry] = []
            for item in children[page.id] ?? [] {
                switch item.type {
                case 4, 5: entries.append(.app(title: item.title ?? "", bundleID: item.bundleID))
                case 2:
                    let list = apps(inFolder: item.id)
                    if !list.isEmpty { entries.append(.folder(title: item.title ?? "Folder", apps: list)) }
                default: break
                }
            }
            if !entries.isEmpty { pages.append(entries) }
        }
        return Imported(pages: pages)
    }

    /// Maps the imported entries onto installed apps. Unknown apps are skipped; apps that
    /// weren't in Launchpad are added later by `Layout.reconcile`.
    static func layout(from imported: Imported, apps: [AppInfo]) -> Layout {
        var byBundle: [String: AppID] = [:]
        var byName: [String: AppID] = [:]
        for app in apps {
            if let b = app.bundleID?.lowercased(), byBundle[b] == nil { byBundle[b] = app.id }
            if byName[app.name.lowercased()] == nil { byName[app.name.lowercased()] = app.id }
        }
        var used = Set<AppID>()
        func resolve(_ title: String, _ bundleID: String?) -> AppID? {
            let id = bundleID.flatMap { byBundle[$0.lowercased()] } ?? byName[title.lowercased()]
            guard let id, used.insert(id).inserted else { return nil }
            return id
        }
        let pages: [[LayoutItem]] = imported.pages.map { page in
            page.compactMap { entry -> LayoutItem? in
                switch entry {
                case .app(let title, let bundleID):
                    return resolve(title, bundleID).map { .app($0) }
                case .folder(let title, let list):
                    let ids = list.compactMap { resolve($0.title, $0.bundleID) }
                    if ids.isEmpty { return nil }
                    if ids.count == 1 { return .app(ids[0]) }
                    return .folder(Folder(name: title, apps: ids))
                }
            }
        }.filter { !$0.isEmpty }
        return Layout(pages: pages)
    }
}
