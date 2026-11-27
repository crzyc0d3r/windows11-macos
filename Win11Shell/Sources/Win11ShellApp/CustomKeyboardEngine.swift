import AppKit
import CoreGraphics
import Foundation
import Win11ShellCore

@MainActor
public final class CustomKeyboardEngine {
    nonisolated public static let syntheticEventTag: Int64 = 0x57313153
    private static let escapeKeyCode: Int64 = 53
    private static let relevantMask: CGEventFlags = SoloWinTapDetector.relevantMask

    private enum TapEventKind: Sendable {
        case flagsChanged
        case keyDown
        case keyUp
    }

    private enum TapOutcome: Sendable {
        case passthrough
        case suppress
        case postSynthetic(RemappedKeyEvent, keyDown: Bool, isAutoRepeat: Bool)
    }

    private let configProvider: @MainActor () -> Win11Config
    private var actionHandler: (@MainActor (ShellCommandAction) -> Void)?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Solo Win tap state (mutated only on MainActor / main run loop)
    private var soloWinDetector = SoloWinTapDetector()

    // Alt+Tab session state
    private var isAltTabActive = false

    // KeyUp pairing so remapped or command-consumed keyDowns release cleanly
    private var remappedKeyDowns: [Int64: RemappedKeyEvent] = [:]
    private var suppressedKeyDowns: Set<Int64> = []

    public init(configProvider: @escaping @MainActor () -> Win11Config) {
        self.configProvider = configProvider
    }

    @discardableResult
    public func start(onAction: @escaping @MainActor (ShellCommandAction) -> Void) -> Bool {
        stop()
        self.actionHandler = onAction

        let mask = CGEventMask(
            (1 << CGEventType.keyDown.rawValue)
                | (1 << CGEventType.keyUp.rawValue)
                | (1 << CGEventType.flagsChanged.rawValue)
                | (1 << CGEventType.leftMouseDown.rawValue)
                | (1 << CGEventType.rightMouseDown.rawValue)
                | (1 << CGEventType.otherMouseDown.rawValue)
        )
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo -> Unmanaged<CGEvent>? in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let engine = Unmanaged<CustomKeyboardEngine>.fromOpaque(userInfo).takeUnretainedValue()
                return engine.handleTapCallback(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    public func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        actionHandler = nil
        soloWinDetector.reset()
        isAltTabActive = false
        remappedKeyDowns.removeAll()
        suppressedKeyDowns.removeAll()
    }

    nonisolated private func handleTapCallback(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Task { @MainActor [weak self] in
                if let tap = self?.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            }
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventTag {
            return Unmanaged.passUnretained(event)
        }

        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    soloWinDetector.cancel()
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.soloWinDetector.cancel()
                }
            }
            return Unmanaged.passUnretained(event)
        }

        let kind: TapEventKind
        switch type {
        case .flagsChanged: kind = .flagsChanged
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        default: return Unmanaged.passUnretained(event)
        }

        guard Thread.isMainThread else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flagsRaw = event.flags.rawValue
        let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        let outcome = MainActor.assumeIsolated {
            processEventOnMain(kind: kind, keyCode: keyCode, flagsRaw: flagsRaw, isAutoRepeat: isAutoRepeat)
        }

        switch outcome {
        case .passthrough:
            return Unmanaged.passUnretained(event)
        case .suppress:
            return nil
        case .postSynthetic(let remapped, let keyDown, let autoRepeat):
            Self.postSyntheticKey(remapped, keyDown: keyDown, isAutoRepeat: autoRepeat)
            return nil
        }
    }

    private func processEventOnMain(
        kind: TapEventKind,
        keyCode: Int64,
        flagsRaw: UInt64,
        isAutoRepeat: Bool
    ) -> TapOutcome {
        let flags = CGEventFlags(rawValue: flagsRaw)

        switch kind {
        case .flagsChanged:
            handleFlagsChanged(keyCode: keyCode, flags: flags)
            return .passthrough

        case .keyDown:
            soloWinDetector.cancel()

            let active = flags.intersection(Self.relevantMask)
            if isAltTabActive,
               keyCode == Self.escapeKeyCode,
               !active.contains(.maskControl),
               !active.contains(.maskCommand) {
                isAltTabActive = false
                suppressedKeyDowns.insert(keyCode)
                dispatchAction(.altTabCancel)
                return .suppress
            }

            let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            let decision = KeyboardRemapper.decide(
                keyCode: keyCode,
                flagsRaw: flagsRaw,
                frontmostBundleID: frontmostBundleID,
                config: configProvider()
            )

            switch decision {
            case .passthrough:
                return .passthrough

            case .suppress:
                suppressedKeyDowns.insert(keyCode)
                return .suppress

            case .command(let action):
                suppressedKeyDowns.insert(keyCode)
                if case .altTabNext = action {
                    isAltTabActive = true
                    dispatchAction(action)
                } else if !isAutoRepeat {
                    dispatchAction(action)
                }
                return .suppress

            case .remap(let remapped):
                remappedKeyDowns[keyCode] = remapped
                return .postSynthetic(remapped, keyDown: true, isAutoRepeat: isAutoRepeat)
            }

        case .keyUp:
            if suppressedKeyDowns.remove(keyCode) != nil {
                return .suppress
            }
            if let remapped = remappedKeyDowns.removeValue(forKey: keyCode) {
                return .postSynthetic(remapped, keyDown: false, isAutoRepeat: false)
            }
            return .passthrough
        }
    }

    private func handleFlagsChanged(keyCode: Int64, flags: CGEventFlags) {
        let active = flags.intersection(Self.relevantMask)

        if isAltTabActive && !active.contains(.maskAlternate) {
            isAltTabActive = false
            dispatchAction(.altTabCommit)
        }

        if soloWinDetector.handleFlagsChanged(keyCode: keyCode, flagsRaw: flags.rawValue) {
            dispatchAction(.toggleStartMenu)
        }
    }

    nonisolated private static func postSyntheticKey(
        _ remapped: RemappedKeyEvent,
        keyDown: Bool,
        isAutoRepeat: Bool
    ) {
        guard let synthetic = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(remapped.keyCode),
            keyDown: keyDown
        ) else {
            return
        }
        synthetic.flags = CGEventFlags(rawValue: remapped.flagsRaw)
        if isAutoRepeat {
            synthetic.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        }
        synthetic.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
        synthetic.post(tap: .cghidEventTap)
    }

    private func dispatchAction(_ action: ShellCommandAction) {
        let handler = actionHandler
        DispatchQueue.main.async {
            handler?(action)
        }
    }
}
