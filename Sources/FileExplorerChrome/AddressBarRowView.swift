import AppKit
import FileExplorerCore
import FileExplorerDesign
import SwiftUI
import UniformTypeIdentifiers

/// Windows 11 24H2 Address Bar row (~44px tall), positioned directly below `TabBarView`
/// and above `CommandBarView`, sharing the active tab's surface color.
struct AddressBarRowView: View {
    let store: ExplorerStore

    @Environment(\.fluentTheme) private var theme
    @State private var editedPath: String = ""
    @State private var openPopoverSegmentID: String?
    @State private var hoveredSegmentID: String?
    @State private var dropTargetedSegmentID: String?
    @State private var isClearSearchHovered = false
    @FocusState private var isPathFieldFocused: Bool
    @FocusState private var isSearchFieldFocused: Bool

    private let rowHeight: CGFloat = 44

    var body: some View {
        HStack(spacing: 8) {
            navigationCluster
            breadcrumbAddressPill
                .frame(maxWidth: .infinity)
            searchBox
        }
        .padding(.horizontal, 10)
        .frame(height: rowHeight)
        .background(theme.activeTabAndAddressSurface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.palette.borderSubtle)
                .frame(height: 1)
        }
        // Hidden Cmd+L shortcut to focus editable address bar.
        .background(
            Button("") {
                beginPathEditing()
            }
            .keyboardShortcut("l", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
        )
        .onChange(of: store.isEditingPath) { _, isEditing in
            if isEditing {
                editedPath = store.activeTab.location.pathString
                isPathFieldFocused = true
            } else {
                isPathFieldFocused = false
            }
        }
    }

    // MARK: - Left Navigation Cluster

    private var navigationCluster: some View {
        HStack(spacing: 2) {
            ChromeIconButton(
                systemName: "arrow.left",
                isEnabled: store.activeTab.canGoBack,
                tooltip: "Back (⌘[)"
            ) {
                store.goBack()
            }

            ChromeIconButton(
                systemName: "arrow.right",
                isEnabled: store.activeTab.canGoForward,
                tooltip: "Forward (⌘])"
            ) {
                store.goForward()
            }

            recentLocationsMenu

            ChromeIconButton(
                systemName: "arrow.up",
                isEnabled: store.activeTab.canGoUp,
                tooltip: upTooltip
            ) {
                store.goUp()
            }

            ChromeIconButton(
                systemName: "arrow.clockwise",
                isEnabled: true,
                tooltip: "Refresh (⌘R)"
            ) {
                store.refresh()
            }
        }
    }

    private var upTooltip: String {
        switch store.activeTab.location {
        case .folder(let url):
            let parent = url.deletingLastPathComponent()
            let title = parent.path == "/" ? "Macintosh HD" : parent.lastPathComponent
            return "Up to \(title) (⌘↑)"
        default:
            return "Up (⌘↑)"
        }
    }

