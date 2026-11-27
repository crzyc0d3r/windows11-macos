import CoreGraphics
import Testing
@testable import Win11ShellCore

@Suite("Solo Win Tap Detector Tests")
struct SoloWinTapTests {
    private static let cmd = CGEventFlags.maskCommand.rawValue
    private static let shift = CGEventFlags.maskShift.rawValue
    private static let alt = CGEventFlags.maskAlternate.rawValue
    private static let ctrl = CGEventFlags.maskControl.rawValue

    private static let winKeyCodes: [Int64] = [
        55, // Left Command (external keyboard)
        54, // Right Command (external keyboard)
        58, // Left Option (hidutil-swapped built-in MacBook keyboard)
        61  // Right Option (hidutil-swapped built-in MacBook keyboard)
    ]

    @Test("Solo tap succeeds for Left/Right Command and Option keyCodes when flags transition through .maskCommand")
    func soloTapAllSupportedKeyCodes() {
        var detector = SoloWinTapDetector()

        for (index, keyCode) in Self.winKeyCodes.enumerated() {
            let t0 = Double(index + 1) * 10.0
            #expect(detector.handleFlagsChanged(keyCode: keyCode, flagsRaw: Self.cmd, now: t0) == false)
            #expect(detector.handleFlagsChanged(keyCode: keyCode, flagsRaw: 0, now: t0 + 0.120) == true)
        }
    }

    @Test("Tap threshold accepts 490ms and ignores 550ms")
    func thresholdBoundary() {
        var detector = SoloWinTapDetector()

        // 490ms succeeds
        #expect(detector.handleFlagsChanged(keyCode: 55, flagsRaw: Self.cmd, now: 1.000) == false)
        #expect(detector.handleFlagsChanged(keyCode: 55, flagsRaw: 0, now: 1.490) == true)

        // 550ms ignored
        #expect(detector.handleFlagsChanged(keyCode: 54, flagsRaw: Self.cmd, now: 5.000) == false)
        #expect(detector.handleFlagsChanged(keyCode: 54, flagsRaw: 0, now: 5.550) == false)

        // Clean recovery after timed-out hold
        #expect(detector.handleFlagsChanged(keyCode: 58, flagsRaw: Self.cmd, now: 6.000) == false)
        #expect(detector.handleFlagsChanged(keyCode: 58, flagsRaw: 0, now: 6.490) == true)
    }

    @Test("Win+E keyDown cancels solo Win tap and resets cleanly for next tap")
    func cancelsOnKeyDown() {
        var detector = SoloWinTapDetector()

        #expect(detector.handleFlagsChanged(keyCode: 55, flagsRaw: Self.cmd, now: 10.0) == false)
        detector.cancel() // Win+E keyDown
        #expect(detector.handleFlagsChanged(keyCode: 55, flagsRaw: 0, now: 10.1) == false)

        // Next solo tap works immediately
        #expect(detector.handleFlagsChanged(keyCode: 54, flagsRaw: Self.cmd, now: 11.0) == false)
        #expect(detector.handleFlagsChanged(keyCode: 54, flagsRaw: 0, now: 11.1) == true)
    }

    @Test("Win+Click mouseDown cancels solo Win tap and resets cleanly")
    func cancelsOnMouseClick() {
        var detector = SoloWinTapDetector()

        #expect(detector.handleFlagsChanged(keyCode: 58, flagsRaw: Self.cmd, now: 20.0) == false)
        detector.cancel() // .leftMouseDown / .rightMouseDown / .otherMouseDown
        #expect(detector.handleFlagsChanged(keyCode: 58, flagsRaw: 0, now: 20.15) == false)

        #expect(detector.handleFlagsChanged(keyCode: 61, flagsRaw: Self.cmd, now: 21.0) == false)
        #expect(detector.handleFlagsChanged(keyCode: 61, flagsRaw: 0, now: 21.15) == true)
    }

