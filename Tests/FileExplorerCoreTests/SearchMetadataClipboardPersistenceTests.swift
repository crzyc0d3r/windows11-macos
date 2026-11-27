import AppKit
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import FileExplorerCore

@Suite("Search, Metadata, Clipboard & Persistence Tests")
struct SearchMetadataClipboardPersistenceTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fe-test-smcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Recursive search honors kind, sizeRange, includeSubfolders, and caseSensitive")
    func recursiveSearchWithFilters() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sub = dir.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        try Data("line1\nline2\n".utf8).write(to: dir.appendingPathComponent("RootReport.txt"))
        try Data("{}".utf8).write(to: sub.appendingPathComponent("report_data.json"))
        try Data(repeating: 0x41, count: 200_000).write(to: sub.appendingPathComponent("BigReport.txt"))

        let search = SearchService()

        // Recursive case-insensitive
        let allReports = try await search.search(
            in: dir,
            query: "report",
            filters: SearchFilters(includeSubfolders: true, caseSensitive: false),
            includeHidden: false
        )
        #expect(allReports.count == 3)

        // Non-recursive
        let topOnly = try await search.search(
            in: dir,
            query: "report",
            filters: SearchFilters(includeSubfolders: false, caseSensitive: false),
            includeHidden: false
        )
        #expect(topOnly.map(\.name) == ["RootReport.txt"])

        // Case-sensitive
        let caseSensitive = try await search.search(
            in: dir,
            query: "Report",
            filters: SearchFilters(includeSubfolders: true, caseSensitive: true),
            includeHidden: false
        )
        #expect(Set(caseSensitive.map(\.name)) == ["RootReport.txt", "BigReport.txt"])

        // Kind filter (.json)
        let jsonOnly = try await search.search(
            in: dir,
            query: "report",
            filters: SearchFilters(kind: .json, includeSubfolders: true),
            includeHidden: false
        )
        #expect(jsonOnly.map(\.name) == ["report_data.json"])

        // Size filter (.small = 100 KB - 1 MB)
        let smallOnly = try await search.search(
            in: dir,
            query: "",
            filters: SearchFilters(sizeRange: .small, includeSubfolders: true),
            includeHidden: false
        )
        #expect(smallOnly.map(\.name) == ["BigReport.txt"])
    }

    @Test("MetadataService reads/writes POSIX permissions, hidden/readonly flags, folder stats, image & PDF metadata")
    func metadataAndPermissions() async throws {
        let dir = try makeTempDir()
        defer {
            // Clear immutable flag before cleanup
            let txt = dir.appendingPathComponent("sample.txt")
            try? MetadataService().setFileFlags(at: txt, isHidden: false, isReadOnly: false)
            try? FileManager.default.removeItem(at: dir)
        }

        let textURL = dir.appendingPathComponent("sample.txt")
        try Data("alpha\nbeta\ngamma\n".utf8).write(to: textURL)

        let sub = dir.appendingPathComponent("Sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(repeating: 0x20, count: 512).write(to: sub.appendingPathComponent("inner.bin"))

        // Create a real 32x16 PNG image
        let pngURL = dir.appendingPathComponent("pixel.png")
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        if let ctx = CGContext(
            data: nil,
            width: 32,
            height: 16,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ),
           let cgImage = ctx.makeImage(),
           let dest = CGImageDestinationCreateWithURL(pngURL as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, cgImage, nil)
            CGImageDestinationFinalize(dest)
        }

        // Create a real 2-page PDF
        let pdfURL = dir.appendingPathComponent("doc.pdf")
        let pdf = PDFDocument()
        pdf.insert(PDFPage(), at: 0)
        pdf.insert(PDFPage(), at: 1)
        pdf.write(to: pdfURL)

        let fs = FileSystemService()
        let meta = MetadataService()

        // POSIX chmod roundtrip
        let newPerms = POSIXPermissions(mode: 0o740)
        try meta.setPOSIXPermissions(newPerms, at: textURL)
        let readPerms = try meta.readPOSIXPermissions(at: textURL)
        #expect(readPerms.octalString == "740")
        #expect(readPerms.symbolicString == "rwxr-----")

        // Hidden / read-only flags
        try meta.setFileFlags(at: textURL, isHidden: true, isReadOnly: true)
        let flaggedItem = fs.makeFileItem(at: textURL)
        #expect(flaggedItem?.isHidden == true)
        #expect(flaggedItem?.isReadOnly == true)
        try meta.setFileFlags(at: textURL, isHidden: false, isReadOnly: false)

        // Text line count
        if let textItem = fs.makeFileItem(at: textURL) {
            let textMeta = await meta.loadMetadata(for: textItem)
            #expect(textMeta.lineCount == 3)
        }

        // Image dimensions
        if let imgItem = fs.makeFileItem(at: pngURL) {
            let imgMeta = await meta.loadMetadata(for: imgItem)
            #expect(imgMeta.dimensions == "32 × 16")
        }

        // PDF page count
        if let pdfItem = fs.makeFileItem(at: pdfURL) {
            let pdfMeta = await meta.loadMetadata(for: pdfItem)
            #expect(pdfMeta.pdfPageCount == 2)
        }

        // Recursive folder stats
        if let dirItem = fs.makeFileItem(at: dir) {
            let dirMeta = await meta.loadMetadata(for: dirItem)
            #expect(dirMeta.folderSubfolderCount == 1)
            #expect((dirMeta.folderFileCount ?? 0) >= 4)
            #expect((dirMeta.folderSizeBytes ?? 0) >= 512)
        }
    }

    @MainActor
    @Test("ClipboardManager syncs NSPasteboard fileURLs and tracks cut state")
    func clipboardCopyAndCut() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileA = dir.appendingPathComponent("a.txt")
        let fileB = dir.appendingPathComponent("b.txt")
        try Data("A".utf8).write(to: fileA)
        try Data("B".utf8).write(to: fileB)

        let pasteboard = NSPasteboard.withUniqueName()
        let clipboard = ClipboardManager(pasteboard: pasteboard)

        let copyPayload = clipboard.copy(urls: [fileA])
        #expect(copyPayload?.operation == .copy)
        #expect(clipboard.currentPayload()?.urls == [fileA.standardizedFileURL])

        let cutPayload = clipboard.cut(urls: [fileB])
        #expect(cutPayload?.operation == .cut)
        #expect(clipboard.currentPayload()?.operation == .cut)

        // External write resets operation back to .copy
        pasteboard.clearContents()
        pasteboard.writeObjects([fileA.standardizedFileURL as NSURL])
        let external = clipboard.currentPayload()
        #expect(external?.operation == .copy)
        #expect(external?.urls == [fileA.standardizedFileURL])

        // Clearing cut state clears pasteboard
        _ = clipboard.cut(urls: [fileB])
        #expect(clipboard.clearCutStateIfNeeded() == nil)
        #expect(clipboard.currentPayload() == nil)
    }

    @Test("PersistenceService saves and loads settings, pinned folders, favorites, recents, and tab session")
    func persistenceRoundtrip() throws {
        let baseDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let service = PersistenceService(baseDirectory: baseDir)

        var settings = ExplorerSettings.default
        settings.theme = .dark
        settings.accentColor = .teal
        settings.showHiddenFiles = true
        settings.launchTarget = .lastSession
        try service.saveSettings(settings)

        let folderURL = URL(fileURLWithPath: "/tmp/PinnedTest", isDirectory: true)
        let pinned = [PinnedFolder(url: folderURL, title: "PinnedTest", iconName: "folder")]
        try service.savePinnedFolders(pinned)

        let fav = [FileItem(url: URL(fileURLWithPath: "/tmp/fav.md"), kind: .markdown, isDirectory: false)]
        try service.saveFavorites(fav)

        let recents = [RecentFileEntry(url: URL(fileURLWithPath: "/tmp/recent.pdf"), name: "recent.pdf", kind: .pdf)]
        try service.saveRecentFiles(recents)

        let tab1 = ExplorerTab(location: .folder(folderURL), viewMode: .largeIcons)
        let tab2 = ExplorerTab(location: .thisPC)
        let session = PersistedTabSession(tabs: [tab1, tab2], activeTabID: tab2.id)
        try service.saveSession(session)

        #expect(service.loadSettings() == settings)
        #expect(service.loadPinnedFolders() == pinned)
        #expect(service.loadFavorites() == fav)
        #expect(service.loadRecentFiles() == recents)
        #expect(service.loadSession() == session)
    }
}
