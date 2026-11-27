import AppKit
import SwiftUI
import Win11ShellCore

@MainActor
public final class TaskbarCoordinator {
    private let model: RunningAppsModel
    private let system: SystemControlsBridge
    private let startMenu: StartMenuController
    private let quickSettings: QuickSettingsController
    private let calendarFlyout: CalendarFlyoutController
    private let auxFlyouts: AuxiliaryFlyoutsController
    private let hoverPreview: TaskbarHoverPreviewController
    private let showDesktop: ShowDesktopController

    private var panels: [CGDirectDisplayID: NonActivatingFloatingPanel] = [:]
    private var notchBezelPanels: [CGDirectDisplayID: NonActivatingFloatingPanel] = [:]
    private var autoHideTimer: Timer?
    private var isAutoHidden = false

    public init(
        model: RunningAppsModel,
        system: SystemControlsBridge,
        startMenu: StartMenuController,
        quickSettings: QuickSettingsController,
        calendarFlyout: CalendarFlyoutController,
        auxFlyouts: AuxiliaryFlyoutsController,
        hoverPreview: TaskbarHoverPreviewController,
        showDesktop: ShowDesktopController
    ) {
        self.model = model
        self.system = system
        self.startMenu = startMenu
        self.quickSettings = quickSettings
        self.calendarFlyout = calendarFlyout
        self.auxFlyouts = auxFlyouts
        self.hoverPreview = hoverPreview
        self.showDesktop = showDesktop

        rebuildPanels()
        NSNotificationCenterObservers()
        startAutoHideAndFullscreenLoop()
    }

