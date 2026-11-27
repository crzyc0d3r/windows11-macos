import FileExplorerCore
import FileExplorerDesign
import SwiftUI

public struct SearchFilterBarView: View {
    public let store: ExplorerStore

    @Environment(\.fluentTheme) private var theme

    private let kindOptions: [(label: String, kind: FileKind?)] = [
        ("All", nil),
        ("Folders", .folder),
        ("Images", .image),
        ("Documents", .document),
        ("Code", .code),
        ("Videos", .video),
        ("Audio", .audio),
        ("Archives", .archive)
    ]

    public init(store: ExplorerStore) {
        self.store = store
    }

    private var filters: SearchFilters {
        store.activeTab.searchFilters
    }

    public var body: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(kindOptions, id: \.label) { option in
                        let selected = filters.kind == option.kind
                        Button {
                            var updated = filters
                            updated.kind = option.kind
                            store.updateSearchFilters(updated)
                        } label: {
                            Text(option.label)
                                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                                .foregroundStyle(selected ? .white : theme.palette.textPrimary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(selected ? theme.palette.accentBlue : theme.palette.cardSurface)
                                )
                                .overlay(
                                    Capsule(style: .continuous)
                                        .stroke(
                                            selected ? theme.palette.accentBlue : theme.palette.borderSubtle,
                                            lineWidth: 1
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider()
                .frame(height: 18)

            Menu {
                ForEach(DateRangeFilter.allCases, id: \.self) { range in
                    Button {
                        var updated = filters
                        updated.dateRange = range
                        store.updateSearchFilters(updated)
                    } label: {
                        HStack {
                            Text(range.displayTitle)
                            if filters.dateRange == range {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                filterMenuLabel(
                    icon: "calendar",
                    text: filters.dateRange == .any ? "Date modified" : filters.dateRange.displayTitle,
                    isActive: filters.dateRange != .any
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Menu {
                ForEach(SizeRangeFilter.allCases, id: \.self) { size in
                    Button {
                        var updated = filters
                        updated.sizeRange = size
                        store.updateSearchFilters(updated)
                    } label: {
                        HStack {
                            Text(size.displayTitle)
                            if filters.sizeRange == size {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                filterMenuLabel(
                    icon: "internaldrive",
                    text: filters.sizeRange == .any ? "Size" : filters.sizeRange.displayTitle,
                    isActive: filters.sizeRange != .any
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                var updated = filters
                updated.includeSubfolders.toggle()
                store.updateSearchFilters(updated)
            } label: {
                filterMenuLabel(
                    icon: filters.includeSubfolders ? "folder.badge.gearshape" : "folder",
                    text: filters.includeSubfolders ? "Subfolders" : "Current folder",
                    isActive: true
                )
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            Text("\(store.currentItems.count) \(store.currentItems.count == 1 ? "result" : "results")")
                .font(.system(size: 12))
                .foregroundStyle(theme.palette.textSecondary)

            Button {
                store.clearSearch()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                    Text("Close search")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(theme.palette.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: theme.cornerRadiusSmall, style: .continuous)
                        .fill(theme.palette.cardSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: theme.cornerRadiusSmall, style: .continuous)
                        .stroke(theme.palette.borderSubtle, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(theme.palette.commandBar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.palette.borderSubtle)
                .frame(height: 1)
        }
    }

    private func filterMenuLabel(icon: String, text: String, isActive: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11))
            Text(text)
                .font(.system(size: 12, weight: isActive ? .medium : .regular))
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(isActive ? theme.palette.accentBlue : theme.palette.textPrimary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: theme.cornerRadiusSmall, style: .continuous)
                .fill(isActive ? theme.palette.selectionFill : theme.palette.cardSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadiusSmall, style: .continuous)
                .stroke(isActive ? theme.palette.accentBlue.opacity(0.45) : theme.palette.borderSubtle, lineWidth: 1)
        )
    }
}
