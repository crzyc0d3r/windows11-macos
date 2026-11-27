import AppKit
import AVFoundation
import AVKit
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
    public var outputKind: SnipOutputKind = .photo
    public var mode: SnipCaptureMode = .rectangle
    public var delay: SnipDelayOption = .none
    public var isCapturing: Bool = false
    public var countdownRemaining: Int = 0
    public var isRecordingArmed: Bool = false
    public var isRecordingActive: Bool = false
    public var recordingElapsed: TimeInterval = 0
    public var captureSystemAudio: Bool = true
    public var captureMicrophone: Bool = false
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

    var videoURL: URL?
    var videoDuration: TimeInterval = 0
    var videoDimensions: CGSize = .zero
    var isVideoPlaybackActive: Bool = false
    var isVideoPreview: Bool { videoURL != nil }

    var activeTool: SnipToolKind = .pen
    var selectedPenColor: SnipColorRGB = .red
    var selectedHighlighterColor: SnipColorRGB = SnipColorRGB.highlighterPresets[0]
    var penWidth: CGFloat = 4
    var highlighterWidth: CGFloat = 18
    var textFontSize: CGFloat = 24

    var activeTextDraftOriginPx: CGPoint?
    var activeTextDraft: String = ""
    var activeTextDraftCanvasScale: CGFloat = 1.0
    var isEditingText: Bool { activeTextDraftOriginPx != nil }

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

    @discardableResult
    func commitTextDraft() -> Bool {
        guard let origin = activeTextDraftOriginPx else { return false }
        let trimmed = activeTextDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        activeTextDraftOriginPx = nil
        activeTextDraft = ""
        guard !trimmed.isEmpty else { return false }
        let pixelFontSize = max(12, textFontSize * max(0.5, activeTextDraftCanvasScale))
        history.append(SnipAnnotation(
            kind: .text(origin: origin, text: trimmed, fontSize: pixelFontSize),
            color: selectedPenColor,
            lineWidth: 2
        ))
        return true
    }

    func cancelTextDraft() {
        activeTextDraftOriginPx = nil
        activeTextDraft = ""
    }
}

@MainActor
public final class SnippingToolController {
    private struct PendingRecordingSpec {
        let displayID: CGDirectDisplayID
        let screenFrameCocoa: CGRect
        let backingScale: CGFloat
        let rectInDisplayPoints: CGRect
    }

    private let model: RunningAppsModel
    private let sharedState = SnippingToolState()
    private let editorState = SnipEditorState()
    private let videoRecorder = SnippingVideoRecorder()

    private var overlayPanels: [CGDirectDisplayID: FocusableFloatingPanel] = [:]
    private var overlayStates: [CGDirectDisplayID: SnipScreenOverlayState] = [:]
    private var countdownPanel: NonActivatingFloatingPanel?
    private var recordingBorderPanel: NonActivatingFloatingPanel?
    private var recordingHUDPanel: NonActivatingFloatingPanel?
    private var editorPanel: FocusableFloatingPanel?

    private var pendingRecordingSpec: PendingRecordingSpec?
    private var recordingTimer: Timer?
    private var recordingStartUptime: TimeInterval = 0

    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var countdownWorkItem: DispatchWorkItem?
    private var toastClearWork: DispatchWorkItem?
    private var shouldRestoreEditorOnCancel = false

    public init(model: RunningAppsModel) {
        self.model = model
    }

    public func openEditorOrCapture() {
        if sharedState.isRecordingArmed || sharedState.isRecordingActive {
            recordingHUDPanel?.orderFrontRegardless()
            return
        }
        if (editorState.baseImage != nil || editorState.videoURL != nil), let editorPanel {
            if editorState.isVideoPreview {
                editorState.isVideoPlaybackActive = true
            }
            editorPanel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            installEditorShortcutMonitor()
            return
        }
        beginCapture()
    }

