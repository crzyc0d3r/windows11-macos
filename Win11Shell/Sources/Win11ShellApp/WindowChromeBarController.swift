import AppKit
import ApplicationServices
import Observation
import QuartzCore
import SwiftUI
import Win11ShellCore

private enum ChromeBarAppearance {
    static let fillColor = Color(red: 0.115, green: 0.115, blue: 0.132)
    static let inactiveFillColor = Color(red: 0.138, green: 0.138, blue: 0.155).opacity(0.95)
    static let notchFillColor = Color.black
    static let inactiveNotchFillColor = Color(red: 0.06, green: 0.06, blue: 0.07)
    static let outerBorderColor = Color.white.opacity(0.15)
    static let inactiveOuterBorderColor = Color.white.opacity(0.10)
    static let bottomDividerColor = Color.white.opacity(0.10)
    static let menuForeground = Color.white.opacity(0.90)
    static let titleForeground = Color.white.opacity(0.76)
    static let inactiveTitleForeground = Color.white.opacity(0.54)
    static let captionForeground = Color.white.opacity(0.86)
    static let inactiveCaptionForeground = Color.white.opacity(0.56)
    static let hoverFill = Color.white.opacity(0.12)
    static let closeHoverFill = Color(red: 0.77, green: 0.17, blue: 0.11)
    static let floatingTopCornerRadius: CGFloat = 12
    static let windowInnerCornerRadius: CGFloat = 15
    static let cornerSkirtHeight: CGFloat = 20
}

private struct FloatingChromeCapShape: Shape {
    let barHeight: CGFloat
    let topCornerRadius: CGFloat
    let innerCornerRadius: CGFloat
    let skirtHeight: CGFloat
    var roundTopLeft: Bool = true
    var roundTopRight: Bool = true

    func path(in rect: CGRect) -> Path {
        let outer = UnevenRoundedRectangle(
            topLeadingRadius: roundTopLeft ? topCornerRadius : 0,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: roundTopRight ? topCornerRadius : 0,
            style: .continuous
        ).path(in: rect)

        guard skirtHeight > 0.5,
              innerCornerRadius > 0.5,
              rect.height > barHeight + 0.5
        else {
            return outer
        }

        let leftExtend: CGFloat = roundTopLeft ? 0 : innerCornerRadius * 2
        let rightExtend: CGFloat = roundTopRight ? 0 : innerCornerRadius * 2
        let cutoutRect = CGRect(
            x: rect.minX - leftExtend,
            y: rect.minY + barHeight,
            width: rect.width + leftExtend + rightExtend,
            height: max(rect.height - barHeight + innerCornerRadius * 2, innerCornerRadius * 3)
        )
        let cutout = RoundedRectangle(cornerRadius: innerCornerRadius, style: .continuous).path(in: cutoutRect)
        return outer.subtracting(cutout)
    }
}

private struct CornerSkirtCutoutShape: Shape {
    let innerCornerRadius: CGFloat
    var roundTopLeft: Bool = true
    var roundTopRight: Bool = true

    func path(in rect: CGRect) -> Path {
        let outer = Rectangle().path(in: rect)
        guard innerCornerRadius > 0.5, rect.width > 1, rect.height > 1 else {
            return outer
        }
        let leftExtend: CGFloat = roundTopLeft ? 0 : innerCornerRadius * 2
        let rightExtend: CGFloat = roundTopRight ? 0 : innerCornerRadius * 2
        let cutoutRect = CGRect(
            x: rect.minX - leftExtend,
            y: rect.minY,
            width: rect.width + leftExtend + rightExtend,
            height: rect.height + innerCornerRadius * 2
        )
        let cutout = RoundedRectangle(cornerRadius: innerCornerRadius, style: .continuous).path(in: cutoutRect)
        return outer.subtracting(cutout)
    }
}

private struct OccludedBarMaskShape: Shape {
    let topLeadingRadius: CGFloat
    let topTrailingRadius: CGFloat
    let occludedLocalRects: [CGRect]

    func path(in rect: CGRect) -> Path {
        let base = UnevenRoundedRectangle(
            topLeadingRadius: topLeadingRadius,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: topTrailingRadius,
            style: .continuous
        ).path(in: rect)

        guard !occludedLocalRects.isEmpty else {
            return base
        }

        var occUnion = Path()
        for occ in occludedLocalRects {
            let clipped = occ.intersection(rect)
            if !clipped.isNull && clipped.width > 0.01 && clipped.height > 0.01 {
                occUnion = occUnion.union(Path(clipped))
            }
        }
        let clippedOcc = occUnion.intersection(base)
        var combined = base
        combined.addPath(clippedOcc)
        return combined
    }
}

private final class ChromeBarHostingView<Content: View>: NSHostingView<Content> {
    var isResizeAllowed: Bool = false {
        didSet {
            if isResizeAllowed != oldValue {
                window?.invalidateCursorRects(for: self)
                if !isResizeAllowed && currentResizeEdge != nil {
                    currentResizeEdge = nil
                    NSCursor.arrow.set()
                }
            }
        }
    }
    var isTopClipped: Bool = false {
        didSet {
            if isTopClipped != oldValue {
                window?.invalidateCursorRects(for: self)
            }
        }
    }
    var isLeftClipped: Bool = false {
        didSet {
            if isLeftClipped != oldValue {
                window?.invalidateCursorRects(for: self)
            }
        }
    }
    var isRightClipped: Bool = false {
        didSet {
            if isRightClipped != oldValue {
                window?.invalidateCursorRects(for: self)
            }
        }
    }

