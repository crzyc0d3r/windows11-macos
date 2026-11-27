import AppKit
import AVFoundation
import FileExplorerCore
import FileExplorerDesign
import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

enum InspectorFormatters {
    @MainActor
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        return formatter
    }()

    @MainActor
    private static let decimalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    @MainActor
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    @MainActor
    static func formatBytes(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: max(0, bytes))
    }

    @MainActor
    static func formatDetailedBytes(_ bytes: Int64) -> String {
        let human = formatBytes(bytes)
        let exact = decimalFormatter.string(from: NSNumber(value: max(0, bytes))) ?? "\(bytes)"
        return "\(human) (\(exact) bytes)"
    }

    @MainActor
    static func formatDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    @MainActor
    static func resolveItem(for url: URL, in store: ExplorerStore) -> FileItem {
        if let existing = store.currentItems.first(where: { $0.url == url })
            ?? store.favoriteFiles.first(where: { $0.url == url }) {
            return existing
        }

        let stdURL = url.standardizedFileURL
        let fm = FileManager.default
        if fm.fileExists(atPath: stdURL.path) {
            let keys: Set<URLResourceKey> = [
                .nameKey,
                .localizedNameKey,
                .isDirectoryKey,
                .isPackageKey,
                .isSymbolicLinkKey,
                .isHiddenKey,
                .isWritableKey,
                .fileSizeKey,
                .contentModificationDateKey,
                .creationDateKey,
                .localizedTypeDescriptionKey,
                .contentTypeKey
            ]
            let values = try? stdURL.resourceValues(forKeys: keys)
            let isDir = values?.isDirectory ?? stdURL.hasDirectoryPath
            let isPkg = values?.isPackage ?? false
            let isSymlink = values?.isSymbolicLink ?? false
            let isHidden = values?.isHidden ?? stdURL.lastPathComponent.hasPrefix(".")
            let isReadOnly = !(values?.isWritable ?? true)
            let size = Int64(values?.fileSize ?? 0)
            let modified = values?.contentModificationDate ?? Date()
            let created = values?.creationDate ?? modified
            let typeDesc = values?.localizedTypeDescription ?? (isDir ? "File folder" : "File")
            let attrs = try? fm.attributesOfItem(atPath: stdURL.path)
            let mode = (attrs?[.posixPermissions] as? NSNumber)?.uint16Value
            let perms = mode.map { POSIXPermissions(mode: $0) }
            let kind = inferFileKind(
                url: stdURL,
                isDirectory: isDir,
                isPackage: isPkg,
                isSymlink: isSymlink,
                contentType: values?.contentType
            )
            return FileItem(
                url: stdURL,
                name: values?.name ?? stdURL.lastPathComponent,
                displayName: values?.localizedName ?? stdURL.lastPathComponent,
                fileExtension: isDir && !isPkg ? "" : stdURL.pathExtension.lowercased(),
                kind: kind,
                isDirectory: isDir,
                isHidden: isHidden,
                isSymlink: isSymlink,
                isPackage: isPkg,
                isReadOnly: isReadOnly,
                size: size,
                dateModified: modified,
                dateCreated: created,
                typeDescription: typeDesc,
                posixPermissions: perms
            )
        }

        let isDir = stdURL.hasDirectoryPath
        return FileItem(
            url: stdURL,
            kind: isDir ? .folder : inferFileKind(url: stdURL, isDirectory: false, isPackage: false, isSymlink: false, contentType: nil),
            isDirectory: isDir,
            typeDescription: isDir ? "File folder" : "File"
        )
    }

    static func inferFileKind(
        url: URL,
        isDirectory: Bool,
        isPackage: Bool,
        isSymlink: Bool,
        contentType: UTType?
    ) -> FileKind {
        if isSymlink { return .symlink }
        if isPackage && url.pathExtension.lowercased() == "app" { return .application }
        if isDirectory && !isPackage { return .folder }

        let ext = url.pathExtension.lowercased()
        switch ext {
        case "app": return .application
        case "pdf": return .pdf
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "svg": return .image
        case "mp4", "mov", "mkv", "avi", "m4v", "webm": return .video
        case "mp3", "m4a", "wav", "flac", "aac", "ogg", "aiff": return .audio
        case "md", "markdown": return .markdown
        case "json": return .json
        case "txt", "log", "rtf", "csv": return .text
        case "swift", "py", "js", "ts", "tsx", "jsx", "rs", "go", "c", "cpp", "h", "hpp", "java", "kt", "sh", "zsh", "yaml", "yml", "toml", "xml", "html", "css":
            return .code
        case "doc", "docx", "pages": return .document
        case "xls", "xlsx", "numbers": return .spreadsheet
        case "ppt", "pptx", "key": return .presentation
        case "zip", "tar", "gz", "tgz", "7z", "rar": return .archive
        case "dmg", "iso": return .diskImage
        default:
            if let contentType {
                if contentType.conforms(to: .image) { return .image }
                if contentType.conforms(to: .movie) { return .video }
                if contentType.conforms(to: .audio) { return .audio }
                if contentType.conforms(to: .pdf) { return .pdf }
                if contentType.conforms(to: .sourceCode) { return .code }
                if contentType.conforms(to: .json) { return .json }
                if contentType.conforms(to: .plainText) { return .text }
                if contentType.conforms(to: .archive) { return .archive }
            }
            return .other
        }
    }

    @MainActor
    static func shareItems(_ urls: [URL], from anchorView: NSView? = nil) {
        guard !urls.isEmpty else { return }
        let picker = NSSharingServicePicker(items: urls)
        if let view = anchorView ?? NSApp.keyWindow?.contentView {
            let rect = NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
        }
    }

    static func openInTerminal(url: URL, isDirectory: Bool) {
        let folderURL = isDirectory ? url : url.deletingLastPathComponent()
        let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([folderURL], withApplicationAt: terminalURL, configuration: config)
    }

    static func copyPathsToPasteboard(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let joined = urls.map(\.path).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(joined, forType: .string)
    }

    static func copyStringToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

