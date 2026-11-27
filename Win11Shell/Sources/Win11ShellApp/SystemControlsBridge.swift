import AppKit
import AudioToolbox
import CoreAudio
import CoreWLAN
import Foundation
import IOKit.ps
import Observation

// Dynamic brightness lookup via private DisplayServices framework (fails gracefully if unavailable)
private typealias DisplayServicesGetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
private typealias DisplayServicesSetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

public struct BatteryStatus: Equatable, Sendable {
    public let percentage: Int
    public let isCharging: Bool
    public let isPluggedIn: Bool
    public let present: Bool
}

public struct SystemStats: Equatable, Sendable {
    public let cpuPercent: Int
    public let memoryUsedGB: Double
    public let memoryTotalGB: Double
}

@MainActor
@Observable
public final class SystemControlsBridge {
    public var volume: Double = 0.5
    public var isMuted: Bool = false
    public var brightness: Double = 0.7
    public var hasBrightnessControl: Bool = false
    public var wifiOn: Bool = false
    public var wifiSSID: String = "Disconnected"
    public var bluetoothOn: Bool = false
    public var isDarkMode: Bool = true
    public var topMenuBarHidden: Bool = true
    public var hasAccessibilityPermission: Bool = false
    public var hasInputMonitoringPermission: Bool = false
    public var hasScreenRecordingPermission: Bool = false
    public var battery = BatteryStatus(percentage: 100, isCharging: false, isPluggedIn: true, present: false)
    public var stats = SystemStats(cpuPercent: 0, memoryUsedGB: 0, memoryTotalGB: 36)

    private var timer: Timer?
    private let displayServicesHandle: UnsafeMutableRawPointer?
    private let getBrightnessFn: DisplayServicesGetBrightnessFn?
    private let setBrightnessFn: DisplayServicesSetBrightnessFn?
    private var isRefreshingBluetooth = false
    private var lastBluetoothCheck: Date = .distantPast

    public init() {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        let handle = dlopen(path, RTLD_LAZY)
        self.displayServicesHandle = handle
        if let handle {
            if let sym = dlsym(handle, "DisplayServicesGetBrightness") {
                self.getBrightnessFn = unsafeBitCast(sym, to: DisplayServicesGetBrightnessFn.self)
            } else {
                self.getBrightnessFn = nil
            }
            if let sym = dlsym(handle, "DisplayServicesSetBrightness") {
                self.setBrightnessFn = unsafeBitCast(sym, to: DisplayServicesSetBrightnessFn.self)
            } else {
                self.setBrightnessFn = nil
            }
        } else {
            self.getBrightnessFn = nil
            self.setBrightnessFn = nil
        }

        refresh(forceBluetooth: true)
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    public func refresh(forceBluetooth: Bool = false) {
        refreshAudio()
        refreshBrightness()
        refreshWiFi()
        refreshBluetooth(force: forceBluetooth)
        refreshAppearanceAndMenuBar()
        refreshPermissions()
        refreshBattery()
        refreshStats()
    }

    public func refreshPermissions() {
        hasAccessibilityPermission = AccessibilityBridge.hasAccessibilityPermission(prompt: false)
        hasInputMonitoringPermission = AccessibilityBridge.hasInputMonitoringPermission()
        hasScreenRecordingPermission = AccessibilityBridge.hasScreenRecordingPermission()
    }

    // MARK: - Audio

    private func defaultOutputDevice() -> AudioDeviceID {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        return deviceID
    }

    public func refreshAudio() {
        let dev = defaultOutputDevice()
        guard dev != kAudioObjectUnknown else { return }

        var vol: Float32 = 0.5
        var volSize = UInt32(MemoryLayout<Float32>.size)
        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(dev, &volAddr, 0, nil, &volSize, &vol) == noErr {
            volume = Double(max(0, min(1, vol)))
        }

        var muted: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(dev, &muteAddr, 0, nil, &muteSize, &muted) == noErr {
            isMuted = muted != 0
        }
    }

    public func setVolume(_ newVolume: Double) {
        let clamped = Float32(max(0, min(1, newVolume)))
        volume = Double(clamped)
        let dev = defaultOutputDevice()
        guard dev != kAudioObjectUnknown else { return }
        var value = clamped
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        if clamped > 0 && isMuted {
            setMuted(false)
        }
    }

    public func setMuted(_ mute: Bool) {
        isMuted = mute
        let dev = defaultOutputDevice()
        guard dev != kAudioObjectUnknown else { return }
        var val: UInt32 = mute ? 1 : 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &val)
    }

    // MARK: - Brightness

    public func refreshBrightness() {
        guard let fn = getBrightnessFn else {
            hasBrightnessControl = false
            return
        }
        var value: Float = 0.7
        if fn(CGMainDisplayID(), &value) == 0 {
            hasBrightnessControl = true
            brightness = Double(max(0, min(1, value)))
        } else {
            hasBrightnessControl = false
        }
    }

    public func setBrightness(_ newValue: Double) {
        let clamped = Float(max(0.05, min(1, newValue)))
        brightness = Double(clamped)
        _ = setBrightnessFn?(CGMainDisplayID(), clamped)
    }

    // MARK: - Wi-Fi & Bluetooth (TCC-safe, external CLI lookup)

    public func refreshWiFi() {
        if let iface = CWWiFiClient.shared().interface() {
            wifiOn = iface.powerOn()
            wifiSSID = iface.ssid() ?? (wifiOn ? "Wi-Fi" : "Off")
        }
    }

    public func toggleWiFi() {
        let ifaceName = CWWiFiClient.shared().interface()?.interfaceName ?? "en0"
        let nextState = wifiOn ? "off" : "on"
        Task.detached {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
            proc.arguments = ["-setairportpower", ifaceName, nextState]
            try? proc.run()
            proc.waitUntilExit()
            await MainActor.run { [weak self] in
                self?.refreshWiFi()
            }
        }
    }

