// Control/MCPServer.swift
// `LaunchApp mcp` — a Model Context Protocol server over stdio (newline-delimited
// JSON-RPC 2.0). It lets an AI assistant read and rearrange the launcher, make folders and
// change settings. Each tool call is forwarded to the running app through ControlSocket;
// the app is started in the background if it isn't running.

import AppKit

enum MCPServer {
    static let protocolVersion = "2025-06-18"

    static func run() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = Swift.readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let msg = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]])
                continue
            }
            handle(msg)
        }
        exit(0)
    }

    private static func handle(_ msg: [String: Any]) {
        let id = msg["id"]
        let method = msg["method"] as? String ?? ""
        let params = msg["params"] as? [String: Any] ?? [:]
        guard let id else { return }   // notifications (initialized, cancelled…) need no reply
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String
            reply(id, [
                "protocolVersion": asked ?? protocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "launchapp", "title": "LaunchApp", "version": version],
                "instructions": instructions,
            ])
        case "ping":
            reply(id, [:])
        case "tools/list":
            reply(id, ["tools": tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            reply(id, call(name, args))
        case "resources/list": reply(id, ["resources": []])
        case "prompts/list": reply(id, ["prompts": []])
        default:
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "method not found: \(method)"]])
        }
    }

    private static func call(_ name: String, _ args: [String: Any]) -> [String: Any] {
        guard tools.contains(where: { $0["name"] as? String == name }) else { return error("unknown tool \(name)") }
        do {
            try ensureAppRunning()
            let r = try ControlSocket.send(name, args)
            guard r["ok"] as? Bool == true else { return error(r["error"] as? String ?? "failed") }
            let result = r["result"] ?? NSNull()
            let data = try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed, .sortedKeys])
            return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]], "isError": false]
        } catch {
            return self.error("\(error)")
        }
    }

    private static func error(_ s: String) -> [String: Any] {
        ["content": [["type": "text", "text": "Error: \(s)"]], "isError": true]
    }

    /// Starts LaunchApp in the background (no launcher on screen) and waits for its socket.
    private static func ensureAppRunning() throws {
        if appsLoaded() { return }
        if (try? ControlSocket.send("status", [:], timeout: 3)) != nil { try waitForApps(); return }
        let bundle = Bundle.main.bundleURL
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = bundle.pathExtension == "app"
            ? ["-g", "-a", bundle.path, "--args", "--background"]
            : ["-g", "-b", "com.vuhpquang.launchapp", "--args", "--background"]
        try p.run()
        p.waitUntilExit()
        for _ in 0..<60 {
            usleep(200_000)
            if (try? ControlSocket.send("status", [:], timeout: 3)) != nil { try waitForApps(); return }
        }
        throw ControlError("couldn't start LaunchApp")
    }

    /// True once the app has scanned the app folders (right after launch it knows none).
    private static func appsLoaded() -> Bool {
        guard let r = try? ControlSocket.send("status", [:], timeout: 3),
              let s = r["result"] as? [String: Any], let n = s["apps"] as? Int else { return false }
        return n > 0
    }

    private static func waitForApps() throws {
        for _ in 0..<75 where !appsLoaded() { usleep(200_000) }
    }

    private static func reply(_ id: Any, _ result: Any) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        FileHandle.standardOutput.write(data + Data([10]))
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static let instructions = """
    LaunchApp is a Launchpad-style app launcher for macOS. Its layout is pages of items; an \
    item is an app or a folder of apps. Refer to apps by id (from list_apps/get_layout) or by \
    exact name, and to folders by id or name. To reorganise everything at once, read \
    get_layout + list_apps, then send the whole arrangement with set_layout (unlisted apps are \
    appended at the end). Each page holds capacity_per_page items. Changes show up live and \
    are saved automatically.
    """

    // MARK: - Tool definitions

    private static func obj(_ props: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": props, "required": required, "additionalProperties": false]
    }
    private static let str: [String: Any] = ["type": "string"]
    private static let strList: [String: Any] = ["type": "array", "items": ["type": "string"]]
    private static let readOnly: [String: Any] = ["readOnlyHint": true, "openWorldHint": false]

    static let tools: [[String: Any]] = [
        ["name": "status", "title": "LaunchApp status",
         "description": "Version, number of apps/pages/folders, grid size and launcher visibility.",
         "inputSchema": obj([:]), "annotations": readOnly],
        ["name": "list_apps", "title": "List apps",
         "description": "Installed apps with id, name, path, and where they are (page, index, folder). Optional fuzzy `query`.",
         "inputSchema": obj(["query": str, "include_hidden": ["type": "boolean"]]), "annotations": readOnly],
        ["name": "get_layout", "title": "Get layout",
         "description": "The full arrangement: pages → items (apps, and folders with their apps).",
         "inputSchema": obj([:]), "annotations": readOnly],
        ["name": "search", "title": "Search apps",
         "description": "Search apps the way the launcher's search field does.",
         "inputSchema": obj(["query": str], required: ["query"]), "annotations": readOnly],
        ["name": "set_layout", "title": "Replace layout",
         "description": """
         Replace the whole arrangement. `pages` is an array of pages; each page is an array whose items are an app \
         (id or name) or a folder object {"folder": "Name", "apps": ["id or name", ...]} (add "id" to keep an \
         existing folder's id). Pages longer than capacity_per_page overflow onto the next page. Installed apps you \
         leave out are appended at the end; unknown names are reported.
         """,
         "inputSchema": obj(["pages": ["type": "array", "items": ["type": "array", "items": [
            "anyOf": [str, obj(["folder": str, "apps": strList, "id": str], required: ["folder", "apps"])],
         ]]]], required: ["pages"])],
        ["name": "move_items", "title": "Move items",
         "description": "Move apps or folders (as one block) to `page` (0-based) at `index` (default: end). Apps inside a folder are taken out of it.",
         "inputSchema": obj(["items": strList, "page": ["type": "integer", "minimum": 0], "index": ["type": "integer", "minimum": 0]],
                            required: ["items", "page"])],
        ["name": "create_folder", "title": "Create folder",
         "description": "Make a folder named `name` from `apps` (taken from wherever they are). Placed where the first app was, or at `page`/`index`.",
         "inputSchema": obj(["name": str, "apps": strList, "page": ["type": "integer", "minimum": 0], "index": ["type": "integer", "minimum": 0]],
                            required: ["name", "apps"])],
        ["name": "update_folder", "title": "Update folder",
         "description": "Rename a folder and/or change its apps: `apps` sets the full ordered list, `add` appends, `remove` takes apps out (they go back next to the folder). A folder left with one app becomes that app.",
         "inputSchema": obj(["folder": str, "name": str, "apps": strList, "add": strList, "remove": strList], required: ["folder"])],
        ["name": "disband_folder", "title": "Disband folder",
         "description": "Replace a folder by its apps, in place.",
         "inputSchema": obj(["folder": str], required: ["folder"]), "annotations": ["destructiveHint": false]],
        ["name": "sort_alphabetically", "title": "Sort A–Z",
         "description": "Sort all items (and apps inside folders) by name.", "inputSchema": obj([:])],
        ["name": "import_launchpad_layout", "title": "Import Launchpad layout",
         "description": "Replace the layout with the one from macOS's old Launchpad database.", "inputSchema": obj([:]),
         "annotations": ["destructiveHint": true]],
        ["name": "reset_layout", "title": "Reset layout",
         "description": "Replace the layout with the default (alphabetical, utilities in a folder).", "inputSchema": obj([:]),
         "annotations": ["destructiveHint": true]],
        ["name": "hide_apps", "title": "Hide apps",
         "description": "Hide apps from the launcher (they stay installed).",
         "inputSchema": obj(["apps": strList], required: ["apps"])],
        ["name": "unhide_apps", "title": "Unhide apps",
         "description": "Show hidden apps again (they are added at the end).",
         "inputSchema": obj(["apps": strList], required: ["apps"])],
        ["name": "rename_app", "title": "Rename app",
         "description": "Set the name shown in the launcher for an app; omit `name` (or empty) to restore the original.",
         "inputSchema": obj(["app": str, "name": str], required: ["app"])],
        ["name": "get_settings", "title": "Get settings",
         "description": "All settings as JSON (keys usable with update_settings), plus the available layout presets.",
         "inputSchema": obj([:]), "annotations": readOnly],
        ["name": "update_settings", "title": "Update settings",
         "description": """
         Change settings by key, e.g. {"columns": 8, "rows": 6, "iconScale": 0.85, "showLabels": true, \
         "background": "wallpaper|glass|dark", "backgroundDim": 0.3, "scrollMode": "paged|vertical", \
         "displayMode": "fullScreen|window", "hotCorner": "none|topLeft|topRight|bottomLeft|bottomRight", \
         "folderColumns": 6, "folderRows": 3, "closeAfterLaunch": true, "liquidGlass": true, \
         "pageTransition": "slide|parallax|fade|zoom|cube|cards|none", "showInAppSwitcher": false}. Use get_settings for all keys. Values are clamped to valid ranges.
         """,
         "inputSchema": obj(["settings": ["type": "object"]], required: ["settings"])],
        ["name": "apply_layout_preset", "title": "Apply layout preset",
         "description": "Set grid size and icon size from a preset: classic (7×5), compact (8×6), dense (10×6), spacious (6×4), big (5×3).",
         "inputSchema": obj(["preset": ["type": "string", "enum": LayoutPreset.allCases.map(\.rawValue)]], required: ["preset"])],
        ["name": "open_app", "title": "Open app", "description": "Launch an app.",
         "inputSchema": obj(["app": str], required: ["app"])],
        ["name": "go_to_page", "title": "Go to page", "description": "Show page `page` (0-based) in the launcher.",
         "inputSchema": obj(["page": ["type": "integer", "minimum": 0]], required: ["page"])],
        ["name": "show_launcher", "title": "Show launcher", "description": "Open the launcher on screen.", "inputSchema": obj([:])],
        ["name": "hide_launcher", "title": "Hide launcher", "description": "Close the launcher.", "inputSchema": obj([:])],
    ]
}
