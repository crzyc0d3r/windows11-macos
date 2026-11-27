import Foundation

public enum HIDMappingGenerator {
    /// USB HID usage IDs for left/right Option and Command modifiers (Usage Page 0x07).
    private static let leftOptionUsage: UInt64 = 0x7000000E2
    private static let leftCommandUsage: UInt64 = 0x7000000E3
    private static let rightOptionUsage: UInt64 = 0x7000000E6
    private static let rightCommandUsage: UInt64 = 0x7000000E7

    /// macOS `hidutil` property JSON swapping Left Option <-> Left Command
    /// and Right Option <-> Right Command on the matched built-in keyboard.
    public static func builtInSwapPropertyJSON() -> String {
        let mappings: [[String: UInt64]] = [
            [
                "HIDKeyboardModifierMappingSrc": leftOptionUsage,
                "HIDKeyboardModifierMappingDst": leftCommandUsage
            ],
            [
                "HIDKeyboardModifierMappingSrc": leftCommandUsage,
                "HIDKeyboardModifierMappingDst": leftOptionUsage
            ],
            [
                "HIDKeyboardModifierMappingSrc": rightOptionUsage,
                "HIDKeyboardModifierMappingDst": rightCommandUsage
            ],
            [
                "HIDKeyboardModifierMappingSrc": rightCommandUsage,
                "HIDKeyboardModifierMappingDst": rightOptionUsage
            ]
        ]

        let payload: [String: Any] = ["UserKeyMapping": mappings]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else {
            return #"{"UserKeyMapping":[]}"#
        }
        return json
    }

    /// macOS `hidutil` property JSON that clears custom `UserKeyMapping` overrides.
    public static func resetPropertyJSON() -> String {
        #"{"UserKeyMapping":[]}"#
    }

    /// macOS `hidutil` `--matching` JSON targeting built-in Apple HID devices.
    public static func builtInMatchingJSON() -> String {
        #"{"Built-In":true}"#
    }
}
