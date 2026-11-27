import AppKit
import FileExplorerCore
import FileExplorerDesign
import SwiftUI

public struct IconGridViews: View {
    public let store: ExplorerStore
    public let onFocusCanvas: () -> Void
    public let onColumnCountChange: (Int) -> Void

    @Environment(\.fluentTheme) private var theme
    @State private var collapsedSectionIDs: Set<String> = []
    @State private var hoveredURL: URL?
    @State private var dropTargetedURL: URL?

    public init(
        store: ExplorerStore,
        onFocusCanvas: @escaping () -> Void = {},
        onColumnCountChange: @escaping (Int) -> Void = { _ in }
    ) {
        self.store = store
        self.onFocusCanvas = onFocusCanvas
        self.onColumnCountChange = onColumnCountChange
    }

    private var viewMode: ViewMode {
        store.activeTab.viewMode
    }

    public var body: some View {
        GeometryReader { geo in
            let availableWidth = max(120, geo.size.width - 24)
            let columnCount = computedColumnCount(for: availableWidth)

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if !store.groupedSections.isEmpty {
                            ForEach(store.groupedSections) { section in
                                let isCollapsed = collapsedSectionIDs.contains(section.id)
                                Win11SectionHeader(
                                    title: section.title,
                                    count: section.items.count,
                                    isCollapsed: isCollapsed
                                ) {
                                    if isCollapsed {
                                        collapsedSectionIDs.remove(section.id)
                                    } else {
                                        collapsedSectionIDs.insert(section.id)
                                    }
                                }

                                if !isCollapsed {
                                    itemsContainer(items: section.items, availableWidth: availableWidth)
                                }
                            }
                        } else {
                            itemsContainer(items: store.currentItems, availableWidth: availableWidth)
                        }
                    }
                    .padding(12)
                    .frame(minWidth: geo.size.width, alignment: .topLeading)
                }
                .onChange(of: store.activeTab.anchorURL) { _, newAnchor in
                    if let newAnchor {
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(newAnchor)
                        }
                    }
                }
            }
            .onAppear {
                onColumnCountChange(columnCount)
            }
            .onChange(of: columnCount) { _, newCount in
                onColumnCountChange(newCount)
            }
        }
        .background(theme.palette.contentCanvas)
    }

    @ViewBuilder
    private func itemsContainer(items: [FileItem], availableWidth: CGFloat) -> some View {
        switch viewMode {
        case .content:
            LazyVStack(spacing: 4) {
                ForEach(items) { item in
                    contentRow(item)
                        .id(item.url)
                }
            }

        case .list:
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 8)],
                alignment: .leading,
                spacing: 4
            ) {
                ForEach(items) { item in
                    listCompactCell(item)
                        .id(item.url)
                }
            }

        case .tiles:
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 240, maximum: 280), spacing: 10)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(items) { item in
                    tileCell(item)
                        .id(item.url)
                }
            }

        case .extraLargeIcons, .largeIcons, .mediumIcons, .smallIcons, .details:
            let spec = iconSpec(for: viewMode)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: spec.cellWidth, maximum: spec.cellWidth + 16), spacing: spec.spacing)],
                alignment: .leading,
                spacing: spec.spacing
            ) {
                ForEach(items) { item in
                    iconGridCell(item, spec: spec)
                        .id(item.url)
                }
            }
        }
    }

    private struct IconLayoutSpec {
        let cellWidth: CGFloat
        let iconSize: CGFloat
        let spacing: CGFloat
        let fontSize: CGFloat
        let lineLimit: Int
    }

    private func iconSpec(for mode: ViewMode) -> IconLayoutSpec {
        switch mode {
        case .extraLargeIcons:
            return IconLayoutSpec(cellWidth: 256, iconSize: 128, spacing: 14, fontSize: 13, lineLimit: 2)
        case .largeIcons:
            return IconLayoutSpec(cellWidth: 148, iconSize: 84, spacing: 10, fontSize: 12.5, lineLimit: 2)
        case .mediumIcons:
            return IconLayoutSpec(cellWidth: 110, iconSize: 56, spacing: 8, fontSize: 12, lineLimit: 2)
        case .smallIcons, .list, .details, .tiles, .content:
            return IconLayoutSpec(cellWidth: 84, iconSize: 32, spacing: 6, fontSize: 11.5, lineLimit: 2)
        }
    }

    private func computedColumnCount(for availableWidth: CGFloat) -> Int {
        switch viewMode {
        case .content, .details:
            return 1
        case .list:
            return max(1, Int((availableWidth + 8) / 208))
        case .tiles:
            return max(1, Int((availableWidth + 10) / 250))
        case .extraLargeIcons, .largeIcons, .mediumIcons, .smallIcons:
            let spec = iconSpec(for: viewMode)
            return max(1, Int((availableWidth + spec.spacing) / (spec.cellWidth + spec.spacing)))
        }
    }

    // MARK: - Cell Views

    private func iconGridCell(_ item: FileItem, spec: IconLayoutSpec) -> some View {
        let isSelected = store.activeTab.selectedURLs.contains(item.url)
        let isHovered = hoveredURL == item.url
        let isDropTargeted = dropTargetedURL == item.url
        let isCut = ExplorerViewFormatting.isCut(item, in: store)
        let isRenaming = store.inlineRenamingURL == item.url

        return ZStack(alignment: .topLeading) {
            VStack(spacing: 8) {
                FileThumbnailView(item: item, size: spec.iconSize, isCut: isCut)
                    .frame(height: spec.iconSize)

                if isRenaming {
                    InlineRenameField(
                        item: item,
                        font: .systemFont(ofSize: spec.fontSize),
                        alignment: .center,
                        onCommit: { newName in
                            store.commitInlineRename(for: item.url, newName: newName)
                        },
                        onCancel: {
                            store.cancelInlineRename()
                        }
                    )
                    .frame(height: 22)
                } else {
                    Text(ExplorerViewFormatting.displayName(for: item, showExtensions: store.settings.showFileExtensions))
                        .font(.system(size: spec.fontSize))
                        .foregroundStyle(theme.palette.textPrimary)
                        .multilineTextAlignment(.center)
                        .lineLimit(spec.lineLimit)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(8)
            .frame(width: spec.cellWidth)

            if store.settings.showCheckboxes && (isHovered || isSelected) {
                FluentCheckbox(isChecked: isSelected) {
                    onFocusCanvas()
                    store.selectItem(url: item.url, toggling: true)
                }
                .padding(6)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: theme.cornerRadiusMedium, style: .continuous)
                .fill(cellBackground(isSelected: isSelected, isHovered: isHovered, isDropTargeted: isDropTargeted))
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadiusMedium, style: .continuous)
                .stroke(cellBorder(isSelected: isSelected, isDropTargeted: isDropTargeted), lineWidth: isDropTargeted ? 1.5 : 1)
        )
        .opacity(isCut ? 0.5 : 1.0)
        .modifier(
            GridItemModifier(
                item: item,
                store: store,
                isRenaming: isRenaming,
                onHoverChange: { hoveredURL = $0 ? item.url : nil },
                dropTargetedURL: $dropTargetedURL,
                onFocusCanvas: onFocusCanvas
            )
        )
    }

    private func listCompactCell(_ item: FileItem) -> some View {
        let isSelected = store.activeTab.selectedURLs.contains(item.url)
        let isHovered = hoveredURL == item.url
        let isDropTargeted = dropTargetedURL == item.url
        let isCut = ExplorerViewFormatting.isCut(item, in: store)
        let isRenaming = store.inlineRenamingURL == item.url

        return HStack(spacing: 8) {
            if store.settings.showCheckboxes {
                FluentCheckbox(isChecked: isSelected) {
                    onFocusCanvas()
                    store.selectItem(url: item.url, toggling: true)
                }
            }

            FluentIconView(kind: .forItem(item), size: 18, isCut: isCut, isSymlink: item.isSymlink)

            if isRenaming {
                InlineRenameField(
                    item: item,
                    onCommit: { store.commitInlineRename(for: item.url, newName: $0) },
                    onCancel: { store.cancelInlineRename() }
                )
                .frame(height: 20)
            } else {
                Text(ExplorerViewFormatting.displayName(for: item, showExtensions: store.settings.showFileExtensions))
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: store.settings.compactView ? 24 : 28)
        .background(
            RoundedRectangle(cornerRadius: theme.cornerRadiusSmall, style: .continuous)
                .fill(cellBackground(isSelected: isSelected, isHovered: isHovered, isDropTargeted: isDropTargeted))
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadiusSmall, style: .continuous)
                .stroke(cellBorder(isSelected: isSelected, isDropTargeted: isDropTargeted), lineWidth: isDropTargeted ? 1.5 : 1)
        )
        .opacity(isCut ? 0.5 : 1.0)
        .modifier(
            GridItemModifier(
                item: item,
                store: store,
                isRenaming: isRenaming,
                onHoverChange: { hoveredURL = $0 ? item.url : nil },
                dropTargetedURL: $dropTargetedURL,
                onFocusCanvas: onFocusCanvas
            )
        )
    }

    private func tileCell(_ item: FileItem) -> some View {
        let isSelected = store.activeTab.selectedURLs.contains(item.url)
        let isHovered = hoveredURL == item.url
        let isDropTargeted = dropTargetedURL == item.url
        let isCut = ExplorerViewFormatting.isCut(item, in: store)
        let isRenaming = store.inlineRenamingURL == item.url

        return HStack(spacing: 10) {
            if store.settings.showCheckboxes {
                FluentCheckbox(isChecked: isSelected) {
                    onFocusCanvas()
                    store.selectItem(url: item.url, toggling: true)
                }
            }

            FileThumbnailView(item: item, size: 48, isCut: isCut)

            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    InlineRenameField(
                        item: item,
                        onCommit: { store.commitInlineRename(for: item.url, newName: $0) },
                        onCancel: { store.cancelInlineRename() }
                    )
                    .frame(height: 22)
                } else {
                    Text(ExplorerViewFormatting.displayName(for: item, showExtensions: store.settings.showFileExtensions))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(theme.palette.textPrimary)
                        .lineLimit(1)
                }

                Text(item.typeDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)

                if !item.isDirectory {
                    Text(ExplorerViewFormatting.formattedSize(item.size))
                        .font(.system(size: 11))
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: 240, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: theme.cornerRadiusMedium, style: .continuous)
                .fill(cellBackground(isSelected: isSelected, isHovered: isHovered, isDropTargeted: isDropTargeted))
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadiusMedium, style: .continuous)
                .stroke(cellBorder(isSelected: isSelected, isDropTargeted: isDropTargeted), lineWidth: isDropTargeted ? 1.5 : 1)
        )
        .opacity(isCut ? 0.5 : 1.0)
        .modifier(
            GridItemModifier(
                item: item,
                store: store,
                isRenaming: isRenaming,
                onHoverChange: { hoveredURL = $0 ? item.url : nil },
                dropTargetedURL: $dropTargetedURL,
                onFocusCanvas: onFocusCanvas
            )
        )
    }

    private func contentRow(_ item: FileItem) -> some View {
        let isSelected = store.activeTab.selectedURLs.contains(item.url)
        let isHovered = hoveredURL == item.url
        let isDropTargeted = dropTargetedURL == item.url
        let isCut = ExplorerViewFormatting.isCut(item, in: store)
        let isRenaming = store.inlineRenamingURL == item.url

        return HStack(spacing: 12) {
            if store.settings.showCheckboxes {
                FluentCheckbox(isChecked: isSelected) {
                    onFocusCanvas()
                    store.selectItem(url: item.url, toggling: true)
                }
            }

            FileThumbnailView(item: item, size: 36, isCut: isCut)

            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    InlineRenameField(
                        item: item,
                        onCommit: { store.commitInlineRename(for: item.url, newName: $0) },
                        onCancel: { store.cancelInlineRename() }
                    )
                    .frame(height: 22)
                } else {
                    Text(ExplorerViewFormatting.displayName(for: item, showExtensions: store.settings.showFileExtensions))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.palette.textPrimary)
                        .lineLimit(1)
                }

                Text("Type: \(item.typeDescription)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text("Date modified: \(ExplorerViewFormatting.formattedDate(item.dateModified))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)

                Text(item.isDirectory ? (item.childCount.map { "\($0) items" } ?? "") : "Size: \(ExplorerViewFormatting.formattedSize(item.size))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: 210, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
        .background(
            RoundedRectangle(cornerRadius: theme.cornerRadiusMedium, style: .continuous)
                .fill(cellBackground(isSelected: isSelected, isHovered: isHovered, isDropTargeted: isDropTargeted))
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadiusMedium, style: .continuous)
                .stroke(cellBorder(isSelected: isSelected, isDropTargeted: isDropTargeted), lineWidth: isDropTargeted ? 1.5 : 1)
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.palette.borderSubtle.opacity(0.6))
                .frame(height: 1)
                .padding(.horizontal, 12)
        }
        .opacity(isCut ? 0.5 : 1.0)
        .modifier(
            GridItemModifier(
                item: item,
                store: store,
                isRenaming: isRenaming,
                onHoverChange: { hoveredURL = $0 ? item.url : nil },
                dropTargetedURL: $dropTargetedURL,
                onFocusCanvas: onFocusCanvas
            )
        )
    }

    private func cellBackground(isSelected: Bool, isHovered: Bool, isDropTargeted: Bool) -> Color {
        if isDropTargeted {
            return theme.palette.accentBlue.opacity(0.22)
        }
        if isSelected {
            return theme.palette.selectionFill
        }
        if isHovered {
            return theme.palette.hoverFill
        }
        return .clear
    }

    private func cellBorder(isSelected: Bool, isDropTargeted: Bool) -> Color {
        if isDropTargeted {
            return theme.palette.accentBlue
        }
        if isSelected {
            return theme.palette.accentBlue.opacity(0.45)
        }
        return .clear
    }
}

