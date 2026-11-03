<div align="center">

<img src="docs/icon.png" width="128" height="128" alt="ClipHistory icon" />

# ClipHistory

**A lightweight, native macOS clipboard manager.**  
One hotkey. Instant popup. Text and images. No subscription.

> **This is a fork of [weiykong/ClipHistory](https://github.com/weiykong/ClipHistory).**
> The app and its design are the upstream author's work; this fork adds the paste
> model, caret-anchored popup and CJK search described below, and publishes its own
> builds. For the original project — issues, history, upstream releases — see
> **[github.com/weiykong/ClipHistory](https://github.com/weiykong/ClipHistory)**.

[![CI](https://github.com/dct74/ClipHistory/actions/workflows/ci.yml/badge.svg)](https://github.com/dct74/ClipHistory/actions/workflows/ci.yml)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)](https://github.com/dct74/ClipHistory/releases/latest)
[![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)](https://swift.org)
[![MIT License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

[**Download for Mac**](https://github.com/dct74/ClipHistory/releases/latest/download/ClipHistory.dmg) · [Website](https://github.com/dct74/ClipHistory/blob/main/docs/index.html) · [Releases](https://github.com/dct74/ClipHistory/releases)

</div>

---

## What it looks like

<div align="center">
  <img src="docs/screenshot.png" width="480" alt="ClipHistory popup in front of a text editor" />
</div>

---

## Why ClipHistory?

If you want 200 features, use Raycast. If you want iCloud sync, use Paste. If you just want a fast, native, free clipboard history that handles text and images — this is it.

| | |
|---|---|
| ✅ Free & open source | ✅ Text & images |
| ✅ Native Swift — ~1 MB | ✅ Paste clips one by one |
| ✅ Search as you type | ✅ Per-app privacy exclusions |
| ✅ Source app icons | ✅ Survives restarts |
| ✅ Launch at Login | ✅ No subscription, no telemetry |
| ✅ AES-256-GCM encrypted history | ✅ Sensitive data auto-skipped |

---

## Features

- **⚡ Instant popup** — press `⇧⌘V` from any app; the popup opens beside the text caret (above, below, left or right — whichever has room)
- **⌘V stays a normal paste** — the clipboard is never rewritten, so rich text and full-resolution images keep their fidelity
- **🖼 Text & images** — captures plain text, screenshots, images from Finder, browsers, Preview
- **🔍 Search** — type to filter instantly; searches content and source app name, CJK input methods included
- **⌃⌘V one by one, ⌃⌥⌘V all at once** — walk the history in order, or paste everything in a single run
- **🔐 Encrypted history** — disk storage is AES-256-GCM encrypted; the key lives in your Keychain, never on disk
- **🔒 Sensitive data protection** — items marked by password managers (`org.nspasteboard.ConcealedType`) are automatically skipped before recording
- **🚫 Per-app exclusions** — block any app from being recorded; changes from excluded apps are silently ignored
- **👁 Hide images toggle** — one click in the popup header to go text-only
- **🏷 Source app icons** — see at a glance which app each item came from
- **🪶 Truly lightweight** — ~1 MB, pure SwiftUI, no background web process, no telemetry

---

## Install

### Homebrew (recommended)

```bash
brew install --cask dct74/tap/cliphistory
```

Upgrades: `brew upgrade --cask cliphistory` · Uninstall: `brew uninstall --cask cliphistory`
(add `--zap` to drop the stored history and preferences too).

### Download

1. [**Download ClipHistory.dmg**](https://github.com/dct74/ClipHistory/releases/latest/download/ClipHistory.dmg)
2. Open the DMG and drag **ClipHistory.app** to `/Applications`
3. **Verify the download** (recommended) — the release ships a checksum:
   ```bash
   shasum -a 256 -c ClipHistory.dmg.sha256
   ```
4. **Unlock the app (one-time)** — macOS blocks apps without an Apple certificate. Open Terminal and run:
   ```bash
   xattr -d com.apple.quarantine /Applications/ClipHistory.app
   ```
   Then double-click ClipHistory to open it normally.
5. Grant **Accessibility** permission when the onboarding screen asks

**Requires macOS 14 Sonoma or later.**

### Build from source

```bash
git clone https://github.com/dct74/ClipHistory.git
cd ClipHistory
bash scripts/build-dmg.sh   # → dist/ClipHistory.dmg
```

Requires Xcode Command Line Tools: `xcode-select --install`

---

## Usage

The list runs oldest → newest: the earliest clip sits at the top, your latest copy at the bottom.

| Action | Shortcut |
|---|---|
| Open popup at the text cursor | `⇧⌘V` *(customisable in Settings)* |
| Paste the latest clip | `⌘V` *(customisable in Settings)* |
| Paste clips one by one (oldest first, one per press) | `⌃⌘V` *(customisable in Settings)* |
| Paste everything in one go | `⌃⌥⌘V` *(customisable in Settings)* |
| Navigate | `↑` / `↓` |
| Paste selected | `↵` |
| Search | Just type — no field to click |
| Delete an item | Click the `trash` icon on the row |
| Hide images | `photo` toggle in the popup header |
| Close | `Esc` or click outside |
| Settings | Menu bar icon → **Settings…** |
| Hide the menu bar icon | System Settings → Menu Bar, or Settings → **Show in Menu Bar** (reopen the popup to bring it back) |

Paste-all joins consecutive text clips into a single paste, end to end with no
separator (images still go one by one, since the pasteboard carries one
representation per paste). Paste-one-by-one stops at the newest clip instead of
wrapping back to the oldest. The popup opens above, below, right or left of the
caret — whichever side has room — with a 10 pt clearance, so it never covers the
insertion point.

Search accepts CJK input: keystrokes reach the system input method through an
`NSTextInputClient` bridge, so pinyin/Japanese/Korean composition works even
though the popup never takes focus from the app you're pasting into.

The app follows your system language (English / Simplified Chinese).

---

## Architecture

Zero dependencies. Swift Package Manager executable target.

```
Sources/ClipHistory/
├── main.swift                  # NSApplication entry point
├── AppTheme.swift              # Shared radii / fills
├── AppDelegate.swift           # Menu bar, hotkey, clipboard polling timer
├── AppSettings.swift           # @Observable settings + UserDefaults persistence
├── ClipboardStore.swift        # Item store, polling, AES-256-GCM encryption, PNG thumbnailing
├── PopupWindowController.swift # NSPanel + CGEventTap keyboard intercept
├── IMESearchBridge.swift       # NSTextInputClient so search accepts CJK input
├── PopupView.swift             # SwiftUI popup UI
├── PopupState.swift            # Shared search / selection state
├── SettingsView.swift          # SwiftUI settings window
├── OnboardingView.swift        # First-launch setup guide
├── HotkeyShortcut.swift        # Hotkey model (Carbon registration lives in AppDelegate)
├── HotkeyRecorderView.swift    # NSViewRepresentable hotkey recorder
├── CaretLocator.swift          # Accessibility caret lookup for popup placement
├── PopupPlacement.swift        # Pure geometry: pick above/below/left/right of the caret
├── Localization.swift          # en / zh-Hans string table driven by system language
├── UpdateChecker.swift         # GitHub releases check
└── MenuBarIcon.swift           # Programmatic SF Symbol menu bar icon
```

<details>
<summary><strong>Key design decisions</strong></summary>

**`NSPanel` with `.nonactivatingPanel`**  
The popup becomes the key window (so SwiftUI buttons receive clicks) without ever activating the app. The previously focused app keeps its text cursor throughout — Cmd+V fires straight into it after paste.

**Session-level `CGEventTap`**  
Keyboard events are intercepted at the OS session level while the popup is visible, routing them to search and navigation without stealing focus from the source app.

**`@Observable` + `@Bindable`**  
Modern Swift observation macros throughout — no `@StateObject` or `@ObservedObject`.

**AES-256-GCM encrypted storage**  
History is saved as `history.json.enc` — a single AES-GCM sealed box. A 256-bit key is generated on first launch and stored in the Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Saves are debounced (1 s) so clipboard bursts produce a single write.

**Sensitive data protection**  
Before recording any clipboard event, the store checks for `org.nspasteboard.ConcealedType` — the standard pasteboard type that 1Password and other credential managers set. Items carrying it are silently dropped.

**Image thumbnailing**  
Clipboard images (screenshots, browser copies, Finder files) are downscaled to ≤ 480 px PNG at capture time using `NSImage(size:flipped:drawingHandler:)`, which forces lazy clipboard images that report `size=(0,0)` to render before sampling. Decoded `NSImage` instances are cached in `NSCache` keyed by item UUID to avoid re-inflating PNG bytes on every render pass.

</details>

---

## Contributing

Issues and pull requests are welcome.  
Please **open an issue first** before starting any large change so we can discuss the approach.

---

## License

[MIT](LICENSE) © 2026 weiykong
