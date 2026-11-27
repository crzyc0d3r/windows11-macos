import Foundation

public struct SearchService: Sendable {
    private let fileSystem = FileSystemService()

    public init() {}

    public func filterItems(
        _ items: [FileItem],
        query: String,
        filters: SearchFilters,
        referenceDate: Date = Date()
    ) -> [FileItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            Self.matches(item: item, query: trimmed, filters: filters, referenceDate: referenceDate)
        }
    }

    public func search(
        in scopeURL: URL,
        query: String,
        filters: SearchFilters,
        includeHidden: Bool,
        maxResults: Int = 1000,
        referenceDate: Date = Date()
    ) async throws -> [FileItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && !filters.isActive {
            return []
        }

        let standardized = scopeURL.standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDir),
              isDir.boolValue else {
            return []
        }

        return try await Task.detached(priority: .userInitiated) {
            var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
            if !includeHidden {
                options.insert(.skipsHiddenFiles)
            }
            if !filters.includeSubfolders {
                options.insert(.skipsSubdirectoryDescendants)
            }

            guard let enumerator = FileManager.default.enumerator(
                at: standardized,
                includingPropertiesForKeys: FileSystemService.resourceKeys,
                options: options,
                errorHandler: { _, _ in true }
            ) else {
                return []
            }

            var results: [FileItem] = []
            while let obj = enumerator.nextObject() {
                if Task.isCancelled {
                    throw CancellationError()
                }
                guard let candidateURL = obj as? URL else { continue }
                if !includeHidden && candidateURL.lastPathComponent.hasPrefix(".") {
                    continue
                }
                guard let item = fileSystem.makeFileItem(at: candidateURL) else { continue }
                if !includeHidden && item.isHidden { continue }
                if Self.matches(item: item, query: trimmed, filters: filters, referenceDate: referenceDate) {
                    results.append(item)
                    if results.count >= maxResults {
                        break
                    }
                }
            }
            return results
        }.value
    }

    public static func matches(
        item: FileItem,
        query: String,
        filters: SearchFilters,
        referenceDate: Date = Date()
    ) -> Bool {
        if !query.isEmpty {
            let matched: Bool
            if filters.caseSensitive {
                matched = item.name.contains(query) || item.displayName.contains(query)
            } else {
                matched = item.name.localizedCaseInsensitiveContains(query) || item.displayName.localizedCaseInsensitiveContains(query)
            }
            if !matched { return false }
        }

        if let kind = filters.kind {
            if kind == .folder {
                if !(item.isDirectory && !item.isPackage) { return false }
            } else if item.kind != kind {
                return false
            }
        }

        if !matchesDateRange(item.dateModified, range: filters.dateRange, referenceDate: referenceDate) {
            return false
        }

        if !matchesSizeRange(item, range: filters.sizeRange) {
            return false
        }

        return true
    }

    private static func matchesDateRange(_ date: Date, range: DateRangeFilter, referenceDate: Date) -> Bool {
        let calendar = Calendar.current
        switch range {
        case .any:
            return true
        case .today:
            return date >= calendar.startOfDay(for: referenceDate)
        case .pastWeek:
            guard let cutoff = calendar.date(byAdding: .day, value: -7, to: referenceDate) else { return true }
            return date >= cutoff
        case .pastMonth:
            guard let cutoff = calendar.date(byAdding: .month, value: -1, to: referenceDate) else { return true }
            return date >= cutoff
        case .pastYear:
            guard let cutoff = calendar.date(byAdding: .year, value: -1, to: referenceDate) else { return true }
            return date >= cutoff
        }
    }

    private static func matchesSizeRange(_ item: FileItem, range: SizeRangeFilter) -> Bool {
        if range == .any { return true }
        if item.isDirectory && !item.isPackage {
            return false
        }
        let size = item.size
        switch range {
        case .any: return true
        case .empty: return size == 0
        case .tiny: return size > 0 && size < 100_000
        case .small: return size >= 100_000 && size < 1_000_000
        case .medium: return size >= 1_000_000 && size < 100_000_000
        case .large: return size >= 100_000_000 && size < 1_000_000_000
        case .huge: return size >= 1_000_000_000
        }
    }
}
