import AppKit
import AVFoundation
import FileExplorerCore
import FileExplorerDesign
import ImageIO
import PDFKit
import QuickLookUI
import SwiftUI

public struct PreviewPaneView: View {
    public let store: ExplorerStore

    @Environment(\.fluentTheme) private var theme
    @State private var loadedPreview: PreviewPayload?
    @State private var isLoading: Bool = false

    public init(store: ExplorerStore) {
        self.store = store
    }

    public var body: some View {
        let targetItem = store.primarySelectedItem ?? store.selectedItems.first
        Group {
            if let item = targetItem {
                VStack(spacing: 0) {
                    previewHeader(item: item)
                    Divider()
                        .overlay(theme.palette.borderSubtle)
                    previewBody(item: item)
                }
                .task(id: "\(item.thumbnailKey):\(store.snapshotMode)") {
                    isLoading = true
                    let payload = await PreviewContentLoader.load(for: item, store: store)
                    if !Task.isCancelled {
                        loadedPreview = payload
                        isLoading = false
                    }
                }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(theme.palette.textSecondary)

            Text("Select a file to preview")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(theme.palette.textSecondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func previewHeader(item: FileItem) -> some View {
        HStack(spacing: 8) {
            FluentIconView(kind: .forItem(item), size: 20, isSymlink: item.isSymlink)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                Text("\(item.typeDescription) · \(item.isDirectory && !item.isPackage ? "\(item.childCount ?? 0) items" : InspectorFormatters.formatBytes(item.size))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                store.openItem(item)
            } label: {
                Text("Open")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.palette.accentBlue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(theme.palette.selectionFill)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.palette.cardSurface)
    }

    @ViewBuilder
    private func previewBody(item: FileItem) -> some View {
        if item.isDirectory && !item.isPackage {
            folderPreviewCard(item: item)
        } else if let payload = loadedPreview, payload.url == item.url {
            switch payload.content {
            case .image(let image, let dimensions):
                imagePreviewView(image: image, dimensions: dimensions)
            case .text(let snippet, let byteCount, let truncated):
                textPreviewView(text: snippet, byteCount: byteCount, truncated: truncated)
            case .pdf(let pages, let totalPages, let author):
                pdfPreviewView(pages: pages, totalPages: totalPages, author: author)
            case .media(let duration, let codec, let dimensions, let showQuickLook):
                mediaPreviewView(item: item, duration: duration, codec: codec, dimensions: dimensions, showQuickLook: showQuickLook)
            case .quickLook(let url):
                if !store.snapshotMode && FileManager.default.fileExists(atPath: url.path) {
                    QuickLookPreviewRepresentable(url: url)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    fallbackCardPreview(item: item)
                }
            case .fallback:
                fallbackCardPreview(item: item)
            }
        } else if isLoading {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading preview...")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            fallbackCardPreview(item: item)
        }
    }

    private func imagePreviewView(image: NSImage, dimensions: String?) -> some View {
        VStack(spacing: 0) {
            ZStack {
                theme.palette.contentCanvas
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(14)
                    .shadow(color: Color.black.opacity(0.14), radius: 8, y: 3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let dimensions {
                Divider()
                    .overlay(theme.palette.borderSubtle)
                HStack {
                    Image(systemName: "aspectratio")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.palette.textSecondary)
                    Text(dimensions)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.palette.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(theme.palette.cardSurface)
            }
        }
    }

    private func textPreviewView(text: String, byteCount: Int, truncated: Bool) -> some View {
        VStack(spacing: 0) {
            ScrollView([.vertical, .horizontal]) {
                Text(text.isEmpty ? "(Empty file)" : text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(text.isEmpty ? theme.palette.textSecondary : theme.palette.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .background(theme.palette.contentCanvas)

            Divider()
                .overlay(theme.palette.borderSubtle)
            HStack {
                Text(truncated ? "Showing first 64 KB" : "UTF-8 · \(InspectorFormatters.formatBytes(Int64(byteCount)))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.palette.textSecondary)
                Spacer()
                let lines = text.isEmpty ? 0 : text.components(separatedBy: .newlines).count
                Text("\(lines) lines")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.palette.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(theme.palette.cardSurface)
        }
    }

    private func pdfPreviewView(pages: [NSImage], totalPages: Int, author: String?) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, pageImage in
                        VStack(spacing: 4) {
                            Image(nsImage: pageImage)
                                .resizable()
                                .scaledToFit()
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .stroke(theme.palette.borderSubtle, lineWidth: 1)
                                )
                                .shadow(color: Color.black.opacity(0.12), radius: 5, y: 2)

                            Text("Page \(index + 1) of \(totalPages)")
                                .font(.system(size: 10.5))
                                .foregroundStyle(theme.palette.textSecondary)
                        }
                    }
                }
                .padding(12)
            }
            .background(theme.palette.contentCanvas)

            Divider()
                .overlay(theme.palette.borderSubtle)
            HStack {
                Text("\(totalPages) \(totalPages == 1 ? "page" : "pages")")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.palette.textSecondary)
                if let author, !author.isEmpty {
                    Text("· \(author)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(theme.palette.cardSurface)
        }
    }

    private func mediaPreviewView(
        item: FileItem,
        duration: String?,
        codec: String?,
        dimensions: String?,
        showQuickLook: Bool
    ) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                if showQuickLook && !store.snapshotMode && FileManager.default.fileExists(atPath: item.url.path) {
                    QuickLookPreviewRepresentable(url: item.url)
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(theme.palette.borderSubtle, lineWidth: 1)
                        )
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(theme.palette.cardSurface)
                            .frame(height: 150)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(theme.palette.borderSubtle, lineWidth: 1)
                            )
                        VStack(spacing: 8) {
                            FluentIconView(kind: .forItem(item), size: 64)
                            Text(item.kind == .video ? "Video Media" : "Audio Track")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(theme.palette.textSecondary)
                        }
                    }
                }

                InspectorSectionCard(title: "Media Details") {
                    VStack(alignment: .leading, spacing: 7) {
                        if let duration {
                            InspectorKeyValueRow(label: "Duration", value: duration)
                        }
                        if let codec {
                            InspectorKeyValueRow(label: "Codec", value: codec)
                        }
                        if let dimensions {
                            InspectorKeyValueRow(label: "Resolution", value: dimensions)
                        }
                        InspectorKeyValueRow(label: "File size", value: InspectorFormatters.formatBytes(item.size))
                    }
                }
            }
            .padding(14)
        }
    }

    private func folderPreviewCard(item: FileItem) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                FluentIconView(kind: .forItem(item), size: 88)
                    .padding(.top, 16)
                Text(item.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                if let count = item.childCount {
                    Text("\(count) items inside")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.textSecondary)
                }
                InspectorSectionCard(title: "Folder") {
                    VStack(alignment: .leading, spacing: 6) {
                        InspectorKeyValueRow(label: "Path", value: item.url.path)
                        InspectorKeyValueRow(label: "Modified", value: InspectorFormatters.formatDate(item.dateModified))
                    }
                }
            }
            .padding(14)
        }
    }

    private func fallbackCardPreview(item: FileItem) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                FileThumbnailView(item: item, size: 112)
                    .padding(.top, 18)

                Text(item.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                    .multilineTextAlignment(.center)

                Text("No live preview available for this item")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.textSecondary)

                InspectorSectionCard(title: "File Info") {
                    VStack(alignment: .leading, spacing: 6) {
                        InspectorKeyValueRow(label: "Type", value: item.typeDescription)
                        InspectorKeyValueRow(label: "Size", value: InspectorFormatters.formatDetailedBytes(item.size))
                        InspectorKeyValueRow(label: "Modified", value: InspectorFormatters.formatDate(item.dateModified))
                    }
                }
            }
            .padding(14)
        }
    }
}

