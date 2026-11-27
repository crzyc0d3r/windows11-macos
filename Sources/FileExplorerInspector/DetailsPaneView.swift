import AppKit
import FileExplorerCore
import FileExplorerDesign
import SwiftUI

public struct RightInspectorContainerView: View {
    public let store: ExplorerStore

    @Environment(\.fluentTheme) private var theme
    @State private var dragStartWidth: CGFloat?
    @State private var isHoveringSplitter: Bool = false

    public init(store: ExplorerStore) {
        self.store = store
    }

    public var body: some View {
        let clampedWidth = min(480, max(260, store.settings.rightPaneWidth))
        HStack(spacing: 0) {
            splitterHandle(currentWidth: clampedWidth)

            VStack(spacing: 0) {
                inspectorHeader
                Divider()
                    .overlay(theme.palette.borderSubtle)

                switch store.settings.rightPaneMode {
                case .details:
                    DetailsPaneView(store: store)
                case .preview:
                    PreviewPaneView(store: store)
                case .none:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.palette.navPane)
        }
        .frame(width: clampedWidth)
        .frame(maxHeight: .infinity)
    }

    private func splitterHandle(currentWidth: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(isHoveringSplitter ? theme.palette.accentBlue.opacity(0.65) : theme.palette.borderSubtle)
                .frame(width: isHoveringSplitter ? 2 : 1)
        }
        .frame(width: 6)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHoveringSplitter = hovering
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if dragStartWidth == nil {
                        dragStartWidth = currentWidth
                    }
                    let base = dragStartWidth ?? currentWidth
                    let proposed = min(480, max(260, base - value.translation.width))
                    store.setRightPaneWidth(proposed)
                }
                .onEnded { _ in
                    dragStartWidth = nil
                }
        )
    }

    private var inspectorHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: store.settings.rightPaneMode == .preview ? "doc.text.magnifyingglass" : "info.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.palette.accentBlue)

            Text(store.settings.rightPaneMode == .preview ? "Preview" : "Details")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary)

            Spacer()

            HStack(spacing: 2) {
                paneModeButton(mode: .details, icon: "sidebar.right", label: "Details")
                paneModeButton(mode: .preview, icon: "rectangle.and.text.magnifyingglass", label: "Preview")
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.palette.hoverFill)
            )

            Button {
                store.setRightPaneMode(store.settings.rightPaneMode)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.palette.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close pane")
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(theme.palette.commandBar)
    }

    private func paneModeButton(mode: RightPaneMode, icon: String, label: String) -> some View {
        let isActive = store.settings.rightPaneMode == mode
        return Button {
            if !isActive {
                store.setRightPaneMode(mode)
            }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isActive ? theme.palette.accentBlue : theme.palette.textSecondary)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isActive ? theme.palette.selectionFill : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(label)
    }
}

public struct DetailsPaneView: View {
    public let store: ExplorerStore

    @Environment(\.fluentTheme) private var theme
    @State private var enrichedInfo: EnrichedInspectorInfo?
    @State private var isLoadingMetadata: Bool = false

    public init(store: ExplorerStore) {
        self.store = store
    }

    public var body: some View {
        let selected = store.selectedItems
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if selected.count == 1, let item = selected.first {
                    singleItemContent(item: item)
                } else if selected.count > 1 {
                    multiItemContent(items: selected)
                } else {
                    noSelectionContent()
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: selected.count == 1 ? selected.first?.thumbnailKey : nil) {
            guard selected.count == 1, let item = selected.first else {
                enrichedInfo = nil
                return
            }
            isLoadingMetadata = true
            let loaded = await InspectorMetadataLoader.load(for: item, store: store)
            if !Task.isCancelled {
                enrichedInfo = loaded
                isLoadingMetadata = false
            }
        }
    }

    @ViewBuilder
    private func singleItemContent(item: FileItem) -> some View {
        let isCut = store.clipboardPayload?.operation == .cut
            && (store.clipboardPayload?.urls.contains(item.url) ?? false)

        VStack(spacing: 10) {
            FileThumbnailView(item: item, size: 108, isCut: isCut)
                .padding(.top, 6)

            Text(item.displayName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .textSelection(.enabled)

            HStack(spacing: 6) {
                Text(item.typeDescription)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.palette.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(theme.palette.hoverFill)
                    )
                    .overlay(
                        Capsule()
                            .stroke(theme.palette.borderSubtle, lineWidth: 1)
                    )

                if !item.fileExtension.isEmpty && !item.isDirectory {
                    Text(item.fileExtension.uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.palette.accentBlue)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(theme.palette.selectionFill)
                        )
                }
            }

            quickActionBar(for: item)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)

        Divider()
            .overlay(theme.palette.borderSubtle)

