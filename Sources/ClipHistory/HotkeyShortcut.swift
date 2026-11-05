import AppKit

struct HotkeyShortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt   // NSEvent.ModifierFlags.rawValue

    /// Opens the popup at the text cursor.
    static let `default` = HotkeyShortcut(
        keyCode: 9,       // V
        modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue
    )

    /// Pastes the most recent clip — keeps ⌘V working as a plain paste.
    static let pasteLatestDefault = HotkeyShortcut(
        keyCode: 9,       // V
        modifiers: NSEvent.ModifierFlags([.command]).rawValue
    )

    /// Steps through the history oldest → newest, one clip per press.
    static let pasteNextDefault = HotkeyShortcut(
        keyCode: 9,       // V
        modifiers: NSEvent.ModifierFlags([.command, .control]).rawValue
    )

    /// Asks for confirmation to clear the whole history.
    static let clearHistoryDefault = HotkeyShortcut(
        keyCode: 40,      // K
        modifiers: NSEvent.ModifierFlags([.command, .control, .option]).rawValue
    )

    /// Pastes every clip in the current scope in one run.
    static let pasteAllDefault = HotkeyShortcut(
        keyCode: 9,       // V
        modifiers: NSEvent.ModifierFlags([.command, .control, .option]).rawValue
    )

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers).intersection(.deviceIndependentFlagsMask)
    }

    /// Human-readable symbol string, e.g. "⌘⇧V"
    var displayString: String {
        var s = ""
        let f = modifierFlags
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option)  { s += "⌥" }
        if f.contains(.shift)   { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        s += keyCodeGlyph(keyCode)
        return s
    }
}

func keyCodeGlyph(_ code: UInt16) -> String {
    let map: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 10: "§", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O",
        32: "U", 33: "[", 34: "I", 35: "P", 36: "↩", 37: "L", 38: "J", 39: "'",
        40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋",
        96: "F5", 97: "F6", 98: "F7",  99: "F3", 100: "F8", 101: "F9",
        103: "F11", 109: "F10", 111: "F12",
        118: "F4", 120: "F2", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
    return map[code] ?? "(\(code))"
}
