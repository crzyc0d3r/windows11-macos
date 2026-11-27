import AppKit
import Foundation
import Win11ShellCore

@main
enum Win11ShellMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if handleCLIIfRequested(args: args) {
            return
        }

        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = ShellAppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            app.run()
        }
    }

    private static func handleCLIIfRequested(args: [String]) -> Bool {
        if let idx = args.firstIndex(of: "--generate-icon") {
            guard args.indices.contains(idx + 1) else {
                fputs("Usage: --generate-icon <png-path>\n", stderr)
                exit(1)
            }
            let outURL = URL(fileURLWithPath: (args[idx + 1] as NSString).expandingTildeInPath)
            do {
                try MainActor.assumeIsolated {
                    try Win11IconRenderer.renderAppIconPNG(to: outURL, size: 1024)
                }
                print("Generated icon: \(outURL.path)")
                return true
            } catch {
                fputs("Icon error: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }

        if args.contains("--generate-configs") {
            var karabinerPath = (NSHomeDirectory() as NSString).appendingPathComponent(".config/karabiner/karabiner.json")
            var devicesPath: String?
            if let kIdx = args.firstIndex(of: "--karabiner-path"), args.indices.contains(kIdx + 1) {
                karabinerPath = (args[kIdx + 1] as NSString).expandingTildeInPath
            }
            if let dIdx = args.firstIndex(of: "--devices-json"), args.indices.contains(dIdx + 1) {
                devicesPath = (args[dIdx + 1] as NSString).expandingTildeInPath
            }

            do {
                let store = Win11ConfigStore()
                let config = store.load()
                if !FileManager.default.fileExists(atPath: store.configURL.path) {
                    try store.save(config)
                }

                let devicesData = devicesPath.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
                let builtIns = devicesData.map { KarabinerConfigGenerator.parseConnectedBuiltInDevices(from: $0) }
                    ?? [KarabinerDeviceIdentifier(vendorID: 0, productID: 0, isKeyboard: true)]

                let kURL = URL(fileURLWithPath: karabinerPath)
                let existing = try? Data(contentsOf: kURL)
                let merged = try KarabinerConfigGenerator.mergeProfile(
                    into: existing,
                    builtInDevices: builtIns,
                    config: config
                )
                try FileManager.default.createDirectory(at: kURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try merged.write(to: kURL, options: .atomic)
                print("Configured Karabiner profile 'Win11' at \(kURL.path)")
                return true
            } catch {
                fputs("Config generation error: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }

        if args.contains("--remove-karabiner-profile") {
            var karabinerPath = (NSHomeDirectory() as NSString).appendingPathComponent(".config/karabiner/karabiner.json")
            if let kIdx = args.firstIndex(of: "--karabiner-path"), args.indices.contains(kIdx + 1) {
                karabinerPath = (args[kIdx + 1] as NSString).expandingTildeInPath
            }
            let kURL = URL(fileURLWithPath: karabinerPath)
            if let existing = try? Data(contentsOf: kURL),
               let updated = try? KarabinerConfigGenerator.removeWin11Profile(from: existing) {
                try? updated.write(to: kURL, options: .atomic)
            }
            return true
        }

        if args.contains("--check-permissions") {
            MainActor.assumeIsolated {
                print("Accessibility:    \(AccessibilityBridge.hasAccessibilityPermission(prompt: false) ? "granted" : "missing")")
                print("Input Monitoring: \(AccessibilityBridge.hasInputMonitoringPermission() ? "granted" : "missing")")
                print("Screen Recording: \(AccessibilityBridge.hasScreenRecordingPermission() ? "granted" : "missing")")
            }
            return true
        }

        if args.contains("--smoke-test") {
            do {
                try MainActor.assumeIsolated {
                    try runSmokeTest()
                }
                print("Smoke test passed.")
                return true
            } catch {
                fputs("Smoke test failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }

        return false
    }

    @MainActor
    private static func runSmokeTest() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Win11ShellSmoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = Win11ConfigStore(configURL: tempDir.appendingPathComponent("config.json"))
        try store.save(.default)
        let loaded = store.load()
        guard loaded == .default else {
            throw NSError(domain: "SmokeTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Config mismatch"])
        }

        let merged = try KarabinerConfigGenerator.mergeProfile(
            into: nil,
            builtInDevices: [KarabinerDeviceIdentifier(vendorID: 0, productID: 0, isKeyboard: true)],
            config: loaded
        )
        guard let parsed = try JSONSerialization.jsonObject(with: merged) as? [String: Any],
              (parsed["profiles"] as? [[String: Any]])?.count == 1
        else {
            throw NSError(domain: "SmokeTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "Karabiner JSON invalid"])
        }

        let iconURL = tempDir.appendingPathComponent("win11.png")
        try Win11IconRenderer.renderAppIconPNG(to: iconURL, size: 256)
        guard FileManager.default.fileExists(atPath: iconURL.path) else {
            throw NSError(domain: "SmokeTest", code: 3, userInfo: [NSLocalizedDescriptionKey: "Icon PNG missing"])
        }

        _ = AppCatalog.scanInstalledApps()
    }
}

@MainActor
final class ShellAppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: ShellCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = AccessibilityBridge.hasAccessibilityPermission(prompt: true)
        coordinator = ShellCoordinator()
    }
}

@MainActor
final class ShellCoordinator {
    private let configStore = Win11ConfigStore()
    private let model: RunningAppsModel
    private let system: SystemControlsBridge
    private let finderSuppressor: FinderSuppressor
    private let showDesktop: ShowDesktopController
    private let startMenu: StartMenuController
    private let quickSettings: QuickSettingsController
    private let calendarFlyout: CalendarFlyoutController
    private let auxFlyouts: AuxiliaryFlyoutsController
    private let hoverPreview: TaskbarHoverPreviewController
    private let windowBar: WindowChromeBarController
    private let taskbar: TaskbarCoordinator
    private let hotkeys: HotkeyBridge

    init() {
        let model = RunningAppsModel(configStore: configStore)
        let system = SystemControlsBridge()
        let finderSuppressor = FinderSuppressor(fileExplorerBundleID: model.config.fileExplorerBundleID)
        let showDesktop = ShowDesktopController()
        let startMenu = StartMenuController(model: model, system: system)
        let quickSettings = QuickSettingsController(model: model, system: system)
        let calendarFlyout = CalendarFlyoutController(model: model)
        let auxFlyouts = AuxiliaryFlyoutsController(model: model, system: system)
        let hoverPreview = TaskbarHoverPreviewController(model: model)
        let windowBar = WindowChromeBarController(model: model)
        let taskbar = TaskbarCoordinator(
            model: model,
            system: system,
            startMenu: startMenu,
            quickSettings: quickSettings,
            calendarFlyout: calendarFlyout,
            auxFlyouts: auxFlyouts,
            hoverPreview: hoverPreview,
            showDesktop: showDesktop
        )
        let hotkeys = HotkeyBridge()

        self.model = model
        self.system = system
        self.finderSuppressor = finderSuppressor
        self.showDesktop = showDesktop
        self.startMenu = startMenu
        self.quickSettings = quickSettings
        self.calendarFlyout = calendarFlyout
        self.auxFlyouts = auxFlyouts
        self.hoverPreview = hoverPreview
        self.windowBar = windowBar
        self.taskbar = taskbar
        self.hotkeys = hotkeys

        finderSuppressor.start()
        _ = hotkeys.start { [weak self] action in
            self?.handleHotkey(action)
        }
    }

    private func handleHotkey(_ action: ShellHotkeyAction) {
        switch action {
        case .toggleStartMenu:
            quickSettings.dismiss()
            calendarFlyout.dismiss()
            auxFlyouts.dismiss()
            startMenu.toggle(focusSearch: false)
        case .openStartSearch:
            quickSettings.dismiss()
            calendarFlyout.dismiss()
            auxFlyouts.dismiss()
            startMenu.toggle(focusSearch: true)
        case .closeOrQuitFrontWindow:
            windowBar.closeOrQuitFrontWindow()
        case .openFileExplorer:
            finderSuppressor.openFileExplorer()
        case .toggleShowDesktop:
            showDesktop.toggleShowDesktop()
        case .toggleQuickSettings:
            startMenu.dismiss()
            calendarFlyout.dismiss()
            auxFlyouts.dismiss()
            quickSettings.toggle()
        case .toggleCalendarFlyout:
            startMenu.dismiss()
            quickSettings.dismiss()
            auxFlyouts.dismiss()
            calendarFlyout.toggle()
        case .openSystemSettings:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        case .openTaskView:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
        case .snippingTool:
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            proc.arguments = ["-i", "-c"]
            try? proc.run()
        case .openTaskManager:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
        case .smartUnmaximizeOrMinimize:
            windowBar.smartUnmaximizeOrMinimize()
        }
    }
}
