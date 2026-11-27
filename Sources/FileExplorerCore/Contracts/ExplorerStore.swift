import AppKit
import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
public final class ExplorerStore {
    // MARK: - Public Observable State

    public var tabs: [ExplorerTab]
    public var activeTabID: UUID

    public var activeTab: ExplorerTab {
        get {
            tabs.first(where: { $0.id == activeTabID }) ?? tabs[0]
        }
        set {
            if let index = tabs.firstIndex(where: { $0.id == activeTabID }) {
                tabs[index] = newValue
            }
        }
    }

    public var currentItems: [FileItem] = []
    public var groupedSections: [ExplorerSection] = []
    public var volumes: [VolumeInfo] = []
    public var cloudLocations: [VolumeInfo] = []
    public var pinnedFolders: [PinnedFolder] = []
    public var favoriteFiles: [FileItem] = []
    public var recentFiles: [RecentFileEntry] = []
    public var sidebarTreeNodes: [SidebarTreeNode] = []

    public var clipboardPayload: ClipboardPayload?
    public var activeOperations: [FileOperationProgress] = []
    public var pendingConflict: ConflictRequest?
    public var settings: ExplorerSettings

    public var contextMenuTarget: ContextMenuTarget?
    public var propertiesTargetURL: URL?
    public var inlineRenamingURL: URL?
    public var isEditingPath: Bool = false
    public var activeSearchText: String = ""
    public var isSearching: Bool = false
    public var lastErrorMessage: String?
    public var tccPermissionWarningURL: URL?
    public var isQuickLookPresented: Bool = false
    public var isSettingsOpen: Bool = false
    public var snapshotMode: Bool

    public var canUndo: Bool = false
    public var canRedo: Bool = false
    public var undoDescription: String?
    public var redoDescription: String?
    public var trashItemCount: Int = 0

    // MARK: - Computed Helpers

    public var selectedItems: [FileItem] {
        let selected = activeTab.selectedURLs
        return currentItems.filter { selected.contains($0.url) }
    }

    public var primarySelectedItem: FileItem? {
        if let anchor = activeTab.anchorURL,
           let item = currentItems.first(where: { $0.url == anchor && activeTab.selectedURLs.contains(anchor) }) {
            return item
        }
        return selectedItems.first
    }

    public var isTrashEmpty: Bool {
        trashItemCount == 0
    }

    // MARK: - Initialization

    public init(
        settings: ExplorerSettings = .default,
        snapshotMode: Bool = false
    ) {
        let initialLocation: ExplorerLocation = settings.launchTarget == .thisPC ? .thisPC : .home
        let initialTab = ExplorerTab(location: initialLocation)
        self.tabs = [initialTab]
        self.activeTabID = initialTab.id
        self.settings = settings
        self.snapshotMode = snapshotMode

        if snapshotMode {
            loadSnapshotFixtures()
        }
    }

    public static func makeSnapshotPreviewStore() -> ExplorerStore {
        ExplorerStore(settings: .default, snapshotMode: true)
    }

    // MARK: - Tab Management

    public func newTab(at location: ExplorerLocation = .home, activate: Bool = true) {
        let tab = ExplorerTab(
            location: location,
            viewMode: activeTab.viewMode,
            sortField: activeTab.sortField,
            sortOrder: activeTab.sortOrder,
            groupBy: activeTab.groupBy
        )
        tabs.append(tab)
        if activate {
            activeTabID = tab.id
            activeSearchText = tab.searchQuery
            refreshCurrentListingInMemory()
        }
    }

