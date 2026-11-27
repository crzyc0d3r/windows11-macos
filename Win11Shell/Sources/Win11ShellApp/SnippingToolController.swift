import AppKit
import CoreGraphics
import ImageIO
import Observation
import SwiftUI
import UniformTypeIdentifiers
import Vision
import Win11ShellCore

@MainActor
@Observable
public final class SnippingToolState {
    public var mode: SnipCaptureMode = .rectangle
    public var delay: SnipDelayOption = .none
    public var isCapturing: Bool = false
    public var countdownRemaining: Int = 0
}

@MainActor
@Observable
private final class SnipScreenOverlayState {
    let displayID: CGDirectDisplayID
    let screenFrameCocoa: CGRect
    let safeAreaTop: CGFloat
    let frozenImage: CGImage
    let frozenNSImage: NSImage
    let windowTargets: [SnipWindowTarget]

    var dragStart: CGPoint?
    var dragCurrent: CGPoint?
    var hoveredWindowTarget: SnipWindowTarget?
    var freeformPoints: [CGPoint] = []
    var isMouseHoveringFullscreen = false

    init(
        displayID: CGDirectDisplayID,
        screenFrameCocoa: CGRect,
        safeAreaTop: CGFloat,
        frozenImage: CGImage,
        windowTargets: [SnipWindowTarget]
    ) {
        self.displayID = displayID
        self.screenFrameCocoa = screenFrameCocoa
        self.safeAreaTop = safeAreaTop
        self.frozenImage = frozenImage
        self.frozenNSImage = NSImage(cgImage: frozenImage, size: screenFrameCocoa.size)
        self.windowTargets = windowTargets
    }
}

private struct SnipWindowTarget: Identifiable {
    let id: CGWindowID
    let ownerName: String
    let rectInOverlayView: CGRect
}

@MainActor
@Observable
private final class SnipEditorState {
    var baseImage: CGImage?
    var displayImage: NSImage?
    var imagePixelSize: CGSize = .zero
    var history = SnipAnnotationHistory()

    var activeTool: SnipToolKind = .pen
    var selectedPenColor: SnipColorRGB = .red
    var selectedHighlighterColor: SnipColorRGB = SnipColorRGB.highlighterPresets[0]
    var penWidth: CGFloat = 4
    var highlighterWidth: CGFloat = 18

    var inProgressAnnotation: SnipAnnotation?
    var cropSelectionRect: CGRect?
    var cropDragStart: CGPoint?

    var recognizedLines: [String] = []
    var isRecognizingText: Bool = false
    var showOCRDrawer: Bool = false
    var ocrStatusMessage: String?

    var savedFileURL: URL?
    var toastMessage: String?

    var activeColor: SnipColorRGB {
        activeTool == .highlighter ? selectedHighlighterColor : selectedPenColor
    }

    var activeLineWidth: CGFloat {
        activeTool == .highlighter ? highlighterWidth : penWidth
    }
}

@MainActor
public final class SnippingToolController {
    private let model: RunningAppsModel
    private let sharedState = SnippingToolState()
    private let editorState = SnipEditorState()

    private var overlayPanels: [CGDirectDisplayID: FocusableFloatingPanel] = [:]
    private var overlayStates: [CGDirectDisplayID: SnipScreenOverlayState] = [:]
    private var countdownPanel: NonActivatingFloatingPanel?
    private var editorPanel: FocusableFloatingPanel?

    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var countdownWorkItem: DispatchWorkItem?
    private var toastClearWork: DispatchWorkItem?
    private var shouldRestoreEditorOnCancel = false

    public init(model: RunningAppsModel) {
        self.model = model
    }

