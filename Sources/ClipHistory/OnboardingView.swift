import AppKit
import SwiftUI

struct OnboardingView: View {
    @Bindable var settings: AppSettings
    var onDone: () -> Void

    @State private var axGranted = AXIsProcessTrusted()

    var body: some View {
        VStack(spacing: 0) {
            header
            steps
            footer
        }
        .frame(width: 500)
        .background {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()
        }
        .task {
            while !axGranted {
                // Leaving / closing the window cancels this task; without the
                // catch the loop would spin without ever suspending.
                do { try await Task.sleep(nanoseconds: 500_000_000) }
                catch { return }
                axGranted = AXIsProcessTrusted()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 5)
                .padding(.bottom, 4)

            Text(L10n.s("Set up ClipHistory", "设置 ClipHistory"))
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text(L10n.s("Three simple steps to clipboard mastery.", "三步完成剪贴板配置。"))
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.7))
        }
        .padding(.horizontal, 24)
        .padding(.top, 32)
        .padding(.bottom, 24)
    }

    // MARK: - Setup steps

    private var steps: some View {
        VStack(spacing: 14) {
            accessibilityCard
            launchAtLoginCard
            shortcutCard
        }
        .padding(.horizontal, 24)
    }

    private var accessibilityCard: some View {
        SetupCard(icon: "hand.raised.fill",
                  iconColor: axGranted ? .green : .orange,
                  title: L10n.s("Accessibility", "辅助功能"),
                  subtitle: L10n.s("Required to paste clips directly into your active apps.",
                             "直接粘贴到正在使用的 App 需要此权限。")) {
            VStack(alignment: .trailing, spacing: 8) {
                statusBadge(text: axGranted ? L10n.s("Granted", "已授权")
                                                : L10n.s("Required", "需要授权"),
                            color: axGranted ? .green : .orange)

                if !axGranted {
                    Button {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                        )
                    } label: {
                        Label(L10n.s("Grant", "去授权"), systemImage: "arrow.up.right.square")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.small)
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: axGranted)
    }

    private var launchAtLoginCard: some View {
        SetupCard(icon: "power.circle.fill",
                  iconColor: .accentColor,
                  title: L10n.s("Auto Launch", "开机启动"),
                  subtitle: L10n.s("Start ClipHistory automatically when you log in.",
                             "登录后自动启动 ClipHistory。")) {
            Toggle("", isOn: $settings.launchAtLogin)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    private var shortcutCard: some View {
        SetupCard(icon: "command.circle.fill",
                  iconColor: .blue,
                  title: L10n.s("Shortcut", "快捷键"),
                  subtitle: L10n.s("The key combination to show your clipboard history at the cursor.",
                             "在光标处展开剪贴板历史的组合键。")) {
            Text(settings.hotkey.displayString)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.8))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 16) {
            Text(axGranted
                 ? L10n.s("You're all set! Enjoy your new clipboard power.",
                          "全部就绪，开始使用吧。")
                 : L10n.s("You can finish now and grant access later in Settings.",
                          "也可以先完成后在设置里再授权。"))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Button(L10n.s("Get Started", "开始使用")) { onDone() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return)
                .tint(.accentColor)
        }
        .padding(24)
        .padding(.bottom, 8)
    }

    private func statusBadge(text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11, weight: .bold, design: .rounded))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Setup card

private struct SetupCard<Accessory: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(iconColor)
                .frame(width: 38, height: 38)
                .background(iconColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            accessory()
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: AppTheme.panelRadius))
    }
}
