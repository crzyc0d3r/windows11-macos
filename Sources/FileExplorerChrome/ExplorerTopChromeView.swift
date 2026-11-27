import FileExplorerCore
import FileExplorerDesign
import SwiftUI

/// Complete Windows 11 24H2 top chrome stack:
/// `TabBarView` (top) → `AddressBarRowView` (middle) → `CommandBarView` (bottom).
public struct ExplorerTopChromeView: View {
    public let store: ExplorerStore
    public let onMoveTabToNewWindow: ((ExplorerTab) -> Void)?

    public init(
        store: ExplorerStore,
        onMoveTabToNewWindow: ((ExplorerTab) -> Void)? = nil
    ) {
        self.store = store
        self.onMoveTabToNewWindow = onMoveTabToNewWindow
    }

    public var body: some View {
        VStack(spacing: 0) {
            TabBarView(store: store, onMoveTabToNewWindow: onMoveTabToNewWindow)
                .zIndex(2)
            AddressBarRowView(store: store)
                .zIndex(1)
            CommandBarView(store: store)
                .zIndex(0)
        }
    }
}
