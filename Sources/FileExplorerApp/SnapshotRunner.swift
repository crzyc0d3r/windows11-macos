import AppKit
import CoreGraphics
import FileExplorerCore
import FileExplorerDesign
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum SnapshotRunner {
    static func run(outputDirectory: URL) throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileExplorerSnapshots-\(UUID().uuidString)", isDirectory: true)
        let fixturesDir = tempRoot.appendingPathComponent("Workspace", isDirectory: true)
        let photosDir = tempRoot.appendingPathComponent("Photos", isDirectory: true)
        let persistenceDir = tempRoot.appendingPathComponent("Persistence", isDirectory: true)

        try FileManager.default.createDirectory(at: fixturesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: photosDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: persistenceDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        try populateFixtureFiles(fixturesDir: fixturesDir, photosDir: photosDir)

        let fs = FileSystemService()
        let workspaceItems = try fs.listDirectory(at: fixturesDir, includeHidden: false)
        let photoItems = try fs.listDirectory(at: photosDir, includeHidden: false)

        let baseStore = makeBaseStore(
            persistenceDir: persistenceDir,
            fixturesDir: fixturesDir,
            photosDir: photosDir,
            workspaceItems: workspaceItems
        )

        // 1. 01_details_dark.png (Details view, Dark Mode, item selected, Details Pane open)
        try renderScenario(
            name: "01_details_dark.png",
            outputDirectory: outputDirectory,
            isDark: true,
            configure: { store in
                store.settings.theme = .dark
                store.settings.rightPaneMode = .details
                store.settings.showNavigationPane = true
                store.settings.compactView = false
                store.settings.showCheckboxes = false
                store.navigate(to: .folder(fixturesDir))
                store.currentItems = workspaceItems
                store.setGroupBy(.none)
                store.setViewMode(.details)
                if let pdf = workspaceItems.first(where: { $0.name == "Q4 Roadmap.pdf" }) {
                    store.selectItem(url: pdf.url)
                }
            }
        )

        // 2. 02_details_light.png (Details view, Light Mode, Preview Pane open showing a crisp file preview)
        try renderScenario(
            name: "02_details_light.png",
            outputDirectory: outputDirectory,
            isDark: false,
            configure: { store in
                store.settings.theme = .light
                store.settings.rightPaneMode = .preview
                store.settings.showNavigationPane = true
                store.settings.compactView = false
                store.settings.showCheckboxes = false
                store.navigate(to: .folder(fixturesDir))
                store.currentItems = workspaceItems
                store.setGroupBy(.none)
                store.setViewMode(.details)
                if let hero = workspaceItems.first(where: { $0.name == "HeroBanner.png" }) {
                    store.selectItem(url: hero.url)
                }
            }
        )

        // 3. 03_home_dark.png (Home dashboard — Quick Access, Favorites, Recent, Dark Mode)
        try renderScenario(
            name: "03_home_dark.png",
            outputDirectory: outputDirectory,
            isDark: true,
            configure: { store in
                store.settings.theme = .dark
                store.settings.rightPaneMode = .none
                store.settings.showNavigationPane = true
                store.navigate(to: .home)
            }
        )

        // 4. 04_this_pc_light.png (This PC — Drives with capacity bars, Light Mode)
        try renderScenario(
            name: "04_this_pc_light.png",
            outputDirectory: outputDirectory,
            isDark: false,
            configure: { store in
                store.settings.theme = .light
                store.settings.rightPaneMode = .none
                store.settings.showNavigationPane = true
                store.navigate(to: .thisPC)
            }
        )

        // 5. 05_large_icons_dark.png (Large Icons view with Fluent folders & image thumbnails, Dark Mode)
        try renderScenario(
            name: "05_large_icons_dark.png",
            outputDirectory: outputDirectory,
            isDark: true,
            configure: { store in
                store.settings.theme = .dark
                store.settings.rightPaneMode = .none
                store.settings.showNavigationPane = true
                store.navigate(to: .folder(fixturesDir))
                store.currentItems = workspaceItems
                store.setGroupBy(.none)
                store.setViewMode(.largeIcons)
                if let banner = workspaceItems.first(where: { $0.name == "HeroBanner.png" }) {
                    store.selectItem(url: banner.url)
                }
            }
        )

        // 6. 06_gallery_dark.png (Gallery view with photo timeline & scrubber, Dark Mode)
        try renderScenario(
            name: "06_gallery_dark.png",
            outputDirectory: outputDirectory,
            isDark: true,
            configure: { store in
                store.settings.theme = .dark
                store.settings.rightPaneMode = .none
                store.settings.showNavigationPane = true
                store.navigate(to: .gallery)
                store.currentItems = photoItems
                if let firstPhoto = photoItems.first {
                    store.selectItem(url: firstPhoto.url)
                }
            }
        )

        // 7. 07_context_menu_dark.png (Windows 11 24H2 right-click context menu with top action bar, Dark Mode)
        try renderScenario(
            name: "07_context_menu_dark.png",
            outputDirectory: outputDirectory,
            isDark: true,
            contextMenuAnchorPoint: CGPoint(x: 520, y: 270),
            configure: { store in
                store.settings.theme = .dark
                store.settings.rightPaneMode = .none
                store.settings.showNavigationPane = true
                store.navigate(to: .folder(fixturesDir))
                store.currentItems = workspaceItems
                store.setGroupBy(.none)
                store.setViewMode(.details)
                if let target = workspaceItems.first(where: { $0.name == "Package.swift" }) {
                    store.selectItem(url: target.url)
                    store.showContextMenu(for: .item(target))
                }
            }
        )

        // 8. 08_properties_dialog_light.png (Windows 11 Properties dialog open, Light Mode)
        try renderScenario(
            name: "08_properties_dialog_light.png",
            outputDirectory: outputDirectory,
            isDark: false,
            configure: { store in
                store.settings.theme = .light
                store.settings.rightPaneMode = .none
                store.settings.showNavigationPane = true
                store.navigate(to: .folder(fixturesDir))
                store.currentItems = workspaceItems
                store.setGroupBy(.none)
                store.setViewMode(.details)
                if let target = workspaceItems.first(where: { $0.name == "Q4 Roadmap.pdf" }) {
                    store.selectItem(url: target.url)
                    store.showProperties(for: target.url)
                }
            }
        )

        // 9. 09_search_results_dark.png (Active search with filter bar & results, Dark Mode)
        try renderScenario(
            name: "09_search_results_dark.png",
            outputDirectory: outputDirectory,
            isDark: true,
            configure: { store in
                store.settings.theme = .dark
                store.settings.rightPaneMode = .none
                store.settings.showNavigationPane = true
                let filters = SearchFilters(
                    kind: nil,
                    dateRange: .pastMonth,
                    sizeRange: .any,
                    includeSubfolders: true,
                    caseSensitive: false
                )
                store.navigate(to: .search(query: "Design", scope: fixturesDir, filters: filters))
                store.activeSearchText = "Design"
                store.isSearching = false
                store.currentItems = workspaceItems.filter {
                    $0.name.localizedCaseInsensitiveContains("Design")
                        || $0.kind == .image
                        || $0.kind == .markdown
                        || $0.kind == .pdf
                }
                store.setGroupBy(.none)
                store.setViewMode(.details)
            }
        )

        // 10. 10_compact_grouped_light.png (Compact Details view with Group By headers + Item Checkboxes, Light Mode)
        try renderScenario(
            name: "10_compact_grouped_light.png",
            outputDirectory: outputDirectory,
            isDark: false,
            configure: { store in
                store.settings.theme = .light
                store.settings.rightPaneMode = .none
                store.settings.showNavigationPane = true
                store.settings.compactView = true
                store.settings.showCheckboxes = true
                store.navigate(to: .folder(fixturesDir))
                store.currentItems = workspaceItems
                store.setViewMode(.details)
                store.setGroupBy(.type)
                let selected = Set(workspaceItems.prefix(2).map(\.url))
                store.setSelection(selected)
            }
        )

        _ = baseStore
    }

    // MARK: - Window Rendering

    private static func renderScenario(
        name: String,
        outputDirectory: URL,
        isDark: Bool,
        contextMenuAnchorPoint: CGPoint? = nil,
        configure: (ExplorerStore) -> Void
    ) throws {
        let store = ExplorerStore(settings: .default, snapshotMode: true)
        store.loadSnapshotFixtures()
        configure(store)

        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        NSApp.appearance = appearance

        let size = NSSize(width: 1440, height: 900)
        let window = NSWindow(
            contentRect: NSRect(x: -5000, y: -5000, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.setContentSize(size)

        let rootView = MainExplorerWindowView(
            store: store,
            contextMenuAnchorPoint: contextMenuAnchorPoint
        )
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.appearance = appearance
        window.contentView = hostingView

        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.35))
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()

        let scale = 2
        let pixelWidth = Int(size.width) * scale
        let pixelHeight = Int(size.height) * scale

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw NSError(domain: "SnapshotRunner", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate bitmap rep for \(name)"])
        }
        rep.size = size

        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)

        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "SnapshotRunner", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG for \(name)"])
        }

        let destinationURL = outputDirectory.appendingPathComponent(name)
        try pngData.write(to: destinationURL, options: .atomic)
        window.close()
    }

    // MARK: - Fixture Creation

    private static func makeBaseStore(
        persistenceDir: URL,
        fixturesDir: URL,
        photosDir: URL,
        workspaceItems: [FileItem]
    ) -> ExplorerStore {
        _ = persistenceDir
        _ = fixturesDir
        _ = photosDir
        _ = workspaceItems
        return ExplorerStore(settings: .default, snapshotMode: true)
    }

    private static func populateFixtureFiles(fixturesDir: URL, photosDir: URL) throws {
        let fm = FileManager.default

        let archDir = fixturesDir.appendingPathComponent("Architecture Specs", isDirectory: true)
        let assetsDir = fixturesDir.appendingPathComponent("Design Assets", isDirectory: true)
        let notesDir = fixturesDir.appendingPathComponent("Release Notes", isDirectory: true)
        try fm.createDirectory(at: archDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: notesDir, withIntermediateDirectories: true)

        try "# Architecture Overview\n\nModular SwiftPM layout.\n".write(
            to: archDir.appendingPathComponent("Overview.md"),
            atomically: true,
            encoding: .utf8
        )
        try "{\"accent\": \"#0067C0\"}\n".write(
            to: assetsDir.appendingPathComponent("ColorTokens.json"),
            atomically: true,
            encoding: .utf8
        )
        try "# v1.0 Notes\n\nInitial Windows 11 Fluent release.\n".write(
            to: notesDir.appendingPathComponent("v1.0.md"),
            atomically: true,
            encoding: .utf8
        )

        let swiftSource = """
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
        try swiftSource.write(
            to: fixturesDir.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )

        let readme = """
        # File Explorer for macOS

        Windows 11 24H2-inspired desktop file manager built natively with SwiftUI & AppKit.

        - Browser-style tabs with drag reordering & tear-off windows
        - Breadcrumb navigation bar & instant scoped search
        - Details, Preview & Properties panes with real POSIX chmod
        """
        try readme.write(
            to: fixturesDir.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )

        let json = """
        {
          "theme": "Fluent 2",
          "micaOpacity": 0.72,
          "accent": "#0067C0"
        }
        """
        try json.write(
            to: fixturesDir.appendingPathComponent("FluentTokens.json"),
            atomically: true,
            encoding: .utf8
        )

        try createSamplePDF(
            at: fixturesDir.appendingPathComponent("Q4 Roadmap.pdf"),
            title: "Q4 Product Roadmap",
            subtitle: "Windows 11 Fluent Architecture & Milestones"
        )

        try createSamplePNG(
            at: fixturesDir.appendingPathComponent("HeroBanner.png"),
            width: 640,
            height: 400,
            topColor: CGColor(red: 0.05, green: 0.34, blue: 0.72, alpha: 1),
            bottomColor: CGColor(red: 0.22, green: 0.72, blue: 0.94, alpha: 1),
            accentColor: CGColor(red: 0.98, green: 0.80, blue: 0.28, alpha: 0.9)
        )

        try Data("PK\u{05}\u{06}".utf8).write(
            to: fixturesDir.appendingPathComponent("Release_Build.zip"),
            options: .atomic
        )

        // Photo timeline fixtures with distinct dates across multiple months
        let calendar = Calendar(identifier: .gregorian)
        let photoSpecs: [(name: String, year: Int, month: Int, day: Int, top: CGColor, bottom: CGColor)] = [
            ("AutumnRidge.png", 2026, 10, 18, CGColor(red: 0.78, green: 0.34, blue: 0.18, alpha: 1), CGColor(red: 0.94, green: 0.68, blue: 0.26, alpha: 1)),
            ("CoastalDawn.png", 2026, 10, 4, CGColor(red: 0.14, green: 0.42, blue: 0.76, alpha: 1), CGColor(red: 0.42, green: 0.82, blue: 0.90, alpha: 1)),
            ("StudioSetup.png", 2026, 9, 22, CGColor(red: 0.18, green: 0.20, blue: 0.26, alpha: 1), CGColor(red: 0.34, green: 0.48, blue: 0.74, alpha: 1)),
            ("ForestMist.png", 2026, 9, 9, CGColor(red: 0.12, green: 0.42, blue: 0.32, alpha: 1), CGColor(red: 0.44, green: 0.74, blue: 0.56, alpha: 1)),
            ("SummerSkyline.png", 2026, 7, 15, CGColor(red: 0.28, green: 0.24, blue: 0.66, alpha: 1), CGColor(red: 0.86, green: 0.44, blue: 0.68, alpha: 1)),
            ("AlpineGlacier.png", 2026, 3, 27, CGColor(red: 0.18, green: 0.56, blue: 0.82, alpha: 1), CGColor(red: 0.82, green: 0.94, blue: 0.98, alpha: 1))
        ]

        for spec in photoSpecs {
            let url = photosDir.appendingPathComponent(spec.name)
            try createSamplePNG(
                at: url,
                width: 480,
                height: 360,
                topColor: spec.top,
                bottomColor: spec.bottom,
                accentColor: CGColor(red: 1, green: 1, blue: 1, alpha: 0.25)
            )
            var comps = DateComponents()
            comps.year = spec.year
            comps.month = spec.month
            comps.day = spec.day
            comps.hour = 14
            if let date = calendar.date(from: comps) {
                try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            }
        }
    }

    private static func createSamplePNG(
        at url: URL,
        width: Int,
        height: Int,
        topColor: CGColor,
        bottomColor: CGColor,
        accentColor: CGColor
    ) throws {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return
        }

        if let gradient = CGGradient(colorsSpace: colorSpace, colors: [topColor, bottomColor] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: CGFloat(height)),
                end: CGPoint(x: CGFloat(width), y: 0),
                options: []
            )
        }

        ctx.setFillColor(accentColor)
        ctx.fillEllipse(in: CGRect(x: CGFloat(width) * 0.55, y: CGFloat(height) * 0.45, width: CGFloat(width) * 0.28, height: CGFloat(width) * 0.28))

        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    private static func createSamplePDF(at url: URL, title: String, subtitle: String) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return
        }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(red: 0.98, green: 0.99, blue: 1.0, alpha: 1))
        ctx.fill(mediaBox)

        ctx.setFillColor(CGColor(red: 0.0, green: 0.40, blue: 0.75, alpha: 1))
        ctx.fill(CGRect(x: 48, y: 710, width: 516, height: 6))

        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 26, weight: .bold),
            .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1)
        ]
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.35, alpha: 1)
        ]
        (title as NSString).draw(at: NSPoint(x: 48, y: 664), withAttributes: titleAttrs)
        (subtitle as NSString).draw(at: NSPoint(x: 48, y: 636), withAttributes: subAttrs)
        NSGraphicsContext.restoreGraphicsState()

        ctx.setFillColor(CGColor(red: 0.88, green: 0.90, blue: 0.93, alpha: 1))
        for row in 0..<10 {
            let y = 570 - CGFloat(row) * 38
            let w: CGFloat = row % 3 == 2 ? 360 : 516
            ctx.fill(CGRect(x: 48, y: y, width: w, height: 12))
        }
        ctx.endPDFPage()
        ctx.closePDF()
    }
}
