import FileExplorerCore
import SwiftUI

/// Pure SwiftUI vector artwork catalog matching Windows 11 24H2 Fluent icons.
struct FluentIconCatalogView: View {
    let kind: FluentIconKind
    let isDark: Bool

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let side = min(size.width, size.height)
            guard side > 0 else { return }
            let dx = (size.width - side) * 0.5
            let dy = (size.height - side) * 0.5
            var ctx = context
            ctx.translateBy(x: dx, y: dy)
            let scale = side / 100.0
            ctx.scaleBy(x: scale, y: scale)
            draw(kind: kind, in: &ctx)
        }
    }

    // MARK: - Dispatch

    private func draw(kind: FluentIconKind, in ctx: inout GraphicsContext) {
        switch kind {
        case .folder:
            drawGoldenFolder(in: &ctx, populated: false)
        case .folderPopulated:
            drawGoldenFolder(in: &ctx, populated: true)
        case .home:
            drawHome(in: &ctx)
        case .gallery:
            drawGallery(in: &ctx)
        case .desktop:
            drawDesktop(in: &ctx)
        case .downloads:
            drawDownloads(in: &ctx)
        case .documents:
            drawDocuments(in: &ctx)
        case .pictures:
            drawPictures(in: &ctx)
        case .music:
            drawMusic(in: &ctx)
        case .videos:
            drawVideos(in: &ctx)
        case .applications:
            drawApplications(in: &ctx)
        case .thisPC:
            drawThisPC(in: &ctx)
        case .hardDrive:
            drawHardDrive(in: &ctx)
        case .externalDrive:
            drawExternalDrive(in: &ctx)
        case .networkDrive:
            drawNetworkDrive(in: &ctx)
        case .cloudDrive:
            drawCloudDrive(in: &ctx)
        case .recycleBinEmpty:
            drawRecycleBin(in: &ctx, isFull: false)
        case .recycleBinFull:
            drawRecycleBin(in: &ctx, isFull: true)
        case .symlinkBadge:
            drawSymlinkBadge(in: &ctx, rect: CGRect(x: 12, y: 12, width: 76, height: 76))
        case .fileKind(let fileKind):
            drawFileKind(fileKind, in: &ctx)
        }
    }

    // MARK: - Iconic Windows 11 Golden-Yellow Folder

    private func drawGoldenFolder(in ctx: inout GraphicsContext, populated: Bool) {
        drawFolderShell(
            in: &ctx,
            backTop: Color(fluentHex: 0xE6A21D),
            backBottom: Color(fluentHex: 0xD89314),
            frontTop: Color(fluentHex: 0xFFE680),
            frontMid: Color(fluentHex: 0xF7BE34),
            frontBottom: Color(fluentHex: 0xECA21A),
            specularColor: Color(fluentHex: 0xFFF6C4, opacity: 0.72),
            bottomRimColor: Color(fluentHex: 0xC47E0C, opacity: 0.65),
            populated: populated
        )
    }

    private func drawFolderShell(
        in ctx: inout GraphicsContext,
        backTop: Color,
        backBottom: Color,
        frontTop: Color,
        frontMid: Color,
        frontBottom: Color,
        specularColor: Color,
        bottomRimColor: Color,
        populated: Bool
    ) {
        // Back plate with raised rounded tab on the left
        let backPath = folderBackPath()
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: Color.black.opacity(0.14), radius: 2.5, x: 0, y: 1.5))
            layer.fill(
                backPath,
                with: .linearGradient(
                    Gradient(colors: [backTop, backBottom]),
                    startPoint: CGPoint(x: 50, y: 14),
                    endPoint: CGPoint(x: 50, y: 84)
                )
            )
        }

        // Populated document sheets peeking out from behind the front flap
        if populated {
            let backSheet = Path(roundedRect: CGRect(x: 20, y: 19, width: 58, height: 28), cornerRadius: 3.5)
            ctx.fill(backSheet, with: .color(Color(fluentHex: 0xEEF2F7)))
            ctx.stroke(backSheet, with: .color(Color.black.opacity(0.10)), lineWidth: 1.0)

            let frontSheet = Path(roundedRect: CGRect(x: 15, y: 24, width: 68, height: 28), cornerRadius: 3.5)
            ctx.fill(frontSheet, with: .color(Color.white))
            ctx.stroke(frontSheet, with: .color(Color.black.opacity(0.12)), lineWidth: 1.0)
        }

        // Front flap
        let frontRect = CGRect(x: 6, y: 31, width: 88, height: 55)
        let frontPath = Path(roundedRect: frontRect, cornerRadius: 7)

        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: Color.black.opacity(0.18), radius: 2.2, x: 0, y: 1.8))
            layer.fill(
                frontPath,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: frontTop, location: 0.0),
                        .init(color: frontMid, location: 0.45),
                        .init(color: frontBottom, location: 1.0)
                    ]),
                    startPoint: CGPoint(x: 50, y: 31),
                    endPoint: CGPoint(x: 50, y: 86)
                )
            )
        }

        // Top specular highlight rim
        var topHighlight = Path()
        topHighlight.move(to: CGPoint(x: 11, y: 32.4))
        topHighlight.addLine(to: CGPoint(x: 89, y: 32.4))
        ctx.stroke(topHighlight, with: .color(specularColor), style: StrokeStyle(lineWidth: 2.0, lineCap: .round))

        // Subtle bottom crease rim
        var bottomRim = Path()
        bottomRim.move(to: CGPoint(x: 11, y: 85.0))
        bottomRim.addLine(to: CGPoint(x: 89, y: 85.0))
        ctx.stroke(bottomRim, with: .color(bottomRimColor), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
    }

    private func folderBackPath() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 13, y: 15))
        p.addLine(to: CGPoint(x: 36, y: 15))
        p.addCurve(
            to: CGPoint(x: 49, y: 24),
            control1: CGPoint(x: 41, y: 15),
            control2: CGPoint(x: 44, y: 24)
        )
        p.addLine(to: CGPoint(x: 87, y: 24))
        p.addQuadCurve(to: CGPoint(x: 94, y: 31), control: CGPoint(x: 94, y: 24))
        p.addLine(to: CGPoint(x: 94, y: 78))
        p.addQuadCurve(to: CGPoint(x: 87, y: 85), control: CGPoint(x: 94, y: 85))
        p.addLine(to: CGPoint(x: 13, y: 85))
        p.addQuadCurve(to: CGPoint(x: 6, y: 78), control: CGPoint(x: 6, y: 85))
        p.addLine(to: CGPoint(x: 6, y: 22))
        p.addQuadCurve(to: CGPoint(x: 13, y: 15), control: CGPoint(x: 6, y: 15))
        p.closeSubpath()
        return p
    }

    // MARK: - Special Windows 11 Icons

    private func drawHome(in ctx: inout GraphicsContext) {
        // House body
        var body = Path()
        body.move(to: CGPoint(x: 20, y: 45))
        body.addLine(to: CGPoint(x: 50, y: 20))
        body.addLine(to: CGPoint(x: 80, y: 45))
        body.addLine(to: CGPoint(x: 80, y: 80))
        body.addQuadCurve(to: CGPoint(x: 73, y: 87), control: CGPoint(x: 80, y: 87))
        body.addLine(to: CGPoint(x: 27, y: 87))
        body.addQuadCurve(to: CGPoint(x: 20, y: 80), control: CGPoint(x: 20, y: 87))
        body.closeSubpath()

        ctx.fill(
            body,
            with: .linearGradient(
                Gradient(colors: [Color(fluentHex: 0xE6F4FE), Color(fluentHex: 0xB8DDFB)]),
                startPoint: CGPoint(x: 50, y: 22),
                endPoint: CGPoint(x: 50, y: 87)
            )
        )
        ctx.stroke(body, with: .color(Color(fluentHex: 0x0078D4, opacity: 0.35)), lineWidth: 1.5)

        // Door
        let door = Path(roundedRect: CGRect(x: 41, y: 56, width: 18, height: 31), cornerRadius: 3)
        ctx.fill(
            door,
            with: .linearGradient(
                Gradient(colors: [Color(fluentHex: 0x0078D4), Color(fluentHex: 0x00529B)]),
                startPoint: CGPoint(x: 50, y: 56),
                endPoint: CGPoint(x: 50, y: 87)
            )
        )

        // Roof
        var roof = Path()
        roof.move(to: CGPoint(x: 11, y: 48))
        roof.addLine(to: CGPoint(x: 50, y: 15))
        roof.addLine(to: CGPoint(x: 89, y: 48))
        ctx.stroke(
            roof,
            with: .linearGradient(
                Gradient(colors: [Color(fluentHex: 0x50E6FF), Color(fluentHex: 0x0067C0)]),
                startPoint: CGPoint(x: 15, y: 20),
                endPoint: CGPoint(x: 85, y: 50)
            ),
            style: StrokeStyle(lineWidth: 9.5, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawGallery(in ctx: inout GraphicsContext) {
        // Back tilted card
        var backLayer = ctx
        backLayer.translateBy(x: 50, y: 50)
        backLayer.rotate(by: .degrees(-7))
        backLayer.translateBy(x: -50, y: -50)
        let backRect = Path(roundedRect: CGRect(x: 16, y: 18, width: 68, height: 58), cornerRadius: 7)
        backLayer.fill(backRect, with: .color(Color(fluentHex: 0xB8E5F8)))
        backLayer.stroke(backRect, with: .color(Color(fluentHex: 0x0099BC, opacity: 0.4)), lineWidth: 1.2)

        // Front photo card
        let card = Path(roundedRect: CGRect(x: 16, y: 22, width: 70, height: 60), cornerRadius: 7)
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: Color.black.opacity(0.16), radius: 2, x: 0, y: 1.5))
            layer.fill(
                card,
                with: .linearGradient(
                    Gradient(colors: [Color(fluentHex: 0x50E6FF), Color(fluentHex: 0x0078D4)]),
                    startPoint: CGPoint(x: 20, y: 22),
                    endPoint: CGPoint(x: 80, y: 82)
                )
            )
        }
        ctx.stroke(card, with: .color(Color.white.opacity(0.85)), lineWidth: 2.2)

        // Sun
        let sun = Path(ellipseIn: CGRect(x: 26, y: 31, width: 13, height: 13))
        ctx.fill(sun, with: .color(Color(fluentHex: 0xFFE680)))

        // Mountains
        ctx.drawLayer { clipped in
            clipped.clip(to: card)
            var backMountain = Path()
            backMountain.move(to: CGPoint(x: 34, y: 82))
            backMountain.addLine(to: CGPoint(x: 62, y: 45))
            backMountain.addLine(to: CGPoint(x: 88, y: 82))
            backMountain.closeSubpath()
            clipped.fill(backMountain, with: .color(Color(fluentHex: 0x00B294)))

            var frontMountain = Path()
            frontMountain.move(to: CGPoint(x: 14, y: 82))
            frontMountain.addLine(to: CGPoint(x: 42, y: 50))
            frontMountain.addLine(to: CGPoint(x: 72, y: 82))
            frontMountain.closeSubpath()
            clipped.fill(frontMountain, with: .color(Color(fluentHex: 0x107C10)))
        }
    }

    private func drawDesktop(in ctx: inout GraphicsContext) {
        // Stand
        let neck = Path(roundedRect: CGRect(x: 43, y: 71, width: 14, height: 12), cornerRadius: 2)
        ctx.fill(neck, with: .color(Color(fluentHex: 0x8A94A0)))
        let base = Path(roundedRect: CGRect(x: 30, y: 81, width: 40, height: 6), cornerRadius: 3)
        ctx.fill(base, with: .color(Color(fluentHex: 0x697480)))

        // Bezel
        let bezel = Path(roundedRect: CGRect(x: 8, y: 15, width: 84, height: 59), cornerRadius: 6)
        ctx.fill(bezel, with: .color(Color(fluentHex: 0x2B3038)))

        // Screen
        let screen = Path(roundedRect: CGRect(x: 12, y: 19, width: 76, height: 51), cornerRadius: 3.5)
        ctx.fill(
            screen,
            with: .linearGradient(
                Gradient(colors: [Color(fluentHex: 0x50E6FF), Color(fluentHex: 0x0067C0)]),
                startPoint: CGPoint(x: 15, y: 19),
                endPoint: CGPoint(x: 85, y: 70)
            )
        )

        // Windows 11 Bloom accent + taskbar
        ctx.drawLayer { layer in
            layer.clip(to: screen)
            let bloom = Path(ellipseIn: CGRect(x: 31, y: 27, width: 38, height: 28))
            layer.fill(bloom, with: .color(Color(fluentHex: 0x004E8C, opacity: 0.55)))
            let taskbar = Path(CGRect(x: 12, y: 63, width: 76, height: 7))
            layer.fill(taskbar, with: .color(Color.white.opacity(0.85)))
            let icons = Path(roundedRect: CGRect(x: 38, y: 65, width: 24, height: 3), cornerRadius: 1.5)
            layer.fill(icons, with: .color(Color(fluentHex: 0x0067C0)))
        }
    }

    private func drawDownloads(in ctx: inout GraphicsContext) {
        drawFolderShell(
            in: &ctx,
            backTop: Color(fluentHex: 0x0078D4),
            backBottom: Color(fluentHex: 0x005A9E),
            frontTop: Color(fluentHex: 0x50E6FF),
            frontMid: Color(fluentHex: 0x1D9BF0),
            frontBottom: Color(fluentHex: 0x0078D4),
            specularColor: Color.white.opacity(0.55),
            bottomRimColor: Color(fluentHex: 0x004E8C, opacity: 0.7),
            populated: false
        )

        // Downward arrow
        var arrow = Path()
        arrow.move(to: CGPoint(x: 50, y: 42))
        arrow.addLine(to: CGPoint(x: 50, y: 66))
        arrow.move(to: CGPoint(x: 38, y: 55))
        arrow.addLine(to: CGPoint(x: 50, y: 67))
        arrow.addLine(to: CGPoint(x: 62, y: 55))
        ctx.stroke(arrow, with: .color(.white), style: StrokeStyle(lineWidth: 5.5, lineCap: .round, lineJoin: .round))

        let tray = Path(roundedRect: CGRect(x: 33, y: 72, width: 34, height: 4.5), cornerRadius: 2.2)
        ctx.fill(tray, with: .color(.white))
    }

    private func drawDocuments(in ctx: inout GraphicsContext) {
        drawFolderShell(
            in: &ctx,
            backTop: Color(fluentHex: 0x185ABD),
            backBottom: Color(fluentHex: 0x104391),
            frontTop: Color(fluentHex: 0x5BA4F7),
            frontMid: Color(fluentHex: 0x2B7DE9),
            frontBottom: Color(fluentHex: 0x185ABD),
            specularColor: Color.white.opacity(0.55),
            bottomRimColor: Color(fluentHex: 0x0D3878, opacity: 0.7),
            populated: true
        )

        let line1 = Path(roundedRect: CGRect(x: 31, y: 46, width: 38, height: 4.2), cornerRadius: 2)
        let line2 = Path(roundedRect: CGRect(x: 31, y: 55, width: 38, height: 4.2), cornerRadius: 2)
        let line3 = Path(roundedRect: CGRect(x: 31, y: 64, width: 25, height: 4.2), cornerRadius: 2)
        ctx.fill(line1, with: .color(Color.white.opacity(0.92)))
        ctx.fill(line2, with: .color(Color.white.opacity(0.92)))
        ctx.fill(line3, with: .color(Color.white.opacity(0.92)))
    }

    private func drawPictures(in ctx: inout GraphicsContext) {
        drawFolderShell(
            in: &ctx,
            backTop: Color(fluentHex: 0x008272),
            backBottom: Color(fluentHex: 0x006357),
            frontTop: Color(fluentHex: 0x4CE0D2),
            frontMid: Color(fluentHex: 0x00B7C3),
            frontBottom: Color(fluentHex: 0x008A96),
            specularColor: Color.white.opacity(0.55),
            bottomRimColor: Color(fluentHex: 0x005B63, opacity: 0.7),
            populated: false
        )

        let sun = Path(ellipseIn: CGRect(x: 61, y: 42, width: 10, height: 10))
        ctx.fill(sun, with: .color(Color(fluentHex: 0xFFE680)))

        var mountain = Path()
        mountain.move(to: CGPoint(x: 24, y: 74))
        mountain.addLine(to: CGPoint(x: 42, y: 50))
        mountain.addLine(to: CGPoint(x: 56, y: 64))
        mountain.addLine(to: CGPoint(x: 65, y: 56))
        mountain.addLine(to: CGPoint(x: 78, y: 74))
        mountain.closeSubpath()
        ctx.fill(mountain, with: .color(Color.white.opacity(0.92)))
    }

    private func drawMusic(in ctx: inout GraphicsContext) {
        drawFolderShell(
            in: &ctx,
            backTop: Color(fluentHex: 0x9B2276),
            backBottom: Color(fluentHex: 0x7A175B),
            frontTop: Color(fluentHex: 0xF573C4),
            frontMid: Color(fluentHex: 0xE3008C),
            frontBottom: Color(fluentHex: 0xB4006E),
            specularColor: Color.white.opacity(0.55),
            bottomRimColor: Color(fluentHex: 0x750047, opacity: 0.7),
            populated: false
        )

        var stem = Path()
        stem.move(to: CGPoint(x: 43, y: 68))
        stem.addLine(to: CGPoint(x: 43, y: 45))
        stem.addLine(to: CGPoint(x: 64, y: 41))
        stem.addLine(to: CGPoint(x: 64, y: 64))
        ctx.stroke(stem, with: .color(.white), style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))

        ctx.fill(Path(ellipseIn: CGRect(x: 32, y: 62, width: 13, height: 11)), with: .color(.white))
        ctx.fill(Path(ellipseIn: CGRect(x: 53, y: 58, width: 13, height: 11)), with: .color(.white))
    }

    private func drawVideos(in ctx: inout GraphicsContext) {
        drawFolderShell(
            in: &ctx,
            backTop: Color(fluentHex: 0x5B3EA8),
            backBottom: Color(fluentHex: 0x442B87),
            frontTop: Color(fluentHex: 0xA48DF5),
            frontMid: Color(fluentHex: 0x744DA9),
            frontBottom: Color(fluentHex: 0x5A358C),
            specularColor: Color.white.opacity(0.55),
            bottomRimColor: Color(fluentHex: 0x3D2163, opacity: 0.7),
            populated: false
        )

        var play = Path()
        play.move(to: CGPoint(x: 42, y: 44))
        play.addLine(to: CGPoint(x: 66, y: 58))
        play.addLine(to: CGPoint(x: 42, y: 72))
        play.closeSubpath()
        ctx.fill(play, with: .color(.white))
    }

    private func drawApplications(in ctx: inout GraphicsContext) {
        drawFolderShell(
            in: &ctx,
            backTop: Color(fluentHex: 0x0F54A3),
            backBottom: Color(fluentHex: 0x0A3D78),
            frontTop: Color(fluentHex: 0x4BB4FF),
            frontMid: Color(fluentHex: 0x0078D4),
            frontBottom: Color(fluentHex: 0x005A9E),
            specularColor: Color.white.opacity(0.55),
            bottomRimColor: Color(fluentHex: 0x003D6B, opacity: 0.7),
            populated: false
        )

        let rects = [
            CGRect(x: 35, y: 44, width: 13, height: 13),
            CGRect(x: 52, y: 44, width: 13, height: 13),
            CGRect(x: 35, y: 61, width: 13, height: 13),
            CGRect(x: 52, y: 61, width: 13, height: 13)
        ]
        for r in rects {
            ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(Color.white.opacity(0.92)))
        }
    }

    private func drawThisPC(in ctx: inout GraphicsContext) {
        // Mini tower on right
        let tower = Path(roundedRect: CGRect(x: 67, y: 26, width: 25, height: 57), cornerRadius: 4)
        ctx.fill(
            tower,
            with: .linearGradient(
                Gradient(colors: [Color(fluentHex: 0x4A525D), Color(fluentHex: 0x2B3038)]),
                startPoint: CGPoint(x: 70, y: 26),
                endPoint: CGPoint(x: 92, y: 83)
            )
        )
        ctx.fill(Path(roundedRect: CGRect(x: 72, y: 34, width: 15, height: 3), cornerRadius: 1.5), with: .color(Color(fluentHex: 0x50E6FF)))
        ctx.fill(Path(ellipseIn: CGRect(x: 77, y: 71, width: 5, height: 5)), with: .color(Color(fluentHex: 0x50E6FF)))

        // Monitor stand
        ctx.fill(Path(roundedRect: CGRect(x: 33, y: 68, width: 12, height: 12), cornerRadius: 2), with: .color(Color(fluentHex: 0x9AA5B1)))
        ctx.fill(Path(roundedRect: CGRect(x: 23, y: 78, width: 32, height: 5.5), cornerRadius: 2.5), with: .color(Color(fluentHex: 0x7A8490)))

        // Monitor frame
        let bezel = Path(roundedRect: CGRect(x: 7, y: 18, width: 64, height: 52), cornerRadius: 5)
        ctx.fill(bezel, with: .color(Color(fluentHex: 0x252A30)))

        let screen = Path(roundedRect: CGRect(x: 11, y: 22, width: 56, height: 44), cornerRadius: 3)
        ctx.fill(
            screen,
            with: .linearGradient(
                Gradient(colors: [Color(fluentHex: 0x60CDFF), Color(fluentHex: 0x0067C0)]),
                startPoint: CGPoint(x: 11, y: 22),
                endPoint: CGPoint(x: 67, y: 66)
            )
        )
    }

    private func drawHardDrive(in ctx: inout GraphicsContext) {
        // Metallic SSD/HDD body
        var body = Path()
        body.move(to: CGPoint(x: 18, y: 26))
        body.addLine(to: CGPoint(x: 82, y: 26))
        body.addQuadCurve(to: CGPoint(x: 88, y: 31), control: CGPoint(x: 86, y: 26))
        body.addLine(to: CGPoint(x: 92, y: 62))
        body.addQuadCurve(to: CGPoint(x: 86, y: 68), control: CGPoint(x: 92, y: 68))
        body.addLine(to: CGPoint(x: 14, y: 68))
        body.addQuadCurve(to: CGPoint(x: 8, y: 62), control: CGPoint(x: 8, y: 68))
        body.addLine(to: CGPoint(x: 12, y: 31))
        body.addQuadCurve(to: CGPoint(x: 18, y: 26), control: CGPoint(x: 14, y: 26))
        body.closeSubpath()

        ctx.fill(
            body,
            with: .linearGradient(
                Gradient(colors: [Color(fluentHex: 0xEDF0F4), Color(fluentHex: 0xC4CCD4)]),
                startPoint: CGPoint(x: 50, y: 26),
                endPoint: CGPoint(x: 50, y: 68)
            )
        )
        ctx.stroke(body, with: .color(Color(fluentHex: 0x8D97A3)), lineWidth: 1.4)

        // Front dark faceplate
        let face = Path(roundedRect: CGRect(x: 8, y: 60, width: 84, height: 18), cornerRadius: 5)
        ctx.fill(
            face,
            with: .linearGradient(
                Gradient(colors: [Color(fluentHex: 0x4A525D), Color(fluentHex: 0x2F353D)]),
                startPoint: CGPoint(x: 50, y: 60),
                endPoint: CGPoint(x: 50, y: 78)
            )
        )

        // Vent slot + glowing blue LED
        ctx.fill(Path(roundedRect: CGRect(x: 16, y: 67, width: 42, height: 4), cornerRadius: 2), with: .color(Color(fluentHex: 0x1D2126)))
        ctx.fill(Path(ellipseIn: CGRect(x: 75, y: 66, width: 7, height: 7)), with: .color(Color(fluentHex: 0x50E6FF)))

        // Subtle system drive badge on top surface
        let badgeRects = [
            CGRect(x: 42, y: 36, width: 7, height: 7),
            CGRect(x: 51, y: 36, width: 7, height: 7),
            CGRect(x: 42, y: 45, width: 7, height: 7),
            CGRect(x: 51, y: 45, width: 7, height: 7)
        ]
        for r in badgeRects {
            ctx.fill(Path(roundedRect: r, cornerRadius: 1), with: .color(Color(fluentHex: 0x0078D4, opacity: 0.78)))
        }
    }

    private func drawExternalDrive(in ctx: inout GraphicsContext) {
        // USB connector cap at top
        let usb = Path(roundedRect: CGRect(x: 37, y: 12, width: 26, height: 14), cornerRadius: 3)
        ctx.fill(usb, with: .color(Color(fluentHex: 0xB8C2CC)))
        ctx.fill(Path(CGRect(x: 42, y: 15, width: 5, height: 5)), with: .color(Color(fluentHex: 0x4A525D)))
        ctx.fill(Path(CGRect(x: 53, y: 15, width: 5, height: 5)), with: .color(Color(fluentHex: 0x4A525D)))

        // Portable drive enclosure
        let body = Path(roundedRect: CGRect(x: 20, y: 23, width: 60, height: 65), cornerRadius: 9)
        ctx.fill(
            body,
            with: .linearGradient(
                Gradient(colors: [Color(fluentHex: 0x2B72AA), Color(fluentHex: 0x17456E)]),
                startPoint: CGPoint(x: 50, y: 23),
                endPoint: CGPoint(x: 50, y: 88)
            )
        )
        ctx.stroke(body, with: .color(Color.white.opacity(0.25)), lineWidth: 1.5)

        // Metallic accent strip + LED
        ctx.fill(Path(roundedRect: CGRect(x: 20, y: 67, width: 60, height: 10), cornerRadius: 2), with: .color(Color(fluentHex: 0x0E2F4D)))
        ctx.fill(Path(ellipseIn: CGRect(x: 46, y: 69.5, width: 8, height: 5)), with: .color(Color(fluentHex: 0x50E6FF)))
    }

    private func drawNetworkDrive(in ctx: inout GraphicsContext) {
        // Drive slightly raised
        var driveCtx = ctx
        driveCtx.translateBy(x: 50, y: 36)
        driveCtx.scaleBy(x: 0.78, y: 0.72)
        driveCtx.translateBy(x: -50, y: -48)
        drawHardDrive(in: &driveCtx)

        // Network T-junction pipe
        var pipe = Path()
        pipe.move(to: CGPoint(x: 50, y: 58))
        pipe.addLine(to: CGPoint(x: 50, y: 80))
        pipe.move(to: CGPoint(x: 16, y: 80))
        pipe.addLine(to: CGPoint(x: 84, y: 80))
        ctx.stroke(pipe, with: .color(Color(fluentHex: 0x7A8490)), style: StrokeStyle(lineWidth: 5, lineCap: .round))

        let node = Path(roundedRect: CGRect(x: 38, y: 73, width: 24, height: 14), cornerRadius: 3.5)
        ctx.fill(
            node,
            with: .linearGradient(
                Gradient(colors: [Color(fluentHex: 0x50E6FF), Color(fluentHex: 0x0078D4)]),
                startPoint: CGPoint(x: 38, y: 73),
                endPoint: CGPoint(x: 62, y: 87)
            )
        )
    }

    private func drawCloudDrive(in ctx: inout GraphicsContext) {
        // Back deep blue lobe
        let backCloud = Path(roundedRect: CGRect(x: 10, y: 34, width: 78, height: 42), cornerRadius: 21)
        ctx.fill(backCloud, with: .color(Color(fluentHex: 0x0067C0)))

        let leftPeak = Path(ellipseIn: CGRect(x: 18, y: 21, width: 42, height: 42))
        ctx.fill(leftPeak, with: .color(Color(fluentHex: 0x1890F1)))

        let rightPeak = Path(ellipseIn: CGRect(x: 47, y: 28, width: 34, height: 34))
        ctx.fill(rightPeak, with: .color(Color(fluentHex: 0x28AFE9)))

        // Bright foreground cloud base
        let frontBase = Path(roundedRect: CGRect(x: 14, y: 46, width: 74, height: 31), cornerRadius: 15.5)
        ctx.fill(
            frontBase,
            with: .linearGradient(
                Gradient(colors: [Color(fluentHex: 0x50E6FF), Color(fluentHex: 0x1890F1)]),
                startPoint: CGPoint(x: 20, y: 46),
                endPoint: CGPoint(x: 80, y: 77)
            )
        )
    }

    private func drawRecycleBin(in ctx: inout GraphicsContext, isFull: Bool) {
        if isFull {
            // Crumpled white/blue paper sheets peeking above the rim
            let paper1 = Path(roundedRect: CGRect(x: 25, y: 12, width: 26, height: 22), cornerRadius: 4)
            ctx.fill(paper1, with: .color(Color(fluentHex: 0xE6F2FC)))
            ctx.stroke(paper1, with: .color(Color(fluentHex: 0xB8CDE0)), lineWidth: 1.2)

            let paper2 = Path(roundedRect: CGRect(x: 45, y: 10, width: 28, height: 24), cornerRadius: 4)
            ctx.fill(paper2, with: .color(Color.white))
            ctx.stroke(paper2, with: .color(Color(fluentHex: 0xC8D3DF)), lineWidth: 1.2)
        }

        // Tapered translucent metallic basket
        var bin = Path()
        bin.move(to: CGPoint(x: 19, y: 25))
        bin.addLine(to: CGPoint(x: 81, y: 25))
        bin.addLine(to: CGPoint(x: 73, y: 84))
        bin.addQuadCurve(to: CGPoint(x: 67, y: 89), control: CGPoint(x: 73, y: 89))
        bin.addLine(to: CGPoint(x: 33, y: 89))
        bin.addQuadCurve(to: CGPoint(x: 27, y: 84), control: CGPoint(x: 27, y: 89))
        bin.closeSubpath()

        ctx.fill(
            bin,
            with: .linearGradient(
                Gradient(colors: [Color(fluentHex: 0xE2E8EE), Color(fluentHex: 0xA8B3BE)]),
                startPoint: CGPoint(x: 20, y: 25),
                endPoint: CGPoint(x: 80, y: 89)
            )
        )
        ctx.stroke(bin, with: .color(Color(fluentHex: 0x7A8591)), lineWidth: 1.6)

        // Top rim
        let rim = Path(roundedRect: CGRect(x: 15, y: 20, width: 70, height: 8), cornerRadius: 4)
        ctx.fill(
            rim,
            with: .linearGradient(
                Gradient(colors: [Color(fluentHex: 0xF5F7FA), Color(fluentHex: 0xC6CFD8)]),
                startPoint: CGPoint(x: 50, y: 20),
                endPoint: CGPoint(x: 50, y: 28)
            )
        )
        ctx.stroke(rim, with: .color(Color(fluentHex: 0x8A95A1)), lineWidth: 1.2)

        // Vertical ribs
        for xPos in [36.0, 50.0, 64.0] {
            var rib = Path()
            rib.move(to: CGPoint(x: xPos, y: 34))
            rib.addLine(to: CGPoint(x: 50 + (xPos - 50) * 0.8, y: 80))
            ctx.stroke(rib, with: .color(Color.white.opacity(0.45)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        }

        // Recycle triangular arrows badge
        let badge = Path(ellipseIn: CGRect(x: 36, y: 44, width: 28, height: 28))
        ctx.fill(badge, with: .color(Color(fluentHex: 0x0078D4, opacity: isFull ? 0.92 : 0.78)))
        var tri = Path()
        tri.move(to: CGPoint(x: 50, y: 50))
        tri.addLine(to: CGPoint(x: 57, y: 63))
        tri.addLine(to: CGPoint(x: 43, y: 63))
        tri.closeSubpath()
        ctx.stroke(tri, with: .color(.white), style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
    }

    // MARK: - Windows 11 Document & File-Type Icons

    private func drawFileKind(_ fileKind: FileKind, in ctx: inout GraphicsContext) {
        switch fileKind {
        case .folder:
            drawGoldenFolder(in: &ctx, populated: false)
        case .application:
            drawApplicationIcon(in: &ctx)
        case .archive:
            drawZipArchiveIcon(in: &ctx)
        case .diskImage:
            drawDiskImageIcon(in: &ctx)
        case .pdf:
            drawDocumentBase(in: &ctx)
            drawDocumentBadge(in: &ctx, color: Color(fluentHex: 0xD13438), label: "PDF")
            var wave = Path()
            wave.move(to: CGPoint(x: 30, y: 43))
            wave.addCurve(to: CGPoint(x: 68, y: 45), control1: CGPoint(x: 44, y: 26), control2: CGPoint(x: 52, y: 56))
            ctx.stroke(wave, with: .color(Color(fluentHex: 0xD13438)), style: StrokeStyle(lineWidth: 3.6, lineCap: .round))
        case .document:
            drawDocumentBase(in: &ctx)
            drawDocumentBadge(in: &ctx, color: Color(fluentHex: 0x185ABD), label: "W")
            drawPageLines(in: &ctx, startY: 32, count: 4, color: Color(fluentHex: 0x185ABD, opacity: 0.45))
        case .spreadsheet:
            drawDocumentBase(in: &ctx)
            drawDocumentBadge(in: &ctx, color: Color(fluentHex: 0x107C41), label: "X")
            for row in 0..<2 {
                for col in 0..<2 {
                    let cell = Path(roundedRect: CGRect(x: 31 + col * 18, y: 31 + row * 12, width: 14, height: 9), cornerRadius: 1.5)
                    ctx.fill(cell, with: .color(Color(fluentHex: 0x107C41, opacity: 0.32)))
                }
            }
        case .presentation:
            drawDocumentBase(in: &ctx)
            drawDocumentBadge(in: &ctx, color: Color(fluentHex: 0xC43E1C), label: "P")
            let ring = Path(ellipseIn: CGRect(x: 37, y: 30, width: 24, height: 24))
            ctx.fill(ring, with: .color(Color(fluentHex: 0xC43E1C, opacity: 0.25)))
            var slice = Path()
            slice.move(to: CGPoint(x: 49, y: 42))
            slice.addLine(to: CGPoint(x: 49, y: 30))
            slice.addArc(center: CGPoint(x: 49, y: 42), radius: 12, startAngle: .degrees(-90), endAngle: .degrees(10), clockwise: false)
            slice.closeSubpath()
            ctx.fill(slice, with: .color(Color(fluentHex: 0xC43E1C)))
        case .code:
            drawDocumentBase(in: &ctx)
            drawDocumentBadge(in: &ctx, color: Color(fluentHex: 0x0078D4), label: nil)
            var codeGlyph = Path()
            // <
            codeGlyph.move(to: CGPoint(x: 38, y: 36))
            codeGlyph.addLine(to: CGPoint(x: 29, y: 44))
            codeGlyph.addLine(to: CGPoint(x: 38, y: 52))
            // >
            codeGlyph.move(to: CGPoint(x: 60, y: 36))
            codeGlyph.addLine(to: CGPoint(x: 69, y: 44))
            codeGlyph.addLine(to: CGPoint(x: 60, y: 52))
            // /
            codeGlyph.move(to: CGPoint(x: 52, y: 34))
            codeGlyph.addLine(to: CGPoint(x: 46, y: 54))
            ctx.stroke(codeGlyph, with: .color(Color(fluentHex: 0x0078D4)), style: StrokeStyle(lineWidth: 3.8, lineCap: .round, lineJoin: .round))
        case .json:
            drawDocumentBase(in: &ctx)
            drawDocumentBadge(in: &ctx, color: Color(fluentHex: 0xC9820D), label: "JSON")
            let text = Text("{ }").font(.system(size: 20, weight: .bold, design: .monospaced)).foregroundStyle(Color(fluentHex: 0xC9820D))
            ctx.draw(text, at: CGPoint(x: 49, y: 42))
        case .markdown:
            drawDocumentBase(in: &ctx)
            drawDocumentBadge(in: &ctx, color: Color(fluentHex: 0x3B5998), label: "MD")
            drawPageLines(in: &ctx, startY: 32, count: 3, color: Color(fluentHex: 0x3B5998, opacity: 0.45))
        case .image:
            drawDocumentBase(in: &ctx)
            let frame = Path(roundedRect: CGRect(x: 26, y: 30, width: 46, height: 34), cornerRadius: 3)
            ctx.fill(
                frame,
                with: .linearGradient(
                    Gradient(colors: [Color(fluentHex: 0x50E6FF), Color(fluentHex: 0x0099BC)]),
                    startPoint: CGPoint(x: 26, y: 30),
                    endPoint: CGPoint(x: 72, y: 64)
                )
            )
            ctx.fill(Path(ellipseIn: CGRect(x: 32, y: 35, width: 8, height: 8)), with: .color(Color(fluentHex: 0xFFE680)))
            var hill = Path()
            hill.move(to: CGPoint(x: 26, y: 64))
            hill.addLine(to: CGPoint(x: 46, y: 45))
            hill.addLine(to: CGPoint(x: 60, y: 55))
            hill.addLine(to: CGPoint(x: 72, y: 64))
            hill.closeSubpath()
            ctx.fill(hill, with: .color(Color(fluentHex: 0x107C41)))
            drawDocumentBadge(in: &ctx, color: Color(fluentHex: 0x0099BC), label: "IMG")
        case .audio:
            drawDocumentBase(in: &ctx)
            drawDocumentBadge(in: &ctx, color: Color(fluentHex: 0xC239B3), label: "AUD")
            let heights: [CGFloat] = [12, 22, 28, 18, 10]
            for (idx, h) in heights.enumerated() {
                let x = 31.0 + Double(idx) * 8.0
                let bar = Path(roundedRect: CGRect(x: x, y: 42 - h * 0.5, width: 4.5, height: h), cornerRadius: 2.2)
                ctx.fill(bar, with: .color(Color(fluentHex: 0xC239B3)))
            }
        case .video:
            drawDocumentBase(in: &ctx)
            drawDocumentBadge(in: &ctx, color: Color(fluentHex: 0x744DA9), label: "VID")
            let box = Path(roundedRect: CGRect(x: 28, y: 29, width: 42, height: 28), cornerRadius: 4)
            ctx.fill(box, with: .color(Color(fluentHex: 0x744DA9, opacity: 0.16)))
            var tri = Path()
            tri.move(to: CGPoint(x: 44, y: 36))
            tri.addLine(to: CGPoint(x: 59, y: 43))
            tri.addLine(to: CGPoint(x: 44, y: 50))
            tri.closeSubpath()
            ctx.fill(tri, with: .color(Color(fluentHex: 0x744DA9)))
        case .text:
            drawDocumentBase(in: &ctx)
            drawPageLines(in: &ctx, startY: 32, count: 5, color: isDark ? Color.white.opacity(0.32) : Color(fluentHex: 0x8A94A0, opacity: 0.55))
        case .symlink:
            drawDocumentBase(in: &ctx)
            drawPageLines(in: &ctx, startY: 32, count: 3, color: Color(fluentHex: 0x8A94A0, opacity: 0.45))
            drawSymlinkBadge(in: &ctx, rect: CGRect(x: 20, y: 52, width: 32, height: 32))
        case .other:
            drawDocumentBase(in: &ctx)
            drawPageLines(in: &ctx, startY: 35, count: 4, color: isDark ? Color.white.opacity(0.22) : Color(fluentHex: 0x9AA5B1, opacity: 0.45))
        }
    }

    private func drawDocumentBase(in ctx: inout GraphicsContext) {
        let fillColor = isDark ? Color(fluentHex: 0x2B2F36) : Color.white
        let strokeColor = isDark ? Color(fluentHex: 0x454C56) : Color(fluentHex: 0xCFD6DF)
        let foldColor = isDark ? Color(fluentHex: 0x3D444E) : Color(fluentHex: 0xE5EAF0)

        var page = Path()
        page.move(to: CGPoint(x: 23, y: 10))
        page.addLine(to: CGPoint(x: 61, y: 10))
        page.addLine(to: CGPoint(x: 81, y: 30))
        page.addLine(to: CGPoint(x: 81, y: 84))
        page.addQuadCurve(to: CGPoint(x: 75, y: 90), control: CGPoint(x: 81, y: 90))
        page.addLine(to: CGPoint(x: 23, y: 90))
        page.addQuadCurve(to: CGPoint(x: 17, y: 84), control: CGPoint(x: 17, y: 90))
        page.addLine(to: CGPoint(x: 17, y: 16))
        page.addQuadCurve(to: CGPoint(x: 23, y: 10), control: CGPoint(x: 17, y: 10))
        page.closeSubpath()

        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: Color.black.opacity(0.12), radius: 2, x: 0, y: 1.5))
            layer.fill(page, with: .color(fillColor))
        }
        ctx.stroke(page, with: .color(strokeColor), lineWidth: 1.6)

        // Folded corner dog-ear
        var fold = Path()
        fold.move(to: CGPoint(x: 61, y: 10))
        fold.addLine(to: CGPoint(x: 61, y: 25))
        fold.addQuadCurve(to: CGPoint(x: 66, y: 30), control: CGPoint(x: 61, y: 30))
        fold.addLine(to: CGPoint(x: 81, y: 30))
        fold.closeSubpath()
        ctx.fill(fold, with: .color(foldColor))
        ctx.stroke(fold, with: .color(strokeColor), lineWidth: 1.2)
    }

    private func drawDocumentBadge(in ctx: inout GraphicsContext, color: Color, label: String?) {
        let banner = Path(roundedRect: CGRect(x: 22, y: 63, width: 54, height: 19), cornerRadius: 4)
        ctx.fill(banner, with: .color(color))
        if let label {
            let fontSize: CGFloat = label.count >= 4 ? 10.5 : 12.0
            let text = Text(label)
                .font(.system(size: fontSize, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white)
            ctx.draw(text, at: CGPoint(x: 49, y: 72.5))
        }
    }

    private func drawPageLines(in ctx: inout GraphicsContext, startY: CGFloat, count: Int, color: Color) {
        for i in 0..<count {
            let y = startY + CGFloat(i) * 7.5
            let w: CGFloat = (i == count - 1) ? 28 : 42
            let line = Path(roundedRect: CGRect(x: 27, y: y, width: w, height: 3.4), cornerRadius: 1.7)
            ctx.fill(line, with: .color(color))
        }
    }

    private func drawZipArchiveIcon(in ctx: inout GraphicsContext) {
        // Golden-kraft archive folder body
        drawFolderShell(
            in: &ctx,
            backTop: Color(fluentHex: 0xC88016),
            backBottom: Color(fluentHex: 0xA8680B),
            frontTop: Color(fluentHex: 0xF5BE58),
            frontMid: Color(fluentHex: 0xE29B2B),
            frontBottom: Color(fluentHex: 0xC67E16),
            specularColor: Color.white.opacity(0.5),
            bottomRimColor: Color(fluentHex: 0x8F5607, opacity: 0.7),
            populated: false
        )

        // Vertical zipper track
        let track = Path(CGRect(x: 45, y: 31, width: 10, height: 55))
        ctx.fill(track, with: .color(Color(fluentHex: 0x7A4B08, opacity: 0.45)))

        // Alternating crisp zipper teeth
        for i in 0..<6 {
            let y = 34.0 + Double(i) * 8.0
            let leftTooth = Path(roundedRect: CGRect(x: 44.5, y: y, width: 5.5, height: 3.5), cornerRadius: 1)
            let rightTooth = Path(roundedRect: CGRect(x: 50.0, y: y + 4.0, width: 5.5, height: 3.5), cornerRadius: 1)
            ctx.fill(leftTooth, with: .color(Color(fluentHex: 0xF5F7FA)))
            ctx.fill(rightTooth, with: .color(Color(fluentHex: 0xDCE2E8)))
        }

        // Metallic zipper slider pull
        let slider = Path(roundedRect: CGRect(x: 42, y: 35, width: 16, height: 18), cornerRadius: 3.5)
        ctx.fill(
            slider,
            with: .linearGradient(
                Gradient(colors: [Color(fluentHex: 0xFFFFFF), Color(fluentHex: 0xB8C2CC)]),
                startPoint: CGPoint(x: 50, y: 35),
                endPoint: CGPoint(x: 50, y: 53)
            )
        )
        ctx.stroke(slider, with: .color(Color(fluentHex: 0x6D7782)), lineWidth: 1.2)
        ctx.fill(Path(roundedRect: CGRect(x: 46.5, y: 44, width: 7, height: 5), cornerRadius: 1.5), with: .color(Color(fluentHex: 0x6D7782)))
    }

    private func drawDiskImageIcon(in ctx: inout GraphicsContext) {
        let outer = Path(ellipseIn: CGRect(x: 12, y: 12, width: 76, height: 76))
        ctx.fill(
            outer,
            with: .linearGradient(
                Gradient(colors: [Color(fluentHex: 0xE6ECF2), Color(fluentHex: 0x9AA6B2)]),
                startPoint: CGPoint(x: 16, y: 16),
                endPoint: CGPoint(x: 84, y: 84)
            )
        )
        ctx.stroke(outer, with: .color(Color(fluentHex: 0x7A8694)), lineWidth: 1.5)

        // Subtle iridescent sheen wedges
        var sheen1 = Path()
        sheen1.move(to: CGPoint(x: 50, y: 50))
        sheen1.addArc(center: CGPoint(x: 50, y: 50), radius: 37, startAngle: .degrees(-55), endAngle: .degrees(-10), clockwise: false)
        sheen1.closeSubpath()
        ctx.fill(sheen1, with: .color(Color(fluentHex: 0x50E6FF, opacity: 0.45)))

        var sheen2 = Path()
        sheen2.move(to: CGPoint(x: 50, y: 50))
        sheen2.addArc(center: CGPoint(x: 50, y: 50), radius: 37, startAngle: .degrees(125), endAngle: .degrees(170), clockwise: false)
        sheen2.closeSubpath()
        ctx.fill(sheen2, with: .color(Color(fluentHex: 0x0078D4, opacity: 0.30)))

        // Inner hub + spindle hole
        let hub = Path(ellipseIn: CGRect(x: 34, y: 34, width: 32, height: 32))
        ctx.fill(hub, with: .color(Color(fluentHex: 0xD2DAE2, opacity: 0.85)))
        ctx.stroke(hub, with: .color(Color(fluentHex: 0x8D99A6)), lineWidth: 1.2)

        let hole = Path(ellipseIn: CGRect(x: 42, y: 42, width: 16, height: 16))
        ctx.fill(hole, with: .color(isDark ? Color(fluentHex: 0x191919) : Color.white))
        ctx.stroke(hole, with: .color(Color(fluentHex: 0x7A8694)), lineWidth: 1.4)
    }

    private func drawApplicationIcon(in ctx: inout GraphicsContext) {
        let tile = Path(roundedRect: CGRect(x: 12, y: 12, width: 76, height: 76), cornerRadius: 14)
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: Color.black.opacity(0.16), radius: 2.5, x: 0, y: 1.5))
            layer.fill(
                tile,
                with: .linearGradient(
                    Gradient(colors: [Color(fluentHex: 0x50E6FF), Color(fluentHex: 0x0067C0)]),
                    startPoint: CGPoint(x: 18, y: 14),
                    endPoint: CGPoint(x: 84, y: 86)
                )
            )
        }
        let panes = [
            CGRect(x: 28, y: 28, width: 19, height: 19),
            CGRect(x: 53, y: 28, width: 19, height: 19),
            CGRect(x: 28, y: 53, width: 19, height: 19),
            CGRect(x: 53, y: 53, width: 19, height: 19)
        ]
        for pane in panes {
            ctx.fill(Path(roundedRect: pane, cornerRadius: 3.5), with: .color(Color.white.opacity(0.94)))
        }
    }

    // MARK: - Symlink Corner Badge

    func drawSymlinkBadge(in ctx: inout GraphicsContext, rect: CGRect) {
        let pill = Path(roundedRect: rect, cornerRadius: rect.width * 0.22)
        ctx.fill(pill, with: .color(Color.white))
        ctx.stroke(pill, with: .color(Color.black.opacity(0.22)), lineWidth: max(1.0, rect.width * 0.05))

        let cx = rect.midX
        let cy = rect.midY
        let u = rect.width / 100.0

        var arrow = Path()
        arrow.move(to: CGPoint(x: cx - 26 * u, y: cy + 20 * u))
        arrow.addQuadCurve(
            to: CGPoint(x: cx + 18 * u, y: cy - 10 * u),
            control: CGPoint(x: cx - 20 * u, y: cy - 14 * u)
        )
        ctx.stroke(arrow, with: .color(Color(fluentHex: 0x0067C0)), style: StrokeStyle(lineWidth: max(1.5, 13 * u), lineCap: .round))

        var head = Path()
        head.move(to: CGPoint(x: cx + 4 * u, y: cy - 26 * u))
        head.addLine(to: CGPoint(x: cx + 26 * u, y: cy - 8 * u))
        head.addLine(to: CGPoint(x: cx + 4 * u, y: cy + 10 * u))
        head.closeSubpath()
        ctx.fill(head, with: .color(Color(fluentHex: 0x0067C0)))
    }
}

