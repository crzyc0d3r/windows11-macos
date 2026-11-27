import AppKit
import FileExplorerCore
import FileExplorerDesign
import SwiftUI

public struct Win11ContextMenuOverlay: View {
    public let store: ExplorerStore
    public let anchorPoint: CGPoint?

    @Environment(\.fluentTheme) private var theme
    @State private var measuredClickPoint: CGPoint?
    @State private var activeSubmenu: ContextSubmenu?
    @State private var showMoreOptions: Bool = false
    @State private var openWithApps: [AppChoice] = []
    @State private var escapeMonitor: Any?

    private enum ContextSubmenu: Hashable {
        case openWith
        case viewMode
        case sortBy
        case groupBy
        case newItem
    }

    public init(store: ExplorerStore, anchorPoint: CGPoint? = nil) {
        self.store = store
        self.anchorPoint = anchorPoint
    }

    public var body: some View {
        if let target = store.contextMenuTarget {
            GeometryReader { geo in
                let rawOrigin = resolvedOrigin(in: geo.size)
                let menuWidth: CGFloat = 264
                let estimatedHeight = estimatedMenuHeight(for: target)
                let clampedX = min(max(12, rawOrigin.x), max(12, geo.size.width - menuWidth - 12))
                let clampedY = min(max(12, rawOrigin.y), max(12, geo.size.height - estimatedHeight - 12))
                let opensSubmenuLeft = (clampedX + menuWidth + 210) > geo.size.width

                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .onTapGesture {
                            dismiss()
                        }

                    MouseCoordinateProbe { point in
                        if anchorPoint == nil && measuredClickPoint == nil {
                            measuredClickPoint = point
                        }
                    }
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)

                    HStack(alignment: .top, spacing: 6) {
                        if opensSubmenuLeft, let activeSubmenu {
                            submenuPanel(for: activeSubmenu, target: target)
                        }

                        mainMenuCard(for: target, width: menuWidth)

                        if !opensSubmenuLeft, let activeSubmenu {
                            submenuPanel(for: activeSubmenu, target: target)
                        }
                    }
                    .offset(
                        x: opensSubmenuLeft && activeSubmenu != nil ? max(12, clampedX - 206) : clampedX,
                        y: clampedY
                    )
                }
                .task(id: target) {
                    activeSubmenu = nil
                    showMoreOptions = false
                    await loadOpenWithIfNeeded(for: target)
                }
            }
            .onAppear {
                installEscapeMonitor()
            }
            .onDisappear {
                removeEscapeMonitor()
                measuredClickPoint = nil
            }
        }
    }

    private func resolvedOrigin(in size: CGSize) -> CGPoint {
        if let anchorPoint {
            return anchorPoint
        }
        if let measuredClickPoint {
            return measuredClickPoint
        }
        return CGPoint(x: max(24, size.width * 0.34), y: max(24, size.height * 0.24))
    }

    private func estimatedMenuHeight(for target: ContextMenuTarget) -> CGFloat {
        switch target {
        case .item, .selection, .sidebarItem:
            return showMoreOptions ? 560 : 450
        case .background:
            return 320
        case .tab:
            return 140
        }
    }

    @ViewBuilder
    private func mainMenuCard(for target: ContextMenuTarget, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            switch target {
            case .item(let item):
                itemMenuBody(items: [item], isSidebar: false)
            case .selection(let items):
                let resolved = items.isEmpty ? store.selectedItems : items
                if resolved.isEmpty {
                    backgroundMenuBody(location: store.activeTab.location)
                } else {
                    itemMenuBody(items: resolved, isSidebar: false)
                }
            case .sidebarItem(let url):
                let resolved = InspectorFormatters.resolveItem(for: url, in: store)
                itemMenuBody(items: [resolved], isSidebar: true)
            case .background(let location):
                backgroundMenuBody(location: location)
            case .tab(let tabID):
                tabMenuBody(tabID: tabID)
            }
        }
        .padding(.vertical, 6)
        .frame(width: width)
        .background(menuSurfaceShape.fill(theme.palette.elevatedFlyout))
        .background(
            MicaBackground(variant: .acrylic)
                .clipShape(menuSurfaceShape)
        )
        .overlay(
            menuSurfaceShape
                .stroke(theme.palette.borderSubtle, lineWidth: 1)
        )
        .shadow(
            color: Color.black.opacity(theme.colorScheme == .dark ? 0.45 : 0.16),
            radius: 18,
            x: 0,
            y: 8
        )
    }

    private var menuSurfaceShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
    }

    @ViewBuilder
    private func itemMenuBody(items: [FileItem], isSidebar: Bool) -> some View {
        let primary = items[0]
        let urls = items.map(\.url)
        let isTrash = store.activeTab.location == .recycleBin

        if !isTrash {
            topActionIconBar(items: items, urls: urls)
            menuDivider()
        }

        if isTrash {
            menuRow(title: "Restore", systemImage: "arrow.uturn.backward") {
                store.restoreFromTrash(urls: urls)
                dismiss()
            }
            menuRow(title: "Delete permanently", systemImage: "trash.slash", isDestructive: true) {
                store.permanentDeleteItems(urls: urls)
                dismiss()
            }
            menuDivider()
            menuRow(title: "Properties", systemImage: "info.circle") {
                store.showProperties(for: primary.url)
                dismiss()
            }
        } else {
            menuRow(
                title: items.count > 1 ? "Open (\(items.count) items)" : "Open",
                systemImage: "arrow.up.right.square",
                shortcut: "⏎"
            ) {
                if items.count == 1 {
                    store.openItem(primary)
                } else {
                    for item in items where !item.isDirectory || item.isPackage {
                        store.openItem(item)
                    }
                }
                dismiss()
            }

            if items.count == 1 && (!primary.isDirectory || primary.isPackage) {
                submenuRow(title: "Open with", systemImage: "app.badge", submenu: .openWith)
            }

            if items.count == 1 && primary.isDirectory && !primary.isPackage {
                menuRow(title: "Open in new tab", systemImage: "plus.rectangle.on.rectangle") {
                    store.newTab(at: .folder(primary.url), activate: true)
                    dismiss()
                }

                let isPinned = store.isPinned(url: primary.url)
                menuRow(
                    title: isPinned ? "Unpin from Quick access" : "Pin to Quick access",
                    systemImage: isPinned ? "pin.slash" : "pin"
                ) {
                    if isPinned {
                        store.unpinFolder(url: primary.url)
                    } else {
                        store.pinFolder(url: primary.url, title: primary.name)
                    }
                    dismiss()
                }
            }

            if !isSidebar {
                let isFav = store.isFavorite(url: primary.url)
                menuRow(
                    title: isFav ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: isFav ? "star.slash" : "star"
                ) {
                    for url in urls {
                        if isFav {
                            store.removeFavorite(url: url)
                        } else {
                            store.addFavorite(url: url)
                        }
                    }
                    dismiss()
                }
            }

            menuRow(title: "Copy as path", systemImage: "link", shortcut: "⌥⌘C") {
                InspectorFormatters.copyPathsToPasteboard(urls)
                dismiss()
            }

            menuDivider()

            menuRow(title: "Compress to ZIP file", systemImage: "doc.zipper") {
                store.zipItems(urls: urls)
                dismiss()
            }

            if items.count == 1 && primary.kind == .archive {
                menuRow(title: "Extract all...", systemImage: "archivebox") {
                    store.extractArchive(at: primary.url)
                    dismiss()
                }
            }

            menuRow(title: "Open in Terminal", systemImage: "terminal") {
                if !store.snapshotMode {
                    InspectorFormatters.openInTerminal(url: primary.url, isDirectory: primary.isDirectory && !primary.isPackage)
                }
                dismiss()
            }

            menuDivider()

            if items.count == 1 && !primary.isDirectory {
                menuRow(title: "Quick Look", systemImage: "eye", shortcut: "Space") {
                    store.setSelection([primary.url])
                    if !store.isQuickLookPresented {
                        store.toggleQuickLook()
                    }
                    dismiss()
                }
            }

            menuRow(title: "Properties", systemImage: "info.circle", shortcut: "⌘I") {
                store.showProperties(for: primary.url)
                dismiss()
            }

            menuRow(
                title: showMoreOptions ? "Show fewer options" : "Show more options",
                systemImage: showMoreOptions ? "chevron.up.circle" : "ellipsis.circle"
            ) {
                showMoreOptions.toggle()
            }

            if showMoreOptions {
                menuDivider()
                menuRow(title: "Duplicate", systemImage: "plus.square.on.square") {
                    store.duplicateItems(urls: urls)
                    dismiss()
                }
                menuRow(title: "Reveal in Finder", systemImage: "finder") {
                    store.revealInFinder(primary.url)
                    dismiss()
                }
                menuRow(title: "Delete permanently", systemImage: "trash.slash", isDestructive: true) {
                    store.permanentDeleteItems(urls: urls)
                    dismiss()
                }
            }
        }
    }

    private func topActionIconBar(items: [FileItem], urls: [URL]) -> some View {
        let primary = items[0]
        let hasClipboard = store.clipboardPayload != nil
        let showPaste = hasClipboard && (primary.isDirectory && !primary.isPackage || store.activeTab.location.urlIfFolder != nil)

        return HStack(spacing: 4) {
            actionIconTile(title: "Cut", systemImage: "scissors") {
                store.cutItems(urls: urls)
                dismiss()
            }
            actionIconTile(title: "Copy", systemImage: "doc.on.doc") {
                store.copyItems(urls: urls)
                dismiss()
            }
            if showPaste {
                actionIconTile(title: "Paste", systemImage: "doc.on.clipboard") {
                    if primary.isDirectory && !primary.isPackage {
                        store.paste(into: primary.url)
                    } else {
                        store.pasteIntoCurrentFolder()
                    }
                    dismiss()
                }
            }
            actionIconTile(title: "Rename", systemImage: "pencil", isEnabled: items.count == 1) {
                store.beginInlineRename(for: primary.url)
                dismiss()
            }
            actionIconTile(title: "Share", systemImage: "square.and.arrow.up") {
                if !store.snapshotMode {
                    InspectorFormatters.shareItems(urls)
                } else {
                    InspectorFormatters.copyPathsToPasteboard(urls)
                }
                dismiss()
            }
            actionIconTile(title: "Delete", systemImage: "trash", isDestructive: true) {
                store.deleteItems(urls: urls)
                dismiss()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func actionIconTile(
        title: String,
        systemImage: String,
        isEnabled: Bool = true,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        ContextIconTileButton(
            title: title,
            systemImage: systemImage,
            isEnabled: isEnabled,
            isDestructive: isDestructive,
            action: action
        )
    }

    @ViewBuilder
    private func backgroundMenuBody(location: ExplorerLocation) -> some View {
        submenuRow(title: "View", systemImage: "square.grid.2x2", submenu: .viewMode)
        submenuRow(title: "Sort by", systemImage: "arrow.up.arrow.down", submenu: .sortBy)
        submenuRow(title: "Group by", systemImage: "rectangle.3.group", submenu: .groupBy)

        menuDivider()

        menuRow(title: "Refresh", systemImage: "arrow.clockwise", shortcut: "⌘R") {
            store.refresh()
            dismiss()
        }

        menuRow(
            title: "Paste",
            systemImage: "doc.on.clipboard",
            shortcut: "⌘V",
            isEnabled: store.clipboardPayload != nil && location.urlIfFolder != nil
        ) {
            store.pasteIntoCurrentFolder()
            dismiss()
        }

        menuDivider()

        submenuRow(title: "New", systemImage: "plus.circle", submenu: .newItem)

        if let folderURL = location.urlIfFolder {
            menuRow(title: "Open in Terminal", systemImage: "terminal") {
                if !store.snapshotMode {
                    InspectorFormatters.openInTerminal(url: folderURL, isDirectory: true)
                }
                dismiss()
            }
            menuDivider()
            menuRow(title: "Properties", systemImage: "info.circle") {
                store.showProperties(for: folderURL)
                dismiss()
            }
        }
    }

    private func tabMenuBody(tabID: UUID) -> some View {
        Group {
            menuRow(title: "Duplicate tab", systemImage: "plus.square.on.square") {
                store.duplicateTab(id: tabID)
                dismiss()
            }
            menuRow(title: "Close tab", systemImage: "xmark", isEnabled: store.tabs.count > 1) {
                store.closeTab(id: tabID)
                dismiss()
            }
            menuRow(title: "Close other tabs", systemImage: "xmark.circle", isEnabled: store.tabs.count > 1) {
                store.closeOtherTabs(keeping: tabID)
                dismiss()
            }
        }
    }

    @ViewBuilder
    private func submenuPanel(for submenu: ContextSubmenu, target: ContextMenuTarget) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            switch submenu {
            case .openWith:
                if let targetItem = primaryItem(from: target) {
                    if openWithApps.isEmpty {
                        menuRow(title: "Preview", systemImage: "doc.text.image") {
                            store.openItem(targetItem.url, withApplication: URL(fileURLWithPath: "/System/Applications/Preview.app"))
                            dismiss()
                        }
                        menuRow(title: "TextEdit", systemImage: "doc.plaintext") {
                            store.openItem(targetItem.url, withApplication: URL(fileURLWithPath: "/System/Applications/TextEdit.app"))
                            dismiss()
                        }
                    } else {
                        ForEach(openWithApps) { app in
                            menuRow(title: app.name, systemImage: "app") {
                                store.openItem(targetItem.url, withApplication: app.url)
                                dismiss()
                            }
                        }
                    }
                }

            case .viewMode:
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    menuRow(
                        title: mode.displayTitle,
                        systemImage: mode.iconSystemName,
                        isChecked: store.activeTab.viewMode == mode
                    ) {
                        store.setViewMode(mode)
                        dismiss()
                    }
                }

            case .sortBy:
                ForEach(SortField.allCases, id: \.self) { field in
                    menuRow(
                        title: field.displayTitle,
                        systemImage: "arrow.up.arrow.down",
                        isChecked: store.activeTab.sortField == field
                    ) {
                        store.setSort(field: field, order: store.activeTab.sortOrder)
                        dismiss()
                    }
                }
                menuDivider()
                menuRow(
                    title: "Ascending",
                    systemImage: "arrow.up",
                    isChecked: store.activeTab.sortOrder == .ascending
                ) {
                    store.setSort(field: store.activeTab.sortField, order: .ascending)
                    dismiss()
                }
                menuRow(
                    title: "Descending",
                    systemImage: "arrow.down",
                    isChecked: store.activeTab.sortOrder == .descending
                ) {
                    store.setSort(field: store.activeTab.sortField, order: .descending)
                    dismiss()
                }

            case .groupBy:
                ForEach(GroupByField.allCases, id: \.self) { group in
                    menuRow(
                        title: group.displayTitle,
                        systemImage: "rectangle.3.group",
                        isChecked: store.activeTab.groupBy == group
                    ) {
                        store.setGroupBy(group)
                        dismiss()
                    }
                }

            case .newItem:
                menuRow(title: "Folder", systemImage: "folder.badge.plus") {
                    store.newFolder()
                    dismiss()
                }
                menuDivider()
                menuRow(title: "Text Document (.txt)", systemImage: "doc.plaintext") {
                    store.newFile(named: "New Text Document", fileExtension: "txt")
                    dismiss()
                }
                menuRow(title: "Markdown Document (.md)", systemImage: "doc.text") {
                    store.newFile(named: "README", fileExtension: "md")
                    dismiss()
                }
                menuRow(title: "JSON File (.json)", systemImage: "curlybraces") {
                    store.newFile(named: "data", fileExtension: "json")
                    dismiss()
                }
                menuRow(title: "Shell Script (.sh)", systemImage: "terminal") {
                    store.newFile(named: "script", fileExtension: "sh")
                    dismiss()
                }
                menuRow(title: "Rich Text Document (.rtf)", systemImage: "doc.richtext") {
                    store.newFile(named: "Document", fileExtension: "rtf")
                    dismiss()
                }
            }
        }
        .padding(.vertical, 6)
        .frame(width: 200)
        .background(menuSurfaceShape.fill(theme.palette.elevatedFlyout))
        .background(
            MicaBackground(variant: .acrylic)
                .clipShape(menuSurfaceShape)
        )
        .overlay(
            menuSurfaceShape
                .stroke(theme.palette.borderSubtle, lineWidth: 1)
        )
        .shadow(
            color: Color.black.opacity(theme.colorScheme == .dark ? 0.45 : 0.16),
            radius: 16,
            x: 0,
            y: 6
        )
    }

    private func menuRow(
        title: String,
        systemImage: String,
        shortcut: String? = nil,
        isChecked: Bool = false,
        isEnabled: Bool = true,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        ContextMenuRowButton(
            title: title,
            systemImage: systemImage,
            shortcut: shortcut,
            isChecked: isChecked,
            hasSubmenu: false,
            isSubmenuOpen: false,
            isEnabled: isEnabled,
            isDestructive: isDestructive,
            onHoverChanged: { hovering in
                if hovering {
                    activeSubmenu = nil
                }
            },
            action: action
        )
    }

    private func submenuRow(title: String, systemImage: String, submenu: ContextSubmenu) -> some View {
        ContextMenuRowButton(
            title: title,
            systemImage: systemImage,
            shortcut: nil,
            isChecked: false,
            hasSubmenu: true,
            isSubmenuOpen: activeSubmenu == submenu,
            isEnabled: true,
            isDestructive: false,
            onHoverChanged: { hovering in
                if hovering {
                    activeSubmenu = submenu
                }
            },
            action: {
                activeSubmenu = activeSubmenu == submenu ? nil : submenu
            }
        )
    }

    private func menuDivider() -> some View {
        Divider()
            .overlay(theme.palette.borderSubtle)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
    }

    private func primaryItem(from target: ContextMenuTarget) -> FileItem? {
        switch target {
        case .item(let item):
            return item
        case .selection(let items):
            return items.first ?? store.primarySelectedItem
        case .sidebarItem(let url):
            return InspectorFormatters.resolveItem(for: url, in: store)
        default:
            return nil
        }
    }

    private func loadOpenWithIfNeeded(for target: ContextMenuTarget) async {
        guard let item = primaryItem(from: target), !item.isDirectory || item.isPackage else {
            openWithApps = []
            return
        }
        let info = await InspectorMetadataLoader.load(for: item, store: store)
        if !Task.isCancelled {
            openWithApps = info.metadata.openWithApps
        }
    }

    private func dismiss() {
        activeSubmenu = nil
        store.dismissContextMenu()
    }

    private func installEscapeMonitor() {
        removeEscapeMonitor()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                Task { @MainActor in
                    dismiss()
                }
                return nil
            }
            return event
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }
}

