import AppKit
import FileExplorerCore
import FileExplorerDesign
import SwiftUI
import UniformTypeIdentifiers

/// Windows 11 24H2 left Navigation Pane with draggable width splitter (`180...420px`),
/// `Home`, `Gallery`, `Quick Access`, `Cloud Storage`, expandable `This PC` tree, `Network`, and `Recycle Bin`.
public struct NavigationPaneView: View {
    public let store: ExplorerStore

    @Environment(\.fluentTheme) private var theme
    @State private var isQuickAccessExpanded = true
    @State private var isCloudExpanded = true
    @State private var isThisPCExpanded = true
    @State private var lazyChildrenByURL: [URL: [SidebarTreeNode]] = [:]
    @State private var loadingFolderURLs: Set<URL> = []
    @State private var dragStartWidth: CGFloat?
    @State private var isSplitterHovered = false
    @State private var didPushResizeCursor = false

    public init(store: ExplorerStore) {
        self.store = store
    }

    public var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    topLocationsSection
                    sectionDivider
                    quickAccessSection

                    if !store.cloudLocations.isEmpty {
                        sectionDivider
                        cloudStorageSection
                    }

                    sectionDivider
                    thisPCSection
                    sectionDivider
                    bottomLocationsSection
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
            }
            .frame(width: clampedSidebarWidth)
            .background(theme.palette.navPane)

            splitterHandle
        }
    }

    private var clampedSidebarWidth: CGFloat {
        min(420, max(180, store.settings.sidebarWidth))
    }

    // MARK: - Sections

    private var topLocationsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            SidebarRowView(
                title: "Home",
                iconKind: .home,
                isSelected: store.activeTab.location == .home,
                store: store
            ) {
                store.navigate(to: .home)
            }

            SidebarRowView(
                title: "Gallery",
                iconKind: .gallery,
                isSelected: store.activeTab.location == .gallery,
                store: store
            ) {
                store.navigate(to: .gallery)
            }
        }
    }

    private var quickAccessSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            SidebarSectionHeader(
                title: "Quick access",
                isExpanded: $isQuickAccessExpanded
            )

            if isQuickAccessExpanded {
                ForEach(store.pinnedFolders) { folder in
                    let location = ExplorerLocation.folder(folder.url)
                    SidebarRowView(
                        title: folder.title,
                        iconKind: FluentIconKind(locationIcon: location.iconKind),
                        isSelected: isFolderActive(folder.url),
                        showPinGlyph: true,
                        dropTargetURL: folder.url,
                        store: store
                    ) {
                        store.navigate(to: location)
                    }
                    .contextMenu {
                        Button("Open") {
                            store.navigate(to: location)
                        }
                        Button("Open in new tab") {
                            store.newTab(at: location)
                        }
                        Divider()
                        Button("Unpin from Quick access") {
                            store.unpinFolder(url: folder.url)
                        }
                    }
                }
            }
        }
    }

    private var cloudStorageSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            SidebarSectionHeader(
                title: "Cloud Storage",
                isExpanded: $isCloudExpanded
            )

            if isCloudExpanded {
                ForEach(store.cloudLocations) { cloud in
                    SidebarRowView(
                        title: cloud.name,
                        iconKind: .cloudDrive,
                        isSelected: isFolderActive(cloud.url),
                        dropTargetURL: cloud.url,
                        store: store
                    ) {
                        store.navigate(to: .folder(cloud.url))
                    }
                }
            }
        }
    }

    private var thisPCSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            SidebarRowView(
                title: "This Mac",
                iconKind: .thisPC,
                isSelected: store.activeTab.location == .thisPC,
                disclosureExpanded: isThisPCExpanded,
                onToggleDisclosure: {
                    withAnimation(.easeInOut(duration: 0.14)) {
                        isThisPCExpanded.toggle()
                    }
                },
                store: store
            ) {
                store.navigate(to: .thisPC)
            }

            if isThisPCExpanded {
                ForEach(standardUserFolders, id: \.url) { entry in
                    SidebarRowView(
                        title: entry.title,
                        iconKind: FluentIconKind(locationIcon: entry.iconKind),
                        isSelected: isFolderActive(entry.url),
                        indentLevel: 1,
                        dropTargetURL: entry.url,
                        store: store
                    ) {
                        store.navigate(to: .folder(entry.url))
                    }
                }

                ForEach(store.volumes) { volume in
                    let iconKind: FluentIconKind = {
                        switch volume.volumeKind {
                        case .internalDrive: return .hardDrive
                        case .externalDrive: return .externalDrive
                        case .networkDrive: return .networkDrive
                        case .cloudDrive: return .cloudDrive
                        }
                    }()
                    SidebarRowView(
                        title: volume.name,
                        iconKind: iconKind,
                        isSelected: isFolderActive(volume.url),
                        indentLevel: 1,
                        dropTargetURL: volume.url,
                        store: store
                    ) {
                        store.navigate(to: .folder(volume.url))
                    }
                }

                ForEach(store.sidebarTreeNodes) { node in
                    SidebarTreeBranchView(
                        node: node,
                        indentLevel: 1,
                        store: store,
                        lazyChildrenByURL: $lazyChildrenByURL,
                        loadingFolderURLs: $loadingFolderURLs,
                        isFolderActive: isFolderActive
                    )
                }
            }
        }
    }

    private var bottomLocationsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            SidebarRowView(
                title: "Network",
                iconKind: .networkDrive,
                isSelected: store.activeTab.location == .network,
                store: store
            ) {
                store.navigate(to: .network)
            }

            SidebarRowView(
                title: "Trash",
                iconKind: store.isTrashEmpty ? .recycleBinEmpty : .recycleBinFull,
                isSelected: store.activeTab.location == .recycleBin,
                store: store
            ) {
                store.navigate(to: .recycleBin)
            }
        }
    }

    private var standardUserFolders: [(title: String, url: URL, iconKind: LocationIconKind)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            ("Desktop", home.appendingPathComponent("Desktop", isDirectory: true), .desktop),
            ("Downloads", home.appendingPathComponent("Downloads", isDirectory: true), .downloads),
            ("Documents", home.appendingPathComponent("Documents", isDirectory: true), .documents),
            ("Pictures", home.appendingPathComponent("Pictures", isDirectory: true), .pictures),
            ("Music", home.appendingPathComponent("Music", isDirectory: true), .music),
            ("Videos", home.appendingPathComponent("Movies", isDirectory: true), .videos)
        ]
    }

    private func isFolderActive(_ url: URL) -> Bool {
        if case .folder(let current) = store.activeTab.location {
            return current.standardizedFileURL == url.standardizedFileURL
        }
        return false
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(theme.palette.borderSubtle)
            .frame(height: 1)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
    }

    // MARK: - Draggable Splitter

    private var splitterHandle: some View {
        ZStack {
            Rectangle()
                .fill(isSplitterHovered ? theme.palette.accentBlue.opacity(0.45) : theme.palette.borderSubtle)
                .frame(width: isSplitterHovered ? 2 : 1)
        }
        .frame(width: 5)
        .contentShape(Rectangle())
        .onHover { hovering in
            isSplitterHovered = hovering
            if hovering && !didPushResizeCursor {
                NSCursor.resizeLeftRight.push()
                didPushResizeCursor = true
            } else if !hovering && didPushResizeCursor {
                NSCursor.pop()
                didPushResizeCursor = false
            }
        }
        .onDisappear {
            if didPushResizeCursor {
                NSCursor.pop()
                didPushResizeCursor = false
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if dragStartWidth == nil {
                        dragStartWidth = clampedSidebarWidth
                    }
                    let start = dragStartWidth ?? clampedSidebarWidth
                    store.setSidebarWidth(start + value.translation.width)
                }
                .onEnded { _ in
                    dragStartWidth = nil
                }
        )
    }
}

