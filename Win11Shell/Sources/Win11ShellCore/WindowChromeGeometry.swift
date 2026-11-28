import CoreGraphics
import Foundation

public enum WindowSnapZone: String, CaseIterable, Equatable, Sendable {
    case leftHalf
    case rightHalf
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case leftTwoThirds
    case rightOneThird
    case maximized
}

public struct DockedBarLayout: Equatable, Sendable {
    public let frameCocoa: CGRect
    public let isNotchDocked: Bool
    public let leftNotchWidth: CGFloat
    public let notchWidth: CGFloat
    public let rightNotchWidth: CGFloat

    public init(
        frameCocoa: CGRect,
        isNotchDocked: Bool,
        leftNotchWidth: CGFloat,
        notchWidth: CGFloat,
        rightNotchWidth: CGFloat
    ) {
        self.frameCocoa = frameCocoa
        self.isNotchDocked = isNotchDocked
        self.leftNotchWidth = leftNotchWidth
        self.notchWidth = notchWidth
        self.rightNotchWidth = rightNotchWidth
    }
}

public enum WindowChromeGeometry {
    /// Converts a window frame in Accessibility coordinates (top-left primary screen origin, +Y down)
    /// to Cocoa screen coordinates (bottom-left primary screen origin, +Y up).
    public static func axRectToCocoa(_ axRect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        let cocoaY = primaryScreenHeight - (axRect.origin.y + axRect.height)
        return CGRect(x: axRect.origin.x, y: cocoaY, width: axRect.width, height: axRect.height)
    }

    /// Converts a Cocoa screen rect back to Accessibility top-left coordinates.
    public static func cocoaRectToAX(_ cocoaRect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        let axY = primaryScreenHeight - (cocoaRect.origin.y + cocoaRect.height)
        return CGRect(x: cocoaRect.origin.x, y: axY, width: cocoaRect.width, height: cocoaRect.height)
    }

    /// Computes both the Cocoa frame and notch-docking geometry for the chrome bar of `axWindowFrame`.
    /// On notched MacBook Pro screens (`safeAreaTopInset >= barHeight`), when the window's top approaches
    /// the notch bezel (`cocoaWindow.maxY + barHeight > maxVisibleTop`), the chrome bar docks directly
    /// into the 38pt notch band split around the camera notch so maximized windows have zero top gap.
    public static func dockedBarLayout(
        forAXWindowFrame axWindowFrame: CGRect,
        primaryScreenHeight: CGFloat,
        screenFrameCocoa: CGRect,
        visibleFrameCocoa: CGRect,
        safeAreaTopInset: CGFloat,
        auxiliaryTopLeftWidth: CGFloat,
        auxiliaryTopRightWidth: CGFloat,
        barHeight: CGFloat,
        taskbarHeight: CGFloat
    ) -> DockedBarLayout? {
        guard axWindowFrame.width >= 220, axWindowFrame.height >= 100 else {
            return nil
        }

        let cocoaWindow = axRectToCocoa(axWindowFrame, primaryScreenHeight: primaryScreenHeight)
        let fillsWidth = abs(cocoaWindow.width - screenFrameCocoa.width) < 4
        let fillsHeight = abs(cocoaWindow.height - screenFrameCocoa.height) < 4
        if fillsWidth && fillsHeight {
            return nil
        }

        let maxVisibleTop = min(visibleFrameCocoa.maxY, screenFrameCocoa.maxY)
        let isFullWidth = cocoaWindow.width >= screenFrameCocoa.width - 24
        if safeAreaTopInset >= barHeight && isFullWidth && (cocoaWindow.maxY + barHeight) > (maxVisibleTop + 0.5) {
            let bezelHeight = min(screenFrameCocoa.height, safeAreaTopInset + 1)
            let bezelRect = CGRect(
                x: screenFrameCocoa.minX,
                y: screenFrameCocoa.maxY - bezelHeight,
                width: screenFrameCocoa.width,
                height: bezelHeight
            )
            let leftW = auxiliaryTopLeftWidth > 100 ? auxiliaryTopLeftWidth : (screenFrameCocoa.width - 220) / 2
            let rightW = auxiliaryTopRightWidth > 100 ? auxiliaryTopRightWidth : (screenFrameCocoa.width - 220) / 2
            let notchW = max(0, screenFrameCocoa.width - leftW - rightW)
            return DockedBarLayout(
                frameCocoa: bezelRect,
                isNotchDocked: true,
                leftNotchWidth: leftW,
                notchWidth: notchW,
                rightNotchWidth: rightW
            )
        }

        guard let rect = dockedBarFrame(
            forAXWindowFrame: axWindowFrame,
            primaryScreenHeight: primaryScreenHeight,
            screenFrameCocoa: screenFrameCocoa,
            visibleFrameCocoa: visibleFrameCocoa,
            barHeight: barHeight,
            taskbarHeight: taskbarHeight
        ) else {
            return nil
        }
        return DockedBarLayout(
            frameCocoa: rect,
            isNotchDocked: false,
            leftNotchWidth: 0,
            notchWidth: 0,
            rightNotchWidth: 0
        )
    }