    public func openEditorOrCapture() {
        if editorState.baseImage != nil, let editorPanel {
            editorPanel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        beginCapture()
    }

    public func beginCapture(mode: SnipCaptureMode? = nil) {
        if let mode {
            sharedState.mode = mode
        }
        if sharedState.isCapturing {
            cancelCapture()
        }

        shouldRestoreEditorOnCancel = editorPanel?.isVisible ?? false
        editorPanel?.orderOut(nil)

        let delaySeconds = sharedState.delay.rawValue
        if delaySeconds > 0 {
            startCountdown(seconds: delaySeconds)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.captureScreensAndPresentOverlays()
                }
            }
        }
    }

    public func cancelCapture() {
        countdownWorkItem?.cancel()
        countdownWorkItem = nil
        countdownPanel?.orderOut(nil)
        sharedState.countdownRemaining = 0

        for (_, p) in overlayPanels {
            p.orderOut(nil)
        }
        overlayPanels.removeAll()
        overlayStates.removeAll()
        sharedState.isCapturing = false
        removeCaptureKeyMonitors()
        NSCursor.arrow.set()

        if shouldRestoreEditorOnCancel, editorState.baseImage != nil {
            shouldRestoreEditorOnCancel = false
            presentEditorPanel()
        }
    }

    // MARK: - Delay Countdown

    private func startCountdown(seconds: Int) {
        countdownWorkItem?.cancel()
        sharedState.isCapturing = true
        sharedState.countdownRemaining = seconds

        installCaptureKeyMonitors()
        showCountdownBadge()

        func tick(_ remaining: Int) {
            guard sharedState.isCapturing else { return }
            sharedState.countdownRemaining = remaining
            if remaining <= 0 {
                countdownPanel?.orderOut(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                    Task { @MainActor [weak self] in
                        await self?.captureScreensAndPresentOverlays()
                    }
                }
                return
            }
            let work = DispatchWorkItem {
                tick(remaining - 1)
            }
            countdownWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
        }
        tick(seconds)
    }

    private func showCountdownBadge() {
        let size = NSSize(width: 196, height: 52)
        if countdownPanel == nil {
            let p = NonActivatingFloatingPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.level = .screenSaver
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.contentView = NSHostingView(rootView: SnipCountdownPillView(
                state: sharedState,
                onCancel: { [weak self] in self?.cancelCapture() }
            ))
            countdownPanel = p
        }
        if let screen = screenForMouse() ?? NSScreen.main ?? NSScreen.screens.first,
           let panel = countdownPanel {
            let x = screen.frame.midX - size.width / 2
            let y = screen.frame.maxY - max(42, screen.safeAreaInsets.top + 16) - size.height
            panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
            panel.orderFrontRegardless()
        }
    }

    // MARK: - Fullscreen Capture Overlays

    private func captureScreensAndPresentOverlays() async {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            cancelCapture()
            return
        }

        let primaryH = AccessibilityBridge.primaryScreenHeight()
        let onScreenWindows = AccessibilityBridge.onScreenNormalWindows()
        let selfPID = ProcessInfo.processInfo.processIdentifier

        var capturedScreens: [(screen: NSScreen, displayID: CGDirectDisplayID, image: CGImage, targets: [SnipWindowTarget])] = []
        for screen in screens {
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                continue
            }
            guard let cgImage = await AccessibilityBridge.captureDisplaySnapshot(displayID: displayID) else {
                continue
            }

            let screenCocoa = screen.frame
            let targets: [SnipWindowTarget] = onScreenWindows.compactMap { snap in
                guard snap.pid != selfPID else { return nil }
                let winCocoa = WindowChromeGeometry.axRectToCocoa(snap.axBounds, primaryScreenHeight: primaryH)
                guard winCocoa.intersects(screenCocoa) else { return nil }
                let clipped = winCocoa.intersection(screenCocoa)
                guard clipped.width >= 20, clipped.height >= 20 else { return nil }
                // Convert Cocoa (bottom-left) -> SwiftUI overlay view coordinates (top-left)
                let viewRect = CGRect(
                    x: clipped.minX - screenCocoa.minX,
                    y: screenCocoa.maxY - clipped.maxY,
                    width: clipped.width,
                    height: clipped.height
                )
                return SnipWindowTarget(id: snap.windowID, ownerName: snap.ownerName, rectInOverlayView: viewRect)
            }
            capturedScreens.append((screen, displayID, cgImage, targets))
        }

        guard !capturedScreens.isEmpty else {
            cancelCapture()
            return
        }

        sharedState.isCapturing = true
        installCaptureKeyMonitors()

        for item in capturedScreens {
            let state = SnipScreenOverlayState(
                displayID: item.displayID,
                screenFrameCocoa: item.screen.frame,
                safeAreaTop: item.screen.safeAreaInsets.top,
                frozenImage: item.image,
                windowTargets: item.targets
            )
            overlayStates[item.displayID] = state

            let panel = FocusableFloatingPanel(
                contentRect: item.screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            panel.allowsNotchAreaPlacement = true
            panel.hidesOnDeactivate = false
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.contentView = NSHostingView(rootView: SnipOverlayView(
                sharedState: sharedState,
                screenState: state,
                onSelectMode: { [weak self] mode in
                    self?.sharedState.mode = mode
                    state.dragStart = nil
                    state.dragCurrent = nil
                    state.freeformPoints.removeAll()
                },
                onCycleDelay: { [weak self] in
                    guard let self else { return }
                    self.sharedState.delay = self.sharedState.delay.next
                },
                onCommitRect: { [weak self] rectInView in
                    self?.completeCapture(from: state, rectInView: rectInView, freeformPolygon: nil)
                },
                onCommitFreeform: { [weak self] points in
                    self?.completeFreeformCapture(from: state, polygonInView: points)
                },
                onCommitWindow: { [weak self] target in
                    self?.completeWindowCapture(from: state, target: target)
                },
                onCommitFullscreen: { [weak self] in
                    self?.completeFullscreenCapture(from: state)
                },
                onCancel: { [weak self] in
                    self?.cancelCapture()
                }
            ))
            panel.setFrame(item.screen.frame, display: true)
            panel.makeKeyAndOrderFront(nil)
            overlayPanels[item.displayID] = panel
        }

        if let mouseScreen = screenForMouse(),
           let mouseDID = mouseScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
           let panel = overlayPanels[mouseDID] {
            panel.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func completeCapture(
        from overlayState: SnipScreenOverlayState,
        rectInView: CGRect,
        freeformPolygon: [CGPoint]?
    ) {
        let cropPixels = SnippingGeometry.pixelCropRect(
            selectionInViewPoints: rectInView,
            viewSize: overlayState.screenFrameCocoa.size,
            imagePixelSize: CGSize(width: overlayState.frozenImage.width, height: overlayState.frozenImage.height)
        )
        guard cropPixels.width >= 2, cropPixels.height >= 2,
              let cropped = overlayState.frozenImage.cropping(to: cropPixels)
        else {
            cancelCapture()
            return
        }

        let finalImage: CGImage
        if let freeformPolygon, freeformPolygon.count >= 3 {
            finalImage = maskCGImageToPolygon(
                cropped,
                polygonInOverlayView: freeformPolygon,
                selectionInOverlayView: rectInView,
                overlayViewSize: overlayState.screenFrameCocoa.size
            ) ?? cropped
        } else {
            finalImage = cropped
        }

        tearDownOverlaysForCaptureCompletion()
        deliverCapturedImage(finalImage)
    }

    private func completeFreeformCapture(from overlayState: SnipScreenOverlayState, polygonInView: [CGPoint]) {
        let bounds = CGRect(origin: .zero, size: overlayState.screenFrameCocoa.size)
        let bbox = SnippingGeometry.freeformBoundingRect(points: polygonInView, clampedTo: bounds)
        guard bbox.width >= 4, bbox.height >= 4 else {
            cancelCapture()
            return
        }
        completeCapture(from: overlayState, rectInView: bbox, freeformPolygon: polygonInView)
    }

    private func completeWindowCapture(from overlayState: SnipScreenOverlayState, target: SnipWindowTarget) {
        let bounds = CGRect(origin: .zero, size: overlayState.screenFrameCocoa.size)
        let clipped = target.rectInOverlayView.intersection(bounds)
        completeCapture(from: overlayState, rectInView: clipped, freeformPolygon: nil)
    }

    private func completeFullscreenCapture(from overlayState: SnipScreenOverlayState) {
        let full = overlayState.frozenImage
        tearDownOverlaysForCaptureCompletion()
        deliverCapturedImage(full)
    }

    private func tearDownOverlaysForCaptureCompletion() {
        countdownWorkItem?.cancel()
        countdownWorkItem = nil
        countdownPanel?.orderOut(nil)
        for (_, p) in overlayPanels {
            p.orderOut(nil)
        }
        overlayPanels.removeAll()
        overlayStates.removeAll()
        sharedState.isCapturing = false
        shouldRestoreEditorOnCancel = false
        removeCaptureKeyMonitors()
        NSCursor.arrow.set()
    }

    private func deliverCapturedImage(_ image: CGImage) {
        editorState.baseImage = image
        editorState.imagePixelSize = CGSize(width: image.width, height: image.height)
        editorState.displayImage = NSImage(cgImage: image, size: CGSize(width: CGFloat(image.width) / 2.0, height: CGFloat(image.height) / 2.0))
        editorState.history.resetAll()
        editorState.inProgressAnnotation = nil
        editorState.cropSelectionRect = nil
        editorState.cropDragStart = nil
        editorState.recognizedLines = []
        editorState.showOCRDrawer = false
        editorState.ocrStatusMessage = nil

        copyCurrentCompositeToPasteboard()
        let savedURL = autoSaveScreenshot(image: image)
        editorState.savedFileURL = savedURL
        showToast(savedURL != nil ? "Copied to clipboard • Saved to Pictures/Screenshots" : "Copied to clipboard")
        presentEditorPanel()
    }

    private func maskCGImageToPolygon(
        _ cropped: CGImage,
        polygonInOverlayView: [CGPoint],
        selectionInOverlayView: CGRect,
        overlayViewSize: CGSize
    ) -> CGImage? {
        let w = cropped.width
        let h = cropped.height
        guard w > 0, h > 0, overlayViewSize.width > 0, overlayViewSize.height > 0 else { return nil }

        let scaleX = CGFloat(w) / max(1, selectionInOverlayView.width)
        let scaleY = CGFloat(h) / max(1, selectionInOverlayView.height)

        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            return nil
        }

        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.beginPath()
        for (idx, pt) in polygonInOverlayView.enumerated() {
            let localX = (pt.x - selectionInOverlayView.minX) * scaleX
            // CGContext origin is bottom-left; SwiftUI overlay view Y=0 is top
            let localY = CGFloat(h) - ((pt.y - selectionInOverlayView.minY) * scaleY)
            if idx == 0 {
                ctx.move(to: CGPoint(x: localX, y: localY))
            } else {
                ctx.addLine(to: CGPoint(x: localX, y: localY))
            }
        }
        ctx.closePath()
        ctx.clip()
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: - Editor Window

    private func presentEditorPanel() {
        let screen = screenForMouse() ?? NSScreen.main ?? NSScreen.screens.first
        let defaultSize = NSSize(width: 920, height: 660)

        if editorPanel == nil {
            let p = FocusableFloatingPanel(
                contentRect: NSRect(origin: .zero, size: defaultSize),
                styleMask: [.borderless, .resizable],
                backing: .buffered,
                defer: false
            )
            p.minSize = NSSize(width: 680, height: 460)
            p.hidesOnDeactivate = false
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.appearance = NSAppearance(named: .darkAqua)
            p.contentView = NSHostingView(rootView: SnippingEditorView(
                sharedState: sharedState,
                editorState: editorState,
                onNewSnip: { [weak self] in self?.beginCapture() },
                onCopy: { [weak self] in
                    self?.copyCurrentCompositeToPasteboard()
                    self?.showToast("Copied to clipboard")
                },
                onSaveAs: { [weak self] in self?.saveAsWithDialog() },
                onOpenFolder: { [weak self] in self?.revealScreenshotsFolder() },
                onApplyCrop: { [weak self] rectInPoints, canvasPointSize in
                    self?.applyCrop(rectInPoints: rectInPoints, canvasPointSize: canvasPointSize)
                },
                onRunOCR: { [weak self] in self?.runTextRecognition() },
                onCopyOCRText: { [weak self] in self?.copyRecognizedText() },
                onMinimize: { [weak p] in p?.miniaturize(nil) },
                onZoomToggle: { [weak p] in p?.zoom(nil) },
                onClose: { [weak self] in self?.closeEditor() }
            ))
            if let screen {
                let vis = screen.visibleFrame
                let origin = NSPoint(
                    x: vis.midX - defaultSize.width / 2,
                    y: max(vis.minY + 48, vis.midY - defaultSize.height / 2)
                )
                p.setFrame(NSRect(origin: origin, size: defaultSize), display: true)
            }
            editorPanel = p
        }

        editorPanel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installEditorShortcutMonitor()
    }

    private func closeEditor() {
        editorPanel?.orderOut(nil)
        removeCaptureKeyMonitors()
    }

    private func applyCrop(rectInPoints: CGRect, canvasPointSize: CGSize) {
        guard let currentComposite = renderedCompositeCGImage() else { return }
        let pxRect = SnippingGeometry.pixelCropRect(
            selectionInViewPoints: rectInPoints,
            viewSize: canvasPointSize,
            imagePixelSize: CGSize(width: currentComposite.width, height: currentComposite.height)
        )
        guard pxRect.width >= 4, pxRect.height >= 4,
              let cropped = currentComposite.cropping(to: pxRect)
        else {
            editorState.cropSelectionRect = nil
            editorState.cropDragStart = nil
            return
        }

        editorState.baseImage = cropped
        editorState.imagePixelSize = CGSize(width: cropped.width, height: cropped.height)
        editorState.displayImage = NSImage(cgImage: cropped, size: CGSize(width: CGFloat(cropped.width) / 2.0, height: CGFloat(cropped.height) / 2.0))
        editorState.history.resetAll()
        editorState.cropSelectionRect = nil
        editorState.cropDragStart = nil
        editorState.activeTool = .pen
        editorState.recognizedLines = []
        editorState.showOCRDrawer = false
        copyCurrentCompositeToPasteboard()
        showToast("Cropped • Copied to clipboard")
    }

    private func runTextRecognition() {
        guard let cgImage = renderedCompositeCGImage() else { return }
        editorState.isRecognizingText = true
        editorState.showOCRDrawer = true
        editorState.ocrStatusMessage = "Scanning image for text..."

        Task.detached(priority: .userInitiated) { [weak self] in
            let lines = Self.recognizeTextLines(in: cgImage)
            await MainActor.run {
                guard let self else { return }
                self.editorState.isRecognizingText = false
                self.editorState.recognizedLines = lines
                if lines.isEmpty {
                    self.editorState.ocrStatusMessage = "No text detected in this snip."
                } else {
                    self.editorState.ocrStatusMessage = "Recognized \(lines.count) line(s)"
                }
            }
        }
    }

    nonisolated private static func recognizeTextLines(in cgImage: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            let observations = request.results ?? []
            return observations.compactMap { $0.topCandidates(1).first?.string }
        } catch {
            return []
        }
    }

    private func copyRecognizedText() {
        let joined = editorState.recognizedLines.joined(separator: "\n")
        guard !joined.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(joined, forType: .string)
        showToast("Copied recognized text")
    }

    // MARK: - Composite Rendering, Clipboard & Saving

    private func renderedCompositeCGImage() -> CGImage? {
        guard let base = editorState.baseImage else { return nil }
        return SnipImageRenderer.renderComposite(
            baseImage: base,
            annotations: editorState.history.annotations
        )
    }

    private func copyCurrentCompositeToPasteboard() {
        guard let cg = renderedCompositeCGImage(),
              let pngData = SnipImageRenderer.pngData(for: cg)
        else {
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(pngData, forType: .png)
        if let tiff = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2.0, height: CGFloat(cg.height) / 2.0)).tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        pb.writeObjects([item])
    }

    private func autoSaveScreenshot(image: CGImage) -> URL? {
        let fm = FileManager.default
        let dir = SnippingGeometry.defaultScreenshotsDirectory(homeDirectory: fm.homeDirectoryForCurrentUser)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(SnippingGeometry.defaultScreenshotFilename())
            guard let data = SnipImageRenderer.pngData(for: image) else { return nil }
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            ShellLogger.log("SnippingTool auto-save failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func saveAsWithDialog() {
        guard let cg = renderedCompositeCGImage(),
              let png = SnipImageRenderer.pngData(for: cg)
        else {
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.directoryURL = SnippingGeometry.defaultScreenshotsDirectory(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        panel.nameFieldStringValue = editorState.savedFileURL?.lastPathComponent
            ?? SnippingGeometry.defaultScreenshotFilename()

        if let editorPanel {
            panel.beginSheetModal(for: editorPanel) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                Task { @MainActor [weak self] in
                    do {
                        try png.write(to: url, options: .atomic)
                        self?.editorState.savedFileURL = url
                        self?.showToast("Saved \(url.lastPathComponent)")
                    } catch {
                        self?.showToast("Save failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func revealScreenshotsFolder() {
        let dir = SnippingGeometry.defaultScreenshotsDirectory(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: model.config.fileExplorerBundleID) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.open([dir], withApplicationAt: appURL, configuration: cfg)
        } else {
            NSWorkspace.shared.open(dir)
        }
    }

    private func showToast(_ msg: String) {
        toastClearWork?.cancel()
        editorState.toastMessage = msg
        let work = DispatchWorkItem { [weak self] in
            self?.editorState.toastMessage = nil
        }
        toastClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }

    // MARK: - Key Monitors & Helpers

    private func installCaptureKeyMonitors() {
        removeCaptureKeyMonitors()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.cancelCapture()
                return nil
            }
            return event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor [weak self] in
                    self?.cancelCapture()
                }
            }
        }
    }

    private func installEditorShortcutMonitor() {
        removeCaptureKeyMonitors()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.editorPanel, panel.isKeyWindow else {
                return event
            }
            let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
            if event.keyCode == 53 {
                if self.editorState.cropSelectionRect != nil {
                    self.editorState.cropSelectionRect = nil
                    return nil
                }
                if self.editorState.showOCRDrawer {
                    self.editorState.showOCRDrawer = false
                    return nil
                }
                self.closeEditor()
                return nil
            }
            if flags == .command {
                switch event.keyCode {
                case 8: // C
                    self.copyCurrentCompositeToPasteboard()
                    self.showToast("Copied to clipboard")
                    return nil
                case 1: // S
                    self.saveAsWithDialog()
                    return nil
                case 6: // Z
                    if self.editorState.history.undo() { return nil }
                case 45: // N
                    self.beginCapture()
                    return nil
                default:
                    break
                }
            } else if flags == [.command, .shift], event.keyCode == 6 {
                if self.editorState.history.redo() { return nil }
            }
            return event
        }
    }

    private func removeCaptureKeyMonitors() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
    }

    private func screenForMouse() -> NSScreen? {
        let loc = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(loc) }
    }
}

