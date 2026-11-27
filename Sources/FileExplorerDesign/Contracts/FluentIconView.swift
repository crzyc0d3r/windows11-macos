import AppKit
import FileExplorerCore
import SwiftUI

public enum FluentIconKind: Sendable, Hashable {
    case folder
    case folderPopulated
    case home
    case gallery
    case desktop
    case downloads
    case documents
    case pictures
    case music
    case videos
    case applications
    case thisPC
    case hardDrive
    case externalDrive
    case networkDrive
    case cloudDrive
    case recycleBinEmpty
    case recycleBinFull
    case symlinkBadge
    case fileKind(FileKind)

    public init(locationIcon: LocationIconKind, isTrashEmpty: Bool = true) {
        switch locationIcon {
        case .home: self = .home
        case .gallery: self = .gallery
        case .thisPC: self = .thisPC
        case .recycleBin: self = isTrashEmpty ? .recycleBinEmpty : .recycleBinFull
        case .network: self = .networkDrive
        case .folder: self = .folder
        case .desktop: self = .desktop
        case .downloads: self = .downloads
        case .documents: self = .documents
        case .pictures: self = .pictures
        case .music: self = .music
        case .videos: self = .videos
        case .applications: self = .applications
        case .search: self = .fileKind(.other)
        case .cloudDrive: self = .cloudDrive
        case .hardDrive: self = .hardDrive
        case .externalDrive: self = .externalDrive
        case .networkDrive: self = .networkDrive
        }
    }

    public static func forItem(_ item: FileItem) -> FluentIconKind {
        if item.isDirectory && !item.isPackage {
            let locKind = ExplorerLocation.folder(item.url).iconKind
            if locKind != .folder {
                return FluentIconKind(locationIcon: locKind)
            }
            return (item.childCount ?? 0) > 0 ? .folderPopulated : .folder
        }
        return .fileKind(item.kind)
    }
}

public struct FluentIconView: View {
    public let kind: FluentIconKind
    public let size: CGFloat
    public let isCut: Bool
    public let isSymlink: Bool

    @Environment(\.fluentTheme) private var theme

    public init(
        kind: FluentIconKind,
        size: CGFloat = 20,
        isCut: Bool = false,
        isSymlink: Bool = false
    ) {
        self.kind = kind
        self.size = size
        self.isCut = isCut
        self.isSymlink = isSymlink
    }

    public var body: some View {
        ZStack(alignment: .bottomLeading) {
            FluentIconCatalogView(kind: kind, isDark: theme.isDark)
                .frame(width: size, height: size)

            if isSymlink && kind != .symlinkBadge {
                FluentSymlinkCornerBadge(badgeSize: max(8, size * 0.36))
                    .offset(x: -1, y: 1)
            }
        }
        .opacity(isCut ? 0.5 : 1.0)
        .accessibilityHidden(true)
    }
}

public struct FileThumbnailView: View {
    public let item: FileItem
    public let size: CGFloat
    public let isCut: Bool

    @Environment(\.fluentTheme) private var theme
    @State private var asyncThumbnail: CGImage?

    public init(item: FileItem, size: CGFloat = 48, isCut: Bool = false) {
        self.item = item
        self.size = size
        self.isCut = isCut
    }

    public var body: some View {
        let resolvedImage = asyncThumbnail ?? ThumbnailProvider.shared.synchronousThumbnail(for: item, size: size)

        ZStack(alignment: .bottomLeading) {
            if let resolvedImage {
                let cornerRadius: CGFloat = size >= 48 ? 6 : 4
                Image(decorative: resolvedImage, scale: 2.0)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(theme.palette.borderSubtle, lineWidth: 1)
                    )
            } else {
                FluentIconView(
                    kind: .forItem(item),
                    size: size,
                    isCut: false,
                    isSymlink: false
                )
            }

            if item.isSymlink {
                FluentSymlinkCornerBadge(badgeSize: max(8, size * 0.34))
                    .offset(x: -1, y: 1)
            }
        }
        .frame(width: size, height: size)
        .opacity(isCut ? 0.5 : 1.0)
        .accessibilityHidden(true)
        .task(id: "\(item.thumbnailKey):\(Int(ceil(size)))") {
            guard resolvedImage == nil else { return }
            let loaded = await ThumbnailProvider.shared.thumbnail(for: item, size: size)
            if !Task.isCancelled, let loaded {
                asyncThumbnail = loaded
            }
        }
    }
}