struct EnrichedInspectorInfo: Sendable, Hashable {
    var metadata: FileMetadata
    var pdfAuthor: String?
    var pdfTitle: String?
    var allocatedSizeBytes: Int64?
}

enum InspectorMetadataLoader {
    @MainActor
    static func load(for item: FileItem, store: ExplorerStore) async -> EnrichedInspectorInfo {
        let baseMeta = await store.loadMetadata(for: item.url)
        let url = item.url
        let isSnapshot = store.snapshotMode

        if isSnapshot || !FileManager.default.fileExists(atPath: url.path) {
            let fallbackMeta = baseMeta ?? FileMetadata(item: item)
            let sampleAuthor = item.kind == .pdf ? "Product Architecture Team" : nil
            return EnrichedInspectorInfo(
                metadata: fallbackMeta,
                pdfAuthor: sampleAuthor,
                pdfTitle: item.kind == .pdf ? item.displayName : nil,
                allocatedSizeBytes: fallbackMeta.folderSizeBytes ?? item.size
            )
        }

        let extra = await Task.detached(priority: .utility) {
            inspectDiskExtras(for: item, existing: baseMeta)
        }.value

        return extra
    }

    private static func inspectDiskExtras(for item: FileItem, existing: FileMetadata?) -> EnrichedInspectorInfo {
        let url = item.url
        var dimensions = existing?.dimensions
        var exifSummary = existing?.exifSummary ?? []
        var pdfPageCount = existing?.pdfPageCount
        var pdfAuthor: String?
        var pdfTitle: String?
        var lineCount = existing?.lineCount
        var folderSizeBytes = existing?.folderSizeBytes
        var folderFileCount = existing?.folderFileCount
        var folderSubfolderCount = existing?.folderSubfolderCount
        var defaultAppName = existing?.defaultAppName
        var defaultAppURL = existing?.defaultAppURL
        var openWithApps = existing?.openWithApps ?? []

        let allocatedSizeBytes: Int64? = {
            let vals = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            if let total = vals?.totalFileAllocatedSize ?? vals?.fileAllocatedSize {
                return Int64(total)
            }
            return item.isDirectory ? nil : item.size
        }()

        if item.isDirectory && !item.isPackage && folderSizeBytes == nil {
            let stats = computeFolderStats(at: url)
            folderSizeBytes = stats.totalBytes
            folderFileCount = stats.fileCount
            folderSubfolderCount = stats.folderCount
        }

        if item.kind == .image, (dimensions == nil || exifSummary.isEmpty) {
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                if dimensions == nil,
                   let width = props[kCGImagePropertyPixelWidth] as? Int,
                   let height = props[kCGImagePropertyPixelHeight] as? Int {
                    dimensions = "\(width) × \(height)"
                }
                if exifSummary.isEmpty {
                    var pairs: [(String, String)] = []
                    if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                        let make = tiff[kCGImagePropertyTIFFMake] as? String
                        let model = tiff[kCGImagePropertyTIFFModel] as? String
                        let combined = [make, model].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                        if !combined.isEmpty {
                            pairs.append(("Camera", combined))
                        }
                    }
                    if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                        if let focal = exif[kCGImagePropertyExifFocalLength] as? Double {
                            pairs.append(("Focal length", String(format: "%.1f mm", focal)))
                        }
                        if let fNumber = exif[kCGImagePropertyExifFNumber] as? Double {
                            pairs.append(("Aperture", String(format: "f/%.1f", fNumber)))
                        }
                        if let isoList = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int], let iso = isoList.first {
                            pairs.append(("ISO", "\(iso)"))
                        }
                    }
                    if let profile = props[kCGImagePropertyProfileName] as? String {
                        pairs.append(("Color profile", profile))
                    }
                    exifSummary = pairs
                }
            }
        }

        if item.kind == .pdf, let doc = PDFDocument(url: url) {
            if pdfPageCount == nil {
                pdfPageCount = doc.pageCount
            }
            if let attrs = doc.documentAttributes {
                pdfAuthor = attrs[PDFDocumentAttribute.authorAttribute] as? String
                pdfTitle = attrs[PDFDocumentAttribute.titleAttribute] as? String
            }
        }

        if (item.kind == .text || item.kind == .code || item.kind == .json || item.kind == .markdown), lineCount == nil {
            if let handle = try? FileHandle(forReadingFrom: url) {
                defer { try? handle.close() }
                if let data = try? handle.read(upToCount: 512 * 1024),
                   let str = String(data: data, encoding: .utf8) {
                    lineCount = str.isEmpty ? 0 : str.components(separatedBy: .newlines).count
                }
            }
        }

        if defaultAppURL == nil {
            defaultAppURL = NSWorkspace.shared.urlForApplication(toOpen: url)
            defaultAppName = defaultAppURL?.deletingPathExtension().lastPathComponent ?? defaultAppName
        }

        if openWithApps.isEmpty && !item.isDirectory {
            let appURLs = NSWorkspace.shared.urlsForApplications(toOpen: url)
            openWithApps = appURLs.prefix(12).map {
                AppChoice(url: $0, name: $0.deletingPathExtension().lastPathComponent)
            }
        }

        let merged = FileMetadata(
            item: item,
            dimensions: dimensions,
            exifSummary: exifSummary,
            mediaDuration: existing?.mediaDuration,
            mediaCodec: existing?.mediaCodec,
            pdfPageCount: pdfPageCount,
            lineCount: lineCount,
            folderSizeBytes: folderSizeBytes,
            folderFileCount: folderFileCount,
            folderSubfolderCount: folderSubfolderCount,
            defaultAppName: defaultAppName,
            defaultAppURL: defaultAppURL,
            openWithApps: openWithApps
        )

        return EnrichedInspectorInfo(
            metadata: merged,
            pdfAuthor: pdfAuthor,
            pdfTitle: pdfTitle,
            allocatedSizeBytes: folderSizeBytes ?? allocatedSizeBytes
        )
    }

    private static func computeFolderStats(at url: URL) -> (totalBytes: Int64, fileCount: Int, folderCount: Int) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return (0, 0, 0)
        }

        var totalBytes: Int64 = 0
        var fileCount = 0
        var folderCount = 0
        var visited = 0

        for case let childURL as URL in enumerator {
            if Task.isCancelled { break }
            visited += 1
            if visited > 25_000 { break }
            let vals = try? childURL.resourceValues(forKeys: Set(keys))
            if vals?.isDirectory == true && vals?.isPackage != true {
                folderCount += 1
            } else {
                fileCount += 1
                totalBytes += Int64(vals?.fileSize ?? 0)
            }
        }
        return (totalBytes, fileCount, folderCount)
    }
}

struct InspectorSectionCard<Content: View>: View {
    let title: String?
    @ViewBuilder let content: () -> Content
    @Environment(\.fluentTheme) private var theme

    init(title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: theme.cornerRadiusLarge, style: .continuous)
                .fill(theme.palette.cardSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadiusLarge, style: .continuous)
                .stroke(theme.palette.borderSubtle, lineWidth: 1)
        )
    }
}

struct InspectorKeyValueRow: View {
    let label: String
    let value: String
    var monospaced: Bool = false
    @Environment(\.fluentTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.palette.textSecondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(size: 11.5, design: .monospaced) : .system(size: 11.5))
                .foregroundStyle(theme.palette.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct FluentCheckboxToggleStyle: ToggleStyle {
    @Environment(\.fluentTheme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(configuration.isOn ? theme.palette.accentBlue : Color.clear)
                        .frame(width: 16, height: 16)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(
                            configuration.isOn ? theme.palette.accentBlue : theme.palette.inputBottomStroke,
                            lineWidth: 1.25
                        )
                        .frame(width: 16, height: 16)
                    if configuration.isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(theme.colorScheme == .dark ? Color.black : Color.white)
                    }
                }
                configuration.label
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.palette.textPrimary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
