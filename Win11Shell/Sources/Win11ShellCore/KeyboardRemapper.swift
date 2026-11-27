import CoreGraphics
import Foundation

public enum ShellCommandAction: Equatable, Sendable {
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
    case snapLeft
    case snapRight
    case snapMaximize
    case snapDownOrMinimize
    case switchDesktopLeft
    case switchDesktopRight
    case altTabNext(reverse: Bool)
    case altTabCommit
    case altTabCancel
}

public struct RemappedKeyEvent: Equatable, Sendable {
    public let keyCode: Int64
    public let flagsRaw: UInt64

    public init(keyCode: Int64, flagsRaw: UInt64) {
        self.keyCode = keyCode
        self.flagsRaw = flagsRaw
    }
}

public enum KeyDecision: Equatable, Sendable {
    case passthrough
    case suppress
    case remap(RemappedKeyEvent)
    case command(ShellCommandAction)
}

public enum KeyboardRemapper {
    // Virtual key codes from Carbon HIToolbox Events.h
    private enum KeyCode {
        static let a: Int64 = 0x00
        static let s: Int64 = 0x01
        static let d: Int64 = 0x02
        static let f: Int64 = 0x03
        static let h: Int64 = 0x04
        static let g: Int64 = 0x05
        static let z: Int64 = 0x06
        static let x: Int64 = 0x07
        static let c: Int64 = 0x08
        static let v: Int64 = 0x09
        static let b: Int64 = 0x0B
        static let q: Int64 = 0x0C
        static let w: Int64 = 0x0D
        static let e: Int64 = 0x0E
        static let r: Int64 = 0x0F
        static let y: Int64 = 0x10
        static let t: Int64 = 0x11
        static let one: Int64 = 0x12
        static let two: Int64 = 0x13
        static let three: Int64 = 0x14
        static let four: Int64 = 0x15
        static let six: Int64 = 0x16
        static let five: Int64 = 0x17
        static let equal: Int64 = 0x18
        static let nine: Int64 = 0x19
        static let seven: Int64 = 0x1A
        static let minus: Int64 = 0x1B
        static let eight: Int64 = 0x1C
        static let zero: Int64 = 0x1D
        static let rightBracket: Int64 = 0x1E
        static let o: Int64 = 0x1F
        static let u: Int64 = 0x20
        static let leftBracket: Int64 = 0x21
        static let i: Int64 = 0x22
        static let p: Int64 = 0x23
        static let returnKey: Int64 = 0x24
        static let l: Int64 = 0x25
        static let j: Int64 = 0x26
        static let k: Int64 = 0x28
        static let comma: Int64 = 0x2B
        static let slash: Int64 = 0x2C
        static let n: Int64 = 0x2D
        static let m: Int64 = 0x2E
        static let period: Int64 = 0x2F
        static let tab: Int64 = 0x30
        static let space: Int64 = 0x31
        static let backspace: Int64 = 0x33
        static let escape: Int64 = 0x35
        static let keypadEnter: Int64 = 0x4C
        static let f5: Int64 = 0x60
        static let home: Int64 = 0x73
        static let forwardDelete: Int64 = 0x75
        static let f4: Int64 = 0x76
        static let end: Int64 = 0x77
        static let leftArrow: Int64 = 0x7B
        static let rightArrow: Int64 = 0x7C
        static let downArrow: Int64 = 0x7D
        static let upArrow: Int64 = 0x7E
    }