    public func refreshBluetooth(force: Bool = false) {
        guard !isRefreshingBluetooth else { return }
        let now = Date()
        if !force && now.timeIntervalSince(lastBluetoothCheck) < 12.0 {
            return
        }
        isRefreshingBluetooth = true
        lastBluetoothCheck = now

        Task.detached(priority: .utility) {
            let powered = Self.readBluetoothPowerStateSafely()
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let powered {
                    self.bluetoothOn = powered
                }
                self.isRefreshingBluetooth = false
            }
        }
    }

    nonisolated private static func readBluetoothPowerStateSafely() -> Bool? {
        // 1. Fast preferences read (present on some macOS releases) without triggering Bluetooth TCC
        let defaultsProc = Process()
        let defaultsOut = Pipe()
        defaultsProc.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        defaultsProc.arguments = ["read", "/Library/Preferences/com.apple.Bluetooth", "ControllerPowerState"]
        defaultsProc.standardOutput = defaultsOut
        defaultsProc.standardError = FileHandle.nullDevice
        if (try? defaultsProc.run()) != nil {
            defaultsProc.waitUntilExit()
            if defaultsProc.terminationStatus == 0 {
                let data = defaultsOut.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if text == "1" { return true }
                if text == "0" { return false }
            }
        }

        // 2. Fallback via system_profiler CLI (external process, avoids TCC crash in Win11ShellApp)
        let spProc = Process()
        let spOut = Pipe()
        spProc.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        spProc.arguments = ["SPBluetoothDataType", "-json"]
        spProc.standardOutput = spOut
        spProc.standardError = FileHandle.nullDevice
        guard (try? spProc.run()) != nil else { return nil }
        let data = spOut.fileHandleForReading.readDataToEndOfFile()
        spProc.waitUntilExit()
        guard spProc.terminationStatus == 0,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["SPBluetoothDataType"] as? [[String: Any]],
              let props = entries.first?["controller_properties"] as? [String: Any],
              let state = props["controller_state"] as? String
        else {
            return nil
        }
        return state == "attrib_on"
    }

    public func openBluetoothSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Appearance & Top Menu Bar

    public func refreshAppearanceAndMenuBar() {
        let style = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
        isDarkMode = (style?.lowercased() == "dark")
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        topMenuBarHidden = (global?["_HIHideMenuBar"] as? Bool) ?? false
    }

    public func toggleDarkMode() {
        let nextDark = !isDarkMode
        Task.detached {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", "tell application \"System Events\" to tell appearance preferences to set dark mode to \(nextDark ? "true" : "false")"]
            try? proc.run()
            proc.waitUntilExit()
            await MainActor.run { [weak self] in
                self?.isDarkMode = nextDark
            }
        }
    }

    public func setTopMenuBarHidden(_ hidden: Bool) {
        topMenuBarHidden = hidden
        Task.detached {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            proc.arguments = ["write", "-g", "_HIHideMenuBar", "-bool", hidden ? "true" : "false"]
            try? proc.run()
            proc.waitUntilExit()
            let ui = Process()
            ui.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            ui.arguments = ["SystemUIServer"]
            try? ui.run()
        }
    }

    // MARK: - Battery & System Stats

    public func refreshBattery() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else {
            battery = BatteryStatus(percentage: 100, isCharging: false, isPluggedIn: true, present: false)
            return
        }

        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
            else {
                continue
            }
            let current = (desc[kIOPSCurrentCapacityKey] as? Int) ?? 100
            let maxCap = max(1, (desc[kIOPSMaxCapacityKey] as? Int) ?? 100)
            let pct = max(0, min(100, Int(round(Double(current) * 100.0 / Double(maxCap)))))
            let charging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
            let sourceState = (desc[kIOPSPowerSourceStateKey] as? String) ?? ""
            let plugged = charging || sourceState == kIOPSACPowerValue
            battery = BatteryStatus(percentage: pct, isCharging: charging, isPluggedIn: plugged, present: true)
            return
        }

        battery = BatteryStatus(percentage: 100, isCharging: false, isPluggedIn: true, present: false)
    }

    public func refreshStats() {
        let totalMem = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let hostPort = mach_host_self()
        var usedMem = totalMem * 0.4
        let kerr = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        if kerr == KERN_SUCCESS {
            var vmPageSize: vm_size_t = 0
            host_page_size(hostPort, &vmPageSize)
            let pageSize = Double(vmPageSize > 0 ? vmPageSize : 16384)
            let active = Double(vmStats.active_count + vmStats.wire_count + vmStats.compressor_page_count) * pageSize
            usedMem = active / 1_073_741_824.0
        }

        var loadAvg = [Double](repeating: 0, count: 3)
        getloadavg(&loadAvg, 3)
        let cores = Double(max(1, ProcessInfo.processInfo.processorCount))
        let cpuPct = max(1, min(100, Int(round((loadAvg[0] / cores) * 100.0))))

        stats = SystemStats(cpuPercent: cpuPct, memoryUsedGB: usedMem, memoryTotalGB: totalMem)
    }

    // MARK: - Power Actions

    public func lockScreen() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        proc.arguments = ["displaysleepnow"]
        try? proc.run()
    }

    public func sleepSystem() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        proc.arguments = ["sleepnow"]
        try? proc.run()
    }

    public func restartSystem() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", "tell application \"System Events\" to restart"]
        try? proc.run()
    }

    public func shutDownSystem() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", "tell application \"System Events\" to shut down"]
        try? proc.run()
    }

    public func signOutUser() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", "tell application \"System Events\" to log out"]
        try? proc.run()
    }
}
