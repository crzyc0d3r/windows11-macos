import CoreGraphics
import Foundation

// MARK: - File Kind & Permissions

public enum FileKind: String, Sendable, Hashable, Codable, CaseIterable {
    case folder
    case application
    case image
    case video
    case audio
    case pdf
    case document
    case spreadsheet
    case presentation
    case code
    case json
    case markdown
    case text
    case archive
    case diskImage
    case symlink
    case other

    public var displayName: String {
        switch self {
        case .folder: return "Folder"
        case .application: return "Application"
        case .image: return "Image"
        case .video: return "Video"
        case .audio: return "Audio"
        case .pdf: return "PDF Document"
        case .document: return "Document"
        case .spreadsheet: return "Spreadsheet"
        case .presentation: return "Presentation"
        case .code: return "Source Code"
        case .json: return "JSON"
        case .markdown: return "Markdown"
        case .text: return "Text Document"
        case .archive: return "Archive"
        case .diskImage: return "Disk Image"
        case .symlink: return "Symbolic Link"
        case .other: return "File"
        }
    }
}

public struct POSIXPermissions: Sendable, Hashable, Codable {
    public let mode: UInt16
    public let ownerRead: Bool
    public let ownerWrite: Bool
    public let ownerExecute: Bool
    public let groupRead: Bool
    public let groupWrite: Bool
    public let groupExecute: Bool
    public let othersRead: Bool
    public let othersWrite: Bool
    public let othersExecute: Bool

    public var octalString: String {
        String(format: "%03o", mode & 0o777)
    }

    public var symbolicString: String {
        let chars: [Character] = [
            ownerRead ? "r" : "-",
            ownerWrite ? "w" : "-",
            ownerExecute ? "x" : "-",
            groupRead ? "r" : "-",
            groupWrite ? "w" : "-",
            groupExecute ? "x" : "-",
            othersRead ? "r" : "-",
            othersWrite ? "w" : "-",
            othersExecute ? "x" : "-"
        ]
        return String(chars)
    }

    public init(mode: UInt16) {
        self.mode = mode & 0o7777
        self.ownerRead = (mode & 0o400) != 0
        self.ownerWrite = (mode & 0o200) != 0
        self.ownerExecute = (mode & 0o100) != 0
        self.groupRead = (mode & 0o040) != 0
        self.groupWrite = (mode & 0o020) != 0
        self.groupExecute = (mode & 0o010) != 0
        self.othersRead = (mode & 0o004) != 0
        self.othersWrite = (mode & 0o002) != 0
        self.othersExecute = (mode & 0o001) != 0
    }

    public init(
        ownerRead: Bool,
        ownerWrite: Bool,
        ownerExecute: Bool,
        groupRead: Bool,
        groupWrite: Bool,
        groupExecute: Bool,
        othersRead: Bool,
        othersWrite: Bool,
        othersExecute: Bool
    ) {
        var computed: UInt16 = 0
        if ownerRead { computed |= 0o400 }
        if ownerWrite { computed |= 0o200 }
        if ownerExecute { computed |= 0o100 }
        if groupRead { computed |= 0o040 }
        if groupWrite { computed |= 0o020 }
        if groupExecute { computed |= 0o010 }
        if othersRead { computed |= 0o004 }
        if othersWrite { computed |= 0o002 }
        if othersExecute { computed |= 0o001 }
        self.mode = computed
        self.ownerRead = ownerRead
        self.ownerWrite = ownerWrite
        self.ownerExecute = ownerExecute
        self.groupRead = groupRead
        self.groupWrite = groupWrite
        self.groupExecute = groupExecute
        self.othersRead = othersRead
        self.othersWrite = othersWrite
        self.othersExecute = othersExecute
    }
}

// MARK: - File Item

