import AppKit
import CoreGraphics
import FileExplorerCore
import Foundation
import ImageIO
import QuickLookThumbnailing

private final class CachedCGImageBox: NSObject, @unchecked Sendable {
    let cgImage: CGImage

    init(_ cgImage: CGImage) {
        self.cgImage = cgImage
    }
}

private final class ThumbnailMemoryCache: @unchecked Sendable {
    private let cache = NSCache<NSString, CachedCGImageBox>()
    private let lock = NSLock()

    init(countLimit: Int = 512, totalCostLimit: Int = 64 * 1024 * 1024) {
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimit
    }

    func image(forKey key: String) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        return cache.object(forKey: key as NSString)?.cgImage
    }

    func insert(_ image: CGImage, forKey key: String) {
        let cost = max(1, image.bytesPerRow * image.height)
        lock.lock()
        cache.setObject(CachedCGImageBox(image), forKey: key as NSString, cost: cost)
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        cache.removeAllObjects()
        lock.unlock()
    }
}

/// Thread-safe thumbnail provider backed by `CGImageSource`, `QLThumbnailGenerator`,
/// `NSWorkspace`, and an in-memory `NSCache` LRU cache.
public actor ThumbnailProvider {
    public static let shared = ThumbnailProvider()

    private let cache = ThumbnailMemoryCache()
    private var inFlightTasks: [String: Task<CGImage?, Never>] = [:]

    public init() {}

    /// Synchronous cache lookup + fast `CGImageSource` preview for local image files.
    /// Ensures offscreen `NSWindow` snapshots render crisp image thumbnails immediately.
    public nonisolated func synchronousThumbnail(for item: FileItem, size: CGFloat) -> CGImage? {
        guard !item.isDirectory || item.isPackage else { return nil }
        guard size >= 32 else { return nil }

        let bucket = Self.pixelBucket(for: size)
        let key = Self.cacheKey(for: item, pixelBucket: bucket)
        if let cached = cache.image(forKey: key) {
            return cached
        }

        guard item.kind == .image,
              FileManager.default.fileExists(atPath: item.url.path),
              let cgImage = Self.makeFastImageThumbnail(url: item.url, maxPixelSize: bucket) else {
            return nil
        }

        cache.insert(cgImage, forKey: key)
        return cgImage
    }

    /// Asynchronously generates and caches a thumbnail for images, PDFs, videos,
    /// QuickLook-supported documents, and `.app` packages.
    public func thumbnail(for item: FileItem, size: CGFloat) async -> CGImage? {
        if item.isDirectory && !item.isPackage {
            return nil
        }
        guard size >= 32 else { return nil }

        let bucket = Self.pixelBucket(for: size)
        let key = Self.cacheKey(for: item, pixelBucket: bucket)

        if let cached = cache.image(forKey: key) {
            return cached
        }

        if let existingTask = inFlightTasks[key] {
            return await existingTask.value
        }

        let url = item.url
        let kind = item.kind
        let isPackage = item.isPackage

        let task = Task<CGImage?, Never>(priority: .utility) {
            guard FileManager.default.fileExists(atPath: url.path) else {
                return nil
            }

            if kind == .application && isPackage {
                return Self.workspaceIconCGImage(for: url, pixelSize: bucket)
            }

            if kind == .image, let fast = Self.makeFastImageThumbnail(url: url, maxPixelSize: bucket) {
                return fast
            }

            guard Self.supportsQuickLookThumbnail(kind: kind) else {
                return nil
            }

            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: CGFloat(bucket) / 2.0, height: CGFloat(bucket) / 2.0),
                scale: 2.0,
                representationTypes: .thumbnail
            )

            return await withCheckedContinuation { continuation in
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                    continuation.resume(returning: rep?.cgImage)
                }
            }
        }

        inFlightTasks[key] = task
        let result = await task.value
        inFlightTasks.removeValue(forKey: key)

        if let result {
            cache.insert(result, forKey: key)
        }
        return result
    }

    /// Returns the native macOS workspace icon as a `CGImage`.
    public nonisolated func systemFileIcon(for url: URL, size: CGFloat) -> CGImage? {
        Self.workspaceIconCGImage(for: url, pixelSize: Self.pixelBucket(for: size))
    }

    public func clearCache() {
        cache.removeAll()
    }

    private nonisolated static func pixelBucket(for size: CGFloat) -> Int {
        let target = Int(ceil(size * 2.0))
        if target <= 64 { return 64 }
        if target <= 128 { return 128 }
        if target <= 256 { return 256 }
        return 512
    }

    private nonisolated static func cacheKey(for item: FileItem, pixelBucket: Int) -> String {
        "\(item.thumbnailKey)@\(pixelBucket)"
    }

    private nonisolated static func supportsQuickLookThumbnail(kind: FileKind) -> Bool {
        switch kind {
        case .image, .pdf, .video, .document, .presentation, .spreadsheet:
            return true
        case .folder, .application, .audio, .code, .json, .markdown, .text, .archive, .diskImage, .symlink, .other:
            return false
        }
    }

    private nonisolated static func makeFastImageThumbnail(url: URL, maxPixelSize: Int) -> CGImage? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            return nil
        }

        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary)
    }

    private nonisolated static func workspaceIconCGImage(for url: URL, pixelSize: Int) -> CGImage? {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        var rect = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
        return icon.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