    /// Expands a floating chrome bar panel downward by `skirtHeight` points when docked flush
    /// atop a window so concave bottom corner skirts hug macOS's rounded upper window corners.
    public static func renderedBarPanelFrame(
        for layout: DockedBarLayout,
        windowCocoaFrame: CGRect,
        skirtHeight: CGFloat
    ) -> (panelFrameCocoa: CGRect, effectiveSkirtHeight: CGFloat) {
        if !layout.isNotchDocked,
           skirtHeight > 0,
           abs(layout.frameCocoa.minY - windowCocoaFrame.maxY) < 1.5,
           windowCocoaFrame.height >= 60 {
            let clampedSkirt = min(skirtHeight, max(0, windowCocoaFrame.height - 40))
            let panelFrame = CGRect(
                x: layout.frameCocoa.minX,
                y: layout.frameCocoa.minY - clampedSkirt,
                width: layout.frameCocoa.width,
                height: layout.frameCocoa.height + clampedSkirt
            )
            return (panelFrame, clampedSkirt)
        }
        return (layout.frameCocoa, 0)
    }

    /// Computes the Cocoa frame for the 28pt Window Chrome Bar docked flush above `axWindowFrame`.
    /// Returns `nil` when the window is too small or covers the full screen (fullscreen/kiosk).
    public static func dockedBarFrame(
        forAXWindowFrame axWindowFrame: CGRect,
        primaryScreenHeight: CGFloat,
        screenFrameCocoa: CGRect,
        visibleFrameCocoa: CGRect,
        barHeight: CGFloat,
        taskbarHeight: CGFloat
    ) -> CGRect? {
        guard axWindowFrame.width >= 220, axWindowFrame.height >= 100 else {
            return nil
        }

        let cocoaWindow = axRectToCocoa(axWindowFrame, primaryScreenHeight: primaryScreenHeight)

        // Hide if window fills virtually the entire screen (native fullscreen / presentation mode).
        let fillsWidth = abs(cocoaWindow.width - screenFrameCocoa.width) < 4
        let fillsHeight = abs(cocoaWindow.height - screenFrameCocoa.height) < 4
        if fillsWidth && fillsHeight {
            return nil
        }

        let maxAllowedTop = min(visibleFrameCocoa.maxY, screenFrameCocoa.maxY)
        let desiredBarBottom = cocoaWindow.maxY
        let clampedBottom = min(
            max(desiredBarBottom, screenFrameCocoa.minY + taskbarHeight),
            maxAllowedTop - barHeight
        )

        let visibleMinX = max(screenFrameCocoa.minX, cocoaWindow.minX)
        let visibleMaxX = min(screenFrameCocoa.maxX, cocoaWindow.maxX)
        let barMinX = min(visibleMinX, screenFrameCocoa.maxX - 220)
        let barWidth = max(0, visibleMaxX - barMinX)
        guard barWidth >= 220 else { return nil }

        return CGRect(x: barMinX, y: clampedBottom, width: barWidth, height: barHeight)
    }

    /// Computes the Accessibility frame for a maximized window on the given screen,
    /// reserving `barHeight` below `visibleFrame.maxY` on non-notched screens or docking cleanly flush
    /// beneath the 38pt notch chrome bar when `safeAreaTopInset >= barHeight`, plus `taskbarHeight` at the bottom.
    public static func maximizedAXFrame(
        forScreenFrameCocoa screenFrameCocoa: CGRect,
        visibleFrameCocoa: CGRect,
        primaryScreenHeight: CGFloat,
        barHeight: CGFloat,
        taskbarHeight: CGFloat,
        safeAreaTopInset: CGFloat = 0
    ) -> CGRect {
        let maxVisibleTop = min(visibleFrameCocoa.maxY, screenFrameCocoa.maxY)
        let topLimitCocoa = (safeAreaTopInset >= barHeight) ? maxVisibleTop : (maxVisibleTop - barHeight)
        let bottomLimitCocoa = screenFrameCocoa.minY + taskbarHeight
        let targetHeight = max(120, topLimitCocoa - bottomLimitCocoa)
        let cocoaTarget = CGRect(
            x: screenFrameCocoa.minX,
            y: bottomLimitCocoa,
            width: screenFrameCocoa.width,
            height: targetHeight
        )
        return cocoaRectToAX(cocoaTarget, primaryScreenHeight: primaryScreenHeight)
    }