public struct FileItem: Identifiable, Sendable, Hashable, Codable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let displayName: String
    public let fileExtension: String
    public let kind: FileKind
    public let isDirectory: Bool
    public let isHidden: Bool
    public let isSymlink: Bool
    public let isPackage: Bool
    public let isReadOnly: Bool
    public let size: Int64
    public let dateModified: Date
    public let dateCreated: Date
    public let childCount: Int?
    public let typeDescription: String
    public let posixPermissions: POSIXPermissions?
    public let thumbnailKey: String

    /// Convenience alias matching the domain specification.
    public var `extension`: String { fileExtension }

    public init(
        url: URL,
        name: String? = nil,
        displayName: String? = nil,
        fileExtension: String? = nil,
        kind: FileKind,
        isDirectory: Bool,
        isHidden: Bool = false,
        isSymlink: Bool = false,
        isPackage: Bool = false,
        isReadOnly: Bool = false,
        size: Int64 = 0,
        dateModified: Date = Date(),
        dateCreated: Date = Date(),
        childCount: Int? = nil,
        typeDescription: String? = nil,
        posixPermissions: POSIXPermissions? = nil,
        thumbnailKey: String? = nil
    ) {
        let resolvedName = name ?? url.lastPathComponent
        let resolvedExt = fileExtension ?? url.pathExtension.lowercased()
        let resolvedDisplayName = displayName ?? resolvedName
        self.url = url
        self.name = resolvedName
        self.displayName = resolvedDisplayName
        self.fileExtension = resolvedExt
        self.kind = kind
        self.isDirectory = isDirectory
        self.isHidden = isHidden
        self.isSymlink = isSymlink
        self.isPackage = isPackage
        self.isReadOnly = isReadOnly
        self.size = size
        self.dateModified = dateModified
        self.dateCreated = dateCreated
        self.childCount = childCount
        self.typeDescription = typeDescription ?? kind.displayName
        self.posixPermissions = posixPermissions
        self.thumbnailKey = thumbnailKey ?? "\(url.path):\(Int64(dateModified.timeIntervalSince1970)):\(size)"
    }
}

// MARK: - Search Filters

public enum DateRangeFilter: String, Sendable, Hashable, Codable, CaseIterable {
    case any
    case today
    case pastWeek
    case pastMonth
    case pastYear

    public var displayTitle: String {
        switch self {
        case .any: return "Any time"
        case .today: return "Today"
        case .pastWeek: return "Past week"
        case .pastMonth: return "Past month"
        case .pastYear: return "Past year"
        }
    }
}

public enum SizeRangeFilter: String, Sendable, Hashable, Codable, CaseIterable {
    case any
    case empty
    case tiny
    case small
    case medium
    case large
    case huge

    public var displayTitle: String {
        switch self {
        case .any: return "Any size"
        case .empty: return "Empty (0 B)"
        case .tiny: return "Tiny (< 100 KB)"
        case .small: return "Small (100 KB - 1 MB)"
        case .medium: return "Medium (1 MB - 100 MB)"
        case .large: return "Large (100 MB - 1 GB)"
        case .huge: return "Huge (> 1 GB)"
        }
    }
}

public struct SearchFilters: Sendable, Hashable, Codable {
    public var kind: FileKind?
    public var dateRange: DateRangeFilter
    public var sizeRange: SizeRangeFilter
    public var includeSubfolders: Bool
    public var caseSensitive: Bool

    public static let `default` = SearchFilters()

    public var isActive: Bool {
        kind != nil || dateRange != .any || sizeRange != .any || !includeSubfolders || caseSensitive
    }

    public init(
        kind: FileKind? = nil,
        dateRange: DateRangeFilter = .any,
        sizeRange: SizeRangeFilter = .any,
        includeSubfolders: Bool = true,
        caseSensitive: Bool = false
    ) {
        self.kind = kind
        self.dateRange = dateRange
        self.sizeRange = sizeRange
        self.includeSubfolders = includeSubfolders
        self.caseSensitive = caseSensitive
    }
}

// MARK: - Locations & Navigation

public enum LocationIconKind: String, Sendable, Hashable, Codable {
    case home
    case gallery
    case thisPC
    case recycleBin
    case network
    case folder
    case desktop
    case downloads
    case documents
    case pictures
    case music
    case videos
    case applications
    case search
    case cloudDrive
    case hardDrive
    case externalDrive
    case networkDrive
}

public enum ExplorerLocation: Sendable, Hashable, Codable {
    case home
    case gallery
    case thisPC
    case recycleBin
    case network
    case folder(URL)
    case search(query: String, scope: URL, filters: SearchFilters)

    public var displayTitle: String {
        switch self {
        case .home:
            return "Home"
        case .gallery:
            return "Gallery"
        case .thisPC:
            return "This Mac"
        case .recycleBin:
            return "Trash"
        case .network:
            return "Network"
        case .folder(let url):
            let standardized = url.standardizedFileURL
            if standardized.path == "/" {
                return "Macintosh HD"
            }
            let name = standardized.lastPathComponent
            return name.isEmpty ? standardized.path : name
        case .search(let query, _, _):
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Search" : "Search: \(trimmed)"
        }
    }