// MARK: - Recursive Tree Branch

private struct SidebarTreeBranchView: View {
    let node: SidebarTreeNode
    let indentLevel: Int
    let store: ExplorerStore
    @Binding var lazyChildrenByURL: [URL: [SidebarTreeNode]]
    @Binding var loadingFolderURLs: Set<URL>
    let isFolderActive: (URL) -> Bool

    var body: some View {
        let resolvedChildren = effectiveChildren
        let canExpand = node.hasChildren || !(resolvedChildren?.isEmpty ?? true)

        SidebarRowView(
            title: node.name,
            iconKind: FluentIconKind(locationIcon: node.iconKind),
            isSelected: isFolderActive(node.url),
            indentLevel: indentLevel,
            disclosureExpanded: canExpand ? node.isExpanded : nil,
            onToggleDisclosure: canExpand ? { toggleExpansion() } : nil,
            dropTargetURL: node.url,
            store: store
        ) {
            store.navigate(to: .folder(node.url))
        }

        if node.isExpanded, let children = resolvedChildren, !children.isEmpty {
            ForEach(children) { child in
                SidebarTreeBranchView(
                    node: child,
                    indentLevel: indentLevel + 1,
                    store: store,
                    lazyChildrenByURL: $lazyChildrenByURL,
                    loadingFolderURLs: $loadingFolderURLs,
                    isFolderActive: isFolderActive
                )
            }
        }
    }

