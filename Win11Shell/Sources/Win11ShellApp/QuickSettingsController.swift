import AppKit
import Observation
import SwiftUI
import Win11ShellCore

@MainActor
public final class QuickSettingsController {
    private let model: RunningAppsModel
    private let system: SystemControlsBridge
    private var panel: FocusableFloatingPanel?
    private var outsideMonitor: Any?

    public var isVisible: Bool { panel?.isVisible ?? false }

    public init(model: RunningAppsModel, system: SystemControlsBridge) {
        self.model = model
        self.system = system
    }

    public func toggle(on screen: NSScreen? = nil) {
        if let panel, panel.isVisible {
            dismiss()
        } else {
            show(on: screen)
        }
    }

    public func show(on screen: NSScreen? = nil) {
        system.refresh(forceBluetooth: true)
        let hosting = NSHostingView(rootView: QuickSettingsView(
            model: model,
            system: system,
            onDismiss: { [weak self] in self?.dismiss() }
        ))
        let fitting = hosting.fittingSize
        let size = NSSize(width: 360, height: max(390, fitting.height))

        if panel == nil {
            let p = FocusableFloatingPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            p.level = .popUpMenu
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            panel = p
        }

        if let panel {
            panel.setContentSize(size)
            panel.contentView = hosting
            let target = screen ?? NSScreen.main ?? NSScreen.screens.first
            if let target {
                let x = target.frame.maxX - size.width - 12
                let y = target.frame.minY + CGFloat(model.config.taskbarHeight) + 12
                panel.setFrameOrigin(NSPoint(x: x, y: y))
                panel.makeKeyAndOrderFront(nil)
            }
        }
        installOutsideMonitor()
    }

    public func dismiss() {
        panel?.orderOut(nil)
        if let outsideMonitor {
            NSEvent.removeMonitor(outsideMonitor)
            self.outsideMonitor = nil
        }
    }

    private func installOutsideMonitor() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                if !panel.frame.contains(NSEvent.mouseLocation) {
                    self.dismiss()
                }
            }
        }
    }
}

private struct QuickSettingsView: View {
    @Bindable var model: RunningAppsModel
    @Bindable var system: SystemControlsBridge
    let onDismiss: () -> Void

    private var needsCorePermissions: Bool {
        !system.hasAccessibilityPermission || !system.hasInputMonitoringPermission
    }

    var body: some View {
        VStack(spacing: 14) {
            if needsCorePermissions {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text("Permissions needed for full Win11 shell")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    HStack(spacing: 8) {
                        PermissionPillButton(
                            title: system.hasAccessibilityPermission ? "Accessibility OK" : "Grant Accessibility",
                            granted: system.hasAccessibilityPermission
                        ) {
                            _ = AccessibilityBridge.hasAccessibilityPermission(prompt: true)
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                            onDismiss()
                        }
                        PermissionPillButton(
                            title: system.hasInputMonitoringPermission ? "Input OK" : "Grant Input",
                            granted: system.hasInputMonitoringPermission
                        ) {
                            CGRequestListenEventAccess()
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                                NSWorkspace.shared.open(url)
                            }
                            onDismiss()
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.yellow.opacity(0.14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.yellow.opacity(0.35), lineWidth: 1)
                        )
                )
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                QuickTile(
                    title: system.wifiOn ? system.wifiSSID : "Wi-Fi",
                    symbol: system.wifiOn ? "wifi" : "wifi.slash",
                    isOn: system.wifiOn,
                    action: { system.toggleWiFi() }
                )
                QuickTile(
                    title: "Bluetooth",
                    symbol: "dot.radiowaves.left.and.right",
                    isOn: system.bluetoothOn,
                    action: {
                        onDismiss()
                        system.openBluetoothSettings()
                    }
                )
                QuickTile(
                    title: system.isDarkMode ? "Dark Mode" : "Light Mode",
                    symbol: system.isDarkMode ? "moon.fill" : "sun.max.fill",
                    isOn: system.isDarkMode,
                    action: { system.toggleDarkMode() }
                )
                QuickTile(
                    title: "Hide Top Bar",
                    symbol: "menubar.rectangle",
                    isOn: system.topMenuBarHidden,
                    action: { system.setTopMenuBarHidden(!system.topMenuBarHidden) }
                )
                QuickTile(
                    title: "Auto-Hide Bar",
                    symbol: "dock.arrow.down.rectangle",
                    isOn: model.config.taskbarAutoHide,
                    action: { model.config.taskbarAutoHide.toggle() }
                )
                QuickTile(
                    title: "Win Menu Bar",
                    symbol: "macwindow",
                    isOn: model.config.showWindowChromeBar,
                    action: { model.config.showWindowChromeBar.toggle() }
                )
            }

            Divider()

            // Brightness Slider
            HStack(spacing: 12) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 14))
                    .frame(width: 22)
                Slider(
                    value: Binding(
                        get: { system.brightness },
                        set: { system.setBrightness($0) }
                    ),
                    in: 0.05...1.0
                )
                .disabled(!system.hasBrightnessControl)
            }

            // Volume Slider
            HStack(spacing: 12) {
                Button {
                    system.setMuted(!system.isMuted)
                } label: {
                    Image(systemName: system.isMuted || system.volume < 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 14))
                        .frame(width: 22)
                }
                .buttonStyle(.plain)
                Slider(
                    value: Binding(
                        get: { system.volume },
                        set: { system.setVolume($0) }
                    ),
                    in: 0.0...1.0
                )
            }

            Divider()

            // Footer: Battery + Settings
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: system.battery.isCharging ? "battery.100.bolt" : "battery.100")
                    Text(system.battery.present ? "\(system.battery.percentage)%" : "AC Power")
                        .font(.system(size: 12))
                }
                .foregroundStyle(.secondary)

                Spacer()

                Button {
                    onDismiss()
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .frame(width: 360)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThickMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                )
        )
        .onExitCommand { onDismiss() }
    }
}

