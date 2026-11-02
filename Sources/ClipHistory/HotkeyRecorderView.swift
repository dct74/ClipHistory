import AppKit
import SwiftUI

// MARK: - AppKit recorder view

final class HotkeyRecorderNSView: NSView {
    var hotkey: HotkeyShortcut { didSet { needsDisplay = true } }
    var onChanged: (HotkeyShortcut) -> Void
    /// Rejects combinations that are already bound (returns false → beep).
    var validate: ((HotkeyShortcut) -> Bool)?

    private var isRecording = false { didSet { needsDisplay = true } }

    init(hotkey: HotkeyShortcut, onChanged: @escaping (HotkeyShortcut) -> Void) {
        self.hotkey = hotkey
        self.onChanged = onChanged
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - First responder

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        isRecording = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        if isRecording { window?.makeFirstResponder(nil) }
        else            { window?.makeFirstResponder(self) }
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }

        let mods    = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let keyCode = event.keyCode

        // Escape cancels recording without saving
        if keyCode == 53 { window?.makeFirstResponder(nil); return }

        // Require at least one real modifier (Cmd / Ctrl / Opt)
        guard mods.contains(.command) || mods.contains(.control) || mods.contains(.option) else { return }

        let newHotkey = HotkeyShortcut(keyCode: keyCode, modifiers: mods.rawValue)
        if let validate, !validate(newHotkey) {
            NSSound.beep()
            return
        }
        hotkey = newHotkey
        onChanged(newHotkey)
        window?.makeFirstResponder(nil)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)

        (isRecording
            ? NSColor.controlAccentColor.withAlphaComponent(0.12)
            : NSColor.controlBackgroundColor.withAlphaComponent(0.82)
        ).setFill()
        path.fill()

        (isRecording
            ? NSColor.controlAccentColor.withAlphaComponent(0.70)
            : NSColor.separatorColor.withAlphaComponent(0.70)
        ).setStroke()
        path.lineWidth = 1
        path.stroke()

        let label = isRecording ? L10n.s("Type shortcut…", "请按下组合键…") : hotkey.displayString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: isRecording ? NSColor.controlAccentColor : NSColor.labelColor,
        ]
        let str = NSAttributedString(string: label, attributes: attrs)
        let sz  = str.size()
        str.draw(at: NSPoint(x: (bounds.width - sz.width) / 2,
                             y: (bounds.height - sz.height) / 2))
    }
}

// MARK: - SwiftUI wrapper

struct HotkeyRecorder: NSViewRepresentable {
    @Binding var hotkey: HotkeyShortcut
    var validate: ((HotkeyShortcut) -> Bool)? = nil

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let view = HotkeyRecorderNSView(hotkey: hotkey) { hotkey = $0 }
        view.validate = validate
        return view
    }

    func updateNSView(_ view: HotkeyRecorderNSView, context: Context) {
        view.hotkey    = hotkey
        view.validate  = validate
        view.onChanged = { hotkey = $0 }
    }
}
