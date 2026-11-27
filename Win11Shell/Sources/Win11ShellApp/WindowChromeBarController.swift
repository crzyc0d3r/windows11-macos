import AppKit
import ApplicationServices
import Observation
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
    public var showSnapLayouts: Bool = false
    public var hoveredButton: String?
}

@MainActor
public final class WindowChromeBarController: NSObject {
    private let model: RunningAppsModel
    private let snapManager: WindowSnapManager
    private let state = WindowChromeBarState()
    private var panel: NonActivatingFloatingPanel?
    private var snapPanel: NonActivatingFloatingPanel?
    private var trafficLightMaskPanel: NonActivatingFloatingPanel?
    private var trafficLightMaskView: TrafficLightMaskNSView?
    private weak var dragZoneNSView: NSView?
    private var sampledMaskColors: [String: NSColor] = [:]
    private var pendingMaskColorKeys: Set<String> = []
    private var syncTimer: Timer?
    private var axObserver: AXObserver?
    private var observedPID: pid_t = 0
    private var lastMenuPID: pid_t = 0
    private var cachedMenusByPID: [pid_t: [MirroredMenuItem]] = [:]
    private var currentWindow: AXWindowInfo?
    private var currentBundleID: String = ""
    private var isDraggingTargetWindow = false
    private var dragTargetWindow: AXWindowInfo?
    private var dragStartMouseAX: CGPoint = .zero
    private var dragStartWindowFrameAX: CGRect = .zero
    private var dragStartPanelFrameCocoa: CGRect = .zero
    private var dragStartMaskOriginCocoa: CGPoint?
    private var dragWasMaximized = false
    private var dragDidUnmaximize = false
    private var dragMinSafeAXTop: CGFloat = 28
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
        syncTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
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
        bar.level = .floating
        bar.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        bar.backgroundColor = .clear
        bar.isOpaque = false
        bar.hasShadow = true

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
        guard model.config.showWindowChromeBar,
              !isDraggingTargetWindow,
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
        guard let barRect = WindowChromeGeometry.dockedBarFrame(
            forAXWindowFrame: win.axFrame,
            primaryScreenHeight: primaryH,
            screenFrameCocoa: screen.frame,
            visibleFrameCocoa: screen.visibleFrame,
            barHeight: CGFloat(model.config.windowBarHeight),
            taskbarHeight: CGFloat(model.config.taskbarHeight)
        ) else {
            hideBar()
            return
        }