    /// Computes the Accessibility frame for any `WindowSnapZone`, reserving top chrome bar and bottom taskbar.
    public static func snapAXFrame(
        for zone: WindowSnapZone,
        screenFrameCocoa: CGRect,
        visibleFrameCocoa: CGRect,
        primaryScreenHeight: CGFloat,
        barHeight: CGFloat,
        taskbarHeight: CGFloat,
        safeAreaTopInset: CGFloat = 0
    ) -> CGRect {
        let maxInsetForZone: CGFloat = (zone == .maximized) ? safeAreaTopInset : 0
        let fullMaxAX = maximizedAXFrame(
            forScreenFrameCocoa: screenFrameCocoa,
            visibleFrameCocoa: visibleFrameCocoa,
            primaryScreenHeight: primaryScreenHeight,
            barHeight: barHeight,
            taskbarHeight: taskbarHeight,
            safeAreaTopInset: maxInsetForZone
        )

        switch zone {
        case .maximized:
            return fullMaxAX
        case .leftHalf:
            return CGRect(x: fullMaxAX.minX, y: fullMaxAX.minY, width: fullMaxAX.width / 2, height: fullMaxAX.height)
        case .rightHalf:
            return CGRect(x: fullMaxAX.minX + fullMaxAX.width / 2, y: fullMaxAX.minY, width: fullMaxAX.width / 2, height: fullMaxAX.height)
        case .topLeft:
            return CGRect(x: fullMaxAX.minX, y: fullMaxAX.minY, width: fullMaxAX.width / 2, height: fullMaxAX.height / 2)
        case .topRight:
            return CGRect(x: fullMaxAX.minX + fullMaxAX.width / 2, y: fullMaxAX.minY, width: fullMaxAX.width / 2, height: fullMaxAX.height / 2)
        case .bottomLeft:
            return CGRect(x: fullMaxAX.minX, y: fullMaxAX.minY + fullMaxAX.height / 2, width: fullMaxAX.width / 2, height: fullMaxAX.height / 2)
        case .bottomRight:
            return CGRect(x: fullMaxAX.minX + fullMaxAX.width / 2, y: fullMaxAX.minY + fullMaxAX.height / 2, width: fullMaxAX.width / 2, height: fullMaxAX.height / 2)
        case .leftTwoThirds:
            return CGRect(x: fullMaxAX.minX, y: fullMaxAX.minY, width: (fullMaxAX.width * 0.66).rounded(), height: fullMaxAX.height)
        case .rightOneThird:
            let w = (fullMaxAX.width * 0.34).rounded()
            return CGRect(x: fullMaxAX.maxX - w, y: fullMaxAX.minY, width: w, height: fullMaxAX.height)
        }
    }

    /// Returns a clamped AX frame when a standard non-fullscreen window extends into the top bar band
    /// or bottom taskbar (`screenFrame.minY + taskbarHeight`), or `nil` if already clean.
    public static func normalizedAXFrame(
        forAXWindowFrame axFrame: CGRect,
        screenFrameCocoa: CGRect,
        visibleFrameCocoa: CGRect,
        primaryScreenHeight: CGFloat,
        barHeight: CGFloat,
        taskbarHeight: CGFloat,
        safeAreaTopInset: CGFloat = 0
    ) -> CGRect? {
        guard axFrame.width >= 100, axFrame.height >= 100 else {
            return nil
        }

        let cocoa = axRectToCocoa(axFrame, primaryScreenHeight: primaryScreenHeight)
        let fillsWidth = abs(cocoa.width - screenFrameCocoa.width) < 4
        let fillsHeight = abs(cocoa.height - screenFrameCocoa.height) < 4
        if fillsWidth && fillsHeight {
            return nil
        }

        let workMinY = screenFrameCocoa.minY + taskbarHeight
        let maxVisibleTop = min(visibleFrameCocoa.maxY, screenFrameCocoa.maxY)
        let isFullWidth = cocoa.width >= screenFrameCocoa.width - 24
        let workMaxY = (safeAreaTopInset >= barHeight && isFullWidth) ? maxVisibleTop : (maxVisibleTop - barHeight)
        let workHeight = max(120, workMaxY - workMinY)

        let extendsAbove = cocoa.maxY > workMaxY + 0.5
        let extendsBelow = cocoa.minY < workMinY - 0.5
        guard extendsAbove || extendsBelow else {
            return nil
        }

        let clampedHeight = min(cocoa.height, workHeight)
        let clampedMinY = min(max(cocoa.minY, workMinY), workMaxY - clampedHeight)
        let clampedWidth = min(cocoa.width, screenFrameCocoa.width)
        let clampedMinX = min(max(cocoa.minX, screenFrameCocoa.minX), screenFrameCocoa.maxX - clampedWidth)

        let targetCocoa = CGRect(x: clampedMinX, y: clampedMinY, width: clampedWidth, height: clampedHeight)
        return cocoaRectToAX(targetCocoa, primaryScreenHeight: primaryScreenHeight)
    }

