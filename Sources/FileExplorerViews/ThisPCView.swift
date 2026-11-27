import AppKit
import FileExplorerCore
import FileExplorerDesign
import SwiftUI

public struct ThisPCView: View {
    public let store: ExplorerStore

    @Environment(\.fluentTheme) private var theme
    @State private var isFoldersCollapsed = false
    @State private var isDrivesCollapsed = false
    @State private var isNetworkCollapsed = false
    @State private var hoveredFolderID: String?
    @State private var hoveredVolumeURL: URL?
    @State private var isNetworkCardHovered = false

    public init(store: ExplorerStore) {
        self.store = store
    }

    private struct UserFolderTile: Identifiable {
        let id: String
        let title: String
        let url: URL
        let iconKind: FluentIconKind
    }

    private var standardUserFolders: [UserFolderTile] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            UserFolderTile(id: "desktop", title: "Desktop", url: home.appendingPathComponent("Desktop", isDirectory: true), iconKind: .desktop),
            UserFolderTile(id: "documents", title: "Documents", url: home.appendingPathComponent("Documents", isDirectory: true), iconKind: .documents),
            UserFolderTile(id: "downloads", title: "Downloads", url: home.appendingPathComponent("Downloads", isDirectory: true), iconKind: .downloads),
            UserFolderTile(id: "pictures", title: "Pictures", url: home.appendingPathComponent("Pictures", isDirectory: true), iconKind: .pictures),
            UserFolderTile(id: "music", title: "Music", url: home.appendingPathComponent("Music", isDirectory: true), iconKind: .music),
            UserFolderTile(id: "videos", title: "Videos", url: home.appendingPathComponent("Movies", isDirectory: true), iconKind: .videos)
        ]
    }

    private var localDrives: [VolumeInfo] {
        store.volumes.filter { $0.volumeKind == .internalDrive || $0.volumeKind == .externalDrive }
    }

    private var networkAndCloudLocations: [VolumeInfo] {
        store.volumes.filter { $0.volumeKind == .networkDrive || $0.volumeKind == .cloudDrive } + store.cloudLocations
    }

    private let folderColumns = [
        GridItem(.adaptive(minimum: 185, maximum: 240), spacing: 12)
    ]

    private let driveColumns = [
        GridItem(.adaptive(minimum: 265, maximum: 340), spacing: 12)
    ]

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Folders section
                VStack(alignment: .leading, spacing: 10) {
                    Win11SectionHeader(
                        title: "Folders",
                        count: standardUserFolders.count,
                        isCollapsed: isFoldersCollapsed
                    ) {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            isFoldersCollapsed.toggle()
                        }
                    }

                    if !isFoldersCollapsed {
                        LazyVGrid(columns: folderColumns, spacing: 10) {
                            ForEach(standardUserFolders) { folder in
                                folderCard(folder)
                            }
                        }
                        .padding(.horizontal, 6)
                    }
                }

                // Devices and drives section
                VStack(alignment: .leading, spacing: 10) {
                    Win11SectionHeader(
                        title: "Devices and drives",
                        count: localDrives.count,
                        isCollapsed: isDrivesCollapsed
                    ) {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            isDrivesCollapsed.toggle()
                        }
                    }

                    if !isDrivesCollapsed {
                        if localDrives.isEmpty {
                            Text("No local drives detected.")
                                .font(.system(size: 12.5))
                                .foregroundStyle(theme.palette.textSecondary)
                                .padding(.horizontal, 12)
                        } else {
                            LazyVGrid(columns: driveColumns, spacing: 12) {
                                ForEach(localDrives) { volume in
                                    driveCard(volume)
                                }
                            }
                            .padding(.horizontal, 6)
                        }
                    }
                }

                // Network locations section
                VStack(alignment: .leading, spacing: 10) {
                    Win11SectionHeader(
                        title: "Network locations",
                        count: networkAndCloudLocations.count + 1,
                        isCollapsed: isNetworkCollapsed
                    ) {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            isNetworkCollapsed.toggle()
                        }
                    }

                    if !isNetworkCollapsed {
                        LazyVGrid(columns: driveColumns, spacing: 12) {
                            ForEach(networkAndCloudLocations) { volume in
                                driveCard(volume)
                            }

                            networkDiscoveryCard
                        }
                        .padding(.horizontal, 6)
                    }
                }
            }
            .padding(20)
        }
        .background(theme.palette.contentCanvas)
        .overlay {
            RightClickHandlerOverlay {
                store.showContextMenu(for: .background(.thisPC))
            }
        }
    }

    private func folderCard(_ folder: UserFolderTile) -> some View {
        let isHovered = hoveredFolderID == folder.id
        return HStack(spacing: 12) {
            FluentIconView(kind: folder.iconKind, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
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
        .onHover { hoveredFolderID = $0 ? folder.id : nil }
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

    private func driveCard(_ volume: VolumeInfo) -> some View {
        let isHovered = hoveredVolumeURL == volume.url
        let isNearFull = volume.usedFraction >= 0.90
        let barColor = isNearFull
            ? Color(red: 0.769, green: 0.169, blue: 0.110) // #C42B1C
            : theme.palette.accentBlue
        let freeString = ExplorerViewFormatting.formattedDriveSpace(volume.freeBytes)
        let totalString = ExplorerViewFormatting.formattedDriveSpace(volume.totalBytes)

        return HStack(spacing: 12) {
            FluentIconView(kind: iconKind(for: volume.volumeKind), size: 42)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(volume.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.palette.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text(volume.fileSystemFormat)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.palette.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            Capsule(style: .continuous)
                                .fill(theme.palette.hoverFill)
                        )
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(theme.palette.borderSubtle)
                        Capsule(style: .continuous)
                            .fill(barColor)
                            .frame(width: max(4, geo.size.width * CGFloat(volume.usedFraction)))
                    }
                }
                .frame(height: 6)

                Text("\(freeString) free of \(totalString)")
                    .font(.system(size: 11))
                    .foregroundStyle(isNearFull ? barColor : theme.palette.textSecondary)
                    .lineLimit(1)
            }
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
        .onHover { hoveredVolumeURL = $0 ? volume.url : nil }
        .onTapGesture {
            let clickCount = NSApp.currentEvent?.clickCount ?? 1
            if clickCount >= 2 || store.settings.singleClickToOpen {
                store.navigate(to: .folder(volume.url))
            }
        }
        .overlay {
            RightClickHandlerOverlay {
                store.showContextMenu(for: .sidebarItem(volume.url))
            }
        }
    }

    private var networkDiscoveryCard: some View {
        HStack(spacing: 12) {
            FluentIconView(kind: .networkDrive, size: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text("Network")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                Text("Browse shared servers & mounted drives")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.palette.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: theme.cornerRadiusMedium, style: .continuous)
                .fill(isNetworkCardHovered ? theme.palette.hoverFill : theme.palette.cardSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadiusMedium, style: .continuous)
                .stroke(theme.palette.borderSubtle, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { isNetworkCardHovered = $0 }
        .onTapGesture {
            let clickCount = NSApp.currentEvent?.clickCount ?? 1
            if clickCount >= 2 || store.settings.singleClickToOpen {
                store.navigate(to: .network)
            }
        }
    }

    private func iconKind(for volumeKind: VolumeKind) -> FluentIconKind {
        switch volumeKind {
        case .internalDrive: return .hardDrive
        case .externalDrive: return .externalDrive
        case .networkDrive: return .networkDrive
        case .cloudDrive: return .cloudDrive
        }
    }
}
