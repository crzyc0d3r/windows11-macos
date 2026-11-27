import FileExplorerCore
import FileExplorerDesign
import SwiftUI

/// Bottom Windows 11 24H2 Status Bar (~28px tall) showing item/selection counts,
/// active background operations, and quick Details / Large thumbnails toggles.
public struct StatusBarView: View {
    public let store: ExplorerStore

    @Environment(\.fluentTheme) private var theme

    private let barHeight: CGFloat = 28

    public init(store: ExplorerStore) {
        self.store = store
    }

    public var body: some View {
        HStack(spacing: 10) {
            leftSummary
            Spacer(minLength: 8)
            rightQuickViewToggles
        }
        .padding(.horizontal, 12)
        .frame(height: barHeight)
        .background(theme.palette.statusBar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.palette.borderSubtle)
                .frame(height: 1)
        }
    }

    // MARK: - Left Item & Selection Summary

    private var leftSummary: some View {
        HStack(spacing: 10) {
            Text(itemCountText)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.palette.textSecondary)

            if !store.selectedItems.isEmpty {
                separator

                Text(selectionSummaryText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.palette.textPrimary)
            }

            if let activeOp = store.activeOperations.first {
                separator

                HStack(spacing: 6) {
                    ProgressView(value: activeOp.fractionCompleted)
                        .progressViewStyle(.linear)
                        .frame(width: 64)
                        .tint(theme.palette.accentBlue)

                    Text(operationSummaryText(activeOp))
                        .font(.system(size: 11))
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var itemCountText: String {
        let count = displayedItemCount
        return count == 1 ? "1 item" : "\(count) items"
    }

    private var displayedItemCount: Int {
        switch store.activeTab.location {
        case .thisPC:
            return store.volumes.count
        default:
            return store.currentItems.count
        }
    }

    private var selectionSummaryText: String {
        let selected = store.selectedItems
        let countLabel = selected.count == 1 ? "1 item selected" : "\(selected.count) items selected"
        let fileSizeSum = selected.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.size }
        if fileSizeSum > 0 || selected.contains(where: { !$0.isDirectory }) {
            let formatted = ByteCountFormatter.string(fromByteCount: fileSizeSum, countStyle: .file)
            return "\(countLabel)  \(formatted)"
        }
        return countLabel
    }

    private func operationSummaryText(_ op: FileOperationProgress) -> String {
        if store.activeOperations.count > 1 {
            return "\(op.title) (+\(store.activeOperations.count - 1))"
        }
        return op.title
    }

    private var separator: some View {
        Rectangle()
            .fill(theme.palette.borderSubtle)
            .frame(width: 1, height: 12)
    }

    // MARK: - Right Quick View Toggles

    private var rightQuickViewToggles: some View {
        HStack(spacing: 2) {
            ChromeIconButton(
                systemName: ViewMode.details.iconSystemName,
                size: 22,
                iconSize: 11.5,
                isEnabled: true,
                isActive: store.activeTab.viewMode == .details,
                tooltip: "Details view"
            ) {
                store.setViewMode(.details)
            }

            ChromeIconButton(
                systemName: ViewMode.largeIcons.iconSystemName,
                size: 22,
                iconSize: 11.5,
                isEnabled: true,
                isActive: store.activeTab.viewMode == .largeIcons,
                tooltip: "Large icons"
            ) {
                store.setViewMode(.largeIcons)
            }
        }
    }
}
