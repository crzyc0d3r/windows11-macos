import AppKit
import ApplicationServices
import Observation
import QuartzCore
import SwiftUI
import Win11ShellCore

@MainActor
@Observable
public final class WindowChromeBarState {
    public var appName: String = ""
    public var appIcon: NSImage?
    public var windowTitle: String = ""
    public var menuItems: [MirroredMenuItem] = []
    public var isMaximized: Bool = false
    public var isNotchDocked: Bool = false
    public var leftNotchWidth: CGFloat = 0
    public var notchWidth: CGFloat = 0
    public var rightNotchWidth: CGFloat = 0
    public var showSnapLayouts: Bool = false
    public var hoveredButton: String?
}

@MainActor
@Observable
private final class DragGhostState {
    var appIcon: NSImage?
    var title: String = ""
    var barHeight: CGFloat = 28
}

@MainActor
public final class WindowChromeBarController: NSObject {
    private let model: RunningAppsModel
    private let snapManager: WindowSnapManager
    private let state = WindowChromeBarState()
    private let dragGhostState = DragGhostState()
    private var panel: NonActivatingFloatingPanel?
    private var snapPanel: NonActivatingFloatingPanel?
    private var dragGhostPanel: NonActivatingFloatingPanel?
    private var trafficLightMaskPanel: NonActivatingFloatingPanel?
    private var trafficLightMaskView: TrafficLightMaskNSView?
    private var backgroundMasks: [CGWindowID: (panel: NonActivatingFloatingPanel, view: TrafficLightMaskNSView, pid: pid_t)] = [:]
    private var cachedMaskRelativeOffsets: [CGWindowID: CGRect] = [:]
    private weak var dragZoneNSView: NSView?
    private weak var leftNotchDragZoneNSView: NSView?
    private var sampledMaskColors: [String: NSColor] = [:]
    private var pendingMaskColorKeys: Set<String> = []
    private var syncTimer: Timer?
    private var fastDragSyncTimer: Timer?
    private var axObserver: AXObserver?
    private var observedPID: pid_t = 0
    private var lastMenuPID: pid_t = 0
    private var cachedMenusByPID: [pid_t: [MirroredMenuItem]] = [:]
    private var currentWindow: AXWindowInfo?
    private var currentBundleID: String = ""
    private var isDraggingTargetWindow = false
    private var isExternalMouseDragging = false
    private var isBlockingNativeTitlebarDrag = false
    private var dragTargetWindow: AXWindowInfo?
    private var dragStartMouseAX: CGPoint = .zero
    private var dragStartWindowFrameAX: CGRect = .zero
    private var dragWasMaximized = false
    private var dragDidStartVisualGhost = false
    private var dragGhostWindowSizeAX: CGSize = .zero
    private var dragGhostCurrentWindowOriginAX: CGPoint = .zero
    private var dragGhostGrabOffsetAX: CGPoint = .zero
    private var dragMinSafeAXTop: CGFloat = 28
    private var lastAutoNormalizedFrameByWindowID: [CGWindowID: CGRect] = [:]
    private var mouseDragTap: CFMachPort?
    private var mouseDragRunLoopSource: CFRunLoopSource?
    private var snapDismissWork: DispatchWorkItem?

