import AppKit
import CoreGraphics
import Foundation

public enum ShellHotkeyAction: Sendable {
    case toggleStartMenu
    case openStartSearch
    case closeOrQuitFrontWindow
    case openFileExplorer
    case toggleShowDesktop
    case toggleQuickSettings
    case toggleCalendarFlyout
    case openSystemSettings
    case openTaskView
    case snippingTool
    case openTaskManager
    case smartUnmaximizeOrMinimize
}

@MainActor
public final class HotkeyBridge {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var handler: ((ShellHotkeyAction) -> Void)?

    public init() {}

    @discardableResult
    public func start(handler: @escaping (ShellHotkeyAction) -> Void) -> Bool {
        self.handler = handler
        stop()

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let bridge = Unmanaged<HotkeyBridge>.fromOpaque(refcon).takeUnretainedValue()
                return bridge.handleTapEvent(type: type, event: event)
            },
            userInfo: userInfo
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
    }

    nonisolated private func handleTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Task { @MainActor [weak self] in
                if let tap = self?.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        if let action = Self.matchAction(keyCode: keyCode, flags: flags) {
            Task { @MainActor [weak self] in
                self?.handler?(action)
            }
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    nonisolated private static func matchAction(keyCode: Int64, flags: CGEventFlags) -> ShellHotkeyAction? {
        let relevant: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
        let active = flags.intersection(relevant)
        let hyper: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        let hyperShift: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]

        // F18 (79) -> Start Menu, F19 (80) -> Close/Quit Window
        if active.isEmpty {
            if keyCode == 79 { return .toggleStartMenu }
            if keyCode == 80 { return .closeOrQuitFrontWindow }
            return nil
        }

        if active == hyperShift && keyCode == 1 { // S
            return .snippingTool
        }

        if active == hyper {
            switch keyCode {
            case 14: return .openFileExplorer        // E
            case 2:  return .toggleShowDesktop       // D
            case 1:  return .openStartSearch         // S
            case 0:  return .toggleQuickSettings     // A
            case 45: return .toggleCalendarFlyout    // N
            case 34: return .openSystemSettings      // I
            case 48: return .openTaskView            // Tab
            case 53: return .openTaskManager         // Escape
            case 125: return .smartUnmaximizeOrMinimize // Down Arrow
            default: return nil
            }
        }

        return nil
    }
}
