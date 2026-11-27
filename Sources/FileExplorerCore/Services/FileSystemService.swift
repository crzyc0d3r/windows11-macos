import Foundation
import UniformTypeIdentifiers

public enum FileSystemError: Error, LocalizedError, Sendable {
    case permissionDenied(URL)
    case itemNotFound(URL)
    case notADirectory(URL)
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let url):
            return "Permission denied accessing \(url.lastPathComponent)."
        case .itemNotFound(let url):
            return "Item not found: \(url.path)."
        case .notADirectory(let url):
            return "\(url.lastPathComponent) is not a folder."
        case .operationFailed(let message):
            return message
        }
    }
}

public struct FileSystemService: Sendable {
    public init() {}

    public static let resourceKeys: [URLResourceKey] = [
        .nameKey,
        .localizedNameKey,
        .fileSizeKey,
        .totalFileSizeKey,
        .contentModificationDateKey,
        .creationDateKey,
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .isPackageKey,
        .isHiddenKey,
        .isWritableKey,
        .isUserImmutableKey,
        .localizedTypeDescriptionKey,
        .contentTypeKey
    ]

    // MARK: - Directory Enumeration

    public func listDirectory(at url: URL, includeHidden: Bool) throws -> [FileItem] {
        let standardized = url.standardizedFileURL
        let fm = FileManager.default

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: standardized.path, isDirectory: &isDir) else {
            throw FileSystemError.itemNotFound(standardized)
        }
        guard isDir.boolValue else {
            throw FileSystemError.notADirectory(standardized)
        }

        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(
                at: standardized,
                includingPropertiesForKeys: Self.resourceKeys,
                options: options
            )
        } catch let error as NSError {
            if Self.isPermissionError(error) {
                throw FileSystemError.permissionDenied(standardized)
            }
            throw error
        }

        var items: [FileItem] = []
        items.reserveCapacity(urls.count)
        for childURL in urls {
            if !includeHidden && childURL.lastPathComponent.hasPrefix(".") {
                continue
            }
            if let item = makeFileItem(at: childURL) {
                if !includeHidden && item.isHidden {
                    continue
                }
                items.append(item)
            }
        }
        return items
    }

    public func makeFileItem(at url: URL) -> FileItem? {
        let standardized = url.standardizedFileURL
        let keysSet = Set(Self.resourceKeys)
        let values = try? standardized.resourceValues(forKeys: keysSet)

        let name = values?.name ?? standardized.lastPathComponent
        let displayName = values?.localizedName ?? name
        let isSymlink = values?.isSymbolicLink ?? false
        let isPackage = values?.isPackage ?? false
        let isDirectoryRaw = values?.isDirectory ?? false
        let isDirectory = isDirectoryRaw && !isSymlink
        let isHidden = (values?.isHidden ?? false) || name.hasPrefix(".")
        let isWritable = values?.isWritable ?? true
        let isImmutable = values?.isUserImmutable ?? false
        let isReadOnly = isImmutable || !isWritable

        let size: Int64
        if isDirectory && !isPackage {
            size = 0
        } else {
            size = Int64(values?.fileSize ?? values?.totalFileSize ?? 0)
        }

        let dateModified = values?.contentModificationDate ?? Date()
        let dateCreated = values?.creationDate ?? dateModified
        let ext = (isDirectory && !isPackage) ? "" : standardized.pathExtension.lowercased()
        let contentType = values?.contentType
        let kind = Self.classifyKind(
            url: standardized,
            fileExtension: ext,
            isDirectory: isDirectory,
            isPackage: isPackage,
            isSymlink: isSymlink,
            contentType: contentType
        )

        let typeDesc: String
        if let localized = values?.localizedTypeDescription, !localized.isEmpty {
            typeDesc = localized
        } else if isDirectory && !isPackage {
            typeDesc = "File folder"
        } else {
            typeDesc = kind.displayName
        }

        let posix = Self.readPOSIXPermissions(at: standardized)

        return FileItem(
            url: standardized,
            name: name,
            displayName: displayName,
            fileExtension: ext,
            kind: kind,
            isDirectory: isDirectory,
            isHidden: isHidden,
            isSymlink: isSymlink,
            isPackage: isPackage,
            isReadOnly: isReadOnly,
            size: size,
            dateModified: dateModified,
            dateCreated: dateCreated,
            childCount: nil,
            typeDescription: typeDesc,
            posixPermissions: posix
        )
    }

    public func loadChildFolders(of url: URL, includeHidden: Bool = false) -> [SidebarTreeNode] {
        guard let items = try? listDirectory(at: url, includeHidden: includeHidden) else {
            return []
        }
        return items
            .filter { $0.isDirectory && !$0.isPackage }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { item in
                SidebarTreeNode(
                    url: item.url,
                    name: item.displayName,
                    iconKind: ExplorerLocation.folder(item.url).iconKind,
                    children: nil,
                    isExpanded: false,
                    hasChildren: hasSubfolders(at: item.url, includeHidden: includeHidden)
                )
            }
    }

    private func hasSubfolders(at url: URL, includeHidden: Bool) -> Bool {
        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [.skipsSubdirectoryDescendants] : [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: options
        ) else {
            return false
        }
        for case let child as URL in enumerator {
            if let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
               values.isDirectory == true,
               values.isPackage != true {
                return true
            }
        }
        return false
    }

    // MARK: - Trash Operations

    public var trashDirectoryURL: URL {
        FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
    }

    public func listTrash(trashDirectory: URL? = nil) throws -> [FileItem] {
        let dir = trashDirectory ?? trashDirectoryURL
        guard FileManager.default.fileExists(atPath: dir.path) else {
            return []
        }
        return try listDirectory(at: dir, includeHidden: true)
            .filter { $0.name != ".DS_Store" }
    }

    public func trashCount(trashDirectory: URL? = nil) -> Int {
        (try? listTrash(trashDirectory: trashDirectory).count) ?? 0
    }

    public func emptyTrash(trashDirectory: URL? = nil) throws {
        let dir = trashDirectory ?? trashDirectoryURL
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return }
        let contents = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [])
        for itemURL in contents where itemURL.lastPathComponent != ".DS_Store" {
            // Clear immutable flag if present before deleting
            var values = URLResourceValues()
            values.isUserImmutable = false
            var mutableURL = itemURL
            try? mutableURL.setResourceValues(values)
            try fm.removeItem(at: itemURL)
        }
    }

    // MARK: - Gallery Discovery

    public func listGalleryItems(limit: Int = 300) -> [FileItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [
            home.appendingPathComponent("Pictures", isDirectory: true),
            home.appendingPathComponent("Desktop", isDirectory: true),
            home.appendingPathComponent("Downloads", isDirectory: true)
        ]
        var collected: [FileItem] = []
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Self.resourceKeys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else {
                continue
            }
            for case let fileURL as URL in enumerator {
                guard let item = makeFileItem(at: fileURL) else { continue }
                if item.kind == .image || item.kind == .video {
                    collected.append(item)
                    if collected.count >= limit {
                        return collected.sorted { $0.dateModified > $1.dateModified }
                    }
                }
            }
        }
        return collected.sorted { $0.dateModified > $1.dateModified }
    }

    // MARK: - Volumes & Cloud Drives

    public func discoverVolumes() -> (volumes: [VolumeInfo], cloudDrives: [VolumeInfo]) {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeIsRemovableKey,
            .volumeIsInternalKey,
            .volumeIsLocalKey,
            .volumeLocalizedFormatDescriptionKey,
            .volumeIsBrowsableKey
        ]

        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        var discoveredVolumes: [VolumeInfo] = []
        var seenPaths = Set<String>()

        for url in urls {
            let std = url.standardizedFileURL
            if std.path.hasPrefix("/System/Volumes/") && std.path != "/System/Volumes/Data" {
                continue
            }
            if std.path == "/System/Volumes/Data" {
                continue
            }
            guard seenPaths.insert(std.path).inserted else { continue }

            let values = try? std.resourceValues(forKeys: Set(keys))
            if values?.volumeIsBrowsable == false && std.path != "/" {
                continue
            }

            let name = values?.volumeName ?? (std.path == "/" ? "Macintosh HD" : std.lastPathComponent)
            let totalBytes = Int64(values?.volumeTotalCapacity ?? 0)
            let importantFree = values?.volumeAvailableCapacityForImportantUsage ?? 0
            let fallbackFree = Int64(values?.volumeAvailableCapacity ?? 0)
            let freeBytes = importantFree > 0 ? importantFree : fallbackFree

            let isLocal = values?.volumeIsLocal ?? true
            let isInternal = values?.volumeIsInternal ?? (std.path == "/")
            let isRemovable = values?.volumeIsRemovable ?? false

            let kind: VolumeKind
            if !isLocal {
                kind = .networkDrive
            } else if isRemovable || !isInternal {
                kind = .externalDrive
            } else {
                kind = .internalDrive
            }

            let format = values?.volumeLocalizedFormatDescription ?? "APFS"
            discoveredVolumes.append(
                VolumeInfo(
                    url: std,
                    name: name,
                    volumeKind: kind,
                    totalBytes: totalBytes,
                    freeBytes: freeBytes,
                    fileSystemFormat: format
                )
            )
        }

        if discoveredVolumes.isEmpty {
            discoveredVolumes.append(
                VolumeInfo(
                    url: URL(fileURLWithPath: "/"),
                    name: "Macintosh HD",
                    volumeKind: .internalDrive,
                    totalBytes: 0,
                    freeBytes: 0,
                    fileSystemFormat: "APFS"
                )
            )
        }

        let cloudDrives = discoverCloudDrives()
        return (discoveredVolumes, cloudDrives)
    }

    public func discoverCloudDrives(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [VolumeInfo] {
        let fm = FileManager.default
        var results: [VolumeInfo] = []
        var seen = Set<String>()

        func addCloudDrive(at url: URL, displayName: String) {
            let std = url.standardizedFileURL
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: std.path, isDirectory: &isDir), isDir.boolValue else {
                return
            }
            guard seen.insert(std.path).inserted else { return }

            let capValues = try? std.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
            let total = Int64(capValues?.volumeTotalCapacity ?? 0)
            let free = (capValues?.volumeAvailableCapacityForImportantUsage ?? 0) > 0
                ? (capValues?.volumeAvailableCapacityForImportantUsage ?? 0)
                : Int64(capValues?.volumeAvailableCapacity ?? 0)

            results.append(
                VolumeInfo(
                    url: std,
                    name: displayName,
                    volumeKind: .cloudDrive,
                    totalBytes: total,
                    freeBytes: free,
                    fileSystemFormat: "Cloud"
                )
            )
        }

        let iCloudURL = homeDirectory.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        addCloudDrive(at: iCloudURL, displayName: "iCloud Drive")

        let cloudStorageDir = homeDirectory.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        if let entries = try? fm.contentsOfDirectory(at: cloudStorageDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for entry in entries {
                let rawName = entry.lastPathComponent
                let cleanedName: String
                if rawName.hasPrefix("OneDrive-") {
                    cleanedName = "OneDrive (\(rawName.dropFirst("OneDrive-".count)))"
                } else if rawName.hasPrefix("GoogleDrive-") {
                    cleanedName = "Google Drive"
                } else if rawName.hasPrefix("Dropbox") {
                    cleanedName = "Dropbox"
                } else {
                    cleanedName = rawName
                }
                addCloudDrive(at: entry, displayName: cleanedName)
            }
        }

        addCloudDrive(at: homeDirectory.appendingPathComponent("OneDrive", isDirectory: true), displayName: "OneDrive")
        addCloudDrive(at: homeDirectory.appendingPathComponent("Dropbox", isDirectory: true), displayName: "Dropbox")
        addCloudDrive(at: homeDirectory.appendingPathComponent("Google Drive", isDirectory: true), displayName: "Google Drive")

        return results
    }

    // MARK: - Sorting & Grouping (Windows 11 Semantics)

    public static func sortItems(_ items: [FileItem], by field: SortField, order: SortOrder) -> [FileItem] {
        items.sorted { lhs, rhs in
            let lhsFolder = lhs.isDirectory && !lhs.isPackage
            let rhsFolder = rhs.isDirectory && !rhs.isPackage
            if lhsFolder != rhsFolder {
                return lhsFolder
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
    }

    public static func groupItems(
        _ sortedItems: [FileItem],
        by groupBy: GroupByField,
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> [ExplorerSection] {
        switch groupBy {
        case .none:
            return []

        case .name:
            let dict = Dictionary(grouping: sortedItems) { item in
                nameBucketLabel(for: item.name)
            }
            let orderedKeys = dict.keys.sorted { lhs, rhs in
                nameBucketRank(lhs) < nameBucketRank(rhs)
            }
            return orderedKeys.compactMap { key in
                guard let items = dict[key], !items.isEmpty else { return nil }
                return ExplorerSection(id: key, title: key, items: items)
            }

        case .type:
            let dict = Dictionary(grouping: sortedItems) { $0.typeDescription }
            return dict.keys
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .compactMap { key in
                    guard let items = dict[key], !items.isEmpty else { return nil }
                    return ExplorerSection(id: key, title: key, items: items)
                }

        case .dateModified:
            let orderedBuckets = [
                "Today",
                "Yesterday",
                "Earlier this week",
                "Last week",
                "Earlier this month",
                "Last month",
                "Earlier this year",
                "A long time ago"
            ]
            let dict = Dictionary(grouping: sortedItems) { item in
                dateBucketLabel(for: item.dateModified, referenceDate: referenceDate, calendar: calendar)
            }
            return orderedBuckets.compactMap { key in
                guard let items = dict[key], !items.isEmpty else { return nil }
                return ExplorerSection(id: key, title: key, items: items)
            }

        case .size:
            let orderedBuckets = [
                "Folders",
                "Empty (0 KB)",
                "Tiny (0-16 KB)",
                "Small (16 KB-1 MB)",
                "Medium (1-128 MB)",
                "Large (128 MB-1 GB)",
                "Huge (>1 GB)"
            ]
            let dict = Dictionary(grouping: sortedItems) { item in
                sizeBucketLabel(for: item)
            }
            return orderedBuckets.compactMap { key in
                guard let items = dict[key], !items.isEmpty else { return nil }
                return ExplorerSection(id: key, title: key, items: items)
            }
        }
    }

    public static func dateBucketLabel(
        for date: Date,
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let startOfToday = calendar.startOfDay(for: referenceDate)
        let startOfDate = calendar.startOfDay(for: date)

        if startOfDate >= startOfToday {
            return "Today"
        }
        if let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday),
           startOfDate >= startOfYesterday {
            return "Yesterday"
        }

        if let thisWeekInterval = calendar.dateInterval(of: .weekOfYear, for: startOfToday) {
            if startOfDate >= thisWeekInterval.start {
                return "Earlier this week"
            }
            if let lastWeekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeekInterval.start),
               startOfDate >= lastWeekStart {
                return "Last week"
            }
        }

        if let thisMonthInterval = calendar.dateInterval(of: .month, for: startOfToday) {
            if startOfDate >= thisMonthInterval.start {
                return "Earlier this month"
            }
            if let lastMonthStart = calendar.date(byAdding: .month, value: -1, to: thisMonthInterval.start),
               startOfDate >= lastMonthStart {
                return "Last month"
            }
        }

        if let thisYearInterval = calendar.dateInterval(of: .year, for: startOfToday),
           startOfDate >= thisYearInterval.start {
            return "Earlier this year"
        }

        return "A long time ago"
    }

    public static func sizeBucketLabel(for item: FileItem) -> String {
        if item.isDirectory && !item.isPackage {
            return "Folders"
        }
        let size = item.size
        if size <= 0 {
            return "Empty (0 KB)"
        }
        if size < 16 * 1024 {
            return "Tiny (0-16 KB)"
        }
        if size < 1024 * 1024 {
            return "Small (16 KB-1 MB)"
        }
        if size < 128 * 1024 * 1024 {
            return "Medium (1-128 MB)"
        }
        if size < 1024 * 1024 * 1024 {
            return "Large (128 MB-1 GB)"
        }
        return "Huge (>1 GB)"
    }

    public static func nameBucketLabel(for name: String) -> String {
        guard let first = name.trimmingCharacters(in: .whitespacesAndNewlines).first else {
            return "#"
        }
        let folded = String(first).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).uppercased()
        guard let scalar = folded.unicodeScalars.first else {
            return "#"
        }
        if CharacterSet.decimalDigits.contains(scalar) {
            return "0-9"
        }
        if scalar.value >= 65 && scalar.value <= 90 {
            return String(scalar)
        }
        return "#"
    }

    private static func nameBucketRank(_ bucket: String) -> (Int, String) {
        if bucket == "0-9" { return (0, bucket) }
        if bucket == "#" { return (2, bucket) }
        return (1, bucket)
    }

    // MARK: - Classification & Helpers

    public static func classifyKind(
        url: URL,
        fileExtension: String? = nil,
        isDirectory: Bool,
        isPackage: Bool,
        isSymlink: Bool,
        contentType: UTType? = nil
    ) -> FileKind {
        if isSymlink { return .symlink }
        let ext = (fileExtension ?? url.pathExtension).lowercased()

        if isPackage || ext == "app" {
            if ext == "app" || (contentType?.conforms(to: .application) ?? false) {
                return .application
            }
        }
        if isDirectory && !isPackage {
            return .folder
        }

        switch ext {
        case "pdf":
            return .pdf
        case "json", "jsonc", "geojson":
            return .json
        case "md", "markdown", "mdown":
            return .markdown
        case "doc", "docx", "pages", "odt", "rtf", "rtfd":
            return .document
        case "xls", "xlsx", "numbers", "csv", "tsv", "ods":
            return .spreadsheet
        case "ppt", "pptx", "key", "odp":
            return .presentation
        case "zip", "tar", "gz", "bz2", "xz", "7z", "rar", "tgz", "tbz2", "zst":
            return .archive
        case "dmg", "iso", "sparseimage", "sparsebundle", "img":
            return .diskImage
        case "swift", "py", "js", "jsx", "ts", "tsx", "c", "cc", "cpp", "h", "hpp",
             "m", "mm", "rs", "go", "java", "kt", "kts", "rb", "php", "sh", "zsh",
             "bash", "fish", "ps1", "yaml", "yml", "toml", "xml", "plist", "html",
             "htm", "css", "scss", "sql", "r", "lua", "zig":
            return .code
        case "txt", "log", "ini", "cfg", "conf", "env", "gitignore", "license":
            return .text
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp", "svg", "ico", "icns", "raw", "dng":
            return .image
        case "mp4", "mov", "m4v", "mkv", "avi", "webm", "wmv", "flv", "tsvideo":
            return .video
        case "mp3", "m4a", "wav", "aac", "flac", "ogg", "aiff", "aif", "wma", "opus":
            return .audio
        default:
            break
        }

        if let utType = contentType ?? UTType(filenameExtension: ext) {
            if utType.conforms(to: .application) { return .application }
            if utType.conforms(to: .pdf) { return .pdf }
            if utType.conforms(to: .image) { return .image }
            if utType.conforms(to: .movie) || utType.conforms(to: .video) { return .video }
            if utType.conforms(to: .audio) { return .audio }
            if utType.conforms(to: .json) { return .json }
            if utType.conforms(to: .archive) { return .archive }
            if utType.conforms(to: .sourceCode) { return .code }
            if utType.conforms(to: .plainText) { return .text }
            if utType.conforms(to: .folder) { return .folder }
        }

        return .other
    }

    public static func readPOSIXPermissions(at url: URL) -> POSIXPermissions? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attrs[.posixPermissions] as? NSNumber else {
            return nil
        }
        return POSIXPermissions(mode: UInt16(number.uint16Value))
    }

    public static func isPermissionError(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError {
            return true
        }
        if error.domain == NSPOSIXErrorDomain && (error.code == Int(EPERM) || error.code == Int(EACCES)) {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isPermissionError(underlying)
        }
        return false
    }
}