private struct GridItemModifier: ViewModifier {
    let item: FileItem
    let store: ExplorerStore
    let isRenaming: Bool
    let onHoverChange: (Bool) -> Void
    @Binding var dropTargetedURL: URL?
    let onFocusCanvas: () -> Void

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .reportItemFrame(url: item.url)
            .onHover(perform: onHoverChange)
            .onTapGesture {
                if !isRenaming {
                    ItemInteractionHandler.handleTap(item: item, store: store, onFocusCanvas: onFocusCanvas)
                }
            }
            .onDrag {
                NSItemProvider(object: item.url as NSURL)
            }
            .onDrop(
                of: [.fileURL],
                isTargeted: Binding(
                    get: { dropTargetedURL == item.url },
                    set: { targeted in
                        if item.isDirectory && !item.isPackage {
                            dropTargetedURL = targeted ? item.url : (dropTargetedURL == item.url ? nil : dropTargetedURL)
                        }
                    }
                )
            ) { providers in
                guard item.isDirectory && !item.isPackage else { return false }
                return ExplorerDropHelper.handleDrop(providers: providers, into: item.url, store: store)
            }
            .overlay {
                RightClickHandlerOverlay {
                    ItemInteractionHandler.handleRightClick(item: item, store: store, onFocusCanvas: onFocusCanvas)
                }
            }
    }
}
