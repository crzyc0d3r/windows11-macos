import FileExplorerChrome
import FileExplorerCore
import FileExplorerDesign
import FileExplorerInspector
import FileExplorerViews
import SwiftUI

@main
struct FileExplorerApp: App {
    @State private var store = ExplorerStore.makeSnapshotPreviewStore()
    @Environment(\.colorScheme) private var systemScheme

    var body: some Scene {
        WindowGroup {
            let fluentTheme = FluentTheme.resolve(
                theme: store.settings.theme,
                systemScheme: systemScheme,
                accent: store.settings.accentColor,
                compact: store.settings.compactView
            )
            ZStack {
                MicaBackground(variant: .mica)
                VStack(spacing: 0) {
                    ChromePlaceholderView(store: store)
                    Divider()
                    HStack(spacing: 0) {
                        ExplorerCanvasPlaceholderView(store: store)
                        if store.settings.rightPaneMode != .none {
                            Divider()
                            InspectorPlaceholderView(store: store)
                                .frame(width: store.settings.rightPaneWidth)
                        }
                    }
                }
            }
            .environment(\.fluentTheme, fluentTheme)
            .frame(minWidth: 960, minHeight: 620)
        }
    }
}