// MARK: - High-DPI Compositor

public enum SnipImageRenderer {
    public static func renderComposite(baseImage: CGImage, annotations: [SnipAnnotation]) -> CGImage? {
        guard !annotations.isEmpty else { return baseImage }

        let w = baseImage.width
        let h = baseImage.height
        guard w > 0, h > 0 else { return baseImage }

        let colorSpace = baseImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return baseImage
        }

        ctx.draw(baseImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Annotations are stored in pixel coordinates with top-left origin (matches SwiftUI Canvas over the image).
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)

        for annotation in annotations {
            drawAnnotation(annotation, in: ctx)
        }

        ctx.restoreGState()
        return ctx.makeImage() ?? baseImage
    }

    private static func drawAnnotation(_ annotation: SnipAnnotation, in ctx: CGContext) {
        let c = annotation.color
        let cgColor = CGColor(
            srgbRed: c.r,
            green: c.g,
            blue: c.b,
            alpha: c.a
        )
        ctx.saveGState()
        ctx.setStrokeColor(cgColor)
        ctx.setFillColor(cgColor)
        ctx.setLineWidth(annotation.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch annotation.kind {
        case .pen(let pts), .highlighter(let pts):
            guard let first = pts.first else { break }
            ctx.beginPath()
            ctx.move(to: first)
            for p in pts.dropFirst() {
                ctx.addLine(to: p)
            }
            if pts.count == 1 {
                ctx.addLine(to: CGPoint(x: first.x + 0.1, y: first.y + 0.1))
            }
            ctx.strokePath()

        case .arrow(let start, let end):
            ctx.beginPath()
            ctx.move(to: start)
            ctx.addLine(to: end)
            ctx.strokePath()

            let dx = end.x - start.x
            let dy = end.y - start.y
            let len = hypot(dx, dy)
            if len > 4 {
                let headLen = max(14, annotation.lineWidth * 3.8)
                let angle = atan2(dy, dx)
                let wingAngle: CGFloat = .pi / 6.5
                let p1 = CGPoint(
                    x: end.x - headLen * cos(angle - wingAngle),
                    y: end.y - headLen * sin(angle - wingAngle)
                )
                let p2 = CGPoint(
                    x: end.x - headLen * cos(angle + wingAngle),
                    y: end.y - headLen * sin(angle + wingAngle)
                )
                ctx.beginPath()
                ctx.move(to: end)
                ctx.addLine(to: p1)
                ctx.move(to: end)
                ctx.addLine(to: p2)
                ctx.strokePath()
            }

        case .rectangle(let rect):
            ctx.stroke(rect.standardized)
        }

        ctx.restoreGState()
    }

    public static func pngData(for cgImage: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            return nil
        }
        return data as Data
    }
}

