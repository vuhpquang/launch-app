// Triggers/GlobalHotKey.swift
// One system-wide hotkey (Carbon RegisterEventHotKey — works without extra permissions and
// while other apps are in front). Used for "Show LaunchApp".

import AppKit
import Carbon.HIToolbox

/// A key + modifiers, as stored in settings ("p" + ⌃⌥⌘).
struct KeyCombo: Codable, Equatable {
    var key: String
    var modifiers: UInt

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }
    var display: String { KeyCodes.display(key: key, modifiers: flags) }
}

final class GlobalHotKey {

    static let shared = GlobalHotKey()

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?
    /// Paused while a shortcut recorder is listening, so pressing the combo records it.
    var paused = false

    private init() {}

    /// Registers `combo` (replacing any previous one); nil just unregisters.
    @discardableResult
    func register(_ combo: KeyCombo?, action: @escaping () -> Void) -> Bool {
        unregister()
        guard let combo, let code = KeyCodes.code(for: combo.key) else { return combo == nil }
        self.action = action
        installHandlerIfNeeded()

        var carbon: UInt32 = 0
        let flags = combo.flags
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }

        let id = EventHotKeyID(signature: OSType(0x4C4E_4348), id: 1)   // 'LNCH'
        let status = RegisterEventHotKey(UInt32(code), carbon, id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            Log.error("GlobalHotKey: could not register \(combo.display) (\(status)) — taken by another app?")
            ref = nil
            return false
        }
        return true
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            let hotKey = GlobalHotKey.shared
            if !hotKey.paused { DispatchQueue.main.async { hotKey.action?() } }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}