    @Test("Extra modifier flags (Shift/Option/Control) cancel solo Win tap regardless of release order")
    func cancelsOnExtraModifiers() {
        var detector = SoloWinTapDetector()

        // Win down -> Shift down -> Shift up -> Win up
        #expect(detector.handleFlagsChanged(keyCode: 55, flagsRaw: Self.cmd, now: 30.0) == false)
        #expect(detector.handleFlagsChanged(keyCode: 56, flagsRaw: Self.cmd | Self.shift, now: 30.05) == false)
        #expect(detector.handleFlagsChanged(keyCode: 56, flagsRaw: Self.cmd, now: 30.10) == false)
        #expect(detector.handleFlagsChanged(keyCode: 55, flagsRaw: 0, now: 30.15) == false)

        // Shift down -> Win down -> Shift up -> Win up
        #expect(detector.handleFlagsChanged(keyCode: 56, flagsRaw: Self.shift, now: 31.0) == false)
        #expect(detector.handleFlagsChanged(keyCode: 54, flagsRaw: Self.cmd | Self.shift, now: 31.05) == false)
        #expect(detector.handleFlagsChanged(keyCode: 56, flagsRaw: Self.cmd, now: 31.10) == false)
        #expect(detector.handleFlagsChanged(keyCode: 54, flagsRaw: 0, now: 31.15) == false)

        // Win + Alt / Win + Ctrl
        #expect(detector.handleFlagsChanged(keyCode: 55, flagsRaw: Self.cmd, now: 32.0) == false)
        #expect(detector.handleFlagsChanged(keyCode: 58, flagsRaw: Self.cmd | Self.alt, now: 32.05) == false)
        #expect(detector.handleFlagsChanged(keyCode: 58, flagsRaw: Self.cmd, now: 32.10) == false)
        #expect(detector.handleFlagsChanged(keyCode: 55, flagsRaw: 0, now: 32.15) == false)

        #expect(detector.handleFlagsChanged(keyCode: 55, flagsRaw: Self.cmd, now: 33.0) == false)
        #expect(detector.handleFlagsChanged(keyCode: 59, flagsRaw: Self.cmd | Self.ctrl, now: 33.05) == false)
        #expect(detector.handleFlagsChanged(keyCode: 55, flagsRaw: 0, now: 33.15) == false)

        // Plain Option / Shift / Control never trigger
        #expect(detector.handleFlagsChanged(keyCode: 58, flagsRaw: Self.alt, now: 34.0) == false)
        #expect(detector.handleFlagsChanged(keyCode: 58, flagsRaw: 0, now: 34.1) == false)

        // Clean subsequent solo tap succeeds
        #expect(detector.handleFlagsChanged(keyCode: 55, flagsRaw: Self.cmd, now: 35.0) == false)
        #expect(detector.handleFlagsChanged(keyCode: 55, flagsRaw: 0, now: 35.2) == true)
    }

    @Test("Consecutive solo Win taps work repeatedly and non-relevant flags like CapsLock do not block")
    func consecutiveTapsAndIrrelevantFlags() {
        var detector = SoloWinTapDetector()

        for step in 0..<5 {
            let base = 40.0 + Double(step)
            #expect(detector.handleFlagsChanged(keyCode: 55, flagsRaw: Self.cmd, now: base) == false)
            #expect(detector.handleFlagsChanged(keyCode: 55, flagsRaw: 0, now: base + 0.08) == true)
        }

        // CapsLock (maskAlphaShift) alongside solo .maskCommand is ignored by relevantMask
        let capsAndCmd = Self.cmd | CGEventFlags.maskAlphaShift.rawValue
        #expect(detector.handleFlagsChanged(keyCode: 54, flagsRaw: capsAndCmd, now: 50.0) == false)
        #expect(detector.handleFlagsChanged(keyCode: 54, flagsRaw: CGEventFlags.maskAlphaShift.rawValue, now: 50.1) == true)

        // After reset(), fresh tap succeeds
        detector.reset()
        #expect(detector.handleFlagsChanged(keyCode: 61, flagsRaw: Self.cmd, now: 51.0) == false)
        #expect(detector.handleFlagsChanged(keyCode: 61, flagsRaw: 0, now: 51.1) == true)
    }
}