private struct PermissionPillButton: View {
    let title: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(granted ? Color.green : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(granted ? Color.green.opacity(0.14) : Color.primary.opacity(0.10))
            )
        }
        .buttonStyle(.plain)
    }
}

private struct QuickTile: View {
    let title: String
    let symbol: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Button(action: action) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isOn ? Color.accentColor : Color.primary.opacity(0.10))
                    .frame(height: 46)
                    .overlay(
                        Image(systemName: symbol)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(isOn ? .white : .primary)
                    )
            }
            .buttonStyle(.plain)

            Text(title)
                .font(.system(size: 11))
                .lineLimit(1)
        }
    }
}

// MARK: - Auxiliary Taskbar Flyouts (Tray Overflow, Widgets, Taskbar Settings)

@MainActor
public final class AuxiliaryFlyoutsController {
    private let model: RunningAppsModel
    private let system: SystemControlsBridge
    private var panel: FocusableFloatingPanel?
    private var outsideMonitor: Any?

    public enum Mode {
        case trayOverflow
        case widgets
        case taskbarSettings
    }

    public init(model: RunningAppsModel, system: SystemControlsBridge) {
        self.model = model
        self.system = system
    }

    public func show(mode: Mode, on screen: NSScreen? = nil) {
        model.refreshAll()
        system.refresh(forceBluetooth: true)

        let size: NSSize
        let rootView: AnyView
        switch mode {
        case .trayOverflow:
            size = NSSize(width: 280, height: 260)
            rootView = AnyView(TrayOverflowView(model: model, onDismiss: { [weak self] in self?.dismiss() }))
        case .widgets:
            size = NSSize(width: 340, height: 320)
            rootView = AnyView(WidgetsFlyoutView(model: model, system: system, onDismiss: { [weak self] in self?.dismiss() }))
        case .taskbarSettings:
            size = NSSize(width: 340, height: 390)
            rootView = AnyView(TaskbarSettingsFlyoutView(model: model, system: system, onDismiss: { [weak self] in self?.dismiss() }))
        }

        if panel == nil {
            let p = FocusableFloatingPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            p.level = .popUpMenu
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            panel = p
        }

        guard let panel else { return }
        panel.setContentSize(size)
        panel.contentView = NSHostingView(rootView: rootView)

        let target = screen ?? NSScreen.main ?? NSScreen.screens.first
        if let target {
            let x: CGFloat
            switch mode {
            case .trayOverflow:
                x = target.frame.maxX - size.width - 140
            case .widgets:
                x = target.frame.minX + 12
            case .taskbarSettings:
                x = target.frame.midX - (size.width / 2)
            }
            let y = target.frame.minY + CGFloat(model.config.taskbarHeight) + 12
            panel.setFrameOrigin(NSPoint(x: max(target.frame.minX + 8, min(x, target.frame.maxX - size.width - 8)), y: y))
            panel.makeKeyAndOrderFront(nil)
        }
        installOutsideMonitor()
    }

