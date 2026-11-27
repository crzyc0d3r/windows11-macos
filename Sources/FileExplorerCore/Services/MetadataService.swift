import AppKit
import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import PDFKit

public struct MetadataService: Sendable {
    public init() {}

    public func loadMetadata(for item: FileItem) async -> FileMetadata {
        let url = item.url
        let (defaultAppName, defaultAppURL, openWithApps) = Self.resolveOpenWithApps(for: url, isDirectory: item.isDirectory && !item.isPackage)

        if item.isDirectory && !item.isPackage {
            let stats = await Self.computeFolderStats(at: url)
            return FileMetadata(
                item: item,
                folderSizeBytes: stats.totalBytes,
                folderFileCount: stats.fileCount,
                folderSubfolderCount: stats.folderCount,
                defaultAppName: defaultAppName,
                defaultAppURL: defaultAppURL,
                openWithApps: openWithApps
            )
        }

        var dimensions: String?
        var exifSummary: [(String, String)] = []
        var mediaDuration: String?
        var mediaCodec: String?
        var pdfPageCount: Int?
        var lineCount: Int?

        switch item.kind {
        case .image:
            let imageInfo = Self.extractImageMetadata(at: url)
            dimensions = imageInfo.dimensions
            exifSummary = imageInfo.exif

        case .video, .audio:
            let mediaInfo = await Self.extractMediaMetadata(at: url)
            dimensions = mediaInfo.dimensions
            mediaDuration = mediaInfo.duration
            mediaCodec = mediaInfo.codec

        case .pdf:
            let pdfInfo = Self.extractPDFMetadata(at: url)
            pdfPageCount = pdfInfo.pageCount
            exifSummary = pdfInfo.attributes

        case .text, .code, .json, .markdown:
            lineCount = Self.countTextLines(at: url)

        default:
            break
        }

        return FileMetadata(
            item: item,
            dimensions: dimensions,
            exifSummary: exifSummary,
            mediaDuration: mediaDuration,
            mediaCodec: mediaCodec,
            pdfPageCount: pdfPageCount,
            lineCount: lineCount,
            defaultAppName: defaultAppName,
            defaultAppURL: defaultAppURL,
            openWithApps: openWithApps
        )
    }

    // MARK: - POSIX Permissions & File Flags

    public func readPOSIXPermissions(at url: URL) throws -> POSIXPermissions {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let num = attrs[.posixPermissions] as? NSNumber else {
            throw FileSystemError.operationFailed("Unable to read POSIX permissions.")
        }
        return POSIXPermissions(mode: UInt16(num.uint16Value))
    }