    /// Maps a mouse pointer in Cocoa screen coordinates during a window drag to a Windows 11 snap zone.
    public static func dragSnapZone(
        forMouseCocoa mouseCocoa: CGPoint,
        screenFrameCocoa: CGRect,
        visibleFrameCocoa: CGRect,
        edgeThreshold: CGFloat = 14,
        cornerSize: CGFloat = 90
    ) -> WindowSnapZone? {
        guard mouseCocoa.x >= screenFrameCocoa.minX - 2,
              mouseCocoa.x <= screenFrameCocoa.maxX + 2,
              mouseCocoa.y >= screenFrameCocoa.minY - 2,
              mouseCocoa.y <= screenFrameCocoa.maxY + 2
        else {
            return nil
        }

        let topEdgeY = min(visibleFrameCocoa.maxY, screenFrameCocoa.maxY)
        let atLeft = mouseCocoa.x <= screenFrameCocoa.minX + edgeThreshold
        let atRight = mouseCocoa.x >= screenFrameCocoa.maxX - edgeThreshold
        let atTop = mouseCocoa.y >= topEdgeY - edgeThreshold

        let nearTop = mouseCocoa.y >= topEdgeY - cornerSize
        let nearBottom = mouseCocoa.y <= screenFrameCocoa.minY + cornerSize
        let nearLeft = mouseCocoa.x <= screenFrameCocoa.minX + cornerSize
        let nearRight = mouseCocoa.x >= screenFrameCocoa.maxX - cornerSize

        if (atLeft && nearTop) || (atTop && nearLeft) {
            return .topLeft
        }
        if (atRight && nearTop) || (atTop && nearRight) {
            return .topRight
        }
        if atLeft && nearBottom {
            return .bottomLeft
        }
        if atRight && nearBottom {
            return .bottomRight
        }
        if atTop {
            return .maximized
        }
        if atLeft {
            return .leftHalf
        }
        if atRight {
            return .rightHalf
        }
        return nil
    }

    public enum TitlebarElementKind: Equatable, Sendable {
        case trafficLight
        case interactiveControl
        case dragSurface
        case ambiguousContainer
    }

    private static let trafficLightSubroles: Set<String> = [
        "AXCloseButton",
        "AXMinimizeButton",
        "AXZoomButton",
        "AXFullScreenButton"
    ]

    private static let interactiveTitlebarRoles: Set<String> = [
        "AXButton",
        "AXRadioButton",
        "AXCheckBox",
        "AXPopUpButton",
        "AXMenuButton",
        "AXTextField",
        "AXSearchField",
        "AXComboBox",
        "AXTab",
        "AXLink",
        "AXDisclosureTriangle",
        "AXMenuItem",
        "AXMenuBarItem",
        "AXSegmentedControl",
        "AXSlider",
        "AXIncrementor",
        "AXColorWell"
    ]

    private static let nonInteractiveTitlebarContainerRoles: Set<String> = [
        "AXWindow",
        "AXWebArea",
        "AXApplication",
        "AXScrollArea",
        "AXToolbar",
        "AXSplitGroup",
        "AXTabGroup",
        "AXMenuBar"
    ]

    private static let confirmedBareDragRoles: Set<String> = [
        "AXWindow",
        "AXToolbar",
        "AXSplitGroup",
        "AXScrollArea",
        "AXMenuBar",
        "AXApplication",
        "AXStaticText"
    ]

    private static let ambiguousContainerRoles: Set<String> = [
        "AXGroup",
        "AXTabGroup",
        "AXWebArea"
    ]