    private func NSNotificationCenterObservers() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rebuildPanels()
            }
        }
    }

    public func rebuildPanels() {
        for (_, p) in panels {
            p.orderOut(nil)
        }
        panels.removeAll()

        for (_, bezel) in notchBezelPanels {
            bezel.orderOut(nil)
        }
        notchBezelPanels.removeAll()

        let height = CGFloat(model.config.taskbarHeight)
        for screen in NSScreen.screens {
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                continue
            }
            if let bezelFrame = WindowChromeGeometry.notchBezelFrameCocoa(
                screenFrameCocoa: screen.frame,
                safeAreaTopInset: screen.safeAreaInsets.top
            ) {
                let bezel = NonActivatingFloatingPanel(
                    contentRect: bezelFrame,
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered,
                    defer: false
                )
                bezel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
                bezel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
                bezel.backgroundColor = .black
                bezel.isOpaque = true
                bezel.hasShadow = false
                bezel.ignoresMouseEvents = true
                bezel.orderFrontRegardless()
                notchBezelPanels[displayID] = bezel
            }

            let frame = NSRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: height)
            let p = NonActivatingFloatingPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true

            p.contentView = NSHostingView(rootView: TaskbarView(
                model: model,
                system: system,
                onStartClick: { [weak self] in
                    self?.quickSettings.dismiss()
                    self?.calendarFlyout.dismiss()
                    self?.auxFlyouts.dismiss()
                    self?.startMenu.toggle(focusSearch: false, on: screen)
                },
                onSearchClick: { [weak self] in
                    self?.quickSettings.dismiss()
                    self?.calendarFlyout.dismiss()
                    self?.auxFlyouts.dismiss()
                    self?.startMenu.toggle(focusSearch: true, on: screen)
                },
                onTaskViewClick: {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
                },
                onWidgetsClick: { [weak self] in
                    self?.startMenu.dismiss()
                    self?.auxFlyouts.show(mode: .widgets, on: screen)
                },
                onTrayOverflowClick: { [weak self] in
                    self?.startMenu.dismiss()
                    self?.auxFlyouts.show(mode: .trayOverflow, on: screen)
                },
                onQuickSettingsClick: { [weak self] in
                    self?.startMenu.dismiss()
                    self?.calendarFlyout.dismiss()
                    self?.auxFlyouts.dismiss()
                    self?.quickSettings.toggle(on: screen)
                },
                onClockClick: { [weak self] in
                    self?.startMenu.dismiss()
                    self?.quickSettings.dismiss()
                    self?.auxFlyouts.dismiss()
                    self?.calendarFlyout.toggle(on: screen)
                },
                onShowDesktopClick: { [weak self] in
                    self?.showDesktop.toggleShowDesktop()
                },
                onTaskbarSettingsClick: { [weak self] in
                    self?.auxFlyouts.show(mode: .taskbarSettings, on: screen)
                },
                onHoverAppIcon: { [weak self] item, hovering, rect in
                    self?.hoverPreview.handleHover(item: item, hovering: hovering, anchorScreenRect: rect)
                },
                onAppClicked: { [weak self] item, isMiddle in
                    self?.hoverPreview.dismissImmediately()
                    self?.model.launchOrActivate(bundleID: item.bundleID, forceNewWindow: isMiddle)
                }
            ))
            p.orderFrontRegardless()
            panels[displayID] = p
        }
        ShellLogger.log("Taskbar panels created: \(panels.count) screen(s), height=\(Int(height))pt, level=statusBar")
    }

    private func startAutoHideAndFullscreenLoop() {
        autoHideTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateVisibility()
            }
        }
    }

    private func updateVisibility() {
        let mouse = NSEvent.mouseLocation
        let height = CGFloat(model.config.taskbarHeight)
        let front = NSWorkspace.shared.frontmostApplication
        let frontWin = front.flatMap { AccessibilityBridge.focusedWindow(for: $0.processIdentifier) }
        let frontScreen = frontWin.flatMap { AccessibilityBridge.screenContaining(axFrame: $0.axFrame) }
        let frontIsFullScreen = frontWin?.isFullScreen ?? false

        for screen in NSScreen.screens {
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let panel = panels[displayID]
            else {
                continue
            }

            // Hide when frontmost window on this screen is in native macOS fullscreen
            if frontIsFullScreen && frontScreen == screen {
                panel.orderOut(nil)
                notchBezelPanels[displayID]?.orderOut(nil)
                continue
            }

            if let bezel = notchBezelPanels[displayID],
               let bezelFrame = WindowChromeGeometry.notchBezelFrameCocoa(
                screenFrameCocoa: screen.frame,
                safeAreaTopInset: screen.safeAreaInsets.top
               ) {
                if bezel.frame != bezelFrame {
                    bezel.setFrame(bezelFrame, display: true)
                }
                if !bezel.isVisible {
                    bezel.orderFrontRegardless()
                }
            }

            if model.config.taskbarAutoHide {
                let nearBottom = screen.frame.contains(CGPoint(x: mouse.x, y: screen.frame.minY + 1))
                    && mouse.y <= screen.frame.minY + (isAutoHidden ? 4 : height + 8)
                let flyoutOpen = startMenu.isVisible || quickSettings.isVisible
                let shouldShow = nearBottom || flyoutOpen
                isAutoHidden = !shouldShow

                let targetY = shouldShow ? screen.frame.minY : (screen.frame.minY - height + 2)
                let targetFrame = NSRect(x: screen.frame.minX, y: targetY, width: screen.frame.width, height: height)
                if panel.frame != targetFrame {
                    panel.setFrame(targetFrame, display: true)
                }
                if !panel.isVisible {
                    panel.orderFrontRegardless()
                }
            } else {
                let targetFrame = NSRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: height)
                if panel.frame != targetFrame {
                    panel.setFrame(targetFrame, display: true)
                }
                if !panel.isVisible {
                    panel.orderFrontRegardless()
                }
            }
        }
    }
}

private struct TaskbarView: View {
    let model: RunningAppsModel
    let system: SystemControlsBridge
    let onStartClick: () -> Void
    let onSearchClick: () -> Void
    let onTaskViewClick: () -> Void
    let onWidgetsClick: () -> Void
    let onTrayOverflowClick: () -> Void
    let onQuickSettingsClick: () -> Void
    let onClockClick: () -> Void
    let onShowDesktopClick: () -> Void
    let onTaskbarSettingsClick: () -> Void
    let onHoverAppIcon: (TaskbarAppItem, Bool, NSRect) -> Void
    let onAppClicked: (TaskbarAppItem, Bool) -> Void

