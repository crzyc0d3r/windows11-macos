import FileExplorerCore
import FileExplorerDesign
import SwiftUI

public struct ExplorerCanvasPlaceholderView: View {
    public let store: ExplorerStore

    public init(store: ExplorerStore) {
        self.store = store
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(store.currentItems) { item in
                HStack(spacing: 8) {
                    FileThumbnailView(item: item, size: 20)
                    Text(item.displayName)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
    }
}
