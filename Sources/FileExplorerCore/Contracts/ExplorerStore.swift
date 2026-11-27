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

    // MARK: - Services (Private)

    private let fileSystemService = FileSystemService()
    private let operationsEngine = FileOperationsEngine()
    private let undoManager = UndoHistoryManager()
    private let searchService = SearchService()
    private let metadataService = MetadataService()
    private let clipboardManager: ClipboardManager
    private let persistenceService: PersistenceService
    private let directoryWatcher = DirectoryWatcher()

    private var trashOrigins: [String: String] = [:]
    private var listingTask: Task<Void, Never>?
    private var operationTasks: [UUID: Task<Void, Never>] = [:]
    private var conflictContinuation: CheckedContinuation<(ConflictResolution, Bool), Never>?

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

    public var isDefaultFileViewer: Bool {
        metadataService.isNSFileViewerEnabled()
    }

    // MARK: - Initialization

    public init(
        settings: ExplorerSettings = .default,
        snapshotMode: Bool = false
    ) {
        let persistence = PersistenceService()
        self.persistenceService = persistence
        self.clipboardManager = ClipboardManager(pasteboard: .general)
        self.snapshotMode = snapshotMode

        if snapshotMode {
            let initialLocation: ExplorerLocation = settings.launchTarget == .thisPC ? .thisPC : .home
            let initialTab = ExplorerTab(location: initialLocation)
            self.tabs = [initialTab]
            self.activeTabID = initialTab.id
            self.settings = settings
            loadSnapshotFixtures()
            return
        }

        let resolvedSettings: ExplorerSettings
        if settings == .default, let saved = persistence.loadSettings() {
            resolvedSettings = saved
        } else {
            resolvedSettings = settings
        }
        self.settings = resolvedSettings

        if resolvedSettings.launchTarget == .lastSession,
           let savedSession = persistence.loadSession(),
           !savedSession.tabs.isEmpty {
            self.tabs = savedSession.tabs
            if savedSession.tabs.contains(where: { $0.id == savedSession.activeTabID }) {
                self.activeTabID = savedSession.activeTabID
            } else {
                self.activeTabID = savedSession.tabs[0].id
            }
        } else {
            let initialLocation: ExplorerLocation = resolvedSettings.launchTarget == .thisPC ? .thisPC : .home
            let initialTab = ExplorerTab(location: initialLocation)
            self.tabs = [initialTab]
            self.activeTabID = initialTab.id
        }

        bootstrapLiveState()
    }

    public init(
        persistenceDirectory: URL,
        settings: ExplorerSettings? = nil,
        pasteboard: NSPasteboard? = nil
    ) {
        let persistence = PersistenceService(baseDirectory: persistenceDirectory)
        self.persistenceService = persistence
        self.clipboardManager = ClipboardManager(pasteboard: pasteboard ?? .general)
        self.snapshotMode = false

        let resolvedSettings = settings ?? persistence.loadSettings() ?? .default
        self.settings = resolvedSettings

        if resolvedSettings.launchTarget == .lastSession,
           let savedSession = persistence.loadSession(),
           !savedSession.tabs.isEmpty {
            self.tabs = savedSession.tabs
            if savedSession.tabs.contains(where: { $0.id == savedSession.activeTabID }) {
                self.activeTabID = savedSession.activeTabID
            } else {
                self.activeTabID = savedSession.tabs[0].id
            }
        } else {
            let initialLocation: ExplorerLocation = resolvedSettings.launchTarget == .thisPC ? .thisPC : .home
            let initialTab = ExplorerTab(location: initialLocation)
            self.tabs = [initialTab]
            self.activeTabID = initialTab.id
        }

        bootstrapLiveState()
    }

    public static func makeSnapshotPreviewStore() -> ExplorerStore {
        ExplorerStore(settings: .default, snapshotMode: true)
    }

    private func bootstrapLiveState() {
        pinnedFolders = persistenceService.loadPinnedFolders() ?? Self.defaultPinnedFolders()
        favoriteFiles = persistenceService.loadFavorites() ?? []
        recentFiles = persistenceService.loadRecentFiles() ?? []
        trashOrigins = persistenceService.loadTrashOrigins()
        clipboardPayload = clipboardManager.currentPayload()
        activeSearchText = activeTab.searchQuery

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshVolumesAndSidebar()
            await self.refreshAsync()
        }
    }

    private static func defaultPinnedFolders() -> [PinnedFolder] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            PinnedFolder(url: home.appendingPathComponent("Desktop", isDirectory: true), title: "Desktop", iconName: "desktop"),
            PinnedFolder(url: home.appendingPathComponent("Downloads", isDirectory: true), title: "Downloads", iconName: "downloads"),
            PinnedFolder(url: home.appendingPathComponent("Documents", isDirectory: true), title: "Documents", iconName: "documents"),
            PinnedFolder(url: home.appendingPathComponent("Pictures", isDirectory: true), title: "Pictures", iconName: "pictures"),
            PinnedFolder(url: home.appendingPathComponent("Music", isDirectory: true), title: "Music", iconName: "music"),
            PinnedFolder(url: home.appendingPathComponent("Movies", isDirectory: true), title: "Videos", iconName: "videos")
        ]
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
            triggerRefresh()
        }
        persistSessionIfNeeded()
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
            triggerRefresh()
        }
        persistSessionIfNeeded()
    }

    public func closeOtherTabs(keeping id: UUID) {
        guard let kept = tabs.first(where: { $0.id == id }) else { return }
        tabs = [kept]
        activeTabID = kept.id
        activeSearchText = kept.searchQuery
        triggerRefresh()
        persistSessionIfNeeded()
    }

    public func selectTab(id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
        inlineRenamingURL = nil
        isEditingPath = false
        activeSearchText = activeTab.searchQuery
        triggerRefresh()
        persistSessionIfNeeded()
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
        triggerRefresh()
        persistSessionIfNeeded()
    }

    public func moveTab(from sourceIndex: Int, to destinationIndex: Int) {
        guard tabs.indices.contains(sourceIndex),
              destinationIndex >= 0,
              destinationIndex <= tabs.count,
              sourceIndex != destinationIndex else { return }
        let item = tabs.remove(at: sourceIndex)
        let adjusted = destinationIndex > sourceIndex ? destinationIndex - 1 : destinationIndex
        tabs.insert(item, at: max(0, min(adjusted, tabs.count)))
        persistSessionIfNeeded()
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
        triggerRefresh()
        persistSessionIfNeeded()
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
        recordRecentFile(url: url)
        NSWorkspace.shared.open(url)
    }

    public func openItem(_ url: URL, withApplication appURL: URL) {
        guard !snapshotMode else { return }
        recordRecentFile(url: url)
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
    }

    public func revealInFinder(_ url: URL) {
        guard !snapshotMode else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public func openInTerminal(at url: URL) {
        guard !snapshotMode else { return }
        metadataService.openInTerminal(at: url)
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
        activeSearchText = tab.searchQuery
        triggerRefresh()
        persistSessionIfNeeded()
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
        activeSearchText = tab.searchQuery
        triggerRefresh()
        persistSessionIfNeeded()
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
        triggerRefresh()
        if !snapshotMode {
            Task { @MainActor [weak self] in
                await self?.refreshVolumesAndSidebar()
            }
        }
    }

    public func refreshAsync() async {
        if snapshotMode {
            refreshCurrentListingInMemory()
            return
        }

        let location = activeTab.location
        let showHidden = settings.showHiddenFiles
        let fs = fileSystemService

        switch location {
        case .home, .thisPC, .network:
            directoryWatcher.stop()
            tccPermissionWarningURL = nil
            isSearching = false
            currentItems = []
            groupedSections = []
            trashItemCount = await Task.detached(priority: .utility) {
                fs.trashCount()
            }.value

        case .gallery:
            directoryWatcher.stop()
            tccPermissionWarningURL = nil
            isSearching = false
            let items = await Task.detached(priority: .userInitiated) {
                fs.listGalleryItems()
            }.value
            currentItems = items
            applySortAndGrouping()

        case .recycleBin:
            tccPermissionWarningURL = nil
            isSearching = false
            let trashURL = fs.trashDirectoryURL
            directoryWatcher.watch(url: trashURL) { [weak self] in
                self?.triggerRefresh()
            }
            let items = await Task.detached(priority: .userInitiated) {
                (try? fs.listTrash()) ?? []
            }.value
            currentItems = items
            trashItemCount = items.count
            applySortAndGrouping()

        case .folder(let folderURL):
            isSearching = false
            directoryWatcher.watch(url: folderURL) { [weak self] in
                self?.triggerRefresh()
            }
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[FileItem], Error> in
                do {
                    return .success(try fs.listDirectory(at: folderURL, includeHidden: showHidden))
                } catch {
                    return .failure(error)
                }
            }.value

            switch result {
            case .success(let items):
                tccPermissionWarningURL = nil
                currentItems = items
                applySortAndGrouping()
            case .failure(let error):
                if case FileSystemError.permissionDenied(let deniedURL) = error {
                    tccPermissionWarningURL = deniedURL
                } else if FileSystemService.isPermissionError(error as NSError) {
                    tccPermissionWarningURL = folderURL
                } else {
                    lastErrorMessage = error.localizedDescription
                }
                currentItems = []
                groupedSections = []
            }
            trashItemCount = await Task.detached(priority: .utility) {
                fs.trashCount()
            }.value

        case .search(let query, let scope, let filters):
            directoryWatcher.stop()
            tccPermissionWarningURL = nil
            isSearching = true
            defer { isSearching = false }
            do {
                let results = try await searchService.search(
                    in: scope,
                    query: query,
                    filters: filters,
                    includeHidden: showHidden
                )
                if Task.isCancelled { return }
                currentItems = results
                applySortAndGrouping()
            } catch is CancellationError {
                return
            } catch {
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    public func refreshVolumesAndSidebar() async {
        guard !snapshotMode else { return }
        let fs = fileSystemService
        let showHidden = settings.showHiddenFiles
        let discovered = await Task.detached(priority: .utility) {
            fs.discoverVolumes()
        }.value

        volumes = discovered.volumes
        cloudLocations = discovered.cloudDrives

        let builtNodes = await Task.detached(priority: .utility) { () -> [SidebarTreeNode] in
            let home = FileManager.default.homeDirectoryForCurrentUser
            let userSubfolders = [
                ("Desktop", LocationIconKind.desktop),
                ("Documents", LocationIconKind.documents),
                ("Downloads", LocationIconKind.downloads),
                ("Pictures", LocationIconKind.pictures),
                ("Music", LocationIconKind.music),
                ("Movies", LocationIconKind.videos)
            ].compactMap { name, icon -> SidebarTreeNode? in
                let url = home.appendingPathComponent(name, isDirectory: true)
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                return SidebarTreeNode(url: url, name: name, iconKind: icon, children: nil, isExpanded: false, hasChildren: true)
            }

            let homeNode = SidebarTreeNode(
                url: home,
                name: home.lastPathComponent,
                iconKind: .home,
                children: userSubfolders,
                isExpanded: false,
                hasChildren: true
            )

            let appsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
            let appsNode = SidebarTreeNode(
                url: appsURL,
                name: "Applications",
                iconKind: .applications,
                children: nil,
                isExpanded: false,
                hasChildren: true
            )

            var rootChildren = [appsNode, homeNode]
            for vol in discovered.volumes where vol.url.path != "/" {
                let children = fs.loadChildFolders(of: vol.url, includeHidden: showHidden)
                rootChildren.append(
                    SidebarTreeNode(
                        url: vol.url,
                        name: vol.name,
                        iconKind: vol.volumeKind == .networkDrive ? .networkDrive : .externalDrive,
                        children: children,
                        isExpanded: false,
                        hasChildren: !children.isEmpty
                    )
                )
            }

            return [
                SidebarTreeNode(
                    url: URL(fileURLWithPath: "/"),
                    name: "Macintosh HD",
                    iconKind: .hardDrive,
                    children: rootChildren,
                    isExpanded: false,
                    hasChildren: true
                )
            ]
        }.value

        sidebarTreeNodes = builtNodes
    }

    public func loadChildFolders(of url: URL) async -> [SidebarTreeNode] {
        if snapshotMode {
            return findSidebarNode(url: url, in: sidebarTreeNodes)?.children ?? []
        }
        let fs = fileSystemService
        let showHidden = settings.showHiddenFiles
        let children = await Task.detached(priority: .userInitiated) {
            fs.loadChildFolders(of: url, includeHidden: showHidden)
        }.value
        updateSidebarChildren(url: url, in: &sidebarTreeNodes, children: children)
        return children
    }

    public func setViewMode(_ mode: ViewMode) {
        var tab = activeTab
        tab.viewMode = mode
        activeTab = tab
        persistSessionIfNeeded()
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
        persistSessionIfNeeded()
    }

    public func setGroupBy(_ groupBy: GroupByField) {
        var tab = activeTab
        tab.groupBy = groupBy
        activeTab = tab
        applySortAndGrouping()
        persistSessionIfNeeded()
    }

    public func setScrollOffset(_ offset: CGFloat) {
        var tab = activeTab
        tab.scrollOffset = offset
        activeTab = tab
    }

    public func expandSidebarNode(url: URL) {
        updateSidebarNode(url: url, in: &sidebarTreeNodes, isExpanded: true)
        if !snapshotMode,
           let node = findSidebarNode(url: url, in: sidebarTreeNodes),
           node.children == nil {
            Task { @MainActor [weak self] in
                _ = await self?.loadChildFolders(of: url)
            }
        }
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
        if snapshotMode {
            clipboardPayload = ClipboardPayload(operation: .copy, urls: urls)
        } else {
            clipboardPayload = clipboardManager.copy(urls: urls)
        }
    }

    public func cutItems(urls: [URL]) {
        guard !urls.isEmpty else { return }
        if snapshotMode {
            clipboardPayload = ClipboardPayload(operation: .cut, urls: urls)
        } else {
            clipboardPayload = clipboardManager.cut(urls: urls)
        }
    }

    public func syncClipboardFromSystem() {
        guard !snapshotMode else { return }
        clipboardPayload = clipboardManager.currentPayload()
    }

    public func pasteIntoCurrentFolder() {
        guard let folder = activeTab.location.urlIfFolder else { return }
        paste(into: folder)
    }

    public func paste(into destinationURL: URL) {
        if snapshotMode {
            guard let payload = clipboardPayload else { return }
            if payload.operation == .cut {
                clipboardPayload = nil
            }
            return
        }
        Task { @MainActor [weak self] in
            await self?.performPaste(into: destinationURL)
        }
    }

    public func performPaste(into destinationURL: URL) async {
        if !snapshotMode {
            clipboardPayload = clipboardManager.currentPayload()
        }
        guard let payload = clipboardPayload, !payload.urls.isEmpty else { return }
        switch payload.operation {
        case .copy:
            await performCopyItems(payload.urls, to: destinationURL)
        case .cut:
            await performMoveItems(urls: payload.urls, to: destinationURL)
            clipboardPayload = clipboardManager.clearCutStateIfNeeded()
        }
    }

    public func copyPathOfSelectedItems() {
        let paths = selectedItems.map(\.url.path)
        guard !paths.isEmpty else { return }
        if snapshotMode { return }
        clipboardManager.copyPathsToStringPasteboard(selectedItems.map(\.url))
    }

    // MARK: - File Operations

    public func newFolder(named name: String? = nil) {
        if snapshotMode {
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
            return
        }

        Task { @MainActor [weak self] in
            _ = await self?.performNewFolder(named: name)
        }
    }

    @discardableResult
    public func performNewFolder(named name: String? = nil, beginRename: Bool = true) async -> URL? {
        guard let baseURL = activeTab.location.urlIfFolder else { return nil }
        do {
            let createdURL = try await operationsEngine.createFolder(in: baseURL, named: name)
            undoManager.record(.create(urls: [createdURL]))
            syncUndoState()
            await refreshAsync()
            selectItem(url: createdURL)
            if beginRename {
                beginInlineRename(for: createdURL)
            }
            return createdURL
        } catch {
            lastErrorMessage = error.localizedDescription
            return nil
        }
    }

    public func newFile(named name: String? = nil, fileExtension: String = "txt") {
        if snapshotMode {
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
                kind: FileSystemService.classifyKind(url: url, fileExtension: ext, isDirectory: false, isPackage: false, isSymlink: false),
                isDirectory: false,
                size: 0,
                typeDescription: ext.isEmpty ? "File" : "\(ext.uppercased()) File"
            )
            currentItems.append(item)
            applySortAndGrouping()
            selectItem(url: url)
            beginInlineRename(for: url)
            return
        }

        Task { @MainActor [weak self] in
            _ = await self?.performNewFile(named: name, fileExtension: fileExtension)
        }
    }

    @discardableResult
    public func performNewFile(named name: String? = nil, fileExtension: String = "txt", beginRename: Bool = true) async -> URL? {
        guard let baseURL = activeTab.location.urlIfFolder else { return nil }
        do {
            let createdURL = try await operationsEngine.createFile(in: baseURL, named: name, fileExtension: fileExtension)
            undoManager.record(.create(urls: [createdURL]))
            syncUndoState()
            await refreshAsync()
            selectItem(url: createdURL)
            if beginRename {
                beginInlineRename(for: createdURL)
            }
            return createdURL
        } catch {
            lastErrorMessage = error.localizedDescription
            return nil
        }
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
        if snapshotMode {
            renameInMemory(at: url, to: newName)
            return
        }
        Task { @MainActor [weak self] in
            _ = await self?.performRenameItem(at: url, to: newName)
        }
    }

    @discardableResult
    public func performRenameItem(at url: URL, to newName: String) async -> URL? {
        do {
            let newURL = try await operationsEngine.renameItem(at: url, to: newName)
            if newURL != url.standardizedFileURL {
                undoManager.record(.rename(from: url.standardizedFileURL, to: newURL))
                syncUndoState()
            }
            updateReferencesAfterRename(from: url.standardizedFileURL, to: newURL)
            await refreshAsync()
            return newURL
        } catch {
            lastErrorMessage = error.localizedDescription
            return nil
        }
    }

    public func deleteSelectedItems() {
        deleteItems(urls: selectedItems.map(\.url))
    }

    public func deleteItems(urls: [URL]) {
        guard !urls.isEmpty else { return }
        if snapshotMode {
            let set = Set(urls)
            currentItems.removeAll { set.contains($0.url) }
            trashItemCount += urls.count
            var tab = activeTab
            tab.selectedURLs.subtract(set)
            activeTab = tab
            applySortAndGrouping()
            return
        }
        Task { @MainActor [weak self] in
            await self?.performDeleteItems(urls: urls)
        }
    }

    public func performDeleteItems(urls: [URL]) async {
        guard !urls.isEmpty else { return }
        do {
            let pairs = try await operationsEngine.moveToTrash(urls: urls)
            for pair in pairs {
                trashOrigins[pair.trashed.path] = pair.original.path
            }
            try? persistenceService.saveTrashOrigins(trashOrigins)
            if !pairs.isEmpty {
                undoManager.record(.trash(pairs: pairs))
                syncUndoState()
            }
            var tab = activeTab
            tab.selectedURLs.subtract(urls.map(\.standardizedFileURL))
            activeTab = tab
            await refreshAsync()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    public func permanentDeleteSelectedItems() {
        permanentDeleteItems(urls: selectedItems.map(\.url))
    }

    public func permanentDeleteItems(urls: [URL]) {
        guard !urls.isEmpty else { return }
        if snapshotMode {
            let set = Set(urls)
            currentItems.removeAll { set.contains($0.url) }
            var tab = activeTab
            tab.selectedURLs.subtract(set)
            activeTab = tab
            applySortAndGrouping()
            return
        }
        Task { @MainActor [weak self] in
            await self?.performPermanentDeleteItems(urls: urls)
        }
    }

    public func performPermanentDeleteItems(urls: [URL]) async {
        guard !urls.isEmpty else { return }
        do {
            try await operationsEngine.permanentDelete(urls: urls)
            for url in urls {
                trashOrigins.removeValue(forKey: url.standardizedFileURL.path)
            }
            try? persistenceService.saveTrashOrigins(trashOrigins)
            var tab = activeTab
            tab.selectedURLs.subtract(urls.map(\.standardizedFileURL))
            activeTab = tab
            await refreshAsync()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    public func duplicateSelectedItems() {
        duplicateItems(urls: selectedItems.map(\.url))
    }

    public func duplicateItems(urls: [URL]) {
        guard !urls.isEmpty else { return }
        if snapshotMode {
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
            return
        }
        Task { @MainActor [weak self] in
            _ = await self?.performDuplicateItems(urls: urls)
        }
    }

    @discardableResult
    public func performDuplicateItems(urls: [URL]) async -> [URL] {
        guard !urls.isEmpty else { return [] }
        let opID = UUID()
        let task = Task { @MainActor [weak self] () -> [URL] in
            guard let self else { return [] }
            defer {
                self.removeActiveOperation(id: opID)
                self.operationTasks.removeValue(forKey: opID)
            }
            do {
                let created = try await self.operationsEngine.duplicateItems(
                    urls: urls,
                    operationID: opID,
                    onProgress: { [weak self] progress in
                        self?.upsertActiveOperation(progress)
                    }
                )
                if !created.isEmpty {
                    self.undoManager.record(.create(urls: created))
                    self.syncUndoState()
                }
                await self.refreshAsync()
                return created
            } catch is CancellationError {
                return []
            } catch {
                self.lastErrorMessage = error.localizedDescription
                return []
            }
        }
        operationTasks[opID] = Task { _ = await task.value }
        return await task.value
    }

    public func zipSelectedItems() {
        zipItems(urls: selectedItems.map(\.url))
    }

    public func zipItems(urls: [URL]) {
        guard let first = urls.first else { return }
        if snapshotMode {
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
            return
        }
        Task { @MainActor [weak self] in
            _ = await self?.performZipItems(urls: urls)
        }
    }

    @discardableResult
    public func performZipItems(urls: [URL]) async -> URL? {
        guard !urls.isEmpty else { return nil }
        do {
            let zipURL = try await operationsEngine.compressToZIP(urls: urls)
            undoManager.record(.create(urls: [zipURL]))
            syncUndoState()
            await refreshAsync()
            selectItem(url: zipURL)
            return zipURL
        } catch {
            lastErrorMessage = error.localizedDescription
            return nil
        }
    }

    public func extractArchive(at url: URL) {
        if snapshotMode {
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
            return
        }
        Task { @MainActor [weak self] in
            _ = await self?.performExtractArchive(at: url)
        }
    }

    @discardableResult
    public func performExtractArchive(at url: URL) async -> URL? {
        do {
            let extractedURL = try await operationsEngine.extractArchive(at: url)
            undoManager.record(.create(urls: [extractedURL]))
            syncUndoState()
            await refreshAsync()
            selectItem(url: extractedURL)
            return extractedURL
        } catch {
            lastErrorMessage = error.localizedDescription
            return nil
        }
    }

    public func restoreFromTrash(urls: [URL]) {
        if snapshotMode {
            let set = Set(urls)
            currentItems.removeAll { set.contains($0.url) }
            trashItemCount = max(0, trashItemCount - urls.count)
            applySortAndGrouping()
            return
        }
        Task { @MainActor [weak self] in
            await self?.performRestoreFromTrash(urls: urls)
        }
    }

    public func restoreAllFromTrash() {
        let urls = currentItems.map(\.url)
        restoreFromTrash(urls: urls)
    }

    public func performRestoreFromTrash(urls: [URL]) async {
        guard !urls.isEmpty else { return }
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        let pairs: [(trashed: URL, original: URL)] = urls.map { url in
            let std = url.standardizedFileURL
            if let originPath = trashOrigins[std.path] {
                return (std, URL(fileURLWithPath: originPath))
            }
            return (std, desktop.appendingPathComponent(std.lastPathComponent))
        }
        do {
            _ = try await operationsEngine.restoreFromTrash(pairs: pairs)
            for pair in pairs {
                trashOrigins.removeValue(forKey: pair.trashed.path)
            }
            try? persistenceService.saveTrashOrigins(trashOrigins)
            await refreshAsync()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    public func emptyTrash() {
        if snapshotMode {
            if activeTab.location == .recycleBin {
                currentItems.removeAll()
                groupedSections.removeAll()
            }
            trashItemCount = 0
            return
        }
        Task { @MainActor [weak self] in
            await self?.performEmptyTrash()
        }
    }

    public func performEmptyTrash() async {
        let fs = fileSystemService
        do {
            try await Task.detached(priority: .userInitiated) {
                try fs.emptyTrash()
            }.value
            trashOrigins.removeAll()
            try? persistenceService.saveTrashOrigins(trashOrigins)
            await refreshAsync()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    public func moveItems(urls: [URL], to destinationFolder: URL) {
        guard !snapshotMode, !urls.isEmpty else { return }
        Task { @MainActor [weak self] in
            await self?.performMoveItems(urls: urls, to: destinationFolder)
        }
    }

    @discardableResult
    public func performMoveItems(urls: [URL], to destinationFolder: URL) async -> [(from: URL, to: URL)] {
        guard !urls.isEmpty else { return [] }
        let opID = UUID()
        let task = Task { @MainActor [weak self] () -> [(from: URL, to: URL)] in
            guard let self else { return [] }
            defer {
                self.removeActiveOperation(id: opID)
                self.operationTasks.removeValue(forKey: opID)
            }
            do {
                let pairs = try await self.operationsEngine.moveItems(
                    urls: urls,
                    to: destinationFolder,
                    operationID: opID,
                    onProgress: { [weak self] progress in
                        self?.upsertActiveOperation(progress)
                    },
                    onConflict: { [weak self] request in
                        guard let self else { return (.skip, false) }
                        return await self.awaitConflictResolution(for: request)
                    }
                )
                if !pairs.isEmpty {
                    self.undoManager.record(.move(pairs: pairs))
                    self.syncUndoState()
                }
                await self.refreshAsync()
                return pairs
            } catch is CancellationError {
                return []
            } catch {
                self.lastErrorMessage = error.localizedDescription
                return []
            }
        }
        operationTasks[opID] = Task { _ = await task.value }
        return await task.value
    }

    public func copyItems(_ urls: [URL], to destinationFolder: URL) {
        guard !snapshotMode, !urls.isEmpty else { return }
        Task { @MainActor [weak self] in
            _ = await self?.performCopyItems(urls, to: destinationFolder)
        }
    }

    @discardableResult
    public func performCopyItems(_ urls: [URL], to destinationFolder: URL) async -> [URL] {
        guard !urls.isEmpty else { return [] }
        let opID = UUID()
        let task = Task { @MainActor [weak self] () -> [URL] in
            guard let self else { return [] }
            defer {
                self.removeActiveOperation(id: opID)
                self.operationTasks.removeValue(forKey: opID)
            }
            do {
                let created = try await self.operationsEngine.copyItems(
                    urls: urls,
                    to: destinationFolder,
                    operationID: opID,
                    onProgress: { [weak self] progress in
                        self?.upsertActiveOperation(progress)
                    },
                    onConflict: { [weak self] request in
                        guard let self else { return (.skip, false) }
                        return await self.awaitConflictResolution(for: request)
                    }
                )
                if !created.isEmpty {
                    self.undoManager.record(.create(urls: created))
                    self.syncUndoState()
                }
                await self.refreshAsync()
                return created
            } catch is CancellationError {
                return []
            } catch {
                self.lastErrorMessage = error.localizedDescription
                return []
            }
        }
        operationTasks[opID] = Task { _ = await task.value }
        return await task.value
    }

    public func resolveConflict(_ resolution: ConflictResolution, applyToAll: Bool = false) {
        pendingConflict = nil
        if let continuation = conflictContinuation {
            conflictContinuation = nil
            continuation.resume(returning: (resolution, applyToAll))
        }
    }

    public func cancelOperation(id: UUID) {
        activeOperations.removeAll { $0.id == id }
        operationTasks[id]?.cancel()
        operationTasks.removeValue(forKey: id)
        Task {
            await operationsEngine.cancel(operationID: id)
        }
        if pendingConflict != nil {
            resolveConflict(.skip, applyToAll: true)
        }
    }

    // MARK: - Undo / Redo

    public func undo() {
        if snapshotMode {
            canUndo = false
            return
        }
        Task { @MainActor [weak self] in
            await self?.performUndo()
        }
    }

    public func redo() {
        if snapshotMode {
            canRedo = false
            return
        }
        Task { @MainActor [weak self] in
            await self?.performRedo()
        }
    }

    public func performUndo() async {
        guard let action = undoManager.popUndo() else {
            syncUndoState()
            return
        }
        do {
            switch action {
            case .rename(let from, let to):
                let restored = try await operationsEngine.renameItem(at: to, to: from.lastPathComponent)
                updateReferencesAfterRename(from: to, to: restored)
                undoManager.pushRedo(.rename(from: restored, to: to))

            case .move(let pairs):
                var reversedPairs: [(from: URL, to: URL)] = []
                for pair in pairs.reversed() {
                    let moved = try await operationsEngine.moveItems(
                        urls: [pair.to],
                        to: pair.from.deletingLastPathComponent()
                    )
                    if let first = moved.first {
                        reversedPairs.append((from: pair.from, to: first.from))
                    }
                }
                undoManager.pushRedo(.move(pairs: pairs))

            case .create(let urls):
                let trashedPairs = try await operationsEngine.moveToTrash(urls: urls.filter { FileManager.default.fileExists(atPath: $0.path) })
                for pair in trashedPairs {
                    trashOrigins[pair.trashed.path] = pair.original.path
                }
                try? persistenceService.saveTrashOrigins(trashOrigins)
                undoManager.pushRedo(.trash(pairs: trashedPairs))

            case .trash(let pairs):
                let restoredURLs = try await operationsEngine.restoreFromTrash(
                    pairs: pairs.map { ($0.trashed, $0.original) }
                )
                for pair in pairs {
                    trashOrigins.removeValue(forKey: pair.trashed.path)
                }
                try? persistenceService.saveTrashOrigins(trashOrigins)
                undoManager.pushRedo(.create(urls: restoredURLs))
            }
            syncUndoState()
            await refreshAsync()
        } catch {
            // Put back on error
            undoManager.pushUndoWithoutClearingRedo(action)
            syncUndoState()
            lastErrorMessage = error.localizedDescription
        }
    }

    public func performRedo() async {
        guard let action = undoManager.popRedo() else {
            syncUndoState()
            return
        }
        do {
            switch action {
            case .rename(let from, let to):
                let renamed = try await operationsEngine.renameItem(at: from, to: to.lastPathComponent)
                updateReferencesAfterRename(from: from, to: renamed)
                undoManager.pushUndoWithoutClearingRedo(.rename(from: from, to: renamed))

            case .move(let pairs):
                var redone: [(from: URL, to: URL)] = []
                for pair in pairs {
                    let moved = try await operationsEngine.moveItems(
                        urls: [pair.from],
                        to: pair.to.deletingLastPathComponent()
                    )
                    redone.append(contentsOf: moved)
                }
                undoManager.pushUndoWithoutClearingRedo(.move(pairs: redone))

            case .create(let urls):
                // Redoing a trash-undo means moving the restored items back to trash
                let trashed = try await operationsEngine.moveToTrash(urls: urls.filter { FileManager.default.fileExists(atPath: $0.path) })
                for pair in trashed {
                    trashOrigins[pair.trashed.path] = pair.original.path
                }
                try? persistenceService.saveTrashOrigins(trashOrigins)
                undoManager.pushUndoWithoutClearingRedo(.trash(pairs: trashed))

            case .trash(let pairs):
                let restored = try await operationsEngine.restoreFromTrash(
                    pairs: pairs.map { ($0.trashed, $0.original) }
                )
                for pair in pairs {
                    trashOrigins.removeValue(forKey: pair.trashed.path)
                }
                try? persistenceService.saveTrashOrigins(trashOrigins)
                undoManager.pushUndoWithoutClearingRedo(.create(urls: restored))
            }
            syncUndoState()
            await refreshAsync()
        } catch {
            undoManager.pushRedo(action)
            syncUndoState()
            lastErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Search

    public func setSearchQuery(_ query: String) {
        activeSearchText = query
        var tab = activeTab
        tab.searchQuery = query
        activeTab = tab
    }

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
            triggerRefresh()
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
        let std = url.standardizedFileURL
        guard !pinnedFolders.contains(where: { $0.url.standardizedFileURL == std }) else { return }
        pinnedFolders.append(PinnedFolder(url: std, title: title ?? std.lastPathComponent))
        persistPinnedIfNeeded()
    }

    public func unpinFolder(url: URL) {
        let std = url.standardizedFileURL
        pinnedFolders.removeAll { $0.url.standardizedFileURL == std }
        persistPinnedIfNeeded()
    }

    public func movePinnedFolder(from sourceIndex: Int, to destinationIndex: Int) {
        guard pinnedFolders.indices.contains(sourceIndex),
              destinationIndex >= 0,
              destinationIndex <= pinnedFolders.count,
              sourceIndex != destinationIndex else { return }
        let entry = pinnedFolders.remove(at: sourceIndex)
        let adjusted = destinationIndex > sourceIndex ? destinationIndex - 1 : destinationIndex
        pinnedFolders.insert(entry, at: max(0, min(adjusted, pinnedFolders.count)))
        persistPinnedIfNeeded()
    }

    public func isPinned(url: URL) -> Bool {
        let std = url.standardizedFileURL
        return pinnedFolders.contains { $0.url.standardizedFileURL == std }
    }

    public func toggleFavorite(url: URL) {
        if isFavorite(url: url) {
            removeFavorite(url: url)
        } else {
            addFavorite(url: url)
        }
    }

    public func addFavorite(url: URL) {
        let std = url.standardizedFileURL
        guard !isFavorite(url: std) else { return }
        if let item = currentItems.first(where: { $0.url.standardizedFileURL == std }) {
            favoriteFiles.append(item)
        } else if !snapshotMode, let realItem = fileSystemService.makeFileItem(at: std) {
            favoriteFiles.append(realItem)
        } else {
            favoriteFiles.append(
                FileItem(
                    url: std,
                    kind: std.hasDirectoryPath ? .folder : .other,
                    isDirectory: std.hasDirectoryPath
                )
            )
        }
        persistFavoritesIfNeeded()
    }

    public func removeFavorite(url: URL) {
        let std = url.standardizedFileURL
        favoriteFiles.removeAll { $0.url.standardizedFileURL == std }
        persistFavoritesIfNeeded()
    }

    public func isFavorite(url: URL) -> Bool {
        let std = url.standardizedFileURL
        return favoriteFiles.contains { $0.url.standardizedFileURL == std }
    }

    // MARK: - Columns & Settings

    public func resizeColumn(id: String, width: CGFloat) {
        guard let index = settings.columns.firstIndex(where: { $0.id == id }) else { return }
        settings.columns[index].width = max(60, width)
        persistSettingsIfNeeded()
    }

    public func toggleColumnVisibility(id: String) {
        guard let index = settings.columns.firstIndex(where: { $0.id == id }) else { return }
        if settings.columns[index].id == "name" { return }
        settings.columns[index].isVisible.toggle()
        persistSettingsIfNeeded()
    }

    public func updateSettings(_ transform: (inout ExplorerSettings) -> Void) {
        var copy = settings
        transform(&copy)
        settings = copy
        persistSettingsIfNeeded()
    }

    public func resetSettingsToDefaults() {
        settings = .default
        persistSettingsIfNeeded()
    }

    public func setSidebarWidth(_ width: CGFloat) {
        settings.sidebarWidth = min(420, max(180, width))
        persistSettingsIfNeeded()
    }

    public func setRightPaneWidth(_ width: CGFloat) {
        settings.rightPaneWidth = min(480, max(240, width))
        persistSettingsIfNeeded()
    }

    public func setRightPaneMode(_ mode: RightPaneMode) {
        settings.rightPaneMode = settings.rightPaneMode == mode ? .none : mode
        persistSettingsIfNeeded()
    }

    public func toggleNavigationPane() {
        settings.showNavigationPane.toggle()
        persistSettingsIfNeeded()
    }

    public func toggleHiddenFiles() {
        settings.showHiddenFiles.toggle()
        persistSettingsIfNeeded()
        triggerRefresh()
    }

    public func toggleFileExtensions() {
        settings.showFileExtensions.toggle()
        persistSettingsIfNeeded()
    }

    public func toggleCompactView() {
        settings.compactView.toggle()
        persistSettingsIfNeeded()
    }

    public func toggleCheckboxes() {
        settings.showCheckboxes.toggle()
        persistSettingsIfNeeded()
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
        let std = url.standardizedFileURL
        let item = currentItems.first(where: { $0.url.standardizedFileURL == std })
            ?? favoriteFiles.first(where: { $0.url.standardizedFileURL == std })
            ?? (snapshotMode ? nil : fileSystemService.makeFileItem(at: std))

        guard let item else { return nil }

        if snapshotMode {
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

        return await metadataService.loadMetadata(for: item)
    }

    public func setPermissions(_ permissions: POSIXPermissions, for url: URL) async {
        guard !snapshotMode else { return }
        do {
            try metadataService.setPOSIXPermissions(permissions, at: url.standardizedFileURL)
            await refreshAsync()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    public func setFileAttributes(for url: URL, isHidden: Bool, isReadOnly: Bool) async {
        guard !snapshotMode else { return }
        do {
            try metadataService.setFileFlags(at: url.standardizedFileURL, isHidden: isHidden, isReadOnly: isReadOnly)
            await refreshAsync()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
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
                    ], isExpanded: false, hasChildren: true)
                ],
                isExpanded: false,
                hasChildren: true
            )
        ]

        trashItemCount = 3
        applySortAndGrouping()
    }

    // MARK: - Internal Helpers

    private func triggerRefresh() {
        if snapshotMode {
            refreshCurrentListingInMemory()
            return
        }
        listingTask?.cancel()
        listingTask = Task { @MainActor [weak self] in
            await self?.refreshAsync()
        }
    }

    private func refreshCurrentListingInMemory() {
        applySortAndGrouping()
    }

    private func applySortAndGrouping() {
        currentItems = FileSystemService.sortItems(
            currentItems,
            by: activeTab.sortField,
            order: activeTab.sortOrder
        )
        groupedSections = FileSystemService.groupItems(
            currentItems,
            by: activeTab.groupBy
        )
    }

    private func renameInMemory(at url: URL, to newName: String) {
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
        updateReferencesAfterRename(from: url, to: newURL)
        applySortAndGrouping()
    }

    private func updateReferencesAfterRename(from oldURL: URL, to newURL: URL) {
        var tab = activeTab
        if tab.selectedURLs.remove(oldURL) != nil {
            tab.selectedURLs.insert(newURL)
        }
        if tab.anchorURL == oldURL {
            tab.anchorURL = newURL
        }
        activeTab = tab
        if propertiesTargetURL == oldURL {
            propertiesTargetURL = newURL
        }
    }

    private func awaitConflictResolution(for request: ConflictRequest) async -> (ConflictResolution, Bool) {
        pendingConflict = request
        return await withCheckedContinuation { continuation in
            self.conflictContinuation = continuation
        }
    }

    private func upsertActiveOperation(_ progress: FileOperationProgress) {
        if let index = activeOperations.firstIndex(where: { $0.id == progress.id }) {
            activeOperations[index] = progress
        } else {
            activeOperations.append(progress)
        }
    }

    private func removeActiveOperation(id: UUID) {
        activeOperations.removeAll { $0.id == id }
    }

    private func syncUndoState() {
        canUndo = undoManager.canUndo
        canRedo = undoManager.canRedo
        undoDescription = undoManager.undoDescription
        redoDescription = undoManager.redoDescription
    }

    private func recordRecentFile(url: URL) {
        let std = url.standardizedFileURL
        recentFiles.removeAll { $0.url.standardizedFileURL == std }
        let kind = fileSystemService.makeFileItem(at: std)?.kind
            ?? FileSystemService.classifyKind(url: std, isDirectory: false, isPackage: false, isSymlink: false)
        recentFiles.insert(
            RecentFileEntry(url: std, name: std.lastPathComponent, accessedAt: Date(), kind: kind),
            at: 0
        )
        if recentFiles.count > 30 {
            recentFiles.removeLast(recentFiles.count - 30)
        }
        try? persistenceService.saveRecentFiles(recentFiles)
    }

    private func persistSettingsIfNeeded() {
        guard !snapshotMode else { return }
        try? persistenceService.saveSettings(settings)
    }

    private func persistPinnedIfNeeded() {
        guard !snapshotMode else { return }
        try? persistenceService.savePinnedFolders(pinnedFolders)
    }

    private func persistFavoritesIfNeeded() {
        guard !snapshotMode else { return }
        try? persistenceService.saveFavorites(favoriteFiles)
    }

    private func persistSessionIfNeeded() {
        guard !snapshotMode else { return }
        try? persistenceService.saveSession(PersistedTabSession(tabs: tabs, activeTabID: activeTabID))
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

    private func updateSidebarChildren(url: URL, in nodes: inout [SidebarTreeNode], children newChildren: [SidebarTreeNode]) {
        for index in nodes.indices {
            if nodes[index].url == url {
                nodes[index].children = newChildren
                nodes[index].hasChildren = !newChildren.isEmpty
                return
            }
            if var children = nodes[index].children {
                updateSidebarChildren(url: url, in: &children, children: newChildren)
                nodes[index].children = children
            }
        }
    }

    private func findSidebarNode(url: URL, in nodes: [SidebarTreeNode]) -> SidebarTreeNode? {
        for node in nodes {
            if node.url == url { return node }
            if let children = node.children, let found = findSidebarNode(url: url, in: children) {
                return found
            }
        }
        return nil
    }
}