private struct PreviewPayload {
    enum Content {
        case image(NSImage, dimensions: String?)
        case text(String, byteCount: Int, truncated: Bool)
        case pdf(pages: [NSImage], totalPages: Int, author: String?)
        case media(duration: String?, codec: String?, dimensions: String?, showQuickLook: Bool)
        case quickLook(URL)
        case fallback
    }

    let url: URL
    let content: Content
}

private enum PreviewContentLoader {
    private static let maxTextBytes = 65_536

    @MainActor
    static func load(for item: FileItem, store: ExplorerStore) async -> PreviewPayload {
        let url = item.url
        let exists = FileManager.default.fileExists(atPath: url.path)

        if !exists || store.snapshotMode {
            if let snapshotContent = makeSnapshotOrSyntheticPreview(for: item, metadata: await store.loadMetadata(for: url)) {
                return PreviewPayload(url: url, content: snapshotContent)
            }
            return PreviewPayload(url: url, content: .fallback)
        }

        switch item.kind {
        case .image:
            let loaded: (NSImage, String?)? = await Task.detached(priority: .userInitiated) {
                guard let image = NSImage(contentsOf: url) else { return nil }
                var dims: String?
                if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                   let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                   let w = props[kCGImagePropertyPixelWidth] as? Int,
                   let h = props[kCGImagePropertyPixelHeight] as? Int {
                    dims = "\(w) × \(h)"
                }
                return (image, dims)
            }.value
            if let (image, dims) = loaded {
                return PreviewPayload(url: url, content: .image(image, dimensions: dims))
            }
            return PreviewPayload(url: url, content: .quickLook(url))

        case .text, .code, .json, .markdown:
            let textLoaded: (String, Int, Bool)? = await Task.detached(priority: .userInitiated) {
                guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
                defer { try? handle.close() }
                guard let data = try? handle.read(upToCount: maxTextBytes + 1) else { return nil }
                let truncated = data.count > maxTextBytes
                let slice = truncated ? data.prefix(maxTextBytes) : data[...]
                let string = String(decoding: slice, as: UTF8.self)
                return (string, slice.count, truncated)
            }.value
            if let (text, byteCount, truncated) = textLoaded {
                return PreviewPayload(url: url, content: .text(text, byteCount: byteCount, truncated: truncated))
            }
            return PreviewPayload(url: url, content: .quickLook(url))

        case .pdf:
            let pdfLoaded: ([NSImage], Int, String?)? = await Task.detached(priority: .userInitiated) {
                guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { return nil }
                let renderLimit = min(doc.pageCount, 8)
                var images: [NSImage] = []
                images.reserveCapacity(renderLimit)
                for idx in 0..<renderLimit {
                    if let page = doc.page(at: idx) {
                        let bounds = page.bounds(for: .mediaBox)
                        let targetWidth: CGFloat = 640
                        let scale = bounds.width > 0 ? (targetWidth / bounds.width) : 1
                        let targetSize = CGSize(width: targetWidth, height: max(200, bounds.height * scale))
                        let thumb = page.thumbnail(of: targetSize, for: .mediaBox)
                        images.append(thumb)
                    }
                }
                let author = doc.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String
                return (images, doc.pageCount, author)
            }.value
            if let (pages, total, author) = pdfLoaded, !pages.isEmpty {
                return PreviewPayload(url: url, content: .pdf(pages: pages, totalPages: total, author: author))
            }
            return PreviewPayload(url: url, content: .quickLook(url))

        case .audio, .video:
            let meta = await store.loadMetadata(for: url)
            return PreviewPayload(
                url: url,
                content: .media(
                    duration: meta?.mediaDuration,
                    codec: meta?.mediaCodec,
                    dimensions: meta?.dimensions,
                    showQuickLook: true
                )
            )

        default:
            return PreviewPayload(url: url, content: .quickLook(url))
        }
    }