    public func closeTab(id: UUID) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == id }) else {
            return
        }
        tabs.remove(at: index)
        if activeTabID == id {
            let nextIndex = min(index, tabs.count - 1)
            activeTabID = tabs[nextIndex].id
            activeSearchText = activeTab.searchQuery
            refreshCurrentListingInMemory()
        }
    }

    public func closeOtherTabs(keeping id: UUID) {
        guard let kept = tabs.first(where: { $0.id == id }) else { return }
        tabs = [kept]
        activeTabID = kept.id
        activeSearchText = kept.searchQuery
        refreshCurrentListingInMemory()
    }

    public func selectTab(id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
        inlineRenamingURL = nil
        isEditingPath = false
        activeSearchText = activeTab.searchQuery
        refreshCurrentListingInMemory()
    }

    public func duplicateTab(id: UUID) {
        guard let source = tabs.first(where: { $0.id == id }),
              let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let copy = ExplorerTab(
            location: source.location,
            title: source.title,
            backStack: source.backStack,
            forwardStack: source.forwardStack,
            viewMode: source.viewMode,
            sortField: source.sortField,
            sortOrder: source.sortOrder,
            groupBy: source.groupBy,
            selectedURLs: [],
            anchorURL: nil,
            searchQuery: source.searchQuery,
            searchFilters: source.searchFilters,
            scrollOffset: 0
        )
        tabs.insert(copy, at: index + 1)
        activeTabID = copy.id
        refreshCurrentListingInMemory()
    }

    public func moveTab(from sourceIndex: Int, to destinationIndex: Int) {
        guard tabs.indices.contains(sourceIndex),
              destinationIndex >= 0,
              destinationIndex <= tabs.count,
              sourceIndex != destinationIndex else { return }
        let item = tabs.remove(at: sourceIndex)
        let adjusted = destinationIndex > sourceIndex ? destinationIndex - 1 : destinationIndex
        tabs.insert(item, at: max(0, min(adjusted, tabs.count)))
    }

    // MARK: - Navigation & View State

    public func navigate(to location: ExplorerLocation) {
        var tab = activeTab
        if tab.location != location {
            tab.backStack.append(tab.location)
            tab.forwardStack.removeAll()
        }
        tab.location = location
        tab.title = location.displayTitle
        tab.selectedURLs.removeAll()
        tab.anchorURL = nil
        tab.scrollOffset = 0
        if case .search(let query, _, let filters) = location {
            tab.searchQuery = query
            tab.searchFilters = filters
            activeSearchText = query
        } else {
            tab.searchQuery = ""
            activeSearchText = ""
        }
        activeTab = tab
        inlineRenamingURL = nil
        isEditingPath = false
        refreshCurrentListingInMemory()
    }

    public func openItem(_ item: FileItem) {
        if item.isDirectory && !item.isPackage {
            navigate(to: .folder(item.url))
        } else {
            openItemWithDefaultApp(item.url)
        }
    }

    public func openItemWithDefaultApp(_ url: URL) {
        guard !snapshotMode else { return }
        NSWorkspace.shared.open(url)
    }

    public func openItem(_ url: URL, withApplication appURL: URL) {
        guard !snapshotMode else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
    }

    public func revealInFinder(_ url: URL) {
        guard !snapshotMode else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public func goBack() {
        var tab = activeTab
        guard let previous = tab.backStack.popLast() else { return }
        tab.forwardStack.append(tab.location)
        tab.location = previous
        tab.title = previous.displayTitle
        tab.selectedURLs.removeAll()
        tab.anchorURL = nil
        activeTab = tab
        inlineRenamingURL = nil
        refreshCurrentListingInMemory()
    }

    public func goForward() {
        var tab = activeTab
        guard let next = tab.forwardStack.popLast() else { return }
        tab.backStack.append(tab.location)
        tab.location = next
        tab.title = next.displayTitle
        tab.selectedURLs.removeAll()
        tab.anchorURL = nil
        activeTab = tab
        inlineRenamingURL = nil
        refreshCurrentListingInMemory()
    }

    public func goUp() {
        switch activeTab.location {
        case .folder(let url):
            let parent = url.deletingLastPathComponent()
            if parent != url {
                navigate(to: .folder(parent))
            }
        case .search(_, let scope, _):
            navigate(to: .folder(scope))
        case .gallery, .thisPC, .recycleBin, .network:
            navigate(to: .home)
        case .home:
            break
        }
    }

    public func refresh() {
        refreshCurrentListingInMemory()
    }

    public func setViewMode(_ mode: ViewMode) {
        var tab = activeTab
        tab.viewMode = mode
        activeTab = tab
    }

    public func setSort(field: SortField, order: SortOrder? = nil) {
        var tab = activeTab
        if let order {
            tab.sortField = field
            tab.sortOrder = order
        } else if tab.sortField == field {
            tab.sortOrder = tab.sortOrder.toggled
        } else {
            tab.sortField = field
            tab.sortOrder = .ascending
        }
        activeTab = tab
        applySortAndGrouping()
    }

    public func setGroupBy(_ groupBy: GroupByField) {
        var tab = activeTab
        tab.groupBy = groupBy
        activeTab = tab
        applySortAndGrouping()
    }

    public func setScrollOffset(_ offset: CGFloat) {
        var tab = activeTab
        tab.scrollOffset = offset
        activeTab = tab
    }

    public func expandSidebarNode(url: URL) {
        updateSidebarNode(url: url, in: &sidebarTreeNodes, isExpanded: true)
    }

    public func collapseSidebarNode(url: URL) {
        updateSidebarNode(url: url, in: &sidebarTreeNodes, isExpanded: false)
    }

    // MARK: - Selection

    public func selectItem(url: URL, extending: Bool = false, toggling: Bool = false) {
        var tab = activeTab
        if extending {
            selectRange(to: url)
            return
        }
        if toggling {
            if tab.selectedURLs.contains(url) {
                tab.selectedURLs.remove(url)
            } else {
                tab.selectedURLs.insert(url)
                tab.anchorURL = url
            }
        } else {
            tab.selectedURLs = [url]
            tab.anchorURL = url
        }
        activeTab = tab
    }

    public func selectRange(to url: URL) {
        var tab = activeTab
        guard let targetIndex = currentItems.firstIndex(where: { $0.url == url }) else { return }
        let anchorIndex: Int
        if let anchor = tab.anchorURL,
           let found = currentItems.firstIndex(where: { $0.url == anchor }) {
            anchorIndex = found
        } else {
            anchorIndex = targetIndex
            tab.anchorURL = url
        }
        let lower = min(anchorIndex, targetIndex)
        let upper = max(anchorIndex, targetIndex)
        tab.selectedURLs = Set(currentItems[lower...upper].map(\.url))
        activeTab = tab
    }

    public func selectAll() {
        var tab = activeTab
        tab.selectedURLs = Set(currentItems.map(\.url))
        if tab.anchorURL == nil {
            tab.anchorURL = currentItems.first?.url
        }
        activeTab = tab
    }

    public func deselectAll() {
        var tab = activeTab
        tab.selectedURLs.removeAll()
        tab.anchorURL = nil
        activeTab = tab
    }

    public func invertSelection() {
        var tab = activeTab
        let all = Set(currentItems.map(\.url))
        tab.selectedURLs = all.subtracting(tab.selectedURLs)
        activeTab = tab
    }

    public func setSelection(_ urls: Set<URL>) {
        var tab = activeTab
        tab.selectedURLs = urls
        if let first = currentItems.first(where: { urls.contains($0.url) }) {
            tab.anchorURL = first.url
        }
        activeTab = tab
    }

    // MARK: - Clipboard

    public func copySelectedItems() {
        let urls = selectedItems.map(\.url)
        copyItems(urls: urls)
    }

    public func cutSelectedItems() {
        let urls = selectedItems.map(\.url)
        cutItems(urls: urls)
    }

    public func copyItems(urls: [URL]) {
        guard !urls.isEmpty else { return }
        clipboardPayload = ClipboardPayload(operation: .copy, urls: urls)
    }

    public func cutItems(urls: [URL]) {
        guard !urls.isEmpty else { return }
        clipboardPayload = ClipboardPayload(operation: .cut, urls: urls)
    }

    public func pasteIntoCurrentFolder() {
        guard let folder = activeTab.location.urlIfFolder else { return }
        paste(into: folder)
    }

    public func paste(into destinationURL: URL) {
        guard let payload = clipboardPayload else { return }
        if payload.operation == .cut {
            clipboardPayload = nil
        }
        _ = destinationURL
    }

    public func copyPathOfSelectedItems() {
        let paths = selectedItems.map(\.url.path)
        guard !paths.isEmpty else { return }
        let joined = paths.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(joined, forType: .string)
    }

    // MARK: - File Operations (Stub / In-Memory Defaults)

    public func newFolder(named name: String? = nil) {
        let folderName = uniqueItemName(base: name ?? "New folder", isFolder: true)
        let baseURL = activeTab.location.urlIfFolder ?? FileManager.default.homeDirectoryForCurrentUser
        let url = baseURL.appendingPathComponent(folderName, isDirectory: true)
        let item = FileItem(
            url: url,
            name: folderName,
            displayName: folderName,
            fileExtension: "",
            kind: .folder,
            isDirectory: true,
            childCount: 0,
            typeDescription: "File folder"
        )
        currentItems.insert(item, at: 0)
        applySortAndGrouping()
        selectItem(url: url)
        beginInlineRename(for: url)
    }

    public func newFile(named name: String? = nil, fileExtension: String = "txt") {
        let baseName = name ?? "New Text Document"
        let ext = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let fullBase = ext.isEmpty ? baseName : "\(baseName).\(ext)"
        let fileName = uniqueItemName(base: fullBase, isFolder: false)
        let baseURL = activeTab.location.urlIfFolder ?? FileManager.default.homeDirectoryForCurrentUser
        let url = baseURL.appendingPathComponent(fileName, isDirectory: false)
        let item = FileItem(
            url: url,
            name: fileName,
            displayName: fileName,
            fileExtension: ext,
            kind: ext == "md" ? .markdown : (ext == "json" ? .json : .text),
            isDirectory: false,
            size: 0,
            typeDescription: ext.isEmpty ? "File" : "\(ext.uppercased()) File"
        )
        currentItems.append(item)
        applySortAndGrouping()
        selectItem(url: url)
        beginInlineRename(for: url)
    }

    public func beginInlineRename(for url: URL) {
        inlineRenamingURL = url
    }

    public func commitInlineRename(for url: URL, newName: String) {
        inlineRenamingURL = nil
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        renameItem(at: url, to: trimmed)
    }

    public func cancelInlineRename() {
        inlineRenamingURL = nil
    }

    public func renameItem(at url: URL, to newName: String) {
        guard let index = currentItems.firstIndex(where: { $0.url == url }) else { return }
        let old = currentItems[index]
        let newURL = url.deletingLastPathComponent().appendingPathComponent(newName, isDirectory: old.isDirectory)
        let newExt = old.isDirectory ? "" : newURL.pathExtension.lowercased()
        let updated = FileItem(
            url: newURL,
            name: newName,
            displayName: newName,
            fileExtension: newExt,
            kind: old.kind,
            isDirectory: old.isDirectory,
            isHidden: newName.hasPrefix("."),
            isSymlink: old.isSymlink,
            isPackage: old.isPackage,
            isReadOnly: old.isReadOnly,
            size: old.size,
            dateModified: Date(),
            dateCreated: old.dateCreated,
            childCount: old.childCount,
            typeDescription: old.typeDescription,
            posixPermissions: old.posixPermissions
        )
        currentItems[index] = updated
        var tab = activeTab
        if tab.selectedURLs.remove(url) != nil {
            tab.selectedURLs.insert(newURL)
        }
        if tab.anchorURL == url {
            tab.anchorURL = newURL
        }
        activeTab = tab
        applySortAndGrouping()
    }

    public func deleteSelectedItems() {
        deleteItems(urls: selectedItems.map(\.url))
    }

    public func deleteItems(urls: [URL]) {
        guard !urls.isEmpty else { return }
        let set = Set(urls)
        currentItems.removeAll { set.contains($0.url) }
        trashItemCount += urls.count
        var tab = activeTab
        tab.selectedURLs.subtract(set)
        activeTab = tab
        applySortAndGrouping()
    }

    public func permanentDeleteSelectedItems() {
        permanentDeleteItems(urls: selectedItems.map(\.url))
    }

    public func permanentDeleteItems(urls: [URL]) {
        guard !urls.isEmpty else { return }
        let set = Set(urls)
        currentItems.removeAll { set.contains($0.url) }
        var tab = activeTab
        tab.selectedURLs.subtract(set)
        activeTab = tab
        applySortAndGrouping()
    }

    public func duplicateSelectedItems() {
        duplicateItems(urls: selectedItems.map(\.url))
    }

    public func duplicateItems(urls: [URL]) {
        for url in urls {
            guard let item = currentItems.first(where: { $0.url == url }) else { continue }
            let stem = item.isDirectory ? item.name : url.deletingPathExtension().lastPathComponent
            let ext = item.isDirectory ? "" : url.pathExtension
            let candidateBase = ext.isEmpty ? "\(stem) copy" : "\(stem) copy.\(ext)"
            let uniqueName = uniqueItemName(base: candidateBase, isFolder: item.isDirectory)
            let copyURL = url.deletingLastPathComponent().appendingPathComponent(uniqueName, isDirectory: item.isDirectory)
            let copyItem = FileItem(
                url: copyURL,
                name: uniqueName,
                displayName: uniqueName,
                fileExtension: item.fileExtension,
                kind: item.kind,
                isDirectory: item.isDirectory,
                isHidden: item.isHidden,
                isSymlink: item.isSymlink,
                isPackage: item.isPackage,
                isReadOnly: item.isReadOnly,
                size: item.size,
                dateModified: Date(),
                dateCreated: Date(),
                childCount: item.childCount,
                typeDescription: item.typeDescription,
                posixPermissions: item.posixPermissions
            )
            currentItems.append(copyItem)
        }
        applySortAndGrouping()
    }

    public func zipSelectedItems() {
        zipItems(urls: selectedItems.map(\.url))
    }

    public func zipItems(urls: [URL]) {
        guard let first = urls.first else { return }
        let baseName = urls.count == 1 ? "\(first.deletingPathExtension().lastPathComponent).zip" : "Archive.zip"
        let zipName = uniqueItemName(base: baseName, isFolder: false)
        let zipURL = first.deletingLastPathComponent().appendingPathComponent(zipName)
        let archiveItem = FileItem(
            url: zipURL,
            name: zipName,
            displayName: zipName,
            fileExtension: "zip",
            kind: .archive,
            isDirectory: false,
            size: 1024,
            typeDescription: "Compressed (zipped) Folder"
        )
        currentItems.append(archiveItem)
        applySortAndGrouping()
    }

    public func extractArchive(at url: URL) {
        let folderName = uniqueItemName(base: url.deletingPathExtension().lastPathComponent, isFolder: true)
        let folderURL = url.deletingLastPathComponent().appendingPathComponent(folderName, isDirectory: true)
        let extracted = FileItem(
            url: folderURL,
            name: folderName,
            displayName: folderName,
            fileExtension: "",
            kind: .folder,
            isDirectory: true,
            childCount: 0,
            typeDescription: "File folder"
        )
        currentItems.append(extracted)
        applySortAndGrouping()
    }

    public func restoreFromTrash(urls: [URL]) {
        let set = Set(urls)
        currentItems.removeAll { set.contains($0.url) }
        trashItemCount = max(0, trashItemCount - urls.count)
        applySortAndGrouping()
    }

    public func emptyTrash() {
        if activeTab.location == .recycleBin {
            currentItems.removeAll()
            groupedSections.removeAll()
        }
        trashItemCount = 0
    }

    public func moveItems(urls: [URL], to destinationFolder: URL) {
        _ = (urls, destinationFolder)
    }

    public func copyItems(_ urls: [URL], to destinationFolder: URL) {
        _ = (urls, destinationFolder)
    }

    public func resolveConflict(_ resolution: ConflictResolution, applyToAll: Bool = false) {
        _ = (resolution, applyToAll)
        pendingConflict = nil
    }

    public func cancelOperation(id: UUID) {
        activeOperations.removeAll { $0.id == id }
    }

    // MARK: - Undo / Redo

    public func undo() {
        canUndo = false
    }

    public func redo() {
        canRedo = false
    }

    // MARK: - Search

    public func performSearch(query: String, filters: SearchFilters? = nil) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        activeSearchText = query
        if trimmed.isEmpty && !(filters?.isActive ?? false) {
            clearSearch()
            return
        }
        let scope = activeTab.location.urlIfFolder ?? FileManager.default.homeDirectoryForCurrentUser
        let resolvedFilters = filters ?? activeTab.searchFilters
        navigate(to: .search(query: query, scope: scope, filters: resolvedFilters))
    }

    public func updateSearchFilters(_ filters: SearchFilters) {
        var tab = activeTab
        tab.searchFilters = filters
        activeTab = tab
        if case .search(let query, let scope, _) = tab.location {
            tab.location = .search(query: query, scope: scope, filters: filters)
            activeTab = tab
            refreshCurrentListingInMemory()
        }
    }

    public func clearSearch() {
        activeSearchText = ""
        isSearching = false
        if case .search(_, let scope, _) = activeTab.location {
            navigate(to: .folder(scope))
        }
    }

    // MARK: - Pinning & Favorites

    public func pinFolder(url: URL, title: String? = nil) {
        guard !pinnedFolders.contains(where: { $0.url == url }) else { return }
        pinnedFolders.append(PinnedFolder(url: url, title: title ?? url.lastPathComponent))
    }

    public func unpinFolder(url: URL) {
        pinnedFolders.removeAll { $0.url == url }
    }

    public func movePinnedFolder(from sourceIndex: Int, to destinationIndex: Int) {
        guard pinnedFolders.indices.contains(sourceIndex),
              destinationIndex >= 0,
              destinationIndex <= pinnedFolders.count,
              sourceIndex != destinationIndex else { return }
        let entry = pinnedFolders.remove(at: sourceIndex)
        let adjusted = destinationIndex > sourceIndex ? destinationIndex - 1 : destinationIndex
        pinnedFolders.insert(entry, at: max(0, min(adjusted, pinnedFolders.count)))
    }

    public func isPinned(url: URL) -> Bool {
        pinnedFolders.contains { $0.url == url }
    }

    public func toggleFavorite(url: URL) {
        if isFavorite(url: url) {
            removeFavorite(url: url)
        } else {
            addFavorite(url: url)
        }
    }

    public func addFavorite(url: URL) {
        guard !isFavorite(url: url) else { return }
        if let item = currentItems.first(where: { $0.url == url }) {
            favoriteFiles.append(item)
        } else {
            favoriteFiles.append(
                FileItem(
                    url: url,
                    kind: url.hasDirectoryPath ? .folder : .other,
                    isDirectory: url.hasDirectoryPath
                )
            )
        }
    }

    public func removeFavorite(url: URL) {
        favoriteFiles.removeAll { $0.url == url }
    }

    public func isFavorite(url: URL) -> Bool {
        favoriteFiles.contains { $0.url == url }
    }

    // MARK: - Columns & Settings

    public func resizeColumn(id: String, width: CGFloat) {
        guard let index = settings.columns.firstIndex(where: { $0.id == id }) else { return }
        settings.columns[index].width = max(60, width)
    }

    public func toggleColumnVisibility(id: String) {
        guard let index = settings.columns.firstIndex(where: { $0.id == id }) else { return }
        if settings.columns[index].id == "name" { return }
        settings.columns[index].isVisible.toggle()
    }

    public func updateSettings(_ transform: (inout ExplorerSettings) -> Void) {
        var copy = settings
        transform(&copy)
        settings = copy
    }

    public func resetSettingsToDefaults() {
        settings = .default
    }

    public func setSidebarWidth(_ width: CGFloat) {
        settings.sidebarWidth = min(420, max(180, width))
    }

    public func setRightPaneWidth(_ width: CGFloat) {
        settings.rightPaneWidth = min(480, max(240, width))
    }

    public func setRightPaneMode(_ mode: RightPaneMode) {
        settings.rightPaneMode = settings.rightPaneMode == mode ? .none : mode
    }

    public func toggleNavigationPane() {
        settings.showNavigationPane.toggle()
    }

    public func toggleHiddenFiles() {
        settings.showHiddenFiles.toggle()
        refreshCurrentListingInMemory()
    }

    public func toggleFileExtensions() {
        settings.showFileExtensions.toggle()
    }

    public func toggleCompactView() {
        settings.compactView.toggle()
    }

    public func toggleCheckboxes() {
        settings.showCheckboxes.toggle()
    }

    // MARK: - Context Menu, Properties, Quick Look, Path Editor & Metadata

    public func showContextMenu(for target: ContextMenuTarget) {
        contextMenuTarget = target
    }

    public func dismissContextMenu() {
        contextMenuTarget = nil
    }

    public func showProperties(for url: URL) {
        propertiesTargetURL = url
    }

    public func dismissProperties() {
        propertiesTargetURL = nil
    }

    public func toggleQuickLook() {
        isQuickLookPresented.toggle()
    }

    public func beginEditingPath() {
        isEditingPath = true
    }

    public func commitPathEdit(_ pathString: String) {
        isEditingPath = false
        let trimmed = pathString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let lowered = trimmed.lowercased()
        switch lowered {
        case "home":
            navigate(to: .home)
        case "gallery":
            navigate(to: .gallery)
        case "this pc", "this mac":
            navigate(to: .thisPC)
        case "trash", "recycle bin":
            navigate(to: .recycleBin)
        case "network":
            navigate(to: .network)
        default:
            let expanded = (trimmed as NSString).expandingTildeInPath
            navigate(to: .folder(URL(fileURLWithPath: expanded)))
        }
    }

    public func cancelPathEdit() {
        isEditingPath = false
    }

    public func openSettings() {
        isSettingsOpen = true
    }

    public func closeSettings() {
        isSettingsOpen = false
    }

    public func dismissError() {
        lastErrorMessage = nil
    }

    public func dismissTCCWarning() {
        tccPermissionWarningURL = nil
    }

    public func loadMetadata(for url: URL) async -> FileMetadata? {
        guard let item = currentItems.first(where: { $0.url == url })
            ?? favoriteFiles.first(where: { $0.url == url }) else {
            return nil
        }
        return FileMetadata(
            item: item,
            dimensions: item.kind == .image ? "2560 × 1440" : nil,
            exifSummary: item.kind == .image ? [("Camera", "Apple iPhone 16 Pro"), ("Color Space", "Display P3")] : [],
            mediaDuration: (item.kind == .video || item.kind == .audio) ? "02:34" : nil,
            mediaCodec: item.kind == .video ? "HEVC / AAC" : (item.kind == .audio ? "AAC 256 kbps" : nil),
            pdfPageCount: item.kind == .pdf ? 14 : nil,
            lineCount: (item.kind == .code || item.kind == .text || item.kind == .markdown || item.kind == .json) ? 142 : nil,
            folderSizeBytes: item.isDirectory ? 48_320_000 : nil,
            folderFileCount: item.isDirectory ? (item.childCount ?? 12) : nil,
            folderSubfolderCount: item.isDirectory ? 3 : nil,
            defaultAppName: item.isDirectory ? "Finder" : "Preview",
            defaultAppURL: nil,
            openWithApps: [
                AppChoice(url: URL(fileURLWithPath: "/System/Applications/Preview.app"), name: "Preview"),
                AppChoice(url: URL(fileURLWithPath: "/System/Applications/TextEdit.app"), name: "TextEdit")
            ]
        )
    }

    // MARK: - Snapshot Fixture Loader

    public func loadSnapshotFixtures() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        let documents = home.appendingPathComponent("Documents", isDirectory: true)
        let pictures = home.appendingPathComponent("Pictures", isDirectory: true)
        let music = home.appendingPathComponent("Music", isDirectory: true)
        let videos = home.appendingPathComponent("Movies", isDirectory: true)

        pinnedFolders = [
            PinnedFolder(url: desktop, title: "Desktop", iconName: "desktop"),
            PinnedFolder(url: downloads, title: "Downloads", iconName: "downloads"),
            PinnedFolder(url: documents, title: "Documents", iconName: "documents"),
            PinnedFolder(url: pictures, title: "Pictures", iconName: "pictures"),
            PinnedFolder(url: music, title: "Music", iconName: "music"),
            PinnedFolder(url: videos, title: "Videos", iconName: "videos")
        ]

        volumes = [
            VolumeInfo(
                url: URL(fileURLWithPath: "/"),
                name: "Macintosh HD",
                volumeKind: .internalDrive,
                totalBytes: 1_000_204_886_016,
                freeBytes: 384_510_000_000,
                fileSystemFormat: "APFS"
            ),
            VolumeInfo(
                url: URL(fileURLWithPath: "/Volumes/T7 Shield"),
                name: "T7 Shield (D:)",
                volumeKind: .externalDrive,
                totalBytes: 2_000_398_934_016,
                freeBytes: 1_240_000_000_000,
                fileSystemFormat: "exFAT"
            )
        ]

        cloudLocations = [
            VolumeInfo(
                url: home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true),
                name: "iCloud Drive",
                volumeKind: .cloudDrive,
                totalBytes: 200_000_000_000,
                freeBytes: 118_000_000_000,
                fileSystemFormat: "Cloud"
            )
        ]

        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let sampleFolder = documents
        let fixtureItems: [FileItem] = [
            FileItem(
                url: sampleFolder.appendingPathComponent("Architecture Specs", isDirectory: true),
                kind: .folder,
                isDirectory: true,
                dateModified: now.addingTimeInterval(-3600),
                dateCreated: now.addingTimeInterval(-86400 * 14),
                childCount: 8,
                typeDescription: "File folder",
                posixPermissions: POSIXPermissions(mode: 0o755)
            ),
            FileItem(
                url: sampleFolder.appendingPathComponent("Design Assets", isDirectory: true),
                kind: .folder,
                isDirectory: true,
                dateModified: now.addingTimeInterval(-7200),
                dateCreated: now.addingTimeInterval(-86400 * 30),
                childCount: 24,
                typeDescription: "File folder",
                posixPermissions: POSIXPermissions(mode: 0o755)
            ),
            FileItem(
                url: sampleFolder.appendingPathComponent("Q4 Roadmap.pdf"),
                kind: .pdf,
                isDirectory: false,
                size: 4_820_412,
                dateModified: now.addingTimeInterval(-1800),
                dateCreated: now.addingTimeInterval(-86400 * 5),
                typeDescription: "PDF Document",
                posixPermissions: POSIXPermissions(mode: 0o644)
            ),
            FileItem(
                url: sampleFolder.appendingPathComponent("HeroBanner.png"),
                kind: .image,
                isDirectory: false,
                size: 2_310_890,
                dateModified: now.addingTimeInterval(-5400),
                dateCreated: now.addingTimeInterval(-86400 * 2),
                typeDescription: "PNG Image",
                posixPermissions: POSIXPermissions(mode: 0o644)
            ),
            FileItem(
                url: sampleFolder.appendingPathComponent("Package.swift"),
                kind: .code,
                isDirectory: false,
                size: 3_420,
                dateModified: now.addingTimeInterval(-900),
                dateCreated: now.addingTimeInterval(-86400),
                typeDescription: "Swift Source",
                posixPermissions: POSIXPermissions(mode: 0o644)
            ),
            FileItem(
                url: sampleFolder.appendingPathComponent("Budget_2026.xlsx"),
                kind: .spreadsheet,
                isDirectory: false,
                size: 642_110,
                dateModified: now.addingTimeInterval(-86400),
                dateCreated: now.addingTimeInterval(-86400 * 10),
                typeDescription: "Microsoft Excel Worksheet",
                posixPermissions: POSIXPermissions(mode: 0o644)
            ),
            FileItem(
                url: sampleFolder.appendingPathComponent("README.md"),
                kind: .markdown,
                isDirectory: false,
                size: 8_192,
                dateModified: now.addingTimeInterval(-1200),
                dateCreated: now.addingTimeInterval(-86400 * 3),
                typeDescription: "Markdown Document",
                posixPermissions: POSIXPermissions(mode: 0o644)
            ),
            FileItem(
                url: sampleFolder.appendingPathComponent("Release_Build.zip"),
                kind: .archive,
                isDirectory: false,
                size: 98_420_000,
                dateModified: now.addingTimeInterval(-86400 * 4),
                dateCreated: now.addingTimeInterval(-86400 * 4),
                typeDescription: "Compressed (zipped) Folder",
                posixPermissions: POSIXPermissions(mode: 0o644)
            )
        ]

        currentItems = fixtureItems
        favoriteFiles = [fixtureItems[2], fixtureItems[4]]
        recentFiles = [
            RecentFileEntry(url: fixtureItems[2].url, name: fixtureItems[2].name, accessedAt: now.addingTimeInterval(-1800), kind: .pdf),
            RecentFileEntry(url: fixtureItems[4].url, name: fixtureItems[4].name, accessedAt: now.addingTimeInterval(-900), kind: .code),
            RecentFileEntry(url: fixtureItems[3].url, name: fixtureItems[3].name, accessedAt: now.addingTimeInterval(-5400), kind: .image),
            RecentFileEntry(url: fixtureItems[6].url, name: fixtureItems[6].name, accessedAt: now.addingTimeInterval(-1200), kind: .markdown)
        ]

        sidebarTreeNodes = [
            SidebarTreeNode(
                url: URL(fileURLWithPath: "/"),
                name: "Macintosh HD",
                iconKind: .hardDrive,
                children: [
                    SidebarTreeNode(url: URL(fileURLWithPath: "/Applications"), name: "Applications", iconKind: .applications, children: [], hasChildren: true),
                    SidebarTreeNode(url: home, name: home.lastPathComponent, iconKind: .home, children: [
                        SidebarTreeNode(url: desktop, name: "Desktop", iconKind: .desktop, children: [], hasChildren: false),
                        SidebarTreeNode(url: documents, name: "Documents", iconKind: .documents, children: [], hasChildren: true),
                        SidebarTreeNode(url: downloads, name: "Downloads", iconKind: .downloads, children: [], hasChildren: false),
                        SidebarTreeNode(url: pictures, name: "Pictures", iconKind: .pictures, children: [], hasChildren: false)
                    ], isExpanded: true, hasChildren: true)
                ],
                isExpanded: true,
                hasChildren: true
            )
        ]

        trashItemCount = 3
        applySortAndGrouping()
    }

    // MARK: - Internal In-Memory Helpers

    private func refreshCurrentListingInMemory() {
        applySortAndGrouping()
    }

    private func applySortAndGrouping() {
        let field = activeTab.sortField
        let order = activeTab.sortOrder
        currentItems.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            let comparison: ComparisonResult
            switch field {
            case .name:
                comparison = lhs.name.localizedStandardCompare(rhs.name)
            case .dateModified:
                comparison = lhs.dateModified.compare(rhs.dateModified)
            case .dateCreated:
                comparison = lhs.dateCreated.compare(rhs.dateCreated)
            case .type:
                comparison = lhs.typeDescription.localizedStandardCompare(rhs.typeDescription)
            case .size:
                if lhs.size == rhs.size {
                    comparison = .orderedSame
                } else {
                    comparison = lhs.size < rhs.size ? .orderedAscending : .orderedDescending
                }
            }
            if comparison == .orderedSame {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return order == .ascending ? (comparison == .orderedAscending) : (comparison == .orderedDescending)
        }

        switch activeTab.groupBy {
        case .none:
            groupedSections = []
        case .name:
            let dict = Dictionary(grouping: currentItems) { item in
                String(item.name.prefix(1)).uppercased()
            }
            groupedSections = dict.keys.sorted().map { key in
                ExplorerSection(id: key, title: key, items: dict[key] ?? [])
            }
        case .type:
            let dict = Dictionary(grouping: currentItems) { $0.typeDescription }
            groupedSections = dict.keys.sorted().map { key in
                ExplorerSection(id: key, title: key, items: dict[key] ?? [])
            }
        case .dateModified:
            let calendar = Calendar.current
            let dict = Dictionary(grouping: currentItems) { item -> String in
                if calendar.isDateInToday(item.dateModified) { return "Today" }
                if calendar.isDateInYesterday(item.dateModified) { return "Yesterday" }
                return "Earlier"
            }
            let orderKeys = ["Today", "Yesterday", "Earlier"]
            groupedSections = orderKeys.compactMap { key in
                guard let items = dict[key], !items.isEmpty else { return nil }
                return ExplorerSection(id: key, title: key, items: items)
            }
        case .size:
            let dict = Dictionary(grouping: currentItems) { item -> String in
                if item.isDirectory { return "Folders" }
                if item.size == 0 { return "Empty (0 B)" }
                if item.size < 100_000 { return "Tiny (< 100 KB)" }
                if item.size < 1_000_000 { return "Small (100 KB - 1 MB)" }
                if item.size < 100_000_000 { return "Medium (1 - 100 MB)" }
                return "Large (> 100 MB)"
            }
            groupedSections = dict.keys.sorted().map { key in
                ExplorerSection(id: key, title: key, items: dict[key] ?? [])
            }
        }
    }

    private func uniqueItemName(base: String, isFolder: Bool) -> String {
        let existingNames = Set(currentItems.map { $0.name.lowercased() })
        if !existingNames.contains(base.lowercased()) {
            return base
        }
        let stem: String
        let ext: String
        if isFolder || !base.contains(".") {
            stem = base
            ext = ""
        } else {
            let url = URL(fileURLWithPath: base)
            stem = url.deletingPathExtension().lastPathComponent
            ext = url.pathExtension
        }
        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            if !existingNames.contains(candidate.lowercased()) {
                return candidate
            }
            counter += 1
        }
    }

    private func updateSidebarNode(url: URL, in nodes: inout [SidebarTreeNode], isExpanded: Bool) {
        for index in nodes.indices {
            if nodes[index].url == url {
                nodes[index].isExpanded = isExpanded
                return
            }
            if var children = nodes[index].children {
                updateSidebarNode(url: url, in: &children, isExpanded: isExpanded)
                nodes[index].children = children
            }
        }
    }
}
