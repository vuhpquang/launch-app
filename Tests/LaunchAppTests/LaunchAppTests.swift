import SQLite3
import XCTest
@testable import LaunchApp

final class LayoutTests: XCTestCase {
    private func ids(_ l: Layout) -> [[String]] { l.pages.map { $0.map(\.id) } }

    func testReflowPushesOverflowToNextPage() {
        var l = Layout(pages: [["a", "b", "c"].map { .app($0) }, [.app("d")]])
        l.reflow(capacity: 2)
        XCTAssertEqual(ids(l), [["a", "b"], ["c", "d"]])
    }

    func testReflowDropsEmptyPagesUnlessDragging() {
        var l = Layout(pages: [[.app("a")], [], [.app("b")]])
        var kept = l
        kept.reflow(capacity: 4, dropEmptyPages: false)
        XCTAssertEqual(kept.pages.count, 3)
        l.reflow(capacity: 4)
        XCTAssertEqual(ids(l), [["a"], ["b"]])
    }

    func testReconcileRemovesGoneAndAppendsNew() {
        var l = Layout(pages: [[.app("a"), .folder(Folder(id: "f", name: "F", apps: ["b", "gone"])), .app("old")]])
        l.reconcile(installed: ["a", "b", "c", "e"], capacity: 3)
        XCTAssertEqual(ids(l), [["a", "f", "c"], ["e"]])
        XCTAssertEqual(l.item(id: "f")?.folder?.apps, ["b"])
    }

    func testReconcileRemovesDuplicates() {
        var l = Layout(pages: [[.app("a"), .app("a")]])
        l.reconcile(installed: ["a"], capacity: 10)
        XCTAssertEqual(ids(l), [["a"]])
    }

    func testMoveBlock() {
        var l = Layout(pages: [["a", "b", "c", "d"].map { .app($0) }])
        l.move(["d", "c"], toPage: 0, index: 0)
        XCTAssertEqual(ids(l), [["d", "c", "a", "b"]])
    }

    func testMergeTwoAppsMakesFolderInPlace() {
        var l = Layout(pages: [["a", "b", "c"].map { .app($0) }])
        let id = l.merge(["c"], into: "a", newFolderName: "Stuff")
        XCTAssertNotNil(id)
        XCTAssertEqual(l.pages[0].count, 2)
        XCTAssertEqual(l.pages[0][0].folder?.apps, ["a", "c"])
        XCTAssertEqual(l.pages[0][0].folder?.name, "Stuff")
        XCTAssertEqual(l.pages[0][1].id, "b")
    }

    func testMergeIntoFolderAppends() {
        var l = Layout(pages: [[.folder(Folder(id: "f", name: "F", apps: ["x", "y"])), .app("a")]])
        l.merge(["a"], into: "f", newFolderName: "?")
        XCTAssertEqual(ids(l), [["f"]])
        XCTAssertEqual(l.item(id: "f")?.folder?.apps, ["x", "y", "a"])
    }

    func testFoldersCannotBeMergedIntoFolders() {
        var l = Layout(pages: [[.folder(Folder(id: "f", name: "F", apps: ["x", "y"])), .app("a")]])
        XCTAssertNil(l.merge(["f"], into: "a", newFolderName: "?"))
        XCTAssertEqual(ids(l), [["f", "a"]])
    }

    func testRemovingFromFolderDissolvesSingleAppFolder() {
        var l = Layout(pages: [[.folder(Folder(id: "f", name: "F", apps: ["x", "y"])), .app("a")]])
        let removed = l.remove(["x"])
        XCTAssertEqual(removed, [.app("x")])
        XCTAssertEqual(ids(l), [["y", "a"]])
    }

    func testMakeFolderAndDisband() {
        var l = Layout(pages: [["a", "b", "c", "d"].map { .app($0) }])
        let fid = l.makeFolder(["b", "d"], name: "N")!
        XCTAssertEqual(ids(l), [["a", fid, "c"]])
        l.disband(fid)
        XCTAssertEqual(ids(l), [["a", "b", "d", "c"]])
    }

    func testFlatIndexRoundTrip() {
        let l = Layout(pages: [[.app("a"), .app("b")], [.app("c")]])
        XCTAssertEqual(l.position(forFlatIndex: 2), ItemPosition(page: 1, index: 0))
        XCTAssertEqual(l.flatIndex(of: ItemPosition(page: 1, index: 0)), 2)
        XCTAssertEqual(l.position(forFlatIndex: 3), ItemPosition(page: 1, index: 1))
    }