    public var urlIfFolder: URL? {
        switch self {
        case .folder(let url):
            return url
        case .search(_, let scope, _):
            return scope
        default:
            return nil
        }
    }

    public var pathString: String {
        switch self {
        case .home:
            return "Home"
        case .gallery:
            return "Gallery"
        case .thisPC:
            return "This Mac"
        case .recycleBin:
            return "Trash"
        case .network:
            return "Network"
        case .folder(let url):
            return url.standardizedFileURL.path
        case .search(let query, let scope, _):
            return "search://\(scope.path)?q=\(query)"
        }
    }

    public var iconKind: LocationIconKind {
        switch self {
        case .home:
            return .home
        case .gallery:
            return .gallery
        case .thisPC:
            return .thisPC
        case .recycleBin:
            return .recycleBin
        case .network:
            return .network
        case .search:
            return .search
        case .folder(let url):
            let std = url.standardizedFileURL
            let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
            if std == home { return .home }
            if std == home.appendingPathComponent("Desktop") { return .desktop }
            if std == home.appendingPathComponent("Downloads") { return .downloads }
            if std == home.appendingPathComponent("Documents") { return .documents }
            if std == home.appendingPathComponent("Pictures") { return .pictures }
            if std == home.appendingPathComponent("Music") { return .music }
            if std == home.appendingPathComponent("Movies") { return .videos }
            if std.path == "/Applications" || std == home.appendingPathComponent("Applications") {
                return .applications
            }
            if std.path == "/" { return .hardDrive }
            return .folder
        }
    }
}

// MARK: - View, Sort, Group & Columns

public enum ViewMode: String, Sendable, Hashable, Codable, CaseIterable {
    case extraLargeIcons
    case largeIcons
    case mediumIcons
    case smallIcons
    case list
    case details
    case tiles
    case content

    public var displayTitle: String {
        switch self {
        case .extraLargeIcons: return "Extra large icons"
        case .largeIcons: return "Large icons"
        case .mediumIcons: return "Medium icons"
        case .smallIcons: return "Small icons"
        case .list: return "List"
        case .details: return "Details"
        case .tiles: return "Tiles"
        case .content: return "Content"
        }
    }

    public var iconSystemName: String {
        switch self {
        case .extraLargeIcons, .largeIcons, .mediumIcons:
            return "square.grid.2x2"
        case .smallIcons:
            return "square.grid.3x3"
        case .list:
            return "list.bullet"
        case .details:
            return "tablecells"
        case .tiles:
            return "rectangle.grid.2x2"
        case .content:
            return "list.bullet.rectangle"
        }
    }
}

public enum SortField: String, Sendable, Hashable, Codable, CaseIterable {
    case name
    case dateModified
    case type
    case size
    case dateCreated

    public var displayTitle: String {
        switch self {
        case .name: return "Name"
        case .dateModified: return "Date modified"
        case .type: return "Type"
        case .size: return "Size"
        case .dateCreated: return "Date created"
        }
    }
}

public enum SortOrder: String, Sendable, Hashable, Codable, CaseIterable {
    case ascending
    case descending

    public var toggled: SortOrder {
        self == .ascending ? .descending : .ascending
    }
}

public enum GroupByField: String, Sendable, Hashable, Codable, CaseIterable {
    case none
    case name
    case dateModified
    case type
    case size

    public var displayTitle: String {
        switch self {
        case .none: return "(None)"
        case .name: return "Name"
        case .dateModified: return "Date modified"
        case .type: return "Type"
        case .size: return "Size"
        }
    }
}

public struct ExplorerColumn: Identifiable, Sendable, Hashable, Codable {
    public let id: String
    public var title: String
    public var field: SortField
    public var width: CGFloat
    public var isVisible: Bool

    public init(
        id: String,
        title: String,
        field: SortField,
        width: CGFloat,
        isVisible: Bool = true
    ) {
        self.id = id
        self.title = title
        self.field = field
        self.width = width
        self.isVisible = isVisible
    }

    public static let defaultColumns: [ExplorerColumn] = [
        ExplorerColumn(id: "name", title: "Name", field: .name, width: 280, isVisible: true),
        ExplorerColumn(id: "dateModified", title: "Date modified", field: .dateModified, width: 165, isVisible: true),
        ExplorerColumn(id: "type", title: "Type", field: .type, width: 145, isVisible: true),
        ExplorerColumn(id: "size", title: "Size", field: .size, width: 95, isVisible: true),
        ExplorerColumn(id: "dateCreated", title: "Date created", field: .dateCreated, width: 165, isVisible: false)
    ]
}

