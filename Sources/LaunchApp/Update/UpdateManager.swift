// Update/UpdateManager.swift
// Self-update from GitHub Releases (github.com/vuhpquang/launch-app).
//
// Flow:
//   1. check()   — GET /repos/{repo}/releases/latest (pre-releases are excluded by GitHub),
//                  compare its tag (v1.2.3) with CFBundleShortVersionString.
//   2. install() — download the release's .dmg, mount it read-only, verify the app inside
//                  (same bundle identifier, valid code signature), stage a copy, then hand
//                  off to a tiny shell script that waits for us to quit, swaps the bundle in
//                  place and relaunches.
//
// Automatic checks run at launch and every 6 hours when enabled in Settings; with
// "Install automatically" on, a found update is installed without asking.
//
// Limitation: builds are ad-hoc signed, so the signature only proves the bundle is
// intact — not who built it — and macOS ties the Accessibility grant to the exact
// binary, so it must be re-granted after each update. A Developer ID certificate
// (TEAM_ID in build.sh) fixes both.

import AppKit
import Combine
import Foundation
import Security
import ServiceManagement

final class UpdateManager: ObservableObject {

    static let shared = UpdateManager()

    static let repo = "vuhpquang/launch-app"

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
        case downloading
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?
    @Published private(set) var releaseNotes: String = ""

    private var latestDMG: URL?
    private var timer: Timer?
    private var cancellable: AnyCancellable?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private init() {}

    // MARK: - Scheduling

    func startAutomaticChecks() {
        cancellable = Preferences.shared.$settings
            .map(\.autoCheckUpdates)
            .removeDuplicates()
            .sink { [weak self] enabled in self?.schedule(enabled) }
    }

    private func schedule(_ enabled: Bool) {
        timer?.invalidate()
        timer = nil
        guard enabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard Preferences.shared.settings.autoCheckUpdates else { return }
            self?.check(userInitiated: false)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.check(userInitiated: false)
        }
    }

    // MARK: - Check

    func check(userInitiated: Bool) {
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        state = .checking

        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("LaunchApp/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.handleCheck(data: data, response: response, error: error, userInitiated: userInitiated)
            }
        }.resume()
    }

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let body: String?
        let assets: [Asset]
    }

    private func handleCheck(data: Data?, response: URLResponse?, error: Error?, userInitiated: Bool) {
        lastChecked = Date()
        guard error == nil, let data = data,
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data) else {
            state = .failed(error?.localizedDescription ?? "Couldn't reach GitHub")
            return
        }

        let remote = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard Self.isVersion(remote, newerThan: currentVersion),
              let dmg = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) else {
            state = .upToDate
            return
        }

        latestDMG = dmg.browser_download_url
        releaseNotes = release.body ?? ""
        state = .available(version: remote)
        Log.info("UpdateManager: \(remote) available (current \(currentVersion)).")

        if !userInitiated && Preferences.shared.settings.autoInstallUpdates {
            install()
        }
    }

    /// Numeric dotted comparison; anything after "-" (pre-release suffix) is ignored.
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Install

    func install() {
        guard let url = latestDMG else { return }
        let target = Bundle.main.bundleURL
        guard target.pathExtension == "app" else {
            state = .failed("Not running from an app bundle")
            return
        }
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            state = .failed("No permission to replace \(target.path)")
            return
        }
        state = .downloading

        URLSession.shared.downloadTask(with: url) { [weak self] location, _, error in
            guard let self = self else { return }
            guard let location = location, error == nil else {
                DispatchQueue.main.async { self.state = .failed(error?.localizedDescription ?? "Download failed") }
                return
            }
            do {
                let staged = try self.stage(dmgAt: location)
                DispatchQueue.main.async { self.relaunch(replacing: target, with: staged) }
            } catch {
                DispatchQueue.main.async { self.state = .failed(error.localizedDescription) }
            }
        }.resume()
    }

    private struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Mounts the DMG, verifies the app inside and copies it to a staging folder.
    private func stage(dmgAt location: URL) throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("LaunchAppUpdate-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let dmg = work.appendingPathComponent("update.dmg")
        try fm.moveItem(at: location, to: dmg)

        let mount = work.appendingPathComponent("mnt")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try Self.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen",
                                           "-mountpoint", mount.path])
        defer { _ = try? Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }

        guard let appName = try fm.contentsOfDirectory(atPath: mount.path).first(where: { $0.hasSuffix(".app") }) else {
            throw UpdateError("The update contains no app")
        }
        let newApp = mount.appendingPathComponent(appName)

        guard Bundle(url: newApp)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError("The update is for a different app")
        }
        do {
            try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
        } catch {
            throw UpdateError("The update's signature is invalid")
        }
        guard Self.satisfiesOwnSigner(newApp) else {
            throw UpdateError("The update isn't signed by the same developer")
        }

        let staged = work.appendingPathComponent(appName)
        try Self.run("/usr/bin/ditto", [newApp.path, staged.path])
        return staged
    }

    /// When this copy is signed with a certificate (Developer ID or the self-signed release
    /// identity), the update must satisfy this copy's designated requirement — i.e. come
    /// from the same signer. Ad-hoc builds have no signer to pin, so they skip this check.
    static func satisfiesOwnSigner(_ candidate: URL) -> Bool {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return true }
        var staticMe: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess, let staticMe else { return true }

        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticMe, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess,
              let certs = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [Any],
              !certs.isEmpty else {
            return true   // ad-hoc or unsigned (development build)
        }

        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticMe, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        var other: SecStaticCode?
        guard SecStaticCodeCreateWithPath(candidate as CFURL, [], &other) == errSecSuccess,
              let other else { return false }
        return SecStaticCodeCheckValidity(other, SecCSFlags(rawValue: kSecCSCheckAllArchitectures),
                                          requirement) == errSecSuccess
    }

    /// Hands the swap to a detached script, then quits so the bundle can be replaced.
    private func relaunch(replacing target: URL, with staged: URL) {
        state = .installing
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf "$1" && /usr/bin/ditto "$2" "$1" && /usr/bin/xattr -dr com.apple.quarantine "$1" 2>/dev/null
        /usr/bin/open "$1"
        rm -rf "$(dirname "$2")"
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script, "launchapp-updater", target.path, staged.path]
        do {
            try task.run()
        } catch {
            state = .failed("Couldn't start the installer: \(error.localizedDescription)")
            return
        }
        NSApp.terminate(nil)
    }

    #if DEBUG
    /// Check → download → mount → verify → stage, without replacing anything.
    func debugDryRun(completion: @escaping (String) -> Void) {
        check(userInitiated: true)
        func poll() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                switch self.state {
                case .checking: poll()
                case .available(let v):
                    guard let url = self.latestDMG else { return completion("no dmg") }
                    URLSession.shared.downloadTask(with: url) { loc, _, err in
                        guard let loc = loc else { return completion("download failed: \(String(describing: err))") }
                        do { completion("available \(v); staged OK at \(try self.stage(dmgAt: loc).path)") }
                        catch { completion("available \(v); stage failed: \(error.localizedDescription)") }
                    }.resume()
                default: completion("state: \(self.state)")
                }
            }
        }
        poll()
    }
    #endif

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else { throw UpdateError("\(tool) failed: \(out)") }
        return out
    }
}

// MARK: - Launch at Login


enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns an error message, or nil on success.
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
