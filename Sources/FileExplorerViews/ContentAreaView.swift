import AppKit
import FileExplorerCore
import FileExplorerDesign
import SwiftUI

public struct ContentAreaView: View {
    public let store: ExplorerStore

    @Environment(\.fluentTheme) private var theme
    @FocusState private var isCanvasFocused: Bool

    @State private var itemFrames: [URL: CGRect] = [:]
    @State private var marqueeStart: CGPoint?
    @State private var marqueeCurrent: CGPoint?
    @State private var isCanvasDropTargeted = false
    @State private var gridColumnCount = 1
    @State private var typeAheadBuffer = ""
    @State private var typeAheadTask: Task<Void, Never>?

    public init(store: ExplorerStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let warningURL = store.tccPermissionWarningURL {
                tccPermissionBanner(for: warningURL)
            }

            routedContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.palette.contentCanvas)
        .focusable()
        .focused($isCanvasFocused)
        .focusEffectDisabled()
        .onKeyPress { press in
            handleKeyPress(press)
        }
    }

    // MARK: - Routing

    @ViewBuilder
    private var routedContent: some View {
        switch store.activeTab.location {
        case .home:
            HomeView(store: store)
        case .thisPC:
            ThisPCView(store: store)
        case .gallery:
            GalleryView(store: store)
        case .network:
            NetworkDiscoveryView(store: store)
        case .folder, .recycleBin, .search:
            folderCanvasView
        }
    }

    private var shouldShowSearchFilterBar: Bool {
        if case .search = store.activeTab.location {
            return true
        }
        return store.isSearching
    }

    private var folderCanvasView: some View {
        VStack(spacing: 0) {
            if shouldShowSearchFilterBar {
                SearchFilterBarView(store: store)
            }

            if store.activeTab.location == .recycleBin {
                recycleBinBar
            }

            ZStack(alignment: .topLeading) {
                if store.currentItems.isEmpty {
                    emptyFolderState
                } else if store.activeTab.viewMode == .details {
                    DetailsListView(store: store) {
                        isCanvasFocused = true
                    }
                } else {
                    IconGridViews(
                        store: store,
                        onFocusCanvas: { isCanvasFocused = true },
                        onColumnCountChange: { gridColumnCount = $0 }
                    )
                }

                if let rect = marqueeRect {
                    Rectangle()
                        .fill(theme.palette.accentBlue.opacity(0.18))
                        .overlay(
                            Rectangle()
                                .stroke(theme.palette.accentBlue.opacity(0.85), lineWidth: 1)
                        )
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)
                }

                if isCanvasDropTargeted {
                    RoundedRectangle(cornerRadius: theme.cornerRadiusMedium, style: .continuous)
                        .stroke(theme.palette.accentBlue, lineWidth: 2)
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: "ContentCanvasSpace")
            .onPreferenceChange(ItemFramePreferenceKey.self) { frames in
                itemFrames = frames
            }
            .contentShape(Rectangle())
            .onTapGesture {
                isCanvasFocused = true
                store.cancelInlineRename()
                store.deselectAll()
            }
            .gesture(marqueeDragGesture)
            .overlay {
                RightClickHandlerOverlay {
                    isCanvasFocused = true
                    store.showContextMenu(for: .background(store.activeTab.location))
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isCanvasDropTargeted) { providers in
                guard let destination = store.activeTab.location.urlIfFolder else { return false }
                return ExplorerDropHelper.handleDrop(providers: providers, into: destination, store: store)
            }
        }
    }

    // MARK: - Banners & Special States

    private func tccPermissionBanner(for url: URL) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 15))
                .foregroundStyle(Color(red: 0.82, green: 0.50, blue: 0.04))

            Text("macOS Privacy & Security blocked access to \"\(url.lastPathComponent)\".")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button {
                if let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(settingsURL)
                }
            } label: {
                Text("Open System Settings")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: theme.cornerRadiusSmall, style: .continuous)
                            .fill(theme.palette.accentBlue)
                    )
            }
            .buttonStyle(.plain)

            Button {
                store.dismissTCCWarning()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.palette.textSecondary)
                    .padding(4)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(red: 0.98, green: 0.78, blue: 0.25).opacity(0.16))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.palette.borderSubtle)
                .frame(height: 1)
        }
    }

    private var recycleBinBar: some View {
        HStack(spacing: 10) {
            FluentIconView(kind: store.isTrashEmpty ? .recycleBinEmpty : .recycleBinFull, size: 18)
            Text(store.isTrashEmpty ? "Trash is empty" : "\(store.trashItemCount) \(store.trashItemCount == 1 ? "item" : "items") in Trash")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(theme.palette.textPrimary)

            Spacer()

            if !store.selectedItems.isEmpty {
                Button("Restore selected") {
                    store.restoreFromTrash(urls: store.selectedItems.map(\.url))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if !store.isTrashEmpty {
                Button("Empty Trash") {
                    store.emptyTrash()
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.palette.dangerRed)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(theme.palette.commandBar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.palette.borderSubtle)
                .frame(height: 1)
        }
    }

    private var emptyFolderState: some View {
        VStack(spacing: 10) {
            FluentIconView(
                kind: store.activeTab.location == .recycleBin ? .recycleBinEmpty : .folder,
                size: 46
            )
            Text(emptyFolderTitle)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary)
            if case .search = store.activeTab.location {
                Text("Try another search term or broaden your filters.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyFolderTitle: String {
        switch store.activeTab.location {
        case .recycleBin:
            return "Trash is empty."
        case .search:
            return "No items match your search."
        default:
            return "This folder is empty."
        }
    }

    // MARK: - Marquee Selection

    private var marqueeRect: CGRect? {
        guard let start = marqueeStart, let current = marqueeCurrent else { return nil }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    private var marqueeDragGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("ContentCanvasSpace"))
            .onChanged { value in
                isCanvasFocused = true
                if marqueeStart == nil {
                    marqueeStart = value.startLocation
                }
                marqueeCurrent = value.location
                if let rect = marqueeRect {
                    let hitURLs = Set(
                        itemFrames.compactMap { url, frame in
                            frame.intersects(rect) ? url : nil
                        }
                    )
                    store.setSelection(hitURLs)
                }
            }
            .onEnded { _ in
                marqueeStart = nil
                marqueeCurrent = nil
            }
    }

    // MARK: - Keyboard Navigation

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard store.inlineRenamingURL == nil, !store.isEditingPath else {
            return .ignored
        }

        let items = store.currentItems
        let isShift = press.modifiers.contains(.shift)
        let isCommand = press.modifiers.contains(.command)

        // Cmd+A: Select All
        if isCommand && press.characters.lowercased() == "a" {
            store.selectAll()
            return .handled
        }

        // Cmd+Up: Navigate Up
        if isCommand && press.key == .upArrow {
            store.goUp()
            return .handled
        }

        // Cmd+Delete or Delete/Backspace on selection
        if isCommand && (press.key == .delete || press.key == .deleteForward) {
            store.deleteSelectedItems()
            return .handled
        }

        // Backspace without Command: Navigate Up
        if !isCommand && press.key == .delete {
            store.goUp()
            return .handled
        }

        // Forward Delete without Command: Move to Trash
        if !isCommand && press.key == .deleteForward {
            store.deleteSelectedItems()
            return .handled
        }

        // Enter / Return: Open primary selection
        if press.key == .return {
            if let primary = store.primarySelectedItem {
                store.openItem(primary)
                return .handled
            }
            return .ignored
        }

        // Space: Toggle Quick Look
        if press.key == .space {
            store.toggleQuickLook()
            return .handled
        }

        // Escape: Deselect all
        if press.key == .escape {
            store.deselectAll()
            return .handled
        }

        // F2: Begin inline rename
        if press.characters == String(UnicodeScalar(NSF2FunctionKey)!) {
            if let primary = store.primarySelectedItem {
                store.beginInlineRename(for: primary.url)
                return .handled
            }
            return .ignored
        }

        // Arrow navigation
        let step: Int? = {
            switch press.key {
            case .downArrow:
                return store.activeTab.viewMode == .details ? 1 : max(1, gridColumnCount)
            case .upArrow:
                return store.activeTab.viewMode == .details ? -1 : -max(1, gridColumnCount)
            case .rightArrow:
                return 1
            case .leftArrow:
                return -1
            default:
                return nil
            }
        }()

        if let step, !items.isEmpty {
            moveSelection(by: step, extending: isShift, in: items)
            return .handled
        }

        // Type-ahead character jump
        if !isCommand && !press.modifiers.contains(.control) && !press.modifiers.contains(.option),
           let scalar = press.characters.unicodeScalars.first,
           CharacterSet.alphanumerics.contains(scalar) || press.characters == "." || press.characters == "_" {
            handleTypeAhead(character: press.characters, in: items)
            return .handled
        }

        return .ignored
    }

    private func moveSelection(by delta: Int, extending: Bool, in items: [FileItem]) {
        let currentIndex: Int
        if let anchor = store.activeTab.anchorURL,
           let idx = items.firstIndex(where: { $0.url == anchor }) {
            currentIndex = idx
        } else if let firstSelected = store.selectedItems.first,
                  let idx = items.firstIndex(where: { $0.url == firstSelected.url }) {
            currentIndex = idx
        } else {
            let initialIndex = delta >= 0 ? 0 : items.count - 1
            store.selectItem(url: items[initialIndex].url)
            return
        }

        let targetIndex = min(items.count - 1, max(0, currentIndex + delta))
        let targetItem = items[targetIndex]
        if extending {
            store.selectRange(to: targetItem.url)
            var tab = store.activeTab
            tab.anchorURL = targetItem.url
            store.activeTab = tab
        } else {
            store.selectItem(url: targetItem.url)
        }
    }

    private func handleTypeAhead(character: String, in items: [FileItem]) {
        typeAheadBuffer.append(character.lowercased())
        typeAheadTask?.cancel()
        typeAheadTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            if !Task.isCancelled {
                typeAheadBuffer = ""
            }
        }

        if let match = items.first(where: { $0.name.lowercased().hasPrefix(typeAheadBuffer) }) {
            store.selectItem(url: match.url)
        } else if typeAheadBuffer.count > 1 {
            let single = character.lowercased()
            typeAheadBuffer = single
            if let match = items.first(where: { $0.name.lowercased().hasPrefix(single) }) {
                store.selectItem(url: match.url)
            }
        }
    }
}

// MARK: - Network Discovery View

private struct NetworkDiscoveryView: View {
    let store: ExplorerStore

    @Environment(\.fluentTheme) private var theme
    @State private var hoveredVolumeURL: URL?

    private var networkDrives: [VolumeInfo] {
        store.volumes.filter { $0.volumeKind == .networkDrive }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    FluentIconView(kind: .networkDrive, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Network")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(theme.palette.textPrimary)
                        Text("Connected SMB, AFP, and cloud network shares on this Mac")
                            .font(.system(size: 12.5))
                            .foregroundStyle(theme.palette.textSecondary)
                    }
                    Spacer()
                    Button {
                        if let netURL = URL(string: "file:///Network") {
                            store.navigate(to: .folder(netURL))
                        }
                    } label: {
                        Label("Browse /Network", systemImage: "bonjour")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: theme.cornerRadiusMedium, style: .continuous)
                        .fill(theme.palette.cardSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: theme.cornerRadiusMedium, style: .continuous)
                        .stroke(theme.palette.borderSubtle, lineWidth: 1)
                )

                Win11SectionHeader(
                    title: "Network locations",
                    count: networkDrives.count,
                    isCollapsed: false,
                    onToggle: {}
                )

                if networkDrives.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "network")
                            .font(.system(size: 36))
                            .foregroundStyle(theme.palette.textSecondary)
                        Text("No mounted network shares found")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(theme.palette.textPrimary)
                        Text("Mount a network drive via Finder (⌘K) or browse /Network to see shared computers here.")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.palette.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(networkDrives) { drive in
                            let isHovered = hoveredVolumeURL == drive.url
                            HStack(spacing: 12) {
                                FluentIconView(kind: .networkDrive, size: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(drive.name)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(theme.palette.textPrimary)
                                    Text(drive.fileSystemFormat)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(theme.palette.textSecondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: theme.cornerRadiusMedium, style: .continuous)
                                    .fill(isHovered ? theme.palette.hoverFill : theme.palette.cardSurface)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: theme.cornerRadiusMedium, style: .continuous)
                                    .stroke(theme.palette.borderSubtle, lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                            .onHover { hoveredVolumeURL = $0 ? drive.url : nil }
                            .onTapGesture {
                                let clickCount = NSApp.currentEvent?.clickCount ?? 1
                                if clickCount >= 2 || store.settings.singleClickToOpen {
                                    store.navigate(to: .folder(drive.url))
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(theme.palette.contentCanvas)
        .overlay {
            RightClickHandlerOverlay {
                store.showContextMenu(for: .background(.network))
            }
        }
    }
}
