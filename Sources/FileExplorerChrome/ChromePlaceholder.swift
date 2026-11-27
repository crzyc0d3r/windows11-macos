import FileExplorerCore
import FileExplorerDesign
import SwiftUI

public struct ChromePlaceholderView: View {
    public let store: ExplorerStore

    public init(store: ExplorerStore) {
        self.store = store
    }

    public var body: some View {
        HStack {
            FluentIconView(kind: .home, size: 16)
            Text(store.activeTab.title)
                .font(.subheadline)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
