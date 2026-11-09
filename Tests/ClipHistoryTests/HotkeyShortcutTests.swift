import Testing
import AppKit
@testable import ClipHistory

@Suite("Hotkey defaults")
struct HotkeyShortcutTests {
    @Test("defaults match the documented shortcuts")
    func defaults() {
        #expect(HotkeyShortcut.default.displayString == "⇧⌘V")
        #expect(HotkeyShortcut.pasteLatestDefault.displayString == "⌘V")
        #expect(HotkeyShortcut.pasteNextDefault.displayString == "⌃⌘V")
        #expect(HotkeyShortcut.pasteAllDefault.displayString == "⌃⌥⌘V")
        #expect(HotkeyShortcut.clearHistoryDefault.displayString == "⌃⌥⌘K")
    }

    @Test("display order is control, option, shift, command")
    func displayOrder() {
        let shortcut = HotkeyShortcut(
            keyCode: 9,
            modifiers: NSEvent.ModifierFlags([.command, .shift, .control, .option]).rawValue)
        #expect(shortcut.displayString == "⌃⌥⇧⌘V")
    }

    @Test("an unknown key code still renders")
    func unknownKeyCode() {
        #expect(HotkeyShortcut(keyCode: 200, modifiers: 0).displayString == "(200)")
    }
}
