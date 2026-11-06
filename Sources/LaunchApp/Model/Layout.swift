// Model/Layout.swift
// The arrangement of the launcher: pages of items, where an item is an app or a folder.
// Everything here is pure value logic (no AppKit) so it can be unit-tested.
//
// Apps are referred to by `AppID` (bundle identifier when unique, else the bundle path —
// see AppCatalog). A page holds at most `capacity` items; `reflow` pushes overflow onto
// the next page, the way Launchpad does when you drop an icon onto a full page.

import Foundation

typealias AppID = String

struct Folder: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    /// Apps in the folder, in order. Folder pages are derived from this list.
    var apps: [AppID]

    init(id: String = "folder:" + UUID().uuidString, name: String, apps: [AppID]) {
        self.id = id
        self.name = name
        self.apps = apps
    }
}

enum LayoutItem: Codable, Hashable, Identifiable {
    case app(AppID)
    case folder(Folder)

    var id: String {
        switch self {
        case .app(let id): return id
        case .folder(let f): return f.id
        }
    }

    var isFolder: Bool { if case .folder = self { return true } else { return false } }

    /// The apps this item stands for (one for an app, all of them for a folder).
    var appIDs: [AppID] {
        switch self {
        case .app(let id): return [id]
        case .folder(let f): return f.apps
        }
    }

    var folder: Folder? { if case .folder(let f) = self { return f } else { return nil } }
}

struct ItemPosition: Equatable {
    var page: Int
    var index: Int
}

struct Layout: Codable, Equatable {
    var pages: [[LayoutItem]]

    init(pages: [[LayoutItem]] = [[]]) {
        self.pages = pages.isEmpty ? [[]] : pages
    }

    static let empty = Layout()

    // MARK: - Queries

    var allItems: [LayoutItem] { pages.flatMap { $0 } }

    var allAppIDs: [AppID] { allItems.flatMap(\.appIDs) }

    func position(of itemID: String) -> ItemPosition? {
        for (p, page) in pages.enumerated() {
            if let i = page.firstIndex(where: { $0.id == itemID }) { return ItemPosition(page: p, index: i) }
        }
        return nil
    }

    func item(id: String) -> LayoutItem? {
        position(of: id).map { pages[$0.page][$0.index] }
    }

    /// The folder holding `appID`, if it is inside one.
    func folderContaining(_ appID: AppID) -> Folder? {
        for item in allItems { if let f = item.folder, f.apps.contains(appID) { return f } }
        return nil
    }

    // MARK: - Reconcile with installed apps

    /// Drops apps that are gone (or hidden) and appends newly installed ones at the end.
    /// `installed` is in the order new apps should be appended (alphabetical).
    mutating func reconcile(installed: [AppID], capacity: Int) {
        let present = Set(installed)
        var seen = Set<AppID>()
        pages = pages.map { page in
            page.compactMap { item -> LayoutItem? in
                switch item {
                case .app(let id):
                    guard present.contains(id), seen.insert(id).inserted else { return nil }
                    return item
                case .folder(var f):
                    f.apps = f.apps.filter { present.contains($0) && seen.insert($0).inserted }
                    if f.apps.isEmpty { return nil }
                    return .folder(f)
                }
            }
        }
        let missing = installed.filter { !seen.contains($0) }
        if !missing.isEmpty {
            if pages.isEmpty { pages = [[]] }
            pages[pages.count - 1].append(contentsOf: missing.map { .app($0) })
        }
        reflow(capacity: capacity)
    }

    // MARK: - Normalising

    /// Moves overflow onto following pages and drops empty pages (keeping at least one).
    /// While dragging, empty pages are kept so page numbers don't shift under the pointer.
    mutating func reflow(capacity: Int, dropEmptyPages: Bool = true) {
        let cap = max(1, capacity)
        var p = 0
        while p < pages.count {
            if pages[p].count > cap {
                let overflow = Array(pages[p][cap...])
                pages[p].removeSubrange(cap...)
                if p + 1 < pages.count {
                    pages[p + 1].insert(contentsOf: overflow, at: 0)
                } else {
                    pages.append(overflow)
                }
            }
            p += 1
        }
        if dropEmptyPages { pages = pages.filter { !$0.isEmpty } }
        if pages.isEmpty { pages = [[]] }
    }

    /// Pages laid end to end and cut every `capacity` items (used when the grid size changes).
    mutating func repack(capacity: Int) {
        let cap = max(1, capacity)
        let items = allItems
        pages = stride(from: 0, to: items.count, by: cap).map { Array(items[$0..<min($0 + cap, items.count)]) }
        if pages.isEmpty { pages = [[]] }
    }

    // MARK: - Editing