    private static func makeSnapshotOrSyntheticPreview(for item: FileItem, metadata: FileMetadata?) -> PreviewPayload.Content? {
        switch item.kind {
        case .code, .markdown, .json, .text:
            let sample: String
            if item.name == "Package.swift" {
                sample = """
                // swift-tools-version: 6.0
                import PackageDescription

                let package = Package(
                    name: "FileExplorer",
                    platforms: [.macOS(.v15)],
                    products: [
                        .executable(name: "FileExplorerApp", targets: ["FileExplorerApp"])
                    ]
                )
                """
            } else if item.kind == .markdown {
                sample = """
                # \(item.displayName)

                Windows 11 24H2-inspired File Explorer for macOS.

                - Dual-pane navigation & tabs
                - Quick Look & rich Inspector panes
                - Real POSIX permissions & file operations
                """
            } else if item.kind == .json {
                sample = "{\n  \"name\": \"\(item.name)\",\n  \"size\": \(item.size)\n}"
            } else {
                sample = "\(item.displayName)\n\(item.typeDescription)"
            }
            return .text(sample, byteCount: sample.utf8.count, truncated: false)

        case .image:
            let image = renderSnapshotHeroBanner(title: item.displayName, dimensions: metadata?.dimensions ?? "2560 × 1440")
            return .image(image, dimensions: metadata?.dimensions ?? "2560 × 1440")

        case .pdf:
            let page = renderSnapshotPDFPage(title: item.displayName, pages: metadata?.pdfPageCount ?? 14)
            return .pdf(pages: [page], totalPages: metadata?.pdfPageCount ?? 14, author: "Architecture Team")

        case .audio, .video:
            return .media(
                duration: metadata?.mediaDuration ?? "02:34",
                codec: metadata?.mediaCodec ?? "HEVC / AAC",
                dimensions: metadata?.dimensions,
                showQuickLook: false
            )

        default:
            return .fallback
        }
    }

