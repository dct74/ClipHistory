import SwiftUI

struct PopupView: View {
    let store:         ClipboardStore
    @Bindable var settings: AppSettings
    @Bindable var state: PopupState
    let updateChecker: UpdateChecker
    let onSelect:      (ClipItem) -> Void
    let onDismiss:     () -> Void
    let onConfirm:     () -> Void
    let onDelete:      (UUID) -> Void
    let onUndo:        () -> Void

    // Single source of truth for filtering — same call the window controller
    // uses, so selection indices always agree between view and key handling.
    // Reading state.queryText / settings.hideImages here (and store.items inside
    // the store method) registers all three @Observable dependencies.
    var filtered: [ClipItem] {
        store.filtered(query: state.queryText, showImages: !settings.hideImages)
    }

    @Environment(\.colorScheme) private var colorScheme
    @State private var searchFocused = true
    @State private var suppressQueryReset = false
    @State private var lastHoverPt: CGPoint? = nil
    @State private var hoverEnabled         = false
    @State private var justOpened           = true

    var body: some View {
        VStack(spacing: 0) {
            header
            if updateChecker.updateAvailable {
                updateBanner
            }
            if !settings.showMenuBarIcon {
                menuBarHiddenBanner
            }
            itemList
                .onContinuousHover { phase in
                    guard case .active(let pt) = phase else { return }
                    if let last = lastHoverPt {
                        if !hoverEnabled {
                            let dx = pt.x - last.x, dy = pt.y - last.y
                            if dx*dx + dy*dy >= 36 { hoverEnabled = true }
                        }
                    } else {
                        lastHoverPt = pt
                    }
                }
            if store.canUndo {
                undoBar
            }
            hintsBar
        }
        // Measured against a real NSMenu on this system: the menu draws an
        // opaque system background (#FFFEFF light), not a vibrancy material —
        // `.menu`/`.ultraThinMaterial` both render greyer than a menu does.
        // The semantic colour follows the system light/dark appearance, and the
        // scroll indicator sits on the same surface. The drop shadow is the
        // window's own (see buildPanel).
        .background {
            RoundedRectangle(cornerRadius: AppTheme.panelRadius)
                .fill(AppTheme.surface(colorScheme))
        }
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.panelRadius))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.panelRadius)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
        }
        .overlay {
            if state.confirmation != nil {
                confirmationCard
            }
        }
        .onChange(of: state.queryText) { _, _ in
            // Opening the panel clears the query; that must not undo a restored
            // selection ("Remember Position").
            if !suppressQueryReset { state.selectedIndex = 0 }
        }
        .onChange(of: state.showToken) { _, _ in
            suppressQueryReset = true
            DispatchQueue.main.async { suppressQueryReset = false }
            searchFocused = true      // typing works immediately — no field to click
            justOpened    = true
            resetHoverState()
        }
        .onAppear { resetHoverState() }
    }

    private func resetHoverState() {
        lastHoverPt  = nil
        hoverEnabled = false
    }

    // MARK: - Confirmation card

    private var confirmationCard: some View {
        ConfirmationCard(
            title: L10n.s("Clear Clipboard History?", "清空剪贴板历史？"),
            message: L10n.s("Removes all \(store.items.count) stored items.\nPress ⌘Z afterwards to undo.",
                            "将删除已保存的全部 \(store.items.count) 条记录。\n之后按 ⌘Z 可撤销。"),
            confirmTitle: L10n.s("Clear All", "全部清空"),
            onCancel: { state.confirmation = nil },
            onConfirm: onConfirm
        )
    }

    /// Appears under the list after a delete, so an accidental one is one click
    /// (or ⌘Z) away from being restored.
    private var undoBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
            Text(L10n.s("Deleted", "已删除"))
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary.opacity(0.6))
            Spacer()
            Button { onUndo() } label: {
                Text(L10n.s("Undo ⌘Z", "撤销 ⌘Z"))
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.04))
        .transition(.opacity)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("CLIPHISTORY")
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .kerning(2)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.primary.opacity(0.8), .primary.opacity(0.4)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    if updateChecker.updateAvailable {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                            .offset(x: -2, y: -1)
                    }
                    Text(headerSubtitle)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.5))
                }

                Spacer()

                HStack(spacing: 8) {
                    Button { settings.hideImages.toggle() } label: {
                        Image(systemName: settings.hideImages ? "photo.slash" : "photo")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(settings.hideImages ? Color.accentColor : Color.primary.opacity(0.4))
                            .frame(width: 28, height: 28)
                            .background(
                                Circle().fill(settings.hideImages ? Color.accentColor.opacity(0.1)
                                                                  : Color.primary.opacity(0.03))
                            )
                    }
                    .buttonStyle(.plain)
                    .help(settings.hideImages ? L10n.s("Show images", "显示图片")
                                              : L10n.s("Hide images", "隐藏图片"))

                    Button { state.confirmation = .clearAll } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.red.opacity(0.4))
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.red.opacity(0.03)))
                    }
                    .buttonStyle(.plain)
                    .help(L10n.s("Clear All Data", "清空全部数据"))

                }
            }

            searchField
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var headerSubtitle: String {
        if filtered.isEmpty {
            return store.items.isEmpty ? L10n.s("Ready to capture", "等待复制")
                                       : L10n.s("No results", "无匹配结果")
        }
        return L10n.s("\(filtered.count) item\(filtered.count == 1 ? "" : "s")",
                      "\(filtered.count) 条")
    }

    // MARK: - Update banner

    private var updateBanner: some View {
        Button {
            if let url = updateChecker.releaseURL {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.green)
                Text(L10n.s("v\(updateChecker.latestVersion ?? "") available",
                            "v\(updateChecker.latestVersion ?? "") 可更新"))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.8))
                Spacer()
                Text(L10n.s("Download", "下载"))
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.1), in: Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.green.opacity(0.06))
        }
        .buttonStyle(.plain)
    }

    /// The icon is the usual route into Settings, so a hidden one has to be
    /// restorable from the popup — the global hotkey still opens it.
    private var menuBarHiddenBanner: some View {
        Button { settings.showMenuBarIcon = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "menubar.rectangle")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                Text(L10n.s("Menu bar icon is hidden", "菜单栏图标已隐藏"))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.75))
                Spacer()
                Text(L10n.s("Show again", "重新显示"))
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.1), in: Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.04))
        }
        .buttonStyle(.plain)
    }


    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(searchFocused ? Color.accentColor : Color.primary.opacity(0.3))
                .scaleEffect(searchFocused ? 1.1 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: searchFocused)

            ZStack(alignment: .leading) {
                if state.queryText.isEmpty {
                    Text(L10n.s("Search history…", "搜索历史…"))
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.25))
                }

                HStack(spacing: 1) {
                    if !state.searchText.isEmpty {
                        Text(state.searchText)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.primary.opacity(0.9))
                    }

                    // Being composed by the input method — underlined, like any
                    // other text field's marked text.
                    if !state.markedText.isEmpty {
                        Text(state.markedText)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.primary.opacity(0.9))
                            .underline()
                    }

                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 2, height: 16)
                        .opacity(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !state.queryText.isEmpty {
                Button { state.searchText = ""; state.markedText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.primary.opacity(0.2))
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { searchFocused = true }
    }

    // MARK: - Item list

    @ViewBuilder
    private var itemList: some View {
        if filtered.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, item in
                            itemRow(item, index: idx)
                                .id(item.id)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: state.selectedIndex) { _, newIdx in
                    if let item = filtered[safe: newIdx] {
                        if justOpened {
                            proxy.scrollTo(item.id)
                            justOpened = false
                        } else {
                            withAnimation(.easeInOut(duration: 0.12)) {
                                proxy.scrollTo(item.id)
                            }
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: AppTheme.cardRadius)
                    .fill(AppTheme.softFill)
                    .frame(width: 44, height: 44)
                Image(systemName: store.items.isEmpty ? "clipboard" : "magnifyingglass")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 4) {
                Text(store.items.isEmpty ? L10n.s("Nothing copied yet", "还没有复制记录")
                                         : L10n.s("No matches", "没有匹配项"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.82))
                Text(store.items.isEmpty ? L10n.s("Your recent clips will appear here.",
                                                 "复制过的内容会出现在这里。")
                                         : L10n.s("Try a different search, or show images.",
                                                 "换个关键词，或显示图片。"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }

    // MARK: - Row

    private func itemRow(_ item: ClipItem, index: Int) -> some View {
        let selected = index == state.selectedIndex
        return Button { onSelect(item) } label: {
            HStack(alignment: .center, spacing: 12) {
                appIconView(item, selected: selected)

                rowContent(for: item, selected: selected)
                    .frame(maxWidth: .infinity, alignment: .leading)

                trailingMeta(for: item, selected: selected)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: AppTheme.rowRadius)
                    .fill(selected ? Color.primary.opacity(0.06) : Color.clear)
            }
            // Fast easeOut instead of a spring: when the cursor sweeps across
            // several rows the highlight must keep up, not bounce behind it.
            .animation(.easeOut(duration: 0.1), value: selected)
        }
        .buttonStyle(.plain)
        .onHover { if $0 && hoverEnabled { state.selectedIndex = index } }
    }

    @ViewBuilder
    private func appIconView(_ item: ClipItem, selected: Bool) -> some View {
        Group {
            if let icon = item.sourceApp?.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05))
                    .frame(width: 28, height: 28)
                    .overlay {
                        Image(systemName: item.isImage ? "photo" : "doc.text")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(selected ? Color.accentColor : Color.primary.opacity(0.4))
                    }
            }
        }
    }

    @ViewBuilder
    private func rowContent(for item: ClipItem, selected: Bool) -> some View {
        switch item.content {

        case .text(let text):
            VStack(alignment: .leading, spacing: 2) {
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary.opacity(selected ? 1 : 0.85))

                if let app = item.sourceApp {
                    Text(app.name)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.5))
                }
            }

        case .image:
            HStack(spacing: 10) {
                if let img = store.cachedImage(for: item) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 48, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(.primary.opacity(0.05), lineWidth: 0.5)
                        }
                        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.s("Image", "图片"))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.9))
                    if let app = item.sourceApp {
                        Text(app.name)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary.opacity(0.5))
                    }
                }
            }
        }
    }

    private func trailingMeta(for item: ClipItem, selected: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            if selected {
                Button {
                    onDelete(item.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.red.opacity(0.4))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }

            Text(shortAge(item.date))
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.primary.opacity(0.2))
        }
        .frame(width: 44, alignment: .trailing)
        .animation(.spring(response: 0.2, dampingFraction: 0.6), value: selected)
    }

    // MARK: - Hints bar

    private var hintsBar: some View {
        HStack(spacing: 12) {
            hintChip(key: "↑↓", label: L10n.s("navigate", "移动"))
            hintChip(key: "↵",  label: L10n.s("paste", "粘贴"))
            hintChip(key: "esc", label: L10n.s("close", "关闭"))
            Spacer()
            if settings.hideImages {
                HStack(spacing: 4) {
                    Image(systemName: "photo.slash")
                    Text(L10n.s("Images hidden", "图片已隐藏"))
                }
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(Color.accentColor.opacity(0.4))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .opacity(0.4) // Make the whole bar very subtle
    }

    private func hintChip(key: String, label: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.3))
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 3))
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.primary.opacity(0.15))
        }
    }

    // MARK: - Age string

    private func shortAge(_ date: Date) -> String {
        let s = max(0, Int(Date.now.timeIntervalSince(date)))
        switch s {
        case ..<5:      return L10n.s("now", "刚刚")
        case ..<60:     return L10n.s("\(s)s", "\(s)秒")
        case ..<3600:   return L10n.s("\(s / 60)m", "\(s / 60)分")
        case ..<86400:  return L10n.s("\(s / 3600)h", "\(s / 3600)小时")
        case ..<604800: return L10n.s("\(s / 86400)d", "\(s / 86400)天")
        default:        return L10n.s("\(s / 604800)w", "\(s / 604800)周")
        }
    }
}

// MARK: - Helpers

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