    func testRepack() {
        var l = Layout(pages: [[.app("a")], [.app("b")], [.app("c")]])
        l.repack(capacity: 2)
        XCTAssertEqual(ids(l), [["a", "b"], ["c"]])
    }

    func testSortAlphabetically() {
        var l = Layout(pages: [[.app("b"), .folder(Folder(id: "f", name: "A folder", apps: ["z", "y"])), .app("c")]])
        l.sortAlphabetically(capacity: 10, name: { item in item.folder?.name ?? item.id }, appName: { $0 })
        XCTAssertEqual(ids(l), [["f", "b", "c"]])
        XCTAssertEqual(l.item(id: "f")?.folder?.apps, ["y", "z"])
    }

    func testLayoutCodableRoundTrip() throws {
        let l = Layout(pages: [[.app("a"), .folder(Folder(id: "f", name: "F", apps: ["b", "c"]))]])
        let back = try JSONDecoder().decode(Layout.self, from: JSONEncoder().encode(l))
        XCTAssertEqual(back, l)
    }
}

final class SearchTests: XCTestCase {
    func testRanking() {
        XCTAssertNotNil(Search.score(name: "Safari", query: "saf"))
        XCTAssertGreaterThan(Search.score(name: "Safari", query: "saf")!, Search.score(name: "Visual Safari", query: "saf")!)
        XCTAssertNotNil(Search.score(name: "Visual Studio Code", query: "vsc"))
        XCTAssertNotNil(Search.score(name: "Tiếng Việt", query: "tieng"))
        XCTAssertNil(Search.score(name: "Calculator", query: "co"))
        XCTAssertNotNil(Search.score(name: "Xcode", query: "xcd"))
        XCTAssertNotNil(Search.score(name: "Renamed", query: "orig", extra: ["Original"]))
    }
}

final class GeometryTests: XCTestCase {
    func testSlotsRoundTrip() {
        let m = GridMetrics(size: CGSize(width: 1512, height: 982), columns: 7, rows: 5)
        for slot in 0..<35 {
            XCTAssertEqual(m.nearestSlot(to: m.iconCenter(slot: slot)), slot)
            XCTAssertTrue(m.hitRect(slot: slot).contains(m.iconCenter(slot: slot)))
        }
        XCTAssertGreaterThan(m.iconSize, 60)
        XCTAssertLessThan(m.iconSize, 140)
    }

    func testHitRectsDoNotOverlap() {
        let m = GridMetrics(size: CGSize(width: 1440, height: 900), columns: 7, rows: 5)
        for a in 0..<35 { for b in (a + 1)..<35 { XCTAssertFalse(m.hitRect(slot: a).intersects(m.hitRect(slot: b)), "\(a) \(b)") } }
    }

    func testVerticalSlot() {
        let m = GridMetrics(size: CGSize(width: 1440, height: 900), columns: 7, rows: 5)
        let c = m.verticalIconCenter(flat: 40, scrollY: 300)
        XCTAssertEqual(m.verticalSlot(at: c, scrollY: 300), 40)
    }

    func testPageDots() {
        let m = GridMetrics(size: CGSize(width: 1440, height: 900), columns: 7, rows: 5)
        let f = m.pageDotsFrame(count: 3)
        XCTAssertEqual(m.pageDot(at: CGPoint(x: f.minX + 9, y: f.midY), count: 3), 0)
        XCTAssertEqual(m.pageDot(at: CGPoint(x: f.maxX - 9, y: f.midY), count: 3), 2)
        XCTAssertNil(m.pageDot(at: CGPoint(x: 10, y: 10), count: 3))
    }

    func testFolderSlots() {
        let m = GridMetrics(size: CGSize(width: 1440, height: 900), columns: 7, rows: 5)
        let fm = FolderMetrics(grid: m, columns: 6, rows: 3, count: 14)
        for s in 0..<14 { XCTAssertEqual(fm.nearestSlot(to: fm.iconCenter(slot: s)), s) }
        XCTAssertTrue(fm.panelRect.contains(fm.iconCenter(slot: 13)))
    }
}

final class TriggerTests: XCTestCase {
    func testPinchInAndSpread() {
        var r = PinchRecognizer()
        func ring(_ radius: Float) -> [(x: Float, y: Float)] {
            [(0.5 + radius, 0.5), (0.5 - radius, 0.5), (0.5, 0.5 + radius), (0.5, 0.5 - radius)]
        }
        XCTAssertNil(r.feed(ring(0.3)))
        XCTAssertNil(r.feed(ring(0.25)))
        XCTAssertEqual(r.feed(ring(0.15)), .pinchIn)
        XCTAssertNil(r.feed(ring(0.1)))   // fires once per gesture
        XCTAssertNil(r.feed([]))
        XCTAssertNil(r.feed(ring(0.1)))
        XCTAssertEqual(r.feed(ring(0.2)), .spread)
    }