/// Crisp Windows 11 shortcut arrow corner badge overlay.
struct FluentSymlinkCornerBadge: View {
    let badgeSize: CGFloat

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let s = min(size.width, size.height)
            guard s > 0 else { return }
            let pill = Path(roundedRect: CGRect(x: 0.5, y: 0.5, width: s - 1, height: s - 1), cornerRadius: s * 0.22)
            context.fill(pill, with: .color(.white))
            context.stroke(pill, with: .color(Color.black.opacity(0.24)), lineWidth: 1)

            var curve = Path()
            curve.move(to: CGPoint(x: s * 0.24, y: s * 0.72))
            curve.addQuadCurve(
                to: CGPoint(x: s * 0.68, y: s * 0.42),
                control: CGPoint(x: s * 0.28, y: s * 0.40)
            )
            context.stroke(
                curve,
                with: .color(Color(fluentHex: 0x0067C0)),
                style: StrokeStyle(lineWidth: max(1.4, s * 0.14), lineCap: .round)
            )

            var head = Path()
            head.move(to: CGPoint(x: s * 0.54, y: s * 0.22))
            head.addLine(to: CGPoint(x: s * 0.80, y: s * 0.43))
            head.addLine(to: CGPoint(x: s * 0.54, y: s * 0.64))
            head.closeSubpath()
            context.fill(head, with: .color(Color(fluentHex: 0x0067C0)))
        }
        .frame(width: badgeSize, height: badgeSize)
        .shadow(color: Color.black.opacity(0.18), radius: 1, x: 0, y: 0.5)
    }
}
