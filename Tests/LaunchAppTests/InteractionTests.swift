import AppKit
import XCTest
@testable import LaunchApp

/// Drives LauncherModel with synthetic mouse/key input, the way InteractionView does.
final class InteractionTests: XCTestCase {
    private var model: LauncherModel!

    override func setUp() {
        let defaults = UserDefaults(suiteName: "launchapp.tests.\(UUID())")!
        let prefs = Preferences(defaults: defaults)
        prefs.settings.columns = 4
        prefs.settings.rows = 2
        model = LauncherModel(prefs: prefs, persists: false)
        model.size = CGSize(width: 1200, height: 800)
        let names = ["a", "b", "c", "d", "e", "f", "g", "h", "i"]
        model.apps = Dictionary(uniqueKeysWithValues: names.map {
            ($0, AppInfo(id: $0, url: URL(fileURLWithPath: "/Applications/\($0).app"), name: $0.uppercased(),
                         bundleID: $0, isSystem: false, isUtility: false))
        })
        model.layout = Layout(pages: [["a", "b", "c", "d", "e", "f", "g", "h"].map { .app($0) }, [.app("i")]])
    }

    private var ids: [[String]] { model.layout.pages.map { $0.map(\.id) } }
    private func center(_ slot: Int) -> CGPoint { model.metrics.iconCenter(slot: slot) }

    /// A point between two icons (left edge of a cell) — reorders instead of merging.
    private func gap(_ slot: Int) -> CGPoint {
        let c = center(slot)
        return CGPoint(x: c.x - model.metrics.cellSize.width * 0.42, y: c.y)
    }

    func testDragReordersWithinPage() {
        model.mouseDown(at: center(0), modifiers: [], clickCount: 1)
        model.mouseDragged(to: CGPoint(x: center(0).x + 20, y: center(0).y))
        model.mouseDragged(to: gap(3))
        Thread.sleep(forTimeInterval: 0.1)
        model.mouseDragged(to: CGPoint(x: gap(3).x + 1, y: gap(3).y))
        model.mouseUp(at: gap(3), modifiers: [])
        XCTAssertNil(model.drag)
        XCTAssertEqual(ids[0], ["b", "c", "d", "a", "e", "f", "g", "h"])
    }

    func testHoverOnIconMakesFolder() {
        model.mouseDown(at: center(0), modifiers: [], clickCount: 1)
        model.mouseDragged(to: CGPoint(x: center(0).x + 20, y: center(0).y))
        let target = center(2)
        model.mouseDragged(to: target)
        Thread.sleep(forTimeInterval: 0.35)
        model.mouseDragged(to: CGPoint(x: target.x + 1, y: target.y))
        XCTAssertEqual(model.mergeTargetID, "c")
        model.mouseUp(at: target, modifiers: [])
        let folder = model.layout.allItems.first { $0.isFolder }?.folder
        XCTAssertEqual(folder?.apps, ["c", "a"])
        XCTAssertFalse(model.layout.allAppIDs.contains { $0 == "a" && model.layout.item(id: "a") != nil })
    }

    func testFullPageOverflowsWhileDraggingFromNextPage() {
        model.page = 1
        model.mouseDown(at: center(0), modifiers: [], clickCount: 1)   // "i"
        model.mouseDragged(to: CGPoint(x: center(0).x + 20, y: center(0).y))
        // Hold at the left edge to flip back to page 0.
        let edge = CGPoint(x: 5, y: center(0).y)
        model.mouseDragged(to: edge)
        Thread.sleep(forTimeInterval: 0.6)
        model.mouseDragged(to: CGPoint(x: 6, y: edge.y))
        XCTAssertEqual(model.page, 0)
        Thread.sleep(forTimeInterval: 0.1)
        model.mouseDragged(to: gap(0))
        model.mouseUp(at: gap(0), modifiers: [])
        XCTAssertEqual(ids, [["i", "a", "b", "c", "d", "e", "f", "g"], ["h"]])
    }

    func testDragOutOfFolder() {
        model.layout = Layout(pages: [[.folder(Folder(id: "f", name: "F", apps: ["a", "b", "c"])), .app("d")]])
        model.openFolder("f")
        guard let fm = model.folderMetrics else { return XCTFail("no folder metrics") }
        let start = fm.iconCenter(slot: 1)   // "b"
        model.mouseDown(at: start, modifiers: [], clickCount: 1)
        model.mouseDragged(to: CGPoint(x: start.x + 20, y: start.y))
        // Far outside the panel.
        let outside = CGPoint(x: 40, y: model.size.height - 60)
        model.mouseDragged(to: outside)
        XCTAssertNil(model.openFolderID)
        model.mouseUp(at: outside, modifiers: [])
        XCTAssertEqual(model.layout.item(id: "f")?.folder?.apps, ["a", "c"])
        XCTAssertNotNil(model.layout.item(id: "b"))
    }