        let pid = front.processIdentifier
        currentWindow = win
        currentBundleID = bundleID
        state.appName = front.localizedName ?? bundleID
        state.appIcon = AppIconCache.icon(forBundleID: bundleID, url: front.bundleURL, size: 16)
        state.windowTitle = win.title.isEmpty ? state.appName : win.title
        state.isMaximized = snapManager.isWindowMaximized(win, on: screen)

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
            if panel.frame != barRect {
                panel.setFrame(barRect, display: true)
            }
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
        }

        syncTrafficLightMask(for: win, bundleID: bundleID, primaryScreenHeight: primaryH)
    }

    private func hideBar() {
        currentWindow = nil
        panel?.orderOut(nil)
        snapPanel?.orderOut(nil)
        trafficLightMaskPanel?.orderOut(nil)
    }

    private func syncTrafficLightMask(for win: AXWindowInfo, bundleID: String, primaryScreenHeight: CGFloat) {
        guard bundleID != model.config.fileExplorerBundleID,
              let axMaskRect = AccessibilityBridge.trafficLightUnionAXRect(for: win.element)
        else {
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
            maskView.onDragDelta = { [weak self] dx, dy in
                self?.dragCurrentWindow(deltaX: dx, deltaY: dy)
            }
            maskView.onDragEnded = { [weak self] in
                self?.finishDraggingCurrentWindow()
            }
            maskView.onDoubleClick = { [weak self] in
                self?.toggleMaximizeCurrentWindow()
            }
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
            if maskPanel.frame != cocoaMaskRect {
                maskPanel.setFrame(cocoaMaskRect, display: true)
            }
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
        if let tap = mouseDragTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = mouseDragRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        mouseDragTap = nil
        mouseDragRunLoopSource = nil
        isDraggingTargetWindow = false
        snapManager.suppressGlobalDragMonitor = false
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

    private func dragZoneScreenRectCocoa() -> CGRect? {
        guard let panel, panel.isVisible else { return nil }
        if let view = dragZoneNSView, view.window === panel, view.bounds.width > 8 {
            let rectInWin = view.convert(view.bounds, to: nil)
            return panel.convertToScreen(rectInWin)
        }
        // Fallback: middle strip between left menus and right 126pt caption buttons
        let f = panel.frame
        let leftInset: CGFloat = min(220, f.width * 0.35)
        let rightInset: CGFloat = 126
        guard f.width > leftInset + rightInset else { return nil }
        return CGRect(x: f.minX + leftInset, y: f.minY, width: f.width - leftInset - rightInset, height: f.height)
    }

    private func handleTapMouseDown(locationAX: CGPoint, clickCount: Int64) -> Bool {
        guard let panel, panel.isVisible, let win = currentWindow else {
            return false
        }

        let primaryH = AccessibilityBridge.primaryScreenHeight()
        let cocoaPt = NSPoint(x: locationAX.x, y: primaryH - locationAX.y)

        let inTitleDrag = dragZoneScreenRectCocoa()?.contains(cocoaPt) ?? false
        let inTrafficMask = (trafficLightMaskPanel?.isVisible == true)
            && (trafficLightMaskPanel?.frame.contains(cocoaPt) == true)

        guard inTitleDrag || inTrafficMask else {
            return false
        }

        if clickCount == 2 {
            DispatchQueue.main.async { [weak self] in
                self?.toggleMaximizeCurrentWindow()
            }
            return true
        }

        let liveWin = AccessibilityBridge.windowInfo(for: win.element, pid: win.pid) ?? win
        let screen = AccessibilityBridge.screenContaining(axFrame: liveWin.axFrame) ?? NSScreen.main ?? NSScreen.screens.first
        let barH = CGFloat(model.config.windowBarHeight)
        let screenTopAX = screen.map { primaryH - min($0.visibleFrame.maxY, $0.frame.maxY) } ?? 0

        currentWindow = liveWin
        dragTargetWindow = liveWin
        dragStartMouseAX = locationAX
        dragStartWindowFrameAX = liveWin.axFrame
        dragStartPanelFrameCocoa = panel.frame
        dragStartMaskOriginCocoa = (trafficLightMaskPanel?.isVisible == true) ? trafficLightMaskPanel?.frame.origin : nil
        dragWasMaximized = screen.map { snapManager.isWindowMaximized(liveWin, on: $0) } ?? false
        dragDidUnmaximize = false
        dragMinSafeAXTop = screenTopAX + barH
        isDraggingTargetWindow = true
        snapManager.suppressGlobalDragMonitor = true
        snapPanel?.orderOut(nil)
        return true
    }

    private func handleTapMouseDragged(locationAX: CGPoint) -> Bool {
        guard isDraggingTargetWindow, let win = dragTargetWindow, let panel else {
            return false
        }

        var dx = locationAX.x - dragStartMouseAX.x
        var dy = locationAX.y - dragStartMouseAX.y

        if dragWasMaximized && !dragDidUnmaximize && hypot(dx, dy) > 10 {
            let bid = currentBundleID.isEmpty ? (NSRunningApplication(processIdentifier: win.pid)?.bundleIdentifier ?? "") : currentBundleID
            if let restored = snapManager.restoreFrameForDrag(window: win, bundleID: bid, cursorAX: locationAX) {
                let updatedWin = AXWindowInfo(
                    pid: win.pid,
                    windowID: win.windowID,
                    title: win.title,
                    axFrame: restored,
                    isMinimized: win.isMinimized,
                    isFullScreen: win.isFullScreen,
                    element: win.element
                )
                dragTargetWindow = updatedWin
                currentWindow = updatedWin
                dragStartWindowFrameAX = restored
                dragStartMouseAX = locationAX
                dragDidUnmaximize = true

                let primaryH = AccessibilityBridge.primaryScreenHeight()
                let barH = CGFloat(model.config.windowBarHeight)
                let newBarFrame = CGRect(
                    x: restored.minX,
                    y: primaryH - restored.minY,
                    width: restored.width,
                    height: barH
                )
                panel.setFrame(newBarFrame, display: true)
                dragStartPanelFrameCocoa = newBarFrame
                if let maskPanel = trafficLightMaskPanel, maskPanel.isVisible,
                   let axMask = AccessibilityBridge.trafficLightUnionAXRect(for: win.element) {
                    let cocoaMask = WindowChromeGeometry.axRectToCocoa(axMask, primaryScreenHeight: primaryH)
                    maskPanel.setFrame(cocoaMask, display: true)
                    dragStartMaskOriginCocoa = cocoaMask.origin
                }
                dx = 0
                dy = 0
            }
        }

        let targetX = (dragStartWindowFrameAX.origin.x + dx).rounded()
        let targetY = max(dragMinSafeAXTop, dragStartWindowFrameAX.origin.y + dy).rounded()
        let appliedDX = targetX - dragStartWindowFrameAX.origin.x
        let appliedDY = targetY - dragStartWindowFrameAX.origin.y

        let newOriginAX = CGPoint(x: targetX, y: targetY)
        AccessibilityBridge.setPosition(win.element, origin: newOriginAX)

        let updatedWin = AXWindowInfo(
            pid: win.pid,
            windowID: win.windowID,
            title: win.title,
            axFrame: CGRect(origin: newOriginAX, size: dragStartWindowFrameAX.size),
            isMinimized: win.isMinimized,
            isFullScreen: win.isFullScreen,
            element: win.element
        )
        dragTargetWindow = updatedWin
        currentWindow = updatedWin

        panel.setFrameOrigin(NSPoint(
            x: dragStartPanelFrameCocoa.origin.x + appliedDX,
            y: dragStartPanelFrameCocoa.origin.y - appliedDY
        ))
        if let maskPanel = trafficLightMaskPanel, maskPanel.isVisible, let startMaskOrigin = dragStartMaskOriginCocoa {
            maskPanel.setFrameOrigin(NSPoint(
                x: startMaskOrigin.x + appliedDX,
                y: startMaskOrigin.y - appliedDY
            ))
        }

        let primaryH = AccessibilityBridge.primaryScreenHeight()
        let cocoaMouse = NSPoint(x: locationAX.x, y: primaryH - locationAX.y)
        snapManager.updateDragPreview(mouseLocationCocoa: cocoaMouse)
        return true
    }

    private func handleTapMouseUp() -> Bool {
        guard isDraggingTargetWindow else {
            return false
        }
        let win = dragTargetWindow ?? currentWindow
        let bid = currentBundleID.isEmpty ? nil : currentBundleID
        isDraggingTargetWindow = false
        dragTargetWindow = nil
        dragStartMaskOriginCocoa = nil
        snapManager.suppressGlobalDragMonitor = false

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            _ = self.snapManager.commitDragSnapIfActive(window: win, bundleID: bid)
            self.syncActiveWindow()
        }
        return true
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
    let onDragDelta: (CGFloat, CGFloat) -> Void
    let onDragEnded: () -> Void
    let onDoubleClickTitle: () -> Void
    let onMinimize: () -> Void
    let onMaximize: () -> Void
    let onClose: () -> Void
    let onHoverMaximize: (Bool, NSRect) -> Void

    var body: some View {
        HStack(spacing: 0) {
            // App icon + live self-contained menu bar
            HStack(spacing: 4) {
                if let icon = state.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 15, height: 15)
                        .padding(.leading, 8)
                }

                let visibleMenus = Array(state.menuItems.prefix(7))
                let overflowMenus = Array(state.menuItems.dropFirst(7))

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

            // Draggable title strip
            ChromeTitleDragArea(
                title: state.windowTitle,
                onViewReady: onDragZoneReady,
                onDragDelta: onDragDelta,
                onDragEnded: onDragEnded,
                onDoubleClick: onDoubleClickTitle
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Right-side Windows 11 caption buttons: — □ ✕
            HStack(spacing: 0) {
                CaptionButton(symbol: "minus", hoverColor: Color.primary.opacity(0.12), action: onMinimize)

                CaptionButton(
                    symbol: state.isMaximized ? "square.on.square" : "square",
                    hoverColor: Color.primary.opacity(0.12),
                    action: onMaximize,
                    onHoverWithScreenRect: { hovering, rect in
                        onHoverMaximize(hovering, rect)
                    }
                )

                CaptionButton(
                    symbol: "xmark",
                    hoverColor: Color(red: 0.77, green: 0.17, blue: 0.11),
                    hoverForeground: .white,
                    action: onClose
                )
            }
        }
        .frame(height: 28)
        .background(
            AcrylicBackground(material: .titlebar)
                .overlay(
                    Rectangle()
                        .frame(height: 0.5)
                        .foregroundStyle(Color.white.opacity(0.12)),
                    alignment: .bottom
                )
        )
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
    let action: () -> Void
    var onHoverWithScreenRect: ((Bool, NSRect) -> Void)?

    @State private var hovered = false
    @State private var hostView: NSView?

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(hovered ? hoverForeground : .primary)
                .frame(width: 42, height: 28)
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