    /// Estimates the height of a window's native macOS titlebar strip from its traffic-light button rect.
    public static func estimatedNativeTitlebarHeight(trafficLightRelativeRect: CGRect?) -> CGFloat {
        if let rel = trafficLightRelativeRect, rel.maxY > 0 {
            return max(44, min(60, rel.maxY + 20))
        }
        return 52
    }

    /// Returns `true` when `axPoint` lies inside the window's native top titlebar band,
    /// preserving the outer `resizeBorder` (top/left/right) for window resizing.
    public static func isInNativeTitlebarBand(
        axPoint: CGPoint,
        windowAXFrame: CGRect,
        titlebarHeight: CGFloat = 52,
        resizeBorder: CGFloat = 4
    ) -> Bool {
        guard windowAXFrame.width >= 100, windowAXFrame.height >= 60 else {
            return false
        }
        let localX = axPoint.x - windowAXFrame.minX
        let localY = axPoint.y - windowAXFrame.minY
        return localX >= resizeBorder
            && localX <= (windowAXFrame.width - resizeBorder)
            && localY >= resizeBorder
            && localY <= min(titlebarHeight, windowAXFrame.height)
    }

    /// Classifies an Accessibility element inside a window's native titlebar band into
    /// traffic lights, interactive controls (tabs/buttons/inputs), confirmed bare titlebar surfaces,
    /// or ambiguous nested container roles (such as Chromium Views `AXGroup` tab strips).
    public static func classifyTitlebarElement(
        role: String?,
        subrole: String?,
        actions: [String]
    ) -> TitlebarElementKind {
        if let subrole, trafficLightSubroles.contains(subrole) {
            return .trafficLight
        }
        if let role, interactiveTitlebarRoles.contains(role) {
            return .interactiveControl
        }
        let hasPressAction = actions.contains("AXPress") || actions.contains("AXConfirm")
        if hasPressAction {
            if let role, nonInteractiveTitlebarContainerRoles.contains(role) {
                return ambiguousContainerRoles.contains(role) ? .ambiguousContainer : .dragSurface
            }
            return .interactiveControl
        }
        if let role, confirmedBareDragRoles.contains(role) {
            return .dragSurface
        }
        return .ambiguousContainer
    }

    /// Returns the Cocoa screen rect for the top notch-bezel band when `safeAreaTopInset > 1` (e.g. 39pt on 38pt-notched MacBook Pro displays to cover MenuBarAgent).
    public static func notchBezelFrameCocoa(
        screenFrameCocoa: CGRect,
        safeAreaTopInset: CGFloat
    ) -> CGRect? {
        guard safeAreaTopInset > 1,
              screenFrameCocoa.width > 0,
              screenFrameCocoa.height > safeAreaTopInset
        else {
            return nil
        }
        let bezelHeight = min(screenFrameCocoa.height, safeAreaTopInset + 1)
        return CGRect(
            x: screenFrameCocoa.minX,
            y: screenFrameCocoa.maxY - bezelHeight,
            width: screenFrameCocoa.width,
            height: bezelHeight
        )
    }

    /// Returns `true` when a focused window intrudes into the 28pt chrome bar or is a maximized/tall window
    /// clipped behind the 48pt bottom taskbar, while leaving intentionally positioned smaller floating windows untouched.
    public static func shouldAutoNormalizeFocusedWindow(
        axFrame: CGRect,
        screenFrameCocoa: CGRect,
        visibleFrameCocoa: CGRect,
        primaryScreenHeight: CGFloat,
        barHeight: CGFloat,
        taskbarHeight: CGFloat,
        safeAreaTopInset: CGFloat = 0
    ) -> Bool {
        guard normalizedAXFrame(
            forAXWindowFrame: axFrame,
            screenFrameCocoa: screenFrameCocoa,
            visibleFrameCocoa: visibleFrameCocoa,
            primaryScreenHeight: primaryScreenHeight,
            barHeight: barHeight,
            taskbarHeight: taskbarHeight,
            safeAreaTopInset: safeAreaTopInset
        ) != nil else {
            return false
        }

        let cocoa = axRectToCocoa(axFrame, primaryScreenHeight: primaryScreenHeight)
        let workMinY = screenFrameCocoa.minY + taskbarHeight
        let maxVisibleTop = min(visibleFrameCocoa.maxY, screenFrameCocoa.maxY)
        let isFullWidth = cocoa.width >= screenFrameCocoa.width - 24
        let workMaxY = (safeAreaTopInset >= barHeight && isFullWidth) ? maxVisibleTop : (maxVisibleTop - barHeight)
        let workHeight = max(120, workMaxY - workMinY)

        if cocoa.maxY > workMaxY + 1.0 {
            return true
        }
        if cocoa.minY < workMinY - 1.0 && (cocoa.maxY >= workMaxY - 40 || cocoa.height >= workHeight - 12) {
            return true
        }
        return false
    }