        propertiesCard(for: item)
    }

    private func quickActionBar(for item: FileItem) -> some View {
        let isPinned = store.isPinned(url: item.url)
        let isFavorited = store.isFavorite(url: item.url)
        return HStack(spacing: 8) {
            quickPillButton(title: "Open", systemImage: "arrow.up.right.square") {
                store.openItem(item)
            }

            quickPillButton(title: "Share", systemImage: "square.and.arrow.up") {
                if !store.snapshotMode {
                    InspectorFormatters.shareItems([item.url])
                } else {
                    InspectorFormatters.copyPathsToPasteboard([item.url])
                }
            }

            if item.isDirectory && !item.isPackage {
                quickPillButton(
                    title: isPinned ? "Pinned" : "Pin",
                    systemImage: isPinned ? "pin.fill" : "pin",
                    isHighlighted: isPinned
                ) {
                    if isPinned {
                        store.unpinFolder(url: item.url)
                    } else {
                        store.pinFolder(url: item.url, title: item.name)
                    }
                }
            } else {
                quickPillButton(
                    title: isFavorited ? "Favorited" : "Favorite",
                    systemImage: isFavorited ? "star.fill" : "star",
                    isHighlighted: isFavorited
                ) {
                    store.toggleFavorite(url: item.url)
                }
            }
        }
    }

    private func quickPillButton(
        title: String,
        systemImage: String,
        isHighlighted: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(isHighlighted ? theme.palette.accentBlue : theme.palette.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(isHighlighted ? theme.palette.selectionFill : theme.palette.cardSurface)
            )
            .overlay(
                Capsule()
                    .stroke(isHighlighted ? theme.palette.accentBlue.opacity(0.45) : theme.palette.borderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func propertiesCard(for item: FileItem) -> some View {
        let meta = enrichedInfo?.metadata
        InspectorSectionCard(title: "Properties") {
            VStack(alignment: .leading, spacing: 7) {
                if item.isDirectory && !item.isPackage {
                    if let folderBytes = meta?.folderSizeBytes {
                        let files = meta?.folderFileCount ?? item.childCount ?? 0
                        let folders = meta?.folderSubfolderCount ?? 0
                        InspectorKeyValueRow(
                            label: "Size",
                            value: "\(InspectorFormatters.formatBytes(folderBytes)) (\(files) files, \(folders) folders)"
                        )
                    } else if isLoadingMetadata {
                        InspectorKeyValueRow(label: "Size", value: "Calculating...")
                    } else if let count = item.childCount {
                        InspectorKeyValueRow(label: "Contents", value: "\(count) items")
                    }
                } else {
                    InspectorKeyValueRow(
                        label: "Size",
                        value: InspectorFormatters.formatDetailedBytes(item.size)
                    )
                }

                InspectorKeyValueRow(
                    label: "Date modified",
                    value: InspectorFormatters.formatDate(item.dateModified)
                )
                InspectorKeyValueRow(
                    label: "Date created",
                    value: InspectorFormatters.formatDate(item.dateCreated)
                )
                InspectorKeyValueRow(
                    label: "Path",
                    value: item.url.path
                )

                if let perms = item.posixPermissions {
                    InspectorKeyValueRow(
                        label: "Permissions",
                        value: "\(perms.symbolicString) (0\(perms.octalString))",
                        monospaced: true
                    )
                }

                if let dimensions = meta?.dimensions {
                    InspectorKeyValueRow(label: "Dimensions", value: dimensions)
                }

                if let exifPairs = meta?.exifSummary, !exifPairs.isEmpty {
                    ForEach(Array(exifPairs.enumerated()), id: \.offset) { _, pair in
                        InspectorKeyValueRow(label: pair.0, value: pair.1)
                    }
                }

                if let duration = meta?.mediaDuration {
                    InspectorKeyValueRow(label: "Duration", value: duration)
                }
                if let codec = meta?.mediaCodec {
                    InspectorKeyValueRow(label: "Codec", value: codec)
                }

                if let pages = meta?.pdfPageCount {
                    InspectorKeyValueRow(label: "Pages", value: "\(pages)")
                }
                if let author = enrichedInfo?.pdfAuthor, !author.isEmpty {
                    InspectorKeyValueRow(label: "Author", value: author)
                }

                if let lines = meta?.lineCount {
                    InspectorKeyValueRow(label: "Lines", value: "\(lines)")
                }

                if let appName = meta?.defaultAppName, !appName.isEmpty {
                    InspectorKeyValueRow(label: "Opens with", value: appName)
                }
            }
        }
    }

    private func multiItemContent(items: [FileItem]) -> some View {
        let totalBytes = items.filter { !$0.isDirectory || $0.isPackage }.reduce(Int64(0)) { $0 + $1.size }
        let folderCount = items.filter { $0.isDirectory && !$0.isPackage }.count
        let fileCount = items.count - folderCount

        return VStack(spacing: 14) {
            ZStack {
                ForEach(Array(items.prefix(3).enumerated().reversed()), id: \.element.id) { index, item in
                    let offset = CGFloat(index - 1) * 14
                    let rotation = Double(index - 1) * 6
                    FluentIconView(kind: .forItem(item), size: 68)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(theme.palette.cardSurface)
                                .shadow(color: Color.black.opacity(0.12), radius: 6, y: 2)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(theme.palette.borderSubtle, lineWidth: 1)
                        )
                        .offset(x: offset, y: CGFloat(index) * -3)
                        .rotationEffect(.degrees(rotation))
                }
            }
            .frame(height: 112)
            .padding(.top, 8)

            VStack(spacing: 4) {
                Text("\(items.count) items selected")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)

                Text("Total size: \(InspectorFormatters.formatBytes(totalBytes))")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.palette.textSecondary)
            }

            HStack(spacing: 8) {
                quickPillButton(title: "Copy", systemImage: "doc.on.doc") {
                    store.copySelectedItems()
                }
                quickPillButton(title: "ZIP", systemImage: "doc.zipper") {
                    store.zipSelectedItems()
                }
                quickPillButton(title: "Delete", systemImage: "trash") {
                    store.deleteSelectedItems()
                }
            }

            Divider()
                .overlay(theme.palette.borderSubtle)

            InspectorSectionCard(title: "Selection Summary") {
                VStack(alignment: .leading, spacing: 7) {
                    InspectorKeyValueRow(label: "Selected", value: "\(items.count) items")
                    if fileCount > 0 {
                        InspectorKeyValueRow(label: "Files", value: "\(fileCount)")
                    }
                    if folderCount > 0 {
                        InspectorKeyValueRow(label: "Folders", value: "\(folderCount)")
                    }
                    InspectorKeyValueRow(
                        label: "Total size",
                        value: InspectorFormatters.formatDetailedBytes(totalBytes)
                    )
                    if let latest = items.map(\.dateModified).max() {
                        InspectorKeyValueRow(
                            label: "Latest change",
                            value: InspectorFormatters.formatDate(latest)
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func noSelectionContent() -> some View {
        let location = store.activeTab.location
        let folderCount = store.currentItems.filter { $0.isDirectory && !$0.isPackage }.count
        let fileCount = store.currentItems.count - folderCount
        let totalVisibleBytes = store.currentItems.filter { !$0.isDirectory || $0.isPackage }.reduce(Int64(0)) { $0 + $1.size }
        let matchedVolume = matchingVolume(for: location)

        return VStack(spacing: 14) {
            FluentIconView(
                kind: FluentIconKind(locationIcon: location.iconKind, isTrashEmpty: store.isTrashEmpty),
                size: 96
            )
            .padding(.top, 10)

            VStack(spacing: 4) {
                Text(location.displayTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                    .multilineTextAlignment(.center)

                Text("\(store.currentItems.count) \(store.currentItems.count == 1 ? "item" : "items")")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.palette.textSecondary)
            }

            Divider()
                .overlay(theme.palette.borderSubtle)

            InspectorSectionCard(title: "Location Summary") {
                VStack(alignment: .leading, spacing: 7) {
                    InspectorKeyValueRow(label: "Location", value: location.pathString)
                    InspectorKeyValueRow(label: "Items", value: "\(fileCount) files, \(folderCount) folders")
                    if totalVisibleBytes > 0 {
                        InspectorKeyValueRow(
                            label: "Visible size",
                            value: InspectorFormatters.formatBytes(totalVisibleBytes)
                        )
                    }
                }
            }

            if let volume = matchedVolume {
                InspectorSectionCard(title: "Storage — \(volume.name)") {
                    VStack(alignment: .leading, spacing: 8) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(theme.palette.hoverFill)
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(volume.usedFraction >= 0.9 ? theme.palette.dangerRed : theme.palette.accentBlue)
                                    .frame(width: max(4, geo.size.width * volume.usedFraction))
                            }
                        }
                        .frame(height: 6)

                        Text("\(InspectorFormatters.formatBytes(volume.freeBytes)) free of \(InspectorFormatters.formatBytes(volume.totalBytes))")
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.palette.textSecondary)

                        InspectorKeyValueRow(label: "Format", value: volume.fileSystemFormat)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func matchingVolume(for location: ExplorerLocation) -> VolumeInfo? {
        guard let url = location.urlIfFolder else {
            return store.volumes.first
        }
        let path = url.standardizedFileURL.path
        let sorted = store.volumes.sorted { $0.url.path.count > $1.url.path.count }
        return sorted.first(where: { path.hasPrefix($0.url.path) }) ?? store.volumes.first
    }
}
