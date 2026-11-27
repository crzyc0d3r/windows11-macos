import CoreGraphics
import Foundation

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
    /// reserving `barHeight` at the top (respecting notch/safe visibleFrame maxY) and `taskbarHeight` at the bottom.
    public static func maximizedAXFrame(
        forScreenFrameCocoa screenFrameCocoa: CGRect,
        visibleFrameCocoa: CGRect,
        primaryScreenHeight: CGFloat,
        barHeight: CGFloat,
        taskbarHeight: CGFloat
    ) -> CGRect {
        let topLimitCocoa = min(visibleFrameCocoa.maxY, screenFrameCocoa.maxY) - barHeight
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
}
