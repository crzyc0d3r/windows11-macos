import CoreGraphics
import Foundation

/// Detects solo Windows-key taps across Left/Right Command and `hidutil`-swapped Option keyCodes.
public struct SoloWinTapDetector: Sendable {
    public static let defaultThresholdSeconds: TimeInterval = 0.500
    public static let relevantMask: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
    public static let supportedWinKeyCodes: Set<Int64> = [55, 54, 58, 61]

    public let thresholdSeconds: TimeInterval
    private var pressTime: TimeInterval?
    private var isEligible: Bool = false
    private var previousRelevantModifiers: CGEventFlags = []

    public init(thresholdSeconds: TimeInterval = SoloWinTapDetector.defaultThresholdSeconds) {
        self.thresholdSeconds = thresholdSeconds
    }

    /// Cancels any in-flight solo Win tap (e.g. on keyDown or mouseDown) without clearing active modifier state.
    public mutating func cancel() {
        pressTime = nil
        isEligible = false
    }

    /// Fully resets detector state (e.g. when stopping the event tap).
    public mutating func reset() {
        pressTime = nil
        isEligible = false
        previousRelevantModifiers = []
    }

    /// Processes a `flagsChanged` transition and returns `true` when a solo Win tap completes within the threshold.
    @discardableResult
    public mutating func handleFlagsChanged(
        keyCode: Int64,
        flagsRaw: UInt64,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        _ = keyCode
        let active = CGEventFlags(rawValue: flagsRaw).intersection(Self.relevantMask)
        defer { previousRelevantModifiers = active }

        if active == .maskCommand {
            if previousRelevantModifiers.isEmpty {
                pressTime = now
                isEligible = true
            } else if !isEligible {
                cancel()
            }
            return false
        }

        if active.isEmpty {
            defer { cancel() }
            if isEligible,
               let pressedAt = pressTime,
               now >= pressedAt,
               (now - pressedAt) <= thresholdSeconds {
                return true
            }
            return false
        }

        // Any extra modifier flag (.maskControl, .maskAlternate, .maskShift) cancels solo-tap eligibility.
        cancel()
        return false
    }
}
