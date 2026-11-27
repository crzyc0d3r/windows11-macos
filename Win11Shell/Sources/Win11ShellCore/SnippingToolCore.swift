import CoreGraphics
import Foundation

public enum SnipOutputKind: String, CaseIterable, Equatable, Sendable {
    case photo
    case video

    public var displayTitle: String {
        switch self {
        case .photo: "Snip"
        case .video: "Record"
        }
    }

    public var systemSymbolName: String {
        switch self {
        case .photo: "camera"
        case .video: "video"
        }
    }
}

public enum SnipCaptureMode: String, CaseIterable, Equatable, Sendable {
    case rectangle
    case window
    case fullscreen
    case freeform

    public static func supportedModes(for outputKind: SnipOutputKind) -> [SnipCaptureMode] {
        switch outputKind {
        case .photo:
            return [.rectangle, .window, .fullscreen, .freeform]
        case .video:
            return [.rectangle, .window, .fullscreen]
        }
    }

    public var displayTitle: String {
        switch self {
        case .rectangle: "Rectangle"
        case .window: "Window"
        case .fullscreen: "Fullscreen"
        case .freeform: "Freeform"
        }
    }

    public var systemSymbolName: String {
        switch self {
        case .rectangle: "rectangle.dashed"
        case .window: "macwindow"
        case .fullscreen: "rectangle.inset.filled"
        case .freeform: "lasso"
        }
    }
}

public enum SnipDelayOption: Int, CaseIterable, Equatable, Sendable {
    case none = 0
    case threeSeconds = 3
    case fiveSeconds = 5

    public var shortLabel: String {
        switch self {
        case .none: "No delay"
        case .threeSeconds: "3s"
        case .fiveSeconds: "5s"
        }
    }

    public var next: SnipDelayOption {
        switch self {
        case .none: .threeSeconds
        case .threeSeconds: .fiveSeconds
        case .fiveSeconds: .none
        }
    }
}

public enum SnipToolKind: String, CaseIterable, Equatable, Sendable {
    case pen
    case highlighter
    case arrow
    case rectangle
    case text
    case eraser
    case crop

    public var displayTitle: String {
        switch self {
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .arrow: "Arrow"
        case .rectangle: "Shape"
        case .text: "Text"
        case .eraser: "Eraser"
        case .crop: "Crop"
        }
    }

    public var systemSymbolName: String {
        switch self {
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .text: "textformat"
        case .eraser: "eraser"
        case .crop: "crop"
        }
    }
}

public struct SnipColorRGB: Equatable, Hashable, Sendable {
    public let r: Double
    public let g: Double
    public let b: Double
    public let a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1.0) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public static let red = SnipColorRGB(r: 0.96, g: 0.26, b: 0.24)
    public static let blue = SnipColorRGB(r: 0.0, g: 0.62, b: 1.0)
    public static let green = SnipColorRGB(r: 0.16, g: 0.80, b: 0.44)
    public static let yellow = SnipColorRGB(r: 1.0, g: 0.84, b: 0.12)
    public static let white = SnipColorRGB(r: 0.98, g: 0.98, b: 0.99)
    public static let black = SnipColorRGB(r: 0.08, g: 0.08, b: 0.10)

    public static let penPresets: [SnipColorRGB] = [.red, .blue, .green, .yellow, .white, .black]
    public static let highlighterPresets: [SnipColorRGB] = [
        SnipColorRGB(r: 1.0, g: 0.92, b: 0.15, a: 0.42),
        SnipColorRGB(r: 0.25, g: 0.90, b: 0.45, a: 0.40),
        SnipColorRGB(r: 0.20, g: 0.80, b: 1.0, a: 0.40),
        SnipColorRGB(r: 1.0, g: 0.40, b: 0.72, a: 0.42)
    ]
}

public enum SnipAnnotationKind: Equatable, Sendable {
    case pen(points: [CGPoint])
    case highlighter(points: [CGPoint])
    case arrow(start: CGPoint, end: CGPoint)
    case rectangle(rect: CGRect)
    case text(origin: CGPoint, text: String, fontSize: CGFloat)
}