    // MARK: - Background Bar Occlusion & Edge Resizing Geometry

    /// Returns intersections of `occludersAX` with `rectAX` expressed in top-left local coordinates of `rectAX`.
    public static func occludedLocalRects(in rectAX: CGRect, occludedBy occludersAX: [CGRect]) -> [CGRect] {
        guard rectAX.width > 0, rectAX.height > 0 else { return [] }
        var result: [CGRect] = []
        result.reserveCapacity(occludersAX.count)
        for occ in occludersAX {
            let inter = rectAX.intersection(occ)
            guard !inter.isNull, inter.width > 0.01, inter.height > 0.01 else {
                continue
            }
            result.append(CGRect(
                x: inter.minX - rectAX.minX,
                y: inter.minY - rectAX.minY,
                width: inter.width,
                height: inter.height
            ))
        }
        return result
    }

    /// Returns `true` when `rectAX` is 100% covered by the union of `occludersAX` via exact X-strip sweep.
    public static func isFullyOccluded(_ rectAX: CGRect, occludedBy occludersAX: [CGRect]) -> Bool {
        guard !rectAX.isNull, rectAX.width > 0.01, rectAX.height > 0.01 else {
            return false
        }

        var clipped: [CGRect] = []
        clipped.reserveCapacity(occludersAX.count)
        var rawXs: [CGFloat] = [rectAX.minX, rectAX.maxX]
        rawXs.reserveCapacity(occludersAX.count * 2 + 2)

        for occ in occludersAX {
            let inter = rectAX.intersection(occ)
            guard !inter.isNull, inter.width > 0.01, inter.height > 0.01 else {
                continue
            }
            clipped.append(inter)
            rawXs.append(inter.minX)
            rawXs.append(inter.maxX)
        }

        guard !clipped.isEmpty else { return false }

        rawXs.sort()
        var xs: [CGFloat] = []
        xs.reserveCapacity(rawXs.count)
        for x in rawXs {
            if let last = xs.last, abs(x - last) <= 0.005 {
                continue
            }
            xs.append(x)
        }

        guard xs.count >= 2 else { return false }

        for i in 0..<(xs.count - 1) {
            let x0 = xs[i]
            let x1 = xs[i + 1]
            if x1 - x0 <= 0.01 { continue }
            let midX = (x0 + x1) * 0.5

            var yIntervals: [(minY: CGFloat, maxY: CGFloat)] = []
            for r in clipped where r.minX <= midX && r.maxX >= midX {
                yIntervals.append((r.minY, r.maxY))
            }
            if yIntervals.isEmpty {
                return false
            }
            yIntervals.sort {
                if $0.minY != $1.minY { return $0.minY < $1.minY }
                return $0.maxY < $1.maxY
            }

            var coveredY = rectAX.minY
            for interval in yIntervals {
                if interval.minY > coveredY + 0.01 {
                    return false
                }
                if interval.maxY > coveredY {
                    coveredY = interval.maxY
                }
                if coveredY >= rectAX.maxY - 0.01 {
                    break
                }
            }
            if coveredY < rectAX.maxY - 0.01 {
                return false
            }
        }

        return true
    }

    public enum ChromeBarResizeEdge: Equatable, Sendable {
        case top
        case topLeft
        case topRight
        case left
        case right
    }

    public enum WindowResizeEdge: Equatable, Sendable {
        case top
        case bottom
        case left
        case right
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
    }

    /// Returns the combined AX bounding rect of a window and its docked chrome bar.
    public static func combinedWindowAndBarAXFrame(
        windowAXFrame: CGRect,
        barAXFrame: CGRect
    ) -> CGRect {
        windowAXFrame.union(barAXFrame)
    }