    private var effectiveChildren: [SidebarTreeNode]? {
        if let modelChildren = node.children, !modelChildren.isEmpty {
            return modelChildren
        }
        return lazyChildrenByURL[node.url]
    }

    private func toggleExpansion() {
        if node.isExpanded {
            store.collapseSidebarNode(url: node.url)
        } else {
            store.expandSidebarNode(url: node.url)
            loadChildrenIfNeeded()
        }
    }

    private func loadChildrenIfNeeded() {
        let hasModelChildren = !(node.children?.isEmpty ?? true)
        guard !hasModelChildren,
              lazyChildrenByURL[node.url] == nil,
              !loadingFolderURLs.contains(node.url),
              !store.snapshotMode else {
            return
        }

        let targetURL = node.url
        let showHidden = store.settings.showHiddenFiles
        loadingFolderURLs.insert(targetURL)

        Task { @MainActor in
            let loaded = await Task.detached(priority: .utility) { () -> [SidebarTreeNode] in
                let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey]
                guard let urls = try? FileManager.default.contentsOfDirectory(
                    at: targetURL,
                    includingPropertiesForKeys: keys,
                    options: [.skipsPackageDescendants]
                ) else {
                    return []
                }

                return urls.compactMap { url -> SidebarTreeNode? in
                    guard let values = try? url.resourceValues(forKeys: Set(keys)),
                          values.isDirectory == true,
                          values.isPackage != true else {
                        return nil
                    }
                    let isHidden = (values.isHidden == true) || url.lastPathComponent.hasPrefix(".")
                    if !showHidden && isHidden {
                        return nil
                    }
                    return SidebarTreeNode(
                        url: url,
                        name: url.lastPathComponent,
                        iconKind: ExplorerLocation.folder(url).iconKind,
                        children: nil,
                        isExpanded: false,
                        hasChildren: true
                    )
                }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }.value

            lazyChildrenByURL[targetURL] = loaded
            loadingFolderURLs.remove(targetURL)
        }
    }
}

// MARK: - Section Header & Sidebar Row

private struct SidebarSectionHeader: View {
    let title: String
    @Binding var isExpanded: Bool

    @Environment(\.fluentTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.14)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.palette.textSecondary)
                    .frame(width: 12)
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(theme.palette.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isHovered ? theme.palette.hoverFill : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private struct SidebarRowView: View {
    let title: String
    let iconKind: FluentIconKind
    let isSelected: Bool
    var indentLevel: Int = 0
    var showPinGlyph: Bool = false
    var disclosureExpanded: Bool? = nil
    var onToggleDisclosure: (() -> Void)? = nil
    var dropTargetURL: URL? = nil
    let store: ExplorerStore
    let action: () -> Void

    @Environment(\.fluentTheme) private var theme
    @State private var isHovered = false
    @State private var isDropTargeted = false

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(rowFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(isDropTargeted ? theme.palette.accentBlue : .clear, lineWidth: 1.5)
                )

            // Signature Windows 11 3px × 16px vertical accent pill on the left edge.
            if isSelected {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(theme.palette.accentBlue)
                    .frame(width: 3, height: 16)
                    .padding(.leading, 2)
            }

            HStack(spacing: 7) {
                if let disclosureExpanded, let onToggleDisclosure {
                    Button(action: onToggleDisclosure) {
                        Image(systemName: disclosureExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(theme.palette.textSecondary)
                            .frame(width: 14, height: 20)
                    }
                    .buttonStyle(.plain)
                } else {
                    Spacer()
                        .frame(width: 14)
                }

                FluentIconView(kind: iconKind, size: 16)

                Text(title)
                    .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                if showPinGlyph {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(theme.palette.textSecondary.opacity(0.7))
                        .rotationEffect(.degrees(45))
                }
            }
            .padding(.leading, 6 + CGFloat(indentLevel) * 14)
            .padding(.trailing, 8)
        }
        .frame(height: theme.isCompact ? 26 : 30)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovering in
            isHovered = hovering
        }
        .onDrop(
            of: [.fileURL],
            isTargeted: Binding(
                get: { isDropTargeted },
                set: { targeted in
                    isDropTargeted = (dropTargetURL != nil) && targeted
                }
            )
        ) { providers in
            guard let dropTargetURL else { return false }
            return ChromeDropHelper.handleFileURLDrop(
                providers: providers,
                destinationFolder: dropTargetURL,
                store: store
            )
        }
    }

    private var rowFill: Color {
        if isDropTargeted || isSelected {
            return theme.palette.selectionFill
        }
        if isHovered {
            return theme.palette.hoverFill
        }
        return .clear
    }
}
