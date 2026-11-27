import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum AppIconRendererError: Error, LocalizedError {
    case invalidSize(Int)
    case graphicsContextCreationFailed
    case imageCreationFailed
    case destinationCreationFailed(URL)
    case pngWriteFailed(URL)

    public var errorDescription: String? {
        switch self {
        case .invalidSize(let size):
            return "Invalid app icon size: \(size). Expected positive integer."
        case .graphicsContextCreationFailed:
            return "Failed to create CGContext for app icon rendering."
        case .imageCreationFailed:
            return "Failed to materialize CGImage from CGContext."
        case .destinationCreationFailed(let url):
            return "Failed to create PNG image destination at \(url.path)."
        case .pngWriteFailed(let url):
            return "Failed to finalize PNG write at \(url.path)."
        }
    }
}

/// Renders the iconic Windows 11 File Explorer app icon
/// (warm golden Fluent folder with blue front clasp strap) to PNG.
public enum AppIconRenderer {
    public static func renderAppIconPNG(to url: URL, size: Int = 1024) throws {
        guard size > 0 else {
            throw AppIconRendererError.invalidSize(size)
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw AppIconRendererError.graphicsContextCreationFailed
        }

        // Flip to top-down coordinate space and scale normalized 100x100 canvas to `size`.
        let scale = CGFloat(size) / 100.0
        ctx.translateBy(x: 0, y: CGFloat(size))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.interpolationQuality = .high
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)

        drawExplorerIcon(in: ctx, colorSpace: colorSpace)

