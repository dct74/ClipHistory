import Foundation
import AppKit
import Observation
import ServiceManagement


@Observable
final class AppSettings {

    // MARK: - Stored properties

    var hotkey: HotkeyShortcut = .default {
        didSet { save(); onHotkeysChanged?() }
    }

    /// Pastes the most recent clip. Defaults to ⌘V, so ClipHistory owns plain
    /// paste system-wide.
    var pasteLatestHotkey: HotkeyShortcut = .pasteLatestDefault {
        didSet { save(); onHotkeysChanged?() }
    }

    /// Walks the history oldest → newest, one clip per press.
    var pasteNextHotkey: HotkeyShortcut = .pasteNextDefault {
        didSet { save(); onHotkeysChanged?() }
    }

    /// Opens the clear-history confirmation.
    var clearHistoryHotkey: HotkeyShortcut = .clearHistoryDefault {
        didSet { save(); onHotkeysChanged?() }
    }

    /// Pastes every clip in the current scope in order.
    var pasteAllHotkey: HotkeyShortcut = .pasteAllDefault {
        didSet { save(); onHotkeysChanged?() }
    }

    var maxItems: Int = 50 {
        didSet { save(); onMaxItemsChanged?(maxItems) }
    }

    var launchAtLogin: Bool = false {
        didSet {
            guard launchAtLogin != oldValue else { return }
            applyLaunchAtLogin()
        }
    }

    /// Hide image items from the popup list.
    var hideImages: Bool = false {
        didSet { save() }
    }

    /// When true, reopening the popup keeps the previous selection/scroll
    /// position instead of jumping back to the start of the list.
    var rememberScrollPosition: Bool = false {
        didSet { save() }
    }

    /// Bundle IDs of apps whose clipboard changes are silently ignored.
    var excludedBundleIDs: Set<String> = [] {
        didSet { save() }
    }

    // MARK: - Callbacks (set by AppDelegate)

    /// Whether the menu bar icon is shown. The app owns this setting — macOS can't
    /// manage an ad-hoc signed status item reliably (it records them by binary
    /// path), so the system's Menu Bar pane is not used.
    var showMenuBarIcon: Bool = true {
        didSet {
            guard showMenuBarIcon != oldValue else { return }
            save()
            onShowMenuBarIconChanged?(showMenuBarIcon)
        }
    }

    var onShowMenuBarIconChanged: ((Bool) -> Void)?

    /// Shortcuts the system refused to register (conflict with another app, or
    /// the same combo bound twice). Shown as a warning in Settings.
    var unavailableHotkeys: Set<String> = []

    var onHotkeysChanged:  (() -> Void)?
    var onMaxItemsChanged: ((Int) -> Void)?

    // MARK: - Init

    init() { load() }

    /// Bump whenever shortcut defaults change meaning.
    private static let defaultsVersion = 2

    /// Suppresses persistence while `load()` assigns the stored values — each
    /// assignment fires `didSet`, which would otherwise write the not-yet-loaded
    /// defaults back over the user's saved shortcuts.
    private var isLoading = true

    // MARK: - Persistence

    private enum Keys {
        static let version                = "settingsVersion"
        static let hotkey                 = "hotkey"
        static let pasteLatestHotkey      = "pasteLatestHotkey"
        static let pasteNextHotkey        = "pasteNextHotkey"
        static let pasteAllHotkey         = "pasteAllHotkey"
        static let clearHistoryHotkey     = "clearHistoryHotkey"
        static let showMenuBarIcon        = "showMenuBarIcon"
        static let maxItems               = "maxItems"
        static let hideImages             = "hideImages"
        static let rememberScrollPosition = "rememberScrollPosition"
        static let excludedBundleIDs      = "excludedBundleIDs"
    }

    private func load() {
        let d = UserDefaults.standard

        // Bump when stored shortcuts change meaning. The paste keys were
        // re-mapped (⌘V latest / ⌃⌘V cycle / ⌃⌥⌘V all), so anything saved under
        // the old mapping is dropped and the new defaults apply.
        if d.integer(forKey: Keys.version) < Self.defaultsVersion {
            [Keys.pasteLatestHotkey, Keys.pasteNextHotkey, Keys.pasteAllHotkey]
                .forEach { d.removeObject(forKey: $0) }
            d.set(Self.defaultsVersion, forKey: Keys.version)
        }
        hotkey = Self.decode(d.data(forKey: Keys.hotkey)) ?? .default
        pasteLatestHotkey = Self.decode(d.data(forKey: Keys.pasteLatestHotkey)) ?? .pasteLatestDefault
        pasteNextHotkey = Self.decode(d.data(forKey: Keys.pasteNextHotkey)) ?? .pasteNextDefault
        pasteAllHotkey  = Self.decode(d.data(forKey: Keys.pasteAllHotkey))  ?? .pasteAllDefault
        clearHistoryHotkey = Self.decode(d.data(forKey: Keys.clearHistoryHotkey)) ?? .clearHistoryDefault

        let n = d.integer(forKey: Keys.maxItems)
        if n >= 5 { maxItems = n }

        hideImages = d.bool(forKey: Keys.hideImages)
        rememberScrollPosition = d.bool(forKey: Keys.rememberScrollPosition)
        if d.object(forKey: Keys.showMenuBarIcon) != nil {
            showMenuBarIcon = d.bool(forKey: Keys.showMenuBarIcon)
        }
        if let ids = d.stringArray(forKey: Keys.excludedBundleIDs) {
            excludedBundleIDs = Set(ids)
        }

        // Read ground-truth from the OS — don't call SMAppService again if it
        // already matches (guard in didSet prevents the redundant call).
        launchAtLogin = SMAppService.mainApp.status == .enabled
        isLoading = false
    }

    private static func decode(_ data: Data?) -> HotkeyShortcut? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(HotkeyShortcut.self, from: data)
    }

    private static func store(_ shortcut: HotkeyShortcut, key: String, into d: UserDefaults) {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        d.set(data, forKey: key)
    }

    private func save() {
        guard !isLoading else { return }
        let d = UserDefaults.standard
        Self.store(hotkey,          key: Keys.hotkey,          into: d)
        Self.store(pasteLatestHotkey, key: Keys.pasteLatestHotkey, into: d)
        Self.store(pasteNextHotkey, key: Keys.pasteNextHotkey, into: d)
        Self.store(pasteAllHotkey,  key: Keys.pasteAllHotkey,  into: d)
        Self.store(clearHistoryHotkey, key: Keys.clearHistoryHotkey, into: d)
        d.set(maxItems,                 forKey: Keys.maxItems)
        d.set(showMenuBarIcon,          forKey: Keys.showMenuBarIcon)
        d.set(hideImages,               forKey: Keys.hideImages)
        d.set(rememberScrollPosition,   forKey: Keys.rememberScrollPosition)
        d.set(Array(excludedBundleIDs), forKey: Keys.excludedBundleIDs)
    }

    // MARK: - Launch at Login

    private func applyLaunchAtLogin() {
        // Loading the stored value must not re-register the login item.
        guard !isLoading else { return }
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Refused (needs user approval, or the bundle isn't eligible):
            // fall back to what the OS actually reports instead of showing a
            // toggle that is on while no login item exists.
            NSLog("ClipHistory: launch-at-login update: \(error.localizedDescription)")
            isLoading = true
            launchAtLogin = SMAppService.mainApp.status == .enabled
            isLoading = false
        }
    }
}
