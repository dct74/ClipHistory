import Foundation

/// Tiny in-app localization: picks English or Simplified Chinese from the
/// system's preferred language at launch.
///
/// No `.lproj` resources — the .app is assembled by `scripts/build-dmg.sh` and
/// an inline pair-per-string table keeps every translation next to its usage.
enum L10n {
    static let isChinese: Bool = {
        guard let code = Locale.preferredLanguages.first?.lowercased() else { return false }
        return code.hasPrefix("zh")
    }()

    /// English when the system language isn't Chinese, otherwise Chinese.
    static func s(_ en: String, _ zh: String) -> String {
        isChinese ? zh : en
    }
}