    var body: some View {
        ZStack {
            AcrylicBackground(material: .hudWindow)
                .overlay(
                    Rectangle()
                        .frame(height: 0.75)
                        .foregroundStyle(Color.white.opacity(0.16)),
                    alignment: .top
                )

            HStack(spacing: 6) {
                // Left zone (Widgets chip or Left-aligned Dock)
                if model.config.taskbarAlignment == .left {
                    centerCluster
                    Spacer()
                } else {
                    if model.config.showWidgetsButton {
                        WidgetsChipButton(system: system, action: onWidgetsClick)
                            .padding(.leading, 8)
                    }
                    Spacer()
                }

                // Right System Tray + Clock + Show Desktop Sliver
                HStack(spacing: 4) {
                    if !system.hasAccessibilityPermission || !system.hasInputMonitoringPermission {
                        Button(action: onQuickSettingsClick) {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 11))
                                Text("Permissions")
                                    .font(.system(size: 10.5, weight: .semibold))
                            }
                            .foregroundStyle(.black)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.yellow.opacity(0.9)))
                        }
                        .buttonStyle(.plain)
                        .help("Accessibility or Input Monitoring permission missing — click to open Quick Settings")
                    }

                    TaskbarTrayButton(symbol: "chevron.up", action: onTrayOverflowClick)
                        .help("Show hidden icons")

                    Button(action: onQuickSettingsClick) {
                        HStack(spacing: 7) {
                            Image(systemName: system.wifiOn ? "wifi" : "wifi.slash")
                                .font(.system(size: 12))
                            Image(systemName: system.isMuted || system.volume < 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 12))
                            if system.battery.present {
                                Image(systemName: system.battery.isCharging ? "battery.100.bolt" : "battery.100")
                                    .font(.system(size: 12))
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.001)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Quick Settings (Win+A)")

                    ClockButtonView(action: onClockClick)

                    ShowDesktopSliver(action: onShowDesktopClick)
                }
                .padding(.trailing, 2)
            }

            if model.config.taskbarAlignment == .center {
                centerCluster
            }
        }
        .frame(height: CGFloat(model.config.taskbarHeight))
        .contextMenu {
            Button("Taskbar settings", action: onTaskbarSettingsClick)
            Button("Task Manager") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            }
            Divider()
            Button("Show Desktop", action: onShowDesktopClick)
        }
    }

    private var centerCluster: some View {
        HStack(spacing: 4) {
            // Start Button
            TaskbarGlyphButton(action: onStartClick) {
                Win11LogoGlyph(size: 19)
            }
            .help("Start (Win)")

            // Search
            if model.config.showSearchButton {
                TaskbarGlyphButton(action: onSearchClick) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .medium))
                }
                .help("Search (Win+S)")
            }

            // Task View
            if model.config.showTaskViewButton {
                TaskbarGlyphButton(action: onTaskViewClick) {
                    Image(systemName: "rectangle.3.group")
                        .font(.system(size: 14, weight: .medium))
                }
                .help("Task View (Win+Tab)")
            }

            ForEach(model.taskbarItems) { item in
                TaskbarAppIconButton(
                    item: item,
                    model: model,
                    onClick: { isMiddle in
                        onAppClicked(item, isMiddle)
                    },
                    onHoverWithRect: { hovering, rect in
                        onHoverAppIcon(item, hovering, rect)
                    }
                )
            }
        }
        .padding(.horizontal, 8)
    }
}

