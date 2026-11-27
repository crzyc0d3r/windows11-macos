import AppKit
import FileExplorerCore
import QuickLookThumbnailing
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
            iconContent
                .frame(width: size, height: size)

            if isSymlink && kind != .symlinkBadge {
                Image(systemName: "arrow.uturn.forward.square.fill")
                    .font(.system(size: max(8, size * 0.34), weight: .semibold))
                    .foregroundStyle(.white, Color(red: 0.0, green: 0.47, blue: 0.84))
                    .offset(x: -1, y: 1)
            }
        }
        .opacity(isCut ? 0.5 : 1.0)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var iconContent: some View {
        switch kind {
        case .folder, .folderPopulated:
            folderGlyph(badgeSystemName: nil, badgeColor: nil, populated: kind == .folderPopulated)
        case .desktop:
            folderGlyph(badgeSystemName: "menubar.dock.rectangle", badgeColor: Color(red: 0.0, green: 0.47, blue: 0.84), populated: true)
        case .downloads:
            folderGlyph(badgeSystemName: "arrow.down.circle.fill", badgeColor: Color(red: 0.05, green: 0.56, blue: 0.85), populated: true)
        case .documents:
            folderGlyph(badgeSystemName: "doc.text.fill", badgeColor: Color(red: 0.16, green: 0.50, blue: 0.73), populated: true)
        case .pictures:
            folderGlyph(badgeSystemName: "photo.fill", badgeColor: Color(red: 0.14, green: 0.65, blue: 0.76), populated: true)
        case .music:
            folderGlyph(badgeSystemName: "music.note", badgeColor: Color(red: 0.60, green: 0.29, blue: 0.78), populated: true)
        case .videos:
            folderGlyph(badgeSystemName: "film.fill", badgeColor: Color(red: 0.49, green: 0.33, blue: 0.85), populated: true)
        case .applications:
            folderGlyph(badgeSystemName: "square.grid.2x2.fill", badgeColor: Color(red: 0.15, green: 0.45, blue: 0.85), populated: true)
        case .home:
            Image(systemName: "house.fill")
                .resizable()
                .scaledToFit()
                .padding(size * 0.1)
                .foregroundStyle(Color(red: 0.00, green: 0.47, blue: 0.84))
        case .gallery:
            Image(systemName: "photo.on.rectangle.angled")
                .resizable()
                .scaledToFit()
                .padding(size * 0.1)
                .foregroundStyle(Color(red: 0.10, green: 0.62, blue: 0.82))
        case .thisPC:
            Image(systemName: "desktopcomputer")
                .resizable()
                .scaledToFit()
                .padding(size * 0.08)
                .foregroundStyle(Color(red: 0.16, green: 0.52, blue: 0.86))
        case .hardDrive:
            Image(systemName: "internaldrive.fill")
                .resizable()
                .scaledToFit()
                .padding(size * 0.1)
                .foregroundStyle(Color(red: 0.44, green: 0.49, blue: 0.56))
        case .externalDrive:
            Image(systemName: "externaldrive.fill")
                .resizable()
                .scaledToFit()
                .padding(size * 0.1)
                .foregroundStyle(Color(red: 0.25, green: 0.56, blue: 0.78))
        case .networkDrive:
            Image(systemName: "externaldrive.connected.to.line.below.fill")
                .resizable()
                .scaledToFit()
                .padding(size * 0.1)
                .foregroundStyle(Color(red: 0.18, green: 0.58, blue: 0.64))
        case .cloudDrive:
            Image(systemName: "cloud.fill")
                .resizable()
                .scaledToFit()
                .padding(size * 0.08)
                .foregroundStyle(Color(red: 0.15, green: 0.58, blue: 0.94))
        case .recycleBinEmpty:
            Image(systemName: "trash")
                .resizable()
                .scaledToFit()
                .padding(size * 0.12)
                .foregroundStyle(Color(red: 0.46, green: 0.50, blue: 0.56))
        case .recycleBinFull:
            Image(systemName: "trash.fill")
                .resizable()
                .scaledToFit()
                .padding(size * 0.12)
                .foregroundStyle(Color(red: 0.24, green: 0.51, blue: 0.80))
        case .symlinkBadge:
            Image(systemName: "arrow.uturn.forward.square.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color(red: 0.00, green: 0.47, blue: 0.84))
        case .fileKind(let fileKind):
            fileKindGlyph(fileKind)
        }
    }

    private func folderGlyph(badgeSystemName: String?, badgeColor: Color?, populated: Bool) -> some View {
        let backGold = Color(red: 0.92, green: 0.67, blue: 0.15)
        let frontGold = Color(red: 0.99, green: 0.80, blue: 0.29)
        return ZStack {
            Image(systemName: populated ? "folder.fill" : "folder.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(
                    LinearGradient(
                        colors: [frontGold, backGold],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            if let badgeSystemName, let badgeColor {
                Image(systemName: badgeSystemName)
                    .font(.system(size: max(7, size * 0.34), weight: .semibold))
                    .foregroundStyle(badgeColor)
                    .offset(y: size * 0.06)
            }
        }
    }

    @ViewBuilder
    private func fileKindGlyph(_ fileKind: FileKind) -> some View {
        switch fileKind {
        case .folder:
            folderGlyph(badgeSystemName: nil, badgeColor: nil, populated: false)
        case .application:
            symbol("app.badge.fill", color: Color(red: 0.16, green: 0.52, blue: 0.90))
        case .image:
            symbol("photo.fill", color: Color(red: 0.14, green: 0.65, blue: 0.76))
        case .video:
            symbol("film.fill", color: Color(red: 0.53, green: 0.34, blue: 0.86))
        case .audio:
            symbol("waveform.circle.fill", color: Color(red: 0.85, green: 0.32, blue: 0.56))
        case .pdf:
            symbol("doc.richtext.fill", color: Color(red: 0.83, green: 0.21, blue: 0.19))
        case .document:
            symbol("doc.text.fill", color: Color(red: 0.12, green: 0.45, blue: 0.80))
        case .spreadsheet:
            symbol("tablecells.fill", color: Color(red: 0.12, green: 0.56, blue: 0.32))
        case .presentation:
            symbol("rectangle.on.rectangle.angled", color: Color(red: 0.84, green: 0.42, blue: 0.16))
        case .code:
            symbol("chevron.left.forwardslash.chevron.right", color: Color(red: 0.22, green: 0.53, blue: 0.86))
        case .json:
            symbol("curlybraces", color: Color(red: 0.72, green: 0.50, blue: 0.10))
        case .markdown:
            symbol("doc.plaintext.fill", color: Color(red: 0.34, green: 0.44, blue: 0.62))
        case .text:
            symbol("doc.plaintext", color: Color(red: 0.45, green: 0.49, blue: 0.55))
        case .archive:
            symbol("doc.zipper", color: Color(red: 0.75, green: 0.52, blue: 0.14))
        case .diskImage:
            symbol("opticaldiscdrive.fill", color: Color(red: 0.45, green: 0.49, blue: 0.55))
        case .symlink:
            symbol("link", color: Color(red: 0.00, green: 0.47, blue: 0.84))
        case .other:
            symbol("doc.fill", color: Color(red: 0.48, green: 0.52, blue: 0.58))
        }
    }

    private func symbol(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .resizable()
            .scaledToFit()
            .padding(size * 0.1)
            .foregroundStyle(color)
    }
}

public struct FileThumbnailView: View {
    public let item: FileItem
    public let size: CGFloat
    public let isCut: Bool

    @State private var thumbnailImage: NSImage?

    public init(item: FileItem, size: CGFloat = 48, isCut: Bool = false) {
        self.item = item
        self.size = size
        self.isCut = isCut
    }

    public var body: some View {
        Group {
            if let thumbnailImage {
                Image(nsImage: thumbnailImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .opacity(isCut ? 0.5 : 1.0)
            } else {
                FluentIconView(
                    kind: .forItem(item),
                    size: size,
                    isCut: isCut,
                    isSymlink: item.isSymlink
                )
            }
        }
        .frame(width: size, height: size)
        .task(id: item.thumbnailKey) {
            await loadThumbnailIfApplicable()
        }
    }

    private func loadThumbnailIfApplicable() async {
        guard !item.isDirectory,
              size >= 32,
              FileManager.default.fileExists(atPath: item.url.path) else {
            return
        }
        let targetSize = CGSize(width: size * 2, height: size * 2)
        let url = item.url
        let loaded: NSImage? = await Task.detached(priority: .utility) {
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: targetSize,
                scale: 2.0,
                representationTypes: .thumbnail
            )
            return await withCheckedContinuation { continuation in
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                    continuation.resume(returning: rep?.nsImage)
                }
            }
        }.value
        if !Task.isCancelled, let loaded {
            thumbnailImage = loaded
        }
    }
}