// MARK: - Countdown Pill View

private struct SnipCountdownPillView: View {
    let state: SnippingToolState
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "timer")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.cyan)
            Text("Snip in \(state.countdownRemaining)s")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: 196, height: 52)
        .background(
            Capsule(style: .continuous)
                .fill(Color(red: 0.12, green: 0.12, blue: 0.15).opacity(0.96))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.20), lineWidth: 1)
                )
        )
    }
}

// MARK: - Fullscreen Capture Overlay View

private struct SnipOverlayView: View {
    let sharedState: SnippingToolState
    @Bindable var screenState: SnipScreenOverlayState
    let onSelectMode: (SnipCaptureMode) -> Void
    let onCycleDelay: () -> Void
    let onCommitRect: (CGRect) -> Void
    let onCommitFreeform: ([CGPoint]) -> Void
    let onCommitWindow: (SnipWindowTarget) -> Void
    let onCommitFullscreen: () -> Void
    let onCancel: () -> Void

    @State private var toolbarFrame: CGRect = .zero

    private var activeSelectionRect: CGRect? {
        switch sharedState.mode {
        case .rectangle:
            guard let start = screenState.dragStart, let current = screenState.dragCurrent else {
                return nil
            }
            let r = SnippingGeometry.normalizedSelectionRect(
                from: start,
                to: current,
                clampedTo: CGRect(origin: .zero, size: screenState.screenFrameCocoa.size)
            )
            return (r.width >= 3 && r.height >= 3) ? r : nil
        case .window:
            return screenState.hoveredWindowTarget?.rectInOverlayView
        case .fullscreen:
            return screenState.isMouseHoveringFullscreen
                ? CGRect(origin: .zero, size: screenState.screenFrameCocoa.size)
                : nil
        case .freeform:
            return nil
        }
    }