        guard let cgImage = ctx.makeImage() else {
            throw AppIconRendererError.imageCreationFailed
        }

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw AppIconRendererError.destinationCreationFailed(url)
        }

        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw AppIconRendererError.pngWriteFailed(url)
        }
    }

    private static func drawExplorerIcon(in ctx: CGContext, colorSpace: CGColorSpace) {
        // 1. Back golden folder plate with top-left rounded tab
        let backPath = CGMutablePath()
        backPath.move(to: CGPoint(x: 13, y: 14))
        backPath.addLine(to: CGPoint(x: 37, y: 14))
        backPath.addCurve(
            to: CGPoint(x: 50, y: 23),
            control1: CGPoint(x: 42, y: 14),
            control2: CGPoint(x: 45, y: 23)
        )
        backPath.addLine(to: CGPoint(x: 87, y: 23))
        backPath.addQuadCurve(to: CGPoint(x: 94, y: 30), control: CGPoint(x: 94, y: 23))
        backPath.addLine(to: CGPoint(x: 94, y: 79))
        backPath.addQuadCurve(to: CGPoint(x: 87, y: 86), control: CGPoint(x: 94, y: 86))
        backPath.addLine(to: CGPoint(x: 13, y: 86))
        backPath.addQuadCurve(to: CGPoint(x: 6, y: 79), control: CGPoint(x: 6, y: 86))
        backPath.addLine(to: CGPoint(x: 6, y: 21))
        backPath.addQuadCurve(to: CGPoint(x: 13, y: 14), control: CGPoint(x: 6, y: 14))
        backPath.closeSubpath()

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2.2), blur: 4.0, color: cgColor(0x000000, alpha: 0.22, space: colorSpace))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.addPath(backPath)
        ctx.clip()
        drawLinearGradient(
            in: ctx,
            colorSpace: colorSpace,
            colors: [cgColor(0xE6A21D, space: colorSpace), cgColor(0xD89314, space: colorSpace)],
            locations: [0.0, 1.0],
            start: CGPoint(x: 50, y: 14),
            end: CGPoint(x: 50, y: 86)
        )
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        // 2. Subtle crisp white paper sheet peeking from inside
        let sheetRect = CGRect(x: 16, y: 25.5, width: 68, height: 18)
        let sheetPath = CGPath(roundedRect: sheetRect, cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)
        ctx.saveGState()
        ctx.addPath(sheetPath)
        ctx.setFillColor(cgColor(0xFFFFFF, space: colorSpace))
        ctx.fillPath()
        ctx.restoreGState()

        // 3. Front golden folder flap
        let frontRect = CGRect(x: 6, y: 31, width: 88, height: 55)
        let frontPath = CGPath(roundedRect: frontRect, cornerWidth: 7, cornerHeight: 7, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2.0), blur: 3.5, color: cgColor(0x000000, alpha: 0.24, space: colorSpace))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.addPath(frontPath)
        ctx.clip()
        drawLinearGradient(
            in: ctx,
            colorSpace: colorSpace,
            colors: [
                cgColor(0xFFE680, space: colorSpace),
                cgColor(0xF7BE34, space: colorSpace),
                cgColor(0xECA21A, space: colorSpace)
            ],
            locations: [0.0, 0.45, 1.0],
            start: CGPoint(x: 50, y: 31),
            end: CGPoint(x: 50, y: 86)
        )
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        // Top specular rim on front flap
        ctx.saveGState()
        ctx.setStrokeColor(cgColor(0xFFF6C4, alpha: 0.78, space: colorSpace))
        ctx.setLineWidth(1.8)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: 11, y: 32.2))
        ctx.addLine(to: CGPoint(x: 89, y: 32.2))
        ctx.strokePath()
        ctx.restoreGState()

        // Bottom warm amber edge
        ctx.saveGState()
        ctx.setStrokeColor(cgColor(0xC27C0A, alpha: 0.65, space: colorSpace))
        ctx.setLineWidth(1.4)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: 11, y: 85.2))
        ctx.addLine(to: CGPoint(x: 89, y: 85.2))
        ctx.strokePath()
        ctx.restoreGState()

        // 4. Iconic Windows 11 File Explorer blue front clasp strap
        let strapFootRect = CGRect(x: 34, y: 74, width: 32, height: 14.5)
        let strapFootPath = CGPath(roundedRect: strapFootRect, cornerWidth: 4.5, cornerHeight: 4.5, transform: nil)
        ctx.saveGState()
        ctx.addPath(strapFootPath)
        ctx.clip()
        drawLinearGradient(
            in: ctx,
            colorSpace: colorSpace,
            colors: [cgColor(0x004E8C, space: colorSpace), cgColor(0x003766, space: colorSpace)],
            locations: [0.0, 1.0],
            start: CGPoint(x: 50, y: 74),
            end: CGPoint(x: 50, y: 88.5)
        )
        ctx.restoreGState()

        let claspRect = CGRect(x: 38.5, y: 55.5, width: 23, height: 32.5)
        let claspPath = CGPath(roundedRect: claspRect, cornerWidth: 5.5, cornerHeight: 5.5, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 2.5, color: cgColor(0x000000, alpha: 0.25, space: colorSpace))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.addPath(claspPath)
        ctx.clip()
        drawLinearGradient(
            in: ctx,
            colorSpace: colorSpace,
            colors: [
                cgColor(0x50E6FF, space: colorSpace),
                cgColor(0x0078D4, space: colorSpace),
                cgColor(0x005A9E, space: colorSpace)
            ],
            locations: [0.0, 0.35, 1.0],
            start: CGPoint(x: 50, y: 55.5),
            end: CGPoint(x: 50, y: 88.0)
        )
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        // Crisp subtle top specular highlight on blue clasp
        ctx.saveGState()
        ctx.setStrokeColor(cgColor(0xB8F3FF, alpha: 0.65, space: colorSpace))
        ctx.setLineWidth(1.2)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: 42.5, y: 56.6))
        ctx.addLine(to: CGPoint(x: 57.5, y: 56.6))
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func cgColor(_ hex: UInt32, alpha: CGFloat = 1.0, space: CGColorSpace) -> CGColor {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        return CGColor(colorSpace: space, components: [r, g, b, alpha]) ?? CGColor(red: r, green: g, blue: b, alpha: alpha)
    }

    private static func drawLinearGradient(
        in ctx: CGContext,
        colorSpace: CGColorSpace,
        colors: [CGColor],
        locations: [CGFloat],
        start: CGPoint,
        end: CGPoint
    ) {
        guard let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: colors as CFArray,
            locations: locations
        ) else {
            return
        }
        ctx.drawLinearGradient(gradient, start: start, end: end, options: [])
    }
}