    func testReorderInsideFolder() {
        model.layout = Layout(pages: [[.folder(Folder(id: "f", name: "F", apps: ["a", "b", "c"]))]])
        model.openFolder("f")
        let fm = model.folderMetrics!
        model.mouseDown(at: fm.iconCenter(slot: 0), modifiers: [], clickCount: 1)
        model.mouseDragged(to: CGPoint(x: fm.iconCenter(slot: 0).x + 20, y: fm.iconCenter(slot: 0).y))
        model.mouseDragged(to: fm.iconCenter(slot: 2))
        model.mouseUp(at: fm.iconCenter(slot: 2), modifiers: [])
        XCTAssertEqual(model.layout.item(id: "f")?.folder?.apps, ["b", "c", "a"])
    }

    func testCommandClickSelectsAndBatchDragMovesBlock() {
        model.mouseDown(at: center(1), modifiers: .command, clickCount: 1)
        model.mouseUp(at: center(1), modifiers: .command)
        model.mouseDown(at: center(3), modifiers: .command, clickCount: 1)
        model.mouseUp(at: center(3), modifiers: .command)
        XCTAssertEqual(Set(model.selection), ["b", "d"])
        model.mouseDown(at: center(1), modifiers: [], clickCount: 1)
        model.mouseDragged(to: CGPoint(x: center(1).x + 20, y: center(1).y))
        model.mouseDragged(to: gap(0))
        model.mouseUp(at: gap(0), modifiers: [])
        XCTAssertEqual(ids[0], ["b", "d", "a", "c", "e", "f", "g", "h"])
    }

    func testSearchAndKeyboard() {
        model.query = "e"
        XCTAssertEqual(model.results.first, "e")
        XCTAssertEqual(model.keyboardIndex, 0)
        model.query = ""
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertTrue(model.keyDown(keyCode: 124, modifiers: [], characters: nil))
        XCTAssertEqual(model.keyboardItemID, "a")
        _ = model.keyDown(keyCode: 125, modifiers: [], characters: nil)
        XCTAssertEqual(model.keyboardItemID, "e")
        _ = model.keyDown(keyCode: 124, modifiers: .command, characters: nil)
        XCTAssertEqual(model.page, 1)
    }

    func testEscapeClosesFolderThenSearch() {
        model.layout = Layout(pages: [[.folder(Folder(id: "f", name: "F", apps: ["a", "b"]))]])
        model.openFolder("f")
        _ = model.keyDown(keyCode: 53, modifiers: [], characters: nil)
        XCTAssertNil(model.openFolderID)
    }

    func testHiddenAppsLeaveLayout() {
        model.hide(["c"])
        XCTAssertTrue(model.prefs.settings.hiddenApps.contains("c"))
    }

    func testIconsOnlyMakeRoomInGapsNotOverAnotherIcon() {
        // Drag "a" so its icon partly covers "c" (not its centre): nothing moves out of the way.
        let s = model.metrics.iconSize
        model.mouseDown(at: center(0), modifiers: [], clickCount: 1)
        model.mouseDragged(to: CGPoint(x: center(0).x + 20, y: center(0).y))
        let near = CGPoint(x: center(2).x - s * 0.4, y: center(2).y + s * 0.1)
        model.mouseDragged(to: near)
        Thread.sleep(forTimeInterval: 0.12)
        model.mouseDragged(to: CGPoint(x: near.x + 1, y: near.y))
        XCTAssertEqual(ids[0], ["a", "b", "c", "d", "e", "f", "g", "h"])
        // Resting there makes it a folder target.
        Thread.sleep(forTimeInterval: 0.3)
        model.mouseDragged(to: CGPoint(x: near.x + 2, y: near.y))
        XCTAssertEqual(model.mergeTargetID, "c")
        model.mouseUp(at: near, modifiers: [])
        XCTAssertEqual(model.layout.allItems.first { $0.isFolder }?.folder?.apps, ["c", "a"])
    }

    func testMouseWheelUpDownFlipsPages() {
        // Classic wheel: one notch down → next page.
        model.scrollWheel(dx: 0, dy: -1, precise: false, phase: [], momentum: [])
        XCTAssertEqual(model.page, 1)
        // Smooth-scrolling mouse (precise deltas, no phases), scrolling up → back.
        model.input.lastWheelFlip = .distantPast
        for _ in 0..<6 { model.scrollWheel(dx: 0, dy: 9, precise: true, phase: [], momentum: []) }
        XCTAssertEqual(model.page, 0)
    }

    func testLayoutPresetAndIconSizeKeys() {
        LayoutPreset.dense.apply(to: &model.prefs.settings)
        XCTAssertEqual(LayoutPreset.matching(model.settings), .dense)
        XCTAssertEqual(model.metrics.capacity, 60)
        let before = model.metrics.iconSize
        XCTAssertTrue(model.keyDown(keyCode: 27, modifiers: .command, characters: "-"))
        XCTAssertLessThan(model.metrics.iconSize, before)
        XCTAssertNil(LayoutPreset.matching(model.settings))
        XCTAssertTrue(model.keyDown(keyCode: 29, modifiers: .command, characters: "0"))
        XCTAssertEqual(model.settings.iconScale, 1.0)
    }

    func testClickOnPageDot() {
        let f = model.metrics.pageDotsFrame(count: 2)
        let p = CGPoint(x: f.maxX - 9, y: f.midY)
        model.mouseDown(at: p, modifiers: [], clickCount: 1)
        model.mouseUp(at: p, modifiers: [])
        XCTAssertEqual(model.page, 1)
    }
}
