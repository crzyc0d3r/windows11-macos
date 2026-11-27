import AppKit
import Observation
import SwiftUI
import Win11ShellCore

public struct HoverWindowPreviewItem: Identifiable, @unchecked Sendable {
    public var id: String { "\(info.pid)-\(info.windowID)-\(index)" }
    public let index: Int
    public let info: AXWindowInfo
    public let thumbnail: NSImage?
}

@MainActor
@Observable
public final class HoverPreviewState {
    public var appName: String = ""
    public var appIcon: NSImage?
    public var windows: [HoverWindowPreviewItem] = []
}

@MainActor
public final class TaskbarHoverPreviewController {
    private let model: RunningAppsModel
    private let state = HoverPreviewState()
    private var panel: NonActivatingFloatingPanel?
    private var showWork: DispatchWorkItem?
    private var dismissWork: DispatchWorkItem?
    private var activeBundleID: String?
    private var isPointerInsidePopover = false

    public init(model: RunningAppsModel) {
        self.model = model
    }

    public func handleHover(item: TaskbarAppItem, hovering: Bool, anchorScreenRect: NSRect) {
        showWork?.cancel()
        dismissWork?.cancel()

        if hovering && item.isRunning {
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.showPreview(for: item, anchorScreenRect: anchorScreenRect)
                }
            }
            showWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        } else {
            scheduleDismiss()
        }
    }

    public func dismissImmediately() {
        showWork?.cancel()
        dismissWork?.cancel()
        isPointerInsidePopover = false
        activeBundleID = nil
        panel?.orderOut(nil)
    }

    private func scheduleDismiss() {
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isPointerInsidePopover else { return }
            self.activeBundleID = nil
            self.panel?.orderOut(nil)
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    private func showPreview(for item: TaskbarAppItem, anchorScreenRect: NSRect) async {
        guard let pid = item.pid else { return }
        let axWindows = AccessibilityBridge.standardWindows(for: pid)
        guard !axWindows.isEmpty else { return }

        activeBundleID = item.bundleID
        state.appName = item.name
        state.appIcon = item.icon

        var previews: [HoverWindowPreviewItem] = []
        for (idx, win) in axWindows.prefix(6).enumerated() {
            let thumb = await AccessibilityBridge.captureWindowThumbnail(windowID: win.windowID)
            previews.append(HoverWindowPreviewItem(index: idx, info: win, thumbnail: thumb))
        }
        guard activeBundleID == item.bundleID else { return }
        state.windows = previews

        let width = CGFloat(min(previews.count, 4)) * 210 + 24
        let height: CGFloat = 170

        if panel == nil {
            let p = NonActivatingFloatingPanel(
                contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.level = .popUpMenu
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.contentView = NSHostingView(rootView: HoverPreviewStripView(
                state: state,
                onFocus: { [weak self] win in
                    AccessibilityBridge.focusWindow(win)
                    self?.dismissImmediately()
                },
                onClose: { [weak self] win in
                    AccessibilityBridge.pressCloseButton(win.element)
                    self?.dismissImmediately()
                },
                onHoverInside: { [weak self] inside in
                    self?.isPointerInsidePopover = inside
                    if inside {
                        self?.dismissWork?.cancel()
                    } else {
                        self?.scheduleDismiss()
                    }
                }
            ))
            panel = p
        }

        guard let panel else { return }
        panel.setContentSize(NSSize(width: width, height: height))

        let screenFrame = NSScreen.screens.first(where: { $0.frame.contains(anchorScreenRect.origin) })?.frame
            ?? NSScreen.main?.frame
            ?? NSRect(x: 0, y: 0, width: 1512, height: 982)
        let desiredX = anchorScreenRect.midX - (width / 2)
        let clampedX = max(screenFrame.minX + 8, min(desiredX, screenFrame.maxX - width - 8))
        let y = screenFrame.minY + CGFloat(model.config.taskbarHeight) + 10
        panel.setFrameOrigin(NSPoint(x: clampedX, y: y))
        panel.orderFront(nil)
    }
}

private struct HoverPreviewStripView: View {
    let state: HoverPreviewState
    let onFocus: (AXWindowInfo) -> Void
    let onClose: (AXWindowInfo) -> Void
    let onHoverInside: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(state.windows.prefix(4)) { win in
                PreviewCard(
                    appName: state.appName,
                    appIcon: state.appIcon,
                    item: win,
                    onFocus: { onFocus(win.info) },
                    onClose: { onClose(win.info) }
                )
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThickMaterial)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
        )
        .onHover { onHoverInside($0) }
    }
}

private struct PreviewCard: View {
    let appName: String
    let appIcon: NSImage?
    let item: HoverWindowPreviewItem
    let onFocus: () -> Void
    let onClose: () -> Void
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 14, height: 14)
                }
                Text(item.info.title.isEmpty ? appName : item.info.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(hovered ? Color(red: 0.77, green: 0.17, blue: 0.11) : Color.primary.opacity(0.12)))
                        .foregroundStyle(hovered ? .white : .primary)
                }
                .buttonStyle(.plain)
            }

            Button(action: onFocus) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.black.opacity(0.25))
                    if let thumb = item.thumbnail {
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else if let appIcon {
                        Image(nsImage: appIcon)
                            .resizable()
                            .frame(width: 44, height: 44)
                    }
                }
                .frame(width: 184, height: 108)
            }
            .buttonStyle(.plain)
        }
        .padding(6)
        .frame(width: 196, height: 144)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovered ? Color.primary.opacity(0.10) : Color.primary.opacity(0.04))
        )
        .onHover { hovered = $0 }
    }
}