public struct SnipAnnotation: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: SnipAnnotationKind
    public let color: SnipColorRGB
    public let lineWidth: CGFloat

    public init(
        id: UUID = UUID(),
        kind: SnipAnnotationKind,
        color: SnipColorRGB,
        lineWidth: CGFloat
    ) {
        self.id = id
        self.kind = kind
        self.color = color
        self.lineWidth = lineWidth
    }
}

public struct SnipAnnotationHistory: Equatable, Sendable {
    public private(set) var annotations: [SnipAnnotation] = []
    private var undoStack: [[SnipAnnotation]] = []
    private var redoStack: [[SnipAnnotation]] = []

    public init(annotations: [SnipAnnotation] = []) {
        self.annotations = annotations
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public mutating func append(_ annotation: SnipAnnotation) {
        undoStack.append(annotations)
        annotations.append(annotation)
        redoStack.removeAll()
    }

    @discardableResult
    public mutating func erase(near point: CGPoint, tolerance: CGFloat = 10) -> Bool {
        for idx in annotations.indices.reversed() {
            if SnippingGeometry.annotationHitTest(annotations[idx], point: point, tolerance: tolerance) {
                undoStack.append(annotations)
                annotations.remove(at: idx)
                redoStack.removeAll()
                return true
            }
        }
        return false
    }

    @discardableResult
    public mutating func undo() -> Bool {
        guard let previous = undoStack.popLast() else {
            return false
        }
        redoStack.append(annotations)
        annotations = previous
        return true
    }

    @discardableResult
    public mutating func redo() -> Bool {
        guard let next = redoStack.popLast() else {
            return false
        }
        undoStack.append(annotations)
        annotations = next
        return true
    }

    public mutating func clear() {
        guard !annotations.isEmpty else { return }
        undoStack.append(annotations)
        annotations.removeAll()
        redoStack.removeAll()
    }

    public mutating func resetAll() {
        annotations.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
    }
}

public enum SnippingGeometry {
    public static func normalizedSelectionRect(
        from start: CGPoint,
        to end: CGPoint,
        clampedTo bounds: CGRect
    ) -> CGRect {
        let minX = max(bounds.minX, min(start.x, end.x))
        let maxX = min(bounds.maxX, max(start.x, end.x))
        let minY = max(bounds.minY, min(start.y, end.y))
        let maxY = min(bounds.maxY, max(start.y, end.y))
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    public static func pixelCropRect(
        selectionInViewPoints selection: CGRect,
        viewSize: CGSize,
        imagePixelSize: CGSize
    ) -> CGRect {
        guard viewSize.width > 0, viewSize.height > 0,
              imagePixelSize.width > 0, imagePixelSize.height > 0
        else {
            return .zero
        }
        let scaleX = imagePixelSize.width / viewSize.width
        let scaleY = imagePixelSize.height / viewSize.height

        let rawMinX = floor(selection.minX * scaleX)
        let rawMinY = floor(selection.minY * scaleY)
        let rawMaxX = ceil(selection.maxX * scaleX)
        let rawMaxY = ceil(selection.maxY * scaleY)

        let minX = max(0, min(imagePixelSize.width, rawMinX))
        let minY = max(0, min(imagePixelSize.height, rawMinY))
        let maxX = max(minX, min(imagePixelSize.width, rawMaxX))
        let maxY = max(minY, min(imagePixelSize.height, rawMaxY))

        let w = maxX - minX
        let h = maxY - minY
        guard w >= 2, h >= 2 else {
            return .zero
        }
        return CGRect(x: minX, y: minY, width: w, height: h)
    }

    public static func freeformBoundingRect(
        points: [CGPoint],
        clampedTo bounds: CGRect
    ) -> CGRect {
        guard let first = points.first else {
            return .zero
        }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x)
            maxX = max(maxX, p.x)
            minY = min(minY, p.y)
            maxY = max(maxY, p.y)
        }
        let clampedMinX = max(bounds.minX, minX)
        let clampedMaxX = min(bounds.maxX, maxX)
        let clampedMinY = max(bounds.minY, minY)
        let clampedMaxY = min(bounds.maxY, maxY)
        return CGRect(
            x: clampedMinX,
            y: clampedMinY,
            width: max(0, clampedMaxX - clampedMinX),
            height: max(0, clampedMaxY - clampedMinY)
        )
    }

