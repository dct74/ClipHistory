import AppKit

/// Gives the popup's search field a real input-method path.
///
/// The panel is non-activating — our app never becomes frontmost — so no window
/// of ours can receive keystrokes; every key arrives through the CGEvent tap.
/// Feeding those events into an `NSTextInputContext` still lets the system input
/// method compose text (Chinese, Japanese, Korean), because the IME drives this
/// client through the `NSTextInputClient` callbacks instead of the responder
/// chain. Plain layouts land here too: letters arrive as `insertText`,
/// Enter/arrows/Delete/Escape as `doCommand`.
final class IMESearchBridge: NSView, NSTextInputClient {

    /// Committed text. A newline means "paste the selected clip".
    var onCommit: ((String) -> Void)?
    /// Text currently being composed; empty when composition ended.
    var onMarked: ((String) -> Void)?
    /// Movement / deletion / cancel commands from the input method.
    var onCommand: ((Selector) -> Void)?
    /// Screen rect the input method's candidate window points at.
    var anchorProvider: (() -> CGRect)?

    private var marked = ""

    override var acceptsFirstResponder: Bool { true }

    /// Returns true when the input method consumed the event.
    func feed(_ event: NSEvent) -> Bool {
        inputContext?.handleEvent(event) ?? false
    }

    // MARK: - NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = Self.plain(string)
        guard !text.isEmpty else { return }
        marked = ""
        onMarked?("")
        onCommit?(text)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = Self.plain(string)
        onMarked?(marked)
    }

    func unmarkText() {
        marked = ""
        onMarked?("")
    }

    /// Drops an in-flight composition when the popup closes, so the input method
    /// doesn't keep routing keystrokes into a hidden window.
    func cancelComposition() {
        marked = ""
        onMarked?("")
        inputContext?.discardMarkedText()
    }

    func hasMarkedText() -> Bool { !marked.isEmpty }

    func markedRange() -> NSRange {
        marked.isEmpty ? NSRange(location: NSNotFound, length: 0)
                       : NSRange(location: 0, length: marked.utf16.count)
    }

    func selectedRange() -> NSRange { NSRange(location: marked.utf16.count, length: 0) }

    func attributedSubstring(forProposedRange range: NSRange,
                             actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> CGRect {
        anchorProvider?() ?? .zero
    }

    override func doCommand(by selector: Selector) {
        onCommand?(selector)
    }

    private static func plain(_ value: Any) -> String {
        if let string = value as? String { return string }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return ""
    }
}
