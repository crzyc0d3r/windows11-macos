import Foundation

public enum CloseAction: Equatable, Sendable {
    case closeWindow
    case quitApp
    case hideApp
}

public enum WindowClosePolicy {
    /// Decides whether closing a window should only close that window, quit the app (Windows 11 default),
    /// or hide/close without quitting (for tray/background keep-alive apps).
    public static func decide(
        bundleID: String,
        standardWindowCount: Int,
        keepAliveBundleIDs: Set<String>
    ) -> CloseAction {
        if standardWindowCount > 1 {
            return .closeWindow
        }
        if keepAliveBundleIDs.contains(bundleID) {
            return .hideApp
        }
        return .quitApp
    }
}