    var body: some View {
        let size = screenState.screenFrameCocoa.size
        ZStack(alignment: .top) {
            // Frozen screen image base
            Image(nsImage: screenState.frozenNSImage)
                .resizable()
                .interpolation(.none)
                .frame(width: size.width, height: size.height)

            // Dimmed scrim with cutout (either rect or freeform polygon)
            Canvas { ctx, canvasSize in
                ctx.fill(Path(CGRect(origin: .zero, size: canvasSize)), with: .color(Color.black.opacity(0.46)))

                if let rect = activeSelectionRect {
                    ctx.blendMode = .destinationOut
                    ctx.fill(Path(rect), with: .color(.black))
                    ctx.blendMode = .normal
                    ctx.stroke(
                        Path(rect),
                        with: .color(.white.opacity(0.95)),
                        lineWidth: 1.75
                    )
                    ctx.stroke(
                        Path(rect.insetBy(dx: -1, dy: -1)),
                        with: .color(.cyan.opacity(0.75)),
                        lineWidth: 1
                    )
                } else if sharedState.mode == .freeform && screenState.freeformPoints.count >= 2 {
                    var lasso = Path()
                    lasso.addLines(screenState.freeformPoints)
                    if screenState.freeformPoints.count >= 3 {
                        lasso.closeSubpath()
                        ctx.blendMode = .destinationOut
                        ctx.fill(lasso, with: .color(.black))
                        ctx.blendMode = .normal
                    }
                    ctx.stroke(
                        lasso,
                        with: .color(.cyan),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [6, 4])
                    )
                }
            }
            .compositingGroup()
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)

            // Live pixel size readout badge for Rectangle drag
            if sharedState.mode == .rectangle, let rect = activeSelectionRect {
                let pxRect = SnippingGeometry.pixelCropRect(
                    selectionInViewPoints: rect,
                    viewSize: size,
                    imagePixelSize: CGSize(width: screenState.frozenImage.width, height: screenState.frozenImage.height)
                )
                Text("\(Int(pxRect.width)) × \(Int(pxRect.height))")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.black.opacity(0.82))
                    )
                    .position(
                        x: min(size.width - 56, max(56, rect.midX)),
                        y: rect.maxY + 22 < size.height - 20 ? rect.maxY + 18 : max(24, rect.minY - 18)
                    )
                    .allowsHitTesting(false)
            }

            // Interactive mouse tracking & drag capture layer
            SnipCaptureInteractionView(
                mode: sharedState.mode,
                excludedRectProvider: { toolbarFrame },
                onHoverPoint: { pt in
                    handleHover(at: pt)
                },
                onDragStart: { pt in
                    handleDragStart(at: pt)
                },
                onDragChanged: { pt in
                    handleDragChanged(at: pt)
                },
                onDragEnded: { pt in
                    handleDragEnded(at: pt)
                }
            )
            .frame(width: size.width, height: size.height)

            // Windows 11 Floating Top Mode Bar (placed cleanly below camera notch)
            SnipModeFloatingToolbar(
                mode: sharedState.mode,
                delay: sharedState.delay,
                onSelectMode: { chosen in
                    if chosen == .fullscreen && sharedState.mode == .fullscreen {
                        onCommitFullscreen()
                    } else {
                        onSelectMode(chosen)
                    }
                },
                onCycleDelay: onCycleDelay,
                onFullscreenNow: onCommitFullscreen,
                onCancel: onCancel
            )
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { toolbarFrame = geo.frame(in: .named("SnipOverlaySpace")) }
                        .onChange(of: geo.size) { _, _ in toolbarFrame = geo.frame(in: .named("SnipOverlaySpace")) }
                }
            )
            .padding(.top, max(16, screenState.safeAreaTop + 14))
        }
        .coordinateSpace(name: "SnipOverlaySpace")
        .frame(width: size.width, height: size.height)
    }

    private func handleHover(at pt: CGPoint) {
        switch sharedState.mode {
        case .window:
            screenState.hoveredWindowTarget = screenState.windowTargets.first {
                $0.rectInOverlayView.contains(pt)
            }
            screenState.isMouseHoveringFullscreen = false
        case .fullscreen:
            screenState.isMouseHoveringFullscreen = true
            screenState.hoveredWindowTarget = nil
        case .rectangle, .freeform:
            screenState.hoveredWindowTarget = nil
            screenState.isMouseHoveringFullscreen = false
        }
    }

    private func handleDragStart(at pt: CGPoint) {
        switch sharedState.mode {
        case .rectangle:
            screenState.dragStart = pt
            screenState.dragCurrent = pt
        case .freeform:
            screenState.freeformPoints = [pt]
        case .window:
            screenState.hoveredWindowTarget = screenState.windowTargets.first {
                $0.rectInOverlayView.contains(pt)
            }
        case .fullscreen:
            screenState.isMouseHoveringFullscreen = true
        }
    }

    private func handleDragChanged(at pt: CGPoint) {
        switch sharedState.mode {
        case .rectangle:
            screenState.dragCurrent = pt
        case .freeform:
            screenState.freeformPoints.append(pt)
        case .window, .fullscreen:
            break
        }
    }

    private func handleDragEnded(at pt: CGPoint) {
        switch sharedState.mode {
        case .rectangle:
            let start = screenState.dragStart ?? pt
            let r = SnippingGeometry.normalizedSelectionRect(
                from: start,
                to: pt,
                clampedTo: CGRect(origin: .zero, size: screenState.screenFrameCocoa.size)
            )
            screenState.dragStart = nil
            screenState.dragCurrent = nil
            if r.width >= 4 && r.height >= 4 {
                onCommitRect(r)
            }
        case .freeform:
            let pts = screenState.freeformPoints
            screenState.freeformPoints.removeAll()
            onCommitFreeform(pts)
        case .window:
            if let hit = screenState.windowTargets.first(where: { $0.rectInOverlayView.contains(pt) }) {
                onCommitWindow(hit)
            }
        case .fullscreen:
            onCommitFullscreen()
        }
    }
}

