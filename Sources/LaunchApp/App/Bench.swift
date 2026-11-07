// App/Bench.swift
// DEBUG only. `LAUNCHAPP_BENCH=1 LAUNCHAPP_LAYOUT_FILE=/tmp/copy.json .build/debug/LaunchApp`
// opens/closes the launcher, opens/closes a folder and drags an app and a folder around,
// timing every frame with a display link, then prints the slow frames per phase and quits.
// Point LAUNCHAPP_LAYOUT_FILE at a copy: the drags reorder the layout.

#if DEBUG
import AppKit

final class Bench: NSObject {
    private let model: LauncherModel
    private let launcher: LauncherWindowController
    private var link: CADisplayLink?
    private var stamps: [CFTimeInterval] = []
    private var phase = ""
    private var results: [(String, [CFTimeInterval])] = []

    init(model: LauncherModel, launcher: LauncherWindowController) {
        self.model = model
        self.launcher = launcher
    }

    func run() {
        Task { @MainActor in
            await sleep(Double(ProcessInfo.processInfo.environment["LAUNCHAPP_BENCH_DELAY"] ?? "") ?? 1.5)
            // The pointer sits over the launcher in real use, and where it is matters (cursor
            // updates are expensive with a customised pointer).
            if let screen = NSScreen.main {
                CGWarpMouseCursorPosition(CGPoint(x: screen.frame.midX, y: screen.frame.height * 0.08))
            }
            let only = ProcessInfo.processInfo.environment["LAUNCHAPP_BENCH_ONLY"]
            for _ in 0..<(only == nil ? 5 : 0) {
                await measure("open") { self.launcher.show() } wait: { 0.6 }
                self.launcher.dismissLauncher(launching: false)
                await sleep(0.5)
            }
            self.launcher.show()
            await sleep(0.8)
            if let page = model.layout.pages.firstIndex(where: { $0.contains(where: \.isFolder) }) {
                model.goToPage(page)
                await sleep(0.8)
                let folder = model.layout.pages[page].first(where: \.isFolder)!
                for _ in 0..<(only == "folder" ? 20 : 5) {
                    await measure("folder open") { self.model.openFolder(folder.id) } wait: { 0.5 }
                    await measure("folder close") { self.model.closeFolder() } wait: { 0.5 }
                }
                if only == "folder" { self.report(); NSApp.terminate(nil); return }
                let items = model.layout.pages[page]
                if let ai = items.firstIndex(where: { !$0.isFolder }) { await drag(slot: ai, label: "drag app") }
                if let fi = model.layout.pages[page].firstIndex(where: \.isFolder) { await drag(slot: fi, label: "drag folder") }
            }
            self.report()
            NSApp.terminate(nil)
        }
    }

    /// Carries the icon in `slot` in a loop across the page and back, at 120 Hz.
    @MainActor private func drag(slot: Int, label: String) async {
        let m = model.metrics
        let start = m.iconCenter(slot: slot)
        let g = m.gridRect
        begin(label)
        model.mouseDown(at: start, modifiers: [], clickCount: 1)
        let steps = 240
        for i in 0...steps {
            let t = Double(i) / Double(steps) * 2 * .pi
            let p = CGPoint(x: g.midX + cos(t) * g.width * 0.35, y: g.midY + sin(t) * g.height * 0.3)
            let blend = min(1, Double(i) / 20)
            model.mouseDragged(to: CGPoint(x: start.x + (p.x - start.x) * blend, y: start.y + (p.y - start.y) * blend))
            await sleep(1.0 / 120)
        }
        model.mouseUp(at: model.pointer.location, modifiers: [])
        await sleep(0.5)
        end()
    }

    @MainActor private func measure(_ label: String, _ action: () -> Void, wait: () -> Double) async {
        begin(label)
        action()
        await sleep(wait())
        end()
    }

    private func begin(_ label: String) {
        phase = label
        stamps = []
        let l = NSScreen.main!.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func end() {
        link?.invalidate()
        link = nil
        results.append((phase, stamps))
    }

    @objc private func tick(_ l: CADisplayLink) { stamps.append(l.timestamp) }

    private func report() {
        let hz = Double(NSScreen.main?.maximumFramesPerSecond ?? 60)
        let budget = 1 / hz
        print("[bench] display \(Int(hz)) Hz, frame budget \(String(format: "%.1f", budget * 1000)) ms")
        var grouped: [String: [CFTimeInterval]] = [:]
        var order: [String] = []
        for (label, s) in results {
            if grouped[label] == nil { order.append(label) }
            let gaps = zip(s.dropFirst(), s).map { $0 - $1 }
            grouped[label, default: []] += gaps
        }
        for label in order {
            let gaps = grouped[label]!.sorted()
            guard !gaps.isEmpty else { continue }
            let dropped = gaps.reduce(0) { $0 + max(0, Int(($1 / budget).rounded()) - 1) }
            let expected = gaps.reduce(0, +) / budget
            let p = { (q: Double) in gaps[min(gaps.count - 1, Int(Double(gaps.count) * q))] * 1000 }
            print(String(format: "[bench] %-13@ frames %4d  dropped %4d (%4.1f%%)  p50 %5.1f  p95 %5.1f  max %6.1f ms",
                         label as NSString, gaps.count, dropped, Double(dropped) / max(1, expected) * 100,
                         p(0.5), p(0.95), gaps.last! * 1000))
        }
    }
}

private func sleep(_ s: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
}
#endif
