import AppKit
import FileExplorerChrome
import FileExplorerCore
import FileExplorerDesign
import FileExplorerInspector
import FileExplorerViews
import SwiftUI

public struct MainExplorerWindowView: View {
    public let store: ExplorerStore
    public var contextMenuAnchorPoint: CGPoint?
    public var onMoveTabToNewWindow: ((ExplorerTab) -> Void)?

    @Environment(\.fluentTheme) private var _unusedTheme
    @Environment(\.colorScheme) private var systemScheme

    public init(
        store: ExplorerStore,
        contextMenuAnchorPoint: CGPoint? = nil,
        onMoveTabToNewWindow: ((ExplorerTab) -> Void)? = nil
    ) {
        self.store = store
        self.contextMenuAnchorPoint = contextMenuAnchorPoint
        self.onMoveTabToNewWindow = onMoveTabToNewWindow
    }

    public var body: some View {
        let resolvedTheme = FluentTheme.resolve(
            theme: store.settings.theme,
            systemScheme: systemScheme,
            accent: store.settings.accentColor,
            compact: store.settings.compactView
        )

        ZStack {
            WindowConfigurator(store: store)
                .frame(width: 0, height: 0)

            QuickLookBridgeView(store: store)
                .frame(width: 0, height: 0)

            MicaBackground(variant: .mica)

            VStack(spacing: 0) {
                ExplorerTopChromeView(
                    store: store,
                    onMoveTabToNewWindow: onMoveTabToNewWindow
                )

                if let errorMessage = store.lastErrorMessage {
                    errorBanner(message: errorMessage, theme: resolvedTheme)
                }

                HStack(spacing: 0) {
                    if store.settings.showNavigationPane {
                        NavigationPaneView(store: store)
                    }

                    ContentAreaView(store: store)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if store.settings.rightPaneMode != .none {
                        RightInspectorContainerView(store: store)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                StatusBarView(store: store)
            }

            FileOperationOverlayView(store: store)
            Win11ContextMenuOverlay(store: store, anchorPoint: contextMenuAnchorPoint)
            ConflictResolutionDialogView(store: store)
            PropertiesDialogView(store: store)
            SettingsOptionsDialogView(store: store)
        }
        .environment(\.fluentTheme, resolvedTheme)
        .preferredColorScheme(preferredColorScheme)
        .frame(minWidth: 920, minHeight: 580)
    }

    private var preferredColorScheme: ColorScheme? {
        switch store.settings.theme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    private func errorBanner(message: String, theme: FluentTheme) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13.5))
                .foregroundStyle(theme.palette.dangerRed)

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(2)

            Spacer()

            Button {
                store.dismissError()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.palette.textSecondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(theme.palette.dangerRed.opacity(0.12))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.palette.dangerRed.opacity(0.35))
                .frame(height: 1)
        }
    }
}