    public init(model: RunningAppsModel, snapManager: WindowSnapManager) {
        self.model = model
        self.snapManager = snapManager
        super.init()
        setupPanel()
        observeWorkspace()
        syncActiveWindow()
        DispatchQueue.main.async { [weak self] in
            self?.attachAXObserverToFrontApp()
            self?.syncActiveWindow()
        }
        syncTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncActiveWindow()
            }
        }
    }

    private func setupPanel() {
        let bar = NonActivatingFloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: model.config.windowBarHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        bar.allowsNotchAreaPlacement = true
        bar.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        bar.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        bar.backgroundColor = .clear
        bar.isOpaque = false
        bar.hasShadow = false

        let hosting = NSHostingView(rootView: WindowChromeBarView(
            state: state,
            onMenuClick: { [weak self] item, sourceView in
                self?.openMirroredMenu(item: item, anchorView: sourceView)
            },
            onOverflowMenusClick: { [weak self] items, sourceView in
                self?.openOverflowMenus(items: items, anchorView: sourceView)
            },
            onDragZoneReady: { [weak self] view in
                self?.dragZoneNSView = view
            },
            onLeftDragZoneReady: { [weak self] view in
                self?.leftNotchDragZoneNSView = view
            },
            onDragDelta: { [weak self] dx, dy in
                self?.dragCurrentWindow(deltaX: dx, deltaY: dy)
            },
            onDragEnded: { [weak self] in
                self?.finishDraggingCurrentWindow()
            },
            onDoubleClickTitle: { [weak self] in
                self?.toggleMaximizeCurrentWindow()
            },
            onMinimize: { [weak self] in
                self?.minimizeCurrentWindow()
            },
            onMaximize: { [weak self] in
                self?.toggleMaximizeCurrentWindow()
            },
            onClose: { [weak self] in
                self?.closeOrQuitFrontWindow()
            },
            onHoverMaximize: { [weak self] hovering, anchorRect in
                self?.handleMaximizeHover(hovering: hovering, anchorRect: anchorRect)
            }
        ))
        bar.contentView = hosting
        panel = bar
    }

    private func observeWorkspace() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.attachAXObserverToFrontApp()
                self?.syncActiveWindow()
            }
        }
        nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier ?? 0
            Task { @MainActor [weak self] in
                guard let self, pid != 0 else { return }
                self.cachedMenusByPID.removeValue(forKey: pid)
                let pidPrefix = "\(pid)-"
                let expiredWIDs = self.sampledMaskColors.keys
                    .filter { $0.hasPrefix(pidPrefix) }
                    .compactMap { UInt32($0.dropFirst(pidPrefix.count)) }
                for wid in expiredWIDs {
                    self.cachedMaskRelativeOffsets.removeValue(forKey: wid)
                }
                self.sampledMaskColors = self.sampledMaskColors.filter { !$0.key.hasPrefix(pidPrefix) }
                if self.lastMenuPID == pid {
                    self.lastMenuPID = 0
                }
            }
        }
        attachAXObserverToFrontApp()
    }

    private func attachAXObserverToFrontApp() {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        let pid = front.processIdentifier
        if pid == observedPID { return }

        if let existing = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(existing), .commonModes)
            axObserver = nil
        }
        observedPID = pid

        var observer: AXObserver?
        let err = AXObserverCreate(pid, { _, _, _, refcon in
            guard let refcon else { return }
            let ctrl = Unmanaged<WindowChromeBarController>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor in
                ctrl.syncActiveWindow()
            }
        }, &observer)

        guard err == .success, let observer else { return }
        let appEl = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let notifications = [
            kAXFocusedWindowChangedNotification,
            kAXWindowMovedNotification,
            kAXWindowResizedNotification,
            kAXTitleChangedNotification,
            kAXWindowMiniaturizedNotification
        ]
        for n in notifications {
            AXObserverAddNotification(observer, appEl, n as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        axObserver = observer
    }

    public func syncActiveWindow() {
        if isDraggingTargetWindow {
            return
        }

        guard model.config.showWindowChromeBar,
              let front = NSWorkspace.shared.frontmostApplication,
              let bundleID = front.bundleIdentifier,
              bundleID != "com.apple.finder",
              !model.config.windowBarExcludedBundleIDs.contains(bundleID),
              let win = AccessibilityBridge.focusedWindow(for: front.processIdentifier),
              !win.isMinimized,
              !win.isFullScreen,
              let screen = AccessibilityBridge.screenContaining(axFrame: win.axFrame)
        else {
            hideBar()
            return
        }

        let primaryH = AccessibilityBridge.primaryScreenHeight()
        var effectiveWin = win
        var effectiveScreen = screen
        if !isDraggingTargetWindow && !isExternalMouseDragging && NSEvent.pressedMouseButtons == 0 {
            if WindowChromeGeometry.shouldAutoNormalizeFocusedWindow(
                axFrame: win.axFrame,
                screenFrameCocoa: screen.frame,
                visibleFrameCocoa: screen.visibleFrame,
                primaryScreenHeight: primaryH,
                barHeight: CGFloat(model.config.windowBarHeight),
                taskbarHeight: CGFloat(model.config.taskbarHeight),
                safeAreaTopInset: screen.safeAreaInsets.top
            ) {
                if lastAutoNormalizedFrameByWindowID[win.windowID] != win.axFrame,
                   let normalized = WindowChromeGeometry.normalizedAXFrame(
                    forAXWindowFrame: win.axFrame,
                    screenFrameCocoa: screen.frame,
                    visibleFrameCocoa: screen.visibleFrame,
                    primaryScreenHeight: primaryH,
                    barHeight: CGFloat(model.config.windowBarHeight),
                    taskbarHeight: CGFloat(model.config.taskbarHeight),
                    safeAreaTopInset: screen.safeAreaInsets.top
                   ) {
                    lastAutoNormalizedFrameByWindowID[win.windowID] = win.axFrame
                    AccessibilityBridge.setFrame(win.element, axFrame: normalized)
                    let liveAX = AccessibilityBridge.liveWindowBounds(windowID: win.windowID) ?? normalized
                    effectiveWin = AXWindowInfo(
                        pid: win.pid,
                        windowID: win.windowID,
                        title: win.title,
                        axFrame: liveAX,
                        isMinimized: win.isMinimized,
                        isFullScreen: win.isFullScreen,
                        element: win.element
                    )
                    effectiveScreen = AccessibilityBridge.screenContaining(axFrame: liveAX) ?? screen
                }
            } else {
                lastAutoNormalizedFrameByWindowID.removeValue(forKey: win.windowID)
            }
        }

        guard let layout = WindowChromeGeometry.dockedBarLayout(
            forAXWindowFrame: effectiveWin.axFrame,
            primaryScreenHeight: primaryH,
            screenFrameCocoa: effectiveScreen.frame,
            visibleFrameCocoa: effectiveScreen.visibleFrame,
            safeAreaTopInset: effectiveScreen.safeAreaInsets.top,
            auxiliaryTopLeftWidth: effectiveScreen.auxiliaryTopLeftArea?.width ?? 0,
            auxiliaryTopRightWidth: effectiveScreen.auxiliaryTopRightArea?.width ?? 0,
            barHeight: CGFloat(model.config.windowBarHeight),
            taskbarHeight: CGFloat(model.config.taskbarHeight)
        ) else {
            hideBar()
            return
        }
        let barRect = layout.frameCocoa

        let pid = front.processIdentifier
        currentWindow = effectiveWin
        currentBundleID = bundleID
        state.appName = front.localizedName ?? bundleID
        state.appIcon = AppIconCache.icon(forBundleID: bundleID, url: front.bundleURL, size: 16)
        state.windowTitle = effectiveWin.title.isEmpty ? state.appName : effectiveWin.title
        state.isMaximized = snapManager.isWindowMaximized(effectiveWin, on: effectiveScreen)
        state.isNotchDocked = layout.isNotchDocked
        state.leftNotchWidth = layout.leftNotchWidth
        state.notchWidth = layout.notchWidth
        state.rightNotchWidth = layout.rightNotchWidth

        // Cache menu bar items per PID — only query AXMenuBar when active PID changes
        if pid != lastMenuPID {
            lastMenuPID = pid
            if let cached = cachedMenusByPID[pid], !cached.isEmpty {
                state.menuItems = cached
            } else {
                let fresh = AccessibilityBridge.readAppMenuBar(pid: pid)
                if !fresh.isEmpty {
                    cachedMenusByPID[pid] = fresh
                }
                state.menuItems = fresh
            }
        }

        if let panel {
            setPanelFrameFast(panel, to: barRect)
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
        }

        let barAXRect = WindowChromeGeometry.cocoaRectToAX(barRect, primaryScreenHeight: primaryH)
        syncTrafficLightMask(
            for: effectiveWin,
            bundleID: bundleID,
            primaryScreenHeight: primaryH,
            barAXRect: barAXRect
        )
        syncBackgroundMasks(frontWindowID: effectiveWin.windowID, frontBarAXRect: barAXRect, primaryScreenHeight: primaryH)
    }

    private func hideBar() {
        currentWindow = nil
        panel?.orderOut(nil)
        snapPanel?.orderOut(nil)
        dragGhostPanel?.orderOut(nil)
        trafficLightMaskPanel?.orderOut(nil)
        if !model.config.showWindowChromeBar {
            hideAllBackgroundMasks()
        } else {
            syncBackgroundMasks(
                frontWindowID: nil,
                frontBarAXRect: nil,
                primaryScreenHeight: AccessibilityBridge.primaryScreenHeight()
            )
        }
    }

    private func hideAllBackgroundMasks() {
        for (_, entry) in backgroundMasks {
            entry.panel.orderOut(nil)
        }
        backgroundMasks.removeAll()
    }

    private func setPanelFrameFast(_ targetPanel: NSPanel, to rect: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let cur = targetPanel.frame
        if abs(cur.width - rect.width) < 0.5 && abs(cur.height - rect.height) < 0.5 {
            if abs(cur.origin.x - rect.origin.x) > 0.1 || abs(cur.origin.y - rect.origin.y) > 0.1 {
                targetPanel.setFrameOrigin(rect.origin)
            }
        } else {
            targetPanel.setFrame(rect, display: true)
        }
    }

    @discardableResult
    private func applyOverlayFramesFast(
        forLiveBounds liveBounds: CGRect,
        windowID: CGWindowID,
        primaryScreenHeight: CGFloat,
        includeBackgroundMasks: Bool
    ) -> CGRect? {
        guard let screen = AccessibilityBridge.screenContaining(axFrame: liveBounds)
            ?? NSScreen.main
            ?? NSScreen.screens.first,
            let layout = WindowChromeGeometry.dockedBarLayout(
                forAXWindowFrame: liveBounds,
                primaryScreenHeight: primaryScreenHeight,
                screenFrameCocoa: screen.frame,
                visibleFrameCocoa: screen.visibleFrame,
                safeAreaTopInset: screen.safeAreaInsets.top,
                auxiliaryTopLeftWidth: screen.auxiliaryTopLeftArea?.width ?? 0,
                auxiliaryTopRightWidth: screen.auxiliaryTopRightArea?.width ?? 0,
                barHeight: CGFloat(model.config.windowBarHeight),
                taskbarHeight: CGFloat(model.config.taskbarHeight)
            )
        else {
            return nil
        }

        state.isNotchDocked = layout.isNotchDocked
        state.leftNotchWidth = layout.leftNotchWidth
        state.notchWidth = layout.notchWidth
        state.rightNotchWidth = layout.rightNotchWidth
        let barRect = layout.frameCocoa

        if let panel {
            setPanelFrameFast(panel, to: barRect)
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
        }

        let barAXRect = WindowChromeGeometry.cocoaRectToAX(barRect, primaryScreenHeight: primaryScreenHeight)
        if let rel = cachedMaskRelativeOffsets[windowID],
           currentBundleID != model.config.fileExplorerBundleID,
           let maskPanel = trafficLightMaskPanel {
            let axMask = CGRect(
                x: liveBounds.minX + rel.minX,
                y: liveBounds.minY + rel.minY,
                width: rel.width,
                height: rel.height
            )
            let overlap = axMask.intersection(barAXRect)
            if !overlap.isEmpty && overlap.height > 2 {
                maskPanel.orderOut(nil)
            } else {
                let cocoaMask = WindowChromeGeometry.axRectToCocoa(axMask, primaryScreenHeight: primaryScreenHeight)
                setPanelFrameFast(maskPanel, to: cocoaMask)
                if !maskPanel.isVisible {
                    maskPanel.orderFrontRegardless()
                }
            }
        }

        if includeBackgroundMasks {
            syncBackgroundMasks(
                frontWindowID: windowID,
                frontBarAXRect: barAXRect,
                primaryScreenHeight: primaryScreenHeight
            )
        }
        return barAXRect
    }

    private func updateBackgroundMaskOcclusionInMemory(draggedWindowAXFrame: CGRect, draggedBarAXRect: CGRect) {
        let primaryH = AccessibilityBridge.primaryScreenHeight()
        for (_, entry) in backgroundMasks where entry.panel.isVisible {
            let maskAX = WindowChromeGeometry.cocoaRectToAX(entry.panel.frame, primaryScreenHeight: primaryH)
            if maskAX.intersects(draggedWindowAXFrame) || maskAX.intersects(draggedBarAXRect) {
                entry.panel.orderOut(nil)
            }
        }
    }

    private func syncOverlayPositionsFromWindowServer() {
        guard !isDraggingTargetWindow,
              let win = currentWindow,
              let liveBounds = AccessibilityBridge.liveWindowBounds(windowID: win.windowID)
        else {
            return
        }

        let primaryH = AccessibilityBridge.primaryScreenHeight()
        if let barAXRect = applyOverlayFramesFast(
            forLiveBounds: liveBounds,
            windowID: win.windowID,
            primaryScreenHeight: primaryH,
            includeBackgroundMasks: false
        ) {
            updateBackgroundMaskOcclusionInMemory(
                draggedWindowAXFrame: liveBounds,
                draggedBarAXRect: barAXRect
            )
        }
    }

    private func syncBackgroundMasks(
        frontWindowID: CGWindowID?,
        frontBarAXRect: CGRect?,
        primaryScreenHeight: CGFloat
    ) {
        guard model.config.showWindowChromeBar,
              AccessibilityBridge.hasAccessibilityPermission(prompt: false)
        else {
            hideAllBackgroundMasks()
            return
        }

        let selfPID = ProcessInfo.processInfo.processIdentifier
        let snapshots = AccessibilityBridge.onScreenNormalWindows()
        var activeIDs: Set<CGWindowID> = []
        var occludingRectsAX: [CGRect] = []
        if let frontBarAXRect {
            occludingRectsAX.append(frontBarAXRect)
        }

        for snap in snapshots {
            if snap.pid == selfPID {
                continue
            }
            if let frontWindowID, snap.windowID == frontWindowID {
                occludingRectsAX.append(snap.axBounds)
                continue
            }

            let app = NSRunningApplication(processIdentifier: snap.pid)
            let bundleID = app?.bundleIdentifier ?? ""
            if bundleID == model.config.fileExplorerBundleID
                || bundleID == "com.apple.finder"
                || model.config.windowBarExcludedBundleIDs.contains(bundleID) {
                occludingRectsAX.append(snap.axBounds)
                continue
            }

            activeIDs.insert(snap.windowID)
            let relOffset = resolveRelativeMaskOffset(for: snap)
            let bgMaskAX = CGRect(
                x: snap.axBounds.minX + relOffset.minX,
                y: snap.axBounds.minY + relOffset.minY,
                width: relOffset.width,
                height: relOffset.height
            )
            let isOccluded = occludingRectsAX.contains { $0.intersects(bgMaskAX) }

            if isOccluded {
                backgroundMasks[snap.windowID]?.panel.orderOut(nil)
            } else {
                let cocoaRect = WindowChromeGeometry.axRectToCocoa(bgMaskAX, primaryScreenHeight: primaryScreenHeight)
                let entry: (panel: NonActivatingFloatingPanel, view: TrafficLightMaskNSView, pid: pid_t)
                if let existing = backgroundMasks[snap.windowID] {
                    entry = existing
                } else {
                    let p = NonActivatingFloatingPanel(
                        contentRect: cocoaRect,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false
                    )
                    p.level = .floating
                    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
                    p.backgroundColor = .clear
                    p.isOpaque = false
                    p.hasShadow = false

                    let v = TrafficLightMaskNSView(frame: NSRect(origin: .zero, size: cocoaRect.size))
                    let targetPID = snap.pid
                    let targetWID = snap.windowID
                    v.onSimpleClick = {
                        if let targetApp = NSRunningApplication(processIdentifier: targetPID) {
                            targetApp.activate(options: [.activateAllWindows])
                        }
                        if let win = AccessibilityBridge.standardWindows(for: targetPID).first(where: { $0.windowID == targetWID }) {
                            AccessibilityBridge.focusWindow(win)
                        }
                    }
                    p.contentView = v
                    entry = (p, v, snap.pid)
                    backgroundMasks[snap.windowID] = entry
                }

                let colorKey = "\(snap.pid)-\(snap.windowID)"
                entry.view.fillColor = sampledMaskColors[colorKey] ?? defaultMaskFallbackColor()
                setPanelFrameFast(entry.panel, to: cocoaRect)
                if !entry.panel.isVisible {
                    entry.panel.orderFrontRegardless()
                }
            }

            occludingRectsAX.append(snap.axBounds)
        }

        let staleIDs = backgroundMasks.keys.filter { !activeIDs.contains($0) }
        for wid in staleIDs {
            backgroundMasks[wid]?.panel.orderOut(nil)
            backgroundMasks.removeValue(forKey: wid)
            cachedMaskRelativeOffsets.removeValue(forKey: wid)
        }
    }

    private func resolveRelativeMaskOffset(for snap: OnScreenWindowSnapshot) -> CGRect {
        if let cached = cachedMaskRelativeOffsets[snap.windowID] {
            return cached
        }
        if let axWin = AccessibilityBridge.standardWindows(for: snap.pid).first(where: { $0.windowID == snap.windowID }),
           let unionAX = AccessibilityBridge.trafficLightUnionAXRect(for: axWin.element) {
            let rel = CGRect(
                x: unionAX.minX - axWin.axFrame.minX,
                y: unionAX.minY - axWin.axFrame.minY,
                width: unionAX.width,
                height: unionAX.height
            )
            cachedMaskRelativeOffsets[snap.windowID] = rel
            return rel
        }
        let fallback = CGRect(x: 10, y: 8, width: 62, height: 22)
        cachedMaskRelativeOffsets[snap.windowID] = fallback
        return fallback
    }

    private func syncTrafficLightMask(
        for win: AXWindowInfo,
        bundleID: String,
        primaryScreenHeight: CGFloat,
        barAXRect: CGRect
    ) {
        guard bundleID != model.config.fileExplorerBundleID else {
            trafficLightMaskPanel?.orderOut(nil)
            return
        }

        let axMaskRect: CGRect
        if win.windowID != 0, let rel = cachedMaskRelativeOffsets[win.windowID] {
            axMaskRect = CGRect(
                x: win.axFrame.minX + rel.minX,
                y: win.axFrame.minY + rel.minY,
                width: rel.width,
                height: rel.height
            )
        } else if let resolved = AccessibilityBridge.trafficLightUnionAXRect(for: win.element) {
            if win.windowID != 0 {
                cachedMaskRelativeOffsets[win.windowID] = CGRect(
                    x: resolved.minX - win.axFrame.minX,
                    y: resolved.minY - win.axFrame.minY,
                    width: resolved.width,
                    height: resolved.height
                )
            }
            axMaskRect = resolved
        } else {
            trafficLightMaskPanel?.orderOut(nil)
            return
        }

        let barOverlap = axMaskRect.intersection(barAXRect)
        if !barOverlap.isEmpty && barOverlap.height > 2 {
            trafficLightMaskPanel?.orderOut(nil)
            return
        }

        let cocoaMaskRect = WindowChromeGeometry.axRectToCocoa(axMaskRect, primaryScreenHeight: primaryScreenHeight)
        if trafficLightMaskPanel == nil {
            let maskPanel = NonActivatingFloatingPanel(
                contentRect: cocoaMaskRect,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            maskPanel.level = .floating
            maskPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            maskPanel.backgroundColor = .clear
            maskPanel.isOpaque = false
            maskPanel.hasShadow = false

            let maskView = TrafficLightMaskNSView(frame: NSRect(origin: .zero, size: cocoaMaskRect.size))
            maskPanel.contentView = maskView
            trafficLightMaskPanel = maskPanel
            trafficLightMaskView = maskView
        }

        let colorKey = "\(win.pid)-\(win.windowID)"
        let fallbackColor = defaultMaskFallbackColor()
        trafficLightMaskView?.fillColor = sampledMaskColors[colorKey] ?? fallbackColor

        if !pendingMaskColorKeys.contains(colorKey) && sampledMaskColors[colorKey] == nil {
            pendingMaskColorKeys.insert(colorKey)
            let windowID = win.windowID
            let windowAXFrame = win.axFrame
            Task { @MainActor [weak self] in
                let sampled = await AccessibilityBridge.sampleTitlebarColor(
                    windowID: windowID,
                    windowAXFrame: windowAXFrame,
                    buttonUnionAXRect: axMaskRect
                )
                guard let self else { return }
                self.pendingMaskColorKeys.remove(colorKey)
                if let sampled {
                    self.sampledMaskColors[colorKey] = sampled
                    if let cur = self.currentWindow, "\(cur.pid)-\(cur.windowID)" == colorKey {
                        self.trafficLightMaskView?.fillColor = sampled
                    }
                }
            }
        }

        if let maskPanel = trafficLightMaskPanel {
            setPanelFrameFast(maskPanel, to: cocoaMaskRect)
            if !maskPanel.isVisible {
                maskPanel.orderFrontRegardless()
            }
        }
    }

    private func defaultMaskFallbackColor() -> NSColor {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.118, green: 0.118, blue: 0.122, alpha: 1.0)
            : NSColor(srgbRed: 0.925, green: 0.925, blue: 0.925, alpha: 1.0)
    }

    // MARK: - Window Actions (delegated to WindowSnapManager)

    public func minimizeCurrentWindow() {
        if let win = currentWindow {
            AccessibilityBridge.setMinimized(win.element, minimized: true)
            hideBar()
        } else {
            snapManager.minimizeFrontWindow()
        }
    }

    public func toggleMaximizeCurrentWindow() {
        snapManager.toggleMaximize(window: currentWindow, bundleID: currentBundleID.isEmpty ? nil : currentBundleID)
    }

    public func smartUnmaximizeOrMinimize() {
        snapManager.smartDownOrMinimize()
    }

    public func applySnapZone(_ zone: WindowSnapZone) {
        snapManager.applySnapZone(zone, to: currentWindow, bundleID: currentBundleID.isEmpty ? nil : currentBundleID)
        snapPanel?.orderOut(nil)
    }

    public func closeOrQuitFrontWindow() {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundleID = front.bundleIdentifier,
              bundleID != "com.hackedple.win11shell"
        else {
            return
        }

        let windows = AccessibilityBridge.standardWindows(for: front.processIdentifier)
        let action = WindowClosePolicy.decide(
            bundleID: bundleID,
            standardWindowCount: max(1, windows.count),
            keepAliveBundleIDs: Set(model.config.keepAliveBundleIDs)
        )

        if let focused = AccessibilityBridge.focusedWindow(for: front.processIdentifier) {
            if !AccessibilityBridge.pressCloseButton(focused.element) {
                // Fallback Cmd+W (tagged with Win11Shell synthetic marker 0x57313153)
                let src = CGEventSource(stateID: .hidSystemState)
                if let down = CGEvent(keyboardEventSource: src, virtualKey: 13, keyDown: true),
                   let up = CGEvent(keyboardEventSource: src, virtualKey: 13, keyDown: false) {
                    down.flags = .maskCommand
                    up.flags = .maskCommand
                    down.setIntegerValueField(.eventSourceUserData, value: 0x57313153)
                    up.setIntegerValueField(.eventSourceUserData, value: 0x57313153)
                    down.post(tap: .cghidEventTap)
                    up.post(tap: .cghidEventTap)
                }
            }
        }

        switch action {
        case .closeWindow:
            break
        case .hideApp:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                front.hide()
            }
        case .quitApp:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                front.terminate()
            }
        }
    }

    // MARK: - Hardware-Level CGEventTap Window Drag Engine

    @discardableResult
    public func startMouseDragTap() -> Bool {
        if mouseDragTap != nil {
            return true
        }
        let mask = CGEventMask(
            (1 << CGEventType.leftMouseDown.rawValue)
                | (1 << CGEventType.leftMouseDragged.rawValue)
                | (1 << CGEventType.leftMouseUp.rawValue)
        )
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo -> Unmanaged<CGEvent>? in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let ctrl = Unmanaged<WindowChromeBarController>.fromOpaque(userInfo).takeUnretainedValue()
                return ctrl.handleMouseTapCallback(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            return false
        }

        mouseDragTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        mouseDragRunLoopSource = source
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    public func stopMouseDragTap() {
        dragGhostPanel?.orderOut(nil)
        fastDragSyncTimer?.invalidate()
        fastDragSyncTimer = nil
        if let tap = mouseDragTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = mouseDragRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        mouseDragTap = nil
        mouseDragRunLoopSource = nil
        isDraggingTargetWindow = false
        isExternalMouseDragging = false
        isBlockingNativeTitlebarDrag = false
        dragDidStartVisualGhost = false
        snapManager.suppressGlobalDragMonitor = false
        hideAllBackgroundMasks()
    }

    nonisolated private func handleMouseTapCallback(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Task { @MainActor [weak self] in
                if let tap = self?.mouseDragTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard Thread.isMainThread else {
            return Unmanaged.passUnretained(event)
        }

        let locationAX = event.location
        let clickCount = event.getIntegerValueField(.mouseEventClickState)

        let swallow = MainActor.assumeIsolated { () -> Bool in
            switch type {
            case .leftMouseDown:
                return handleTapMouseDown(locationAX: locationAX, clickCount: clickCount)
            case .leftMouseDragged:
                return handleTapMouseDragged(locationAX: locationAX)
            case .leftMouseUp:
                return handleTapMouseUp()
            default:
                return false
            }
        }

        return swallow ? nil : Unmanaged.passUnretained(event)
    }

    private func isPointInDragZone(_ cocoaPt: NSPoint) -> Bool {
        guard let panel, panel.isVisible else { return false }
        if let view = dragZoneNSView, view.window === panel, view.bounds.width > 8 {
            let screenRect = panel.convertToScreen(view.convert(view.bounds, to: nil))
            if screenRect.contains(cocoaPt) {
                return true
            }
        }
        if state.isNotchDocked,
           let leftView = leftNotchDragZoneNSView,
           leftView.window === panel,
           leftView.bounds.width > 8 {
            let screenRect = panel.convertToScreen(leftView.convert(leftView.bounds, to: nil))
            if screenRect.contains(cocoaPt) {
                return true
            }
        }
        if dragZoneNSView != nil {
            return false
        }
        let f = panel.frame
        let leftInset: CGFloat = min(220, f.width * 0.35)
        let rightInset: CGFloat = 126
        guard f.width > leftInset + rightInset else { return false }
        let fallbackRect = CGRect(
            x: f.minX + leftInset,
            y: f.minY,
            width: f.width - leftInset - rightInset,
            height: f.height
        )
        return fallbackRect.contains(cocoaPt)
    }

    private func ensureDragGhostPanel() -> NonActivatingFloatingPanel {
        if let existing = dragGhostPanel {
            return existing
        }
        let p = NonActivatingFloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.allowsNotchAreaPlacement = true
        p.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.contentView = NSHostingView(rootView: DragGhostPreviewView(state: dragGhostState))
        dragGhostPanel = p
        return p
    }

    private func focusBackgroundWindow(pid: pid_t, windowID: CGWindowID) {
        if let targetApp = NSRunningApplication(processIdentifier: pid) {
            targetApp.activate(options: [.activateAllWindows])
        }
        if let win = AccessibilityBridge.standardWindows(for: pid).first(where: { $0.windowID == windowID }) {
            AccessibilityBridge.focusWindow(win)
        }
        syncActiveWindow()
    }

    private func handleTapMouseDown(locationAX: CGPoint, clickCount: Int64) -> Bool {
        isBlockingNativeTitlebarDrag = false

        let primaryH = AccessibilityBridge.primaryScreenHeight()
        let cocoaPt = NSPoint(x: locationAX.x, y: primaryH - locationAX.y)

        // 1. Clicks inside our chrome bar
        if let panel, panel.isVisible, panel.frame.contains(cocoaPt) {
            if let win = currentWindow,
               isPointInDragZone(cocoaPt) {
                if clickCount == 2 {
                    DispatchQueue.main.async { [weak self] in
                        self?.toggleMaximizeCurrentWindow()
                    }
                    return true
                }

                let fastFrame = AccessibilityBridge.liveWindowBounds(windowID: win.windowID) ?? win.axFrame
                let screen = AccessibilityBridge.screenContaining(axFrame: fastFrame) ?? NSScreen.main ?? NSScreen.screens.first
                let barH = CGFloat(model.config.windowBarHeight)
                let screenTopAX = screen.map { primaryH - min($0.visibleFrame.maxY, $0.frame.maxY) } ?? 0
                let topSafeReserve = (screen?.safeAreaInsets.top ?? 0) >= barH ? 0 : barH

                dragTargetWindow = AXWindowInfo(
                    pid: win.pid,
                    windowID: win.windowID,
                    title: win.title,
                    axFrame: fastFrame,
                    isMinimized: win.isMinimized,
                    isFullScreen: win.isFullScreen,
                    element: win.element
                )
                dragStartMouseAX = locationAX
                dragStartWindowFrameAX = fastFrame
                dragWasMaximized = screen.map { snapManager.isWindowMaximized(dragTargetWindow!, on: $0) } ?? false
                dragDidStartVisualGhost = false
                dragGhostWindowSizeAX = fastFrame.size
                dragGhostCurrentWindowOriginAX = fastFrame.origin
                dragGhostGrabOffsetAX = CGPoint(
                    x: locationAX.x - fastFrame.minX,
                    y: locationAX.y - fastFrame.minY
                )
                dragMinSafeAXTop = screenTopAX + topSafeReserve
                isDraggingTargetWindow = true
                snapManager.suppressGlobalDragMonitor = true
                snapPanel?.orderOut(nil)
                return true
            }
            // Menu items & caption buttons on our bar handle their own clicks without launching external drag sync.
            return false
        }

        // 2. Clicks inside the foreground traffic-light mask are blocked completely.
        if trafficLightMaskPanel?.isVisible == true,
           trafficLightMaskPanel?.frame.contains(cocoaPt) == true {
            isBlockingNativeTitlebarDrag = true
            return true
        }

        // 3. Clicks inside a background window's traffic-light mask focus that window without starting an OS drag.
        if let (bgWID, entry) = backgroundMasks.first(where: { $0.value.panel.isVisible && $0.value.panel.frame.contains(cocoaPt) }) {
            isBlockingNativeTitlebarDrag = true
            let pid = entry.pid
            DispatchQueue.main.async { [weak self] in
                self?.focusBackgroundWindow(pid: pid, windowID: bgWID)
            }
            return true
        }

        // 4. Fast path for ordinary body clicks strictly inside focused window content (zero CGWindowList / AX IPC / timers).
        if let win = currentWindow {
            let f = win.axFrame
            if locationAX.x > f.minX + 10
                && locationAX.x < f.maxX - 10
                && locationAX.y > f.minY + 54
                && locationAX.y < f.maxY - 10 {
                return false
            }
        }

        // 5. Block dragging/clicking empty native OS titlebar strip & exposed traffic lights on normal windows.
        if model.config.showWindowChromeBar && AccessibilityBridge.hasAccessibilityPermission(prompt: false) {
            let selfPID = ProcessInfo.processInfo.processIdentifier
            if let snap = AccessibilityBridge.onScreenNormalWindows().first(where: {
                $0.pid != selfPID && $0.axBounds.contains(locationAX)
            }) {
                let bundleID = NSRunningApplication(processIdentifier: snap.pid)?.bundleIdentifier ?? ""
                let excluded = bundleID == model.config.fileExplorerBundleID
                    || bundleID == "com.apple.finder"
                    || model.config.windowBarExcludedBundleIDs.contains(bundleID)
                let isFullscreen: Bool
                if let screen = AccessibilityBridge.screenContaining(axFrame: snap.axBounds) {
                    isFullscreen = abs(snap.axBounds.width - screen.frame.width) < 4
                        && abs(snap.axBounds.height - screen.frame.height) < 4
                } else {
                    isFullscreen = false
                }

                if !excluded && !isFullscreen {
                    let titlebarH = WindowChromeGeometry.estimatedNativeTitlebarHeight(
                        trafficLightRelativeRect: cachedMaskRelativeOffsets[snap.windowID]
                    )
                    if WindowChromeGeometry.isInNativeTitlebarBand(
                        axPoint: locationAX,
                        windowAXFrame: snap.axBounds,
                        titlebarHeight: titlebarH,
                        resizeBorder: 5
                    ) {
                        let hit = AccessibilityBridge.classifyTitlebarHit(atAXPoint: locationAX, pid: snap.pid)
                        if hit == .trafficLight || hit == .nativeTitlebarDragSurface {
                            isBlockingNativeTitlebarDrag = true
                            if snap.windowID != currentWindow?.windowID {
                                let targetPID = snap.pid
                                let targetWID = snap.windowID
                                DispatchQueue.main.async { [weak self] in
                                    self?.focusBackgroundWindow(pid: targetPID, windowID: targetWID)
                                }
                            }
                            return true
                        }
                    }
                }
            }
        }

        // 6. Start external drag sync only when resizing near focused window edges or dragging File Explorer titlebar.
        if let win = currentWindow {
            let f = win.axFrame
            let nearEdge = abs(locationAX.x - f.minX) <= 10
                || abs(locationAX.x - f.maxX) <= 10
                || abs(locationAX.y - f.minY) <= 10
                || abs(locationAX.y - f.maxY) <= 10
            let inFileExplorerTitle = (currentBundleID == model.config.fileExplorerBundleID)
                && (locationAX.y <= f.minY + 46)
            if nearEdge || inFileExplorerTitle {
                isExternalMouseDragging = true
                startFastDragSyncTimer()
            }
        }
        return false
    }

    private func handleTapMouseDragged(locationAX: CGPoint) -> Bool {
        if isBlockingNativeTitlebarDrag {
            return true
        }
        guard isDraggingTargetWindow, let win = dragTargetWindow else {
            return false
        }

        let dx = locationAX.x - dragStartMouseAX.x
        let dy = locationAX.y - dragStartMouseAX.y
        let barH = CGFloat(model.config.windowBarHeight)

        if !dragDidStartVisualGhost {
            guard hypot(dx, dy) >= 3 else {
                return true
            }
            dragDidStartVisualGhost = true

            if dragWasMaximized {
                let bid = currentBundleID.isEmpty
                    ? (NSRunningApplication(processIdentifier: win.pid)?.bundleIdentifier ?? "")
                    : currentBundleID
                let screen = AccessibilityBridge.screenContaining(axFrame: dragStartWindowFrameAX)
                    ?? NSScreen.main
                    ?? NSScreen.screens.first
                let restoredSize = screen.map {
                    snapManager.restoreSizeForDrag(window: win, bundleID: bid, on: $0)
                } ?? CGSize(width: 1200, height: 780)
                dragGhostWindowSizeAX = restoredSize
                dragGhostGrabOffsetAX = CGPoint(x: restoredSize.width / 2, y: -(barH / 2))
            } else {
                dragGhostWindowSizeAX = dragStartWindowFrameAX.size
                if dragGhostGrabOffsetAX.y > 0 {
                    dragGhostGrabOffsetAX.y = -(barH / 2)
                }
            }

            panel?.orderOut(nil)
            dragGhostState.appIcon = state.appIcon
            dragGhostState.title = state.windowTitle
            dragGhostState.barHeight = barH

            let targetWinX = (locationAX.x - dragGhostGrabOffsetAX.x).rounded()
            let targetWinY = max(dragMinSafeAXTop, (locationAX.y - dragGhostGrabOffsetAX.y).rounded())
            dragGhostCurrentWindowOriginAX = CGPoint(x: targetWinX, y: targetWinY)

            let primaryH = AccessibilityBridge.primaryScreenHeight()
            let ghostAXRect = CGRect(
                x: targetWinX,
                y: targetWinY - barH,
                width: dragGhostWindowSizeAX.width,
                height: dragGhostWindowSizeAX.height + barH
            )
            let ghostCocoaRect = WindowChromeGeometry.axRectToCocoa(ghostAXRect, primaryScreenHeight: primaryH)
            let ghostPanel = ensureDragGhostPanel()
            ghostPanel.setFrame(ghostCocoaRect, display: true)
            ghostPanel.orderFrontRegardless()
        }

        let targetWinX = (locationAX.x - dragGhostGrabOffsetAX.x).rounded()
        let targetWinY = max(dragMinSafeAXTop, (locationAX.y - dragGhostGrabOffsetAX.y).rounded())
        dragGhostCurrentWindowOriginAX = CGPoint(x: targetWinX, y: targetWinY)

        let primaryH = AccessibilityBridge.primaryScreenHeight()
        let ghostAXRect = CGRect(
            x: targetWinX,
            y: targetWinY - barH,
            width: dragGhostWindowSizeAX.width,
            height: dragGhostWindowSizeAX.height + barH
        )
        let ghostCocoaRect = WindowChromeGeometry.axRectToCocoa(ghostAXRect, primaryScreenHeight: primaryH)
        if let ghostPanel = dragGhostPanel {
            setPanelFrameFast(ghostPanel, to: ghostCocoaRect)
        }

        let cocoaMouse = NSPoint(x: locationAX.x, y: primaryH - locationAX.y)
        snapManager.updateDragPreview(mouseLocationCocoa: cocoaMouse)
        return true
    }

    private func handleTapMouseUp() -> Bool {
        if isBlockingNativeTitlebarDrag {
            isBlockingNativeTitlebarDrag = false
            return true
        }

        if isExternalMouseDragging {
            isExternalMouseDragging = false
            fastDragSyncTimer?.invalidate()
            fastDragSyncTimer = nil
            DispatchQueue.main.async { [weak self] in
                self?.syncActiveWindow()
            }
        }

        guard isDraggingTargetWindow else {
            return false
        }

        let win = dragTargetWindow ?? currentWindow
        let bid = currentBundleID.isEmpty ? nil : currentBundleID
        let didMove = dragDidStartVisualGhost
        let wasMax = dragWasMaximized
        let finalAXFrame = CGRect(origin: dragGhostCurrentWindowOriginAX, size: dragGhostWindowSizeAX)

        dragGhostPanel?.orderOut(nil)
        isDraggingTargetWindow = false
        dragDidStartVisualGhost = false
        dragTargetWindow = nil
        snapManager.suppressGlobalDragMonitor = false

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let didSnap = self.snapManager.commitDragSnapIfActive(window: win, bundleID: bid)
            if !didSnap && didMove, let win {
                if wasMax {
                    self.snapManager.clearSavedRestoreFrame(for: win, bundleID: bid ?? "")
                    AccessibilityBridge.setFrame(win.element, axFrame: finalAXFrame)
                } else {
                    AccessibilityBridge.setPosition(win.element, origin: finalAXFrame.origin)
                }
            }
            self.syncActiveWindow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.syncActiveWindow()
        }
        return true
    }

    private func startFastDragSyncTimer() {
        fastDragSyncTimer?.invalidate()
        fastDragSyncTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 45.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isExternalMouseDragging else { return }
                self.syncOverlayPositionsFromWindowServer()
            }
        }
    }

    private func dragCurrentWindow(deltaX: CGFloat, deltaY: CGFloat) {
        guard let win = currentWindow, let panel else { return }
        isDraggingTargetWindow = true
        snapManager.suppressGlobalDragMonitor = true
        let newOrigin = CGPoint(x: win.axFrame.origin.x + deltaX, y: win.axFrame.origin.y - deltaY)
        AccessibilityBridge.setPosition(win.element, origin: newOrigin)
        let updated = AXWindowInfo(
            pid: win.pid,
            windowID: win.windowID,
            title: win.title,
            axFrame: CGRect(origin: newOrigin, size: win.axFrame.size),
            isMinimized: win.isMinimized,
            isFullScreen: win.isFullScreen,
            element: win.element
        )
        currentWindow = updated
        panel.setFrameOrigin(NSPoint(x: panel.frame.origin.x + deltaX, y: panel.frame.origin.y + deltaY))
        if let maskPanel = trafficLightMaskPanel, maskPanel.isVisible {
            maskPanel.setFrameOrigin(NSPoint(x: maskPanel.frame.origin.x + deltaX, y: maskPanel.frame.origin.y + deltaY))
        }
        snapManager.updateDragPreview(mouseLocationCocoa: NSEvent.mouseLocation)
    }

    private func finishDraggingCurrentWindow() {
        let win = currentWindow
        let bid = currentBundleID.isEmpty ? nil : currentBundleID
        isDraggingTargetWindow = false
        snapManager.suppressGlobalDragMonitor = false
        _ = snapManager.commitDragSnapIfActive(window: win, bundleID: bid)
        syncActiveWindow()
    }

    // MARK: - Live Mirrored App Menus

    private func openMirroredMenu(item: MirroredMenuItem, anchorView: NSView) {
        let children = AccessibilityBridge.readMenuChildren(of: item.element, maxDepth: 2)
        if children.isEmpty {
            AccessibilityBridge.performPress(item.element)
            return
        }
        let menu = AccessibilityBridge.buildNSMenu(from: children, target: self, action: #selector(handleMirroredMenuAction(_:)))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: anchorView)
    }

    private func openOverflowMenus(items: [MirroredMenuItem], anchorView: NSView) {
        let menu = NSMenu()
        for item in items {
            let sub = AccessibilityBridge.readMenuChildren(of: item.element, maxDepth: 2)
            let mi = NSMenuItem(title: item.title, action: sub.isEmpty ? #selector(handleMirroredMenuAction(_:)) : nil, keyEquivalent: "")
            mi.target = sub.isEmpty ? self : nil
            mi.representedObject = item.element
            if !sub.isEmpty {
                mi.submenu = AccessibilityBridge.buildNSMenu(from: sub, target: self, action: #selector(handleMirroredMenuAction(_:)))
            }
            menu.addItem(mi)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: anchorView)
    }

    @objc private func handleMirroredMenuAction(_ sender: NSMenuItem) {
        guard let el = sender.representedObject else { return }
        let axEl = el as! AXUIElement
        AccessibilityBridge.performPress(axEl)
    }

    // MARK: - Snap Layouts Hover Picker

    private func handleMaximizeHover(hovering: Bool, anchorRect: NSRect) {
        snapDismissWork?.cancel()
        if hovering {
            let work = DispatchWorkItem { [weak self] in
                self?.showSnapLayoutsPicker(anchorScreenRect: anchorRect)
            }
            snapDismissWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: work)
        } else {
            let work = DispatchWorkItem { [weak self] in
                self?.snapPanel?.orderOut(nil)
            }
            snapDismissWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    private func showSnapLayoutsPicker(anchorScreenRect: NSRect) {
        if snapPanel == nil {
            let p = NonActivatingFloatingPanel(
                contentRect: NSRect(x: 0, y: 0, width: 236, height: 122),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.level = .popUpMenu
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.contentView = NSHostingView(rootView: SnapLayoutsPopoverView(
                onSelect: { [weak self] zone in
                    self?.applySnapZone(zone)
                },
                onHoverInside: { [weak self] inside in
                    self?.snapDismissWork?.cancel()
                    if !inside {
                        let w = DispatchWorkItem { [weak self] in
                            self?.snapPanel?.orderOut(nil)
                        }
                        self?.snapDismissWork = w
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
                    }
                }
            ))
            snapPanel = p
        }

        let origin = NSPoint(
            x: anchorScreenRect.maxX - 236,
            y: anchorScreenRect.minY - 126
        )
        snapPanel?.setFrameOrigin(origin)
        snapPanel?.orderFrontRegardless()
    }
}

private struct SnapLayoutsPopoverView: View {
    let onSelect: (WindowSnapZone) -> Void
    let onHoverInside: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            // 50 / 50
            HStack(spacing: 3) {
                zoneBox(.leftHalf)
                zoneBox(.rightHalf)
            }
            .frame(width: 62, height: 42)

            // 66 / 34
            HStack(spacing: 3) {
                zoneBox(.leftTwoThirds)
                zoneBox(.rightOneThird)
                    .frame(width: 20)
            }
            .frame(width: 62, height: 42)

            // 4 quadrants
            VStack(spacing: 3) {
                HStack(spacing: 3) {
                    zoneBox(.topLeft)
                    zoneBox(.topRight)
                }
                HStack(spacing: 3) {
                    zoneBox(.bottomLeft)
                    zoneBox(.bottomRight)
                }
            }
            .frame(width: 62, height: 42)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThickMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                )
        )
        .onHover { onHoverInside($0) }
    }

    private func zoneBox(_ zone: WindowSnapZone) -> some View {
        SnapZoneButton(onTap: { onSelect(zone) })
    }
}

private struct SnapZoneButton: View {
    let onTap: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(hovered ? Color.accentColor : Color.primary.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.75)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct WindowChromeBarView: View {
    let state: WindowChromeBarState
    let onMenuClick: (MirroredMenuItem, NSView) -> Void
    let onOverflowMenusClick: ([MirroredMenuItem], NSView) -> Void
    let onDragZoneReady: (NSView) -> Void
    let onLeftDragZoneReady: (NSView) -> Void
    let onDragDelta: (CGFloat, CGFloat) -> Void
    let onDragEnded: () -> Void
    let onDoubleClickTitle: () -> Void
    let onMinimize: () -> Void
    let onMaximize: () -> Void
    let onClose: () -> Void
    let onHoverMaximize: (Bool, NSRect) -> Void

    var body: some View {
        let barHeight: CGFloat = state.isNotchDocked ? 38 : 28
        Group {
            if state.isNotchDocked {
                HStack(spacing: 0) {
                    HStack(spacing: 0) {
                        menuStrip(visibleCount: 6)
                        ChromeTitleDragArea(
                            title: "",
                            onViewReady: onLeftDragZoneReady,
                            onDragDelta: onDragDelta,
                            onDragEnded: onDragEnded,
                            onDoubleClick: onDoubleClickTitle
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(width: state.leftNotchWidth)
                    .frame(maxHeight: .infinity)

                    Color.black
                        .frame(width: state.notchWidth)
                        .frame(maxHeight: .infinity)

                    HStack(spacing: 0) {
                        ChromeTitleDragArea(
                            title: state.windowTitle,
                            onViewReady: onDragZoneReady,
                            onDragDelta: onDragDelta,
                            onDragEnded: onDragEnded,
                            onDoubleClick: onDoubleClickTitle
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        captionButtons(height: barHeight)
                    }
                    .frame(width: state.rightNotchWidth)
                    .frame(maxHeight: .infinity)
                }
            } else {
                HStack(spacing: 0) {
                    menuStrip(visibleCount: 7)

                    ChromeTitleDragArea(
                        title: state.windowTitle,
                        onViewReady: onDragZoneReady,
                        onDragDelta: onDragDelta,
                        onDragEnded: onDragEnded,
                        onDoubleClick: onDoubleClickTitle
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    captionButtons(height: barHeight)
                }
            }
        }
        .frame(height: barHeight)
        .background(
            Group {
                if state.isNotchDocked {
                    Color.black
                } else {
                    AcrylicBackground(material: .titlebar)
                }
            }
            .overlay(
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundStyle(Color.white.opacity(state.isNotchDocked ? 0.14 : 0.12)),
                alignment: .bottom
            )
        )
    }

    @ViewBuilder
    private func menuStrip(visibleCount: Int) -> some View {
        HStack(spacing: 4) {
            if let icon = state.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 15, height: 15)
                    .padding(.leading, 8)
            }

            let visibleMenus = Array(state.menuItems.prefix(visibleCount))
            let overflowMenus = Array(state.menuItems.dropFirst(visibleCount))

            ForEach(Array(visibleMenus.enumerated()), id: \.offset) { _, item in
                MenuAnchorButton(title: item.title) { anchorView in
                    onMenuClick(item, anchorView)
                }
            }

            if !overflowMenus.isEmpty {
                MenuAnchorButton(title: "•••") { anchorView in
                    onOverflowMenusClick(overflowMenus, anchorView)
                }
            }
        }
    }

    @ViewBuilder
    private func captionButtons(height: CGFloat) -> some View {
        HStack(spacing: 0) {
            CaptionButton(symbol: "minus", hoverColor: Color.primary.opacity(0.12), height: height, action: onMinimize)

            CaptionButton(
                symbol: state.isMaximized ? "square.on.square" : "square",
                hoverColor: Color.primary.opacity(0.12),
                height: height,
                action: onMaximize,
                onHoverWithScreenRect: { hovering, rect in
                    onHoverMaximize(hovering, rect)
                }
            )

            CaptionButton(
                symbol: "xmark",
                hoverColor: Color(red: 0.77, green: 0.17, blue: 0.11),
                hoverForeground: .white,
                height: height,
                action: onClose
            )
        }
    }
}

private struct DragGhostPreviewView: View {
    let state: DragGhostState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let icon = state.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 15, height: 15)
                        .padding(.leading, 10)
                }

                Text(state.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                HStack(spacing: 0) {
                    ghostCaptionGlyph("minus")
                    ghostCaptionGlyph("square")
                    ghostCaptionGlyph("xmark")
                }
            }
            .frame(height: state.barHeight)
            .background(Color(red: 0.10, green: 0.10, blue: 0.12).opacity(0.94))
            .overlay(
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundStyle(Color.white.opacity(0.16)),
                alignment: .bottom
            )

            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.24))
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 1.5)

                HStack(spacing: 8) {
                    if let icon = state.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 18, height: 18)
                    }
                    Text(state.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(0.45))
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
        )
    }

    private func ghostCaptionGlyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.65))
            .frame(width: 42, height: state.barHeight)
    }
}

