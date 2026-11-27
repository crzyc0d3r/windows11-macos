import Foundation

public struct InstalledAppEntry: Identifiable, Hashable, Sendable {
    public var id: String { bundleID }
    public let bundleID: String
    public let name: String
    public let url: URL

    public init(bundleID: String, name: String, url: URL) {
        self.bundleID = bundleID
        self.name = name
        self.url = url
    }
}

public enum AppCatalog {
    public static func filterApps(
        _ apps: [InstalledAppEntry],
        query: String,
        hideFinder: Bool = true
    ) -> [InstalledAppEntry] {
        let filtered = apps.filter { entry in
            if hideFinder && entry.bundleID == "com.apple.finder" {
                return false
            }
            return entry.bundleID != "com.hackedple.win11shell"
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            return filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        let matching = filtered.filter {
            $0.name.lowercased().contains(trimmed) || $0.bundleID.lowercased().contains(trimmed)
        }

        return matching.sorted { lhs, rhs in
            let lName = lhs.name.lowercased()
            let rName = rhs.name.lowercased()
            let lPrefix = lName.hasPrefix(trimmed)
            let rPrefix = rName.hasPrefix(trimmed)
            if lPrefix != rPrefix {
                return lPrefix
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    public static func scanInstalledApps(searchDirectories: [URL]? = nil) -> [InstalledAppEntry] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let directories = searchDirectories ?? [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true)
        ]

        var byBundleID: [String: InstalledAppEntry] = [:]

        for dir in directories {
            guard let contents = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for item in contents where item.pathExtension == "app" {
                guard let bundle = Bundle(url: item),
                      let bundleID = bundle.bundleIdentifier,
                      bundleID != "com.apple.finder",
                      bundleID != "com.hackedple.win11shell"
                else {
                    continue
                }

                let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? item.deletingPathExtension().lastPathComponent

                let entry = InstalledAppEntry(bundleID: bundleID, name: displayName, url: item)
                if byBundleID[bundleID] == nil {
                    byBundleID[bundleID] = entry
                }
            }
        }

        return filterApps(Array(byBundleID.values), query: "", hideFinder: true)
    }
}
