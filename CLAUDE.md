# LaunchApp — notes for Claude

LaunchApp is a Launchpad replacement for macOS 26+ (Swift Package, no Xcode project),
modelled on LaunchOS. Repo `vuhpquang/launch-app`, branch `main` (also the release branch —
push straight to it). Bundle ID `com.vuhpquang.launchapp`, universal binary.

## Commands

```bash
swift build / swift test          # unit + interaction tests (synthetic mouse/keys on LauncherModel)
./build.sh                        # release .app + styled DMG in build/
scripts/release.sh X.Y.Z [notes.md]          # bump, test, build, verify signer, tag, push, GitHub release
INSTALL=1 scripts/release.sh X.Y.Z notes.md  # …and replace /Applications/LaunchApp.app
LAUNCHAPP_SNAPSHOT=/tmp/x.png .build/debug/LaunchApp           # offscreen render (works with screen locked)
LAUNCHAPP_DEBUG=folder|edit|search:saf|page:1|settings:apps     # put the UI in a state
# frame-time bench (open, folder open/close, drags); drags reorder, so use a layout copy:
swift build -c release -Xswiftc -DDEBUG --build-path .build-bench
cp ~/Library/Application\ Support/LaunchApp/layout.json /tmp/l.json
LAUNCHAPP_BENCH=1 LAUNCHAPP_LAYOUT_FILE=/tmp/l.json .build-bench/release/LaunchApp --background
#   LAUNCHAPP_BENCH_ONLY=folder, LAUNCHAPP_BENCH_DELAY=5 (time to attach `xctrace record --attach`)
```

Performance notes (measured with the bench): tiles (`IconTile`) don't observe the model —
they take `TileLook` + explicit values and are `.equatable()`, so a publish elsewhere
doesn't re-evaluate every icon. Glass is lit from a known `screenFrame`, not a live
GeometryReader (that redrew every rim each animation frame). Keep AppKit text fields out of
scale animations (they re-rasterise per frame). With a customised pointer, every
`NSCursor.set()` is expensive — `LauncherHostingView` skips redundant ones.

Text fields and glass don't render in the offscreen snapshot (yellow boxes); everything else does.
`.build/debug/LaunchApp` runs without a bundle, so it uses its own defaults domain but the
**real** layout file (`~/Library/Application Support/LaunchApp/layout.json`).
Tests use `LauncherModel(prefs:, persists: false)` — never let tests touch the real file.

## Layout

- `Model/` — pure: `Layout` (pages of `.app(id)` / `.folder`), `AppCatalog` (scan + FSEvents),
  `LaunchpadImporter` (old Launchpad SQLite DB in `$(getconf DARWIN_USER_DIR)com.apple.dock.launchpad/db`),
  `Search`, `LayoutStore`.
- `Launcher/` — `GridMetrics` (all geometry; shared by drawing and hit-testing),
  `LauncherModel` (+`Input`: mouse/scroll/keys/drag state machine/context menus),
  `LauncherView` (SwiftUI drawing only), `LauncherWindowController` (window, InteractionView,
  Dock drag session).
- `Triggers/` — hotkey (Carbon), Launchpad/F4 key (CGEventTap, needs Accessibility), pinch
  (private MultitouchSupport, copied from Padlet), hot corner.
- `System/` — icons cache, wallpaper blur, app actions (open, Dock tiles, uninstall).
- `Control/` — MCP: `MCPServer` (`LaunchApp mcp`, stdio JSON-RPC, tool list) → `ControlSocket`
  (Unix socket, 0600, peer uid checked) → `ControlServer` in the app → `LauncherModel.control`
  (`ControlCommands.swift`). New tool = add to `MCPServer.tools` + `controlCommands` + the switch;
  `ControlTests` checks they match. `--background` launch arg skips showing the launcher.
- `Settings/`, `Update/` (GitHub releases self-update, copied from Padlet).

App IDs are bundle ids (or the path for duplicates/no bundle id). Settings decode every field
with a default — add new fields to `Settings.init(from:)`.

## Window

Borderless, level `dockWindow - 1` (Dock stays above, so drag-to-Dock works), all Spaces,
`autoHideMenuBar` while shown. InteractionView (on top of the NSHostingView) takes all mouse
events except the search field, the folder title and dialogs. Losing key closes the launcher.

## Signing / releases

Signed with the self-signed identity **"LaunchApp Self-Signed"** (SHA-1 `904e41a3…6c09`;
backup `~/.config/launchapp-signing/launchapp-signing.p12` + `p12-password.txt`, never commit).
The updater only installs builds from the same signer, so always release through
`scripts/release.sh`. A release = tag `vX.Y.Z`, marked Latest, `LaunchApp.dmg` attached.
Not notarized: first launch needs Privacy & Security → Open Anyway.

GitNexus can't parse Swift; don't run `npx gitnexus analyze` in this repo.
In the parent `software-team` repo, bump the pointer with `git add projects/launch-app` and commit `chore: bump launch-app submodule (LaunchApp X.Y.Z)`.
