import AppKit
import FileExplorerCore
import FileExplorerDesign
import SwiftUI

public struct DetailsListView: View {
    public let store: ExplorerStore
    public let onFocusCanvas: () -> Void

    @Environment(\.fluentTheme) private var theme
    @State private var collapsedSectionIDs: Set<String> = []
    @State private var hoveredURL: URL?
    @State private var dropTargetedURL: URL?
    @State private var dragStartWidths: [String: CGFloat] = [:]
    @State private var hoveredColumnID: String?

    public init(store: ExplorerStore, onFocusCanvas: @escaping () -> Void = {}) {
        self.store = store
        self.onFocusCanvas = onFocusCanvas
    }

    private var visibleColumns: [ExplorerColumn] {
        store.settings.columns.filter(\.isVisible)
    }

    private var rowHeight: CGFloat {
        store.settings.compactView ? 24 : 32
    }

    private var totalColumnsWidth: CGFloat {
        let checkboxWidth: CGFloat = store.settings.showCheckboxes ? 28 : 0
        return visibleColumns.reduce(checkboxWidth + 16) { $0 + $1.width }
    }

    public var body: some View {
        GeometryReader { geo in
            let contentWidth = max(geo.size.width, totalColumnsWidth)

            ScrollView(.horizontal, showsIndicators: true) {
                VStack(spacing: 0) {
                    stickyHeaderBar
                        .frame(width: contentWidth, height: 32)

                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: true) {
                            LazyVStack(alignment: .leading, spacing: 2) {
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
                                            ForEach(section.items) { item in
                                                itemRow(item)
                                                    .id(item.url)
                                            }
                                        }
                                    }
                                } else {
                                    ForEach(store.currentItems) { item in
                                        itemRow(item)
                                            .id(item.url)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                            .frame(width: contentWidth, alignment: .topLeading)
                        }
                        .onChange(of: store.activeTab.anchorURL) { _, newAnchor in
                            if let newAnchor {
                                withAnimation(.easeOut(duration: 0.12)) {
                                    proxy.scrollTo(newAnchor)
                                }
                            }
                        }
                    }
                }
                .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
            }
        }
        .background(theme.palette.contentCanvas)
    }

    private var stickyHeaderBar: some View {
        HStack(spacing: 0) {
            if store.settings.showCheckboxes {
                Color.clear
                    .frame(width: 28, height: 32)
            }

            ForEach(visibleColumns) { column in
                let isSorted = store.activeTab.sortField == column.field
                let isHovered = hoveredColumnID == column.id

                ZStack(alignment: .trailing) {
                    Button {
                        store.setSort(field: column.field)
                    } label: {
                        HStack(spacing: 5) {
                            if column.field == .size {
                                Spacer(minLength: 0)
                            }

                            Text(column.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(isSorted ? theme.palette.textPrimary : theme.palette.textSecondary)
                                .lineLimit(1)

                            if isSorted {
                                Image(systemName: store.activeTab.sortOrder == .ascending ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(theme.palette.textPrimary)
                            }

                            if column.field != .size {
                                Spacer(minLength: 0)
                            }
                        }
                        .padding(.horizontal, 10)
                        .frame(width: column.width, height: 32)
                        .background(isHovered ? theme.palette.hoverFill : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveredColumnID = $0 ? column.id : nil }

                    // Column separator resize handle
                    Rectangle()
                        .fill(theme.palette.borderSubtle)
                        .frame(width: 1, height: 16)
                        .padding(.horizontal, 3)
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            if hovering {
                                NSCursor.resizeLeftRight.set()
                            } else {
                                NSCursor.arrow.set()
                            }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    let base = dragStartWidths[column.id] ?? column.width
                                    if dragStartWidths[column.id] == nil {
                                        dragStartWidths[column.id] = column.width
                                    }
                                    store.resizeColumn(id: column.id, width: max(60, base + value.translation.width))
                                }
                                .onEnded { _ in
                                    dragStartWidths.removeValue(forKey: column.id)
                                }
                        )
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .background(theme.palette.contentCanvas)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.palette.borderSubtle)
                .frame(height: 1)
        }
    }

    private func itemRow(_ item: FileItem) -> some View {
        let isSelected = store.activeTab.selectedURLs.contains(item.url)
        let isHovered = hoveredURL == item.url
        let isDropTargeted = dropTargetedURL == item.url
        let isCut = ExplorerViewFormatting.isCut(item, in: store)
        let isRenaming = store.inlineRenamingURL == item.url

        return HStack(spacing: 0) {
            if store.settings.showCheckboxes {
                FluentCheckbox(isChecked: isSelected) {
                    onFocusCanvas()
                    store.selectItem(url: item.url, toggling: true)
                }
                .frame(width: 28)
            }

            ForEach(visibleColumns) { column in
                columnCell(item: item, column: column, isCut: isCut, isRenaming: isRenaming)
                    .frame(width: column.width, alignment: column.field == .size ? .trailing : .leading)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: rowHeight)
        .background(
            RoundedRectangle(cornerRadius: theme.cornerRadiusSmall, style: .continuous)
                .fill(rowBackground(isSelected: isSelected, isHovered: isHovered, isDropTargeted: isDropTargeted))
                .padding(.horizontal, 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadiusSmall, style: .continuous)
                .stroke(
                    isDropTargeted ? theme.palette.accentBlue : (isSelected ? theme.palette.accentBlue.opacity(0.35) : .clear),
                    lineWidth: isDropTargeted ? 1.5 : 1
                )
                .padding(.horizontal, 4)
        )
        .opacity(isCut ? 0.5 : 1.0)
        .contentShape(Rectangle())
        .reportItemFrame(url: item.url)
        .onHover { hoveredURL = $0 ? item.url : nil }
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

    @ViewBuilder
    private func columnCell(item: FileItem, column: ExplorerColumn, isCut: Bool, isRenaming: Bool) -> some View {
        switch column.field {
        case .name:
            HStack(spacing: 8) {
                FluentIconView(
                    kind: .forItem(item),
                    size: 20,
                    isCut: isCut,
                    isSymlink: item.isSymlink
                )

                if isRenaming {
                    InlineRenameField(
                        item: item,
                        onCommit: { newName in
                            store.commitInlineRename(for: item.url, newName: newName)
                        },
                        onCancel: {
                            store.cancelInlineRename()
                        }
                    )
                    .frame(height: max(20, rowHeight - 6))
                } else {
                    Text(ExplorerViewFormatting.displayName(for: item, showExtensions: store.settings.showFileExtensions))
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, 10)

        case .dateModified:
            Text(ExplorerViewFormatting.formattedDate(item.dateModified))
                .font(.system(size: 12))
                .foregroundStyle(theme.palette.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 10)

        case .dateCreated:
            Text(ExplorerViewFormatting.formattedDate(item.dateCreated))
                .font(.system(size: 12))
                .foregroundStyle(theme.palette.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 10)

        case .type:
            Text(item.typeDescription)
                .font(.system(size: 12))
                .foregroundStyle(theme.palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 10)

        case .size:
            Text(item.isDirectory ? "" : ExplorerViewFormatting.formattedSize(item.size))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(theme.palette.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
        }
    }

    private func rowBackground(isSelected: Bool, isHovered: Bool, isDropTargeted: Bool) -> Color {
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
}
