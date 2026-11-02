import SwiftUI

/// Destructive-action confirmation rendered inside the popup.
///
/// It has to live in the panel rather than an `NSAlert`: the panel never
/// activates the app, so a modal alert would never receive ⏎ (key events route
/// to the app the user came from). Kept as a standalone view so its layout can
/// be rendered and measured without the whole popup.
struct ConfirmationCard: View {
    let title:        String
    let message:      String
    let confirmTitle: String
    let onCancel:     () -> Void
    let onConfirm:    () -> Void

    // Card metrics. The button row splits whatever width is left, so nothing
    // has to be hard-coded per label (a fixed min width used to squeeze
    // "Cancel" down to ~30 pt).
    static let width:     CGFloat = 316
    static let inset:     CGFloat = 20
    static let buttonGap: CGFloat = 10

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.92))
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Self.inset)
            .padding(.top, 24)
            .padding(.bottom, 20)

            Divider().opacity(0.5)

            HStack(spacing: Self.buttonGap) {
                Button(action: onCancel) { Text(L10n.s("Cancel", "取消")) }
                    .buttonStyle(CardButtonStyle(fill: Color.primary.opacity(0.07),
                                                 textColor: .primary))
                Button(action: onConfirm) { Text(confirmTitle) }
                    .buttonStyle(CardButtonStyle(fill: Color.red.opacity(0.85),
                                                 textColor: .white))
            }
            .padding(.horizontal, Self.inset)
            .padding(.vertical, 16)
        }
        .frame(width: Self.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
    }
}

/// Dialog-style button: fills the width it is given, so both buttons always
/// match the card instead of shrinking to their label.
private struct CardButtonStyle: ButtonStyle {
    let fill: Color
    let textColor: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(textColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(fill, in: RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}