    public func dismiss() {
        panel?.orderOut(nil)
        if let outsideMonitor {
            NSEvent.removeMonitor(outsideMonitor)
            self.outsideMonitor = nil
        }
    }

    private func installOutsideMonitor() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                if !panel.frame.contains(NSEvent.mouseLocation) {
                    self.dismiss()
                }
            }
        }
    }
}

private struct TrayOverflowView: View {
    let model: RunningAppsModel
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("System Tray")
                .font(.system(size: 13, weight: .semibold))

            if model.trayExtras.isEmpty {
                Text("No third-party menu bar tray apps detected.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        ForEach(model.trayExtras) { extra in
                            Button {
                                AccessibilityBridge.performPress(extra.element)
                                onDismiss()
                            } label: {
                                VStack(spacing: 4) {
                                    if let icon = extra.icon {
                                        Image(nsImage: icon)
                                            .resizable()
                                            .frame(width: 22, height: 22)
                                    } else {
                                        Image(systemName: "app")
                                            .frame(width: 22, height: 22)
                                    }
                                    Text(extra.appName)
                                        .font(.system(size: 9.5))
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(6)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                            }
                            .buttonStyle(.plain)
                            .help(extra.title)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            HStack {
                Button("Task Manager") {
                    onDismiss()
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Settings") {
                    onDismiss()
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(width: 280, height: 260)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThickMaterial)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
        )
    }
}

private struct WidgetsFlyoutView: View {
    let model: RunningAppsModel
    let system: SystemControlsBridge
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("System & Widgets")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(Date.now.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                StatCard(title: "CPU Load", value: "\(system.stats.cpuPercent)%", symbol: "cpu")
                StatCard(
                    title: "Memory",
                    value: String(format: "%.1f / %.0f GB", system.stats.memoryUsedGB, system.stats.memoryTotalGB),
                    symbol: "memorychip"
                )
            }

            HStack(spacing: 10) {
                StatCard(
                    title: "Battery",
                    value: system.battery.present ? "\(system.battery.percentage)%" : "AC Power",
                    symbol: system.battery.isCharging ? "battery.100.bolt" : "battery.100"
                )
                StatCard(
                    title: "Network",
                    value: system.wifiOn ? system.wifiSSID : "Disconnected",
                    symbol: system.wifiOn ? "wifi" : "wifi.slash"
                )
            }

            Spacer(minLength: 0)

            HStack {
                Button("Open File Explorer") {
                    model.launchOrActivate(bundleID: model.config.fileExplorerBundleID)
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Button("Activity Monitor") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                    onDismiss()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(width: 340, height: 320)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThickMaterial)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
        )
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }
}

private struct TaskbarSettingsFlyoutView: View {
    @Bindable var model: RunningAppsModel
    @Bindable var system: SystemControlsBridge
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Taskbar & Win11 Settings")
                .font(.system(size: 14, weight: .semibold))

            Picker("Alignment", selection: $model.config.taskbarAlignment) {
                Text("Center").tag(TaskbarAlignment.center)
                Text("Left").tag(TaskbarAlignment.left)
            }
            .pickerStyle(.segmented)

            Toggle("Automatically hide taskbar", isOn: $model.config.taskbarAutoHide)
            Toggle("Show Search button", isOn: $model.config.showSearchButton)
            Toggle("Show Task View button", isOn: $model.config.showTaskViewButton)
            Toggle("Show Widgets chip", isOn: $model.config.showWidgetsButton)
            Toggle("Per-window menu bar + (— □ ✕)", isOn: $model.config.showWindowChromeBar)
            Toggle("Hide macOS top menu bar", isOn: Binding(
                get: { system.topMenuBarHidden },
                set: { system.setTopMenuBarHidden($0) }
            ))

            Divider()

            HStack(spacing: 8) {
                PermissionPillButton(
                    title: "AX: \(system.hasAccessibilityPermission ? "OK" : "Needed")",
                    granted: system.hasAccessibilityPermission
                ) {
                    _ = AccessibilityBridge.hasAccessibilityPermission(prompt: true)
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                    onDismiss()
                }
                PermissionPillButton(
                    title: "Input: \(system.hasInputMonitoringPermission ? "OK" : "Needed")",
                    granted: system.hasInputMonitoringPermission
                ) {
                    CGRequestListenEventAccess()
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                        NSWorkspace.shared.open(url)
                    }
                    onDismiss()
                }
            }

            HStack {
                Button("Privacy Settings") {
                    onDismiss()
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Done") { onDismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 340, height: 390)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThickMaterial)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
        )
    }
}
