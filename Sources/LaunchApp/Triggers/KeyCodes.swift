// Triggers/KeyCodes.swift
// Maps between virtual key codes and the key names stored in a keystroke action.
// Named keys ("←", "F5", "Space"…) are fixed; characters come from the current keyboard
// layout, so a recorded "z" on AZERTY posts the key that types "z" there.

import AppKit
import Carbon.HIToolbox

enum KeyCodes {

    /// Keys that don't type a character, by display name.
    static let named: [(name: String, code: CGKeyCode)] = [
        ("↩", 36), ("⇥", 48), ("Space", 49), ("⌫", 51), ("⎋", 53), ("⌦", 117),
        ("←", 123), ("→", 124), ("↓", 125), ("↑", 126),
        ("Home", 115), ("End", 119), ("PgUp", 116), ("PgDn", 121),
        ("F1", 122), ("F2", 120), ("F3", 99), ("F4", 118), ("F5", 96), ("F6", 97),
        ("F7", 98), ("F8", 100), ("F9", 101), ("F10", 109), ("F11", 103), ("F12", 111),
        ("F13", 105), ("F14", 107), ("F15", 113), ("F16", 106), ("F17", 64), ("F18", 79),
        ("F19", 80), ("F20", 90),
    ]

    /// Name to store for a key code: a named key, else the character it types (lowercased).
    static func name(for code: CGKeyCode) -> String? {
        if let named = named.first(where: { $0.code == code }) { return named.name }
        return character(for: code)?.lowercased()
    }

    /// Key code to post for a stored key name.
    static func code(for name: String) -> CGKeyCode? {
        if let named = named.first(where: { $0.name == name }) { return named.code }
        let wanted = name.lowercased()
        return characterMap()[wanted]
    }

    /// "⌃⌥⇧⌘T" — modifiers in macOS menu order, then the key.
    static func display(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + (key.count == 1 ? key.uppercased() : key)
    }

    // MARK: - Layout

    private static var cachedMap: [String: CGKeyCode]?
    private static var cachedLayoutID: String?

    /// character → key code for the current layout (rebuilt when the layout changes).
    private static func characterMap() -> [String: CGKeyCode] {
        let id = currentLayoutID()
        if let map = cachedMap, id == cachedLayoutID { return map }
        var map: [String: CGKeyCode] = [:]
        for code in CGKeyCode(0)..<CGKeyCode(128) where !named.contains(where: { $0.code == code }) {
            if let c = character(for: code)?.lowercased(), map[c] == nil { map[c] = code }
        }
        // Fallback for when no layout data is available (e.g. tests): US ANSI letters.
        if map.isEmpty { map = usANSI }
        cachedMap = map
        cachedLayoutID = id
        return map
    }

    private static func currentLayoutID() -> String {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    /// The character a key types with no modifiers on the current layout.
    private static func character(for code: CGKeyCode) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return usANSI.first(where: { $0.value == code })?.key
        }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: length)
        guard let scalar = s.unicodeScalars.first, !CharacterSet.controlCharacters.contains(scalar),
              !CharacterSet.whitespaces.contains(scalar) else { return nil }
        return s
    }

    private static let usANSI: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
        "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
        "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
    ]
}