    public func beginCapture(mode: SnipCaptureMode? = nil) {
        if let mode {
            sharedState.mode = mode
        }
        if sharedState.outputKind == .video && sharedState.mode == .freeform {
            sharedState.mode = .rectangle
        }
        if sharedState.isRecordingActive {
            Task { @MainActor [weak self] in
                await self?.stopActiveVideoRecording()
            }
            return
        }
        if sharedState.isRecordingArmed {
            cancelVideoRecording()
        }
        if sharedState.isCapturing {
            cancelCapture()
        }

        editorState.commitTextDraft()
        if editorState.isVideoPreview {
            editorState.isVideoPlaybackActive = false
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

        if shouldRestoreEditorOnCancel, (editorState.baseImage != nil || editorState.videoURL != nil) {
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
                onSelectOutputKind: { [weak self] kind in
                    guard let self else { return }
                    self.sharedState.outputKind = kind
                    if kind == .video && self.sharedState.mode == .freeform {
                        self.sharedState.mode = .rectangle
                    }
                    state.dragStart = nil
                    state.dragCurrent = nil
                    state.freeformPoints.removeAll()
                    state.hoveredWindowTarget = nil
                },
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
        if sharedState.outputKind == .video {
            let bounds = CGRect(origin: .zero, size: overlayState.screenFrameCocoa.size)
            let clipped = rectInView.intersection(bounds)
            guard clipped.width >= 16, clipped.height >= 16 else {
                cancelCapture()
                return
            }
            let matchingScreen = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == overlayState.displayID
            }
            let scale = min(2.0, matchingScreen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0)
            tearDownOverlaysForCaptureCompletion()
            armVideoRecording(
                displayID: overlayState.displayID,
                screenFrameCocoa: overlayState.screenFrameCocoa,
                backingScale: scale,
                rectInDisplayPoints: clipped
            )
            return
        }

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
        if sharedState.outputKind == .video {
            let fullRect = CGRect(origin: .zero, size: overlayState.screenFrameCocoa.size)
            completeCapture(from: overlayState, rectInView: fullRect, freeformPolygon: nil)
            return
        }
        let full = overlayState.frozenImage
        tearDownOverlaysForCaptureCompletion()
        deliverCapturedImage(full)
    }

    // MARK: - Video Screen Recording Flow

    private func armVideoRecording(
        displayID: CGDirectDisplayID,
        screenFrameCocoa: CGRect,
        backingScale: CGFloat,
        rectInDisplayPoints: CGRect
    ) {
        pendingRecordingSpec = PendingRecordingSpec(
            displayID: displayID,
            screenFrameCocoa: screenFrameCocoa,
            backingScale: backingScale,
            rectInDisplayPoints: rectInDisplayPoints
        )
        sharedState.isRecordingArmed = true
        sharedState.isRecordingActive = false
        sharedState.recordingElapsed = 0

        presentRecordingBorderPanel(screenFrameCocoa: screenFrameCocoa, rectInDisplayPoints: rectInDisplayPoints)
        presentRecordingHUDPanel(screenFrameCocoa: screenFrameCocoa, rectInDisplayPoints: rectInDisplayPoints)
        installArmedRecordingEscMonitor()
    }

    private func presentRecordingBorderPanel(screenFrameCocoa: CGRect, rectInDisplayPoints: CGRect) {
        let pad: CGFloat = 4
        let cocoaX = screenFrameCocoa.minX + rectInDisplayPoints.minX - pad
        let cocoaY = screenFrameCocoa.maxY - rectInDisplayPoints.maxY - pad
        let rawRect = NSRect(
            x: cocoaX,
            y: cocoaY,
            width: rectInDisplayPoints.width + pad * 2,
            height: rectInDisplayPoints.height + pad * 2
        )
        let clampedRect = rawRect.intersection(screenFrameCocoa)
        guard !clampedRect.isNull, clampedRect.width >= 16, clampedRect.height >= 16 else { return }

        let p: NonActivatingFloatingPanel
        if let existing = recordingBorderPanel {
            p = existing
        } else {
            let created = NonActivatingFloatingPanel(
                contentRect: clampedRect,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            created.allowsNotchAreaPlacement = true
            created.hidesOnDeactivate = false
            created.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3)
            created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            created.backgroundColor = .clear
            created.isOpaque = false
            created.hasShadow = false
            created.ignoresMouseEvents = true
            created.contentView = NSHostingView(rootView: SnipRecordingRegionBorderView(state: sharedState))
            recordingBorderPanel = created
            p = created
        }
        p.setFrame(clampedRect, display: true)
        p.orderFrontRegardless()
    }

    private func presentRecordingHUDPanel(screenFrameCocoa: CGRect, rectInDisplayPoints: CGRect) {
        let hudSize = NSSize(width: 344, height: 48)
        let rectTopCocoa = screenFrameCocoa.maxY - rectInDisplayPoints.minY
        let rectMidXCocoa = screenFrameCocoa.minX + rectInDisplayPoints.midX
        let maxHUDY = screenFrameCocoa.maxY - 46 - hudSize.height
        let preferredAboveY = rectTopCocoa + 10
        let hudY: CGFloat
        if preferredAboveY <= maxHUDY {
            hudY = preferredAboveY
        } else {
            hudY = max(screenFrameCocoa.minY + 56, min(maxHUDY, rectTopCocoa - hudSize.height - 12))
        }
        let hudX = max(screenFrameCocoa.minX + 12, min(screenFrameCocoa.maxX - hudSize.width - 12, rectMidXCocoa - hudSize.width / 2))
        let hudFrame = NSRect(x: hudX, y: hudY, width: hudSize.width, height: hudSize.height)

        let p: NonActivatingFloatingPanel
        if let existing = recordingHUDPanel {
            p = existing
        } else {
            let created = NonActivatingFloatingPanel(
                contentRect: hudFrame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            created.allowsNotchAreaPlacement = true
            created.hidesOnDeactivate = false
            created.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 4)
            created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            created.backgroundColor = .clear
            created.isOpaque = false
            created.hasShadow = true
            created.appearance = NSAppearance(named: .darkAqua)
            created.contentView = NSHostingView(rootView: SnipRecordingHUDView(
                state: sharedState,
                onStart: { [weak self] in self?.startArmedVideoRecording() },
                onStop: { [weak self] in
                    Task { @MainActor [weak self] in
                        await self?.stopActiveVideoRecording()
                    }
                },
                onToggleAudio: { [weak self] in
                    self?.sharedState.captureSystemAudio.toggle()
                },
                onToggleMic: { [weak self] in
                    self?.sharedState.captureMicrophone.toggle()
                },
                onCancel: { [weak self] in self?.cancelVideoRecording() }
            ))
            recordingHUDPanel = created
            p = created
        }
        p.setFrame(hudFrame, display: true)
        p.orderFrontRegardless()
    }

    private func installArmedRecordingEscMonitor() {
        removeCaptureKeyMonitors()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.sharedState.isRecordingArmed, !self.sharedState.isRecordingActive else {
                return event
            }
            if event.keyCode == 53 {
                self.cancelVideoRecording()
                return nil
            }
            return event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor [weak self] in
                    guard let self, self.sharedState.isRecordingArmed, !self.sharedState.isRecordingActive else { return }
                    self.cancelVideoRecording()
                }
            }
        }
    }

    private func startArmedVideoRecording() {
        guard let spec = pendingRecordingSpec, !sharedState.isRecordingActive else { return }
        removeCaptureKeyMonitors()

        let fm = FileManager.default
        let dir = SnippingGeometry.defaultRecordingsDirectory(homeDirectory: fm.homeDirectoryForCurrentUser)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let outputURL = dir.appendingPathComponent(SnippingGeometry.defaultRecordingFilename())

        let excludedWindowIDs: Set<CGWindowID> = Set(
            [recordingBorderPanel, recordingHUDPanel, editorPanel, countdownPanel]
                .compactMap { $0 }
                .filter { $0.windowNumber > 0 }
                .map { CGWindowID($0.windowNumber) }
        )

        let captureSystemAudio = sharedState.captureSystemAudio
        let captureMicrophone = sharedState.captureMicrophone

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.videoRecorder.startRecording(
                    displayID: spec.displayID,
                    sourceRectInDisplayPoints: spec.rectInDisplayPoints,
                    backingScale: spec.backingScale,
                    outputURL: outputURL,
                    captureSystemAudio: captureSystemAudio,
                    captureMicrophone: captureMicrophone,
                    excludedWindowIDs: excludedWindowIDs,
                    onUnexpectedError: { [weak self] message in
                        guard let self else { return }
                        ShellLogger.log("SnippingTool unexpected recording error: \(message)")
                        self.tearDownRecordingUI()
                        self.showToast("Recording error: \(message)")
                        self.presentEditorPanel()
                    }
                )
                self.sharedState.isRecordingActive = true
                self.sharedState.recordingElapsed = 0
                self.recordingStartUptime = ProcessInfo.processInfo.systemUptime
                self.recordingTimer?.invalidate()
                self.recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.sharedState.isRecordingActive else { return }
                        self.sharedState.recordingElapsed = max(0, ProcessInfo.processInfo.systemUptime - self.recordingStartUptime)
                    }
                }
            } catch {
                ShellLogger.log("SnippingTool recording start failed: \(error.localizedDescription)")
                self.tearDownRecordingUI()
                self.showToast("Recording failed: \(error.localizedDescription)")
                self.presentEditorPanel()
            }
        }
    }

    private func stopActiveVideoRecording() async {
        guard sharedState.isRecordingActive else { return }
        recordingTimer?.invalidate()
        recordingTimer = nil

        do {
            let outputURL = try await videoRecorder.stopRecording()
            tearDownRecordingUI()
            await deliverRecordedVideo(url: outputURL)
        } catch {
            ShellLogger.log("SnippingTool stop recording failed: \(error.localizedDescription)")
            tearDownRecordingUI()
            showToast("Recording failed: \(error.localizedDescription)")
            presentEditorPanel()
        }
    }

    private func cancelVideoRecording() {
        removeCaptureKeyMonitors()
        recordingTimer?.invalidate()
        recordingTimer = nil
        let wasActive = sharedState.isRecordingActive
        tearDownRecordingUI()
        if wasActive || videoRecorder.isRecording {
            Task { @MainActor [weak self] in
                await self?.videoRecorder.cancelRecording()
            }
        }
        if shouldRestoreEditorOnCancel, (editorState.baseImage != nil || editorState.videoURL != nil) {
            shouldRestoreEditorOnCancel = false
            presentEditorPanel()
        }
    }

    private func tearDownRecordingUI() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingBorderPanel?.orderOut(nil)
        recordingHUDPanel?.orderOut(nil)
        sharedState.isRecordingActive = false
        sharedState.isRecordingArmed = false
        sharedState.recordingElapsed = 0
        pendingRecordingSpec = nil
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
        editorState.videoURL = nil
        editorState.videoDuration = 0
        editorState.videoDimensions = .zero
        editorState.isVideoPlaybackActive = false
        editorState.cancelTextDraft()

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

        copyCurrentAssetToPasteboard()
        let savedURL = autoSaveScreenshot(image: image)
        editorState.savedFileURL = savedURL
        showToast(savedURL != nil ? "Copied to clipboard • Saved to Pictures/Screenshots" : "Copied to clipboard")
        presentEditorPanel()
    }

    private func deliverRecordedVideo(url: URL) async {
        editorState.baseImage = nil
        editorState.displayImage = nil
        editorState.imagePixelSize = .zero
        editorState.history.resetAll()
        editorState.inProgressAnnotation = nil
        editorState.cropSelectionRect = nil
        editorState.cropDragStart = nil
        editorState.cancelTextDraft()
        editorState.recognizedLines = []
        editorState.showOCRDrawer = false
        editorState.ocrStatusMessage = nil

        let asset = AVURLAsset(url: url)
        let durationSeconds = (try? await asset.load(.duration).seconds) ?? 0
        let naturalSize: CGSize
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            let transformed = size.applying(transform)
            naturalSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
        } else {
            naturalSize = .zero
        }

        editorState.videoURL = url
        editorState.videoDuration = durationSeconds.isFinite ? max(0, durationSeconds) : 0
        editorState.videoDimensions = naturalSize
        editorState.savedFileURL = url
        editorState.isVideoPlaybackActive = true

        copyCurrentAssetToPasteboard()
        showToast("Video saved to Movies/Screen Recordings • Copied file")
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
                    guard let self else { return }
                    self.editorState.commitTextDraft()
                    self.copyCurrentAssetToPasteboard()
                    self.showToast(self.editorState.isVideoPreview ? "Copied video file" : "Copied to clipboard")
                },
                onSaveAs: { [weak self] in
                    guard let self else { return }
                    self.editorState.commitTextDraft()
                    self.saveAsWithDialog()
                },
                onOpenFolder: { [weak self] in self?.revealOutputFolder() },
                onApplyCrop: { [weak self] rectInPoints, canvasPointSize in
                    self?.editorState.commitTextDraft()
                    self?.applyCrop(rectInPoints: rectInPoints, canvasPointSize: canvasPointSize)
                },
                onCommitTextAnnotation: { [weak self] in
                    self?.copyCurrentAssetToPasteboard()
                },
                onRunOCR: { [weak self] in
                    self?.editorState.commitTextDraft()
                    self?.runTextRecognition()
                },
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

        if editorState.isVideoPreview {
            editorState.isVideoPlaybackActive = true
        }
        editorPanel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installEditorShortcutMonitor()
    }

    private func closeEditor() {
        editorState.cancelTextDraft()
        editorState.isVideoPlaybackActive = false
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
        copyCurrentAssetToPasteboard()
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

    private func copyCurrentAssetToPasteboard() {
        if let videoURL = editorState.videoURL {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([videoURL as NSURL])
            return
        }
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
        if let sourceVideoURL = editorState.videoURL {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.mpeg4Movie]
            panel.canCreateDirectories = true
            panel.directoryURL = sourceVideoURL.deletingLastPathComponent()
            panel.nameFieldStringValue = sourceVideoURL.lastPathComponent

            if let editorPanel {
                panel.beginSheetModal(for: editorPanel) { [weak self] response in
                    guard response == .OK, let destURL = panel.url else { return }
                    Task { @MainActor [weak self] in
                        do {
                            let fm = FileManager.default
                            if destURL != sourceVideoURL {
                                if fm.fileExists(atPath: destURL.path) {
                                    try fm.removeItem(at: destURL)
                                }
                                try fm.copyItem(at: sourceVideoURL, to: destURL)
                            }
                            self?.editorState.savedFileURL = destURL
                            self?.showToast("Saved \(destURL.lastPathComponent)")
                        } catch {
                            self?.showToast("Save failed: \(error.localizedDescription)")
                        }
                    }
                }
            }
            return
        }

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

    private func revealOutputFolder() {
        let dir: URL
        if let saved = editorState.savedFileURL {
            dir = saved.deletingLastPathComponent()
        } else if editorState.isVideoPreview || sharedState.outputKind == .video {
            dir = SnippingGeometry.defaultRecordingsDirectory(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        } else {
            dir = SnippingGeometry.defaultScreenshotsDirectory(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        }
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
            let isTypingText = self.editorState.isEditingText || (panel.firstResponder is NSTextView)
            if isTypingText {
                if event.keyCode == 53 {
                    self.editorState.cancelTextDraft()
                    return nil
                }
                if flags == .command {
                    switch event.keyCode {
                    case 1: // Cmd+S
                        self.editorState.commitTextDraft()
                        self.saveAsWithDialog()
                        return nil
                    case 45: // Cmd+N
                        self.editorState.commitTextDraft()
                        self.beginCapture()
                        return nil
                    default:
                        break
                    }
                }
                return event
            }

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
                    self.copyCurrentAssetToPasteboard()
                    self.showToast(self.editorState.isVideoPreview ? "Copied video file" : "Copied to clipboard")
                    return nil
                case 1: // S
                    self.saveAsWithDialog()
                    return nil
                case 6: // Z
                    if !self.editorState.isVideoPreview, self.editorState.history.undo() { return nil }
                case 45: // N
                    self.beginCapture()
                    return nil
                default:
                    break
                }
            } else if flags == [.command, .shift], event.keyCode == 6 {
                if !self.editorState.isVideoPreview, self.editorState.history.redo() { return nil }
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
    @MainActor
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

    @MainActor
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

        case .text(let origin, let text, let fontSize):
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
            ]
            (text as NSString).draw(at: origin, withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
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

// MARK: - Recording Overlay Border & HUD Pill

private struct SnipRecordingRegionBorderView: View {
    let state: SnippingToolState

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(
                state.isRecordingActive ? Color.red.opacity(0.92) : Color.cyan.opacity(0.92),
                style: StrokeStyle(lineWidth: 2.5, dash: state.isRecordingActive ? [] : [8, 5])
            )
            .padding(1)
    }
}

private struct SnipRecordingHUDView: View {
    let state: SnippingToolState
    let onStart: () -> Void
    let onStop: () -> Void
    let onToggleAudio: () -> Void
    let onToggleMic: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            SnipWindowDragHandle(onDoubleClick: {})
                .frame(width: 14, height: 30)
                .overlay(
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                        .allowsHitTesting(false)
                )

            if state.isRecordingActive {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 9, height: 9)
                    Text(SnippingGeometry.formatRecordingDuration(state.recordingElapsed))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))

                Button(action: onStop) {
                    HStack(spacing: 5) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10.5))
                        Text("Stop")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(red: 0.85, green: 0.20, blue: 0.18)))
                }
                .buttonStyle(.plain)
            } else {
                Button(action: onStart) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 8, height: 8)
                        Text("Start")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(red: 0.85, green: 0.20, blue: 0.18)))
                }
                .buttonStyle(.plain)
            }

            Button(action: onToggleAudio) {
                Image(systemName: state.captureSystemAudio ? "speaker.wave.2.fill" : "speaker.slash")
                    .font(.system(size: 12))
                    .foregroundStyle(state.captureSystemAudio ? .cyan : .white.opacity(0.5))
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(state.captureSystemAudio ? 0.14 : 0.06)))
            }
            .buttonStyle(.plain)
            .disabled(state.isRecordingActive)
            .help(state.captureSystemAudio ? "System audio enabled" : "System audio muted")

            Button(action: onToggleMic) {
                Image(systemName: state.captureMicrophone ? "mic.fill" : "mic.slash")
                    .font(.system(size: 12))
                    .foregroundStyle(state.captureMicrophone ? .cyan : .white.opacity(0.5))
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(state.captureMicrophone ? 0.14 : 0.06)))
            }
            .buttonStyle(.plain)
            .disabled(state.isRecordingActive)
            .help(state.captureMicrophone ? "Microphone enabled" : "Microphone muted")

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help(state.isRecordingActive ? "Discard recording" : "Cancel (Esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: 344, height: 48)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(red: 0.12, green: 0.12, blue: 0.14).opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.55), radius: 14, x: 0, y: 6)
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
    let onSelectOutputKind: (SnipOutputKind) -> Void
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

                let borderColor: Color = sharedState.outputKind == .video ? .red.opacity(0.90) : .cyan.opacity(0.75)

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
                        with: .color(borderColor),
                        lineWidth: 1.25
                    )
                } else if sharedState.outputKind == .photo && sharedState.mode == .freeform && screenState.freeformPoints.count >= 2 {
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
                outputKind: sharedState.outputKind,
                mode: sharedState.mode,
                delay: sharedState.delay,
                onSelectOutputKind: onSelectOutputKind,
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
    let outputKind: SnipOutputKind
    let mode: SnipCaptureMode
    let delay: SnipDelayOption
    let onSelectOutputKind: (SnipOutputKind) -> Void
    let onSelectMode: (SnipCaptureMode) -> Void
    let onCycleDelay: () -> Void
    let onFullscreenNow: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            // Photo vs Video capture mode toggle (Windows 11 24H2 Snipping Tool style)
            ForEach(SnipOutputKind.allCases, id: \.self) { kind in
                Button {
                    onSelectOutputKind(kind)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: kind.systemSymbolName)
                            .font(.system(size: 12, weight: .semibold))
                        Text(kind.displayTitle)
                            .font(.system(size: 11.5, weight: outputKind == kind ? .semibold : .regular))
                    }
                    .foregroundStyle(outputKind == kind ? .white : .white.opacity(0.75))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(outputKind == kind
                                ? (kind == .video ? Color(red: 0.85, green: 0.20, blue: 0.18) : Color.accentColor.opacity(0.85))
                                : Color.white.opacity(0.06))
                    )
                }
                .buttonStyle(.plain)
            }

            Divider()
                .frame(height: 18)
                .padding(.horizontal, 4)

            ForEach(SnipCaptureMode.supportedModes(for: outputKind), id: \.self) { m in
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
    let onCommitTextAnnotation: () -> Void
    let onRunOCR: () -> Void
    let onCopyOCRText: () -> Void
    let onMinimize: () -> Void
    let onZoomToggle: () -> Void
    let onClose: () -> Void

    @State private var lastCanvasPointSize: CGSize = .zero

    private let textSizePresets: [(label: String, size: CGFloat)] = [
        ("S", 16),
        ("M", 24),
        ("L", 36),
        ("XL", 48)
    ]

    var body: some View {
        VStack(spacing: 0) {
            titlebar
            toolbar
            Divider().overlay(Color.white.opacity(0.08))

            ZStack(alignment: .top) {
                Color(red: 0.085, green: 0.088, blue: 0.10)

                if let videoURL = editorState.videoURL, editorState.isVideoPlaybackActive {
                    SnipVideoPlayerView(url: videoURL)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.5), radius: 14, x: 0, y: 6)
                        .padding(16)
                } else if let displayImage = editorState.displayImage {
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
                        .onChange(of: canvasSize) { _, newSize in
                            lastCanvasPointSize = newSize
                            if newSize.width > 0 {
                                editorState.activeTextDraftCanvasScale = editorState.imagePixelSize.width / newSize.width
                            }
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: sharedState.outputKind == .video ? "video" : "scissors")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("Press Win+Shift+S or click + New to capture a snip or screen recording")
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

            if !editorState.isVideoPreview && editorState.cropSelectionRect != nil && editorState.activeTool == .crop {
                cropActionBar
            }

            if !editorState.isVideoPreview && editorState.showOCRDrawer {
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
                Image(systemName: editorState.isVideoPreview ? "video.fill" : "scissors")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(editorState.isVideoPreview ? .red : .cyan)
                Text("Snipping Tool")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.9))
                if editorState.isVideoPreview {
                    let dimText = editorState.videoDimensions.width > 0
                        ? "\(Int(editorState.videoDimensions.width)) × \(Int(editorState.videoDimensions.height)) • "
                        : ""
                    Text("\(dimText)\(SnippingGeometry.formatRecordingDuration(editorState.videoDuration))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.55))
                } else if editorState.imagePixelSize.width > 0 {
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
                    Image(systemName: sharedState.outputKind == .video ? "record.circle" : "plus")
                        .font(.system(size: 11.5, weight: .bold))
                    Text("New")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(sharedState.outputKind == .video ? Color(red: 0.85, green: 0.20, blue: 0.18) : Color.accentColor)
                )
            }
            .buttonStyle(.plain)
            .help("New Capture (Cmd+N / Win+Shift+S)")

            HStack(spacing: 2) {
                ForEach(SnipOutputKind.allCases, id: \.self) { kind in
                    Button {
                        sharedState.outputKind = kind
                        if kind == .video && sharedState.mode == .freeform {
                            sharedState.mode = .rectangle
                        }
                    } label: {
                        Image(systemName: kind.systemSymbolName)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(sharedState.outputKind == kind ? .white : .white.opacity(0.65))
                            .frame(width: 26, height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(sharedState.outputKind == kind
                                        ? (kind == .video ? Color(red: 0.85, green: 0.20, blue: 0.18) : Color.white.opacity(0.18))
                                        : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(kind == .photo ? "Photo Snip Mode" : "Screen Video Recording Mode")
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))

            Menu {
                ForEach(SnipCaptureMode.supportedModes(for: sharedState.outputKind), id: \.self) { m in
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

            if editorState.isVideoPreview {
                HStack(spacing: 6) {
                    Text("MP4 Video")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.88))
                    if let name = editorState.savedFileURL?.lastPathComponent {
                        Text(name)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))

                Spacer()
            } else {
                ForEach(SnipToolKind.allCases, id: \.self) { tool in
                    Button {
                        if editorState.commitTextDraft() {
                            onCommitTextAnnotation()
                        }
                        editorState.activeTool = tool
                        if tool != .crop {
                            editorState.cropSelectionRect = nil
                            editorState.cropDragStart = nil
                        }
                    } label: {
                        Image(systemName: tool.systemSymbolName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(editorState.activeTool == tool ? .cyan : .white.opacity(0.82))
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(editorState.activeTool == tool ? Color.white.opacity(0.16) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(tool.displayTitle)
                }

                // Color swatches for Pen/Arrow/Rect/Text or Highlighter
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

                // Text size picker when Text tool is active
                if editorState.activeTool == .text {
                    HStack(spacing: 3) {
                        ForEach(textSizePresets, id: \.size) { preset in
                            let selected = abs(editorState.textFontSize - preset.size) < 0.5
                            Button {
                                editorState.textFontSize = preset.size
                            } label: {
                                Text(preset.label)
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(selected ? .cyan : .white.opacity(0.75))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 4)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .fill(selected ? Color.white.opacity(0.16) : Color.white.opacity(0.06))
                                    )
                            }
                            .buttonStyle(.plain)
                            .help("Text size \(Int(preset.size))pt")
                        }
                    }
                }

                Divider().frame(height: 20).padding(.horizontal, 2)

                Button {
                    editorState.cancelTextDraft()
                    _ = editorState.history.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 12.5))
                        .foregroundStyle(editorState.history.canUndo ? .white : .white.opacity(0.32))
                        .frame(width: 26, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(!editorState.history.canUndo)
                .help("Undo (Cmd+Z)")

                Button {
                    editorState.cancelTextDraft()
                    _ = editorState.history.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 12.5))
                        .foregroundStyle(editorState.history.canRedo ? .white : .white.opacity(0.32))
                        .frame(width: 26, height: 28)
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
            }

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
            .disabled(editorState.baseImage == nil && editorState.videoURL == nil)
            .help("Copy (Cmd+C)")

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
            .disabled(editorState.baseImage == nil && editorState.videoURL == nil)
            .help("Save As (Cmd+S)")

            Button(action: onOpenFolder) {
                Image(systemName: "folder")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.86))
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help(editorState.isVideoPreview ? "Open ~/Movies/Screen Recordings" : "Open ~/Pictures/Screenshots")
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

        return ZStack(alignment: .topLeading) {
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

            if let originPx = editorState.activeTextDraftOriginPx {
                let rawX = originPx.x * toViewX
                let rawY = originPx.y * toViewY
                let maxBoxW = max(160, min(320, canvasSize.width - 12))
                let clampedX = max(4, min(canvasSize.width - maxBoxW, rawX))
                let clampedY = max(4, min(max(4, canvasSize.height - 44), rawY))

                HStack(spacing: 6) {
                    SnipInlineTextField(
                        text: $editorState.activeTextDraft,
                        fontSize: editorState.textFontSize,
                        color: editorState.selectedPenColor,
                        onCommit: {
                            if editorState.commitTextDraft() {
                                onCommitTextAnnotation()
                            }
                        },
                        onCancel: {
                            editorState.cancelTextDraft()
                        }
                    )
                    .frame(minWidth: 120, maxWidth: maxBoxW - 62, minHeight: max(28, editorState.textFontSize * 1.45))

                    Button {
                        if editorState.commitTextDraft() {
                            onCommitTextAnnotation()
                        }
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.accentColor))
                    }
                    .buttonStyle(.plain)
                    .help("Commit text (Enter)")

                    Button {
                        editorState.cancelTextDraft()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.white.opacity(0.18)))
                    }
                    .buttonStyle(.plain)
                    .help("Cancel text (Esc)")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(red: 0.08, green: 0.09, blue: 0.11).opacity(0.84))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Color.cyan.opacity(0.85), lineWidth: 1.25)
                        )
                )
                .offset(x: clampedX, y: clampedY)
            }
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
        case .text:
            break
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
        if editorState.activeTool == .text {
            let clampedX = max(4, min(max(4, canvasSize.width - 24), value.location.x))
            let clampedY = max(4, min(max(4, canvasSize.height - 24), value.location.y))
            let scaleX = editorState.imagePixelSize.width / max(1, canvasSize.width)
            let scaleY = editorState.imagePixelSize.height / max(1, canvasSize.height)
            let ptPx = CGPoint(x: clampedX * scaleX, y: clampedY * scaleY)

            if editorState.commitTextDraft() {
                onCommitTextAnnotation()
            }
            editorState.activeTextDraftCanvasScale = scaleX
            editorState.activeTextDraftOriginPx = ptPx
            editorState.activeTextDraft = ""
            return
        }
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

        case .text(let origin, let text, let fontSize):
            let displaySize = max(8, fontSize * scaleFromPixels)
            let resolved = ctx.resolve(
                Text(text)
                    .font(.system(size: displaySize, weight: .semibold))
                    .foregroundStyle(color)
            )
            ctx.draw(resolved, at: CGPoint(x: origin.x * toViewX, y: origin.y * toViewY), anchor: .topLeading)
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

