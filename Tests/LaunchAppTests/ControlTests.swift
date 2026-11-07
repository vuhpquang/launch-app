import XCTest
@testable import LaunchApp

/// The commands the MCP server sends, run straight against a model.
final class ControlTests: XCTestCase {
    private var model: LauncherModel!

    override func setUp() {
        let prefs = Preferences(defaults: UserDefaults(suiteName: "launchapp.control.\(UUID())")!)
        prefs.settings.columns = 4
        prefs.settings.rows = 2
        model = LauncherModel(prefs: prefs, persists: false)
        let names = ["Safari", "Notes", "Mail", "Xcode", "Figma", "Slack"]
        model.apps = Dictionary(uniqueKeysWithValues: names.map {
            ("com.x.\($0.lowercased())", AppInfo(id: "com.x.\($0.lowercased())", url: URL(fileURLWithPath: "/Applications/\($0).app"),
                                                name: $0, bundleID: "com.x.\($0.lowercased())", isSystem: false, isUtility: false))
        })
        model.layout = Layout(pages: [names.map { .app("com.x.\($0.lowercased())") }])
    }

    private var flat: [String] { model.layout.pages.flatMap { $0.map { model.name(of: $0) } } }

    func testCreateFolderByNameAndUpdate() throws {
        let r = try model.control("create_folder", ["name": "Design", "apps": ["Figma", "com.x.slack"]]) as! [String: Any]
        let fid = r["folder_id"] as! String
        XCTAssertEqual(model.layout.item(id: fid)?.folder?.apps, ["com.x.figma", "com.x.slack"])
        _ = try model.control("update_folder", ["folder": "design", "name": "Work", "add": ["Mail"], "remove": ["Slack"]])
        XCTAssertEqual(model.layout.item(id: fid)?.folder?.name, "Work")
        XCTAssertEqual(model.layout.item(id: fid)?.folder?.apps, ["com.x.figma", "com.x.mail"])
        XCTAssertNotNil(model.layout.position(of: "com.x.slack"))
        _ = try model.control("disband_folder", ["folder": "Work"])
        XCTAssertEqual(Set(model.layout.allAppIDs).count, 6)
        XCTAssertFalse(model.layout.allItems.contains(where: \.isFolder))
    }

    func testSetLayoutAppendsUnlistedAndReportsUnknown() throws {
        let r = try model.control("set_layout", ["pages": [["Xcode", ["folder": "Web", "apps": ["Safari", "Mail"]], "Nope"]]]) as! [String: Any]
        XCTAssertEqual(r["unknown_apps"] as? [String], ["Nope"])
        XCTAssertEqual(flat, ["Xcode", "Web", "Figma", "Notes", "Slack"])
        XCTAssertEqual(model.layout.allAppIDs.count, 6)
    }

    func testMoveItemsAcrossPagesAndOutOfFolder() throws {
        _ = try model.control("create_folder", ["name": "F", "apps": ["Safari", "Notes"]])
        _ = try model.control("move_items", ["items": ["Notes"], "page": 1, "index": 0])
        XCTAssertEqual(model.layout.pages.count, 2)
        XCTAssertEqual(model.layout.pages[1].first?.id, "com.x.notes")
        XCTAssertEqual(model.layout.item(id: "com.x.safari")?.isFolder, false) // one-app folder dissolved
    }

    func testSettingsUpdateValidatesAndClamps() throws {
        XCTAssertThrowsError(try model.control("update_settings", ["settings": ["colums": 5]]))
        _ = try model.control("update_settings", ["settings": ["columns": 40, "iconScale": 0.8, "background": "dark"]])
        XCTAssertEqual(model.settings.columns, 12)
        XCTAssertEqual(model.settings.iconScale, 0.8)
        XCTAssertEqual(model.settings.background, .dark)
        _ = try model.control("apply_layout_preset", ["preset": "spacious"])
        XCTAssertEqual(model.settings.columns, 6)
        XCTAssertEqual(model.settings.rows, 4)
    }

    func testHideRenameAndSearch() throws {
        _ = try model.control("hide_apps", ["apps": ["Slack"]])
        XCTAssertTrue(model.settings.hiddenApps.contains("com.x.slack"))
        _ = try model.control("rename_app", ["app": "Xcode", "name": "IDE"])
        let found = try model.control("search", ["query": "ide"]) as! [[String: Any]]
        XCTAssertEqual(found.first?["id"] as? String, "com.x.xcode")
        _ = try model.control("unhide_apps", ["apps": ["Slack"]])
        XCTAssertFalse(model.settings.hiddenApps.contains("com.x.slack"))
    }

    func testMCPToolsMatchCommands() {
        let names = Set(MCPServer.tools.compactMap { $0["name"] as? String })
        XCTAssertTrue(Set(LauncherModel.controlCommands).isSubset(of: names))
        XCTAssertTrue(names.subtracting(LauncherModel.controlCommands).isSubset(of: ["show_launcher", "hide_launcher"]))
        for t in MCPServer.tools { XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: t)) }
    }
}