public struct ExplorerSection: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let items: [FileItem]

    public init(id: String, title: String, items: [FileItem]) {
        self.id = id
        self.title = title
        self.items = items
    }
}

public struct SidebarTreeNode: Identifiable, Sendable, Hashable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let iconKind: LocationIconKind
    public var children: [SidebarTreeNode]?
    public var isExpanded: Bool
    public var hasChildren: Bool

    public init(
        url: URL,
        name: String,
        iconKind: LocationIconKind = .folder,
        children: [SidebarTreeNode]? = nil,
        isExpanded: Bool = false,
        hasChildren: Bool = true
    ) {
        self.url = url
        self.name = name
        self.iconKind = iconKind
        self.children = children
        self.isExpanded = isExpanded
        self.hasChildren = hasChildren
    }
}

// MARK: - Tabs

public struct ExplorerTab: Identifiable, Sendable, Hashable, Codable {
    public let id: UUID
    public var location: ExplorerLocation
    public var title: String
    public var backStack: [ExplorerLocation]
    public var forwardStack: [ExplorerLocation]
    public var viewMode: ViewMode
    public var sortField: SortField
    public var sortOrder: SortOrder
    public var groupBy: GroupByField
    public var selectedURLs: Set<URL>
    public var anchorURL: URL?
    public var searchQuery: String
    public var searchFilters: SearchFilters
    public var scrollOffset: CGFloat

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }
    public var canGoUp: Bool {
        switch location {
        case .folder(let url):
            return url.standardizedFileURL.path != "/"
        case .search(_, let scope, _):
            return scope.standardizedFileURL.path != "/"
        case .home:
            return false
        case .gallery, .thisPC, .recycleBin, .network:
            return true
        }
    }

    public init(
        id: UUID = UUID(),
        location: ExplorerLocation = .home,
        title: String? = nil,
        backStack: [ExplorerLocation] = [],
        forwardStack: [ExplorerLocation] = [],
        viewMode: ViewMode = .details,
        sortField: SortField = .name,
        sortOrder: SortOrder = .ascending,
        groupBy: GroupByField = .none,
        selectedURLs: Set<URL> = [],
        anchorURL: URL? = nil,
        searchQuery: String = "",
        searchFilters: SearchFilters = .default,
        scrollOffset: CGFloat = 0
    ) {
        self.id = id
        self.location = location
        self.title = title ?? location.displayTitle
        self.backStack = backStack
        self.forwardStack = forwardStack
        self.viewMode = viewMode
        self.sortField = sortField
        self.sortOrder = sortOrder
        self.groupBy = groupBy
        self.selectedURLs = selectedURLs
        self.anchorURL = anchorURL
        self.searchQuery = searchQuery
        self.searchFilters = searchFilters
        self.scrollOffset = scrollOffset
    }
}

// MARK: - Volumes, Pinned Folders, Recents

public enum VolumeKind: String, Sendable, Hashable, Codable, CaseIterable {
    case internalDrive
    case externalDrive
    case networkDrive
    case cloudDrive
}

public struct VolumeInfo: Identifiable, Sendable, Hashable, Codable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let volumeKind: VolumeKind
    public let totalBytes: Int64
    public let freeBytes: Int64
    public let usedFraction: Double
    public let fileSystemFormat: String

    public var usedBytes: Int64 {
        max(0, totalBytes - freeBytes)
    }

    public init(
        url: URL,
        name: String,
        volumeKind: VolumeKind,
        totalBytes: Int64,
        freeBytes: Int64,
        usedFraction: Double? = nil,
        fileSystemFormat: String = "APFS"
    ) {
        self.url = url
        self.name = name
        self.volumeKind = volumeKind
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        if let usedFraction {
            self.usedFraction = min(1, max(0, usedFraction))
        } else if totalBytes > 0 {
            self.usedFraction = min(1, max(0, Double(totalBytes - freeBytes) / Double(totalBytes)))
        } else {
            self.usedFraction = 0
        }
        self.fileSystemFormat = fileSystemFormat
    }
}

public struct PinnedFolder: Identifiable, Sendable, Hashable, Codable {
    public let id: UUID
    public let url: URL
    public var title: String
    public var iconName: String?

    public init(
        id: UUID = UUID(),
        url: URL,
        title: String? = nil,
        iconName: String? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title ?? url.lastPathComponent
        self.iconName = iconName
    }
}

