import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let store:    ClipboardStore
    var onReopenOnboarding: (() -> Void)?

    @State private var showClearAlert = false

    private var knownSourceApps: [SourceApp] {
        var seen = Set<String>()
        return store.items
            .compactMap(\.sourceApp)
            .filter { seen.insert($0.bundleID).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                settingsHeader
                if !settings.unavailableHotkeys.isEmpty {
                    hotkeyWarning
                }
                generalSection
                shortcutSection
                pasteSection
                historySection
                privacySection
                footerLink
            }
            .padding(28)
        }
        .frame(width: 480, height: 700)
        .background {
            VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
                .ignoresSafeArea()
        }
        .alert(L10n.s("Clear clipboard history?", "清空剪贴板历史？"), isPresented: $showClearAlert) {
            Button(L10n.s("Clear All", "全部清空"), role: .destructive) { store.clearAll() }
            Button(L10n.s("Cancel", "取消"), role: .cancel) {}
        } message: {
            Text(L10n.s("This will permanently delete all \(store.items.count) stored items.",
                        "将永久删除已保存的 \(store.items.count) 条记录。"))
        }
    }

    // MARK: - Header

    private var settingsHeader: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.1), radius: 8, y: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text("ClipHistory")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(L10n.s("Light. Private. Fast. — v\(UpdateChecker.currentVersion)",
                            "轻快、私密、高效 — v\(UpdateChecker.currentVersion)"))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.8))
            }

            Spacer()

            HeaderMetric(value: "\(store.items.count)", label: L10n.s("Items", "条目"))
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: AppTheme.panelRadius))
    }

    /// Shown when the system refused a shortcut (another app owns it, or the
    /// same combination is bound to two actions).
    private var hotkeyWarning: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.orange)

            Text(L10n.s("These shortcuts could not be registered — another app may already use them: ",
                        "以下快捷键无法注册，可能已被其他 App 占用：")
                 + settings.unavailableHotkeys.sorted().joined(separator: ", "))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: AppTheme.panelRadius))
    }

    /// Rejects a combination already bound to another action.
    private func shortcutIsFree(_ candidate: HotkeyShortcut, current: HotkeyShortcut) -> Bool {
        [settings.hotkey, settings.pasteLatestHotkey,
         settings.pasteNextHotkey, settings.pasteAllHotkey]
            .filter { $0 != current }
            .allSatisfy { $0 != candidate }
    }

    // MARK: - Sections

    private var generalSection: some View {
        SettingsSection(title: L10n.s("General", "通用"),
                        subtitle: L10n.s("Launch behavior", "启动行为")) {
            SettingsRow(icon: "bolt.fill",
                        iconColor: .accentColor,
                        label: L10n.s("Launch at Login", "登录时启动"),
                        hint: L10n.s("Start ClipHistory automatically when you log in.",
                                     "登录后自动启动 ClipHistory。")) {
                Toggle("", isOn: $settings.launchAtLogin)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            Divider().padding(.horizontal, 16).opacity(0.5)

            SettingsRow(icon: "menubar.rectangle",
                        iconColor: .accentColor,
                        label: L10n.s("Show in Menu Bar", "在菜单栏显示图标"),
                        hint: L10n.s("Turn off to hide the icon; reopen the popup to bring it back.",
                                     "关掉可隐藏图标；再次打开面板即可恢复。")) {
                Toggle("", isOn: $settings.showMenuBarIcon)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
    }

    private var shortcutSection: some View {
        SettingsSection(title: L10n.s("Shortcut", "快捷键"),
                        subtitle: L10n.s("Global access", "全局唤起")) {
            VStack(alignment: .leading, spacing: 0) {
                SettingsRow(icon: "keyboard.fill",
                            iconColor: .blue,
                            label: L10n.s("Open Popup", "打开面板"),
                            hint: L10n.s("Shows your history at the text cursor.",
                                         "在文字光标处展开历史列表。")) {
                    HotkeyRecorder(hotkey: $settings.hotkey) { candidate in
                        shortcutIsFree(candidate, current: settings.hotkey)
                    }
                    .frame(width: 162, height: 32)
                }

                Text(L10n.s("Click the field, then press your desired shortcut.",
                            "点击输入框，然后按下想用的组合键。"))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            }
        }
    }

    private var pasteSection: some View {
        SettingsSection(title: L10n.s("Paste", "粘贴"),
                        subtitle: L10n.s("Keyboard driven", "键盘操作")) {
            VStack(alignment: .leading, spacing: 0) {
                SettingsRow(icon: "arrow.down.doc.fill",
                            iconColor: .purple,
                            label: L10n.s("Paste Latest", "粘贴最近一条"),
                            hint: L10n.s("Pastes the newest clip in your history.",
                                         "粘贴历史里最新的一条。")) {
                    HotkeyRecorder(hotkey: $settings.pasteLatestHotkey) { candidate in
                        shortcutIsFree(candidate, current: settings.pasteLatestHotkey)
                    }
                    .frame(width: 162, height: 32)
                }

                Divider().padding(.horizontal, 16).opacity(0.5)

                SettingsRow(icon: "arrow.down.right.and.arrow.up.left",
                            iconColor: .purple,
                            label: L10n.s("Paste Next Item", "依次粘贴"),
                            hint: L10n.s("Each press pastes the next clip, oldest first.",
                                         "每按一次粘贴下一条，从最早的一条开始。")) {
                    HotkeyRecorder(hotkey: $settings.pasteNextHotkey) { candidate in
                        shortcutIsFree(candidate, current: settings.pasteNextHotkey)
                    }
                    .frame(width: 162, height: 32)
                }

                Divider().padding(.horizontal, 16).opacity(0.5)

                SettingsRow(icon: "text.line.first.and.arrowtriangle.forward",
                            iconColor: .purple,
                            label: L10n.s("Paste All Items", "全部粘贴"),
                            hint: L10n.s("Joins text clips into one paste; images paste one by one.",
                                         "文本合并为一次粘贴，图片逐条粘贴。")) {
                    HotkeyRecorder(hotkey: $settings.pasteAllHotkey) { candidate in
                        shortcutIsFree(candidate, current: settings.pasteAllHotkey)
                    }
                    .frame(width: 162, height: 32)
                }

            }
        }
    }

    private var historySection: some View {
        SettingsSection(title: L10n.s("History", "历史"),
                        subtitle: L10n.s("Management", "管理")) {
            VStack(spacing: 0) {
                SettingsRow(icon: "tray.full.fill",
                            iconColor: .accentColor,
                            label: L10n.s("Max Items", "最大条数"),
                            hint: L10n.s("Oldest clips are trimmed away.",
                                         "超出后最早记录会被清理。")) {
                    HStack(spacing: 12) {
                        Text("\(settings.maxItems)")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .frame(minWidth: 34, alignment: .trailing)
                        Stepper("", value: $settings.maxItems, in: 5...500)
                            .labelsHidden()
                    }
                }

                Divider().padding(.horizontal, 16).opacity(0.5)

                SettingsRow(icon: "arrow.up.to.line",
                            iconColor: .accentColor,
                            label: L10n.s("Remember Position", "记住位置"),
                            hint: L10n.s("Reopen where you left off instead of the start.",
                                         "下次打开时回到上次浏览的位置。")) {
                    Toggle("", isOn: $settings.rememberScrollPosition)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                Divider().padding(.horizontal, 16).opacity(0.5)

                SettingsRow(icon: "clock.fill",
                            iconColor: .secondary,
                            label: L10n.s("Capacity", "当前容量"),
                            hint: L10n.s("Current amount of stored clips.",
                                         "目前已保存的记录数。")) {
                    Text(L10n.s("\(store.items.count) clips", "\(store.items.count) 条"))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Divider().padding(.horizontal, 16).opacity(0.5)

                HStack(spacing: 12) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.red)
                        .frame(width: 32, height: 32)
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.s("Clear All Data", "清空全部数据"))
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                        Text(L10n.s("This removes all clips permanently.",
                                    "将永久删除所有记录。"))
                            .font(.system(size: 11.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary.opacity(0.6))
                    }

                    Spacer()

                    Button(L10n.s("Clear", "清空")) {
                        showClearAlert = true
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.regular)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
    }

    private var privacySection: some View {
        SettingsSection(title: L10n.s("Privacy", "隐私"),
                        subtitle: L10n.s("Exclusions", "排除项")) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.green)
                        .frame(width: 28, height: 28)
                        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                    Text(L10n.s("Sensitive content and password managers are always ignored. You can manually exclude specific apps below.",
                                "敏感内容与密码管理器始终会被忽略。你也可以在下面手动排除特定 App。"))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)

                Divider().padding(.horizontal, 16).opacity(0.5)

                if knownSourceApps.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "app.dashed")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.secondary.opacity(0.3))
                            .frame(width: 32, height: 32)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.s("No apps detected", "尚未检测到 App"))
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                            Text(L10n.s("Apps appear here after they copy content.",
                                        "App 复制内容后会出现在这里。"))
                                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary.opacity(0.4))
                        }
                        Spacer()
                    }
                    .padding(16)
                } else {
                    ForEach(Array(knownSourceApps.enumerated()), id: \.element.bundleID) { i, app in
                        if i > 0 { Divider().padding(.horizontal, 16).opacity(0.5) }
                        appExcludeRow(app)
                    }
                }
            }
        }
    }

    private func appExcludeRow(_ app: SourceApp) -> some View {
        let excluded = settings.excludedBundleIDs.contains(app.bundleID)
        return HStack(spacing: 12) {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(0.05))
                    .frame(width: 32, height: 32)
                    .overlay {
                        Image(systemName: "app.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary.opacity(0.5))
                    }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Text(excluded ? L10n.s("Excluded", "已排除") : L10n.s("Monitored", "已监控"))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(excluded ? Color.accentColor : Color.secondary.opacity(0.6))
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { excluded },
                set: { on in
                    if on { settings.excludedBundleIDs.insert(app.bundleID) }
                    else  { settings.excludedBundleIDs.remove(app.bundleID) }
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var footerLink: some View {
        Button {
            onReopenOnboarding?()
        } label: {
            Label(L10n.s("Restart Guide", "重新查看向导"), systemImage: "arrow.clockwise")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.4))
        }
        .buttonStyle(.plain)
        .padding(.vertical, 8)
    }
}

// MARK: - Header metric

private struct HeaderMetric: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(label.uppercased())
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(.secondary.opacity(0.4))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Reusable section container

private struct SettingsSection<Content: View>: View {
    let title:    String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.9))
                Spacer()
                Text(subtitle)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.4))
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                content()
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: AppTheme.panelRadius))
        }
    }
}

// MARK: - Single labeled row

private struct SettingsRow<Trailing: View>: View {
    let icon: String
    var iconColor: Color = .accentColor
    let label: String
    var hint:  String? = nil
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(iconColor)
                .frame(width: 32, height: 32)
                .background(iconColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                if let hint {
                    Text(hint)
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

// MARK: - Visual Effect View helper

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
