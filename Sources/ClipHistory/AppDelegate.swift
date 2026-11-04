import AppKit
import Carbon.HIToolbox
import UserNotifications
import SwiftUI




private func clipHistoryHotkeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData, let event else { return noErr }

    var hotkeyID = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &hotkeyID)
    guard status == noErr else { return noErr }

    let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
    delegate.handleHotkey(id: hotkeyID.id)
    return noErr
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {

    // MARK: - Core objects

    private var settings:       AppSettings!
    private var store:          ClipboardStore!
    private var popup:          PopupWindowController!
    private var updateChecker:  UpdateChecker!

    // MARK: - UI

    private var statusItem:       NSStatusItem?
    private var hotkeyHintItem:   NSMenuItem?   // updated live when hotkey changes
    private var settingsWindow:   NSWindow?
    private var onboardingWindow: NSWindow?
    private var onboardingDelegate = OnboardingWindowDelegate()

    // MARK: - Background work

    private var hotkeyRefs:          [UInt32: EventHotKeyRef] = [:]
    private var eventHandlerRef:     EventHandlerRef?
    private var clipboardTimer:      Timer?
    private var lastFrontmostSource: SourceApp?   // updated on every app-switch
    private var lastPasteboardChangeCount = NSPasteboard.general.changeCount
    private var visibilityObservation: NSKeyValueObservation?
    private var policyTimer: Timer?
    private var isInFallbackMode = false
    private var suppressVisibilitySync = false

    private static let popupHotkeyID:     UInt32 = 1
    private static let pasteLatestHotkeyID: UInt32 = 2
    private static let pasteNextHotkeyID: UInt32 = 3
    private static let pasteAllHotkeyID:  UInt32 = 4

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        settings      = AppSettings()
        store         = ClipboardStore(maxCount: settings.maxItems)
        updateChecker = UpdateChecker()
        popup         = PopupWindowController(store: store, settings: settings, updateChecker: updateChecker)

        // Wire setting-change callbacks
        settings.onHotkeysChanged  = { [weak self] in self?.reRegisterHotkeys() }
        settings.onMaxItemsChanged = { [weak self] n  in self?.store.updateMaxCount(n) }
        store.onItemCaptured       = { [weak self] in self?.popup.resetPasteCycle() }

        setupMenuBar()
        startFrontmostAppTracking()
        startClipboardMonitoring()
        requestAccessibilityAndRegisterHotkey()
        showOnboardingIfNeeded()

        // Check for updates on every launch
        updateChecker.checkForUpdate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardTimer?.invalidate()
        policyTimer?.invalidate()
        store.flushNow()          // the 1 s debounce would otherwise drop the last clip
        unregisterHotkeys()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    // MARK: - Menu bar

    private func setupMenuBar() {
        installStatusItem()

        // The menu bar icon is owned by macOS: System Settings → Menu Bar keeps a
        // per-app "allow" list. No public API exposes it, so the state is polled
        // and mirrored — a flip in the pane hides/shows the item within a couple
        // of seconds, like native menu bar extras. We never remove the item.
        visibilityObservation = statusItem?.observe(\.isVisible, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.settings.showMenuBarIcon = item.isVisible
                self.refreshMenuBarIconState()
            }
        }

        popup.onOpenMenuBarSettings = {
            if let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
        popup.onRestartApp = { [weak self] in self?.relaunchApp() }

        policyTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.syncWithSystemMenuBarPolicy()
        }
        syncWithSystemMenuBarPolicy()
    }

    private func installStatusItem() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = .clipHistoryMenuBar()
        // Stable identity: this is what the system persists visibility under.
        item.autosaveName = "ClipHistoryMenuBarItem"

        let menu = NSMenu()
        menu.delegate = self

        let hint = NSMenuItem(title: hintTitle, action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        hotkeyHintItem = hint

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L10n.s("Settings…", "设置…"),
                                action: #selector(openSettings),
                                keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: L10n.s("Quit", "退出"),
                                action: #selector(quit),
                                keyEquivalent: "q"))
        item.menu = menu

        statusItem = item
    }

    /// Mirrors the system policy onto `isVisible` and into the state the popup uses.
    private func syncWithSystemMenuBarPolicy() {
        guard let policy = currentMenuBarPolicy() else {
            refreshMenuBarIconState()
            return
        }
        let wasBlocked = settings.menuBarIconBlocked
        settings.menuBarIconBlocked = !policy.isAllowed
        settings.menuBarPolicyStale = policy.recordedForAnotherBuild

        // A menu-bar-only app with its icon hidden is unreachable: no menu bar
        // icon, no Dock tile, and double-clicking the app does nothing. Give it a
        // Dock tile (and a one-time notification) so there is a way back in.
        if !policy.isAllowed && !wasBlocked {
            enterFallbackMode()
        } else if policy.isAllowed && wasBlocked {
            leaveFallbackMode()
        }

        guard let item = statusItem, item.isVisible != policy.isAllowed else { return }
        suppressVisibilitySync = true
        item.isVisible = policy.isAllowed
        settings.showMenuBarIcon = policy.isAllowed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.suppressVisibilitySync = false
            self?.refreshMenuBarIconState()
        }
    }

    // MARK: - Menu bar policy (System Settings → Menu Bar)

    struct MenuBarPolicy {
        let isAllowed: Bool
        /// The pane recorded this app against another binary (each ad-hoc build
        /// gets a path-keyed record), so its switch may not describe us.
        let recordedForAnotherBuild: Bool
    }

    /// The pane keeps its per-app allow list in ControlCenter's group container.
    /// No public API exposes it, so it is read here; `refreshMenuBarIconState`
    /// falls back to the zero-height heuristic when the file can't be read.
    private func currentMenuBarPolicy() -> MenuBarPolicy? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent(
            "Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let blob = plist["trackedApplications"] as? Data,
              let tracked = try? PropertyListSerialization.propertyList(from: blob, format: nil)
        else { return nil }

        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? ""

        var entries: [[String: Any]] = []
        collectEntries(tracked, bundleID: bundleID, into: &entries)
        guard let first = entries.first else { return nil }

        let allowed = first["isAllowed"] as? Bool ?? true
        let recordedPaths = allStrings(in: first).filter { $0.hasPrefix("file://") }
        let matched = recordedPaths.isEmpty || recordedPaths.contains { $0.contains(executable) }
        return MenuBarPolicy(isAllowed: allowed, recordedForAnotherBuild: !matched)
    }

    private func collectEntries(_ node: Any, bundleID: String, into out: inout [[String: Any]]) {
        if let dict = node as? [String: Any] {
            if dict["isAllowed"] != nil, allStrings(in: dict).contains(where: { $0.contains(bundleID) }) {
                out.append(dict)
            }
            for value in dict.values { collectEntries(value, bundleID: bundleID, into: &out) }
        } else if let array = node as? [Any] {
            for value in array { collectEntries(value, bundleID: bundleID, into: &out) }
        }
    }

    private func allStrings(in node: Any) -> [String] {
        if let string = node as? String { return [string] }
        if let dict = node as? [String: Any] { return dict.values.flatMap { allStrings(in: $0) } }
        if let array = node as? [Any] { return array.flatMap { allStrings(in: $0) } }
        return []
    }

    /// Updates the flags the popup shows. The zero-height window is the fallback
    /// signal when the policy store can't be read.
    private func refreshMenuBarIconState() {
        guard let item = statusItem else {
            settings.menuBarIconBlocked = false
            settings.menuBarPolicyStale = false
            return
        }
        if let policy = currentMenuBarPolicy() {
            settings.menuBarIconBlocked = !policy.isAllowed
            settings.menuBarPolicyStale = policy.recordedForAnotherBuild
        } else {
            let frame = item.button?.window?.frame ?? .zero
            let drawn = frame.height >= 1 && frame.width >= 1
            let blocked = settings.showMenuBarIcon && !drawn
            settings.menuBarIconBlocked = blocked
            settings.menuBarPolicyStale = false
            if blocked { enterFallbackMode() } else { leaveFallbackMode() }
        }
    }

    /// Dock tile + notification while the menu bar icon is switched off.
    private func enterFallbackMode() {
        guard !isInFallbackMode else { return }
        isInFallbackMode = true
        NSApp.setActivationPolicy(.regular)

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = L10n.s("Menu bar icon hidden", "菜单栏图标已隐藏")
            content.body = L10n.s("Re-enable ClipHistory in System Settings → Menu Bar, then reopen the app.",
                                  "在 系统设置 → 菜单栏 重新打开 ClipHistory，然后重启 App。")
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "ClipHistoryMenuBarHidden", content: content, trigger: nil))
        }
    }

    private func leaveFallbackMode() {
        guard isInFallbackMode else { return }
        isInFallbackMode = false
        NSApp.setActivationPolicy(.accessory)
    }

    /// Quits and reopens the app so ControlCenter re-applies its policy — the
    /// switch only takes effect when the item is registered.
    fileprivate func relaunchApp() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }
    }



    /// Keeps the Settings toggle in step with the system's Menu Bar settings and
    /// carries the app's own re-add action back into the status item.

    /// Applies a visibility request and ignores the KVO echo it produces, so the
    /// stored preference can't be overwritten by the value we just set.

    /// Refresh the hint line right before the menu opens (hotkey might have changed)
    func menuWillOpen(_ menu: NSMenu) {
        hotkeyHintItem?.title = hintTitle
    }

    private var hintTitle: String {
        L10n.s("ClipHistory  —  \(settings.hotkey.displayString) to open",
               "ClipHistory  —  \(settings.hotkey.displayString) 打开")
    }

    // MARK: - Settings window

    @objc private func openSettings() {
        if let win = settingsWindow, win.isVisible {
            win.makeKeyAndOrderFront(nil)
            NSRunningApplication.current.activate()
            return
        }

        let view       = SettingsView(settings: settings, store: store,
                                     onReopenOnboarding: { [weak self] in
                                         self?.settingsWindow?.orderOut(nil)
                                         UserDefaults.standard.removeObject(forKey: Self.onboardingDoneKey)
                                         self?.showOnboarding()
                                     })
        let controller = NSHostingController(rootView: view)
        let win        = NSWindow(contentViewController: controller)
        win.title                = L10n.s("ClipHistory Settings", "ClipHistory 设置")
        win.styleMask            = NSWindow.StyleMask([.titled, .closable])
        win.isReleasedWhenClosed = false
        win.delegate = self          // released in windowWillClose
        win.center()
        settingsWindow = win

        win.makeKeyAndOrderFront(NSApp)
        NSRunningApplication.current.activate()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    /// Double-clicking the app (or its Dock tile) opens Settings — the only
    /// window there is.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openSettings() }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard let win = notification.object as? NSWindow, win === settingsWindow else { return }
        settingsWindow = nil
    }

    // MARK: - Onboarding

    private static let onboardingDoneKey = "onboardingComplete"

    private func showOnboardingIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.onboardingDoneKey) else { return }
        showOnboarding()
    }

    func showOnboarding() {
        if let existing = onboardingWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSRunningApplication.current.activate()
            return
        }

        let view = OnboardingView(settings: settings) { [weak self] in
            self?.dismissOnboarding()
        }
        let controller = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: controller)
        win.title                = L10n.s("ClipHistory Setup", "ClipHistory 向导")
        win.styleMask            = [.titled, .closable]
        win.isReleasedWhenClosed = false
        win.center()
        onboardingWindow = win

        // Use a delegate to catch the window's close button as well
        onboardingDelegate.onClose = { [weak self] in self?.dismissOnboarding() }
        win.delegate = onboardingDelegate

        win.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate()
    }

    private func dismissOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardingDoneKey)
        onboardingWindow?.close()
        onboardingWindow = nil
    }

    // MARK: - Source-app tracking

    private func startFrontmostAppTracking() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(frontmostAppDidChange),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        updateFrontmostSource()   // capture the app that's active right now
    }

    @objc private func frontmostAppDidChange(_ note: Notification) {
        updateFrontmostSource()
    }

    private func updateFrontmostSource() {
        guard let app  = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              let name = app.localizedName
        else { return }
        let source = SourceApp(bundleID: app.bundleIdentifier ?? "", name: name)
        guard source != lastFrontmostSource else { return }

        // A copy made just before the switch still belongs to the app that made
        // it — flush it first so the exclusion list is checked against the right
        // app, and so attribution isn't taken from the app we switched to.
        capturePendingClipboard()

        lastFrontmostSource = source
        // A new app means a new copy/paste context — restart the paste cycle.
        popup.resetPasteCycle()

        // The popup no longer owns the keyboard: leaving it up would keep the
        // event tap swallowing keystrokes meant for the newly focused app.
        popup.hideIfVisible()
    }

    // MARK: - Clipboard polling

    private func startClipboardMonitoring() {
        // Capture whatever is already on the clipboard at launch — through the
        // same exclusion filter the polling path uses.
        capture(from: lastFrontmostSource)

        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.capturePendingClipboard()
        }
    }

    /// Polls only when the pasteboard actually changed since the last look.
    private func capturePendingClipboard() {
        let changeCount = NSPasteboard.general.changeCount
        guard changeCount != lastPasteboardChangeCount else { return }
        lastPasteboardChangeCount = changeCount
        capture(from: lastFrontmostSource)
    }

    private func capture(from source: SourceApp?) {
        // Apps on the exclusion list never end up in the history.
        if let bundleID = source?.bundleID, settings.excludedBundleIDs.contains(bundleID) { return }
        store.pollClipboard(source: source)
    }

    // MARK: - Global hotkey

    private func requestAccessibilityAndRegisterHotkey() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
        reRegisterHotkeys()
    }

    private func reRegisterHotkeys() {
        installHotkeyHandlerIfNeeded()
        unregisterHotkeys()

        var failed = Set<String>()
        if !register(settings.hotkey, id: Self.popupHotkeyID) {
            failed.insert(L10n.s("Open Popup", "打开面板"))
        }
        if !register(settings.pasteLatestHotkey, id: Self.pasteLatestHotkeyID) {
            failed.insert(L10n.s("Paste Latest", "粘贴最近一条"))
        }
        if !register(settings.pasteNextHotkey, id: Self.pasteNextHotkeyID) {
            failed.insert(L10n.s("Paste Next Item", "依次粘贴"))
        }
        if !register(settings.pasteAllHotkey, id: Self.pasteAllHotkeyID) {
            failed.insert(L10n.s("Paste All Items", "全部粘贴"))
        }
        settings.unavailableHotkeys = failed
    }

    /// Returns false when the system refused the combination (already owned by
    /// another app, or bound twice), so Settings can say so instead of silently
    /// showing a shortcut that never fires.
    private func register(_ shortcut: HotkeyShortcut, id: UInt32) -> Bool {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            shortcut.carbonModifierFlags,
            EventHotKeyID(signature: Self.hotkeySignature, id: id),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            NSLog("ClipHistory failed to register hotkey \(id): \(status)")
            return false
        }
        hotkeyRefs[id] = ref
        return true
    }

    /// Carbon delivers every registered hotkey here; the ID says which one.
    fileprivate func handleHotkey(id: UInt32) {
        // Synthesized ⌘V presses are ours — acting on them would loop forever.
        guard !popup.hotkeysSuppressed else { return }

        switch id {
        case Self.pasteLatestHotkeyID:
            DispatchQueue.main.async { [weak self] in self?.popup.pasteLatest() }
        case Self.pasteNextHotkeyID:
            DispatchQueue.main.async { [weak self] in self?.popup.pasteNextInOrder() }
        case Self.pasteAllHotkeyID:
            DispatchQueue.main.async { [weak self] in self?.popup.pasteAllInOrder() }
        default:
            showPopupFromHotkey()
        }
    }

    fileprivate func showPopupFromHotkey() {
        DispatchQueue.main.async { [weak self] in
            // Open at the text caret when the focused app reports one,
            // otherwise fall back to the pointer.
            let anchor = CaretLocator.currentRect()
                ?? CGRect(origin: NSEvent.mouseLocation, size: .zero)
            self?.popup.show(near: anchor)
        }
    }

    private func installHotkeyHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            clipHistoryHotkeyHandler,
            1,
            &eventType,
            userData,
            &eventHandlerRef
        )

        if status != noErr {
            NSLog("ClipHistory failed to install hotkey handler: \(status)")
        }
    }

    private func unregisterHotkeys() {
        for (_, ref) in hotkeyRefs { UnregisterEventHotKey(ref) }
        hotkeyRefs.removeAll()
    }

    private static let hotkeySignature: OSType = 0x43484B59 // "CHKY"
}

// MARK: - Onboarding window delegate

/// Thin NSWindowDelegate that fires a closure when the window is about to close.
/// Used so the "× close" button marks onboarding complete just like "Get Started".
final class OnboardingWindowDelegate: NSObject, NSWindowDelegate {
    var onClose: () -> Void = {}
    func windowWillClose(_ notification: Notification) { onClose() }
}

// MARK: -

private extension HotkeyShortcut {
    var carbonModifierFlags: UInt32 {
        var flags: UInt32 = 0
        let modifiers = modifierFlags

        if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        if modifiers.contains(.option)  { flags |= UInt32(optionKey) }
        if modifiers.contains(.control) { flags |= UInt32(controlKey) }
        if modifiers.contains(.shift)   { flags |= UInt32(shiftKey) }

        return flags
    }
}