private struct ContextIconTileButton: View {
    let title: String
    let systemImage: String
    let isEnabled: Bool
    let isDestructive: Bool
    let action: () -> Void

    @Environment(\.fluentTheme) private var theme
    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(
                        !isEnabled
                            ? theme.palette.textSecondary.opacity(0.45)
                            : (isDestructive ? theme.palette.dangerRed : theme.palette.textPrimary)
                    )
                    .frame(width: 36, height: 26)
                Text(title)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(isEnabled ? theme.palette.textSecondary : theme.palette.textSecondary.opacity(0.45))
                    .lineLimit(1)
            }
            .frame(width: 40, height: 42)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered && isEnabled ? theme.palette.hoverFill : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private struct ContextMenuRowButton: View {
    let title: String
    let systemImage: String
    let shortcut: String?
    let isChecked: Bool
    let hasSubmenu: Bool
    let isSubmenuOpen: Bool
    let isEnabled: Bool
    let isDestructive: Bool
    let onHoverChanged: (Bool) -> Void
    let action: () -> Void

    @Environment(\.fluentTheme) private var theme
    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: isChecked ? "checkmark" : systemImage)
                    .font(.system(size: 12.5, weight: isChecked ? .bold : .regular))
                    .foregroundStyle(foregroundColor)
                    .frame(width: 16, alignment: .center)

                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(foregroundColor)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.palette.textSecondary)
                }

                if hasSubmenu {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.palette.textSecondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill((isHovered || isSubmenuOpen) && isEnabled ? theme.palette.hoverFill : Color.clear)
            )
            .padding(.horizontal, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering in
            isHovered = hovering
            onHoverChanged(hovering)
        }
    }

    private var foregroundColor: Color {
        if !isEnabled {
            return theme.palette.textSecondary.opacity(0.45)
        }
        if isDestructive {
            return theme.palette.dangerRed
        }
        return theme.palette.textPrimary
    }
}

private struct MouseCoordinateProbe: NSViewRepresentable {
    let onLocate: (CGPoint) -> Void

    func makeNSView(context: Context) -> NSView {
        ProbeView(onLocate: onLocate)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ProbeView: NSView {
        let onLocate: (CGPoint) -> Void
        var didReport = false

        init(onLocate: @escaping (CGPoint) -> Void) {
            self.onLocate = onLocate
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !didReport, let window, let contentView = window.contentView else { return }
            didReport = true
            let windowPoint = window.mouseLocationOutsideOfEventStream
            let bounds = contentView.bounds
            guard bounds.contains(windowPoint) else { return }
            let swiftUIPoint = CGPoint(x: windowPoint.x, y: bounds.height - windowPoint.y)
            Task { @MainActor in
                onLocate(swiftUIPoint)
            }
        }
    }
}
