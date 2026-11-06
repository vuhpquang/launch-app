// Triggers/DeviceMonitor.swift (shared with Padlet)
// Registers a touch-frame callback on every multitouch device and forwards frames.
//
// Note: MTDeviceStart takes TWO arguments (device, runMode). Calling it with one was
// undefined behaviour that once corrupted the trackpad state.

import Foundation

protocol DeviceMonitorDelegate: AnyObject {
    /// Called on the multitouch thread for every frame. `fingers` is empty on the
    /// frame(s) sent when the last finger lifts.
    func didReceiveFingers(_ fingers: [MTFinger], timestamp: Double, device: TouchDevice)
}

// MARK: - State shared with the C callback

private weak var _activeMonitor: DeviceMonitor?

/// Written in start()/stop() while delivery is off; read from the callback thread.
private var _devices: [MTDevice: TouchDevice] = [:]
/// Guards _devices/_activeMonitor: they're replaced on the main thread while the callback reads them.
private let _lock = NSLock()

/// MultitouchSupport family IDs reported by Magic Mouse hardware.
private let magicMouseFamilyIDs: Set<Int32> = [112, 113]

// MARK: - DeviceMonitor

final class DeviceMonitor {

    weak var delegate: DeviceMonitorDelegate?
    private(set) var isRunning = false

    /// Trackpads (not mice) currently being monitored.
    var trackpads: [TouchDevice] { _devices.values.filter { !$0.isMouse } }

    func start() {
        let fw = MultitouchFramework.shared
        guard fw.isAvailable else {
            Log.error("DeviceMonitor: MultitouchSupport not available — gestures disabled.")
            return
        }
        guard !isRunning else { return }
        guard let list = fw.MTDeviceCreateList?() else {
            Log.error("DeviceMonitor: MTDeviceCreateList returned nil.")
            return
        }

        var devices: [MTDevice: TouchDevice] = [:]
        for i in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let handle = UInt(bitPattern: raw)
            var family: Int32 = 0
            _ = fw.MTDeviceGetFamilyID?(handle, &family)
            var deviceID: UInt64 = 0
            _ = fw.MTDeviceGetDeviceID?(handle, &deviceID)
            devices[handle] = TouchDevice(handle: handle, deviceID: deviceID, familyID: family,
                                          isMouse: magicMouseFamilyIDs.contains(family))
        }
        _lock.lock()
        _devices = devices
        _activeMonitor = self
        _lock.unlock()

        for device in devices.values {
            fw.MTRegisterContactFrameCallback?(device.handle, deviceTouchCallback)
            fw.MTDeviceStart?(device.handle, 0)
            Log.info("DeviceMonitor: started device family \(device.familyID)\(device.isMouse ? " (mouse)" : "") id \(device.deviceID)")
        }
        isRunning = !devices.isEmpty
    }

    func stop() {
        let fw = MultitouchFramework.shared
        if fw.isAvailable {
            for handle in _devices.keys { fw.MTDeviceStop?(handle, 0) }
        }
        _lock.lock()
        _activeMonitor = nil
        _devices = [:]
        _lock.unlock()
        isRunning = false
        Log.info("DeviceMonitor: stopped.")
    }
}

// MARK: - C callback

private let deviceTouchCallback: MTContactFrameCallback = { handle, fingerData, fingerCount, timestamp, _ in
    _lock.lock()
    let monitor = _activeMonitor, device = _devices[handle]
    _lock.unlock()
    guard let monitor, let device else { return }
    guard fingerCount > 0 else {
        monitor.delegate?.didReceiveFingers([], timestamp: timestamp, device: device)
        return
    }
    let ptr = fingerData.assumingMemoryBound(to: MTFinger.self)
    let fingers = Array(UnsafeBufferPointer(start: ptr, count: Int(fingerCount)))
    monitor.delegate?.didReceiveFingers(fingers, timestamp: timestamp, device: device)
}