private struct MenuAnchorButton: View {
    let title: String
    let onPress: (NSView) -> Void
    @State private var hovered = false
    @State private var anchorNSView: NSView?

    var body: some View {
        Button {
            if let anchorNSView {
                onPress(anchorNSView)
            }
        } label: {
            Text(title)
                .font(.system(size: 11.5, weight: .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(hovered ? Color.primary.opacity(0.12) : .clear)
                )
        }
        .buttonStyle(.plain)
        .background(AnchorViewFinder(viewRef: $anchorNSView))
        .onHover { hovered = $0 }
    }
}

private struct AnchorViewFinder: NSViewRepresentable {
    @Binding var viewRef: NSView?

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            viewRef = v
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct CaptionButton: View {
    let symbol: String
    let hoverColor: Color
    var hoverForeground: Color = .primary
    var height: CGFloat = 28
    let action: () -> Void
    var onHoverWithScreenRect: ((Bool, NSRect) -> Void)?

    @State private var hovered = false
    @State private var hostView: NSView?

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(hovered ? hoverForeground : .primary)
                .frame(width: 42, height: height)
                .background(hovered ? hoverColor : .clear)
        }
        .buttonStyle(.plain)
        .background(AnchorViewFinder(viewRef: $hostView))
        .onHover { isHovering in
            hovered = isHovering
            if let onHoverWithScreenRect, let hostView, let win = hostView.window {
                let rectInWin = hostView.convert(hostView.bounds, to: nil)
                let screenRect = win.convertToScreen(rectInWin)
                onHoverWithScreenRect(isHovering, screenRect)
            }
        }
    }
}

