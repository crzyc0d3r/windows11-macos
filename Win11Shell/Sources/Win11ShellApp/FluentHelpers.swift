import AppKit
import SwiftUI

public struct AcrylicBackground: NSViewRepresentable {
    public var material: NSVisualEffectView.Material
    public var blendingMode: NSVisualEffectView.BlendingMode

    public init(
        material: NSVisualEffectView.Material = .hudWindow,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    ) {
        self.material = material
        self.blendingMode = blendingMode
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

public struct Win11LogoGlyph: View {
    public var size: CGFloat = 18

    public init(size: CGFloat = 18) {
        self.size = size
    }

    public var body: some View {
        let pane = (size - 2) / 2
        VStack(spacing: 2) {
            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color(red: 0.30, green: 0.72, blue: 0.99))
                    .frame(width: pane, height: pane)
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color(red: 0.24, green: 0.65, blue: 0.96))
                    .frame(width: pane, height: pane)
            }
            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color(red: 0.16, green: 0.56, blue: 0.92))
                    .frame(width: pane, height: pane)
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color(red: 0.08, green: 0.46, blue: 0.85))
                    .frame(width: pane, height: pane)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Custom NSPanel that allows text fields inside borderless panels (like Start Menu search) to become key window.
public final class FocusableFloatingPanel: NSPanel {
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
}

/// Non-activating NSPanel used for the per-window menu bar, Taskbar, and hover previews
/// so clicking buttons never steals focus away from the active app window unless desired.
public final class NonActivatingFloatingPanel: NSPanel {
    public var allowsNotchAreaPlacement: Bool = false
    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    public override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        allowsNotchAreaPlacement ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}

@MainActor
public enum AppIconCache {
    private static var cache: [String: NSImage] = [:]

    public static func icon(forBundleID bundleID: String, url: URL? = nil, size: CGFloat = 32) -> NSImage {
        let key = "\(bundleID)-\(Int(size))"
        if let hit = cache[key] {
            return hit
        }

        let resolvedURL = url ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let img: NSImage
        if let resolvedURL {
            img = NSWorkspace.shared.icon(forFile: resolvedURL.path)
        } else {
            img = NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil) ?? NSImage()
        }
        img.size = NSSize(width: size, height: size)
        cache[key] = img
        return img
    }
}

public enum Win11IconRenderer {
    public static func renderAppIconPNG(to url: URL, size: Int = 1024) throws {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = NSSize(width: size, height: size)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        let inset = CGFloat(size) * 0.06
        let bgRect = rect.insetBy(dx: inset, dy: inset)
        let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: CGFloat(size) * 0.22, yRadius: CGFloat(size) * 0.22)

        let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.07, green: 0.14, blue: 0.29, alpha: 1),
            NSColor(calibratedRed: 0.04, green: 0.08, blue: 0.18, alpha: 1)
        ])!
        gradient.draw(in: bgPath, angle: -45)

        let gridSize = CGFloat(size) * 0.50
        let gap = CGFloat(size) * 0.035
        let tile = (gridSize - gap) / 2
        let originX = (CGFloat(size) - gridSize) / 2
        let originY = (CGFloat(size) - gridSize) / 2
        let corner = tile * 0.14

        let colors: [(CGFloat, CGFloat, NSColor)] = [
            (originX, originY + tile + gap, NSColor(calibratedRed: 0.35, green: 0.78, blue: 1.0, alpha: 1)),
            (originX + tile + gap, originY + tile + gap, NSColor(calibratedRed: 0.24, green: 0.67, blue: 0.98, alpha: 1)),
            (originX, originY, NSColor(calibratedRed: 0.15, green: 0.55, blue: 0.94, alpha: 1)),
            (originX + tile + gap, originY, NSColor(calibratedRed: 0.07, green: 0.43, blue: 0.84, alpha: 1))
        ]

        for (x, y, color) in colors {
            let tileRect = NSRect(x: x, y: y, width: tile, height: tile)
            color.setFill()
            NSBezierPath(roundedRect: tileRect, xRadius: corner, yRadius: corner).fill()
        }

        NSGraphicsContext.restoreGraphicsState()

        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "Win11IconRenderer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pngData.write(to: url, options: .atomic)
    }
}