    func testThreeFingersIgnored() {
        var r = PinchRecognizer()
        XCTAssertNil(r.feed([(0.2, 0.2), (0.8, 0.8), (0.2, 0.8)]))
        XCTAssertNil(r.feed([(0.5, 0.5), (0.51, 0.5), (0.5, 0.51)]))
    }

    func testHotCorner() {
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        XCTAssertTrue(HotCornerMonitor.isInCorner(CGPoint(x: 0, y: 899), corner: .topLeft, screens: screens))
        XCTAssertTrue(HotCornerMonitor.isInCorner(CGPoint(x: 1439, y: 0), corner: .bottomRight, screens: screens))
        XCTAssertFalse(HotCornerMonitor.isInCorner(CGPoint(x: 700, y: 0), corner: .bottomRight, screens: screens))
    }

    func testVersionCompare() {
        XCTAssertTrue(UpdateManager.isVersion("1.0.1", newerThan: "1.0.0"))
        XCTAssertFalse(UpdateManager.isVersion("1.0.0", newerThan: "1.0.0"))
        XCTAssertTrue(UpdateManager.isVersion("1.10.0", newerThan: "1.9.9"))
    }

    func testSettingsDecodeWithMissingKeys() throws {
        let s = try JSONDecoder().decode(Settings.self, from: Data(#"{"columns": 9}"#.utf8))
        XCTAssertEqual(s.columns, 9)
        XCTAssertEqual(s.rows, Settings().rows)
        XCTAssertEqual(s.hotKey, Settings().hotKey)
    }

    func testCategoryNames() {
        XCTAssertEqual(AppActions.categoryName("public.app-category.developer-tools"), "Developer Tools")
        XCTAssertEqual(AppActions.categoryName("public.app-category.puzzle-games"), "Games")
        XCTAssertNil(AppActions.categoryName("nonsense"))
    }
}

final class ImporterTests: XCTestCase {
    /// Builds a tiny database with the Launchpad schema: root 1 → page 2 → [app 3, folder 4 → page 5 → apps 6, 7].
    func testReadsPagesAndFolders() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lp-\(UUID()).db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let sql = """
        CREATE TABLE items (rowid INTEGER PRIMARY KEY, uuid VARCHAR, flags INTEGER, type INTEGER, parent_id INTEGER, ordering INTEGER);
        CREATE TABLE apps (item_id INTEGER PRIMARY KEY, title VARCHAR, bundleid VARCHAR);
        CREATE TABLE groups (item_id INTEGER PRIMARY KEY, category_id INTEGER, title VARCHAR);
        CREATE TABLE dbinfo (key VARCHAR, value VARCHAR);
        INSERT INTO dbinfo VALUES ('launchpad_root', '1');
        INSERT INTO items VALUES (1,'',0,1,0,0),(2,'',0,3,1,0),(3,'',0,4,2,1),(4,'',0,2,2,0),(5,'',0,3,4,0),(6,'',0,4,5,0),(7,'',0,4,5,1),(8,'',0,3,1,1),(9,'',0,4,8,0);
        INSERT INTO apps VALUES (3,'Safari','com.apple.Safari'),(6,'Notes','com.apple.Notes'),(7,'Gone','x.gone'),(9,'Xcode','com.apple.dt.Xcode');
        INSERT INTO groups VALUES (4,0,'Work');
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        defer { try? FileManager.default.removeItem(at: url) }

        let imported = try LaunchpadImporter.read(databaseAt: url)
        XCTAssertEqual(imported.pages.count, 2)
        XCTAssertEqual(imported.appCount, 4)

        func app(_ id: String, _ name: String) -> AppInfo {
            AppInfo(id: id, url: URL(fileURLWithPath: "/Applications/\(name).app"), name: name, bundleID: id, isSystem: false, isUtility: false)
        }
        let layout = LaunchpadImporter.layout(from: imported, apps: [
            app("com.apple.Safari", "Safari"), app("com.apple.Notes", "Notes"), app("com.apple.dt.Xcode", "Xcode"),
        ])
        // The folder lost "Gone" and kept one app, so it becomes that app.
        XCTAssertEqual(layout.pages.map { $0.map(\.id) }, [["com.apple.Notes", "com.apple.Safari"], ["com.apple.dt.Xcode"]])
    }
}