    public func setPOSIXPermissions(_ permissions: POSIXPermissions, at url: URL) throws {
        let result = Darwin.chmod(url.path, mode_t(permissions.mode))
        if result != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EACCES)
        }
    }

    public func setFileFlags(at url: URL, isHidden: Bool, isReadOnly: Bool) throws {
        var mutableURL = url
        var values = URLResourceValues()
        values.isHidden = isHidden
        values.isUserImmutable = isReadOnly
        try mutableURL.setResourceValues(values)
    }

    // MARK: - Folder Stats

    public static func computeFolderStats(at url: URL) async -> (totalBytes: Int64, fileCount: Int, folderCount: Int) {
        await Task.detached(priority: .utility) {
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey],
                options: [],
                errorHandler: { _, _ in true }
            ) else {
                return (0, 0, 0)
            }

            var totalBytes: Int64 = 0
            var fileCount = 0
            var folderCount = 0

            while let obj = enumerator.nextObject() {
                if Task.isCancelled { break }
                guard let child = obj as? URL else { continue }
                let vals = try? child.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey])
                let isDir = vals?.isDirectory ?? false
                let isPkg = vals?.isPackage ?? false
                if isDir && !isPkg {
                    folderCount += 1
                } else {
                    fileCount += 1
                    totalBytes += Int64(vals?.fileSize ?? 0)
                }
            }
            return (totalBytes, fileCount, folderCount)
        }.value
    }

    // MARK: - Image / Media / PDF / Text Extractors

    private static func extractImageMetadata(at url: URL) -> (dimensions: String?, exif: [(String, String)]) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (nil, [])
        }

        var dimensions: String?
        if let width = props[kCGImagePropertyPixelWidth] as? Int,
           let height = props[kCGImagePropertyPixelHeight] as? Int {
            dimensions = "\(width) × \(height)"
        }

        var summary: [(String, String)] = []
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            let make = tiff[kCGImagePropertyTIFFMake] as? String
            let model = tiff[kCGImagePropertyTIFFModel] as? String
            if let make, let model {
                let camera = model.localizedCaseInsensitiveContains(make) ? model : "\(make) \(model)"
                summary.append(("Camera", camera))
            } else if let model {
                summary.append(("Camera", model))
            }
        }

        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let fNumber = exif[kCGImagePropertyExifFNumber] as? Double {
                summary.append(("Aperture", String(format: "f/%.1f", fNumber)))
            }
            if let exposure = exif[kCGImagePropertyExifExposureTime] as? Double, exposure > 0 {
                if exposure < 1 {
                    let denom = Int((1.0 / exposure).rounded())
                    summary.append(("Exposure", "1/\(max(1, denom)) s"))
                } else {
                    summary.append(("Exposure", String(format: "%.1f s", exposure)))
                }
            }
            if let isoList = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int], let iso = isoList.first {
                summary.append(("ISO", "\(iso)"))
            }
            if let focalLength = exif[kCGImagePropertyExifFocalLength] as? Double {
                summary.append(("Focal Length", String(format: "%.0f mm", focalLength)))
            }
        }

        if let profile = props[kCGImagePropertyProfileName] as? String {
            summary.append(("Color Profile", profile))
        } else if let colorModel = props[kCGImagePropertyColorModel] as? String {
            summary.append(("Color Space", colorModel))
        }

        return (dimensions, summary)
    }

    private static func extractMediaMetadata(at url: URL) async -> (dimensions: String?, duration: String?, codec: String?) {
        let asset = AVURLAsset(url: url)
        var durationString: String?
        var dimensions: String?
        var codecParts: [String] = []

        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite && seconds >= 0 {
                let total = Int(seconds.rounded())
                let hours = total / 3600
                let mins = (total % 3600) / 60
                let secs = total % 60
                if hours > 0 {
                    durationString = String(format: "%d:%02d:%02d", hours, mins, secs)
                } else {
                    durationString = String(format: "%02d:%02d", mins, secs)
                }
            }
        }

        if let tracks = try? await asset.load(.tracks) {
            for track in tracks {
                if track.mediaType == .video, dimensions == nil,
                   let naturalSize = try? await track.load(.naturalSize),
                   naturalSize.width > 0, naturalSize.height > 0 {
                    dimensions = "\(Int(naturalSize.width)) × \(Int(naturalSize.height))"
                }
                if let descriptions = try? await track.load(.formatDescriptions) {
                    for desc in descriptions {
                        let subType = CMFormatDescriptionGetMediaSubType(desc)
                        let fourCC = fourCharCodeString(subType)
                        if !fourCC.isEmpty && !codecParts.contains(fourCC) {
                            codecParts.append(fourCC)
                        }
                    }
                }
            }
        }

        let codec = codecParts.isEmpty ? nil : codecParts.joined(separator: " / ")
        return (dimensions, durationString, codec)
    }

    private static func fourCharCodeString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        let raw = String(bytes: bytes, encoding: .ascii)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch raw.lowercased() {
        case "hvc1", "hev1": return "HEVC"
        case "avc1": return "H.264"
        case "aac ": return "AAC"
        case "mp4a": return "AAC"
        case "alac": return "ALAC"
        case "flac": return "FLAC"
        case ".mp3": return "MP3"
        case "lpcm": return "LPCM"
        case "apch", "apcn", "apcs", "apco": return "ProRes"
        default: return raw.uppercased()
        }
    }

    private static func extractPDFMetadata(at url: URL) -> (pageCount: Int?, attributes: [(String, String)]) {
        guard let doc = PDFDocument(url: url) else {
            return (nil, [])
        }
        var attrs: [(String, String)] = []
        if let docAttrs = doc.documentAttributes {
            if let title = docAttrs[PDFDocumentAttribute.titleAttribute] as? String, !title.isEmpty {
                attrs.append(("Title", title))
            }
            if let author = docAttrs[PDFDocumentAttribute.authorAttribute] as? String, !author.isEmpty {
                attrs.append(("Author", author))
            }
            if let creator = docAttrs[PDFDocumentAttribute.creatorAttribute] as? String, !creator.isEmpty {
                attrs.append(("Creator", creator))
            }
        }
        return (doc.pageCount, attrs)
    }

    private static func countTextLines(at url: URL) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              size <= 5 * 1024 * 1024 else {
            return nil
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        if data.isEmpty { return 0 }
        var lines = 1
        for byte in data where byte == 0x0A {
            lines += 1
        }
        if data.last == 0x0A {
            lines -= 1
        }
        return max(1, lines)
    }

    // MARK: - Workspace Apps, Terminal & NSFileViewer

    public static func resolveOpenWithApps(for url: URL, isDirectory: Bool) -> (defaultName: String?, defaultURL: URL?, choices: [AppChoice]) {
        if isDirectory {
            let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
            return ("Finder", finderURL, [])
        }

        let workspace = NSWorkspace.shared
        let defaultAppURL = workspace.urlForApplication(toOpen: url)
        let defaultAppName = defaultAppURL.map { $0.deletingPathExtension().lastPathComponent }

        let allAppURLs = workspace.urlsForApplications(toOpen: url)
        var seen = Set<URL>()
        var choices: [AppChoice] = []
        for appURL in allAppURLs {
            let std = appURL.standardizedFileURL
            if seen.insert(std).inserted {
                let name = std.deletingPathExtension().lastPathComponent
                choices.append(AppChoice(url: std, name: name))
            }
        }
        choices.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (defaultAppName, defaultAppURL, choices)
    }

    @MainActor
    public func openInTerminal(at url: URL) {
        let folderURL: URL
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            folderURL = url
        } else {
            folderURL = url.deletingLastPathComponent()
        }

        let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([folderURL], withApplicationAt: terminalURL, configuration: config)
    }

    public func isNSFileViewerEnabled(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> Bool {
        let globalDomain = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        guard let viewer = globalDomain?["NSFileViewer"] as? String else {
            return false
        }
        if let bundleIdentifier {
            return viewer == bundleIdentifier
        }
        return !viewer.isEmpty
    }
}
