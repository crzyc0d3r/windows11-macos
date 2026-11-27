import Foundation

public struct PersistedTabSession: Sendable, Codable, Equatable {
    public let tabs: [ExplorerTab]
    public let activeTabID: UUID

    public init(tabs: [ExplorerTab], activeTabID: UUID) {
        self.tabs = tabs
        self.activeTabID = activeTabID
    }
}

public struct PersistenceService: Sendable {
    public let baseDirectory: URL

    public init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            self.baseDirectory = baseDirectory.standardizedFileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            self.baseDirectory = appSupport.appendingPathComponent("FileExplorer", isDirectory: true)
        }
    }

    private var settingsURL: URL { baseDirectory.appendingPathComponent("settings.json") }
    private var pinnedURL: URL { baseDirectory.appendingPathComponent("pinned_folders.json") }
    private var favoritesURL: URL { baseDirectory.appendingPathComponent("favorites.json") }
    private var recentsURL: URL { baseDirectory.appendingPathComponent("recents.json") }
    private var sessionURL: URL { baseDirectory.appendingPathComponent("session.json") }
    private var trashOriginsURL: URL { baseDirectory.appendingPathComponent("trash_origins.json") }

    // MARK: - Settings

    public func loadSettings() -> ExplorerSettings? {
        load(ExplorerSettings.self, from: settingsURL)
    }

    public func saveSettings(_ settings: ExplorerSettings) throws {
        try save(settings, to: settingsURL)
    }

    // MARK: - Pinned Folders

    public func loadPinnedFolders() -> [PinnedFolder]? {
        load([PinnedFolder].self, from: pinnedURL)
    }

    public func savePinnedFolders(_ folders: [PinnedFolder]) throws {
        try save(folders, to: pinnedURL)
    }

    // MARK: - Favorites

    public func loadFavorites() -> [FileItem]? {
        load([FileItem].self, from: favoritesURL)
    }

    public func saveFavorites(_ items: [FileItem]) throws {
        try save(items, to: favoritesURL)
    }

    // MARK: - Recent Files

    public func loadRecentFiles() -> [RecentFileEntry]? {
        load([RecentFileEntry].self, from: recentsURL)
    }

    public func saveRecentFiles(_ recents: [RecentFileEntry]) throws {
        try save(recents, to: recentsURL)
    }

    // MARK: - Tab Session

    public func loadSession() -> PersistedTabSession? {
        load(PersistedTabSession.self, from: sessionURL)
    }

    public func saveSession(_ session: PersistedTabSession) throws {
        try save(session, to: sessionURL)
    }

    // MARK: - Trash Origins

    public func loadTrashOrigins() -> [String: String] {
        load([String: String].self, from: trashOriginsURL) ?? [:]
    }

    public func saveTrashOrigins(_ origins: [String: String]) throws {
        try save(origins, to: trashOriginsURL)
    }

    // MARK: - Generic Atomic JSON I/O

    private func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        let decoder = JSONDecoder()
        return try? decoder.decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, to url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: baseDirectory.path) {
            try fm.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
    }
}