private struct ChromeTitleDragArea: NSViewRepresentable {
    let title: String
    let onViewReady: (NSView) -> Void
    let onDragDelta: (CGFloat, CGFloat) -> Void
    let onDragEnded: () -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> TitleDragNSView {
        let v = TitleDragNSView()
        v.onDragDelta = onDragDelta
        v.onDragEnded = onDragEnded
        v.onDoubleClick = onDoubleClick
        v.title = title
        DispatchQueue.main.async {
            onViewReady(v)
        }
        return v
    }

    func updateNSView(_ nsView: TitleDragNSView, context: Context) {
        nsView.title = title
        nsView.onDragDelta = onDragDelta
        nsView.onDragEnded = onDragEnded
        nsView.onDoubleClick = onDoubleClick
        onViewReady(nsView)
    }
}

private final class TitleDragNSView: NSView {
    var title: String = "" {
        didSet { label.stringValue = title }
    }
    var onDragDelta: ((CGFloat, CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private var lastScreenPoint: NSPoint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.centerXAnchor.constraint(equalTo: centerXAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        var lastPoint = NSEvent.mouseLocation
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            switch next.type {
            case .leftMouseDragged:
                let current = NSEvent.mouseLocation
                let dx = current.x - lastPoint.x
                let dy = current.y - lastPoint.y
                lastPoint = current
                if abs(dx) > 0.1 || abs(dy) > 0.1 {
                    onDragDelta?(dx, dy)
                }
            case .leftMouseUp:
                onDragEnded?()
                return
            default:
                break
            }
        }
        onDragEnded?()
    }
}

private final class TrafficLightMaskNSView: NSView {
    var fillColor: NSColor = NSColor(srgbRed: 0.118, green: 0.118, blue: 0.122, alpha: 1.0) {
        didSet {
            layer?.backgroundColor = fillColor.cgColor
        }
    }
    var onDragDelta: ((CGFloat, CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onSimpleClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.masksToBounds = true
        layer?.backgroundColor = fillColor.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if let onSimpleClick {
            onSimpleClick()
            return
        }
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        super.mouseDown(with: event)
    }
}