public struct RecentFileEntry: Identifiable, Sendable, Hashable, Codable {
    public let id: UUID
    public let url: URL
    public let name: String
    public let accessedAt: Date
    public let kind: FileKind

    public init(
        id: UUID = UUID(),
        url: URL,
        name: String? = nil,
        accessedAt: Date = Date(),
        kind: FileKind = .other
    ) {
        self.id = id
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.accessedAt = accessedAt
        self.kind = kind
    }
}

// MARK: - Metadata & Open With

public struct AppChoice: Identifiable, Sendable, Hashable, Codable {
    public var id: URL { url }
    public let url: URL
    public let name: String

    public init(url: URL, name: String) {
        self.url = url
        self.name = name
    }
}

public struct FileMetadata: Sendable, Hashable {
    public let item: FileItem
    public let dimensions: String?
    public let exifSummary: [(String, String)]
    public let mediaDuration: String?
    public let mediaCodec: String?
    public let pdfPageCount: Int?
    public let lineCount: Int?
    public let folderSizeBytes: Int64?
    public let folderFileCount: Int?
    public let folderSubfolderCount: Int?
    public let defaultAppName: String?
    public let defaultAppURL: URL?
    public let openWithApps: [AppChoice]

    public init(
        item: FileItem,
        dimensions: String? = nil,
        exifSummary: [(String, String)] = [],
        mediaDuration: String? = nil,
        mediaCodec: String? = nil,
        pdfPageCount: Int? = nil,
        lineCount: Int? = nil,
        folderSizeBytes: Int64? = nil,
        folderFileCount: Int? = nil,
        folderSubfolderCount: Int? = nil,
        defaultAppName: String? = nil,
        defaultAppURL: URL? = nil,
        openWithApps: [AppChoice] = []
    ) {
        self.item = item
        self.dimensions = dimensions
        self.exifSummary = exifSummary
        self.mediaDuration = mediaDuration
        self.mediaCodec = mediaCodec
        self.pdfPageCount = pdfPageCount
        self.lineCount = lineCount
        self.folderSizeBytes = folderSizeBytes
        self.folderFileCount = folderFileCount
        self.folderSubfolderCount = folderSubfolderCount
        self.defaultAppName = defaultAppName
        self.defaultAppURL = defaultAppURL
        self.openWithApps = openWithApps
    }

    public static func == (lhs: FileMetadata, rhs: FileMetadata) -> Bool {
        lhs.item == rhs.item
            && lhs.dimensions == rhs.dimensions
            && lhs.exifSummary.elementsEqual(rhs.exifSummary) { $0.0 == $1.0 && $0.1 == $1.1 }
            && lhs.mediaDuration == rhs.mediaDuration
            && lhs.mediaCodec == rhs.mediaCodec
            && lhs.pdfPageCount == rhs.pdfPageCount
            && lhs.lineCount == rhs.lineCount
            && lhs.folderSizeBytes == rhs.folderSizeBytes
            && lhs.folderFileCount == rhs.folderFileCount
            && lhs.folderSubfolderCount == rhs.folderSubfolderCount
            && lhs.defaultAppName == rhs.defaultAppName
            && lhs.defaultAppURL == rhs.defaultAppURL
            && lhs.openWithApps == rhs.openWithApps
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(item)
        hasher.combine(dimensions)
        hasher.combine(exifSummary.count)
        for pair in exifSummary {
            hasher.combine(pair.0)
            hasher.combine(pair.1)
        }
        hasher.combine(mediaDuration)
        hasher.combine(mediaCodec)
        hasher.combine(pdfPageCount)
        hasher.combine(lineCount)
        hasher.combine(folderSizeBytes)
        hasher.combine(folderFileCount)
        hasher.combine(folderSubfolderCount)
        hasher.combine(defaultAppName)
        hasher.combine(defaultAppURL)
        hasher.combine(openWithApps)
    }
}

// MARK: - Clipboard & Operations

public enum ClipboardOperation: String, Sendable, Hashable, Codable {
    case copy
    case cut
}

public struct ClipboardPayload: Sendable, Hashable, Codable {
    public let operation: ClipboardOperation
    public let urls: [URL]

    public init(operation: ClipboardOperation, urls: [URL]) {
        self.operation = operation
        self.urls = urls
    }
}

public struct FileOperationProgress: Identifiable, Sendable, Hashable {
    public let id: UUID
    public var title: String
    public var currentItem: String
    public var completedBytes: Int64
    public var totalBytes: Int64
    public var completedItems: Int
    public var totalItems: Int
    public var isCancellable: Bool