    private static func renderSnapshotHeroBanner(title: String, dimensions: String) -> NSImage {
        let size = NSSize(width: 480, height: 300)
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        let gradient = NSGradient(
            colors: [
                NSColor(calibratedRed: 0.08, green: 0.36, blue: 0.72, alpha: 1.0),
                NSColor(calibratedRed: 0.14, green: 0.62, blue: 0.86, alpha: 1.0),
                NSColor(calibratedRed: 0.45, green: 0.78, blue: 0.96, alpha: 1.0)
            ]
        )
        gradient?.draw(in: rect, angle: -35)

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85)
        ]
        (title as NSString).draw(at: NSPoint(x: 28, y: 150), withAttributes: titleAttrs)
        (dimensions as NSString).draw(at: NSPoint(x: 28, y: 124), withAttributes: subAttrs)
        image.unlockFocus()
        return image
    }

    private static func renderSnapshotPDFPage(title: String, pages: Int) -> NSImage {
        let size = NSSize(width: 420, height: 540)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()

        NSColor(calibratedRed: 0.00, green: 0.40, blue: 0.75, alpha: 1.0).setFill()
        NSRect(x: 32, y: 470, width: 356, height: 4).fill()

        let headingAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 20, weight: .bold),
            .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1.0)
        ]
        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.35, alpha: 1.0)
        ]
        (title as NSString).draw(at: NSPoint(x: 32, y: 432), withAttributes: headingAttrs)
        ("Document Overview · \(pages) pages" as NSString).draw(at: NSPoint(x: 32, y: 406), withAttributes: bodyAttrs)

        NSColor(calibratedWhite: 0.88, alpha: 1.0).setFill()
        for idx in 0..<8 {
            let y = 350 - idx * 34
            let width = idx % 3 == 2 ? 260 : 356
            NSRect(x: 32, y: y, width: width, height: 10).fill()
        }
        image.unlockFocus()
        return image
    }
}

private struct QuickLookPreviewRepresentable: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        if (nsView.previewItem as? URL) != url {
            nsView.previewItem = url as NSURL
        }
    }
}