    public static func distanceFromPointToSegment(
        point p: CGPoint,
        a: CGPoint,
        b: CGPoint
    ) -> CGFloat {
        let abX = b.x - a.x
        let abY = b.y - a.y
        let lenSq = abX * abX + abY * abY
        if lenSq <= 0.0001 {
            return hypot(p.x - a.x, p.y - a.y)
        }
        let t = max(0, min(1, ((p.x - a.x) * abX + (p.y - a.y) * abY) / lenSq))
        let projX = a.x + t * abX
        let projY = a.y + t * abY
        return hypot(p.x - projX, p.y - projY)
    }

    public static func annotationHitTest(
        _ annotation: SnipAnnotation,
        point: CGPoint,
        tolerance: CGFloat
    ) -> Bool {
        let threshold = max(tolerance, annotation.lineWidth * 0.65)
        switch annotation.kind {
        case .pen(let points), .highlighter(let points):
            guard !points.isEmpty else { return false }
            if points.count == 1 {
                return hypot(point.x - points[0].x, point.y - points[0].y) <= threshold
            }
            for i in 0..<(points.count - 1) {
                if distanceFromPointToSegment(point: point, a: points[i], b: points[i + 1]) <= threshold {
                    return true
                }
            }
            return false

        case .arrow(let start, let end):
            return distanceFromPointToSegment(point: point, a: start, b: end) <= threshold

        case .rectangle(let rect):
            let r = rect.standardized
            let tl = CGPoint(x: r.minX, y: r.minY)
            let tr = CGPoint(x: r.maxX, y: r.minY)
            let br = CGPoint(x: r.maxX, y: r.maxY)
            let bl = CGPoint(x: r.minX, y: r.maxY)
            return distanceFromPointToSegment(point: point, a: tl, b: tr) <= threshold
                || distanceFromPointToSegment(point: point, a: tr, b: br) <= threshold
                || distanceFromPointToSegment(point: point, a: br, b: bl) <= threshold
                || distanceFromPointToSegment(point: point, a: bl, b: tl) <= threshold

        case .text(let origin, let text, let fontSize):
            let box = estimatedTextBoundingRect(origin: origin, text: text, fontSize: fontSize)
            return box.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    public static func estimatedTextBoundingRect(
        origin: CGPoint,
        text: String,
        fontSize: CGFloat
    ) -> CGRect {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let lineCount = max(1, lines.count)
        let maxChars = max(1, lines.map(\.count).max() ?? 1)
        let width = max(fontSize * 1.2, CGFloat(maxChars) * fontSize * 0.62)
        let height = CGFloat(lineCount) * fontSize * 1.28
        return CGRect(x: origin.x, y: origin.y, width: width, height: height)
    }

    public static func defaultScreenshotFilename(
        date: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = timeZone
        fmt.dateFormat = "yyyy-MM-dd HHmmss"
        return "Screenshot \(fmt.string(from: date)).png"
    }

    public static func defaultScreenshotsDirectory(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent("Pictures", isDirectory: true)
            .appendingPathComponent("Screenshots", isDirectory: true)
    }

    public static func defaultRecordingFilename(
        date: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = timeZone
        fmt.dateFormat = "yyyy-MM-dd HHmmss"
        return "Recording \(fmt.string(from: date)).mp4"
    }

    public static func defaultRecordingsDirectory(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent("Movies", isDirectory: true)
            .appendingPathComponent("Screen Recordings", isDirectory: true)
    }

    public static func formatRecordingDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    public static func evenPixelDimension(_ value: CGFloat, minimum: Int = 16) -> Int {
        let roundedEven = (Int(value.rounded()) / 2) * 2
        let minEven = (max(2, minimum) % 2 == 0) ? max(2, minimum) : max(2, minimum) + 1
        return max(minEven, roundedEven)
    }
}