    private var recentLocationsMenu: some View {
        Menu {
            let backLocations = Array(store.activeTab.backStack.reversed().prefix(6))
            let forwardLocations = Array(store.activeTab.forwardStack.reversed().prefix(4))

            if !forwardLocations.isEmpty {
                Section("Forward") {
                    ForEach(Array(forwardLocations.enumerated()), id: \.offset) { _, loc in
                        Button {
                            store.navigate(to: loc)
                        } label: {
                            Label(loc.displayTitle, systemImage: "arrow.right")
                        }
                    }
                }
            }

            Section("Current") {
                Button {
                    store.refresh()
                } label: {
                    Label(store.activeTab.location.displayTitle, systemImage: "checkmark")
                }
            }

            if !backLocations.isEmpty {
                Section("Recent locations") {
                    ForEach(Array(backLocations.enumerated()), id: \.offset) { _, loc in
                        Button {
                            store.navigate(to: loc)
                        } label: {
                            Label(loc.displayTitle, systemImage: "clock")
                        }
                    }
                }
            }

            if !store.pinnedFolders.isEmpty {
                Section("Quick access") {
                    ForEach(store.pinnedFolders) { folder in
                        Button {
                            store.navigate(to: .folder(folder.url))
                        } label: {
                            Label(folder.title, systemImage: "folder")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.palette.textSecondary)
                .frame(width: 18, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Recent locations")
    }

    // MARK: - Center Breadcrumb Address Pill

    private var breadcrumbAddressPill: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.inputFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(
                            store.isEditingPath ? theme.palette.accentBlue : theme.palette.borderSubtle,
                            lineWidth: store.isEditingPath ? 1.5 : 1
                        )
                )

            if store.isEditingPath {
                editablePathField
            } else {
                breadcrumbContent
            }
        }
        .frame(height: 32)
    }

    private var breadcrumbContent: some View {
        GeometryReader { geometry in
            let segments = breadcrumbSegments
            let layout = computeBreadcrumbLayout(segments: segments, availableWidth: geometry.size.width)

            ZStack(alignment: .leading) {
                // Full-pill empty-area click target behind the breadcrumb controls.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        beginPathEditing()
                    }

                HStack(spacing: 1) {
                    FluentIconView(
                        kind: FluentIconKind(
                            locationIcon: store.activeTab.location.iconKind,
                            isTrashEmpty: store.isTrashEmpty
                        ),
                        size: 16
                    )
                    .padding(.leading, 8)
                    .padding(.trailing, 4)

                    if !layout.overflowSegments.isEmpty {
                        overflowAncestorsButton(segments: layout.overflowSegments)
                    }

                    ForEach(Array(layout.visibleSegments.enumerated()), id: \.element.id) { index, segment in
                        breadcrumbSegmentButton(segment)

                        if index < layout.visibleSegments.count - 1 || segment.folderURL != nil {
                            chevronPopoverButton(for: segment)
                        }
                    }

                    Spacer(minLength: 16)
                }
                .padding(.trailing, 6)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
        }
        .frame(height: 32)
    }

    private func overflowAncestorsButton(segments: [BreadcrumbSegment]) -> some View {
        Menu {
            ForEach(segments) { segment in
                Button {
                    store.navigate(to: segment.location)
                } label: {
                    Label(segment.title, systemImage: segment.folderURL == nil ? "desktopcomputer" : "folder")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.palette.textSecondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(theme.palette.hoverFill.opacity(0.6))
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.trailing, 2)
        .help("Earlier path folders")
    }

    private func computeBreadcrumbLayout(
        segments: [BreadcrumbSegment],
        availableWidth: CGFloat
    ) -> (overflowSegments: [BreadcrumbSegment], visibleSegments: [BreadcrumbSegment]) {
        guard !segments.isEmpty else { return ([], []) }

        let iconAndPadding: CGFloat = 34
        let trailingBuffer: CGFloat = 24
        let overflowButtonWidth: CGFloat = 26
        let chevronWidth: CGFloat = 18

        let font = NSFont.systemFont(ofSize: 12.5, weight: .regular)
        let segmentWidths: [CGFloat] = segments.enumerated().map { index, segment in
            let textWidth = ceil((segment.title as NSString).size(withAttributes: [.font: font]).width)
            let buttonWidth = textWidth + 14
            let hasChevron = index < segments.count - 1 || segment.folderURL != nil
            return buttonWidth + (hasChevron ? chevronWidth : 0) + 2
        }

        let usableWidth = max(120, availableWidth - iconAndPadding - trailingBuffer)
        let totalWidth = segmentWidths.reduce(0, +)
        if totalWidth <= usableWidth {
            return ([], segments)
        }

        // Collapse leading ancestors into `«` so the current folder and immediate parents always stay visible.
        var visibleCount = 1
        var usedWidth = segmentWidths[segments.count - 1]
        let budgetWithOverflow = max(80, usableWidth - overflowButtonWidth)

        if segments.count > 1 {
            for index in stride(from: segments.count - 2, through: 0, by: -1) {
                let candidateWidth = segmentWidths[index]
                let remainingBudget = (index == 0) ? usableWidth : budgetWithOverflow
                if usedWidth + candidateWidth <= remainingBudget {
                    usedWidth += candidateWidth
                    visibleCount += 1
                } else {
                    break
                }
            }
        }

        let splitIndex = max(0, segments.count - visibleCount)
        return (
            Array(segments[..<splitIndex]),
            Array(segments[splitIndex...])
        )
    }

    private func breadcrumbSegmentButton(_ segment: BreadcrumbSegment) -> some View {
        let isHovered = hoveredSegmentID == segment.id
        let isDropTarget = dropTargetedSegmentID == segment.id

        return Button {
            store.navigate(to: segment.location)
        } label: {
            Text(segment.title)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isDropTarget ? theme.palette.selectionFill : (isHovered ? theme.palette.hoverFill : .clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(isDropTarget ? theme.palette.accentBlue : .clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredSegmentID = hovering ? segment.id : (hoveredSegmentID == segment.id ? nil : hoveredSegmentID)
        }
        .onDrop(
            of: [.fileURL],
            isTargeted: Binding(
                get: { dropTargetedSegmentID == segment.id },
                set: { targeted in
                    if targeted, segment.folderURL != nil {
                        dropTargetedSegmentID = segment.id
                    } else if !targeted && dropTargetedSegmentID == segment.id {
                        dropTargetedSegmentID = nil
                    }
                }
            )
        ) { providers in
            guard let targetURL = segment.folderURL else { return false }
            return ChromeDropHelper.handleFileURLDrop(
                providers: providers,
                destinationFolder: targetURL,
                store: store
            )
        }
    }

    private func chevronPopoverButton(for segment: BreadcrumbSegment) -> some View {
        let isOpen = openPopoverSegmentID == segment.id
        return Button {
            openPopoverSegmentID = isOpen ? nil : segment.id
        } label: {
            Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.palette.textSecondary)
                .frame(width: 16, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isOpen ? theme.palette.hoverFill : .clear)
                )
        }
        .buttonStyle(.plain)
        .popover(
            isPresented: Binding(
                get: { openPopoverSegmentID == segment.id },
                set: { presented in
                    if !presented && openPopoverSegmentID == segment.id {
                        openPopoverSegmentID = nil
                    }
                }
            ),
            arrowEdge: .bottom
        ) {
            SiblingFoldersPopover(
                segment: segment,
                store: store,
                onSelect: { destination in
                    openPopoverSegmentID = nil
                    store.navigate(to: destination)
                }
            )
        }
    }

    private var editablePathField: some View {
        let suggestions = ChromeFilesystemHelper.pathSuggestions(for: editedPath, store: store)
        return HStack(spacing: 6) {
            FluentIconView(
                kind: FluentIconKind(
                    locationIcon: store.activeTab.location.iconKind,
                    isTrashEmpty: store.isTrashEmpty
                ),
                size: 16
            )
            .padding(.leading, 8)

            TextField("Enter path or location", text: $editedPath)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.palette.textPrimary)
                .focused($isPathFieldFocused)
                .onSubmit {
                    store.commitPathEdit(editedPath)
                }
                .onExitCommand {
                    store.cancelPathEdit()
                }

            Button {
                store.cancelPathEdit()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.palette.textSecondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
        }
        .popover(
            isPresented: Binding(
                get: { store.isEditingPath && !suggestions.isEmpty },
                set: { _ in }
            ),
            arrowEdge: .bottom
        ) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        editedPath = suggestion
                        store.commitPathEdit(suggestion)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: suggestion.hasPrefix("/") ? "folder.fill" : "location.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.palette.accentBlue)
                            Text(suggestion)
                                .font(.system(size: 12))
                                .foregroundStyle(theme.palette.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .frame(minWidth: 320, maxWidth: 460)
            .background(theme.palette.elevatedFlyout)
        }
    }

    private func beginPathEditing() {
        editedPath = store.activeTab.location.pathString
        store.beginEditingPath()
        isPathFieldFocused = true
    }

    // MARK: - Breadcrumb Segments Builder

    private var breadcrumbSegments: [BreadcrumbSegment] {
        switch store.activeTab.location {
        case .home:
            return [BreadcrumbSegment(id: "home", title: "Home", location: .home, folderURL: nil)]
        case .gallery:
            return [BreadcrumbSegment(id: "gallery", title: "Gallery", location: .gallery, folderURL: nil)]
        case .thisPC:
            return [BreadcrumbSegment(id: "thispc", title: "This Mac", location: .thisPC, folderURL: nil)]
        case .recycleBin:
            return [BreadcrumbSegment(id: "trash", title: "Trash", location: .recycleBin, folderURL: nil)]
        case .network:
            return [BreadcrumbSegment(id: "network", title: "Network", location: .network, folderURL: nil)]
        case .folder(let url):
            return folderSegments(for: url)
        case .search(let query, let scope, _):
            var segments = folderSegments(for: scope)
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = trimmed.isEmpty ? "Search results" : "Search: \(trimmed)"
            segments.append(BreadcrumbSegment(id: "search-leaf", title: label, location: store.activeTab.location, folderURL: nil))
            return segments
        }
    }

    private func folderSegments(for url: URL) -> [BreadcrumbSegment] {
        let std = url.standardizedFileURL
        var segments: [BreadcrumbSegment] = [
            BreadcrumbSegment(id: "thispc-root", title: "This Mac", location: .thisPC, folderURL: nil),
            BreadcrumbSegment(
                id: "folder-/",
                title: "Macintosh HD",
                location: .folder(URL(fileURLWithPath: "/")),
                folderURL: URL(fileURLWithPath: "/")
            )
        ]

        let components = std.pathComponents.filter { $0 != "/" }
        var runningURL = URL(fileURLWithPath: "/")
        for component in components {
            runningURL = runningURL.appendingPathComponent(component, isDirectory: true)
            segments.append(
                BreadcrumbSegment(
                    id: "folder-\(runningURL.path)",
                    title: component,
                    location: .folder(runningURL),
                    folderURL: runningURL
                )
            )
        }
        return segments
    }

    // MARK: - Right Search Box

    private var searchBox: some View {
        let searchBinding = Binding<String>(
            get: { store.activeSearchText },
            set: { newValue in
                store.activeSearchText = newValue
            }
        )

        let isInSearchLocation: Bool = {
            if case .search = store.activeTab.location { return true }
            return false
        }()

        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.palette.textSecondary)

            TextField("Search \(store.activeTab.title)", text: searchBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.palette.textPrimary)
                .focused($isSearchFieldFocused)
                .onSubmit {
                    store.performSearch(query: store.activeSearchText)
                }

            if !store.activeSearchText.isEmpty || isInSearchLocation {
                Button {
                    store.clearSearch()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(theme.palette.textSecondary)
                        .frame(width: 18, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(isClearSearchHovered ? theme.palette.hoverFill : .clear)
                        )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isClearSearchHovered = hovering
                }
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 220, idealWidth: 250, maxWidth: 280, minHeight: 32, maxHeight: 32)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.inputFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(
                    isSearchFieldFocused ? theme.palette.accentBlue : theme.palette.borderSubtle,
                    lineWidth: isSearchFieldFocused ? 1.5 : 1
                )
        )
    }
}

// MARK: - Breadcrumb Supporting Types

private struct BreadcrumbSegment: Identifiable {
    let id: String
    let title: String
    let location: ExplorerLocation
    let folderURL: URL?
}

private struct SiblingFoldersPopover: View {
    let segment: BreadcrumbSegment
    let store: ExplorerStore
    let onSelect: (ExplorerLocation) -> Void

    @Environment(\.fluentTheme) private var theme
    @State private var hoveredURL: URL?

    var body: some View {
        let items = choices
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if items.isEmpty {
                    Text("No subfolders")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                } else {
                    ForEach(items) { item in
                        Button {
                            onSelect(.folder(item.url))
                        } label: {
                            HStack(spacing: 8) {
                                FluentIconView(
                                    kind: FluentIconKind(locationIcon: item.iconKind),
                                    size: 15
                                )
                                Text(item.name)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(theme.palette.textPrimary)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(hoveredURL == item.url ? theme.palette.hoverFill : .clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            hoveredURL = hovering ? item.url : (hoveredURL == item.url ? nil : hoveredURL)
                        }
                    }
                }
            }
            .padding(6)
        }
        .frame(minWidth: 200, maxWidth: 280, maxHeight: 300)
        .background(theme.palette.elevatedFlyout)
    }

    private var choices: [FolderChoice] {
        if let folderURL = segment.folderURL {
            return ChromeFilesystemHelper.immediateSubfolders(
                of: folderURL,
                showHidden: store.settings.showHiddenFiles,
                store: store
            )
        }
        if segment.location == .thisPC {
            var list: [FolderChoice] = store.volumes.map {
                FolderChoice(
                    url: $0.url,
                    name: $0.name,
                    iconKind: $0.volumeKind == .externalDrive ? .externalDrive : .hardDrive
                )
            }
            for pinned in store.pinnedFolders {
                if !list.contains(where: { $0.url == pinned.url }) {
                    list.append(
                        FolderChoice(
                            url: pinned.url,
                            name: pinned.title,
                            iconKind: ExplorerLocation.folder(pinned.url).iconKind
                        )
                    )
                }
            }
            return list
        }
        return []
    }
}