private struct SnipModeFloatingToolbar: View {
    let mode: SnipCaptureMode
    let delay: SnipDelayOption
    let onSelectMode: (SnipCaptureMode) -> Void
    let onCycleDelay: () -> Void
    let onFullscreenNow: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SnipCaptureMode.allCases, id: \.self) { m in
                Button {
                    onSelectMode(m)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: m.systemSymbolName)
                            .font(.system(size: 13, weight: .medium))
                        Text(m.displayTitle)
                            .font(.system(size: 11.5, weight: mode == m ? .semibold : .regular))
                    }
                    .foregroundStyle(mode == m ? .white : .white.opacity(0.75))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(mode == m ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.06))
                    )
                }
                .buttonStyle(.plain)
            }

            Divider()
                .frame(height: 18)
                .padding(.horizontal, 4)

            Button(action: onCycleDelay) {
                HStack(spacing: 4) {
                    Image(systemName: "timer")
                        .font(.system(size: 12))
                    Text(delay.shortLabel)
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.88))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
            }
            .buttonStyle(.plain)
            .help("Cycle capture delay (No delay / 3s / 5s)")

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .help("Cancel snip (Esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(red: 0.12, green: 0.12, blue: 0.14).opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.55), radius: 14, x: 0, y: 6)
    }
}

private struct SnipCaptureInteractionView: NSViewRepresentable {
    let mode: SnipCaptureMode
    let excludedRectProvider: () -> CGRect
    let onHoverPoint: (CGPoint) -> Void
    let onDragStart: (CGPoint) -> Void
    let onDragChanged: (CGPoint) -> Void
    let onDragEnded: (CGPoint) -> Void

    func makeNSView(context: Context) -> SnipCaptureInteractionNSView {
        let v = SnipCaptureInteractionNSView()
        v.updateCallbacks(
            mode: mode,
            excludedRectProvider: excludedRectProvider,
            onHoverPoint: onHoverPoint,
            onDragStart: onDragStart,
            onDragChanged: onDragChanged,
            onDragEnded: onDragEnded
        )
        return v
    }

    func updateNSView(_ nsView: SnipCaptureInteractionNSView, context: Context) {
        nsView.updateCallbacks(
            mode: mode,
            excludedRectProvider: excludedRectProvider,
            onHoverPoint: onHoverPoint,
            onDragStart: onDragStart,
            onDragChanged: onDragChanged,
            onDragEnded: onDragEnded
        )
    }
}

private final class SnipCaptureInteractionNSView: NSView {
    private var mode: SnipCaptureMode = .rectangle
    private var excludedRectProvider: (() -> CGRect)?
    private var onHoverPoint: ((CGPoint) -> Void)?
    private var onDragStart: ((CGPoint) -> Void)?
    private var onDragChanged: ((CGPoint) -> Void)?
    private var onDragEnded: ((CGPoint) -> Void)?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func updateCallbacks(
        mode: SnipCaptureMode,
        excludedRectProvider: @escaping () -> CGRect,
        onHoverPoint: @escaping (CGPoint) -> Void,
        onDragStart: @escaping (CGPoint) -> Void,
        onDragChanged: @escaping (CGPoint) -> Void,
        onDragEnded: @escaping (CGPoint) -> Void
    ) {
        self.mode = mode
        self.excludedRectProvider = excludedRectProvider
        self.onHoverPoint = onHoverPoint
        self.onDragStart = onDragStart
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
        window?.invalidateCursorRects(for: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        let cursor: NSCursor = (mode == .rectangle || mode == .freeform) ? .crosshair : .pointingHand
        addCursorRect(bounds, cursor: cursor)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if let excluded = excludedRectProvider?(), excluded.contains(local) {
            return nil
        }
        return bounds.contains(local) ? self : nil
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        onHoverPoint?(pt)
    }

    override func mouseDown(with event: NSEvent) {
        let start = convert(event.locationInWindow, from: nil)
        onDragStart?(start)
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let pt = convert(next.locationInWindow, from: nil)
            switch next.type {
            case .leftMouseDragged:
                onDragChanged?(pt)
            case .leftMouseUp:
                onDragEnded?(pt)
                return
            default:
                break
            }
        }
        onDragEnded?(start)
    }
}

// MARK: - Snipping Tool Editor Window View

private struct SnippingEditorView: View {
    @Bindable var sharedState: SnippingToolState
    @Bindable var editorState: SnipEditorState
    let onNewSnip: () -> Void
    let onCopy: () -> Void
    let onSaveAs: () -> Void
    let onOpenFolder: () -> Void
    let onApplyCrop: (CGRect, CGSize) -> Void
    let onRunOCR: () -> Void
    let onCopyOCRText: () -> Void
    let onMinimize: () -> Void
    let onZoomToggle: () -> Void
    let onClose: () -> Void

    @State private var lastCanvasPointSize: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
            titlebar
            toolbar
            Divider().overlay(Color.white.opacity(0.08))

            ZStack(alignment: .top) {
                Color(red: 0.085, green: 0.088, blue: 0.10)

                if let displayImage = editorState.displayImage {
                    GeometryReader { geo in
                        let canvasSize = fittedCanvasSize(
                            imagePixels: editorState.imagePixelSize,
                            container: CGSize(
                                width: max(120, geo.size.width - 32),
                                height: max(120, geo.size.height - 32)
                            )
                        )
                        ZStack {
                            canvasView(image: displayImage, canvasSize: canvasSize)
                                .shadow(color: Color.black.opacity(0.5), radius: 14, x: 0, y: 6)
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .onAppear { lastCanvasPointSize = canvasSize }
                        .onChange(of: canvasSize) { _, newSize in lastCanvasPointSize = newSize }
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "scissors")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("Press Win+Shift+S or click + New to capture a snip")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if let toast = editorState.toastMessage {
                    Text(toast)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color(red: 0.13, green: 0.15, blue: 0.19).opacity(0.95))
                                .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                        )
                        .padding(.top, 12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if editorState.cropSelectionRect != nil && editorState.activeTool == .crop {
                cropActionBar
            }

            if editorState.showOCRDrawer {
                ocrDrawer
            }
        }
        .background(Color(red: 0.115, green: 0.115, blue: 0.132))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
        )
    }

