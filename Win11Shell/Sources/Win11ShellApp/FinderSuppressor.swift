import AppKit
import Foundation

@MainActor
public final class FinderSuppressor {
    private let fileExplorerBundleID: String
    private var observers: [NSObjectProtocol] = []
    private var lastRedirectDate = Date.distantPast
    public var isEnabled = true

    public init(fileExplorerBundleID: String = "com.hackedple.fileexplorer") {
        self.fileExplorerBundleID = fileExplorerBundleID
    }

    public func start() {
        stop()
        let center = NSWorkspace.shared.notificationCenter

        let actObs = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                self?.handleAppEvent(app)
            }
        }

        let launchObs = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                self?.handleAppEvent(app)
            }
        }

        observers = [actObs, launchObs]
        suppressRunningFinderIfNeeded(openReplacement: false)
    }

    public func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for obs in observers {
            center.removeObserver(obs)
        }
        observers.removeAll()
    }

    private func handleAppEvent(_ app: NSRunningApplication?) {
        guard isEnabled, let app, app.bundleIdentifier == "com.apple.finder" else {
            return
        }
        suppress(app, openReplacement: true)
    }

    public func suppressRunningFinderIfNeeded(openReplacement: Bool) {
        guard isEnabled else { return }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder") {
            suppress(app, openReplacement: openReplacement)
        }
    }

    private func suppress(_ finder: NSRunningApplication, openReplacement: Bool) {
        finder.hide()
        // Quit Finder cleanly if QuitMenuItem is enabled; ignore if macOS respawns it in background
        finder.terminate()

        guard openReplacement else { return }
        let now = Date()
        guard now.timeIntervalSince(lastRedirectDate) > 0.6 else { return }
        lastRedirectDate = now
        openFileExplorer()
    }

    public func openFileExplorer() {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: fileExplorerBundleID).first {
            if running.isHidden {
                running.unhide()
            }
            running.activate(options: [.activateAllWindows])
            let windows = AccessibilityBridge.standardWindows(for: running.processIdentifier)
            if windows.isEmpty {
                // Trigger new window if already running with zero windows
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: fileExplorerBundleID) {
                    let config = NSWorkspace.OpenConfiguration()
                    config.activates = true
                    NSWorkspace.shared.openApplication(at: url, configuration: config)
                }
            }
            return
        }

        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: fileExplorerBundleID) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        }
    }
}