private struct TaskbarGlyphButton<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            content()
                .frame(width: 40, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovered ? Color.primary.opacity(0.11) : .clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct TaskbarAppIconButton: View {
    let item: TaskbarAppItem
    let model: RunningAppsModel
    let onClick: (Bool) -> Void
    let onHoverWithRect: (Bool, NSRect) -> Void

    @State private var hovered = false
    @State private var hostView: NSView?

    var body: some View {
        Button {
            onClick(false)
        } label: {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(item.isActive ? Color.primary.opacity(0.13) : (hovered ? Color.primary.opacity(0.09) : .clear))
                    .frame(width: 40, height: 38)

                Image(nsImage: item.icon)
                    .resizable()
                    .frame(width: 24, height: 24)
                    .padding(.bottom, 7)

                if item.isRunning {
                    Capsule()
                        .fill(item.isActive ? Color.accentColor : Color.secondary)
                        .frame(width: item.isActive ? 16 : 6, height: 3)
                        .padding(.bottom, 2)
                }
            }
        }
        .buttonStyle(.plain)
        .background(TaskbarAnchorFinder(viewRef: $hostView, onMiddleClick: { onClick(true) }))
        .onHover { isHovering in
            hovered = isHovering
            if let hostView, let win = hostView.window {
                let rectInWin = hostView.convert(hostView.bounds, to: nil)
                let screenRect = win.convertToScreen(rectInWin)
                onHoverWithRect(isHovering, screenRect)
            }
        }
        .help(item.name)
        .contextMenu {
            Button(item.isRunning ? "New window" : "Open") {
                model.launchOrActivate(bundleID: item.bundleID, forceNewWindow: item.isRunning)
            }
            if let pid = item.pid {
                let wins = AccessibilityBridge.standardWindows(for: pid)
                if !wins.isEmpty {
                    Divider()
                    ForEach(Array(wins.prefix(6).enumerated()), id: \.offset) { _, w in
                        Button(w.title.isEmpty ? item.name : w.title) {
                            AccessibilityBridge.focusWindow(w)
                        }
                    }
                }
            }
            Divider()
            Button(item.isPinned ? "Unpin from taskbar" : "Pin to taskbar") {
                model.togglePin(bundleID: item.bundleID)
            }
            if item.isRunning, let pid = item.pid, let app = NSRunningApplication(processIdentifier: pid) {
                Divider()
                Button("Close all windows / Quit") {
                    app.terminate()
                }
            }
        }
    }
}

private struct TaskbarAnchorFinder: NSViewRepresentable {
    @Binding var viewRef: NSView?
    let onMiddleClick: () -> Void

    func makeNSView(context: Context) -> MiddleClickCaptureView {
        let v = MiddleClickCaptureView()
        v.onMiddleClick = onMiddleClick
        DispatchQueue.main.async { viewRef = v }
        return v
    }

    func updateNSView(_ nsView: MiddleClickCaptureView, context: Context) {
        nsView.onMiddleClick = onMiddleClick
    }
}

private final class MiddleClickCaptureView: NSView {
    var onMiddleClick: (() -> Void)?

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 {
            onMiddleClick?()
        } else {
            super.otherMouseDown(with: event)
        }
    }
}

private struct WidgetsChipButton: View {
    let system: SystemControlsBridge
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 0) {
                    Text("CPU \(system.stats.cpuPercent)%")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text(String(format: "%.0f GB", system.stats.memoryUsedGB))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? Color.primary.opacity(0.10) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct TaskbarTrayButton: View {
    let symbol: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 34)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovered ? Color.primary.opacity(0.10) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct ClockButtonView: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            Button(action: action) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(context.date.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11.5, weight: .medium))
                    Text(context.date.formatted(date: .numeric, time: .omitted))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? Color.primary.opacity(0.10) : .clear))
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .help("Date and Time (Win+N)")
        }
    }
}

private struct ShowDesktopSliver: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.primary.opacity(hovered ? 0.45 : 0.18))
                    .frame(width: 1, height: 18)
                Color.clear.frame(width: 7, height: 38)
            }
            .background(hovered ? Color.primary.opacity(0.10) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Show Desktop (Win+D)")
    }
}
