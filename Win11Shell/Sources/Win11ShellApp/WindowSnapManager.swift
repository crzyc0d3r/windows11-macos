import AppKit
import ApplicationServices
import SwiftUI
import Win11ShellCore

@MainActor
public final class WindowSnapManager {
    private let model: RunningAppsModel
    private var savedRestoreFrames: [String: CGRect] = [:]
    private var previewPanel: NonActivatingFloatingPanel?
    private var activePreviewZone: WindowSnapZone?
    private var activePreviewScreen: NSScreen?

    private var dragMonitors: [Any] = []
    private var dragCandidateWindow: AXWindowInfo?
    private var dragCandidateBundleID: String = ""
    private var dragStartFrame: CGRect = .zero
    private var dragSawWindowMove = false

    public var onWindowFrameChanged: (() -> Void)?

    public init(model: RunningAppsModel) {
        self.model = model
        startDragSnapMonitoring()
    }

    isolated deinit {
        for monitor in dragMonitors {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Public Snap Actions

    public func snapLeft() {
        applySnapZone(.leftHalf)
    }

    public func snapRight() {
        applySnapZone(.rightHalf)
    }

    public func toggleMaximize(window: AXWindowInfo? = nil, bundleID: String? = nil) {
        guard let target = resolveTarget(window: window, bundleID: bundleID) else { return }
        let (win, bid, screen) = target
        let key = windowKey(win, bundleID: bid)

        if isWindowMaximized(win, on: screen) {
            if let restore = savedRestoreFrames.removeValue(forKey: key) {
                AccessibilityBridge.setFrame(win.element, axFrame: restore)
            } else {
                let fallback = centeredRestoreAXFrame(on: screen)
                AccessibilityBridge.setFrame(win.element, axFrame: fallback)
            }
            onWindowFrameChanged?()
        } else {
            if savedRestoreFrames[key] == nil {
                savedRestoreFrames[key] = win.axFrame
            }
            applySnapZone(.maximized, to: win, bundleID: bid)
        }
    }

    public func smartDownOrMinimize() {
        guard let (win, bid, screen) = resolveTarget(window: nil, bundleID: nil) else { return }
        let key = windowKey(win, bundleID: bid)

        if isWindowMaximized(win, on: screen) || (savedRestoreFrames[key] != nil && isNearAnySnapZone(win, on: screen)) {
            if let restore = savedRestoreFrames.removeValue(forKey: key) {
                AccessibilityBridge.setFrame(win.element, axFrame: restore)
            } else {
                AccessibilityBridge.setFrame(win.element, axFrame: centeredRestoreAXFrame(on: screen))
            }
            onWindowFrameChanged?()
        } else {
            savedRestoreFrames.removeValue(forKey: key)
            AccessibilityBridge.setMinimized(win.element, minimized: true)
            onWindowFrameChanged?()
        }
    }

    public func minimizeFrontWindow() {
        guard let (win, bid, _) = resolveTarget(window: nil, bundleID: nil) else { return }
        savedRestoreFrames.removeValue(forKey: windowKey(win, bundleID: bid))
        AccessibilityBridge.setMinimized(win.element, minimized: true)
        onWindowFrameChanged?()
    }

    public func applySnapZone(
        _ zone: WindowSnapZone,
        to window: AXWindowInfo? = nil,
        bundleID: String? = nil,
        screen overrideScreen: NSScreen? = nil
    ) {
        guard let target = resolveTarget(window: window, bundleID: bundleID, overrideScreen: overrideScreen) else {
            return
        }
        let (win, bid, screen) = target
        let key = windowKey(win, bundleID: bid)
        if savedRestoreFrames[key] == nil {
            savedRestoreFrames[key] = win.axFrame
        }

        let targetAX = WindowChromeGeometry.snapAXFrame(
            for: zone,
            screenFrameCocoa: screen.frame,
            visibleFrameCocoa: screen.visibleFrame,
            primaryScreenHeight: AccessibilityBridge.primaryScreenHeight(),
            barHeight: CGFloat(model.config.windowBarHeight),
            taskbarHeight: CGFloat(model.config.taskbarHeight)
        )
        AccessibilityBridge.setFrame(win.element, axFrame: targetAX)
        cancelDragPreview()
        onWindowFrameChanged?()
    }

    public func isWindowMaximized(_ win: AXWindowInfo, on screen: NSScreen) -> Bool {
        let maxAX = WindowChromeGeometry.maximizedAXFrame(
            forScreenFrameCocoa: screen.frame,
            visibleFrameCocoa: screen.visibleFrame,
            primaryScreenHeight: AccessibilityBridge.primaryScreenHeight(),
            barHeight: CGFloat(model.config.windowBarHeight),
            taskbarHeight: CGFloat(model.config.taskbarHeight)
        )
        return abs(win.axFrame.width - maxAX.width) < 12 && abs(win.axFrame.height - maxAX.height) < 12
    }

    // MARK: - Launch Normalization

    @discardableResult
    public func normalizeVisibleWindows() -> Int {
        guard AccessibilityBridge.hasAccessibilityPermission(prompt: false) else {
            ShellLogger.log("Window normalization skipped: Accessibility permission missing")
            return 0
        }

        let primaryH = AccessibilityBridge.primaryScreenHeight()
        let barH = CGFloat(model.config.windowBarHeight)
        let tbH = CGFloat(model.config.taskbarHeight)
        var adjusted = 0

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  !app.isHidden,
                  let bundleID = app.bundleIdentifier,
                  bundleID != "com.hackedple.win11shell",
                  bundleID != "com.apple.finder"
            else {
                continue
            }

            let windows = AccessibilityBridge.standardWindows(for: app.processIdentifier)
            for win in windows where !win.isMinimized && !win.isFullScreen {
                guard let screen = AccessibilityBridge.screenContaining(axFrame: win.axFrame) else {
                    continue
                }
                if let normalized = WindowChromeGeometry.normalizedAXFrame(
                    forAXWindowFrame: win.axFrame,
                    screenFrameCocoa: screen.frame,
                    visibleFrameCocoa: screen.visibleFrame,
                    primaryScreenHeight: primaryH,
                    barHeight: barH,
                    taskbarHeight: tbH
                ) {
                    AccessibilityBridge.setFrame(win.element, axFrame: normalized)
                    adjusted += 1
                }
            }
        }

        ShellLogger.log("Normalized \(adjusted) visible window(s) into Win11 work area (top=\(Int(barH))pt, bottom=\(Int(tbH))pt)")
        return adjusted
    }

    // MARK: - Drag-to-Edge/Corner Snap & Preview Overlay

    public func updateDragPreview(mouseLocationCocoa: NSPoint) {
        guard let screen = screenForMouse(mouseLocationCocoa),
              let zone = WindowChromeGeometry.dragSnapZone(
                forMouseCocoa: mouseLocationCocoa,
                screenFrameCocoa: screen.frame,
                visibleFrameCocoa: screen.visibleFrame
              )
        else {
            cancelDragPreview()
            return
        }

        if activePreviewZone == zone && activePreviewScreen == screen {
            return
        }
        activePreviewZone = zone
        activePreviewScreen = screen
        showPreviewOverlay(for: zone, on: screen)
    }

    @discardableResult
    public func commitDragSnapIfActive(window: AXWindowInfo? = nil, bundleID: String? = nil) -> Bool {
        guard let zone = activePreviewZone else {
            cancelDragPreview()
            return false
        }
        let targetScreen = activePreviewScreen
        cancelDragPreview()
        applySnapZone(zone, to: window, bundleID: bundleID, screen: targetScreen)
        return true
    }

    public func cancelDragPreview() {
        activePreviewZone = nil
        activePreviewScreen = nil
        previewPanel?.orderOut(nil)
    }

    private func showPreviewOverlay(for zone: WindowSnapZone, on screen: NSScreen) {
        let primaryH = AccessibilityBridge.primaryScreenHeight()
        let axRect = WindowChromeGeometry.snapAXFrame(
            for: zone,
            screenFrameCocoa: screen.frame,
            visibleFrameCocoa: screen.visibleFrame,
            primaryScreenHeight: primaryH,
            barHeight: CGFloat(model.config.windowBarHeight),
            taskbarHeight: CGFloat(model.config.taskbarHeight)
        )
        let cocoaRect = WindowChromeGeometry.axRectToCocoa(axRect, primaryScreenHeight: primaryH)
        let insetRect = cocoaRect.insetBy(dx: 6, dy: 6)

        if previewPanel == nil {
            let p = NonActivatingFloatingPanel(
                contentRect: insetRect,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.contentView = NSHostingView(rootView: SnapPreviewOverlayView())
            previewPanel = p
        }

        guard let previewPanel else { return }
        previewPanel.setFrame(insetRect, display: true)
        previewPanel.orderFrontRegardless()
    }

    private func startDragSnapMonitoring() {
        let downMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleGlobalMouseDown()
            }
        }
        let dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleGlobalMouseDragged()
            }
        }
        let upMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleGlobalMouseUp()
            }
        }

        dragMonitors = [downMonitor, dragMonitor, upMonitor].compactMap { $0 }
    }

    private func handleGlobalMouseDown() {
        dragCandidateWindow = nil
        dragCandidateBundleID = ""
        dragStartFrame = .zero
        dragSawWindowMove = false
        cancelDragPreview()

        guard AccessibilityBridge.hasAccessibilityPermission(prompt: false),
              let front = NSWorkspace.shared.frontmostApplication,
              let bundleID = front.bundleIdentifier,
              bundleID != "com.hackedple.win11shell",
              bundleID != "com.apple.finder",
              let win = AccessibilityBridge.focusedWindow(for: front.processIdentifier),
              !win.isMinimized,
              !win.isFullScreen
        else {
            return
        }

        dragCandidateWindow = win
        dragCandidateBundleID = bundleID
        dragStartFrame = win.axFrame
    }

    private func handleGlobalMouseDragged() {
        guard let candidate = dragCandidateWindow else { return }

        if !dragSawWindowMove {
            guard let live = AccessibilityBridge.windowInfo(for: candidate.element, pid: candidate.pid) else {
                dragCandidateWindow = nil
                return
            }
            let sameSize = abs(live.axFrame.width - dragStartFrame.width) < 2
                && abs(live.axFrame.height - dragStartFrame.height) < 2
            let movedOrigin = abs(live.axFrame.origin.x - dragStartFrame.origin.x) > 3
                || abs(live.axFrame.origin.y - dragStartFrame.origin.y) > 3
            if sameSize && movedOrigin {
                dragSawWindowMove = true
                dragCandidateWindow = live
            } else {
                return
            }
        }

        updateDragPreview(mouseLocationCocoa: NSEvent.mouseLocation)
    }

    private func handleGlobalMouseUp() {
        defer {
            dragCandidateWindow = nil
            dragCandidateBundleID = ""
            dragStartFrame = .zero
            dragSawWindowMove = false
        }

        if dragSawWindowMove, let win = dragCandidateWindow {
            _ = commitDragSnapIfActive(window: win, bundleID: dragCandidateBundleID)
        } else {
            cancelDragPreview()
        }
    }

    // MARK: - Helpers

    private func resolveTarget(
        window: AXWindowInfo?,
        bundleID: String?,
        overrideScreen: NSScreen? = nil
    ) -> (AXWindowInfo, String, NSScreen)? {
        if let window {
            let bid = bundleID
                ?? NSRunningApplication(processIdentifier: window.pid)?.bundleIdentifier
                ?? ""
            guard !window.isMinimized, !window.isFullScreen,
                  let screen = overrideScreen ?? AccessibilityBridge.screenContaining(axFrame: window.axFrame)
            else {
                return nil
            }
            return (window, bid, screen)
        }

        guard let front = NSWorkspace.shared.frontmostApplication,
              let bid = front.bundleIdentifier,
              bid != "com.hackedple.win11shell",
              bid != "com.apple.finder",
              let win = AccessibilityBridge.focusedWindow(for: front.processIdentifier),
              !win.isMinimized,
              !win.isFullScreen,
              let screen = overrideScreen ?? AccessibilityBridge.screenContaining(axFrame: win.axFrame)
        else {
            return nil
        }
        return (win, bid, screen)
    }

    private func windowKey(_ win: AXWindowInfo, bundleID: String) -> String {
        "\(win.pid)-\(win.windowID)-\(bundleID)"
    }

    private func centeredRestoreAXFrame(on screen: NSScreen) -> CGRect {
        let primaryH = AccessibilityBridge.primaryScreenHeight()
        let maxAX = WindowChromeGeometry.maximizedAXFrame(
            forScreenFrameCocoa: screen.frame,
            visibleFrameCocoa: screen.visibleFrame,
            primaryScreenHeight: primaryH,
            barHeight: CGFloat(model.config.windowBarHeight),
            taskbarHeight: CGFloat(model.config.taskbarHeight)
        )
        let w = (maxAX.width * 0.75).rounded()
        let h = (maxAX.height * 0.75).rounded()
        return CGRect(
            x: (maxAX.minX + (maxAX.width - w) / 2).rounded(),
            y: (maxAX.minY + (maxAX.height - h) / 2).rounded(),
            width: w,
            height: h
        )
    }

    private func isNearAnySnapZone(_ win: AXWindowInfo, on screen: NSScreen) -> Bool {
        let primaryH = AccessibilityBridge.primaryScreenHeight()
        let barH = CGFloat(model.config.windowBarHeight)
        let tbH = CGFloat(model.config.taskbarHeight)
        return WindowSnapZone.allCases.contains { zone in
            let expected = WindowChromeGeometry.snapAXFrame(
                for: zone,
                screenFrameCocoa: screen.frame,
                visibleFrameCocoa: screen.visibleFrame,
                primaryScreenHeight: primaryH,
                barHeight: barH,
                taskbarHeight: tbH
            )
            return abs(win.axFrame.origin.x - expected.origin.x) < 12
                && abs(win.axFrame.origin.y - expected.origin.y) < 12
                && abs(win.axFrame.width - expected.width) < 12
                && abs(win.axFrame.height - expected.height) < 12
        }
    }

    private func screenForMouse(_ point: NSPoint) -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.insetBy(dx: -2, dy: -2).contains(point) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}

private struct SnapPreviewOverlayView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.20))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.75), lineWidth: 2)
            )
    }
}
