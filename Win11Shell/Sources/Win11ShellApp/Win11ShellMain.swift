import AppKit
import CoreGraphics
import Foundation
import Win11ShellCore

public enum ShellLogger {
    private static let queue = DispatchQueue(label: "com.hackedple.win11shell.logger")

    public static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
            .appendingPathComponent("Win11Shell.log")
    }

    public static func log(_ message: String) {
        let timestamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))
        let line = "[\(timestamp)] \(message)\n"
        queue.async {
            let url = logURL
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}

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

        if args.contains("--hidutil-swap-json") {
            print(HIDMappingGenerator.builtInSwapPropertyJSON())
            return true
        }

        if args.contains("--hidutil-reset-json") {
            print(HIDMappingGenerator.resetPropertyJSON())
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

        let swapJSON = HIDMappingGenerator.builtInSwapPropertyJSON()
        let resetJSON = HIDMappingGenerator.resetPropertyJSON()
        let matchingJSON = HIDMappingGenerator.builtInMatchingJSON()
        guard let swapData = swapJSON.data(using: .utf8),
              let swapObj = try JSONSerialization.jsonObject(with: swapData) as? [String: Any],
              (swapObj["UserKeyMapping"] as? [[String: Any]])?.count == 4,
              let resetData = resetJSON.data(using: .utf8),
              let resetObj = try JSONSerialization.jsonObject(with: resetData) as? [String: Any],
              (resetObj["UserKeyMapping"] as? [Any])?.isEmpty == true,
              let matchData = matchingJSON.data(using: .utf8),
              let matchObj = try JSONSerialization.jsonObject(with: matchData) as? [String: Any],
              (matchObj["Built-In"] as? Bool) == true
        else {
            throw NSError(domain: "SmokeTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "HID mapping JSON invalid"])
        }

        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)
        let leftSnap = WindowChromeGeometry.snapAXFrame(
            for: .leftHalf,
            screenFrameCocoa: screen,
            visibleFrameCocoa: visible,
            primaryScreenHeight: 982,
            barHeight: 28,
            taskbarHeight: 48
        )
        guard leftSnap.width == 756, leftSnap.height == 868 else {
            throw NSError(domain: "SmokeTest", code: 3, userInfo: [NSLocalizedDescriptionKey: "Snap geometry invalid"])
        }

        let iconURL = tempDir.appendingPathComponent("win11.png")
        try Win11IconRenderer.renderAppIconPNG(to: iconURL, size: 256)
        guard FileManager.default.fileExists(atPath: iconURL.path) else {
            throw NSError(domain: "SmokeTest", code: 4, userInfo: [NSLocalizedDescriptionKey: "Icon PNG missing"])
        }

        _ = AppCatalog.scanInstalledApps()
    }
}

@MainActor
final class ShellAppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: ShellCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let axGranted = AccessibilityBridge.hasAccessibilityPermission(prompt: true)
        let inputGranted = AccessibilityBridge.hasInputMonitoringPermission()
        let screenGranted = AccessibilityBridge.hasScreenRecordingPermission()
        ShellLogger.log("Win11Shell starting (AX=\(axGranted), InputMonitoring=\(inputGranted), ScreenRecording=\(screenGranted))")
        coordinator = ShellCoordinator()
    }
}

@MainActor
final class ShellCoordinator {
    private static let syntheticEventTag: Int64 = 0x57313153

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
    private let windowSnap: WindowSnapManager
    private let windowBar: WindowChromeBarController
    private let taskbar: TaskbarCoordinator
    private let altTabSwitcher: AltTabSwitcherController
    private let keyboardEngine: CustomKeyboardEngine

    init() {
        let model = RunningAppsModel(configStore: configStore)
        if !FileManager.default.fileExists(atPath: configStore.configURL.path) {
            try? configStore.save(model.config)
        }
        let system = SystemControlsBridge()
        let finderSuppressor = FinderSuppressor(fileExplorerBundleID: model.config.fileExplorerBundleID)
        let showDesktop = ShowDesktopController()
        let startMenu = StartMenuController(model: model, system: system)
        let quickSettings = QuickSettingsController(model: model, system: system)
        let calendarFlyout = CalendarFlyoutController(model: model)
        let auxFlyouts = AuxiliaryFlyoutsController(model: model, system: system)
        let hoverPreview = TaskbarHoverPreviewController(model: model)
        let windowSnap = WindowSnapManager(model: model)
        let windowBar = WindowChromeBarController(model: model, snapManager: windowSnap)
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
        let altTabSwitcher = AltTabSwitcherController(model: model)
        let keyboardEngine = CustomKeyboardEngine(configProvider: { [weak model] in
            model?.config ?? .default
        })

        self.model = model
        self.system = system
        self.finderSuppressor = finderSuppressor
        self.showDesktop = showDesktop
        self.startMenu = startMenu
        self.quickSettings = quickSettings
        self.calendarFlyout = calendarFlyout
        self.auxFlyouts = auxFlyouts
        self.hoverPreview = hoverPreview
        self.windowSnap = windowSnap
        self.windowBar = windowBar
        self.taskbar = taskbar
        self.altTabSwitcher = altTabSwitcher
        self.keyboardEngine = keyboardEngine

        windowSnap.onWindowFrameChanged = { [weak windowBar] in
            windowBar?.syncActiveWindow()
        }

        _ = windowSnap.normalizeVisibleWindows()
        windowBar.syncActiveWindow()
        finderSuppressor.start()

        Self.applyBuiltInHIDSwapAsync()

        let tapStarted = keyboardEngine.start { [weak self] action in
            self?.handleAction(action)
        }
        ShellLogger.log("CustomKeyboardEngine event tap started: \(tapStarted)")
    }

    private static func applyBuiltInHIDSwapAsync() {
        let matchingJSON = HIDMappingGenerator.builtInMatchingJSON()
        let swapJSON = HIDMappingGenerator.builtInSwapPropertyJSON()
        Task.detached(priority: .userInitiated) {
            let proc = Process()
            let errPipe = Pipe()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
            proc.arguments = ["property", "--matching", matchingJSON, "--set", swapJSON]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = errPipe
            do {
                try proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus == 0 {
                    ShellLogger.log("Applied built-in hidutil Option<->Command swap")
                } else {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    ShellLogger.log("hidutil swap exited with status \(proc.terminationStatus): \(errMsg)")
                }
            } catch {
                ShellLogger.log("Failed to run hidutil swap: \(error.localizedDescription)")
            }
        }
    }

    private func handleAction(_ action: ShellCommandAction) {
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
        case .snapLeft:
            windowSnap.snapLeft()
        case .snapRight:
            windowSnap.snapRight()
        case .snapMaximize:
            windowSnap.toggleMaximize()
        case .snapDownOrMinimize:
            windowSnap.smartDownOrMinimize()
        case .switchDesktopLeft:
            postSyntheticKey(virtualKey: 123, flags: .maskControl)
        case .switchDesktopRight:
            postSyntheticKey(virtualKey: 124, flags: .maskControl)
        case .altTabNext(let reverse):
            altTabSwitcher.step(reverse: reverse)
        case .altTabCommit:
            altTabSwitcher.commitSelection()
        case .altTabCancel:
            altTabSwitcher.cancel()
        }
    }

    private func postSyntheticKey(virtualKey: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: false)
        else {
            return
        }
        down.flags = flags
        up.flags = flags
        down.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventTag)
        up.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventTag)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