    public var fractionCompleted: Double {
        if totalBytes > 0 {
            return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
        }
        if totalItems > 0 {
            return min(1, max(0, Double(completedItems) / Double(totalItems)))
        }
        return 0
    }

    public init(
        id: UUID = UUID(),
        title: String,
        currentItem: String,
        completedBytes: Int64 = 0,
        totalBytes: Int64 = 0,
        completedItems: Int = 0,
        totalItems: Int = 0,
        isCancellable: Bool = true
    ) {
        self.id = id
        self.title = title
        self.currentItem = currentItem
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.completedItems = completedItems
        self.totalItems = totalItems
        self.isCancellable = isCancellable
    }
}

public enum ConflictResolution: String, Sendable, Hashable, Codable {
    case replace
    case skip
    case keepBoth
}

public struct ConflictRequest: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let sourceURL: URL
    public let destinationURL: URL
    public let isDirectory: Bool

    public init(
        id: UUID = UUID(),
        sourceURL: URL,
        destinationURL: URL,
        isDirectory: Bool
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.isDirectory = isDirectory
    }
}

public enum ContextMenuTarget: Sendable, Hashable {
    case item(FileItem)
    case selection([FileItem])
    case background(ExplorerLocation)
    case sidebarItem(URL)
    case tab(UUID)
}

// MARK: - Settings

public enum AppTheme: String, Sendable, Hashable, Codable, CaseIterable {
    case system
    case light
    case dark

    public var displayTitle: String {
        switch self {
        case .system: return "Use system setting"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

public enum AccentColorChoice: String, Sendable, Hashable, Codable, CaseIterable {
    case windowsBlue
    case teal
    case purple
    case amber
    case rose

    public var displayTitle: String {
        switch self {
        case .windowsBlue: return "Windows Blue"
        case .teal: return "Teal"
        case .purple: return "Purple"
        case .amber: return "Amber"
        case .rose: return "Rose"
        }
    }
}

public enum LaunchTarget: String, Sendable, Hashable, Codable, CaseIterable {
    case home
    case thisPC
    case lastSession

    public var displayTitle: String {
        switch self {
        case .home: return "Home"
        case .thisPC: return "This Mac"
        case .lastSession: return "Restore previous tabs"
        }
    }
}

public enum RightPaneMode: String, Sendable, Hashable, Codable, CaseIterable {
    case none
    case details
    case preview

    public var displayTitle: String {
        switch self {
        case .none: return "Off"
        case .details: return "Details"
        case .preview: return "Preview"
        }
    }
}

public struct ExplorerSettings: Sendable, Hashable, Codable {
    public var theme: AppTheme
    public var accentColor: AccentColorChoice
    public var launchTarget: LaunchTarget
    public var showHiddenFiles: Bool
    public var showFileExtensions: Bool
    public var showCheckboxes: Bool
    public var compactView: Bool
    public var singleClickToOpen: Bool
    public var showNavigationPane: Bool
    public var rightPaneMode: RightPaneMode
    public var sidebarWidth: CGFloat
    public var rightPaneWidth: CGFloat
    public var columns: [ExplorerColumn]

    public static let `default` = ExplorerSettings()

    public init(
        theme: AppTheme = .system,
        accentColor: AccentColorChoice = .windowsBlue,
        launchTarget: LaunchTarget = .home,
        showHiddenFiles: Bool = false,
        showFileExtensions: Bool = true,
        showCheckboxes: Bool = false,
        compactView: Bool = false,
        singleClickToOpen: Bool = false,
        showNavigationPane: Bool = true,
        rightPaneMode: RightPaneMode = .none,
        sidebarWidth: CGFloat = 240,
        rightPaneWidth: CGFloat = 300,
        columns: [ExplorerColumn] = ExplorerColumn.defaultColumns
    ) {
        self.theme = theme
        self.accentColor = accentColor
        self.launchTarget = launchTarget
        self.showHiddenFiles = showHiddenFiles
        self.showFileExtensions = showFileExtensions
        self.showCheckboxes = showCheckboxes
        self.compactView = compactView
        self.singleClickToOpen = singleClickToOpen
        self.showNavigationPane = showNavigationPane
        self.rightPaneMode = rightPaneMode
        self.sidebarWidth = sidebarWidth
        self.rightPaneWidth = rightPaneWidth
        self.columns = columns
    }
}