    /// Hit-tests the outer perimeter of `combinedFrameAX` (expanded outward by `outset` and
    /// extending `borderThickness` inward, with `cornerSize` corner catch zones) in AX coordinates.
    public static func windowResizeEdge(
        atAXPoint pt: CGPoint,
        combinedFrameAX: CGRect,
        borderThickness: CGFloat = 6,
        outset: CGFloat = 2,
        cornerSize: CGFloat = 14,
        isTopClipped: Bool = false,
        isLeftClipped: Bool = false,
        isRightClipped: Bool = false,
        isBottomClipped: Bool = false
    ) -> WindowResizeEdge? {
        guard !combinedFrameAX.isNull,
              combinedFrameAX.width > 0,
              combinedFrameAX.height > 0
        else {
            return nil
        }

        let leftOutset: CGFloat = isLeftClipped ? 0 : outset
        let rightOutset: CGFloat = isRightClipped ? 0 : outset
        let topOutset: CGFloat = isTopClipped ? 0 : outset
        let bottomOutset: CGFloat = isBottomClipped ? 0 : outset

        guard pt.x >= combinedFrameAX.minX - leftOutset,
              pt.x <= combinedFrameAX.maxX + rightOutset,
              pt.y >= combinedFrameAX.minY - topOutset,
              pt.y <= combinedFrameAX.maxY + bottomOutset
        else {
            return nil
        }

        let nearTop = !isTopClipped && pt.y <= combinedFrameAX.minY + borderThickness
        let nearBottom = !isBottomClipped && pt.y >= combinedFrameAX.maxY - borderThickness
        let nearLeft = !isLeftClipped && pt.x <= combinedFrameAX.minX + borderThickness
        let nearRight = !isRightClipped && pt.x >= combinedFrameAX.maxX - borderThickness

        let inTopCornerY = !isTopClipped && pt.y <= combinedFrameAX.minY + cornerSize
        let inBottomCornerY = !isBottomClipped && pt.y >= combinedFrameAX.maxY - cornerSize
        let inLeftCornerX = !isLeftClipped && pt.x <= combinedFrameAX.minX + cornerSize
        let inRightCornerX = !isRightClipped && pt.x >= combinedFrameAX.maxX - cornerSize

        if inTopCornerY && inLeftCornerX {
            return .topLeft
        }
        if inTopCornerY && inRightCornerX {
            return .topRight
        }
        if inBottomCornerY && inLeftCornerX {
            return .bottomLeft
        }
        if inBottomCornerY && inRightCornerX {
            return .bottomRight
        }
        if nearTop {
            return .top
        }
        if nearBottom {
            return .bottom
        }
        if nearLeft {
            return .left
        }
        if nearRight {
            return .right
        }
        return nil
    }

    /// Hit-tests the outer resize borders and top corners of a chrome bar in top-left local coordinates.
    public static func chromeBarResizeEdge(
        atLocalPoint pt: CGPoint,
        barSize: CGSize,
        topBorder: CGFloat = 5,
        sideBorder: CGFloat = 5,
        cornerSize: CGFloat = 10,
        isTopClipped: Bool = false,
        isLeftClipped: Bool = false,
        isRightClipped: Bool = false
    ) -> ChromeBarResizeEdge? {
        guard barSize.width > 0,
              barSize.height > 0,
              pt.x >= 0, pt.x <= barSize.width,
              pt.y >= 0, pt.y <= barSize.height
        else {
            return nil
        }

        let nearTop = !isTopClipped && pt.y <= topBorder
        let nearLeft = !isLeftClipped && pt.x <= sideBorder
        let nearRight = !isRightClipped && pt.x >= barSize.width - sideBorder

        let inTopCornerY = !isTopClipped && pt.y <= cornerSize
        let inLeftCornerX = !isLeftClipped && pt.x <= cornerSize
        let inRightCornerX = !isRightClipped && pt.x >= barSize.width - cornerSize

        if inTopCornerY && inLeftCornerX {
            return .topLeft
        }
        if inTopCornerY && inRightCornerX {
            return .topRight
        }
        if nearTop {
            return .top
        }
        if nearLeft {
            return .left
        }
        if nearRight {
            return .right
        }
        return nil
    }

