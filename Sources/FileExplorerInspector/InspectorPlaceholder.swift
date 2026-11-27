import FileExplorerCore
import FileExplorerDesign
import SwiftUI

public struct InspectorPlaceholderView: View {
    public let store: ExplorerStore

    public init(store: ExplorerStore) {
        self.store = store
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let item = store.primarySelectedItem {
                FluentIconView(kind: .forItem(item), size: 32)
                Text(item.name)
                    .font(.headline)
            } else {
                Text("Select an item to view details")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
    }
}
