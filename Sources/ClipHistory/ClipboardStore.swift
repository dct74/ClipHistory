import AppKit
import CryptoKit
import LocalAuthentication
import Observation
import Security

// MARK: - Source app

struct SourceApp: Codable, Equatable {
    let bundleID: String
    let name:     String

    var icon: NSImage? { SourceApp.cachedIcon(for: bundleID) }

    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        cache.totalCostLimit = 4 * 1024 * 1024
        return cache
    }()

    private static func cachedIcon(for bundleID: String) -> NSImage? {
        if let hit = cache.object(forKey: bundleID as NSString) { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(img, forKey: bundleID as NSString, cost: 32 * 32 * 4)
        return img
    }
}

// MARK: - Content kind

enum ClipContent: Equatable {
    case text(String)
    case image(Data)    // PNG thumbnail (≤ 480 px on longest side)
}

extension ClipContent: Codable {
    private enum CK: String, CodingKey { case type, text, imageData }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CK.self)
        switch self {
        case .text(let t):
            try c.encode("text",  forKey: .type)
            try c.encode(t,       forKey: .text)
        case .image(let d):
            try c.encode("image", forKey: .type)
            try c.encode(d,       forKey: .imageData)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CK.self)
        switch try c.decode(String.self, forKey: .type) {
        case "text":  self = .text(try c.decode(String.self, forKey: .text))
        case "image": self = .image(try c.decode(Data.self, forKey: .imageData))
        default:      throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                          debugDescription: "Unknown ClipContent type")
        }
    }
}

// MARK: - Clip item

struct ClipItem: Identifiable, Equatable {
    let id:        UUID
    let content:   ClipContent
    let date:      Date
    let sourceApp: SourceApp?

    init(content: ClipContent, date: Date = .now, sourceApp: SourceApp? = nil) {
        self.id        = UUID()
        self.content   = content
        self.date      = date
        self.sourceApp = sourceApp
    }

    var preview: String {
        switch content {
        case .text(let t): return t.trimmingCharacters(in: .whitespacesAndNewlines)
        case .image:       return L10n.s("Image", "图片")
        }
    }

    var textContent: String? {
        if case .text(let t) = content { return t }
        return nil
    }

    var isImage: Bool {
        if case .image = content { return true }
        return false
    }
}

extension ClipItem: Codable {
    private enum CK: String, CodingKey { case id, content, date, sourceApp, text }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CK.self)
        try c.encode(id,        forKey: .id)
        try c.encode(content,   forKey: .content)
        try c.encode(date,      forKey: .date)
        try c.encodeIfPresent(sourceApp, forKey: .sourceApp)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CK.self)
        id        = try  c.decode(UUID.self,      forKey: .id)
        date      = try  c.decode(Date.self,      forKey: .date)
        sourceApp = try? c.decode(SourceApp.self, forKey: .sourceApp)

        if let cont = try? c.decode(ClipContent.self, forKey: .content) {
            content = cont
        } else if let text = try? c.decode(String.self, forKey: .text) {
            content = .text(text)
        } else {
            throw DecodingError.dataCorruptedError(forKey: .content, in: c,
                debugDescription: "ClipItem missing both 'content' and legacy 'text' key")
        }
    }
}

/// Wrapper that swallows per-element decoding failures, so one corrupt record
/// can't take the whole history with it.
private struct LossyClipItem: Decodable {
    let value: ClipItem?

    init(from decoder: Decoder) throws {
        value = try? ClipItem(from: decoder)
    }
}

// MARK: - Store

@Observable
final class ClipboardStore {
    private(set) var items: [ClipItem] = []
    private var maxCount: Int

    /// Pasteboard generation of our own last write. Capture is skipped when the
    /// pasteboard still holds it — exact, with no timing window, unlike the old
    /// "suppress the next poll" flag.
    private(set) var lastWrittenChangeCount = -1

    /// Remembers the last few deletions so they can be undone (⌘Z in the popup,
    /// or the status menu). Not persisted — an undo is a session-level courtesy.
    enum Deletion: Equatable {
        case removed(index: Int, item: ClipItem)
        case cleared([ClipItem])
    }