    private var titlebar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "scissors")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.cyan)
                Text("Snipping Tool")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.9))
                if editorState.imagePixelSize.width > 0 {
                    Text("\(Int(editorState.imagePixelSize.width)) × \(Int(editorState.imagePixelSize.height)) px")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
            }
            .padding(.leading, 12)

            SnipWindowDragHandle(onDoubleClick: onZoomToggle)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 0) {
                editorCaptionButton("minus", hoverFill: Color.white.opacity(0.12), action: onMinimize)
                editorCaptionButton("square", hoverFill: Color.white.opacity(0.12), action: onZoomToggle)
                editorCaptionButton("xmark", hoverFill: Color(red: 0.77, green: 0.17, blue: 0.11), action: onClose)
            }
        }
        .frame(height: 34)
        .background(Color(red: 0.115, green: 0.115, blue: 0.132))
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button(action: onNewSnip) {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 11.5, weight: .bold))
                    Text("New")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor)
                )
            }
            .buttonStyle(.plain)
            .help("New Snip (Cmd+N / Win+Shift+S)")

            Menu {
                ForEach(SnipCaptureMode.allCases, id: \.self) { m in
                    Button {
                        sharedState.mode = m
                    } label: {
                        Label(m.displayTitle, systemImage: m.systemSymbolName)
                    }
                }
                Divider()
                ForEach(SnipDelayOption.allCases, id: \.self) { d in
                    Button {
                        sharedState.delay = d
                    } label: {
                        Text(d == .none ? "Delay: None" : "Delay: \(d.shortLabel)")
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: sharedState.mode.systemSymbolName)
                        .font(.system(size: 12))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                }
                .foregroundStyle(.white.opacity(0.88))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Divider().frame(height: 20).padding(.horizontal, 2)

            ForEach(SnipToolKind.allCases, id: \.self) { tool in
                Button {
                    editorState.activeTool = tool
                    if tool != .crop {
                        editorState.cropSelectionRect = nil
                        editorState.cropDragStart = nil
                    }
                } label: {
                    Image(systemName: tool.systemSymbolName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(editorState.activeTool == tool ? .cyan : .white.opacity(0.82))
                        .frame(width: 30, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(editorState.activeTool == tool ? Color.white.opacity(0.16) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .help(tool.displayTitle)
            }

            // Color swatches for Pen/Arrow/Rect or Highlighter
            if editorState.activeTool != .eraser && editorState.activeTool != .crop {
                let presets = editorState.activeTool == .highlighter
                    ? SnipColorRGB.highlighterPresets
                    : SnipColorRGB.penPresets
                HStack(spacing: 4) {
                    ForEach(presets, id: \.self) { swatch in
                        let isSelected = editorState.activeColor == swatch
                        Button {
                            if editorState.activeTool == .highlighter {
                                editorState.selectedHighlighterColor = swatch
                            } else {
                                editorState.selectedPenColor = swatch
                            }
                        } label: {
                            Circle()
                                .fill(Color(red: swatch.r, green: swatch.g, blue: swatch.b, opacity: min(1.0, swatch.a + 0.35)))
                                .frame(width: 14, height: 14)
                                .overlay(
                                    Circle()
                                        .strokeBorder(isSelected ? Color.white : Color.white.opacity(0.25), lineWidth: isSelected ? 2 : 0.75)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 4)
            }

            Divider().frame(height: 20).padding(.horizontal, 2)

            Button {
                _ = editorState.history.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 12.5))
                    .foregroundStyle(editorState.history.canUndo ? .white : .white.opacity(0.32))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(!editorState.history.canUndo)
            .help("Undo (Cmd+Z)")

            Button {
                _ = editorState.history.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 12.5))
                    .foregroundStyle(editorState.history.canRedo ? .white : .white.opacity(0.32))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(!editorState.history.canRedo)
            .help("Redo (Cmd+Shift+Z)")

            Spacer()

            Button(action: onRunOCR) {
                HStack(spacing: 4) {
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 12.5))
                    Text("Text actions")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(editorState.showOCRDrawer ? .cyan : .white.opacity(0.9))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(editorState.showOCRDrawer ? Color.cyan.opacity(0.18) : Color.white.opacity(0.08))
                )
            }
            .buttonStyle(.plain)
            .disabled(editorState.baseImage == nil)

            Button(action: onCopy) {
                HStack(spacing: 4) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                    Text("Copy")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .disabled(editorState.baseImage == nil)
            .help("Copy image (Cmd+C)")

            Button(action: onSaveAs) {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 12))
                    Text("Save As")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .disabled(editorState.baseImage == nil)
            .help("Save As PNG (Cmd+S)")

            Button(action: onOpenFolder) {
                Image(systemName: "folder")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.86))
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Open ~/Pictures/Screenshots")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(red: 0.135, green: 0.138, blue: 0.158))
    }

    private func canvasView(image: NSImage, canvasSize: CGSize) -> some View {
        let pxW = max(1, editorState.imagePixelSize.width)
        let pxH = max(1, editorState.imagePixelSize.height)
        let toViewX = canvasSize.width / pxW
        let toViewY = canvasSize.height / pxH

        return ZStack {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: canvasSize.width, height: canvasSize.height)

            Canvas { ctx, _ in
                let scaleToPixels = pxW / max(1, canvasSize.width)
                let all = editorState.history.annotations + (editorState.inProgressAnnotation.map { [$0] } ?? [])
                for item in all {
                    drawCanvasAnnotation(item, toViewX: toViewX, toViewY: toViewY, scaleFromPixels: 1.0 / scaleToPixels, in: &ctx)
                }

                if editorState.activeTool == .crop, let cropRect = editorState.cropSelectionRect {
                    var scrim = Path(CGRect(origin: .zero, size: canvasSize))
                    scrim.addRect(cropRect)
                    ctx.fill(scrim, with: .color(Color.black.opacity(0.45)), style: FillStyle(eoFill: true))
                    ctx.stroke(Path(cropRect), with: .color(.cyan), lineWidth: 1.5)
                }
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .allowsHitTesting(false)
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    handleCanvasDragChanged(value: value, canvasSize: canvasSize)
                }
                .onEnded { value in
                    handleCanvasDragEnded(value: value, canvasSize: canvasSize)
                }
        )
    }

    private func handleCanvasDragChanged(value: DragGesture.Value, canvasSize: CGSize) {
        let clampedX = max(0, min(canvasSize.width, value.location.x))
        let clampedY = max(0, min(canvasSize.height, value.location.y))
        let scaleX = editorState.imagePixelSize.width / max(1, canvasSize.width)
        let scaleY = editorState.imagePixelSize.height / max(1, canvasSize.height)
        let ptPx = CGPoint(x: clampedX * scaleX, y: clampedY * scaleY)
        let startPx = CGPoint(
            x: max(0, min(canvasSize.width, value.startLocation.x)) * scaleX,
            y: max(0, min(canvasSize.height, value.startLocation.y)) * scaleY
        )

        switch editorState.activeTool {
        case .pen:
            var pts: [CGPoint]
            if case .pen(let existing) = editorState.inProgressAnnotation?.kind {
                pts = existing
            } else {
                pts = []
            }
            pts.append(ptPx)
            editorState.inProgressAnnotation = SnipAnnotation(
                kind: .pen(points: pts),
                color: editorState.selectedPenColor,
                lineWidth: editorState.penWidth * scaleX
            )
        case .highlighter:
            var pts: [CGPoint]
            if case .highlighter(let existing) = editorState.inProgressAnnotation?.kind {
                pts = existing
            } else {
                pts = []
            }
            pts.append(ptPx)
            editorState.inProgressAnnotation = SnipAnnotation(
                kind: .highlighter(points: pts),
                color: editorState.selectedHighlighterColor,
                lineWidth: editorState.highlighterWidth * scaleX
            )
        case .arrow:
            editorState.inProgressAnnotation = SnipAnnotation(
                kind: .arrow(start: startPx, end: ptPx),
                color: editorState.selectedPenColor,
                lineWidth: editorState.penWidth * scaleX
            )
        case .rectangle:
            let r = SnippingGeometry.normalizedSelectionRect(
                from: startPx,
                to: ptPx,
                clampedTo: CGRect(origin: .zero, size: editorState.imagePixelSize)
            )
            editorState.inProgressAnnotation = SnipAnnotation(
                kind: .rectangle(rect: r),
                color: editorState.selectedPenColor,
                lineWidth: editorState.penWidth * scaleX
            )
        case .eraser:
            editorState.history.erase(near: ptPx, tolerance: 14 * scaleX)
        case .crop:
            let startPt = editorState.cropDragStart ?? CGPoint(
                x: max(0, min(canvasSize.width, value.startLocation.x)),
                y: max(0, min(canvasSize.height, value.startLocation.y))
            )
            editorState.cropDragStart = startPt
            editorState.cropSelectionRect = SnippingGeometry.normalizedSelectionRect(
                from: startPt,
                to: CGPoint(x: clampedX, y: clampedY),
                clampedTo: CGRect(origin: .zero, size: canvasSize)
            )
        }
    }

    private func handleCanvasDragEnded(value: DragGesture.Value, canvasSize: CGSize) {
        if let pending = editorState.inProgressAnnotation {
            editorState.history.append(pending)
            editorState.inProgressAnnotation = nil
        }
        editorState.cropDragStart = nil
    }

    private func drawCanvasAnnotation(
        _ annotation: SnipAnnotation,
        toViewX: CGFloat,
        toViewY: CGFloat,
        scaleFromPixels: CGFloat,
        in ctx: inout GraphicsContext
    ) {
        let color = Color(red: annotation.color.r, green: annotation.color.g, blue: annotation.color.b, opacity: annotation.color.a)
        let style = StrokeStyle(
            lineWidth: max(1, annotation.lineWidth * scaleFromPixels),
            lineCap: .round,
            lineJoin: .round
        )

        switch annotation.kind {
        case .pen(let pts), .highlighter(let pts):
            guard let first = pts.first else { return }
            var path = Path()
            path.move(to: CGPoint(x: first.x * toViewX, y: first.y * toViewY))
            for p in pts.dropFirst() {
                path.addLine(to: CGPoint(x: p.x * toViewX, y: p.y * toViewY))
            }
            if pts.count == 1 {
                path.addLine(to: CGPoint(x: first.x * toViewX + 0.5, y: first.y * toViewY + 0.5))
            }
            ctx.stroke(path, with: .color(color), style: style)

        case .arrow(let start, let end):
            let s = CGPoint(x: start.x * toViewX, y: start.y * toViewY)
            let e = CGPoint(x: end.x * toViewX, y: end.y * toViewY)
            var path = Path()
            path.move(to: s)
            path.addLine(to: e)
            let dx = e.x - s.x
            let dy = e.y - s.y
            if hypot(dx, dy) > 4 {
                let headLen = max(10, style.lineWidth * 3.8)
                let angle = atan2(dy, dx)
                let wing: CGFloat = .pi / 6.5
                path.move(to: e)
                path.addLine(to: CGPoint(x: e.x - headLen * cos(angle - wing), y: e.y - headLen * sin(angle - wing)))
                path.move(to: e)
                path.addLine(to: CGPoint(x: e.x - headLen * cos(angle + wing), y: e.y - headLen * sin(angle + wing)))
            }
            ctx.stroke(path, with: .color(color), style: style)

        case .rectangle(let rect):
            let vr = CGRect(
                x: rect.minX * toViewX,
                y: rect.minY * toViewY,
                width: rect.width * toViewX,
                height: rect.height * toViewY
            )
            ctx.stroke(Path(vr), with: .color(color), style: style)
        }
    }

    private var cropActionBar: some View {
        HStack(spacing: 12) {
            Text("Drag to adjust crop region")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.8))
            Spacer()
            Button("Cancel") {
                editorState.cropSelectionRect = nil
                editorState.activeTool = .pen
            }
            .buttonStyle(.bordered)

            Button("Apply Crop") {
                if let rect = editorState.cropSelectionRect {
                    onApplyCrop(rect, lastCanvasPointSize)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(red: 0.14, green: 0.15, blue: 0.18))
    }

    private var ocrDrawer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(editorState.ocrStatusMessage ?? "Recognized Text")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                if !editorState.recognizedLines.isEmpty {
                    Button("Copy all text", action: onCopyOCRText)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                Button {
                    editorState.showOCRDrawer = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .buttonStyle(.plain)
            }

            if editorState.isRecognizingText {
                ProgressView()
                    .controlSize(.small)
                    .padding(.vertical, 8)
            } else if !editorState.recognizedLines.isEmpty {
                ScrollView {
                    Text(editorState.recognizedLines.joined(separator: "\n"))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
            }
        }
        .padding(12)
        .background(Color(red: 0.13, green: 0.14, blue: 0.16))
        .overlay(alignment: .top) {
            Rectangle().frame(height: 0.5).foregroundStyle(Color.white.opacity(0.12))
        }
    }

    private func editorCaptionButton(_ symbol: String, hoverFill: Color, action: @escaping () -> Void) -> some View {
        SnipCaptionButton(symbol: symbol, hoverFill: hoverFill, action: action)
    }

    private func fittedCanvasSize(imagePixels: CGSize, container: CGSize) -> CGSize {
        guard imagePixels.width > 0, imagePixels.height > 0, container.width > 0, container.height > 0 else {
            return container
        }
        let maxPtW = min(container.width, imagePixels.width)
        let maxPtH = min(container.height, imagePixels.height)
        let scale = min(maxPtW / imagePixels.width, maxPtH / imagePixels.height)
        return CGSize(
            width: max(40, (imagePixels.width * scale).rounded()),
            height: max(40, (imagePixels.height * scale).rounded())
        )
    }
}

private struct SnipCaptionButton: View {
    let symbol: String
    let hoverFill: Color
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(hovered ? .white : Color.white.opacity(0.84))
                .frame(width: 42, height: 34)
                .background(hovered ? hoverFill : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct SnipWindowDragHandle: NSViewRepresentable {
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> SnipDragHandleNSView {
        let v = SnipDragHandleNSView()
        v.onDoubleClick = onDoubleClick
        return v
    }

    func updateNSView(_ nsView: SnipDragHandleNSView, context: Context) {
        nsView.onDoubleClick = onDoubleClick
    }
}

private final class SnipDragHandleNSView: NSView {
    var onDoubleClick: (() -> Void)?
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        } else {
            window?.performDrag(with: event)
        }
    }
}
