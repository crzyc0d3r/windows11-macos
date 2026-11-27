import AppKit
import FileExplorerCore
import SwiftUI

/// Configures the hosting macOS `NSWindow` for seamless Windows 11 Fluent chrome:
/// transparent full-size titlebar, hidden title, minimum size `920×580`, and theme appearance.
public struct WindowConfigurator: NSViewRepresentable {
    public let store: ExplorerStore

    public init(store: ExplorerStore) {
        self.store = store
    }

    public func makeNSView(context: Context) -> WindowConfiguratorNSView {
        let view = WindowConfiguratorNSView()
        view.theme = store.settings.theme
        return view
    }

    public func updateNSView(_ nsView: WindowConfiguratorNSView, context: Context) {
        nsView.theme = store.settings.theme
        nsView.applyWindowConfiguration()
    }
}

public final class WindowConfiguratorNSView: NSView {
    var theme: AppTheme = .system

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyWindowConfiguration()
    }

    func applyWindowConfiguration() {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 920, height: 580)

        let targetAppearance: NSAppearance?
        switch theme {
        case .system:
            targetAppearance = nil
        case .light:
            targetAppearance = NSAppearance(named: .aqua)
        case .dark:
            targetAppearance = NSAppearance(named: .darkAqua)
        }
        if window.appearance != targetAppearance {
            window.appearance = targetAppearance
        }
    }
}
