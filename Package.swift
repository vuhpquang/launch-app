// swift-tools-version:5.10
// LaunchApp — a classic Launchpad for macOS 26+.
// `swift build` / `swift test`; ./build.sh makes the signed .app and DMG.
import PackageDescription

let package = Package(
    name: "LaunchApp",
    platforms: [
        .macOS("26.0")
    ],
    targets: [
        .executableTarget(
            name: "LaunchApp",
            path: "Sources/LaunchApp",
            // Info.plist and the icon are copied into the .app by build.sh, not SPM.
            exclude: ["Resources"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "LaunchAppTests",
            dependencies: ["LaunchApp"],
            path: "Tests/LaunchAppTests"
        ),
    ]
)