    private var resizeTrackingArea: NSTrackingArea?
    private var currentResizeEdge: WindowChromeGeometry.ChromeBarResizeEdge?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let resizeTrackingArea {
            removeTrackingArea(resizeTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        resizeTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateResizeCursor(forWindowPoint: event.locationInWindow)
    }

    override func cursorUpdate(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if let edge = resizeEdge(atViewPoint: pt) {
            currentResizeEdge = edge
            Self.cursor(for: edge).set()
        } else {
            currentResizeEdge = nil
            super.cursorUpdate(with: event)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if currentResizeEdge != nil {
            currentResizeEdge = nil
            NSCursor.arrow.set()
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isResizeAllowed, bounds.width > 20, bounds.height > 10 else { return }

        let topH: CGFloat = 5
        let sideW: CGFloat = 5
        let corner: CGFloat = 10

        func addTopLeftRect(_ topLeftRect: CGRect, edge: WindowChromeGeometry.ChromeBarResizeEdge) {
            let y = isFlipped ? topLeftRect.minY : (bounds.height - topLeftRect.maxY)
            let viewRect = CGRect(x: topLeftRect.minX, y: y, width: topLeftRect.width, height: topLeftRect.height)
                .intersection(bounds)
            if !viewRect.isNull && viewRect.width > 0 && viewRect.height > 0 {
                addCursorRect(viewRect, cursor: Self.cursor(for: edge))
            }
        }

        if !isTopClipped && !isLeftClipped {
            addTopLeftRect(CGRect(x: 0, y: 0, width: corner, height: corner), edge: .topLeft)
        }
        if !isTopClipped && !isRightClipped {
            addTopLeftRect(CGRect(x: bounds.width - corner, y: 0, width: corner, height: corner), edge: .topRight)
        }
        if !isTopClipped {
            let startX: CGFloat = isLeftClipped ? 0 : corner
            let endX: CGFloat = isRightClipped ? bounds.width : (bounds.width - corner)
            if endX > startX {
                addTopLeftRect(CGRect(x: startX, y: 0, width: endX - startX, height: topH), edge: .top)
            }
        }
        if !isLeftClipped {
            let startY: CGFloat = isTopClipped ? 0 : corner
            if bounds.height > startY {
                addTopLeftRect(CGRect(x: 0, y: startY, width: sideW, height: bounds.height - startY), edge: .left)
            }
        }
        if !isRightClipped {
            let startY: CGFloat = isTopClipped ? 0 : corner
            if bounds.height > startY {
                addTopLeftRect(CGRect(x: bounds.width - sideW, y: startY, width: sideW, height: bounds.height - startY), edge: .right)
            }
        }
    }

    private func updateResizeCursor(forWindowPoint windowPoint: NSPoint) {
        let pt = convert(windowPoint, from: nil)
        let edge = resizeEdge(atViewPoint: pt)
        if let edge {
            currentResizeEdge = edge
            Self.cursor(for: edge).set()
        } else if currentResizeEdge != nil {
            currentResizeEdge = nil
            NSCursor.arrow.set()
        }
    }

    private func resizeEdge(atViewPoint pt: NSPoint) -> WindowChromeGeometry.ChromeBarResizeEdge? {
        guard isResizeAllowed else { return nil }
        let topLeftPt = CGPoint(x: pt.x, y: isFlipped ? pt.y : (bounds.height - pt.y))
        return WindowChromeGeometry.chromeBarResizeEdge(
            atLocalPoint: topLeftPt,
            barSize: bounds.size,
            isTopClipped: isTopClipped,
            isLeftClipped: isLeftClipped,
            isRightClipped: isRightClipped
        )
    }

    static func cursor(for edge: WindowChromeGeometry.ChromeBarResizeEdge) -> NSCursor {
        switch edge {
        case .top:
            return NSCursor.frameResize(position: .top, directions: .all)
        case .topLeft:
            return NSCursor.frameResize(position: .topLeft, directions: .all)
        case .topRight:
            return NSCursor.frameResize(position: .topRight, directions: .all)
        case .left:
            return NSCursor.frameResize(position: .left, directions: .all)
        case .right:
            return NSCursor.frameResize(position: .right, directions: .all)
        }
    }
}

private final class OccludedBarHostingView<Content: View>: NSHostingView<Content> {
    var occludedLocalRects: [CGRect] = []

    func isTopLeftPointOccluded(_ topLeftPt: CGPoint) -> Bool {
        occludedLocalRects.contains { $0.contains(topLeftPt) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        let topLeftPt = CGPoint(x: local.x, y: isFlipped ? local.y : (bounds.height - local.y))
        if isTopLeftPointOccluded(topLeftPt) {
            return nil
        }
        return super.hitTest(point)
    }
}

@MainActor
@Observable
public final class WindowChromeBarState {
    public var appName: String = ""
    public var appIcon: NSImage?
    public var windowTitle: String = ""
    public var menuItems: [MirroredMenuItem] = []
    public var isMaximized: Bool = false
    public var barHeight: CGFloat = 28
    public var cornerSkirtHeight: CGFloat = 0
    public var isLeftEdgeClipped: Bool = false
    public var isRightEdgeClipped: Bool = false
    public var isNotchDocked: Bool = false
    public var leftNotchWidth: CGFloat = 0
    public var notchWidth: CGFloat = 0
    public var rightNotchWidth: CGFloat = 0
    public var showSnapLayouts: Bool = false
    public var hoveredButton: String?
}

@MainActor
@Observable
private final class CornerSkirtState {
    var isLeftEdgeClipped: Bool = false
    var isRightEdgeClipped: Bool = false
}

@MainActor
@Observable
private final class BackgroundChromeBarState {
    var appIcon: NSImage?
    var windowTitle: String = ""
    var isMaximized: Bool = false
    var barHeight: CGFloat = 28
    var isLeftEdgeClipped: Bool = false
    var isRightEdgeClipped: Bool = false
    var isNotchDocked: Bool = false
    var leftNotchWidth: CGFloat = 0
    var notchWidth: CGFloat = 0
    var rightNotchWidth: CGFloat = 0
    var occludedLocalRects: [CGRect] = []
}

@MainActor
@Observable
private final class DragGhostState {
    var appIcon: NSImage?
    var title: String = ""
    var menuTitles: [String] = []
    var hasOverflowMenus: Bool = false
    var barHeight: CGFloat = 28
    var snapshot: NSImage?
    var snapshotOriginalSize: CGSize = .zero
    var trafficLightMaskRectLocal: CGRect?
    var trafficLightMaskColor: NSColor?
}

@MainActor
public final class WindowChromeBarController: NSObject {
    public var onInteractionStateChanged: (@MainActor (Bool) -> Void)?

    private struct CachedWindowMeta {
        let pid: pid_t
        let isStandard: Bool
        var isFullScreen: Bool
        var title: String
        var trafficLightRelOffset: CGRect?
    }

    private struct BackgroundBarEntry {
        let panel: NonActivatingFloatingPanel
        let hostingView: OccludedBarHostingView<BackgroundChromeBarView>
        let barState: BackgroundChromeBarState
        var pid: pid_t
        var windowID: CGWindowID
        var bundleID: String
        var axBarRect: CGRect
        var axWindowFrame: CGRect
        var baseOccludingRectsAX: [CGRect]
    }

    private struct ActiveBarResize {
        let window: AXWindowInfo
        let edge: WindowChromeGeometry.ChromeBarResizeEdge
        let startMouseAX: CGPoint
        let startWindowFrameAX: CGRect
        let minWindowTopAX: CGFloat
        var lastAppliedFrameAX: CGRect
        var lastApplyTimestamp: TimeInterval
    }

    private let model: RunningAppsModel
    private let snapManager: WindowSnapManager
    private let state = WindowChromeBarState()
    private let cornerSkirtState = CornerSkirtState()
    private let dragGhostState = DragGhostState()
    private var panel: NonActivatingFloatingPanel?
    private var cornerSkirtPanel: NonActivatingFloatingPanel?
    private var barHostingView: ChromeBarHostingView<WindowChromeBarView>?
    private var logicalBarFrameCocoa: CGRect = .zero
    private var snapPanel: NonActivatingFloatingPanel?
    private var dragGhostPanel: NonActivatingFloatingPanel?
    private var trafficLightMaskPanel: NonActivatingFloatingPanel?
    private var trafficLightMaskView: TrafficLightMaskNSView?
    private var backgroundMasks: [CGWindowID: (panel: NonActivatingFloatingPanel, view: TrafficLightMaskNSView, pid: pid_t)] = [:]
    private var backgroundBars: [CGWindowID: BackgroundBarEntry] = [:]
    private var cachedWindowMeta: [CGWindowID: CachedWindowMeta] = [:]
    private var cachedMaskRelativeOffsets: [CGWindowID: CGRect] = [:]
    private var noTrafficLightWindowIDs: Set<CGWindowID> = []
    private weak var dragZoneNSView: NSView?
    private weak var leftNotchDragZoneNSView: NSView?
    private var sampledMaskColors: [String: NSColor] = [:]
    private var pendingMaskColorKeys: Set<String> = []
    private var cachedDragSnapshot: (windowID: CGWindowID, image: NSImage, size: CGSize, capturedAt: TimeInterval)?
    private var snapshotCaptureInFlightWID: CGWindowID?
    private var hiddenDragAppPID: pid_t?
    private var isFinishingDragDrop = false
    private var syncTimer: Timer?
    private var fastDragSyncTimer: Timer?
    private var axObserver: AXObserver?
    private var observedPID: pid_t = 0
    private var lastMenuPID: pid_t = 0
    private var cachedMenusByPID: [pid_t: [MirroredMenuItem]] = [:]
    private var currentWindow: AXWindowInfo?
    private var currentBundleID: String = ""
    private var isDraggingTargetWindow = false
    private var activeBarResize: ActiveBarResize?
    private var isReportingInteraction = false
    private var isExternalMouseDragging = false
    private var isBlockingNativeTitlebarDrag = false
    private var dragTargetWindow: AXWindowInfo?
    private var dragStartMouseAX: CGPoint = .zero
    private var dragStartWindowFrameAX: CGRect = .zero
    private var dragWasMaximized = false
    private var dragDidCrossThreshold = false
    private var dragDidStartVisualGhost = false
    private var dragWaitingForSnapshot = false
    private var dragSnapshotTimeoutWork: DispatchWorkItem?
    private var dragGeneration: UInt64 = 0
    private var dragGhostWindowSizeAX: CGSize = .zero
    private var dragGhostCurrentWindowOriginAX: CGPoint = .zero
    private var dragGhostGrabOffsetAX: CGPoint = .zero
    private var dragMinSafeAXTop: CGFloat = 28
    private nonisolated static let syntheticEventTag: Int64 = 0x57313153

    private struct NativeDragGuard {
        let pid: pid_t
        let windowID: CGWindowID
        let element: AXUIElement?
        let startOrigin: CGPoint
    }

    private var lastAutoNormalizedFrameByWindowID: [CGWindowID: CGRect] = [:]
    private var nativeDragGuard: NativeDragGuard?
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
                guard let self else { return }
                let physicalLeftDown = CGEventSource.buttonState(.hidSystemState, button: .left)
                if self.hiddenDragAppPID != nil && !self.isFinishingDragDrop && !physicalLeftDown {
                    self.dragGhostPanel?.orderOut(nil)
                    self.isDraggingTargetWindow = false
                    self.dragDidStartVisualGhost = false
                    self.dragTargetWindow = nil
                    self.snapManager.suppressGlobalDragMonitor = false
                    self.setInteractionActive(false)
                    self.restoreHiddenDragAppIfNeeded()
                }
                if self.activeBarResize != nil && !physicalLeftDown {
                    self.activeBarResize = nil
                    self.snapManager.suppressGlobalDragMonitor = false
                    self.setInteractionActive(false)
                }
                self.syncActiveWindow()
            }
        }
    }

    private func setInteractionActive(_ active: Bool) {
        guard isReportingInteraction != active else { return }
        isReportingInteraction = active
        onInteractionStateChanged?(active)
    }

    private func setupPanel() {
        let bar = NonActivatingFloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: model.config.windowBarHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        bar.allowsNotchAreaPlacement = true
        bar.appearance = NSAppearance(named: .darkAqua)
        bar.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        bar.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        bar.backgroundColor = .clear
        bar.isOpaque = false
        bar.hasShadow = false

        let hosting = ChromeBarHostingView(rootView: WindowChromeBarView(
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
            },
            onHoverBar: { [weak self] hovering in
                if hovering {
                    self?.prewarmSnapshotForCurrentWindow(force: false)
                }
            }
        ))
        barHostingView = hosting
        bar.contentView = hosting
        panel = bar

        let skirt = NonActivatingFloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: ChromeBarAppearance.cornerSkirtHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        skirt.allowsNotchAreaPlacement = true
        skirt.appearance = NSAppearance(named: .darkAqua)
        skirt.level = bar.level
        skirt.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        skirt.backgroundColor = .clear
        skirt.isOpaque = false
        skirt.hasShadow = false
        skirt.ignoresMouseEvents = true
        skirt.contentView = NSHostingView(rootView: CornerSkirtOverlayView(state: cornerSkirtState))
        cornerSkirtPanel = skirt
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
                    self.noTrafficLightWindowIDs.remove(wid)
                    self.cachedWindowMeta.removeValue(forKey: wid)
                    AccessibilityBridge.invalidateCaptureFilter(for: wid)
                    if self.cachedDragSnapshot?.windowID == wid {
                        self.cachedDragSnapshot = nil
                    }
                }
                let staleMetaIDs = self.cachedWindowMeta.keys.filter { self.cachedWindowMeta[$0]?.pid == pid }
                for wid in staleMetaIDs {
                    self.cachedWindowMeta.removeValue(forKey: wid)
                }
                let staleBarIDs = self.backgroundBars.keys.filter { self.backgroundBars[$0]?.pid == pid }
                for wid in staleBarIDs {
                    self.backgroundBars[wid]?.panel.orderOut(nil)
                    self.backgroundBars.removeValue(forKey: wid)
                }
                let staleMaskIDs = self.backgroundMasks.keys.filter { self.backgroundMasks[$0]?.pid == pid }
                for wid in staleMaskIDs {
                    self.backgroundMasks[wid]?.panel.orderOut(nil)
                    self.backgroundMasks.removeValue(forKey: wid)
                }
                if self.hiddenDragAppPID == pid {
                    self.hiddenDragAppPID = nil
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
        if isDraggingTargetWindow || isFinishingDragDrop || activeBarResize != nil {
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
        if !isDraggingTargetWindow
            && activeBarResize == nil
            && !isExternalMouseDragging
            && !CGEventSource.buttonState(.hidSystemState, button: .left)
            && NSEvent.pressedMouseButtons == 0 {
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
        let windowCocoa = WindowChromeGeometry.axRectToCocoa(effectiveWin.axFrame, primaryScreenHeight: primaryH)
        let isMaximized = snapManager.isWindowMaximized(effectiveWin, on: effectiveScreen)
        let (_, rawSkirt) = WindowChromeGeometry.renderedBarPanelFrame(
            for: layout,
            windowCocoaFrame: windowCocoa,
            skirtHeight: ChromeBarAppearance.cornerSkirtHeight
        )
        let effectiveSkirt: CGFloat = (layout.isNotchDocked || isMaximized) ? 0 : rawSkirt
        let leftClipped = windowCocoa.minX < barRect.minX - 1.0
        let rightClipped = windowCocoa.maxX > barRect.maxX + 1.0
        logicalBarFrameCocoa = barRect

        let prevWindowID = currentWindow?.windowID ?? 0
        let pid = front.processIdentifier
        currentWindow = effectiveWin
        currentBundleID = bundleID
        if effectiveWin.windowID != 0 {
            if var existingMeta = cachedWindowMeta[effectiveWin.windowID] {
                existingMeta.title = effectiveWin.title
                existingMeta.isFullScreen = effectiveWin.isFullScreen
                cachedWindowMeta[effectiveWin.windowID] = existingMeta
            } else {
                cachedWindowMeta[effectiveWin.windowID] = CachedWindowMeta(
                    pid: pid,
                    isStandard: true,
                    isFullScreen: effectiveWin.isFullScreen,
                    title: effectiveWin.title,
                    trafficLightRelOffset: cachedMaskRelativeOffsets[effectiveWin.windowID]
                )
            }
        }
        if effectiveWin.windowID != 0 && effectiveWin.windowID != prevWindowID {
            prewarmSnapshotForCurrentWindow(force: false)
        }
        state.appName = front.localizedName ?? bundleID
        state.appIcon = AppIconCache.icon(forBundleID: bundleID, url: front.bundleURL, size: 16)
        state.windowTitle = effectiveWin.title.isEmpty ? state.appName : effectiveWin.title
        state.isMaximized = isMaximized
        state.barHeight = barRect.height
        state.cornerSkirtHeight = effectiveSkirt
        state.isLeftEdgeClipped = leftClipped
        state.isRightEdgeClipped = rightClipped
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
            barHostingView?.isResizeAllowed = !layout.isNotchDocked && !isMaximized
            barHostingView?.isTopClipped = false
            barHostingView?.isLeftClipped = leftClipped
            barHostingView?.isRightClipped = rightClipped
            updatePanelLevel(isNotchDocked: layout.isNotchDocked)
            setPanelFrameFast(panel, to: barRect)
            if !panel.isVisible {
                panel.displayIfNeeded()
                panel.orderFrontRegardless()
            }
        }

        syncCornerSkirtPanel(
            barRect: barRect,
            effectiveSkirt: effectiveSkirt,
            leftClipped: leftClipped,
            rightClipped: rightClipped
        )

        let barAXRect = WindowChromeGeometry.cocoaRectToAX(barRect, primaryScreenHeight: primaryH)
        syncTrafficLightMask(
            for: effectiveWin,
            bundleID: bundleID,
            primaryScreenHeight: primaryH,
            barAXRect: barAXRect
        )
        syncBackgroundOverlays(
            frontWindowID: effectiveWin.windowID,
            frontBarAXRect: barAXRect,
            primaryScreenHeight: primaryH
        )
    }

    private func syncCornerSkirtPanel(
        barRect: CGRect,
        effectiveSkirt: CGFloat,
        leftClipped: Bool,
        rightClipped: Bool
    ) {
        cornerSkirtState.isLeftEdgeClipped = leftClipped
        cornerSkirtState.isRightEdgeClipped = rightClipped

        guard effectiveSkirt > 0.5, let cornerSkirtPanel else {
            cornerSkirtPanel?.orderOut(nil)
            return
        }

        let skirtRect = CGRect(
            x: barRect.minX,
            y: barRect.minY - effectiveSkirt,
            width: barRect.width,
            height: effectiveSkirt
        )
        if let panel, cornerSkirtPanel.level != panel.level {
            cornerSkirtPanel.level = panel.level
        }
        setPanelFrameFast(cornerSkirtPanel, to: skirtRect)
        if !cornerSkirtPanel.isVisible {
            cornerSkirtPanel.displayIfNeeded()
            cornerSkirtPanel.orderFrontRegardless()
        }
    }

    private func hideBar() {
        currentWindow = nil
        logicalBarFrameCocoa = .zero
        panel?.orderOut(nil)
        cornerSkirtPanel?.orderOut(nil)
        snapPanel?.orderOut(nil)
        dragGhostPanel?.orderOut(nil)
        trafficLightMaskPanel?.orderOut(nil)
        if !model.config.showWindowChromeBar {
            hideAllBackgroundOverlays()
        } else {
            syncBackgroundOverlays(
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

    private func hideAllBackgroundBars() {
        for (_, entry) in backgroundBars {
            entry.panel.orderOut(nil)
        }
        backgroundBars.removeAll()
    }

    private func hideAllBackgroundOverlays() {
        hideAllBackgroundMasks()
        hideAllBackgroundBars()
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

    private func updatePanelLevel(isNotchDocked: Bool) {
        guard let panel else { return }
        let targetLevel = isNotchDocked
            ? NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
            : NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        if panel.level != targetLevel {
            panel.level = targetLevel
        }
        if let cornerSkirtPanel, cornerSkirtPanel.level != targetLevel {
            cornerSkirtPanel.level = targetLevel
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

        let barRect = layout.frameCocoa
        let windowCocoa = WindowChromeGeometry.axRectToCocoa(liveBounds, primaryScreenHeight: primaryScreenHeight)
        let isMaximized = currentWindow.map {
            let temp = AXWindowInfo(
                pid: $0.pid,
                windowID: windowID,
                title: $0.title,
                axFrame: liveBounds,
                isMinimized: $0.isMinimized,
                isFullScreen: $0.isFullScreen,
                element: $0.element
            )
            return snapManager.isWindowMaximized(temp, on: screen)
        } ?? state.isMaximized
        let (_, rawSkirt) = WindowChromeGeometry.renderedBarPanelFrame(
            for: layout,
            windowCocoaFrame: windowCocoa,
            skirtHeight: ChromeBarAppearance.cornerSkirtHeight
        )
        let effectiveSkirt: CGFloat = (layout.isNotchDocked || isMaximized) ? 0 : rawSkirt
        let leftClipped = windowCocoa.minX < barRect.minX - 1.0
        let rightClipped = windowCocoa.maxX > barRect.maxX + 1.0
        logicalBarFrameCocoa = barRect

        state.isMaximized = isMaximized
        state.barHeight = barRect.height
        state.cornerSkirtHeight = effectiveSkirt
        state.isLeftEdgeClipped = leftClipped
        state.isRightEdgeClipped = rightClipped
        state.isNotchDocked = layout.isNotchDocked
        state.leftNotchWidth = layout.leftNotchWidth
        state.notchWidth = layout.notchWidth
        state.rightNotchWidth = layout.rightNotchWidth

        if let panel {
            barHostingView?.isResizeAllowed = !layout.isNotchDocked && !isMaximized
            barHostingView?.isTopClipped = false
            barHostingView?.isLeftClipped = leftClipped
            barHostingView?.isRightClipped = rightClipped
            updatePanelLevel(isNotchDocked: layout.isNotchDocked)
            setPanelFrameFast(panel, to: barRect)
            if !panel.isVisible {
                panel.displayIfNeeded()
                panel.orderFrontRegardless()
            }
        }

        syncCornerSkirtPanel(
            barRect: barRect,
            effectiveSkirt: effectiveSkirt,
            leftClipped: leftClipped,
            rightClipped: rightClipped
        )

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
                    maskPanel.displayIfNeeded()
                    maskPanel.orderFrontRegardless()
                }
            }
        }

        if includeBackgroundMasks {
            syncBackgroundOverlays(
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

        let dynamicOccluders = [draggedWindowAXFrame, draggedBarAXRect].filter { !$0.isEmpty && !$0.isNull }
        for (wid, entry) in backgroundBars {
            let combinedOccluders = entry.baseOccludingRectsAX + dynamicOccluders
            if WindowChromeGeometry.isFullyOccluded(entry.axBarRect, occludedBy: combinedOccluders) {
                if entry.panel.isVisible {
                    entry.panel.orderOut(nil)
                }
            } else {
                let occludedLocal = WindowChromeGeometry.occludedLocalRects(in: entry.axBarRect, occludedBy: combinedOccluders)
                if entry.barState.occludedLocalRects != occludedLocal {
                    entry.barState.occludedLocalRects = occludedLocal
                    entry.hostingView.occludedLocalRects = occludedLocal
                }
                if !entry.panel.isVisible {
                    entry.panel.displayIfNeeded()
                    entry.panel.orderFrontRegardless()
                }
            }
            _ = wid
        }
    }

    private func syncOverlayPositionsFromWindowServer() {
        guard !isDraggingTargetWindow,
              activeBarResize == nil,
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

    private func syncBackgroundOverlays(
        frontWindowID: CGWindowID?,
        frontBarAXRect: CGRect?,
        primaryScreenHeight: CGFloat
    ) {
        guard model.config.showWindowChromeBar,
              AccessibilityBridge.hasAccessibilityPermission(prompt: false)
        else {
            hideAllBackgroundOverlays()
            return
        }

        let selfPID = ProcessInfo.processInfo.processIdentifier
        let snapshots = AccessibilityBridge.onScreenNormalWindows()
        var activeMaskIDs: Set<CGWindowID> = []
        var activeBarIDs: Set<CGWindowID> = []
        var occludingRectsAX: [CGRect] = []
        if let frontBarAXRect {
            occludingRectsAX.append(frontBarAXRect)
        }

        var bundleIDByPID: [pid_t: String] = [:]
        var appByPID: [pid_t: NSRunningApplication] = [:]
        var resolvedPIDsThisPass: Set<pid_t> = []

        for snap in snapshots {
            if snap.pid == selfPID {
                continue
            }
            if let frontWindowID, snap.windowID == frontWindowID {
                occludingRectsAX.append(snap.axBounds)
                continue
            }

            let app: NSRunningApplication?
            if let cachedApp = appByPID[snap.pid] {
                app = cachedApp
            } else {
                let resolved = NSRunningApplication(processIdentifier: snap.pid)
                appByPID[snap.pid] = resolved
                app = resolved
            }

            let bundleID: String
            if let cachedBID = bundleIDByPID[snap.pid] {
                bundleID = cachedBID
            } else {
                bundleID = app?.bundleIdentifier ?? ""
                bundleIDByPID[snap.pid] = bundleID
            }

            if bundleID == "com.apple.finder"
                || model.config.windowBarExcludedBundleIDs.contains(bundleID) {
                occludingRectsAX.append(snap.axBounds)
                continue
            }

            let isFileExplorer = (bundleID == model.config.fileExplorerBundleID)
            let meta = resolveBackgroundWindowMeta(
                for: snap,
                allSnapshots: snapshots,
                includeTrafficLight: !isFileExplorer,
                resolvedPIDsThisPass: &resolvedPIDsThisPass
            )

            guard let meta, meta.isStandard, !meta.isFullScreen else {
                backgroundMasks[snap.windowID]?.panel.orderOut(nil)
                backgroundMasks.removeValue(forKey: snap.windowID)
                backgroundBars[snap.windowID]?.panel.orderOut(nil)
                backgroundBars.removeValue(forKey: snap.windowID)
                occludingRectsAX.append(snap.axBounds)
                continue
            }

            // 1. Persistent background chrome bar (includes FileExplorer)
            if let screen = AccessibilityBridge.screenContaining(axFrame: snap.axBounds),
               let layout = WindowChromeGeometry.dockedBarLayout(
                forAXWindowFrame: snap.axBounds,
                primaryScreenHeight: primaryScreenHeight,
                screenFrameCocoa: screen.frame,
                visibleFrameCocoa: screen.visibleFrame,
                safeAreaTopInset: screen.safeAreaInsets.top,
                auxiliaryTopLeftWidth: screen.auxiliaryTopLeftArea?.width ?? 0,
                auxiliaryTopRightWidth: screen.auxiliaryTopRightArea?.width ?? 0,
                barHeight: CGFloat(model.config.windowBarHeight),
                taskbarHeight: CGFloat(model.config.taskbarHeight)
               ) {
                let bgBarRectCocoa = layout.frameCocoa
                let bgBarAXRect = WindowChromeGeometry.cocoaRectToAX(bgBarRectCocoa, primaryScreenHeight: primaryScreenHeight)
                let baseOccluders = occludingRectsAX
                let fullyOccluded = WindowChromeGeometry.isFullyOccluded(bgBarAXRect, occludedBy: occludingRectsAX)
                activeBarIDs.insert(snap.windowID)

                let bgAXInfo = AXWindowInfo(
                    pid: snap.pid,
                    windowID: snap.windowID,
                    title: meta.title,
                    axFrame: snap.axBounds,
                    isMinimized: false,
                    isFullScreen: meta.isFullScreen,
                    element: AXUIElementCreateApplication(snap.pid)
                )
                let bgIsMax = snapManager.isWindowMaximized(bgAXInfo, on: screen)
                let bgWindowCocoa = WindowChromeGeometry.axRectToCocoa(snap.axBounds, primaryScreenHeight: primaryScreenHeight)
                let leftClipped = bgWindowCocoa.minX < bgBarRectCocoa.minX - 1.0
                let rightClipped = bgWindowCocoa.maxX > bgBarRectCocoa.maxX + 1.0
                let displayTitle = meta.title.isEmpty ? (app?.localizedName ?? snap.ownerName) : meta.title
                let appIcon = AppIconCache.icon(forBundleID: bundleID, url: app?.bundleURL, size: 14)

                if fullyOccluded {
                    if var existing = backgroundBars[snap.windowID] {
                        existing.axBarRect = bgBarAXRect
                        existing.axWindowFrame = snap.axBounds
                        existing.baseOccludingRectsAX = baseOccluders
                        existing.panel.orderOut(nil)
                        backgroundBars[snap.windowID] = existing
                    }
                } else {
                    let occludedLocal = WindowChromeGeometry.occludedLocalRects(in: bgBarAXRect, occludedBy: occludingRectsAX)
                    var entry: BackgroundBarEntry
                    if let existing = backgroundBars[snap.windowID] {
                        entry = existing
                    } else {
                        let barState = BackgroundChromeBarState()
                        let targetPID = snap.pid
                        let targetWID = snap.windowID
                        let targetBundleID = bundleID
                        let hosting = OccludedBarHostingView(rootView: BackgroundChromeBarView(
                            state: barState,
                            onFocus: { [weak self] in
                                self?.focusBackgroundWindow(pid: targetPID, windowID: targetWID)
                            },
                            onMinimize: { [weak self] in
                                self?.minimizeBackgroundWindow(pid: targetPID, windowID: targetWID)
                            },
                            onMaximize: { [weak self] in
                                self?.toggleMaximizeBackgroundWindow(pid: targetPID, windowID: targetWID, bundleID: targetBundleID)
                            },
                            onClose: { [weak self] in
                                self?.closeBackgroundWindow(pid: targetPID, windowID: targetWID, bundleID: targetBundleID)
                            }
                        ))
                        let p = NonActivatingFloatingPanel(
                            contentRect: bgBarRectCocoa,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false
                        )
                        p.allowsNotchAreaPlacement = true
                        p.appearance = NSAppearance(named: .darkAqua)
                        p.level = layout.isNotchDocked
                            ? NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
                            : .floating
                        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
                        p.backgroundColor = .clear
                        p.isOpaque = false
                        p.hasShadow = false
                        p.contentView = hosting

                        entry = BackgroundBarEntry(
                            panel: p,
                            hostingView: hosting,
                            barState: barState,
                            pid: snap.pid,
                            windowID: snap.windowID,
                            bundleID: bundleID,
                            axBarRect: bgBarAXRect,
                            axWindowFrame: snap.axBounds,
                            baseOccludingRectsAX: baseOccluders
                        )
                    }

                    entry.pid = snap.pid
                    entry.bundleID = bundleID
                    entry.axBarRect = bgBarAXRect
                    entry.axWindowFrame = snap.axBounds
                    entry.baseOccludingRectsAX = baseOccluders
                    entry.barState.appIcon = appIcon
                    entry.barState.windowTitle = displayTitle
                    entry.barState.isMaximized = bgIsMax
                    entry.barState.barHeight = bgBarRectCocoa.height
                    entry.barState.isLeftEdgeClipped = leftClipped
                    entry.barState.isRightEdgeClipped = rightClipped
                    entry.barState.isNotchDocked = layout.isNotchDocked
                    entry.barState.leftNotchWidth = layout.leftNotchWidth
                    entry.barState.notchWidth = layout.notchWidth
                    entry.barState.rightNotchWidth = layout.rightNotchWidth
                    if entry.barState.occludedLocalRects != occludedLocal {
                        entry.barState.occludedLocalRects = occludedLocal
                    }
                    entry.hostingView.occludedLocalRects = occludedLocal

                    let targetLevel: NSWindow.Level = layout.isNotchDocked
                        ? NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
                        : .floating
                    if entry.panel.level != targetLevel {
                        entry.panel.level = targetLevel
                    }
                    setPanelFrameFast(entry.panel, to: bgBarRectCocoa)
                    if !entry.panel.isVisible {
                        entry.panel.displayIfNeeded()
                        entry.panel.orderFrontRegardless()
                    }
                    backgroundBars[snap.windowID] = entry
                    occludingRectsAX.append(bgBarAXRect)
                }
            }

            // 2. Background traffic-light mask (skip FileExplorer)
            if !isFileExplorer, let relOffset = meta.trafficLightRelOffset {
                activeMaskIDs.insert(snap.windowID)
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
                        v.onSimpleClick = { [weak self] in
                            self?.focusBackgroundWindow(pid: targetPID, windowID: targetWID)
                        }
                        p.contentView = v
                        entry = (p, v, snap.pid)
                        backgroundMasks[snap.windowID] = entry
                    }

                    let colorKey = "\(snap.pid)-\(snap.windowID)"
                    entry.view.fillColor = sampledMaskColors[colorKey] ?? defaultMaskFallbackColor()
                    setPanelFrameFast(entry.panel, to: cocoaRect)
                    if !entry.panel.isVisible {
                        entry.panel.displayIfNeeded()
                        entry.panel.orderFrontRegardless()
                    }
                }
            }

            occludingRectsAX.append(snap.axBounds)
        }

        let staleMaskIDs = backgroundMasks.keys.filter { !activeMaskIDs.contains($0) }
        for wid in staleMaskIDs {
            backgroundMasks[wid]?.panel.orderOut(nil)
            backgroundMasks.removeValue(forKey: wid)
        }
        let staleBarIDs = backgroundBars.keys.filter { !activeBarIDs.contains($0) }
        for wid in staleBarIDs {
            backgroundBars[wid]?.panel.orderOut(nil)
            backgroundBars.removeValue(forKey: wid)
        }

        let visibleSnapshotIDs = Set(snapshots.map(\.windowID))
        noTrafficLightWindowIDs = noTrafficLightWindowIDs.intersection(visibleSnapshotIDs)
        for wid in Array(cachedWindowMeta.keys) where !visibleSnapshotIDs.contains(wid) {
            cachedWindowMeta.removeValue(forKey: wid)
            cachedMaskRelativeOffsets.removeValue(forKey: wid)
        }
    }

    private func resolveBackgroundWindowMeta(
        for snap: OnScreenWindowSnapshot,
        allSnapshots: [OnScreenWindowSnapshot],
        includeTrafficLight: Bool,
        resolvedPIDsThisPass: inout Set<pid_t>
    ) -> CachedWindowMeta? {
        if let cached = cachedWindowMeta[snap.windowID] {
            return cached
        }
        guard !resolvedPIDsThisPass.contains(snap.pid) else {
            return nil
        }
        resolvedPIDsThisPass.insert(snap.pid)

        let standardWins = AccessibilityBridge.standardWindows(for: snap.pid)
        var foundIDs: Set<CGWindowID> = []
        for axWin in standardWins {
            foundIDs.insert(axWin.windowID)
            var rel: CGRect? = cachedMaskRelativeOffsets[axWin.windowID]
            if includeTrafficLight && rel == nil && !noTrafficLightWindowIDs.contains(axWin.windowID) {
                if let unionAX = AccessibilityBridge.trafficLightUnionAXRect(for: axWin.element) {
                    let computed = CGRect(
                        x: unionAX.minX - axWin.axFrame.minX,
                        y: unionAX.minY - axWin.axFrame.minY,
                        width: unionAX.width,
                        height: unionAX.height
                    )
                    cachedMaskRelativeOffsets[axWin.windowID] = computed
                    rel = computed
                } else {
                    noTrafficLightWindowIDs.insert(axWin.windowID)
                }
            }
            cachedWindowMeta[axWin.windowID] = CachedWindowMeta(
                pid: snap.pid,
                isStandard: true,
                isFullScreen: axWin.isFullScreen,
                title: axWin.title,
                trafficLightRelOffset: rel
            )
        }

        if !standardWins.isEmpty {
            for s in allSnapshots where s.pid == snap.pid && !foundIDs.contains(s.windowID) {
                cachedWindowMeta[s.windowID] = CachedWindowMeta(
                    pid: snap.pid,
                    isStandard: false,
                    isFullScreen: false,
                    title: "",
                    trafficLightRelOffset: nil
                )
                noTrafficLightWindowIDs.insert(s.windowID)
            }
        }

        return cachedWindowMeta[snap.windowID]
    }

    private func resolveRelativeMaskOffset(for snap: OnScreenWindowSnapshot) -> CGRect? {
        if let cached = cachedMaskRelativeOffsets[snap.windowID] {
            return cached
        }
        if noTrafficLightWindowIDs.contains(snap.windowID) {
            return nil
        }
        let standardWins = AccessibilityBridge.standardWindows(for: snap.pid)
        if let axWin = standardWins.first(where: { $0.windowID == snap.windowID }) {
            if let unionAX = AccessibilityBridge.trafficLightUnionAXRect(for: axWin.element) {
                let rel = CGRect(
                    x: unionAX.minX - axWin.axFrame.minX,
                    y: unionAX.minY - axWin.axFrame.minY,
                    width: unionAX.width,
                    height: unionAX.height
                )
                cachedMaskRelativeOffsets[snap.windowID] = rel
                return rel
            }
            noTrafficLightWindowIDs.insert(snap.windowID)
            return nil
        }
        if !standardWins.isEmpty {
            noTrafficLightWindowIDs.insert(snap.windowID)
        }
        return nil
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
                maskPanel.displayIfNeeded()
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
        dragSnapshotTimeoutWork?.cancel()
        dragSnapshotTimeoutWork = nil
        dragGhostPanel?.orderOut(nil)
        cornerSkirtPanel?.orderOut(nil)
        restoreHiddenDragAppIfNeeded()
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
        activeBarResize = nil
        setInteractionActive(false)
        isExternalMouseDragging = false
        isBlockingNativeTitlebarDrag = false
        nativeDragGuard = nil
        isFinishingDragDrop = false
        dragDidCrossThreshold = false
        dragDidStartVisualGhost = false
        dragWaitingForSnapshot = false
        snapManager.suppressGlobalDragMonitor = false
        hideAllBackgroundOverlays()
    }

    private func prewarmSnapshotForCurrentWindow(force: Bool, maxAge: TimeInterval = 0.6) {
        guard !isFinishingDragDrop,
              let win = isDraggingTargetWindow ? dragTargetWindow : currentWindow,
              win.windowID != 0
        else {
            return
        }

        let wid = win.windowID
        let frame = AccessibilityBridge.liveWindowBounds(windowID: wid) ?? win.axFrame
        let now = ProcessInfo.processInfo.systemUptime

        if !force,
           let cached = cachedDragSnapshot,
           cached.windowID == wid,
           abs(cached.size.width - frame.width) < 4,
           abs(cached.size.height - frame.height) < 4,
           (now - cached.capturedAt) < maxAge {
            return
        }

        if snapshotCaptureInFlightWID == wid {
            return
        }
        snapshotCaptureInFlightWID = wid

        Task { @MainActor [weak self] in
            let image = await AccessibilityBridge.captureWindowSnapshot(windowID: wid, windowAXFrame: frame)
            guard let self else { return }
            if self.snapshotCaptureInFlightWID == wid {
                self.snapshotCaptureInFlightWID = nil
            }
            if let image {
                self.cachedDragSnapshot = (wid, image, frame.size, ProcessInfo.processInfo.systemUptime)
            }

            if self.isDraggingTargetWindow,
               let activeWin = self.dragTargetWindow,
               activeWin.windowID == wid {
                if let image {
                    self.dragGhostState.snapshot = image
                    self.dragGhostState.snapshotOriginalSize = frame.size
                }
                if self.dragWaitingForSnapshot && !self.dragDidStartVisualGhost {
                    self.dragWaitingForSnapshot = false
                    self.dragSnapshotTimeoutWork?.cancel()
                    self.dragSnapshotTimeoutWork = nil
                    self.startVisualGhostDrag(for: activeWin)
                }
            }
        }
    }

    private func hideRealWindowForActiveDrag(pid: pid_t, windowID: CGWindowID) {
        guard hiddenDragAppPID == nil,
              pid != ProcessInfo.processInfo.processIdentifier
        else {
            return
        }

        panel?.orderOut(nil)
        cornerSkirtPanel?.orderOut(nil)
        trafficLightMaskPanel?.orderOut(nil)
        var didHide = false
        if let targetApp = NSRunningApplication(processIdentifier: pid) {
            let appHidden = targetApp.hide()
            if targetApp.isHidden || appHidden {
                didHide = true
            }
        }
        if !didHide {
            let appEl = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appEl, 0.08)
            if AXUIElementSetAttributeValue(appEl, kAXHiddenAttribute as CFString, kCFBooleanTrue) == .success {
                didHide = true
            }
        }
        if didHide {
            hiddenDragAppPID = pid
        }

        let barH = CGFloat(model.config.windowBarHeight)
        let ghostWindowAX = CGRect(origin: dragGhostCurrentWindowOriginAX, size: dragGhostWindowSizeAX)
        let ghostBarAX = CGRect(
            x: dragGhostCurrentWindowOriginAX.x,
            y: dragGhostCurrentWindowOriginAX.y - barH,
            width: dragGhostWindowSizeAX.width,
            height: barH
        )
        updateBackgroundMaskOcclusionInMemory(draggedWindowAXFrame: ghostWindowAX, draggedBarAXRect: ghostBarAX)
    }

    private func restoreHiddenDragAppIfNeeded() {
        guard let pid = hiddenDragAppPID else { return }
        hiddenDragAppPID = nil
        NSRunningApplication(processIdentifier: pid)?.unhide()
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.08)
        AXUIElementSetAttributeValue(appEl, kAXHiddenAttribute as CFString, kCFBooleanFalse)
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

        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventTag {
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
        let f = logicalBarFrameCocoa.width > 0 ? logicalBarFrameCocoa : panel.frame
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
        p.appearance = NSAppearance(named: .darkAqua)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3)
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
        if let win = AccessibilityBridge.standardWindows(for: pid).first(where: { $0.windowID == windowID }) {
            AccessibilityBridge.focusWindow(win)
        } else if let targetApp = NSRunningApplication(processIdentifier: pid) {
            targetApp.unhide()
            targetApp.activate(options: [.activateAllWindows])
        }
        syncActiveWindow()
    }

    private func minimizeBackgroundWindow(pid: pid_t, windowID: CGWindowID) {
        if let win = AccessibilityBridge.standardWindows(for: pid).first(where: { $0.windowID == windowID }) {
            AccessibilityBridge.setMinimized(win.element, minimized: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.syncActiveWindow()
        }
    }

    private func toggleMaximizeBackgroundWindow(pid: pid_t, windowID: CGWindowID, bundleID: String) {
        guard let win = AccessibilityBridge.standardWindows(for: pid).first(where: { $0.windowID == windowID }) else {
            return
        }
        AccessibilityBridge.focusWindow(win)
        snapManager.toggleMaximize(window: win, bundleID: bundleID)
        AccessibilityBridge.focusWindow(win)
        syncActiveWindow()
    }

    private func closeBackgroundWindow(pid: pid_t, windowID: CGWindowID, bundleID: String) {
        let windows = AccessibilityBridge.standardWindows(for: pid)
        guard let win = windows.first(where: { $0.windowID == windowID }) else { return }
        let action = WindowClosePolicy.decide(
            bundleID: bundleID,
            standardWindowCount: max(1, windows.count),
            keepAliveBundleIDs: Set(model.config.keepAliveBundleIDs)
        )

        if !AccessibilityBridge.pressCloseButton(win.element) {
            AccessibilityBridge.focusWindow(win)
            let src = CGEventSource(stateID: .hidSystemState)
            if let down = CGEvent(keyboardEventSource: src, virtualKey: 13, keyDown: true),
               let up = CGEvent(keyboardEventSource: src, virtualKey: 13, keyDown: false) {
                down.flags = .maskCommand
                up.flags = .maskCommand
                down.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventTag)
                up.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventTag)
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
        }

        if let app = NSRunningApplication(processIdentifier: pid) {
            switch action {
            case .closeWindow:
                break
            case .hideApp:
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    app.hide()
                }
            case .quitApp:
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    app.terminate()
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.syncActiveWindow()
        }
    }

    private func handleTapMouseDown(locationAX: CGPoint, clickCount: Int64) -> Bool {
        isBlockingNativeTitlebarDrag = false
        nativeDragGuard = nil

        let primaryH = AccessibilityBridge.primaryScreenHeight()
        let cocoaPt = NSPoint(x: locationAX.x, y: primaryH - locationAX.y)

        // 1. Clicks inside our chrome bar (logical bar frame, 0pt overlap with app content)
        let activeBarHitRect = logicalBarFrameCocoa.width > 0 ? logicalBarFrameCocoa : (panel?.frame ?? .zero)
        if let panel, panel.isVisible, activeBarHitRect.contains(cocoaPt) {
            // Check outer resize borders & corners first for floating bars
            if !state.isNotchDocked,
               !state.isMaximized,
               let win = currentWindow {
                let localTopLeft = CGPoint(
                    x: cocoaPt.x - activeBarHitRect.minX,
                    y: activeBarHitRect.maxY - cocoaPt.y
                )
                if let edge = WindowChromeGeometry.chromeBarResizeEdge(
                    atLocalPoint: localTopLeft,
                    barSize: activeBarHitRect.size,
                    isTopClipped: false,
                    isLeftClipped: state.isLeftEdgeClipped,
                    isRightClipped: state.isRightEdgeClipped
                ) {
                    let fastFrame = AccessibilityBridge.liveWindowBounds(windowID: win.windowID) ?? win.axFrame
                    let screen = AccessibilityBridge.screenContaining(axFrame: fastFrame)
                        ?? NSScreen.main
                        ?? NSScreen.screens.first
                    let barH = CGFloat(model.config.windowBarHeight)
                    let screenTopAX = screen.map { primaryH - min($0.visibleFrame.maxY, $0.frame.maxY) } ?? 0
                    let topSafeReserve = (screen?.safeAreaInsets.top ?? 0) >= barH ? 0 : barH
                    let minWindowTopAX = screenTopAX + topSafeReserve

                    activeBarResize = ActiveBarResize(
                        window: AXWindowInfo(
                            pid: win.pid,
                            windowID: win.windowID,
                            title: win.title,
                            axFrame: fastFrame,
                            isMinimized: win.isMinimized,
                            isFullScreen: win.isFullScreen,
                            element: win.element
                        ),
                        edge: edge,
                        startMouseAX: locationAX,
                        startWindowFrameAX: fastFrame,
                        minWindowTopAX: minWindowTopAX,
                        lastAppliedFrameAX: fastFrame,
                        lastApplyTimestamp: 0
                    )
                    ChromeBarHostingView<WindowChromeBarView>.cursor(for: edge).set()
                    snapManager.suppressGlobalDragMonitor = true
                    snapPanel?.orderOut(nil)
                    setInteractionActive(true)
                    return true
                }
            }

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
                dragWasMaximized = screen.map { snapManager.shouldRestoreSizeOnDrag(dragTargetWindow!, on: $0) } ?? false
                dragDidCrossThreshold = false
                dragDidStartVisualGhost = false
                dragWaitingForSnapshot = false
                dragSnapshotTimeoutWork?.cancel()
                dragSnapshotTimeoutWork = nil
                dragGeneration &+= 1
                dragGhostWindowSizeAX = fastFrame.size
                dragGhostCurrentWindowOriginAX = fastFrame.origin
                dragGhostGrabOffsetAX = CGPoint(
                    x: locationAX.x - fastFrame.minX,
                    y: locationAX.y - fastFrame.minY
                )
                dragMinSafeAXTop = screenTopAX + topSafeReserve
                isDraggingTargetWindow = true
                setInteractionActive(true)
                snapManager.suppressGlobalDragMonitor = true
                snapPanel?.orderOut(nil)
                prewarmSnapshotForCurrentWindow(force: false, maxAge: 0.25)
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
                && locationAX.y > f.minY + 62
                && locationAX.y < f.maxY - 10 {
                return false
            }
        }

        let hittingShellWindow = NSApp.windows.contains { win in
            win !== panel
                && win !== cornerSkirtPanel
                && win !== trafficLightMaskPanel
                && !backgroundMasks.values.contains(where: { $0.panel === win })
                && win.isVisible
                && !win.ignoresMouseEvents
                && win.frame.contains(cocoaPt)
                && (win.contentView?.hitTest(win.convertPoint(fromScreen: cocoaPt)) != nil)
        }

        // 5. Arm NativeDragGuard in native OS titlebar band WITHOUT swallowing leftMouseDown (preserves all tabs/buttons/controls).
        if !hittingShellWindow
            && model.config.showWindowChromeBar
            && AccessibilityBridge.hasAccessibilityPermission(prompt: false) {
            let selfPID = ProcessInfo.processInfo.processIdentifier
            if let snap = AccessibilityBridge.onScreenNormalWindows().first(where: {
                $0.pid != selfPID && $0.axBounds.contains(locationAX)
            }) {
                let bundleID = NSRunningApplication(processIdentifier: snap.pid)?.bundleIdentifier ?? ""
                let excluded = bundleID == "com.apple.finder"
                    || model.config.windowBarExcludedBundleIDs.contains(bundleID)
                let isFullscreen: Bool
                if let screen = AccessibilityBridge.screenContaining(axFrame: snap.axBounds) {
                    isFullscreen = abs(snap.axBounds.width - screen.frame.width) < 4
                        && abs(snap.axBounds.height - screen.frame.height) < 4
                } else {
                    isFullscreen = false
                }

                if !excluded && !isFullscreen {
                    let trafficLightRel = (snap.windowID == currentWindow?.windowID)
                        ? cachedMaskRelativeOffsets[snap.windowID]
                        : (cachedWindowMeta[snap.windowID]?.trafficLightRelOffset ?? resolveRelativeMaskOffset(for: snap))

                    if let trafficLightRel {
                        let estimatedH = WindowChromeGeometry.estimatedNativeTitlebarHeight(
                            trafficLightRelativeRect: trafficLightRel
                        )
                        let titlebarH = snap.axBounds.height >= 160
                            ? min(max(52, estimatedH), snap.axBounds.height * 0.35)
                            : estimatedH
                        if WindowChromeGeometry.isInNativeTitlebarBand(
                            axPoint: locationAX,
                            windowAXFrame: snap.axBounds,
                            titlebarHeight: titlebarH,
                            resizeBorder: 4
                        ) {
                            let targetElement = (snap.windowID == currentWindow?.windowID) ? currentWindow?.element : nil
                            nativeDragGuard = NativeDragGuard(
                                pid: snap.pid,
                                windowID: snap.windowID,
                                element: targetElement,
                                startOrigin: snap.axBounds.origin
                            )
                            return false
                        }
                    }
                }
            }
        }

        // 6. Start external drag sync only when resizing near focused window edges.
        if let win = currentWindow {
            let f = win.axFrame
            let nearEdge = abs(locationAX.x - f.minX) <= 10
                || abs(locationAX.x - f.maxX) <= 10
                || abs(locationAX.y - f.minY) <= 10
                || abs(locationAX.y - f.maxY) <= 10
            if nearEdge {
                isExternalMouseDragging = true
                startFastDragSyncTimer()
            }
        }
        return false
    }

    private func startVisualGhostDrag(for win: AXWindowInfo) {
        guard isDraggingTargetWindow, !dragDidStartVisualGhost else { return }
        dragDidStartVisualGhost = true
        dragWaitingForSnapshot = false
        dragSnapshotTimeoutWork?.cancel()
        dragSnapshotTimeoutWork = nil

        let barH = CGFloat(model.config.windowBarHeight)
        let primaryH = AccessibilityBridge.primaryScreenHeight()
        let ghostAXRect = CGRect(
            x: dragGhostCurrentWindowOriginAX.x,
            y: dragGhostCurrentWindowOriginAX.y - barH,
            width: dragGhostWindowSizeAX.width,
            height: dragGhostWindowSizeAX.height + barH
        )
        let ghostCocoaRect = WindowChromeGeometry.axRectToCocoa(ghostAXRect, primaryScreenHeight: primaryH)
        let ghostPanel = ensureDragGhostPanel()
        ghostPanel.setFrame(ghostCocoaRect, display: true)
        ghostPanel.contentView?.layoutSubtreeIfNeeded()
        ghostPanel.displayIfNeeded()
        ghostPanel.orderFrontRegardless()

        let pid = win.pid
        let wid = win.windowID
        let generation = dragGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            guard let self,
                  self.isDraggingTargetWindow,
                  self.dragDidStartVisualGhost,
                  self.dragGeneration == generation,
                  self.dragTargetWindow?.windowID == wid
            else { return }
            self.panel?.orderOut(nil)
            self.cornerSkirtPanel?.orderOut(nil)
            self.trafficLightMaskPanel?.orderOut(nil)
            self.hideRealWindowForActiveDrag(pid: pid, windowID: wid)
        }
    }

    private func handleTapMouseDragged(locationAX: CGPoint) -> Bool {
        if isBlockingNativeTitlebarDrag {
            return true
        }
        if let guardInfo = nativeDragGuard {
            if let live = AccessibilityBridge.liveWindowBounds(windowID: guardInfo.windowID),
               hypot(live.origin.x - guardInfo.startOrigin.x, live.origin.y - guardInfo.startOrigin.y) >= 1.0 {
                isBlockingNativeTitlebarDrag = true
                nativeDragGuard = nil

                let axEl = guardInfo.element ?? AccessibilityBridge.standardWindows(for: guardInfo.pid).first(where: { $0.windowID == guardInfo.windowID })?.element
                if let axEl {
                    AccessibilityBridge.setPosition(axEl, origin: guardInfo.startOrigin)
                }

                if let cancelUp = CGEvent(
                    mouseEventSource: nil,
                    mouseType: .leftMouseUp,
                    mouseCursorPosition: locationAX,
                    mouseButton: .left
                ) {
                    cancelUp.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventTag)
                    cancelUp.post(tap: .cgSessionEventTap)
                }

                let startOrigin = guardInfo.startOrigin
                let targetWID = guardInfo.windowID
                let targetPID = guardInfo.pid
                for delay in [0.015, 0.050] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        if let currentBounds = AccessibilityBridge.liveWindowBounds(windowID: targetWID),
                           hypot(currentBounds.origin.x - startOrigin.x, currentBounds.origin.y - startOrigin.y) >= 1.0 {
                            let el = axEl ?? AccessibilityBridge.standardWindows(for: targetPID).first(where: { $0.windowID == targetWID })?.element
                            if let el {
                                AccessibilityBridge.setPosition(el, origin: startOrigin)
                            }
                        }
                        self?.syncActiveWindow()
                    }
                }
                return true
            }
            return false
        }

        if var resize = activeBarResize {
            let deltaAX = CGSize(
                width: locationAX.x - resize.startMouseAX.x,
                height: locationAX.y - resize.startMouseAX.y
            )
            let targetFrame = WindowChromeGeometry.resizedWindowAXFrame(
                startWindowAXFrame: resize.startWindowFrameAX,
                edge: resize.edge,
                deltaAX: deltaAX,
                minWindowTopAX: resize.minWindowTopAX
            )
            let diff = max(
                abs(targetFrame.minX - resize.lastAppliedFrameAX.minX),
                abs(targetFrame.minY - resize.lastAppliedFrameAX.minY),
                abs(targetFrame.width - resize.lastAppliedFrameAX.width),
                abs(targetFrame.height - resize.lastAppliedFrameAX.height)
            )
            let now = ProcessInfo.processInfo.systemUptime
            if diff >= 1.0 && (now - resize.lastApplyTimestamp) >= (1.0 / 60.0) {
                AccessibilityBridge.setFrame(resize.window.element, axFrame: targetFrame)
                resize.lastAppliedFrameAX = targetFrame
                resize.lastApplyTimestamp = now
                activeBarResize = resize

                let liveBounds = AccessibilityBridge.liveWindowBounds(windowID: resize.window.windowID) ?? targetFrame
                let primaryH = AccessibilityBridge.primaryScreenHeight()
                if let barAXRect = applyOverlayFramesFast(
                    forLiveBounds: liveBounds,
                    windowID: resize.window.windowID,
                    primaryScreenHeight: primaryH,
                    includeBackgroundMasks: false
                ) {
                    updateBackgroundMaskOcclusionInMemory(draggedWindowAXFrame: liveBounds, draggedBarAXRect: barAXRect)
                }
            }
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

            if !dragDidCrossThreshold {
                dragDidCrossThreshold = true
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

                dragGhostState.appIcon = state.appIcon
                dragGhostState.title = state.windowTitle
                dragGhostState.menuTitles = Array(state.menuItems.prefix(7).map(\.title))
                dragGhostState.hasOverflowMenus = state.menuItems.count > 7
                dragGhostState.barHeight = barH

                if currentBundleID != model.config.fileExplorerBundleID {
                    dragGhostState.trafficLightMaskRectLocal = cachedMaskRelativeOffsets[win.windowID]
                    dragGhostState.trafficLightMaskColor = sampledMaskColors["\(win.pid)-\(win.windowID)"]
                        ?? defaultMaskFallbackColor()
                } else {
                    dragGhostState.trafficLightMaskRectLocal = nil
                    dragGhostState.trafficLightMaskColor = nil
                }
            }

            let targetWinX = (locationAX.x - dragGhostGrabOffsetAX.x).rounded()
            let targetWinY = max(dragMinSafeAXTop, (locationAX.y - dragGhostGrabOffsetAX.y).rounded())
            dragGhostCurrentWindowOriginAX = CGPoint(x: targetWinX, y: targetWinY)

            if let cached = cachedDragSnapshot,
               cached.windowID == win.windowID,
               abs(cached.size.width - dragStartWindowFrameAX.width) < 4,
               abs(cached.size.height - dragStartWindowFrameAX.height) < 4 {
                dragGhostState.snapshot = cached.image
                dragGhostState.snapshotOriginalSize = cached.size
                startVisualGhostDrag(for: win)
            } else {
                if !dragWaitingForSnapshot {
                    dragWaitingForSnapshot = true
                    dragGhostState.snapshot = nil
                    dragGhostState.snapshotOriginalSize = dragStartWindowFrameAX.size
                    prewarmSnapshotForCurrentWindow(force: true)

                    dragSnapshotTimeoutWork?.cancel()
                    let wid = win.windowID
                    let generation = dragGeneration
                    let work = DispatchWorkItem { [weak self] in
                        guard let self,
                              self.isDraggingTargetWindow,
                              self.dragWaitingForSnapshot,
                              !self.dragDidStartVisualGhost,
                              self.dragGeneration == generation,
                              self.dragTargetWindow?.windowID == wid
                        else { return }
                        self.dragWaitingForSnapshot = false
                        self.dragSnapshotTimeoutWork = nil
                        self.startVisualGhostDrag(for: win)
                    }
                    dragSnapshotTimeoutWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.060, execute: work)
                }

                let primaryH = AccessibilityBridge.primaryScreenHeight()
                let cocoaMouse = NSPoint(x: locationAX.x, y: primaryH - locationAX.y)
                snapManager.updateDragPreview(mouseLocationCocoa: cocoaMouse)
                return true
            }
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
        updateBackgroundMaskOcclusionInMemory(
            draggedWindowAXFrame: CGRect(x: targetWinX, y: targetWinY, width: dragGhostWindowSizeAX.width, height: dragGhostWindowSizeAX.height),
            draggedBarAXRect: CGRect(x: targetWinX, y: targetWinY - barH, width: dragGhostWindowSizeAX.width, height: barH)
        )

        let cocoaMouse = NSPoint(x: locationAX.x, y: primaryH - locationAX.y)
        snapManager.updateDragPreview(mouseLocationCocoa: cocoaMouse)
        return true
    }

    private func handleTapMouseUp() -> Bool {
        nativeDragGuard = nil
        if isBlockingNativeTitlebarDrag {
            isBlockingNativeTitlebarDrag = false
            return true
        }

        if let resize = activeBarResize {
            activeBarResize = nil
            snapManager.suppressGlobalDragMonitor = false
            NSCursor.arrow.set()

            let primaryH = AccessibilityBridge.primaryScreenHeight()
            let mouseCocoa = NSEvent.mouseLocation
            let locationAX = CGPoint(x: mouseCocoa.x, y: primaryH - mouseCocoa.y)
            let deltaAX = CGSize(
                width: locationAX.x - resize.startMouseAX.x,
                height: locationAX.y - resize.startMouseAX.y
            )
            let finalFrame = WindowChromeGeometry.resizedWindowAXFrame(
                startWindowAXFrame: resize.startWindowFrameAX,
                edge: resize.edge,
                deltaAX: deltaAX,
                minWindowTopAX: resize.minWindowTopAX
            )
            AccessibilityBridge.setFrame(resize.window.element, axFrame: finalFrame)
            let liveBounds = AccessibilityBridge.liveWindowBounds(windowID: resize.window.windowID) ?? finalFrame
            _ = applyOverlayFramesFast(
                forLiveBounds: liveBounds,
                windowID: resize.window.windowID,
                primaryScreenHeight: primaryH,
                includeBackgroundMasks: false
            )
            setInteractionActive(false)
            DispatchQueue.main.async { [weak self] in
                self?.syncActiveWindow()
            }
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

        dragSnapshotTimeoutWork?.cancel()
        dragSnapshotTimeoutWork = nil
        dragWaitingForSnapshot = false
        dragDidCrossThreshold = false

        let win = dragTargetWindow ?? currentWindow
        let bid = currentBundleID.isEmpty ? nil : currentBundleID
        let didMove = dragDidStartVisualGhost
        let wasMax = dragWasMaximized
        let finalAXFrame = CGRect(origin: dragGhostCurrentWindowOriginAX, size: dragGhostWindowSizeAX)
        let hiddenPID = hiddenDragAppPID
        let dropGeneration = dragGeneration

        dragDidStartVisualGhost = false
        dragTargetWindow = nil
        snapManager.suppressGlobalDragMonitor = false

        if !didMove {
            dragGhostPanel?.orderOut(nil)
            isDraggingTargetWindow = false
            setInteractionActive(false)
            restoreHiddenDragAppIfNeeded()
            DispatchQueue.main.async { [weak self] in
                self?.syncActiveWindow()
            }
            return true
        }

        cachedDragSnapshot = nil
        isFinishingDragDrop = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // Capture snap target BEFORE commitDragSnapIfActive clears preview state.
            let snappedZone = self.snapManager.currentPreviewZone
            let snappedScreen = self.snapManager.currentPreviewScreen
            let desiredFinalAXFrame: CGRect
            if let snappedZone,
               let targetScreen = snappedScreen
                ?? AccessibilityBridge.screenContaining(axFrame: finalAXFrame)
                ?? NSScreen.main
                ?? NSScreen.screens.first {
                desiredFinalAXFrame = self.snapManager.targetAXFrame(for: snappedZone, on: targetScreen)
            } else {
                desiredFinalAXFrame = finalAXFrame
            }

            // Unhide & bring frontmost FIRST while dragGhostPanel stays on top so Chromium/macOS windows accept AX resize + move reliably.
            let targetPID = hiddenPID ?? win?.pid
            if let targetPID {
                if self.hiddenDragAppPID == targetPID {
                    self.hiddenDragAppPID = nil
                }
                let appEl = AXUIElementCreateApplication(targetPID)
                AXUIElementSetMessagingTimeout(appEl, 0.12)
                AXUIElementSetAttributeValue(appEl, kAXHiddenAttribute as CFString, kCFBooleanFalse)
                AXUIElementSetAttributeValue(appEl, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                if let app = NSRunningApplication(processIdentifier: targetPID) {
                    app.unhide()
                    app.activate(options: [.activateAllWindows])
                }
            }

            let didSnap = self.snapManager.commitDragSnapIfActive(window: win, bundleID: bid)
            if !didSnap, let win {
                if wasMax {
                    self.snapManager.clearSavedRestoreFrame(for: win, bundleID: bid ?? "")
                    AccessibilityBridge.setFrame(win.element, axFrame: desiredFinalAXFrame)
                } else {
                    AccessibilityBridge.setPosition(win.element, origin: desiredFinalAXFrame.origin)
                }
            }

            var didHideGhost = false
            let finishDrop: () -> Void = { [weak self] in
                guard let self, self.dragGeneration == dropGeneration, !didHideGhost else { return }
                didHideGhost = true
                self.dragGhostPanel?.orderOut(nil)
                self.isDraggingTargetWindow = false
                self.isFinishingDragDrop = false
                self.setInteractionActive(false)
                self.syncActiveWindow()
                self.panel?.displayIfNeeded()
                self.cornerSkirtPanel?.displayIfNeeded()
                self.trafficLightMaskPanel?.displayIfNeeded()
            }

            if let win {
                AccessibilityBridge.focusWindow(win)

                let reapplyIfNeeded: () -> Bool = {
                    let app = NSRunningApplication(processIdentifier: win.pid)
                    let liveBounds = AccessibilityBridge.liveWindowBounds(windowID: win.windowID)
                    if app?.isHidden == true || liveBounds == nil {
                        let appEl = AXUIElementCreateApplication(win.pid)
                        AXUIElementSetMessagingTimeout(appEl, 0.12)
                        AXUIElementSetAttributeValue(appEl, kAXHiddenAttribute as CFString, kCFBooleanFalse)
                        AXUIElementSetAttributeValue(appEl, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                        app?.unhide()
                        app?.activate(options: [.activateAllWindows])
                        AccessibilityBridge.setFrame(win.element, axFrame: desiredFinalAXFrame)
                        AccessibilityBridge.focusWindow(win)
                        return false
                    }

                    guard let liveBounds else { return false }
                    let originDiff = hypot(liveBounds.minX - desiredFinalAXFrame.minX, liveBounds.minY - desiredFinalAXFrame.minY)
                    let sizeDiff = (didSnap || wasMax) && (
                        abs(liveBounds.width - desiredFinalAXFrame.width) > 12
                            || abs(liveBounds.height - desiredFinalAXFrame.height) > 12
                    )
                    if originDiff > 4 || sizeDiff {
                        AccessibilityBridge.setFrame(win.element, axFrame: desiredFinalAXFrame)
                        AccessibilityBridge.focusWindow(win)
                        return false
                    }
                    return true
                }

                for delay in [0.035, 0.090, 0.160] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self, self.dragGeneration == dropGeneration else { return }
                        let verified = reapplyIfNeeded()
                        if verified {
                            finishDrop()
                        } else if didHideGhost {
                            self.syncActiveWindow()
                        }
                    }
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.190) {
                    finishDrop()
                }
            } else {
                finishDrop()
            }
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
        if !isDraggingTargetWindow {
            setInteractionActive(true)
        }
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
        if logicalBarFrameCocoa.width > 0 {
            logicalBarFrameCocoa.origin.x += deltaX
            logicalBarFrameCocoa.origin.y += deltaY
        }
        panel.setFrameOrigin(NSPoint(x: panel.frame.origin.x + deltaX, y: panel.frame.origin.y + deltaY))
        if let cornerSkirtPanel, cornerSkirtPanel.isVisible {
            cornerSkirtPanel.setFrameOrigin(NSPoint(x: cornerSkirtPanel.frame.origin.x + deltaX, y: cornerSkirtPanel.frame.origin.y + deltaY))
        }
        if let maskPanel = trafficLightMaskPanel, maskPanel.isVisible {
            maskPanel.setFrameOrigin(NSPoint(x: maskPanel.frame.origin.x + deltaX, y: maskPanel.frame.origin.y + deltaY))
        }
        snapManager.updateDragPreview(mouseLocationCocoa: NSEvent.mouseLocation)
    }

    private func finishDraggingCurrentWindow() {
        let win = currentWindow
        let bid = currentBundleID.isEmpty ? nil : currentBundleID
        isDraggingTargetWindow = false
        setInteractionActive(false)
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
    let onHoverBar: (Bool) -> Void

    var body: some View {
        let barHeight = state.barHeight
        let topRadius: CGFloat = (state.isNotchDocked || state.isMaximized) ? 0 : ChromeBarAppearance.floatingTopCornerRadius
        let roundLeft = !state.isLeftEdgeClipped
        let roundRight = !state.isRightEdgeClipped
        let barShape = UnevenRoundedRectangle(
            topLeadingRadius: roundLeft ? topRadius : 0,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: roundRight ? topRadius : 0,
            style: .continuous
        )

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
        .onHover(perform: onHoverBar)
        .background {
            if state.isNotchDocked {
                ChromeBarAppearance.notchFillColor
                    .overlay(
                        Rectangle()
                            .frame(height: 0.5)
                            .foregroundStyle(Color.white.opacity(0.14)),
                        alignment: .bottom
                    )
            } else {
                ChromeBarAppearance.fillColor
            }
        }
        .overlay(alignment: .bottom) {
            if !state.isNotchDocked {
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundStyle(ChromeBarAppearance.bottomDividerColor)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if !state.isNotchDocked {
                barShape
                    .strokeBorder(ChromeBarAppearance.outerBorderColor, lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
        }
        .clipShape(barShape)
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
            CaptionButton(
                symbol: "minus",
                hoverColor: ChromeBarAppearance.hoverFill,
                height: height,
                action: onMinimize
            )

            CaptionButton(
                symbol: state.isMaximized ? "square.on.square" : "square",
                hoverColor: ChromeBarAppearance.hoverFill,
                height: height,
                action: onMaximize,
                onHoverWithScreenRect: { hovering, rect in
                    onHoverMaximize(hovering, rect)
                }
            )

            CaptionButton(
                symbol: "xmark",
                hoverColor: ChromeBarAppearance.closeHoverFill,
                hoverForeground: .white,
                height: height,
                action: onClose
            )
        }
    }
}

private struct CornerSkirtOverlayView: View {
    let state: CornerSkirtState

    var body: some View {
        let shape = CornerSkirtCutoutShape(
            innerCornerRadius: ChromeBarAppearance.windowInnerCornerRadius,
            roundTopLeft: !state.isLeftEdgeClipped,
            roundTopRight: !state.isRightEdgeClipped
        )
        ChromeBarAppearance.fillColor
            .clipShape(shape)
            .allowsHitTesting(false)
    }
}

private struct BackgroundChromeBarView: View {
    let state: BackgroundChromeBarState
    let onFocus: () -> Void
    let onMinimize: () -> Void
    let onMaximize: () -> Void
    let onClose: () -> Void

    var body: some View {
        let barHeight = state.barHeight
        let topRadius: CGFloat = (state.isNotchDocked || state.isMaximized) ? 0 : ChromeBarAppearance.floatingTopCornerRadius
        let roundLeft = !state.isLeftEdgeClipped
        let roundRight = !state.isRightEdgeClipped
        let maskShape = OccludedBarMaskShape(
            topLeadingRadius: roundLeft ? topRadius : 0,
            topTrailingRadius: roundRight ? topRadius : 0,
            occludedLocalRects: state.occludedLocalRects
        )

        Group {
            if state.isNotchDocked {
                HStack(spacing: 0) {
                    BackgroundTitleClickArea(
                        title: "",
                        icon: state.appIcon,
                        onFocus: onFocus
                    )
                    .frame(width: state.leftNotchWidth)
                    .frame(maxHeight: .infinity)

                    Color.black
                        .frame(width: state.notchWidth)
                        .frame(maxHeight: .infinity)

                    HStack(spacing: 0) {
                        BackgroundTitleClickArea(
                            title: state.windowTitle,
                            icon: nil,
                            onFocus: onFocus
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        inactiveCaptionButtons(height: barHeight)
                    }
                    .frame(width: state.rightNotchWidth)
                    .frame(maxHeight: .infinity)
                }
            } else {
                HStack(spacing: 0) {
                    BackgroundTitleClickArea(
                        title: state.windowTitle,
                        icon: state.appIcon,
                        onFocus: onFocus
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    inactiveCaptionButtons(height: barHeight)
                }
            }
        }
        .frame(height: barHeight)
        .background {
            if state.isNotchDocked {
                ChromeBarAppearance.inactiveNotchFillColor
            } else {
                ChromeBarAppearance.inactiveFillColor
            }
        }
        .overlay(alignment: .bottom) {
            if !state.isNotchDocked {
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundStyle(ChromeBarAppearance.bottomDividerColor)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if !state.isNotchDocked {
                UnevenRoundedRectangle(
                    topLeadingRadius: roundLeft ? topRadius : 0,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: roundRight ? topRadius : 0,
                    style: .continuous
                )
                .strokeBorder(ChromeBarAppearance.inactiveOuterBorderColor, lineWidth: 0.75)
                .allowsHitTesting(false)
            }
        }
        .clipShape(maskShape, style: FillStyle(eoFill: true))
    }

    @ViewBuilder
    private func inactiveCaptionButtons(height: CGFloat) -> some View {
        HStack(spacing: 0) {
            CaptionButton(
                symbol: "minus",
                hoverColor: ChromeBarAppearance.hoverFill,
                defaultForeground: ChromeBarAppearance.inactiveCaptionForeground,
                height: height,
                action: onMinimize
            )

            CaptionButton(
                symbol: state.isMaximized ? "square.on.square" : "square",
                hoverColor: ChromeBarAppearance.hoverFill,
                defaultForeground: ChromeBarAppearance.inactiveCaptionForeground,
                height: height,
                action: onMaximize
            )

            CaptionButton(
                symbol: "xmark",
                hoverColor: ChromeBarAppearance.closeHoverFill,
                defaultForeground: ChromeBarAppearance.inactiveCaptionForeground,
                hoverForeground: .white,
                height: height,
                action: onClose
            )
        }
    }
}

private struct BackgroundTitleClickArea: NSViewRepresentable {
    let title: String
    let icon: NSImage?
    let onFocus: () -> Void

    func makeNSView(context: Context) -> BackgroundTitleClickNSView {
        let v = BackgroundTitleClickNSView()
        v.title = title
        v.icon = icon
        v.onFocus = onFocus
        return v
    }

    func updateNSView(_ nsView: BackgroundTitleClickNSView, context: Context) {
        nsView.title = title
        nsView.icon = icon
        nsView.onFocus = onFocus
    }
}

private final class BackgroundTitleClickNSView: NSView {
    var title: String = "" {
        didSet { label.stringValue = title }
    }
    var icon: NSImage? {
        didSet {
            iconView.image = icon
            iconView.isHidden = (icon == nil)
        }
    }
    var onFocus: (() -> Void)?

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.isHidden = true

        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.54)
        label.lineBreakMode = .byTruncatingTail
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(label)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: iconView.trailingAnchor, constant: 8),
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
        onFocus?()
    }
}

private struct DragGhostPreviewView: View {
    let state: DragGhostState

    var body: some View {
        let barHeight = state.barHeight
        let skirtHeight = ChromeBarAppearance.cornerSkirtHeight
        let capShape = FloatingChromeCapShape(
            barHeight: barHeight,
            topCornerRadius: ChromeBarAppearance.floatingTopCornerRadius,
            innerCornerRadius: ChromeBarAppearance.windowInnerCornerRadius,
            skirtHeight: skirtHeight
        )

        ZStack(alignment: .top) {
            Group {
                if let snapshot = state.snapshot {
                    GeometryReader { geo in
                        let origW = max(1, state.snapshotOriginalSize.width)
                        let origH = max(1, state.snapshotOriginalSize.height)
                        let sx = geo.size.width / origW
                        let sy = geo.size.height / origH
                        ZStack(alignment: .topLeading) {
                            Image(nsImage: snapshot)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: geo.size.width, height: geo.size.height)

                            if let relMask = state.trafficLightMaskRectLocal,
                               let maskColor = state.trafficLightMaskColor {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color(nsColor: maskColor))
                                    .frame(
                                        width: max(1, relMask.width * sx),
                                        height: max(1, relMask.height * sy)
                                    )
                                    .offset(
                                        x: relMask.minX * sx,
                                        y: relMask.minY * sy
                                    )
                            }
                        }
                    }
                } else {
                    let bodyShape = UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: ChromeBarAppearance.windowInnerCornerRadius,
                        bottomTrailingRadius: ChromeBarAppearance.windowInnerCornerRadius,
                        topTrailingRadius: 0,
                        style: .continuous
                    )
                    ZStack {
                        bodyShape
                            .fill(ChromeBarAppearance.fillColor)
                        bodyShape
                            .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)

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
            }
            .padding(.top, barHeight)

            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    if let icon = state.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 15, height: 15)
                            .padding(.leading, 8)
                    }

                    ForEach(Array(state.menuTitles.enumerated()), id: \.offset) { _, menuTitle in
                        Text(menuTitle)
                            .font(.system(size: 11.5, weight: .regular))
                            .foregroundStyle(ChromeBarAppearance.menuForeground)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                    }

                    if state.hasOverflowMenus {
                        Text("•••")
                            .font(.system(size: 11.5, weight: .regular))
                            .foregroundStyle(ChromeBarAppearance.menuForeground)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                    }

                    Spacer(minLength: 8)

                    Text(state.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ChromeBarAppearance.titleForeground)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 8)

                    HStack(spacing: 0) {
                        ghostCaptionGlyph("minus")
                        ghostCaptionGlyph("square")
                        ghostCaptionGlyph("xmark")
                    }
                }
                .frame(height: barHeight)

                Color.clear
                    .frame(height: skirtHeight)
            }
            .background(ChromeBarAppearance.fillColor)
            .overlay(alignment: .top) {
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundStyle(ChromeBarAppearance.bottomDividerColor)
                    .offset(y: barHeight - 0.5)
            }
            .overlay {
                UnevenRoundedRectangle(
                    topLeadingRadius: ChromeBarAppearance.floatingTopCornerRadius,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: ChromeBarAppearance.floatingTopCornerRadius,
                    style: .continuous
                )
                .strokeBorder(ChromeBarAppearance.outerBorderColor, lineWidth: 0.75)
            }
            .clipShape(capShape)
        }
    }

    private func ghostCaptionGlyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(ChromeBarAppearance.captionForeground)
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
                .foregroundStyle(ChromeBarAppearance.menuForeground)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(hovered ? ChromeBarAppearance.hoverFill : .clear)
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
    var defaultForeground: Color = ChromeBarAppearance.captionForeground
    var hoverForeground: Color = .white
    var height: CGFloat = 28
    let action: () -> Void
    var onHoverWithScreenRect: ((Bool, NSRect) -> Void)?

    @State private var hovered = false
    @State private var hostView: NSView?

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(hovered ? hoverForeground : defaultForeground)
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
        label.textColor = NSColor.white.withAlphaComponent(0.76)
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
