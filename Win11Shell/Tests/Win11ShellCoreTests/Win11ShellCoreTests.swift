import CoreGraphics
import Foundation
import Testing
@testable import Win11ShellCore

@Suite("Win11ShellCore Tests")
struct Win11ShellCoreTests {
    @Test("Config round-trip serialization and no external tool exclusions")
    func configRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Win11ShellConfigTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("config.json")
        let store = Win11ConfigStore(configURL: url)
        var config = Win11Config.default
        config.taskbarAlignment = .left
        config.taskbarAutoHide = true
        config.showWidgetsButton = false

        try store.save(config)
        let loaded = store.load()
        #expect(loaded == config)
        #expect(loaded.windowBarExcludedBundleIDs == [
            "com.hackedple.win11shell",
            "com.apple.Spotlight",
            "com.apple.notificationcenterui",
            "com.apple.controlcenter"
        ])
    }

    @Test("AX <-> Cocoa geometry conversion, docked bar placement, and maximized frame")
    func geometryCalculations() {
        let primaryHeight: CGFloat = 982
        let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1512, height: 944) // 38pt notch safe area at top

        let axWindow = CGRect(x: 100, y: 120, width: 800, height: 600)
        let cocoaWindow = WindowChromeGeometry.axRectToCocoa(axWindow, primaryScreenHeight: primaryHeight)
        #expect(cocoaWindow == CGRect(x: 100, y: 262, width: 800, height: 600))
        #expect(WindowChromeGeometry.cocoaRectToAX(cocoaWindow, primaryScreenHeight: primaryHeight) == axWindow)

        let barFrame = WindowChromeGeometry.dockedBarFrame(
            forAXWindowFrame: axWindow,
            primaryScreenHeight: primaryHeight,
            screenFrameCocoa: screenFrame,
            visibleFrameCocoa: visibleFrame,
            barHeight: 28,
            taskbarHeight: 48
        )
        #expect(barFrame == CGRect(x: 100, y: 862, width: 800, height: 28))

        // Fullscreen window hides bar
        let fullscreenAX = CGRect(x: 0, y: 0, width: 1512, height: 982)
        #expect(
            WindowChromeGeometry.dockedBarFrame(
                forAXWindowFrame: fullscreenAX,
                primaryScreenHeight: primaryHeight,
                screenFrameCocoa: screenFrame,
                visibleFrameCocoa: visibleFrame,
                barHeight: 28,
                taskbarHeight: 48
            ) == nil
        )

        // Maximized window reserves 28pt bar under visibleFrame top and 48pt taskbar at bottom
        let maxAX = WindowChromeGeometry.maximizedAXFrame(
            forScreenFrameCocoa: screenFrame,
            visibleFrameCocoa: visibleFrame,
            primaryScreenHeight: primaryHeight,
            barHeight: 28,
            taskbarHeight: 48
        )
        let maxCocoa = WindowChromeGeometry.axRectToCocoa(maxAX, primaryScreenHeight: primaryHeight)
        #expect(maxCocoa.minY == 48)
        #expect(maxCocoa.maxY == CGFloat(944 - 28))
        #expect(maxCocoa.width == 1512)
    }

    @Test("Snap zones reserve 28pt chrome bar and 48pt taskbar across halves, quadrants, and thirds")
    func snapZoneGeometry() {
        let primaryHeight: CGFloat = 982
        let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1512, height: 944)

        let leftAX = WindowChromeGeometry.snapAXFrame(
            for: .leftHalf,
            screenFrameCocoa: screenFrame,
            visibleFrameCocoa: visibleFrame,
            primaryScreenHeight: primaryHeight,
            barHeight: 28,
            taskbarHeight: 48
        )
        let rightAX = WindowChromeGeometry.snapAXFrame(
            for: .rightHalf,
            screenFrameCocoa: screenFrame,
            visibleFrameCocoa: visibleFrame,
            primaryScreenHeight: primaryHeight,
            barHeight: 28,
            taskbarHeight: 48
        )
        #expect(leftAX.minX == 0)
        #expect(leftAX.width == 756)
        #expect(rightAX.minX == 756)
        #expect(rightAX.width == 756)
        #expect(leftAX.height == CGFloat(944 - 28 - 48))

        let topRightAX = WindowChromeGeometry.snapAXFrame(
            for: .topRight,
            screenFrameCocoa: screenFrame,
            visibleFrameCocoa: visibleFrame,
            primaryScreenHeight: primaryHeight,
            barHeight: 28,
            taskbarHeight: 48
        )
        let bottomLeftAX = WindowChromeGeometry.snapAXFrame(
            for: .bottomLeft,
            screenFrameCocoa: screenFrame,
            visibleFrameCocoa: visibleFrame,
            primaryScreenHeight: primaryHeight,
            barHeight: 28,
            taskbarHeight: 48
        )
        #expect(topRightAX.minY == leftAX.minY)
        #expect(topRightAX.height == leftAX.height / 2)
        #expect(bottomLeftAX.minY == leftAX.minY + leftAX.height / 2)

        let twoThirds = WindowChromeGeometry.snapAXFrame(
            for: .leftTwoThirds,
            screenFrameCocoa: screenFrame,
            visibleFrameCocoa: visibleFrame,
            primaryScreenHeight: primaryHeight,
            barHeight: 28,
            taskbarHeight: 48
        )
        let oneThird = WindowChromeGeometry.snapAXFrame(
            for: .rightOneThird,
            screenFrameCocoa: screenFrame,
            visibleFrameCocoa: visibleFrame,
            primaryScreenHeight: primaryHeight,
            barHeight: 28,
            taskbarHeight: 48
        )
        #expect(twoThirds.width + oneThird.width == 1512)
        #expect(oneThird.maxX == 1512)
    }

    @Test("Window normalization clamps overlapping windows into 28pt/48pt work area and skips clean or fullscreen windows")
    func windowNormalization() {
        let primaryHeight: CGFloat = 982
        let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1512, height: 944)

        // Window extending into top bar and bottom taskbar
        let overlappingCocoa = CGRect(x: 80, y: 10, width: 900, height: 930)
        let overlappingAX = WindowChromeGeometry.cocoaRectToAX(overlappingCocoa, primaryScreenHeight: primaryHeight)
        let clampedAX = WindowChromeGeometry.normalizedAXFrame(
            forAXWindowFrame: overlappingAX,
            screenFrameCocoa: screenFrame,
            visibleFrameCocoa: visibleFrame,
            primaryScreenHeight: primaryHeight,
            barHeight: 28,
            taskbarHeight: 48
        )
        let clampedCocoa = clampedAX.map { WindowChromeGeometry.axRectToCocoa($0, primaryScreenHeight: primaryHeight) }
        #expect(clampedCocoa != nil)
        #expect(clampedCocoa!.minY >= 48)
        #expect(clampedCocoa!.maxY <= CGFloat(944 - 28))

        // Already clean window returns nil
        let cleanCocoa = CGRect(x: 100, y: 120, width: 800, height: 600)
        let cleanAX = WindowChromeGeometry.cocoaRectToAX(cleanCocoa, primaryScreenHeight: primaryHeight)
        #expect(
            WindowChromeGeometry.normalizedAXFrame(
                forAXWindowFrame: cleanAX,
                screenFrameCocoa: screenFrame,
                visibleFrameCocoa: visibleFrame,
                primaryScreenHeight: primaryHeight,
                barHeight: 28,
                taskbarHeight: 48
            ) == nil
        )

        // Fullscreen window returns nil
        let fullscreenAX = CGRect(x: 0, y: 0, width: 1512, height: 982)
        #expect(
            WindowChromeGeometry.normalizedAXFrame(
                forAXWindowFrame: fullscreenAX,
                screenFrameCocoa: screenFrame,
                visibleFrameCocoa: visibleFrame,
                primaryScreenHeight: primaryHeight,
                barHeight: 28,
                taskbarHeight: 48
            ) == nil
        )
    }

    @Test("Drag-to-edge and corner snap zone detection")
    func dragSnapZones() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)

        #expect(WindowChromeGeometry.dragSnapZone(forMouseCocoa: CGPoint(x: 4, y: 500), screenFrameCocoa: screen, visibleFrameCocoa: visible) == .leftHalf)
        #expect(WindowChromeGeometry.dragSnapZone(forMouseCocoa: CGPoint(x: 1508, y: 500), screenFrameCocoa: screen, visibleFrameCocoa: visible) == .rightHalf)
        #expect(WindowChromeGeometry.dragSnapZone(forMouseCocoa: CGPoint(x: 750, y: 940), screenFrameCocoa: screen, visibleFrameCocoa: visible) == .maximized)
        #expect(WindowChromeGeometry.dragSnapZone(forMouseCocoa: CGPoint(x: 5, y: 940), screenFrameCocoa: screen, visibleFrameCocoa: visible) == .topLeft)
        #expect(WindowChromeGeometry.dragSnapZone(forMouseCocoa: CGPoint(x: 1508, y: 940), screenFrameCocoa: screen, visibleFrameCocoa: visible) == .topRight)
        #expect(WindowChromeGeometry.dragSnapZone(forMouseCocoa: CGPoint(x: 5, y: 20), screenFrameCocoa: screen, visibleFrameCocoa: visible) == .bottomLeft)
        #expect(WindowChromeGeometry.dragSnapZone(forMouseCocoa: CGPoint(x: 1508, y: 20), screenFrameCocoa: screen, visibleFrameCocoa: visible) == .bottomRight)
        #expect(WindowChromeGeometry.dragSnapZone(forMouseCocoa: CGPoint(x: 750, y: 500), screenFrameCocoa: screen, visibleFrameCocoa: visible) == nil)
    }

    @Test("WindowClosePolicy quits on last window except keep-alive apps")
    func closePolicy() {
        let keepAlive: Set<String> = ["com.microsoft.Outlook", "com.apple.finder"]
        #expect(WindowClosePolicy.decide(bundleID: "com.google.Chrome", standardWindowCount: 2, keepAliveBundleIDs: keepAlive) == .closeWindow)
        #expect(WindowClosePolicy.decide(bundleID: "com.google.Chrome", standardWindowCount: 1, keepAliveBundleIDs: keepAlive) == .quitApp)
        #expect(WindowClosePolicy.decide(bundleID: "com.microsoft.Outlook", standardWindowCount: 1, keepAliveBundleIDs: keepAlive) == .hideApp)
    }

    @Test("AppCatalog hides Finder and ranks prefix matches first")
    func appCatalogSearch() {
        let sample = [
            InstalledAppEntry(bundleID: "com.apple.finder", name: "Finder", url: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")),
            InstalledAppEntry(bundleID: "com.apple.Safari", name: "Safari", url: URL(fileURLWithPath: "/Applications/Safari.app")),
            InstalledAppEntry(bundleID: "com.hackedple.fileexplorer", name: "File Explorer", url: URL(fileURLWithPath: "/Applications/FileExplorer.app")),
            InstalledAppEntry(bundleID: "com.foo.myfiles", name: "My Files", url: URL(fileURLWithPath: "/Applications/MyFiles.app"))
        ]

        let all = AppCatalog.filterApps(sample, query: "", hideFinder: true)
        #expect(!all.contains { $0.bundleID == "com.apple.finder" })
        #expect(all.count == 3)

        let queryMatches = AppCatalog.filterApps(sample, query: "file", hideFinder: true)
        #expect(queryMatches.map(\.name) == ["File Explorer", "My Files"])
    }

    @Test("Native titlebar band detection preserves resize borders and excludes client content")
    func nativeTitlebarBandDetection() {
        let winFrame = CGRect(x: 100, y: 120, width: 800, height: 600)

        // Resize borders (outer 5pt top/left/right) must pass through
        #expect(!WindowChromeGeometry.isInNativeTitlebarBand(axPoint: CGPoint(x: 400, y: 122), windowAXFrame: winFrame))
        #expect(!WindowChromeGeometry.isInNativeTitlebarBand(axPoint: CGPoint(x: 102, y: 138), windowAXFrame: winFrame))
        #expect(!WindowChromeGeometry.isInNativeTitlebarBand(axPoint: CGPoint(x: 897, y: 138), windowAXFrame: winFrame))

        // Interior native titlebar band returns true
        #expect(WindowChromeGeometry.isInNativeTitlebarBand(axPoint: CGPoint(x: 400, y: 138), windowAXFrame: winFrame))
        #expect(WindowChromeGeometry.isInNativeTitlebarBand(axPoint: CGPoint(x: 120, y: 138), windowAXFrame: winFrame))

        // Below titlebar (client content) and outside window return false
        #expect(!WindowChromeGeometry.isInNativeTitlebarBand(axPoint: CGPoint(x: 400, y: 165), windowAXFrame: winFrame))
        #expect(!WindowChromeGeometry.isInNativeTitlebarBand(axPoint: CGPoint(x: 50, y: 138), windowAXFrame: winFrame))

        // Estimated height from traffic lights
        #expect(WindowChromeGeometry.estimatedNativeTitlebarHeight(trafficLightRelativeRect: nil) == 38)
        #expect(WindowChromeGeometry.estimatedNativeTitlebarHeight(trafficLightRelativeRect: CGRect(x: 8, y: 8, width: 62, height: 22)) == 40)
        #expect(WindowChromeGeometry.estimatedNativeTitlebarHeight(trafficLightRelativeRect: CGRect(x: 8, y: 4, width: 60, height: 14)) == 36)
        #expect(WindowChromeGeometry.estimatedNativeTitlebarHeight(trafficLightRelativeRect: CGRect(x: 8, y: 20, width: 60, height: 30)) == 52)
    }

    @Test("Titlebar Accessibility element classification distinguishes traffic lights, controls, and drag surfaces")
    func titlebarElementClassification() {
        for subrole in ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"] {
            #expect(
                WindowChromeGeometry.classifyTitlebarElement(role: "AXButton", subrole: subrole, actions: ["AXPress"])
                    == .trafficLight
            )
        }

        for role in ["AXButton", "AXPopUpButton", "AXRadioButton", "AXTab", "AXSearchField", "AXTextField"] {
            #expect(
                WindowChromeGeometry.classifyTitlebarElement(role: role, subrole: nil, actions: ["AXPress"])
                    == .interactiveControl
            )
        }

        // Custom clickable Electron/web group control
        #expect(
            WindowChromeGeometry.classifyTitlebarElement(role: "AXGroup", subrole: nil, actions: ["AXPress"])
                == .interactiveControl
        )

        // Bare titlebar / web container / text drag surfaces
        for role in ["AXGroup", "AXWebArea", "AXWindow", "AXToolbar", "AXStaticText"] {
            #expect(
                WindowChromeGeometry.classifyTitlebarElement(role: role, subrole: nil, actions: ["AXShowMenu"])
                    == .dragSurface
            )
            #expect(
                WindowChromeGeometry.classifyTitlebarElement(role: role, subrole: nil, actions: [])
                    == .dragSurface
            )
        }

        // Even with AXPress on top-level container roles, keep dragSurface
        #expect(
            WindowChromeGeometry.classifyTitlebarElement(role: "AXWebArea", subrole: nil, actions: ["AXPress"])
                == .dragSurface
        )
    }

    @Test("Notch bezel frame covers top safe area band on notched displays and returns nil otherwise")
    func notchBezelFrameGeometry() {
        let notchedScreen = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        let bezel = WindowChromeGeometry.notchBezelFrameCocoa(
            screenFrameCocoa: notchedScreen,
            safeAreaTopInset: 38
        )
        #expect(bezel == CGRect(x: 0, y: 1131, width: 1800, height: 38))

        let standardScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(WindowChromeGeometry.notchBezelFrameCocoa(screenFrameCocoa: standardScreen, safeAreaTopInset: 0) == nil)
    }

    @Test("Auto-normalization catches native zoom and bottom-clipped maximized windows while leaving floating windows")
    func autoNormalizationFocusedCheck() {
        let primaryH: CGFloat = 1169
        let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        let visible = CGRect(x: 0, y: 0, width: 1800, height: 1131)

        // Native macOS Zoom (0, 38, 1800, 1131) extends into top chrome bar and bottom taskbar
        #expect(WindowChromeGeometry.shouldAutoNormalizeFocusedWindow(
            axFrame: CGRect(x: 0, y: 38, width: 1800, height: 1131),
            screenFrameCocoa: screen,
            visibleFrameCocoa: visible,
            primaryScreenHeight: primaryH,
            barHeight: 28,
            taskbarHeight: 48
        ))

        // Bottom-clipped maximized window (0, 66, 1800, 1103) extends behind taskbar
        #expect(WindowChromeGeometry.shouldAutoNormalizeFocusedWindow(
            axFrame: CGRect(x: 0, y: 66, width: 1800, height: 1103),
            screenFrameCocoa: screen,
            visibleFrameCocoa: visible,
            primaryScreenHeight: primaryH,
            barHeight: 28,
            taskbarHeight: 48
        ))

        // Clean Win11 maximized window (0, 66, 1800, 1055) does not trigger normalization
        #expect(!WindowChromeGeometry.shouldAutoNormalizeFocusedWindow(
            axFrame: CGRect(x: 0, y: 66, width: 1800, height: 1055),
            screenFrameCocoa: screen,
            visibleFrameCocoa: visible,
            primaryScreenHeight: primaryH,
            barHeight: 28,
            taskbarHeight: 48
        ))

        // Small floating window positioned partially near bottom taskbar stays untouched
        #expect(!WindowChromeGeometry.shouldAutoNormalizeFocusedWindow(
            axFrame: CGRect(x: 200, y: 650, width: 700, height: 500),
            screenFrameCocoa: screen,
            visibleFrameCocoa: visible,
            primaryScreenHeight: primaryH,
            barHeight: 28,
            taskbarHeight: 48
        ))
    }
}
