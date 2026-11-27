import AppKit
import FileExplorerCore
import FileExplorerDesign
import SwiftUI

public struct HomeView: View {
    public let store: ExplorerStore

    @Environment(\.fluentTheme) private var theme
    @State private var isQuickAccessCollapsed = false
    @State private var isFavoritesCollapsed = false
    @State private var isRecentCollapsed = false
    @State private var hoveredPinnedID: UUID?
    @State private var hoveredFavoriteURL: URL?
    @State private var hoveredRecentID: UUID?

    public init(store: ExplorerStore) {
        self.store = store
    }

    private let quickAccessColumns = [
        GridItem(.adaptive(minimum: 185, maximum: 240), spacing: 12)
    ]

    private let favoriteColumns = [
        GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 12)
    ]

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Quick access
                VStack(alignment: .leading, spacing: 10) {
                    Win11SectionHeader(
                        title: "Quick access",
                        count: store.pinnedFolders.count,
                        isCollapsed: isQuickAccessCollapsed
                    ) {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            isQuickAccessCollapsed.toggle()
                        }
                    }

                    if !isQuickAccessCollapsed {
                        if store.pinnedFolders.isEmpty {
                            emptyRow("No pinned folders yet. Right-click any folder to pin it to Quick access.")
                        } else {
                            LazyVGrid(columns: quickAccessColumns, spacing: 10) {
                                ForEach(store.pinnedFolders) { folder in
                                    quickAccessCard(folder)
                                }
                            }
                            .padding(.horizontal, 6)
                        }
                    }
                }

                // Favorites
                VStack(alignment: .leading, spacing: 10) {
                    Win11SectionHeader(
                        title: "Favorites",
                        count: store.favoriteFiles.count,
                        isCollapsed: isFavoritesCollapsed
                    ) {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            isFavoritesCollapsed.toggle()
                        }
                    }

                    if !isFavoritesCollapsed {
                        if store.favoriteFiles.isEmpty {
                            emptyRow("No favorite files yet. Mark frequently used files as Favorites to see them here.")
                        } else {
                            LazyVGrid(columns: favoriteColumns, spacing: 10) {
                                ForEach(store.favoriteFiles) { item in
                                    favoriteCard(item)
                                }
                            }
                            .padding(.horizontal, 6)
                        }
                    }
                }

                // Recent
                VStack(alignment: .leading, spacing: 8) {
                    Win11SectionHeader(
                        title: "Recent",
                        count: store.recentFiles.count,
                        isCollapsed: isRecentCollapsed
                    ) {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            isRecentCollapsed.toggle()
                        }
                    }

                    if !isRecentCollapsed {
                        if store.recentFiles.isEmpty {
                            emptyRow("Recent files will appear here as you open documents and folders.")
                        } else {
                            recentTable
                                .padding(.horizontal, 6)
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(theme.palette.contentCanvas)
        .overlay {
            RightClickHandlerOverlay {
                store.showContextMenu(for: .background(.home))
            }
        }
    }

    private func quickAccessCard(_ folder: PinnedFolder) -> some View {
        let isHovered = hoveredPinnedID == folder.id
        return HStack(spacing: 12) {
            FluentIconView(
                kind: ExplorerViewFormatting.iconKind(for: folder),
                size: 34
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(folder.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.palette.textPrimary)
                        .lineLimit(1)
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(theme.palette.accentBlue)
                        .rotationEffect(.degrees(35))
                }
                Text(folder.url.path)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: theme.cornerRadiusMedium, style: .continuous)
                .fill(isHovered ? theme.palette.hoverFill : theme.palette.cardSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadiusMedium, style: .continuous)
                .stroke(theme.palette.borderSubtle, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hoveredPinnedID = $0 ? folder.id : nil }
        .onTapGesture {
            let clickCount = NSApp.currentEvent?.clickCount ?? 1
            if clickCount >= 2 || store.settings.singleClickToOpen {
                store.navigate(to: .folder(folder.url))
            }
        }
        .overlay {
            RightClickHandlerOverlay {
                store.showContextMenu(for: .sidebarItem(folder.url))
            }
        }
    }

    private func favoriteCard(_ item: FileItem) -> some View {
        let isHovered = hoveredFavoriteURL == item.url
        let isSelected = store.activeTab.selectedURLs.contains(item.url)
        return HStack(spacing: 10) {
            FileThumbnailView(item: item, size: 32, isCut: ExplorerViewFormatting.isCut(item, in: store))

            VStack(alignment: .leading, spacing: 2) {
                Text(ExplorerViewFormatting.displayName(for: item, showExtensions: store.settings.showFileExtensions))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                Text(item.url.deletingLastPathComponent().lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button {
                store.removeFavorite(url: item.url)
            } label: {
                Image(systemName: "star.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.93, green: 0.68, blue: 0.14))
            }
            .buttonStyle(.plain)
            .help("Remove from Favorites")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: theme.cornerRadiusMedium, style: .continuous)
                .fill(isSelected ? theme.palette.selectionFill : (isHovered ? theme.palette.hoverFill : theme.palette.cardSurface))
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadiusMedium, style: .continuous)
                .stroke(isSelected ? theme.palette.accentBlue.opacity(0.6) : theme.palette.borderSubtle, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hoveredFavoriteURL = $0 ? item.url : nil }
        .onTapGesture {
            ItemInteractionHandler.handleTap(item: item, store: store) {}
        }
        .overlay {
            RightClickHandlerOverlay {
                store.selectItem(url: item.url)
                store.showContextMenu(for: .item(item))
            }
        }
    }

    private var recentTable: some View {
        VStack(spacing: 0) {
            // Table header
            HStack(spacing: 12) {
                Text("Name")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Date accessed")
                    .frame(width: 150, alignment: .leading)
                Text("Location")
                    .frame(width: 220, alignment: .leading)
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(theme.palette.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            Divider()

            ForEach(store.recentFiles) { entry in
                let isHovered = hoveredRecentID == entry.id
                let isSelected = store.activeTab.selectedURLs.contains(entry.url)
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        FluentIconView(kind: .fileKind(entry.kind), size: 18)
                        Text(entry.name)
                            .font(.system(size: 12.5))
                            .foregroundStyle(theme.palette.textPrimary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(ExplorerViewFormatting.formattedDate(entry.accessedAt))
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.textSecondary)
                        .frame(width: 150, alignment: .leading)

                    Text(entry.url.deletingLastPathComponent().path)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 220, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .frame(height: store.settings.compactView ? 26 : 32)
                .background(
                    RoundedRectangle(cornerRadius: theme.cornerRadiusSmall, style: .continuous)
                        .fill(isSelected ? theme.palette.selectionFill : (isHovered ? theme.palette.hoverFill : .clear))
                )
                .contentShape(Rectangle())
                .onHover { hoveredRecentID = $0 ? entry.id : nil }
                .onTapGesture {
                    let clickCount = NSApp.currentEvent?.clickCount ?? 1
                    store.selectItem(url: entry.url)
                    if clickCount >= 2 || store.settings.singleClickToOpen {
                        store.openItemWithDefaultApp(entry.url)
                    }
                }
                .overlay {
                    RightClickHandlerOverlay {
                        let item = FileItem(url: entry.url, name: entry.name, kind: entry.kind, isDirectory: false, dateModified: entry.accessedAt)
                        store.selectItem(url: entry.url)
                        store.showContextMenu(for: .item(item))
                    }
                }
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: theme.cornerRadiusMedium, style: .continuous)
                .fill(theme.palette.cardSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadiusMedium, style: .continuous)
                .stroke(theme.palette.borderSubtle, lineWidth: 1)
        )
    }

    private func emptyRow(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12.5))
            .foregroundStyle(theme.palette.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }
}