    private static let relevantMask: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]

    /// Standard Ctrl+<key> -> Cmd+<key> keys (explicitly excluding Tab and Y, which has its own rule).
    private static let ctrlToCmdKeyCodes: Set<Int64> = [
        KeyCode.a, KeyCode.b, KeyCode.c, KeyCode.d, KeyCode.e, KeyCode.f, KeyCode.g, KeyCode.h,
        KeyCode.i, KeyCode.j, KeyCode.k, KeyCode.l, KeyCode.m, KeyCode.n, KeyCode.o, KeyCode.p,
        KeyCode.q, KeyCode.r, KeyCode.s, KeyCode.t, KeyCode.u, KeyCode.v, KeyCode.w, KeyCode.x,
        KeyCode.z,
        KeyCode.zero, KeyCode.one, KeyCode.two, KeyCode.three, KeyCode.four,
        KeyCode.five, KeyCode.six, KeyCode.seven, KeyCode.eight, KeyCode.nine,
        KeyCode.equal, KeyCode.minus, KeyCode.leftBracket, KeyCode.rightBracket,
        KeyCode.slash, KeyCode.comma, KeyCode.period, KeyCode.returnKey, KeyCode.space
    ]

    public static func decide(
        keyCode: Int64,
        flagsRaw: UInt64,
        frontmostBundleID: String?,
        config: Win11Config
    ) -> KeyDecision {
        let active = CGEventFlags(rawValue: flagsRaw).intersection(relevantMask)
        let preservedAlpha = flagsRaw & CGEventFlags.maskAlphaShift.rawValue

        if let globalDecision = decideGlobal(keyCode: keyCode, active: active, preservedAlpha: preservedAlpha) {
            return globalDecision
        }

        if frontmostBundleID == config.fileExplorerBundleID,
           let explorerDecision = decideFileExplorer(keyCode: keyCode, active: active, preservedAlpha: preservedAlpha) {
            return explorerDecision
        }

        let isTerminal = frontmostBundleID.map { config.terminalBundleIDs.contains($0) } ?? false
        if !isTerminal,
           let editingDecision = decideNonTerminal(keyCode: keyCode, active: active, preservedAlpha: preservedAlpha) {
            return editingDecision
        }

        return .passthrough
    }

    private static func decideGlobal(
        keyCode: Int64,
        active: CGEventFlags,
        preservedAlpha: UInt64
    ) -> KeyDecision? {
        // Alt+F4 -> Close or quit front window
        if active == .maskAlternate && keyCode == KeyCode.f4 {
            return .command(.closeOrQuitFrontWindow)
        }

        // Alt+Tab / Alt+Shift+Tab -> Custom Alt+Tab switcher
        if keyCode == KeyCode.tab {
            if active == .maskAlternate {
                return .command(.altTabNext(reverse: false))
            }
            if active == [.maskAlternate, .maskShift] {
                return .command(.altTabNext(reverse: true))
            }
        }

        // Ctrl+Shift+Esc -> Task Manager (Activity Monitor)
        if active == [.maskControl, .maskShift] && keyCode == KeyCode.escape {
            return .command(.openTaskManager)
        }

        // Win+Ctrl+Left/Right -> Virtual Desktops (macOS Spaces)
        if active == [.maskCommand, .maskControl] {
            if keyCode == KeyCode.leftArrow { return .command(.switchDesktopLeft) }
            if keyCode == KeyCode.rightArrow { return .command(.switchDesktopRight) }
        }

        // Win+Shift+S -> Snipping Tool
        if active == [.maskCommand, .maskShift] && keyCode == KeyCode.s {
            return .command(.snippingTool)
        }

        // Win+<key> global shortcuts (Cmd = Win after built-in hidutil swap)
        if active == .maskCommand {
            switch keyCode {
            case KeyCode.e: return .command(.openFileExplorer)
            case KeyCode.d: return .command(.toggleShowDesktop)
            case KeyCode.s: return .command(.openStartSearch)
            case KeyCode.a: return .command(.toggleQuickSettings)
            case KeyCode.n: return .command(.toggleCalendarFlyout)
            case KeyCode.i: return .command(.openSystemSettings)
            case KeyCode.tab: return .command(.openTaskView)
            case KeyCode.leftArrow: return .command(.snapLeft)
            case KeyCode.rightArrow: return .command(.snapRight)
            case KeyCode.upArrow: return .command(.snapMaximize)
            case KeyCode.downArrow: return .command(.snapDownOrMinimize)
            case KeyCode.l:
                return remap(KeyCode.q, flags: [.maskControl, .maskCommand], preservedAlpha: preservedAlpha)
            case KeyCode.period:
                return remap(KeyCode.space, flags: [.maskControl, .maskCommand], preservedAlpha: preservedAlpha)
            default:
                break
            }
        }

        return nil
    }

    private static func decideFileExplorer(
        keyCode: Int64,
        active: CGEventFlags,
        preservedAlpha: UInt64
    ) -> KeyDecision? {
        if active.isEmpty && keyCode == KeyCode.forwardDelete {
            return remap(KeyCode.backspace, flags: .maskCommand, preservedAlpha: preservedAlpha)
        }
        if active == .maskAlternate {
            switch keyCode {
            case KeyCode.upArrow:
                return remap(KeyCode.upArrow, flags: .maskCommand, preservedAlpha: preservedAlpha)
            case KeyCode.returnKey, KeyCode.keypadEnter:
                return remap(KeyCode.i, flags: .maskCommand, preservedAlpha: preservedAlpha)
            case KeyCode.d:
                return remap(KeyCode.l, flags: .maskCommand, preservedAlpha: preservedAlpha)
            default:
                break
            }
        }
        if active == .maskControl && keyCode == KeyCode.h {
            return remap(KeyCode.period, flags: [.maskCommand, .maskShift], preservedAlpha: preservedAlpha)
        }
        return nil
    }

    private static func decideNonTerminal(
        keyCode: Int64,
        active: CGEventFlags,
        preservedAlpha: UInt64
    ) -> KeyDecision? {
        // Ctrl+Y -> Cmd+Shift+Z (Redo)
        if active == .maskControl && keyCode == KeyCode.y {
            return remap(KeyCode.z, flags: [.maskCommand, .maskShift], preservedAlpha: preservedAlpha)
        }

        // Ctrl+Left/Right (+Shift) -> Opt+Left/Right (+Shift)
        if (active == .maskControl || active == [.maskControl, .maskShift])
            && (keyCode == KeyCode.leftArrow || keyCode == KeyCode.rightArrow) {
            var target: CGEventFlags = .maskAlternate
            if active.contains(.maskShift) { target.insert(.maskShift) }
            return remap(keyCode, flags: target, preservedAlpha: preservedAlpha)
        }

        // Ctrl+Backspace / Ctrl+Delete -> Opt+Backspace / Opt+Delete
        if active == .maskControl && (keyCode == KeyCode.backspace || keyCode == KeyCode.forwardDelete) {
            return remap(keyCode, flags: .maskAlternate, preservedAlpha: preservedAlpha)
        }

        // Ctrl+Home/End (+Shift) -> Cmd+Up/Down (+Shift) (evaluated before plain Home/End)
        if active == .maskControl || active == [.maskControl, .maskShift] {
            var target: CGEventFlags = .maskCommand
            if active.contains(.maskShift) { target.insert(.maskShift) }
            if keyCode == KeyCode.home {
                return remap(KeyCode.upArrow, flags: target, preservedAlpha: preservedAlpha)
            }
            if keyCode == KeyCode.end {
                return remap(KeyCode.downArrow, flags: target, preservedAlpha: preservedAlpha)
            }
        }

        // Home/End (+Shift) -> Cmd+Left/Right (+Shift)
        if active.isEmpty || active == .maskShift {
            var target: CGEventFlags = .maskCommand
            if active.contains(.maskShift) { target.insert(.maskShift) }
            if keyCode == KeyCode.home {
                return remap(KeyCode.leftArrow, flags: target, preservedAlpha: preservedAlpha)
            }
            if keyCode == KeyCode.end {
                return remap(KeyCode.rightArrow, flags: target, preservedAlpha: preservedAlpha)
            }
        }

        // Alt+Left/Right -> Cmd+[ / Cmd+]
        if active == .maskAlternate {
            if keyCode == KeyCode.leftArrow {
                return remap(KeyCode.leftBracket, flags: .maskCommand, preservedAlpha: preservedAlpha)
            }
            if keyCode == KeyCode.rightArrow {
                return remap(KeyCode.rightBracket, flags: .maskCommand, preservedAlpha: preservedAlpha)
            }
        }

        // Ctrl+F5 -> Cmd+Shift+R, F5 -> Cmd+R
        if keyCode == KeyCode.f5 {
            if active == .maskControl {
                return remap(KeyCode.r, flags: [.maskCommand, .maskShift], preservedAlpha: preservedAlpha)
            }
            if active.isEmpty {
                return remap(KeyCode.r, flags: .maskCommand, preservedAlpha: preservedAlpha)
            }
        }

        // Standard Ctrl+<key> (+Shift/Opt) -> Cmd+<key> (never Ctrl+Tab, never Win+Ctrl+<key>)
        if active.contains(.maskControl),
           !active.contains(.maskCommand),
           ctrlToCmdKeyCodes.contains(keyCode) {
            var target = active
            target.remove(.maskControl)
            target.insert(.maskCommand)
            return remap(keyCode, flags: target, preservedAlpha: preservedAlpha)
        }

        return nil
    }

    private static func remap(
        _ keyCode: Int64,
        flags: CGEventFlags,
        preservedAlpha: UInt64
    ) -> KeyDecision {
        .remap(RemappedKeyEvent(keyCode: keyCode, flagsRaw: flags.rawValue | preservedAlpha))
    }
}
