import AppKit
import SwiftUI
import CoreGraphics

final class PopupWindowController {
    private var panel:          NSPanel?
    private let store:          ClipboardStore
    private let settings:       AppSettings
    private let updateChecker:  UpdateChecker
    private let popupState = PopupState()

    var onOpenMenuBarSettings: (() -> Void)?
    var onRestartApp: (() -> Void)?

    private var clickMonitor: Any?
    private var eventTap:     CFMachPort?
    private var tapSource:    CFRunLoopSource?
    private let imeBridge     = IMESearchBridge(frame: .zero)

    // MARK: - Paste hotkeys (⌘V / ⌃⌘V / ⌃⌥⌘V)

    /// How far the ⌃⌘V cycle has walked into its scope.
    private var cycleCursor = 0

    /// Bumped whenever a new paste action starts — an older paste-all chain
    /// checks it and stops, so two chains can never interleave pastes.
    private var pasteGeneration = 0

    /// The scope the running cycle walks over. Captured on the first press —
    /// otherwise the popup closing after that paste would switch the scope back
    /// to the whole history mid-cycle.
    private var cycleScope: [ClipItem] = []

    /// Deadline during which synthesized ⌘V presses must not be mistaken for
    /// real ones — otherwise each paste would re-trigger the paste-next hotkey.
    private var suppressHotkeysUntil: Date = .distantPast

    /// The session event tap and the Carbon hotkey can both report the same
    /// physical press — keep the last one from acting twice.
    private var lastCycleActionAt: Date = .distantPast

    var hotkeysSuppressed: Bool { Date() < suppressHotkeysUntil }

    private func claimPress() -> Bool {
        let now = Date.now
        guard now.timeIntervalSince(lastCycleActionAt) > 0.08 else { return false }
        lastCycleActionAt = now
        return true
    }

    init(store: ClipboardStore, settings: AppSettings, updateChecker: UpdateChecker) {
        self.store         = store
        self.settings      = settings
        self.updateChecker = updateChecker
    }

    // MARK: - Show / Hide

    func show(near anchor: CGRect) {
        pasteGeneration &+= 1
        resetPasteCycle()
        popupState.reset(keepSelection: settings.rememberScrollPosition)
        // Clamp the remembered index in case clips were trimmed/added while
        // the popup was closed, so it never points past the end of the list.
        if settings.rememberScrollPosition {
            let count = store.filtered(query: "", showImages: !settings.hideImages).count
            popupState.selectedIndex = min(popupState.selectedIndex, max(0, count - 1))
        }

        if panel == nil { buildPanel() }
        guard let panel else { return }

        panel.setFrame(frame(for: anchor, size: CGSize(width: 360, height: 420)), display: true)

        // makeKeyAndOrderFront so SwiftUI buttons inside the panel receive clicks.
        // .nonactivatingPanel guarantees our *app* is never activated, meaning
        // App A remains the active application.  Its text cursor / first-responder
        // state is preserved inside its own window and resumes the moment our
        // panel closes, which is exactly what we need before firing Cmd+V.
        panel.makeKeyAndOrderFront(nil)
        // Re-assert focus: the input method only drives a focused view.
        panel.makeFirstResponder(imeBridge)
        startEventTap()
        addClickMonitor()
    }

