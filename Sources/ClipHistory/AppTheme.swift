import SwiftUI

/// One place for the window/menu surfaces.
///
/// Light mode uses a fixed near-white (#FAFAFA) instead of the system's pure
/// white, so every surface of the app matches; dark mode keeps the system
/// background (changing it there would fight the system's own contrast).
extension AppTheme {
    static let lightSurface = Color(red: 250.0 / 255.0, green: 250.0 / 255.0, blue: 250.0 / 255.0)

    static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(nsColor: .windowBackgroundColor) : lightSurface
    }
}

enum AppTheme {
    static let panelRadius: CGFloat = 24
    static let cardRadius: CGFloat = 12
    static let rowRadius: CGFloat = 12

    static var softFill: Color {
        Color.primary.opacity(0.035)
    }

}