    /// Computes a clamped window AX frame while dragging any of the 8 outer resize edges or corners.
    public static func resizedWindowAXFrame(
        startWindowAXFrame: CGRect,
        edge: WindowResizeEdge,
        deltaAX: CGSize,
        minSize: CGSize = CGSize(width: 260, height: 160),
        minWindowTopAX: CGFloat,
        maxWindowBottomAX: CGFloat? = nil
    ) -> CGRect {
        var minX = startWindowAXFrame.minX
        var maxX = startWindowAXFrame.maxX
        var minY = startWindowAXFrame.minY
        var maxY = startWindowAXFrame.maxY

        switch edge {
        case .left, .topLeft, .bottomLeft:
            let proposedMinX = startWindowAXFrame.minX + deltaAX.width
            minX = min(proposedMinX, maxX - minSize.width)
        case .right, .topRight, .bottomRight:
            let proposedMaxX = startWindowAXFrame.maxX + deltaAX.width
            maxX = max(proposedMaxX, minX + minSize.width)
        case .top, .bottom:
            break
        }

        switch edge {
        case .top, .topLeft, .topRight:
            let proposedMinY = startWindowAXFrame.minY + deltaAX.height
            let maxAllowedMinY = max(minWindowTopAX, maxY - minSize.height)
            minY = min(max(proposedMinY, minWindowTopAX), maxAllowedMinY)
        case .bottom, .bottomLeft, .bottomRight:
            let proposedMaxY = startWindowAXFrame.maxY + deltaAX.height
            var clampedMaxY = max(proposedMaxY, minY + minSize.height)
            if let maxWindowBottomAX {
                clampedMaxY = min(clampedMaxY, max(minY + minSize.height, maxWindowBottomAX))
            }
            maxY = clampedMaxY
        case .left, .right:
            break
        }

        return CGRect(
            x: minX,
            y: minY,
            width: max(minSize.width, maxX - minX),
            height: max(minSize.height, maxY - minY)
        )
    }

    /// Computes a clamped window AX frame while dragging one of the chrome bar's top/side resize edges.
    public static func resizedWindowAXFrame(
        startWindowAXFrame: CGRect,
        edge: ChromeBarResizeEdge,
        deltaAX: CGSize,
        minSize: CGSize = CGSize(width: 260, height: 160),
        minWindowTopAX: CGFloat
    ) -> CGRect {
        let mappedEdge: WindowResizeEdge
        switch edge {
        case .top:
            mappedEdge = .top
        case .topLeft:
            mappedEdge = .topLeft
        case .topRight:
            mappedEdge = .topRight
        case .left:
            mappedEdge = .left
        case .right:
            mappedEdge = .right
        }
        return resizedWindowAXFrame(
            startWindowAXFrame: startWindowAXFrame,
            edge: mappedEdge,
            deltaAX: deltaAX,
            minSize: minSize,
            minWindowTopAX: minWindowTopAX,
            maxWindowBottomAX: nil
        )
    }

    /// Computes how many leading menu bar items can fit cleanly inside a chrome bar of `barWidth`
    /// without truncating labels or overflowing past the caption buttons and minimum title space.
    public static func visibleMenuCount(
        forMenuTitles titles: [String],
        barWidth: CGFloat,
        maxVisibleMenus: Int = 7,
        leadingReservedWidth: CGFloat = 27,
        trailingReservedWidth: CGFloat = 126,
        minTitleWidth: CGFloat = 110,
        overflowButtonWidth: CGFloat = 34,
        itemSpacing: CGFloat = 4,
        itemHorizontalPadding: CGFloat = 12,
        estimatedCharWidth: CGFloat = 7.2
    ) -> Int {
        guard !titles.isEmpty, maxVisibleMenus > 0 else { return 0 }

        let effectiveMinTitle = min(minTitleWidth, max(48, barWidth * 0.24))
        let totalBudget = barWidth - leadingReservedWidth - trailingReservedWidth - effectiveMinTitle
        guard totalBudget > 0 else { return 0 }

        var accumulated: CGFloat = 0
        var bestCount = 0
        let limit = min(maxVisibleMenus, titles.count)

        for i in 0..<limit {
            let itemWidth = max(20, CGFloat(titles[i].count) * estimatedCharWidth) + itemHorizontalPadding
            let nextAccum = accumulated + (i > 0 ? itemSpacing : 0) + itemWidth
            let hasOverflow = (i + 1) < titles.count
            let needed = nextAccum + (hasOverflow ? (itemSpacing + overflowButtonWidth) : 0)
            if needed <= totalBudget {
                bestCount = i + 1
                accumulated = nextAccum
            } else {
                break
            }
        }

        return bestCount
    }

    /// Validates that a window-local traffic-light bounding rect sits plausibly in the top-left titlebar band.
    public static func isValidTrafficLightRelativeRect(_ relRect: CGRect, forWindowSize windowSize: CGSize) -> Bool {
        windowSize.width >= 100
            && windowSize.height >= 60
            && relRect.minX >= -6 && relRect.minX <= 56
            && relRect.minY >= -6 && relRect.minY <= 56
            && relRect.width >= 32 && relRect.width <= 120
            && relRect.height >= 10 && relRect.height <= 42
            && relRect.maxX <= windowSize.width + 6
            && relRect.maxY <= windowSize.height + 6
    }
}