    private var undoStack: [Deletion] = []
    private(set) var canUndo: Bool = false
    private static let undoLimit = 10

    /// Fired whenever a new clip lands in the history — drives resetting the
    /// paste cycle.
    var onItemCaptured: (() -> Void)?

    // Decoded-image cache — avoids re-inflating PNG bytes on every render pass.
    // Keyed by item UUID so entries are automatically orphaned when items are evicted.
    private let imageCache = NSCache<NSUUID, NSImage>()

    private let saveURL: URL = {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipHistory", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json.enc")
    }()

    // AES-GCM key stored in the Keychain — never written to disk in plaintext.
    private let encryptionKey: SymmetricKey

    // Pending save work item — cancelled and rescheduled on each write so
    // rapid clipboard bursts collapse into a single disk write.
    private var pendingSave: DispatchWorkItem?

    init(maxCount: Int = 50) {
        self.maxCount      = maxCount
        self.encryptionKey = ClipboardStore.loadOrCreateKey()
        imageCache.countLimit = maxCount * 2
        // Cost must be the *decoded* size — a 480 px PNG is ~100 KB on disk but
        // ~0.9 MB once inflated, so byte-counting the PNG under-reported by ~9x.
        imageCache.totalCostLimit = 24 * 1024 * 1024
        load()
    }

    // MARK: - Image cache

    func cachedImage(for item: ClipItem) -> NSImage? {
        let key = item.id as NSUUID
        if let hit = imageCache.object(forKey: key) { return hit }
        guard case .image(let data) = item.content,
              let img = NSImage(data: data) else { return nil }
        let pixels = img.representations.reduce(0) { $0 + $1.pixelsWide * $1.pixelsHigh }
        imageCache.setObject(img, forKey: key, cost: max(pixels, 1) * 4)
        return img
    }

    /// Drops decoded images while the popup is closed — they are only needed to
    /// draw rows, and NSCache would otherwise keep them for the whole session.
    func releaseDecodedImages() {
        imageCache.removeAllObjects()
    }

    /// Records the pasteboard generation of a write we just performed, so the
    /// next poll ignores it instead of storing our own paste back as a new clip.
    func noteOwnWrite() {
        lastWrittenChangeCount = NSPasteboard.general.changeCount
    }

    // MARK: - Public API

    func pollClipboard(source: SourceApp? = nil) {
        let pb = NSPasteboard.general
        let changeCount = pb.changeCount

        // Our own paste (single or paste-all) — never capture it back.
        if changeCount == lastWrittenChangeCount { return }

        // Skip items explicitly marked as sensitive by the source app
        // (1Password, Keychain prompts, etc. set this type on the pasteboard).
        let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        if pb.types?.contains(concealedType) == true { return }

        // ── 1. File URLs from Finder ──────────────────────────────────────────
        let imageExts: Set<String> = ["jpg","jpeg","png","gif","tiff","tif",
                                      "webp","heic","bmp","avif"]
        if let urls = pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            for url in urls where imageExts.contains(url.pathExtension.lowercased()) {
                if let thumb = ImageThumbnail.png(fromFile: url) {
                    add(ClipItem(content: .image(thumb), sourceApp: source))
                    return
                }
            }
            return
        }

        // ── 2. Direct image data ──────────────────────────────────────────────
        // Skip if the pasteboard also carries text — apps like Excel write both
        // a bitmap preview and structured text/CSV simultaneously. Preferring
        // text means cell content stays editable when pasted into a text editor.
        let pasteboardHasText = pb.string(forType: .string)
            .map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        if !pasteboardHasText {
            // Downsample straight from the encoded bytes — inflating the full
            // image first costs tens of MB on a 4K capture and stalls the poll.
            if let data = pb.data(forType: .tiff) ?? pb.data(forType: .png),
               let thumb = ImageThumbnail.png(from: data) {
                add(ClipItem(content: .image(thumb), sourceApp: source))
                return
            }
            // Sources that only offer an NSImage still work, one copy at a time.
            if let imgs = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
               let img = imgs.first(where: { $0.isValid }),
               let tiff = img.tiffRepresentation,
               let thumb = ImageThumbnail.png(from: tiff) {
                add(ClipItem(content: .image(thumb), sourceApp: source))
                return
            }
        }

        // ── 3. Text ───────────────────────────────────────────────────────────
        guard let text = pb.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text != items.first?.textContent
        else { return }
        // Very large text (logs, minified JSON) would dominate the history and
        // every save; 256 KB is far above anything a person copies on purpose.
        guard text.utf8.count <= Self.maxTextBytes else {
            NSLog("ClipHistory: skipped a %.1f KB text clip", Double(text.utf8.count) / 1024)
            return
        }
        add(ClipItem(content: .text(text), sourceApp: source))
    }

    func clearAll() {
        if !items.isEmpty { pushUndo(.cleared(items)) }
        items = []
        imageCache.removeAllObjects()
        flushSave()
    }

    /// Restores the most recent deletion or clear. Returns false when there is
    /// nothing to undo.
    @discardableResult
    func undoDeletion() -> Bool {
        guard let action = undoStack.popLast() else { return false }
        switch action {
        case .removed(let index, let item):
            items.insert(item, at: min(max(index, 0), items.count))
        case .cleared(let previous):
            // Merge instead of replacing: anything copied after the clear must
            // survive the undo (both arrays are newest-first).
            let kept = Set(items.map(\.id))
            items = items + previous.filter { !kept.contains($0.id) }
        }
        imageCache.removeAllObjects()
        canUndo = !undoStack.isEmpty
        trimToLimit()
        scheduleSave()
        return true
    }

    private func pushUndo(_ action: Deletion) {
        // Only the most recent clear is worth keeping: an older snapshot is a
        // whole history (images included) and would never be reached first.
        undoStack.removeAll { if case .cleared = $0 { return true } else { return false } }
        undoStack.append(action)
        while undoStack.count > Self.undoLimit || undoBytes > Self.undoByteLimit {
            guard undoStack.count > 1 else { break }
            undoStack.removeFirst()
        }
        canUndo = true
    }

    private var undoBytes: Int {
        undoStack.reduce(0) { total, action in
            switch action {
            case .removed(_, let item):
                return total + ClipboardStore.byteCost(of: item)
            case .cleared(let items):
                return total + items.reduce(0) { $0 + ClipboardStore.byteCost(of: $1) }
            }
        }
    }

    private static func byteCost(of item: ClipItem) -> Int {
        switch item.content {
        case .text(let text): return text.utf8.count
        case .image(let data): return data.count
        }
    }

    private static let undoByteLimit = 8 * 1024 * 1024
    private static let maxTextBytes = 256 * 1024

    func updateMaxCount(_ n: Int) {
        maxCount = n
        imageCache.countLimit = n * 2
        trimToLimit()
        scheduleSave()
    }

    func remove(id: UUID) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            let item = items[idx]
            pushUndo(.removed(index: idx, item: item))
            items.remove(at: idx)
            imageCache.removeObject(forKey: id as NSUUID)
            scheduleSave()
        }
    }

    /// Display order: oldest clip first, newest last. Storage stays newest-first
    /// internally, so capture, dedupe and trimming keep working on the head.
    func filtered(query: String, showImages: Bool = true) -> [ClipItem] {
        var result = items
        if !showImages { result = result.filter { !$0.isImage } }
        if !query.isEmpty {
            result = result.filter {
                $0.preview.localizedCaseInsensitiveContains(query) ||
                ($0.sourceApp?.name.localizedCaseInsensitiveContains(query) ?? false)
            }
        }
        return Array(result.reversed())
    }

    // MARK: - Private helpers

    private func add(_ item: ClipItem) {
        items.insert(item, at: 0)
        trimToLimit()
        scheduleSave()
        onItemCaptured?()
    }

    private func trimToLimit() {
        // Newest entries live at the head — keep those, evict the tail.
        let kept = Array(items.prefix(maxCount))
        for item in items.dropFirst(kept.count) {
            imageCache.removeObject(forKey: item.id as NSUUID)
        }
        items = kept
    }

    // MARK: - Debounced save

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushSave() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func flushSave() {
        pendingSave = nil
        // Hand the array (copy-on-write) to the save queue and encode there: with
        // images in the history the encoded blob is the biggest allocation of a
        // save, and it has no business on the main thread.
        let snapshot = items
        let key = encryptionKey
        let url = saveURL
        ClipboardStore.saveQueue.async {
            guard let plain = try? JSONEncoder().encode(snapshot) else { return }
            ClipboardStore.write(plain, key: key, to: url)
        }
    }

    /// Writes any pending change before the process exits — the 1 s debounce
    /// would otherwise drop a clip copied right before "Quit".
    func flushNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let plain = try? JSONEncoder().encode(items) else { return }   // must finish before exit
        let key = encryptionKey
        let url = saveURL
        _ = ClipboardStore.saveQueue.sync {
            ClipboardStore.write(plain, key: key, to: url)
        }
    }

    /// Envelope: `0x02 || nonce(12) || ciphertext || tag(16)`.
    ///
    /// Written in chunks to a temporary file and then swapped in, so the history
    /// is never half-written and the process never holds a second full copy of
    /// the ciphertext (`SealedBox.combined` used to allocate exactly that).
    private static let envelopeVersion: UInt8 = 0x02

    @discardableResult
    private static func write(_ plain: Data, key: SymmetricKey, to url: URL) -> Bool {
        guard let sealed = try? AES.GCM.seal(plain, using: key) else { return false }

        let temp = url.appendingPathExtension("tmp")
        try? FileManager.default.removeItem(at: temp)
        guard FileManager.default.createFile(atPath: temp.path, contents: nil) else { return false }

        do {
            let handle = try FileHandle(forWritingTo: temp)
            try handle.write(contentsOf: Data([envelopeVersion]))
            try handle.write(contentsOf: sealed.nonce.withUnsafeBytes { Data($0) })
            try handle.write(contentsOf: sealed.ciphertext)
            try handle.write(contentsOf: sealed.tag)
            try handle.synchronize()
            try handle.close()
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            return true
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
    }

    /// Reads either the current envelope or the older `combined` layout.
    private static func decrypt(_ data: Data, key: SymmetricKey) -> Data? {
        if data.first == envelopeVersion, data.count > 1 + 12 + 16 {
            let body = data.dropFirst()
            let nonce = body.prefix(12)
            let tag = body.suffix(16)
            let ciphertext = body.dropFirst(12).dropLast(16)
            guard let box = try? AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
                                                  ciphertext: ciphertext,
                                                  tag: tag) else { return nil }
            return try? AES.GCM.open(box, using: key)
        }
        guard let box = try? AES.GCM.SealedBox(combined: data) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    private static let saveQueue = DispatchQueue(label: "com.weiyuankong.cliphistory.save",
                                                 qos: .utility)

    // MARK: - Load (decrypts + falls back to legacy plaintext)

    private func load() {
        if let enc = try? Data(contentsOf: saveURL) {
            if let plain = Self.decrypt(enc, key: encryptionKey) {
                items = Array(Self.decodeItems(plain).prefix(maxCount * 2))
            } else {
                // Wrong key or damaged file: keep it for the user instead of
                // letting the next debounced save overwrite the only copy.
                NSLog("ClipHistory: history could not be decrypted — moved aside")
                quarantineHistory()
            }
            return
        }

        // Migrate legacy unencrypted history.json if present
        let legacyURL = saveURL.deletingLastPathComponent().appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: legacyURL) {
            items = Array(Self.decodeItems(data).prefix(maxCount * 2))
            // Only drop the plaintext file once the encrypted write succeeded.
            let plain = try? JSONEncoder().encode(items)
            let key   = encryptionKey
            let url   = saveURL
            ClipboardStore.saveQueue.sync {
                guard let plain, ClipboardStore.write(plain, key: key, to: url) else { return }
                try? FileManager.default.removeItem(at: legacyURL)
            }
        }
    }

    /// Decodes element by element so one damaged record doesn't discard the
    /// whole history.
    private static func decodeItems(_ data: Data) -> [ClipItem] {
        guard let lossy = try? JSONDecoder().decode([LossyClipItem].self, from: data) else { return [] }
        return lossy.compactMap(\.value)
    }

    private func quarantineHistory() {
        let aside = saveURL.appendingPathExtension("unreadable")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: saveURL, to: aside)
    }

    // MARK: - Encryption key

    private static let keychainService = "com.weiyuankong.cliphistory"
    private static let keychainAccount = "history-encryption-key"

    /// `~/Library/Application Support/ClipHistory/encryption.key`, mode 0600.
    private static var keyFileURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipHistory", isDirectory: true)
            .appendingPathComponent("encryption.key")
    }

    /// The key lives in a 0600 file, with the Keychain as a *migration source*
    /// only.
    ///
    /// Every build of this app is ad-hoc signed, so each release has a different
    /// code identity. A Keychain item created by one build prompts for
    /// authorisation in the next one — and because this is a menu bar app with no
    /// window, that prompt is invisible: the app simply hangs at launch and never
    /// creates its status item. Reading the Keychain with UI disabled and keeping
    /// the key in a file next to the (equally readable) history removes both the
    /// hang and the history loss on upgrade.
    private static func loadOrCreateKey() -> SymmetricKey {
        if let data = try? Data(contentsOf: keyFileURL), data.count == 32 {
            return SymmetricKey(data: data)
        }

        // One-time migration from builds that stored the key in the Keychain.
        if let existing = existingKeychainKey() {
            writeKeyFile(existing)
            return existing
        }

        let key = SymmetricKey(size: .bits256)
        writeKeyFile(key)
        storeInKeychain(key)          // best effort, never blocks
        return key
    }

    /// Reads the Keychain copy without ever showing UI, so a differently signed
    /// build fails fast instead of hanging.
    private static func existingKeychainKey() -> SymmetricKey? {
        let query: [CFString: Any] = [
            kSecClass:                     kSecClassGenericPassword,
            kSecAttrService:               keychainService,
            kSecAttrAccount:               keychainAccount,
            kSecReturnData:                true,
            kSecUseAuthenticationContext:  noInteractionContext(),
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    private static func storeInKeychain(_ key: SymmetricKey) {
        let keyData = key.withUnsafeBytes { Data($0) }
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
        ]
        let add: [CFString: Any] = [
            kSecClass:           kSecClassGenericPassword,
            kSecAttrService:     keychainService,
            kSecAttrAccount:     keychainAccount,
            kSecValueData:       keyData,
            kSecAttrAccessible:  kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecUseAuthenticationContext: noInteractionContext(),
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("ClipHistory: keychain copy not stored: \(status)")
        }
    }

    /// An authentication context that must never put UI on screen — an invisible
    /// modal prompt is what used to hang the app at launch.
    private static func noInteractionContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    private static func writeKeyFile(_ key: SymmetricKey) {
        let data = key.withUnsafeBytes { Data($0) }
        let url = keyFileURL
        let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        if !FileManager.default.createFile(atPath: url.path, contents: data, attributes: attributes) {
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
            try? FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
        }
    }
}

// MARK: - Image thumbnailing

/// Downscales to ≤ 480 px and re-encodes as PNG **without** decoding the full
/// image: `CGImageSourceCreateThumbnailAtIndex` decodes only what the thumbnail
/// needs, so a 4K screenshot no longer costs ~33 MB of transient bitmaps on the
/// main thread during clipboard polling.
enum ImageThumbnail {
    static func png(fromFile url: URL, maxDimension: CGFloat = 480) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return png(from: source, maxDimension: maxDimension)
    }

    static func png(from data: Data, maxDimension: CGFloat = 480) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return png(from: source, maxDimension: maxDimension)
    }

    private static func png(from source: CGImageSource, maxDimension: CGFloat) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        return bitmap.representation(using: .png, properties: [.compressionFactor: 0.85])
    }
}
