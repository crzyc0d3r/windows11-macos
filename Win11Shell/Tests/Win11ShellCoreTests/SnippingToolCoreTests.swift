import CoreGraphics
import Foundation
import Testing
@testable import Win11ShellCore

@Suite("Snipping Tool Core Tests")
struct SnippingToolCoreTests {
    @Test("normalizedSelectionRect handles all drag directions and clamps to overlay bounds")
    func normalizedSelectionRectTests() {
        let bounds = CGRect(x: 0, y: 0, width: 1800, height: 1169)

        // Forward drag
        let r1 = SnippingGeometry.normalizedSelectionRect(
            from: CGPoint(x: 100, y: 120),
            to: CGPoint(x: 500, y: 420),
            clampedTo: bounds
        )
        #expect(r1 == CGRect(x: 100, y: 120, width: 400, height: 300))

        // Reverse drag + out-of-bounds clamping
        let r2 = SnippingGeometry.normalizedSelectionRect(
            from: CGPoint(x: 600, y: 500),
            to: CGPoint(x: -50, y: -20),
            clampedTo: bounds
        )
        #expect(r2 == CGRect(x: 0, y: 0, width: 600, height: 500))

        // Clamp upper edge
        let r3 = SnippingGeometry.normalizedSelectionRect(
            from: CGPoint(x: 1600, y: 1000),
            to: CGPoint(x: 1950, y: 1300),
            clampedTo: bounds
        )
        #expect(r3 == CGRect(x: 1600, y: 1000, width: 200, height: 169))
    }

    @Test("pixelCropRect scales Retina view selections cleanly and rejects tiny drags")
    func pixelCropRectTests() {
        let viewSize = CGSize(width: 1800, height: 1169)
        let imagePixels = CGSize(width: 3600, height: 2338)

        let crop = SnippingGeometry.pixelCropRect(
            selectionInViewPoints: CGRect(x: 100, y: 50, width: 400, height: 250),
            viewSize: viewSize,
            imagePixelSize: imagePixels
        )
        #expect(crop == CGRect(x: 200, y: 100, width: 800, height: 500))

        // Sub-2px selection rejected
        let tiny = SnippingGeometry.pixelCropRect(
            selectionInViewPoints: CGRect(x: 10, y: 10, width: 0.4, height: 0.4),
            viewSize: viewSize,
            imagePixelSize: imagePixels
        )
        #expect(tiny == .zero)

        // Clamped cleanly when slightly past view edge
        let clamped = SnippingGeometry.pixelCropRect(
            selectionInViewPoints: CGRect(x: 1700, y: 1100, width: 200, height: 100),
            viewSize: viewSize,
            imagePixelSize: imagePixels
        )
        #expect(clamped == CGRect(x: 3400, y: 2200, width: 200, height: 138))
    }

    @Test("freeformBoundingRect encloses lasso path and clamps to bounds")
    func freeformBoundingRectTests() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let pts = [
            CGPoint(x: 120, y: 200),
            CGPoint(x: 340, y: 90),
            CGPoint(x: 410, y: 310),
            CGPoint(x: -10, y: 250)
        ]
        let rect = SnippingGeometry.freeformBoundingRect(points: pts, clampedTo: bounds)
        #expect(rect == CGRect(x: 0, y: 90, width: 410, height: 220))
        #expect(SnippingGeometry.freeformBoundingRect(points: [], clampedTo: bounds) == .zero)
    }

    @Test("defaultScreenshotFilename and defaultScreenshotsDirectory format cleanly")
    func namingAndDirectoryTests() {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 11
        comps.day = 27
        comps.hour = 14
        comps.minute = 5
        comps.second = 9
        let tz = TimeZone(secondsFromGMT: 0)!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let date = cal.date(from: comps)!

        let name = SnippingGeometry.defaultScreenshotFilename(date: date, timeZone: tz)
        #expect(name == "Screenshot 2026-11-27 140509.png")

        let dir = SnippingGeometry.defaultScreenshotsDirectory(homeDirectory: URL(fileURLWithPath: "/Users/alice", isDirectory: true))
        #expect(dir.path == "/Users/alice/Pictures/Screenshots")
    }

    @Test("SnipAnnotationHistory supports append, undo, redo, redo clearing, and proximity erase")
    func annotationHistoryTests() {
        var history = SnipAnnotationHistory()
        #expect(!history.canUndo)
        #expect(!history.canRedo)

        let stroke = SnipAnnotation(
            kind: .pen(points: [CGPoint(x: 10, y: 10), CGPoint(x: 100, y: 10)]),
            color: .red,
            lineWidth: 4
        )
        let rect = SnipAnnotation(
            kind: .rectangle(rect: CGRect(x: 200, y: 200, width: 120, height: 80)),
            color: .blue,
            lineWidth: 3
        )

        history.append(stroke)
        history.append(rect)
        #expect(history.annotations.count == 2)
        #expect(history.canUndo)

        // Erase hit near rectangle border
        let didErase = history.erase(near: CGPoint(x: 203, y: 240), tolerance: 8)
        #expect(didErase)
        #expect(history.annotations.count == 1)
        #expect(history.annotations[0].id == stroke.id)

        // Undo restores rectangle
        let didUndo = history.undo()
        #expect(didUndo)
        #expect(history.annotations.count == 2)
        #expect(history.canRedo)

        // Redo re-applies erase
        let didRedo = history.redo()
        #expect(didRedo)
        #expect(history.annotations.count == 1)

        // New append clears redo stack
        let arrow = SnipAnnotation(
            kind: .arrow(start: CGPoint(x: 50, y: 50), end: CGPoint(x: 120, y: 120)),
            color: .green,
            lineWidth: 4
        )
        history.append(arrow)
        #expect(!history.canRedo)
        #expect(history.annotations.count == 2)

        // Miss erase does nothing
        let missed = history.erase(near: CGPoint(x: 700, y: 700), tolerance: 10)
        #expect(!missed)
        #expect(history.annotations.count == 2)
    }
}