    /// Places the panel around `anchor` — above / below / right / left, whichever
    /// keeps it fully on screen without covering the anchor.
    private func frame(for anchor: CGRect, size: CGSize) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: anchor.midX, y: anchor.midY)) }
            ?? NSScreen.main
        let visible = (screen?.visibleFrame ?? .zero).insetBy(dx: 8, dy: 8)
        return PopupPlacement.frame(for: anchor, size: size, within: visible)
    }

    var isVisible: Bool { panel?.isVisible == true }

    /// Closes the popup only if it's actually up.
    func hideIfVisible() {
        if isVisible { hide() }
    }

    func hide() {
        popupState.confirmation = nil
        stopEventTap()
        removeClickMonitor()
        imeBridge.cancelComposition()
        // Decoded thumbnails are only needed while rows are on screen.
        store.releaseDecodedImages()
        panel?.orderOut(nil)
        // No focus restoration needed — App A never lost focus.
    }

    // MARK: - Paste

    func pasteItem(_ item: ClipItem) {
        pasteGeneration &+= 1        // any running paste-all chain stops here
        writeToPasteboard(item)

        hide()

        // Short delay so the panel finishes dismissing before Cmd+V fires.
        // App A's text field kept focus the whole time (nonactivatingPanel),
        // so no activate() call is needed — the Cmd+V lands directly into App A.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.simulateCmdV()
        }
    }

    // MARK: - Paste hotkeys

    /// Scope for the paste hotkeys: the popup's search filter while it's open,
    /// otherwise the whole history (images only if they're shown).
    private var pasteScopeItems: [ClipItem] {
        panel?.isVisible == true
            ? filteredItems
            : store.filtered(query: "", showImages: !settings.hideImages)
    }

    /// Called when the history or the active app changes — the cycle restarts
    /// from the oldest clip.
    func resetPasteCycle() {
        cycleCursor = 0
        cycleScope  = []
    }

    /// ⌘V: paste what's on the clipboard, untouched.
    ///
    /// The history stores plain strings and ≤480 px thumbnails, so rewriting the
    /// pasteboard here would silently downgrade a copied web page to plain text
    /// or a 4K screenshot to a thumbnail. Only an empty clipboard is filled from
    /// the newest clip.
    func pasteLatest() {
        guard claimPress() else { return }

        if (NSPasteboard.general.types ?? []).isEmpty,
           let newest = pasteScopeItems.last {
            pasteItem(newest)
        } else {
            pasteClipboardAsIs()
        }
    }

    /// Sends ⌘V to App A without touching the pasteboard.
    private func pasteClipboardAsIs() {
        pasteGeneration &+= 1
        hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.simulateCmdV()
        }
    }

    /// ⌃⌘V: paste the next clip in display order (oldest → newest). Stops at the
    /// end instead of wrapping — walking back round to the oldest is never what
    /// the user meant. The cycle restarts when a new clip is captured, the
    /// active app changes, or the popup opens.
    func pasteNextInOrder() {
        guard claimPress() else { return }

        if cycleScope.isEmpty { cycleScope = pasteScopeItems }
        guard cycleCursor < cycleScope.count else { return }

        let item = cycleScope[cycleCursor]
        cycleCursor += 1
        pasteItem(item)
    }

    /// ⌃⌥⌘V: paste everything in scope, oldest → newest. Consecutive text clips
    /// are joined into a single paste — pasting dozens of separate clips one
    /// keypress at a time reads as stutter. Images can't be joined (the
    /// pasteboard carries one representation per paste), so each image still
    /// gets its own paste in its chronological position.
    func pasteAllInOrder() {
        guard claimPress() else { return }
        let items = pasteScopeItems
        guard !items.isEmpty else { return }

        let runs = Self.pasteRuns(in: items)
        pasteGeneration &+= 1
        let generation = pasteGeneration
        hide()

        // Same 80 ms the single paste waits: the panel must be off screen before
        // the first ⌘V fires, otherwise the first run is swallowed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.pasteRuns(runs, from: 0, generation: generation)
        }
    }

    private func pasteRuns(_ runs: [[ClipItem]], from index: Int, generation: Int) {
        guard generation == pasteGeneration else { return }
        guard index < runs.count else { return }
        let run = runs[index]

        if run.count == 1, run[0].isImage {
            writeToPasteboard(run[0])
        } else {
            writeText(run.compactMap(\.textContent).joined())
        }
        simulateCmdV()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            self?.pasteRuns(runs, from: index + 1, generation: generation)
        }
    }

    /// Groups the scope into paste-sized runs: a run of consecutive text clips
    /// (joined into one paste) or a single image.
    private static func pasteRuns(in items: [ClipItem]) -> [[ClipItem]] {
        var runs: [[ClipItem]] = []
        var pendingText: [ClipItem] = []

        for item in items {
            if item.isImage {
                if !pendingText.isEmpty {
                    runs.append(pendingText)
                    pendingText = []
                }
                runs.append([item])
            } else {
                pendingText.append(item)
            }
        }
        if !pendingText.isEmpty { runs.append(pendingText) }
        return runs
    }

    /// Text clips are stored as plain strings only, so there is never any rich
    /// payload to strip — the plain-text setting documents that behaviour.
    private func writeToPasteboard(_ item: ClipItem) {
        switch item.content {
        case .text(let text):
            writeText(text)
        case .image(let data):
            let pb = NSPasteboard.general
            pb.clearContents()
            if let img = NSImage(data: data) { pb.writeObjects([img]) }
            store.noteOwnWrite()
        }
    }

    private func writeText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        store.noteOwnWrite()
    }

    // MARK: - Filtered items

    private var filteredItems: [ClipItem] {
        store.filtered(query: popupState.queryText,
                       showImages: !settings.hideImages)
    }

    private func selectCurrentItem() {
        let items = filteredItems
        guard items.indices.contains(popupState.selectedIndex) else { return }
        pasteItem(items[popupState.selectedIndex])
    }

    // MARK: - Panel construction

    /// A non-activating panel that can still become the key window.
    ///
    /// Key status is what the input method attaches to: without it the IME
    /// silently drops composition, so Chinese/Japanese/Korean never reaches the
    /// search field. `.nonactivatingPanel` keeps the *frontmost application*
    /// unchanged (the app the user is pasting into), which is the part that
    /// matters — `NSApp` flips back to inactive as soon as the panel is hidden.
    private func buildPanel() {
        let p = KeyablePanel(
            contentRect: .zero,
            // .nonactivatingPanel: ordering the panel front never makes our app the
            // frontmost one, so App A keeps its text cursor and stays the paste target.
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.level              = .popUpMenu
        p.isFloatingPanel    = true
        p.hidesOnDeactivate  = false
        p.backgroundColor    = .clear
        p.isOpaque           = false
        p.hasShadow          = true   // the standard macOS menu/popover drop shadow
        p.appearance         = nil    // follow the system light/dark appearance

        p.contentView = NSHostingView(rootView: PopupView(
            store:         store,
            settings:      settings,
            state:         popupState,
            updateChecker: updateChecker,
            onSelect:      { [weak self] item in self?.pasteItem(item) },
            onDismiss:     { [weak self] in self?.hide() },
            onConfirm:     { [weak self] in self?.confirmPendingAction() },
            onOpenMenuBarSettings: { [weak self] in self?.onOpenMenuBarSettings?() },
            onRestartApp:  { [weak self] in self?.onRestartApp?() }
        ))

        // The bridge never draws; it only needs to live in the window. Focus is
        // what lets the input method drive it.
        imeBridge.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        imeBridge.alphaValue = 0
        p.contentView?.addSubview(imeBridge)
        p.makeFirstResponder(imeBridge)

        imeBridge.onCommit = { [weak self] text in self?.commitInput(text) }
        imeBridge.onMarked = { [weak self] text in self?.popupState.markedText = text }
        imeBridge.onCommand = { [weak self] selector in self?.performInputCommand(selector) }
        imeBridge.anchorProvider = { [weak p] in
            // Point the input method's candidate window at the search row.
            guard let frame = p?.frame else { return .zero }
            return CGRect(x: frame.minX + 24, y: frame.maxY - 84, width: 2, height: 18)
        }

        panel = p
    }

    // MARK: - CGEvent tap (keyboard interception while popup is visible)
    //
    // Because the panel is non-activating, App A retains keyboard focus and
    // SwiftUI's onKeyPress would never fire.  We install a session-level
    // intercepting event tap instead so ALL key-down events are routed here.

    private func startEventTap() {
        stopEventTap()   // clean up any stale tap

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let mask    = CGEventMask(1 << CGEventType.keyDown.rawValue)

        let tap = CGEvent.tapCreate(
            tap:              .cgSessionEventTap,
            place:            .headInsertEventTap,
            options:          .defaultTap,          // intercepting (events can be consumed)
            eventsOfInterest: mask,
            callback: { (_, type, cgEvent, userInfo) -> Unmanaged<CGEvent>? in
                guard let userInfo else { return Unmanaged.passUnretained(cgEvent) }
                let ctrl = Unmanaged<PopupWindowController>
                    .fromOpaque(userInfo).takeUnretainedValue()
                // macOS silently disables taps that are slow to respond (e.g.
                // after sleep/wake or heavy load). Re-enable instead of letting
                // keyboard handling die for the rest of the session.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = ctrl.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return nil
                }
                return ctrl.handleKeyDown(event: cgEvent)
            },
            userInfo: selfPtr
        )

        guard let tap else { return }   // Accessibility permission not granted — degrade gracefully
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap  = tap
        tapSource = src
    }

    private func stopEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let src = tapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        eventTap  = nil
        tapSource = nil
    }

    /// Called from the CGEvent tap, which is scheduled on the main run loop.
    /// Returns nil to consume the event; returns the event to pass it through.
    private func handleKeyDown(event: CGEvent) -> Unmanaged<CGEvent>? {
        // Our own synthesized ⌘V (paste-all) can reach this tap if the popup is
        // reopened mid-chain — let it through untouched.
        if hotkeysSuppressed { return Unmanaged.passUnretained(event) }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags   = event.flags

        // A confirmation card owns the keyboard while it's up, but system
        // shortcuts (⌘Q, ⌘Tab, …) still pass through.
        if popupState.confirmation != nil {
            if flags.contains(.maskCommand) || flags.contains(.maskControl) {
                return Unmanaged.passUnretained(event)
            }
            switch keyCode {
            case 36, 76:                                  // ⏎ — confirm
                DispatchQueue.main.async { [weak self] in self?.confirmPendingAction() }
            case 53:                                      // Esc — cancel
                popupState.confirmation = nil
            default:
                break                                     // ignore the rest
            }
            return nil
        }

        // While the popup owns the keyboard, the paste hotkeys land here first.
        // Consuming them keeps the press from reaching App A as well (which
        // would paste the previous clipboard content on top of ours).
        if matches(settings.pasteLatestHotkey, keyCode: keyCode, flags: flags) {
            DispatchQueue.main.async { [weak self] in self?.pasteLatest() }
            return nil
        }
        if matches(settings.pasteNextHotkey, keyCode: keyCode, flags: flags) {
            DispatchQueue.main.async { [weak self] in self?.pasteNextInOrder() }
            return nil
        }
        if matches(settings.pasteAllHotkey, keyCode: keyCode, flags: flags) {
            DispatchQueue.main.async { [weak self] in self?.pasteAllInOrder() }
            return nil
        }

        // Always pass Cmd and Ctrl combos through so the OS / App A can handle
        // things like Cmd+Q, Cmd+Tab, Ctrl+C, etc.
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            return Unmanaged.passUnretained(event)
        }

        // Everything else goes to the input method first: that's what makes
        // Chinese/Japanese/Korean composition work, and on plain layouts it
        // arrives back as insertText / doCommand(insertNewline|moveDown|…).
        if let nsEvent = NSEvent(cgEvent: event), imeBridge.feed(nsEvent) {
            return nil
        }

        switch keyCode {
        case 53:                        // Escape
            DispatchQueue.main.async { [weak self] in self?.hide() }
            return nil

        case 126:                       // ↑ Up arrow
            DispatchQueue.main.async { [weak self] in self?.moveSelection(by: -1) }
            return nil

        case 125:                       // ↓ Down arrow
            DispatchQueue.main.async { [weak self] in self?.moveSelection(by: 1) }
            return nil

        case 36, 76:                    // Return / numpad Enter
            DispatchQueue.main.async { [weak self] in self?.selectCurrentItem() }
            return nil

        case 51:                        // Backspace / Delete
            DispatchQueue.main.async { [weak self] in self?.deleteSearchCharacter() }
            return nil

        case 123, 124:                  // ← → arrows — no meaning in popup, consume
            return nil

        default:
            // Decode the typed character (respects shift, option-accent, etc.)
            var unicodeChars = [UniChar](repeating: 0, count: 4)
            var length       = 0
            event.keyboardGetUnicodeString(maxStringLength: 4,
                                           actualStringLength: &length,
                                           unicodeString: &unicodeChars)
            guard length > 0 else { return Unmanaged.passUnretained(event) }

            let typed = String(decoding: unicodeChars.prefix(length), as: Unicode.UTF16.self)
            let printable = Self.printableCharacters(in: typed)
            guard !printable.isEmpty else { return Unmanaged.passUnretained(event) }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.popupState.searchText += printable
                self.popupState.selectedIndex = 0
            }
            return nil
        }
    }

    // MARK: - Input method callbacks

    /// Text the input method committed. A newline means "paste the selection".
    private func commitInput(_ text: String) {
        if text == "\n" || text == "\r" {
            DispatchQueue.main.async { [weak self] in self?.selectCurrentItem() }
            return
        }
        let printable = Self.printableCharacters(in: text)
        guard !printable.isEmpty else { return }
        popupState.searchText += printable
        popupState.selectedIndex = 0
    }

    private func performInputCommand(_ selector: Selector) {
        switch selector {
        case #selector(NSResponder.deleteBackward(_:)):
            deleteSearchCharacter()

        case #selector(NSResponder.insertNewline(_:)):
            DispatchQueue.main.async { [weak self] in self?.selectCurrentItem() }

        case #selector(NSResponder.cancelOperation(_:)):
            DispatchQueue.main.async { [weak self] in self?.hide() }

        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)

        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)

        default:
            break   // Tab, horizontal arrows and friends mean nothing here.
        }
    }

    /// Shared by the input-method path and the raw-key fallback so the two can
    /// never drift apart.
    private func moveSelection(by delta: Int) {
        let count = filteredItems.count
        popupState.selectedIndex = min(max(popupState.selectedIndex + delta, 0),
                                       max(count - 1, 0))
    }

    private func deleteSearchCharacter() {
        if !popupState.markedText.isEmpty {
            popupState.markedText = ""
        } else if !popupState.searchText.isEmpty {
            popupState.searchText.removeLast()
            popupState.selectedIndex = 0
        }
    }

    /// Drops control characters a key press might carry (tab, delete, …).
    private static func printableCharacters(in text: String) -> String {
        text.filter { ch in
            guard let value = ch.unicodeScalars.first?.value else { return false }
            return value >= 32 && value != 127
        }
    }

    /// Applies whatever the confirmation card is asking about.
    private func confirmPendingAction() {
        guard let confirmation = popupState.confirmation else { return }
        popupState.confirmation = nil
        switch confirmation {
        case .clearAll:       store.clearAll()
        case .delete(let id): store.remove(id: id)
        }
    }

    private func matches(_ shortcut: HotkeyShortcut, keyCode: Int, flags: CGEventFlags) -> Bool {
        guard Int(shortcut.keyCode) == keyCode else { return false }
        // Caps Lock / numeric pad must not defeat the match.
        let pressed = NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue))
            .intersection([.command, .control, .option, .shift])
        return pressed == shortcut.modifierFlags
    }

    // MARK: - Click monitor (dismiss when user clicks outside the popup)

    private func addClickMonitor() {
        removeClickMonitor()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self, let panel = self.panel else { return }
            if !panel.frame.contains(NSEvent.mouseLocation) {
                DispatchQueue.main.async { self.hide() }
            }
        }
    }

    private func removeClickMonitor() {
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil
    }

    // MARK: - Paste simulation

    private func simulateCmdV() {
        suppressHotkeysUntil = Date().addingTimeInterval(0.15)

        let src  = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        down?.flags = .maskCommand
        up?.flags   = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}

// MARK: -

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
