import Foundation

public enum TaskbarAlignment: String, Codable, CaseIterable, Sendable {
    case center
    case left
}

public struct Win11Config: Codable, Equatable, Sendable {
    public var taskbarHeight: Double
    public var windowBarHeight: Double
    public var taskbarAlignment: TaskbarAlignment
    public var taskbarAutoHide: Bool
    public var showSearchButton: Bool
    public var showTaskViewButton: Bool
    public var showWidgetsButton: Bool
    public var showWindowChromeBar: Bool
    public var fileExplorerBundleID: String
    public var pinnedBundleIDs: [String]
    public var keepAliveBundleIDs: [String]
    public var terminalBundleIDs: [String]
    public var windowBarExcludedBundleIDs: [String]

    public init(
        taskbarHeight: Double = 48,
        windowBarHeight: Double = 28,
        taskbarAlignment: TaskbarAlignment = .center,
        taskbarAutoHide: Bool = false,
        showSearchButton: Bool = true,
        showTaskViewButton: Bool = true,
        showWidgetsButton: Bool = true,
        showWindowChromeBar: Bool = true,
        fileExplorerBundleID: String = "com.hackedple.fileexplorer",
        pinnedBundleIDs: [String] = [
            "com.hackedple.fileexplorer",
            "com.google.Chrome",
            "com.apple.Safari",
            "com.apple.Terminal",
            "com.apple.systempreferences"
        ],
        keepAliveBundleIDs: [String] = [
            "com.apple.finder",
            "com.microsoft.Outlook",
            "com.microsoft.teams2",
            "net.whatsapp.WhatsApp",
            "com.microsoft.OneDrive",
            "io.tailscale.ipn.macos",
            "com.apple.mail",
            "com.tinyspeck.slackmacgap",
            "com.hackedple.win11shell"
        ],
        terminalBundleIDs: [String] = [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "com.mitchellh.ghostty",
            "dev.warp.Warp-Stable",
            "org.alacritty",
            "net.kovidgoyal.kitty",
            "com.github.wez.wezterm",
            "co.zeit.hyper"
        ],
        windowBarExcludedBundleIDs: [String] = [
            "com.hackedple.win11shell",
            "com.lwouis.alt-tab-macos",
            "com.knollsoft.Rectangle",
            "com.apple.Spotlight",
            "com.apple.notificationcenterui",
            "com.apple.controlcenter"
        ]
    ) {
        self.taskbarHeight = taskbarHeight
        self.windowBarHeight = windowBarHeight
        self.taskbarAlignment = taskbarAlignment
        self.taskbarAutoHide = taskbarAutoHide
        self.showSearchButton = showSearchButton
        self.showTaskViewButton = showTaskViewButton
        self.showWidgetsButton = showWidgetsButton
        self.showWindowChromeBar = showWindowChromeBar
        self.fileExplorerBundleID = fileExplorerBundleID
        self.pinnedBundleIDs = pinnedBundleIDs
        self.keepAliveBundleIDs = keepAliveBundleIDs
        self.terminalBundleIDs = terminalBundleIDs
        self.windowBarExcludedBundleIDs = windowBarExcludedBundleIDs
    }

    public static let `default` = Win11Config()
}

public final class Win11ConfigStore: @unchecked Sendable {
    public let configURL: URL

    public static var defaultConfigURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("HackedpleWin11", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    public init(configURL: URL = Win11ConfigStore.defaultConfigURL) {
        self.configURL = configURL
    }

    public func load() -> Win11Config {
        guard let data = try? Data(contentsOf: configURL) else {
            return .default
        }
        let decoder = JSONDecoder()
        return (try? decoder.decode(Win11Config.self, from: data)) ?? .default
    }

    public func save(_ config: Win11Config) throws {
        let parent = configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: configURL, options: .atomic)
    }
}
