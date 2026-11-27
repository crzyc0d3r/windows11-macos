import AppKit
import Foundation

@MainActor
public final class ShowDesktopController {
    private var hiddenBundleIDs: [pid_t] = []
    private var isDesktopShown = false

    public init() {}

    public func toggleShowDesktop() {
        if isDesktopShown && !hiddenBundleIDs.isEmpty {
            restoreHiddenApps()
            return
        }

        var newlyHidden: [pid_t] = []
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier,
                  bundleID != "com.hackedple.win11shell",
                  bundleID != "com.apple.finder",
                  !app.isHidden
            else {
                continue
            }
            let visibleWins = AccessibilityBridge.standardWindows(for: app.processIdentifier)
                .filter { !$0.isMinimized }
            if !visibleWins.isEmpty {
                app.hide()
                newlyHidden.append(app.processIdentifier)
            }
        }

        if !newlyHidden.isEmpty {
            hiddenBundleIDs = newlyHidden
            isDesktopShown = true
        } else {
            isDesktopShown = false
        }
    }

    public func restoreHiddenApps() {
        for pid in hiddenBundleIDs {
            if let app = NSRunningApplication(processIdentifier: pid) {
                app.unhide()
            }
        }
        hiddenBundleIDs.removeAll()
        isDesktopShown = false
    }
}
