import AppKit
import Foundation
import Observation
import Win11ShellCore

public struct TaskbarAppItem: Identifiable, @unchecked Sendable {
    public var id: String { bundleID }
    public let bundleID: String
    public let name: String
    public let icon: NSImage
    public let isPinned: Bool
    public let isRunning: Bool
    public let isActive: Bool
    public let pid: pid_t?
    public let windowCount: Int
    public let appURL: URL?
}

public struct RecentFileItem: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let name: String
    public let folderName: String
    public let url: URL
    public let modifiedAt: Date
}

@MainActor
@Observable
public final class RunningAppsModel {
    public var taskbarItems: [TaskbarAppItem] = []
    public var installedApps: [InstalledAppEntry] = []
    public var recentFiles: [RecentFileItem] = []
    public var trayExtras: [TrayExtraItem] = []
    public var frontmostBundleID: String?
    public var frontmostPID: pid_t?

    private let configStore: Win11ConfigStore
    public var config: Win11Config {
        didSet {
            try? configStore.save(config)
            refreshTaskbarItems()
        }
    }

    private var observers: [NSObjectProtocol] = []
    private var refreshTimer: Timer?

    public init(configStore: Win11ConfigStore) {
        self.configStore = configStore
        self.config = configStore.load()
        refreshInstalledApps()
        refreshRecentFiles()
        refreshAll()
        startObserving()
    }

    private func startObserving() {
        let nc = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification
        ]
        for name in names {
            let obs = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshAll()
                }
            }
            observers.append(obs)
        }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAll()
            }
        }
    }

    public func refreshAll() {
        refreshTaskbarItems()
        trayExtras = AccessibilityBridge.readTrayExtras(
            excludingBundleIDs: ["com.hackedple.win11shell", "com.apple.finder"]
        )
    }

    public func refreshInstalledApps() {
        installedApps = AppCatalog.scanInstalledApps()
    }

    public func refreshRecentFiles() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let dirs = [
            home.appendingPathComponent("Desktop", isDirectory: true),
            home.appendingPathComponent("Downloads", isDirectory: true),
            home.appendingPathComponent("Documents", isDirectory: true)
        ]

        var collected: [RecentFileItem] = []
        for dir in dirs {
            guard let urls = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for url in urls.prefix(20) {
                let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                if vals?.isRegularFile == true {
                    collected.append(RecentFileItem(
                        name: url.lastPathComponent,
                        folderName: dir.lastPathComponent,
                        url: url,
                        modifiedAt: vals?.contentModificationDate ?? .distantPast
                    ))
                }
            }
        }
        recentFiles = Array(collected.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(8))
    }

    public func refreshTaskbarItems() {
        let front = NSWorkspace.shared.frontmostApplication
        frontmostBundleID = front?.bundleIdentifier
        frontmostPID = front?.processIdentifier

        let running = NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular
                && app.bundleIdentifier != "com.apple.finder"
                && app.bundleIdentifier != "com.hackedple.win11shell"
        }

        var runningByBundle: [String: NSRunningApplication] = [:]
        for app in running {
            if let bid = app.bundleIdentifier, runningByBundle[bid] == nil {
                runningByBundle[bid] = app
            }
        }

        var items: [TaskbarAppItem] = []
        var seen: Set<String> = []

        // 1. Pinned apps first in order
        for bid in config.pinnedBundleIDs {
            guard bid != "com.apple.finder", bid != "com.hackedple.win11shell" else { continue }
            guard seen.insert(bid).inserted else { continue }

            let app = runningByBundle[bid]
            let url = app?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid)
            let name = app?.localizedName
                ?? installedApps.first(where: { $0.bundleID == bid })?.name
                ?? url?.deletingPathExtension().lastPathComponent
                ?? bid
            let winCount = app.map { AccessibilityBridge.standardWindows(for: $0.processIdentifier).count } ?? 0

            // Skip pinned apps that aren't installed or running (except FileExplorer)
            if app == nil && url == nil && bid != config.fileExplorerBundleID {
                continue
            }

            items.append(TaskbarAppItem(
                bundleID: bid,
                name: name,
                icon: AppIconCache.icon(forBundleID: bid, url: url, size: 28),
                isPinned: true,
                isRunning: app != nil,
                isActive: bid == frontmostBundleID,
                pid: app?.processIdentifier,
                windowCount: winCount,
                appURL: url
            ))
        }

        // 2. Remaining running apps
        for app in running {
            guard let bid = app.bundleIdentifier, seen.insert(bid).inserted else { continue }
            let winCount = AccessibilityBridge.standardWindows(for: app.processIdentifier).count
            items.append(TaskbarAppItem(
                bundleID: bid,
                name: app.localizedName ?? bid,
                icon: AppIconCache.icon(forBundleID: bid, url: app.bundleURL, size: 28),
                isPinned: false,
                isRunning: true,
                isActive: bid == frontmostBundleID,
                pid: app.processIdentifier,
                windowCount: winCount,
                appURL: app.bundleURL
            ))
        }

        taskbarItems = items
    }

    public func togglePin(bundleID: String) {
        if let idx = config.pinnedBundleIDs.firstIndex(of: bundleID) {
            config.pinnedBundleIDs.remove(at: idx)
        } else {
            config.pinnedBundleIDs.append(bundleID)
        }
    }

    public func isPinned(_ bundleID: String) -> Bool {
        config.pinnedBundleIDs.contains(bundleID)
    }

    public func launchOrActivate(bundleID: String, forceNewWindow: Bool = false) {
        if bundleID == "com.apple.finder" {
            launchOrActivate(bundleID: config.fileExplorerBundleID, forceNewWindow: forceNewWindow)
            return
        }

        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
            if forceNewWindow {
                running.activate(options: [.activateAllWindows])
                sendCmdN()
                return
            }

            if running.bundleIdentifier == frontmostBundleID && !running.isHidden {
                let windows = AccessibilityBridge.standardWindows(for: running.processIdentifier).filter { !$0.isMinimized }
                if windows.isEmpty {
                    running.hide()
                } else {
                    running.hide()
                }
            } else {
                if running.isHidden {
                    running.unhide()
                }
                let windows = AccessibilityBridge.standardWindows(for: running.processIdentifier)
                if let firstMin = windows.first(where: { $0.isMinimized }), windows.allSatisfy(\.isMinimized) {
                    AccessibilityBridge.focusWindow(firstMin)
                } else {
                    running.activate(options: [.activateAllWindows])
                }
            }
            return
        }

        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let openCfg = NSWorkspace.OpenConfiguration()
            openCfg.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: openCfg)
        }
    }

    public func launchApp(entry: InstalledAppEntry) {
        let openCfg = NSWorkspace.OpenConfiguration()
        openCfg.activates = true
        NSWorkspace.shared.openApplication(at: entry.url, configuration: openCfg)
    }

    private func sendCmdN() {
        let src = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: 45, keyDown: true),
           let up = CGEvent(keyboardEventSource: src, virtualKey: 45, keyDown: false) {
            down.flags = .maskCommand
            up.flags = .maskCommand
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }
}