    /// Removes items (apps anywhere — including inside folders — or whole folders) and
    /// returns them in the order given. A folder left with one app turns back into that app.
    @discardableResult
    mutating func remove(_ ids: [String]) -> [LayoutItem] {
        var removed: [String: LayoutItem] = [:]
        let wanted = Set(ids)
        for p in pages.indices {
            var newPage: [LayoutItem] = []
            for item in pages[p] {
                if wanted.contains(item.id) {
                    removed[item.id] = item
                    continue
                }
                if case .folder(var f) = item {
                    let hit = f.apps.filter { wanted.contains($0) }
                    if !hit.isEmpty {
                        hit.forEach { removed[$0] = .app($0) }
                        f.apps.removeAll { wanted.contains($0) }
                        if f.apps.isEmpty { continue }
                        newPage.append(f.apps.count == 1 ? .app(f.apps[0]) : .folder(f))
                        continue
                    }
                }
                newPage.append(item)
            }
            pages[p] = newPage
        }
        return ids.compactMap { removed[$0] }
    }

    /// Inserts items on `page` at `index` (clamped). Creates the page if it is one past the end.
    mutating func insert(_ items: [LayoutItem], page: Int, index: Int) {
        while pages.count <= page { pages.append([]) }
        let i = min(max(0, index), pages[page].count)
        pages[page].insert(contentsOf: items, at: i)
    }

    /// Moves items (as one block) to a position. Removing happens first, so `index` refers
    /// to the page as it looks without the moved items.
    mutating func move(_ ids: [String], toPage page: Int, index: Int) {
        let items = remove(ids)
        guard !items.isEmpty else { return }
        insert(items, page: page, index: index)
    }

    /// Drops `appIDs` onto `targetID`: adds them to a folder, or makes a new folder out of
    /// the target app and them (in its place). Returns the folder's id.
    @discardableResult
    mutating func merge(_ appIDs: [AppID], into targetID: String, newFolderName: String) -> String? {
        let moving = appIDs.filter { $0 != targetID }
        guard !moving.isEmpty, let target = item(id: targetID) else { return nil }
        // Only apps can go into folders.
        guard moving.allSatisfy({ item(id: $0).map { !$0.isFolder } ?? (folderContaining($0) != nil) }) else { return nil }
        remove(moving)
        guard let pos = position(of: targetID) else { return nil }
        switch target {
        case .folder(var f):
            f.apps.append(contentsOf: moving)
            pages[pos.page][pos.index] = .folder(f)
            return f.id
        case .app(let id):
            let f = Folder(name: newFolderName, apps: [id] + moving)
            pages[pos.page][pos.index] = .folder(f)
            return f.id
        }
    }

    /// Makes a new folder from `appIDs`, placed where the first of them was.
    @discardableResult
    mutating func makeFolder(_ appIDs: [AppID], name: String) -> String? {
        guard let first = appIDs.first else { return nil }
        let anchor = position(of: first)
            ?? folderContaining(first).flatMap { position(of: $0.id) }
            ?? ItemPosition(page: max(0, pages.count - 1), index: pages.last?.count ?? 0)
        let before = pages[anchor.page].prefix(anchor.index).filter { item in
            !appIDs.contains(item.id)
        }.count
        remove(appIDs)
        let f = Folder(name: name, apps: appIDs)
        insert([.folder(f)], page: min(anchor.page, pages.count), index: before)
        return f.id
    }

    mutating func updateFolder(_ id: String, _ change: (inout Folder) -> Void) {
        guard let pos = position(of: id), case .folder(var f) = pages[pos.page][pos.index] else { return }
        change(&f)
        if f.apps.isEmpty {
            pages[pos.page].remove(at: pos.index)
        } else if f.apps.count == 1 {
            pages[pos.page][pos.index] = .app(f.apps[0])
        } else {
            pages[pos.page][pos.index] = .folder(f)
        }
    }

    /// Replaces a folder by its apps, in place.
    mutating func disband(_ folderID: String) {
        guard let pos = position(of: folderID), let f = pages[pos.page][pos.index].folder else { return }
        pages[pos.page].replaceSubrange(pos.index...pos.index, with: f.apps.map { .app($0) })
    }

    /// Sorts everything by `name`; folders keep their contents but are sorted too.
    mutating func sortAlphabetically(capacity: Int, name: (LayoutItem) -> String, appName: (AppID) -> String) {
        var items = allItems.map { item -> LayoutItem in
            guard case .folder(var f) = item else { return item }
            f.apps.sort { appName($0).localizedStandardCompare(appName($1)) == .orderedAscending }
            return .folder(f)
        }
        items.sort { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
        pages = [items]
        reflow(capacity: capacity)
    }

    /// Flat index (pages laid end to end) ↔ position. Used by the vertical scroll view.
    func flatIndex(of pos: ItemPosition) -> Int {
        pages.prefix(pos.page).reduce(0) { $0 + $1.count } + pos.index
    }

    func position(forFlatIndex flat: Int) -> ItemPosition {
        var remaining = max(0, flat)
        for (p, page) in pages.enumerated() {
            if remaining <= page.count && (remaining < page.count || p == pages.count - 1) {
                return ItemPosition(page: p, index: remaining)
            }
            remaining -= page.count
        }
        return ItemPosition(page: max(0, pages.count - 1), index: pages.last?.count ?? 0)
    }
}
