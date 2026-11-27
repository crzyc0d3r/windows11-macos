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
        if safeAreaTopInset >= barHeight && (cocoaWindow.maxY + barHeight) > (maxVisibleTop + 0.5) {
            let bezelRect = CGRect(
                x: screenFrameCocoa.minX,
                y: screenFrameCocoa.maxY - safeAreaTopInset,
                width: screenFrameCocoa.width,
                height: safeAreaTopInset
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

        let barMinX = max(screenFrameCocoa.minX, min(cocoaWindow.minX, screenFrameCocoa.maxX - 220))
        let barWidth = min(cocoaWindow.width, screenFrameCocoa.maxX - barMinX)
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
        let fullMaxAX = maximizedAXFrame(
            forScreenFrameCocoa: screenFrameCocoa,
            visibleFrameCocoa: visibleFrameCocoa,
            primaryScreenHeight: primaryScreenHeight,
            barHeight: barHeight,
            taskbarHeight: taskbarHeight,
            safeAreaTopInset: safeAreaTopInset
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
        let workMaxY = (safeAreaTopInset >= barHeight) ? maxVisibleTop : (maxVisibleTop - barHeight)
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

    /// Estimates the height of a window's native macOS titlebar strip from its traffic-light button rect.
    public static func estimatedNativeTitlebarHeight(trafficLightRelativeRect: CGRect?) -> CGFloat {
        if let rel = trafficLightRelativeRect, rel.maxY > 0 {
            return max(36, min(52, rel.maxY + 10))
        }
        return 38
    }

    /// Returns `true` when `axPoint` lies inside the window's native top titlebar band,
    /// preserving the outer `resizeBorder` (top/left/right) for window resizing.
    public static func isInNativeTitlebarBand(
        axPoint: CGPoint,
        windowAXFrame: CGRect,
        titlebarHeight: CGFloat = 38,
        resizeBorder: CGFloat = 5
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
    /// traffic lights, interactive controls (tabs/buttons/inputs), or bare draggable titlebar surface.
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
                return .dragSurface
            }
            return .interactiveControl
        }
        return .dragSurface
    }

    /// Returns the Cocoa screen rect for the top notch-bezel band when `safeAreaTopInset > 1` (e.g. 38pt on notched MacBook Pro displays).
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
        return CGRect(
            x: screenFrameCocoa.minX,
            y: screenFrameCocoa.maxY - safeAreaTopInset,
            width: screenFrameCocoa.width,
            height: safeAreaTopInset
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
        let workMaxY = (safeAreaTopInset >= barHeight) ? maxVisibleTop : (maxVisibleTop - barHeight)
        let workHeight = max(120, workMaxY - workMinY)

        if cocoa.maxY > workMaxY + 1.0 {
            return true
        }
        if cocoa.minY < workMinY - 1.0 && (cocoa.maxY >= workMaxY - 40 || cocoa.height >= workHeight - 12) {
            return true
        }
        return false
    }
}