private struct SnipInlineTextField: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let color: SnipColorRGB
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField()
        tf.delegate = context.coordinator
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.placeholderString = "Type text..."
        tf.font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        tf.textColor = NSColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: color.a)
        tf.stringValue = text
        tf.lineBreakMode = .byWordWrapping
        tf.cell?.wraps = true
        tf.cell?.isScrollable = false
        DispatchQueue.main.async { [weak tf] in
            guard let tf, let win = tf.window else { return }
            win.makeFirstResponder(tf)
        }
        return tf
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        nsView.textColor = NSColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: color.a)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SnipInlineTextField

        init(_ parent: SnipInlineTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            parent.text = tf.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                if flags.contains(.shift) || flags.contains(.option) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                parent.onCommit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            return false
        }
    }
}

private struct SnipVideoPlayerView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        let player = AVPlayer(url: url)
        context.coordinator.player = player
        context.coordinator.loadedURL = url
        view.player = player
        player.play()
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if context.coordinator.loadedURL != url {
            context.coordinator.player?.pause()
            let player = AVPlayer(url: url)
            context.coordinator.player = player
            context.coordinator.loadedURL = url
            nsView.player = player
            player.play()
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        coordinator.player?.pause()
        nsView.player = nil
        coordinator.player = nil
        coordinator.loadedURL = nil
    }

    @MainActor
    final class Coordinator {
        var player: AVPlayer?
        var loadedURL: URL?
    }
}
