// Triggers/Triggers.swift
// Ways to open the launcher besides the Dock icon:
//   • PinchRecognizer + TrackpadPinch — pinch thumb and three fingers together (open) or
//     apart (close), read from the private MultitouchSupport framework.
//   • HotCornerMonitor — rest the pointer in a screen corner.
//   • LaunchpadKeyTap — the Launchpad/F4 key, via a CGEvent tap (needs Accessibility).
// The global hotkey lives in GlobalHotKey.swift.

import AppKit
import ApplicationServices

// MARK: - Pinch

/// Pure recogniser: frames of touch points in, `.pinchIn` / `.spread` out.
struct PinchRecognizer {
    enum Event: Equatable { case pinchIn, spread }

    /// Fingers needed (thumb + three).
    var minFingers = 4
    var pinchRatio: Float = 0.62
    var spreadRatio: Float = 1.5

    private var startSpread: Float?
    private var fired = false

    /// Feed the normalised positions of the fingers touching right now.
    mutating func feed(_ points: [(x: Float, y: Float)]) -> Event? {
        guard points.count >= minFingers else {
            if points.count < 2 { startSpread = nil; fired = false }
            return nil
        }
        let s = Self.spread(points)
        guard let start = startSpread else {
            startSpread = s
            return nil
        }
        guard !fired, start > 0.01 else { return nil }
        let ratio = s / start
        if ratio < pinchRatio { fired = true; return .pinchIn }
        if ratio > spreadRatio { fired = true; return .spread }
        return nil
    }

    /// Mean distance of the points from their centroid.
    static func spread(_ points: [(x: Float, y: Float)]) -> Float {
        let n = Float(points.count)
        let cx = points.map(\.x).reduce(0, +) / n
        let cy = points.map(\.y).reduce(0, +) / n
        return points.map { (($0.x - cx) * ($0.x - cx) + ($0.y - cy) * ($0.y - cy)).squareRoot() }.reduce(0, +) / n
    }
}

final class TrackpadPinch: DeviceMonitorDelegate {
    private let monitor = DeviceMonitor()
    private var recognizer = PinchRecognizer()
    private let lock = NSLock()
    var onPinchIn: (() -> Void)?
    var onSpread: (() -> Void)?

    var isRunning: Bool { monitor.isRunning }

    func start() {
        monitor.delegate = self
        monitor.start()
    }

    func stop() { monitor.stop() }

    func didReceiveFingers(_ fingers: [MTFinger], timestamp: Double, device: TouchDevice) {
        guard !device.isMouse else { return }
        // States 3…5 are touching (1/2 hovering, 6/7 lifting).
        let touching = fingers.filter { (3...5).contains($0.state) }
            .map { (x: $0.normalized.position.x, y: $0.normalized.position.y) }
        lock.lock()
        let event = recognizer.feed(touching)
        lock.unlock()
        guard let event else { return }
        DispatchQueue.main.async {
            switch event {
            case .pinchIn: self.onPinchIn?()
            case .spread: self.onSpread?()
            }
        }
    }
}

// MARK: - Hot corner

final class HotCornerMonitor {
    private var timer: Timer?
    private var enteredAt: Date?
    private var armed = true
    var corner: HotCorner = .none
    var delay: TimeInterval = 0.25
    var onTrigger: (() -> Void)?

    func update(corner: HotCorner, delay: TimeInterval) {
        self.corner = corner
        self.delay = delay
        timer?.invalidate()
        timer = nil
        guard corner != .none else { return }
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    static func isInCorner(_ p: CGPoint, corner: HotCorner, screens: [CGRect], tolerance: CGFloat = 3) -> Bool {
        for f in screens {
            let left = p.x <= f.minX + tolerance, right = p.x >= f.maxX - 1 - tolerance
            let bottom = p.y <= f.minY + tolerance, top = p.y >= f.maxY - 1 - tolerance
            guard f.insetBy(dx: -1, dy: -1).contains(p) else { continue }
            switch corner {
            case .topLeft: if top && left { return true }
            case .topRight: if top && right { return true }
            case .bottomLeft: if bottom && left { return true }
            case .bottomRight: if bottom && right { return true }
            case .none: return false
            }
        }
        return false
    }

    private func tick() {
        // Never fire while a mouse button is held (dragging windows/files).
        guard NSEvent.pressedMouseButtons == 0 else { enteredAt = nil; return }
        let inside = Self.isInCorner(NSEvent.mouseLocation, corner: corner, screens: NSScreen.screens.map(\.frame))
        if !inside {
            enteredAt = nil
            armed = true
            return
        }
        guard armed else { return }
        if enteredAt == nil { enteredAt = Date() }
        if let t = enteredAt, Date().timeIntervalSince(t) >= delay {
            armed = false
            onTrigger?()
        }
    }
}

// MARK: - Launchpad / F4 key

final class LaunchpadKeyTap {
    /// 131 = the Launchpad key on Apple keyboards, 118 = F4 (when F-keys are standard keys),
    /// 160 is Mission Control (not ours).
    static let keyCodes: Set<Int64> = [131, 118]

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var onTrigger: (() -> Void)?

    static var hasPermission: Bool { AXIsProcessTrusted() }

    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard Self.hasPermission else { return false }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<LaunchpadKeyTap>.fromOpaque(info).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let mods = event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
            guard LaunchpadKeyTap.keyCodes.contains(code), mods.isEmpty else { return Unmanaged.passUnretained(event) }
            if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                DispatchQueue.main.async { me.onTrigger?() }
            }
            return nil   // swallow
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Log.error("LaunchpadKeyTap: could not create the event tap")
            return false
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }
}
