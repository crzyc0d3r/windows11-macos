import Foundation

public struct KarabinerDeviceIdentifier: Equatable, Hashable, Sendable {
    public let vendorID: Int
    public let productID: Int
    public let isKeyboard: Bool

    public init(vendorID: Int, productID: Int, isKeyboard: Bool = true) {
        self.vendorID = vendorID
        self.productID = productID
        self.isKeyboard = isKeyboard
    }
}

public enum KarabinerConfigGenerator {
    public static let profileName = "Win11"

    public static func parseConnectedBuiltInDevices(from karabinerCLIJSON: Data) -> [KarabinerDeviceIdentifier] {
        guard let array = try? JSONSerialization.jsonObject(with: karabinerCLIJSON) as? [[String: Any]] else {
            return [KarabinerDeviceIdentifier(vendorID: 0, productID: 0, isKeyboard: true)]
        }

        var results: [KarabinerDeviceIdentifier] = []
        var seen: Set<KarabinerDeviceIdentifier> = []

        for entry in array {
            guard let isBuiltIn = entry["is_built_in_keyboard"] as? Bool, isBuiltIn,
                  let isKeyboard = entry["is_keyboard"] as? Bool, isKeyboard,
                  let identifiers = entry["device_identifiers"] as? [String: Any]
            else {
                continue
            }

            let vendorID = (identifiers["vendor_id"] as? Int) ?? 0
            let productID = (identifiers["product_id"] as? Int) ?? 0
            let id = KarabinerDeviceIdentifier(vendorID: vendorID, productID: productID, isKeyboard: true)
            if seen.insert(id).inserted {
                results.append(id)
            }
        }

        if results.isEmpty {
            results.append(KarabinerDeviceIdentifier(vendorID: 0, productID: 0, isKeyboard: true))
        }
        return results
    }

    public static func mergeProfile(
        into existingJSONData: Data?,
        builtInDevices: [KarabinerDeviceIdentifier],
        config: Win11Config
    ) throws -> Data {
        var root: [String: Any] = [:]
        if let existingJSONData,
           let parsed = try? JSONSerialization.jsonObject(with: existingJSONData) as? [String: Any] {
            root = parsed
        }

        var global = (root["global"] as? [String: Any]) ?? [:]
        global["check_for_updates_on_startup"] = global["check_for_updates_on_startup"] ?? true
        global["show_in_menu_bar"] = false
        global["show_profile_name_in_menu_bar"] = false
        root["global"] = global

        var profiles = (root["profiles"] as? [[String: Any]]) ?? []
        for idx in profiles.indices {
            profiles[idx]["selected"] = false
        }

        let win11Profile = buildWin11Profile(builtInDevices: builtInDevices, config: config)
        if let existingIndex = profiles.firstIndex(where: { ($0["name"] as? String) == profileName }) {
            profiles[existingIndex] = win11Profile
        } else {
            profiles.append(win11Profile)
        }
        root["profiles"] = profiles

        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    public static func removeWin11Profile(from existingJSONData: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: existingJSONData) as? [String: Any] else {
            return existingJSONData
        }
        var profiles = (root["profiles"] as? [[String: Any]]) ?? []
        profiles.removeAll { ($0["name"] as? String) == profileName }
        if !profiles.isEmpty && !profiles.contains(where: { ($0["selected"] as? Bool) == true }) {
            profiles[0]["selected"] = true
        }
        root["profiles"] = profiles
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    private static func buildWin11Profile(
        builtInDevices: [KarabinerDeviceIdentifier],
        config: Win11Config
    ) -> [String: Any] {
        let devicesList = builtInDevices.map { device -> [String: Any] in
            [
                "identifiers": [
                    "is_keyboard": device.isKeyboard,
                    "product_id": device.productID,
                    "vendor_id": device.vendorID
                ],
                "ignore": false,
                "manipulate_caps_lock_led": true,
                "simple_modifications": [
                    [
                        "from": ["key_code": "left_option"],
                        "to": [["key_code": "left_command"]]
                    ],
                    [
                        "from": ["key_code": "left_command"],
                        "to": [["key_code": "left_option"]]
                    ],
                    [
                        "from": ["key_code": "right_option"],
                        "to": [["key_code": "right_command"]]
                    ],
                    [
                        "from": ["key_code": "right_command"],
                        "to": [["key_code": "right_option"]]
                    ]
                ]
            ]
        }

        return [
            "name": profileName,
            "selected": true,
            "devices": devicesList,
            "virtual_hid_keyboard": [
                "keyboard_type_v2": "ansi"
            ],
            "complex_modifications": [
                "parameters": [
                    "basic.to_if_alone_timeout_milliseconds": 250,
                    "basic.to_if_held_down_threshold_milliseconds": 250,
                    "basic.simultaneous_threshold_milliseconds": 50
                ],
                "rules": buildRules(config: config)
            ]
        ]
    }

    private static func buildRules(config: Win11Config) -> [[String: Any]] {
        [
            ruleSoloWinKeyTap(),
            ruleWin11GlobalSystemHotkeys(),
            ruleFileExplorerExtras(bundleID: config.fileExplorerBundleID),
            ruleNonTerminalEditingAndAppShortcuts(terminalBundleIDs: config.terminalBundleIDs)
        ]
    }

    // Rule 1: Solo Win tap -> F18 (toggles Win11Shell Start Menu), while holding Win still behaves as Command/Win for combos.
    private static func ruleSoloWinKeyTap() -> [String: Any] {
        [
            "description": "Win11: Tap Win alone to open Start Menu (F18)",
            "manipulators": [
                [
                    "type": "basic",
                    "from": [
                        "key_code": "left_command",
                        "modifiers": ["optional": ["any"]]
                    ],
                    "to": [
                        ["key_code": "left_command", "lazy": true]
                    ],
                    "to_if_alone": [
                        ["key_code": "f18"]
                    ]
                ]
            ]
        ]
    }

    // Rule 2: Global Windows 11 system hotkeys (after device swap: left_control=Ctrl, left_command=Win, left_option=Alt).
    private static func ruleWin11GlobalSystemHotkeys() -> [String: Any] {
        let manipulators: [[String: Any]] = [
            // Alt+F4 -> F19 (Win11Shell close/quit-on-last-window)
            basic(fromKey: "f4", fromMods: ["option"], toKey: "f19", toMods: []),
            // Win+E -> FileExplorer
            basic(fromKey: "e", fromMods: ["command"], toKey: "e", toMods: ["control", "option", "command"]),
            // Win+D -> Show Desktop
            basic(fromKey: "d", fromMods: ["command"], toKey: "d", toMods: ["control", "option", "command"]),
            // Win+S -> Start Menu Search
            basic(fromKey: "s", fromMods: ["command"], toKey: "s", toMods: ["control", "option", "command"]),
            // Win+A -> Quick Settings
            basic(fromKey: "a", fromMods: ["command"], toKey: "a", toMods: ["control", "option", "command"]),
            // Win+N -> Calendar / Clock flyout
            basic(fromKey: "n", fromMods: ["command"], toKey: "n", toMods: ["control", "option", "command"]),
            // Win+I -> System Settings
            basic(fromKey: "i", fromMods: ["command"], toKey: "i", toMods: ["control", "option", "command"]),
            // Win+L -> Lock Screen
            basic(fromKey: "l", fromMods: ["command"], toKey: "q", toMods: ["control", "command"]),
            // Win+Tab -> Task View / Mission Control
            basic(fromKey: "tab", fromMods: ["command"], toKey: "tab", toMods: ["control", "option", "command"]),
            // Win+Shift+S -> Interactive Clipboard Snipping Tool
            basic(fromKey: "s", fromMods: ["command", "shift"], toKey: "s", toMods: ["control", "option", "command", "shift"]),
            // Win+. -> Emoji Picker
            basic(fromKey: "period", fromMods: ["command"], toKey: "spacebar", toMods: ["control", "command"]),
            // Ctrl+Shift+Esc -> Task Manager (Activity Monitor)
            basic(fromKey: "escape", fromMods: ["control", "shift"], toKey: "escape", toMods: ["control", "option", "command"]),
            // Win+Ctrl+Left/Right -> Virtual Desktops (macOS Spaces)
            basic(fromKey: "left_arrow", fromMods: ["command", "control"], toKey: "left_arrow", toMods: ["control"]),
            basic(fromKey: "right_arrow", fromMods: ["command", "control"], toKey: "right_arrow", toMods: ["control"]),
            // Win+Left/Right/Up -> Rectangle Left/Right/Maximize via Ctrl+Opt+Cmd+Arrow (avoids Home/End Cmd+Arrow collision)
            basic(fromKey: "left_arrow", fromMods: ["command"], toKey: "left_arrow", toMods: ["control", "option", "command"]),
            basic(fromKey: "right_arrow", fromMods: ["command"], toKey: "right_arrow", toMods: ["control", "option", "command"]),
            basic(fromKey: "up_arrow", fromMods: ["command"], toKey: "up_arrow", toMods: ["control", "option", "command"]),
            // Win+Down -> Win11Shell smart unmaximize or minimize
            basic(fromKey: "down_arrow", fromMods: ["command"], toKey: "down_arrow", toMods: ["control", "option", "command"])
        ]

        return [
            "description": "Win11: Global System & Window Management Hotkeys",
            "manipulators": manipulators
        ]
    }

    // Rule 3: FileExplorer.app Windows 11 key bindings.
    private static func ruleFileExplorerExtras(bundleID: String) -> [String: Any] {
        let escaped = NSRegularExpression.escapedPattern(for: bundleID)
        let condition: [String: Any] = [
            "type": "frontmost_application_if",
            "bundle_identifiers": ["^\(escaped)$"]
        ]

        let manipulators: [[String: Any]] = [
            basic(fromKey: "delete_forward", fromMods: [], optionalMods: [], toKey: "delete_or_backspace", toMods: ["command"], conditions: [condition]),
            basic(fromKey: "up_arrow", fromMods: ["option"], optionalMods: [], toKey: "up_arrow", toMods: ["command"], conditions: [condition]),
            basic(fromKey: "return_or_enter", fromMods: ["option"], optionalMods: [], toKey: "i", toMods: ["command"], conditions: [condition]),
            basic(fromKey: "d", fromMods: ["option"], optionalMods: [], toKey: "l", toMods: ["command"], conditions: [condition]),
            basic(fromKey: "h", fromMods: ["control"], optionalMods: [], toKey: "period", toMods: ["command", "shift"], conditions: [condition])
        ]

        return [
            "description": "Win11: FileExplorer Windows 11 Shortcut Extras",
            "manipulators": manipulators
        ]
    }

    // Rule 4: Standard Windows editing & Ctrl->Cmd shortcuts in all non-terminal apps.
    private static func ruleNonTerminalEditingAndAppShortcuts(terminalBundleIDs: [String]) -> [String: Any] {
        let patterns = terminalBundleIDs.map { "^\(NSRegularExpression.escapedPattern(for: $0))$" }
        let nonTerminalCondition: [String: Any] = [
            "type": "frontmost_application_unless",
            "bundle_identifiers": patterns
        ]
        let conditions = [nonTerminalCondition]

        var manipulators: [[String: Any]] = [
            // Ctrl+Y -> Cmd+Shift+Z (Redo)
            basic(fromKey: "y", fromMods: ["control"], optionalMods: [], toKey: "z", toMods: ["command", "shift"], conditions: conditions),
            // Ctrl+Left/Right -> Option+Left/Right (word navigation & selection)
            basic(fromKey: "left_arrow", fromMods: ["control"], optionalMods: ["shift"], toKey: "left_arrow", toMods: ["option"], conditions: conditions),
            basic(fromKey: "right_arrow", fromMods: ["control"], optionalMods: ["shift"], toKey: "right_arrow", toMods: ["option"], conditions: conditions),
            // Ctrl+Backspace / Ctrl+Delete -> Option+Backspace / Option+Delete
            basic(fromKey: "delete_or_backspace", fromMods: ["control"], optionalMods: [], toKey: "delete_or_backspace", toMods: ["option"], conditions: conditions),
            basic(fromKey: "delete_forward", fromMods: ["control"], optionalMods: [], toKey: "delete_forward", toMods: ["option"], conditions: conditions),
            // Ctrl+Home / Ctrl+End -> Cmd+Up / Cmd+Down (must appear BEFORE plain Home/End!)
            basic(fromKey: "home", fromMods: ["control"], optionalMods: ["shift"], toKey: "up_arrow", toMods: ["command"], conditions: conditions),
            basic(fromKey: "end", fromMods: ["control"], optionalMods: ["shift"], toKey: "down_arrow", toMods: ["command"], conditions: conditions),
            // Home / End -> Cmd+Left / Cmd+Right (line start/end)
            basic(fromKey: "home", fromMods: [], optionalMods: ["shift"], toKey: "left_arrow", toMods: ["command"], conditions: conditions),
            basic(fromKey: "end", fromMods: [], optionalMods: ["shift"], toKey: "right_arrow", toMods: ["command"], conditions: conditions),
            // Alt+Left / Alt+Right -> Cmd+[ / Cmd+] (Back / Forward)
            basic(fromKey: "left_arrow", fromMods: ["option"], optionalMods: [], toKey: "open_bracket", toMods: ["command"], conditions: conditions),
            basic(fromKey: "right_arrow", fromMods: ["option"], optionalMods: [], toKey: "close_bracket", toMods: ["command"], conditions: conditions),
            // Ctrl+F5 -> Hard Refresh (must appear before plain F5)
            basic(fromKey: "f5", fromMods: ["control"], optionalMods: [], toKey: "r", toMods: ["command", "shift"], conditions: conditions),
            // F5 -> Refresh
            basic(fromKey: "f5", fromMods: [], optionalMods: [], toKey: "r", toMods: ["command"], conditions: conditions)
        ]

        // Standard Ctrl+<key> -> Cmd+<key> (notice: `tab` is deliberately NOT in this list so Ctrl+Tab keeps switching tabs)
        let ctrlKeys: [String] = [
            "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m",
            "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "z",
            "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
            "equal_sign", "hyphen", "open_bracket", "close_bracket",
            "slash", "comma", "period", "return_or_enter", "spacebar"
        ]

        for key in ctrlKeys {
            manipulators.append(
                basic(
                    fromKey: key,
                    fromMods: ["control"],
                    optionalMods: ["shift", "option"],
                    toKey: key,
                    toMods: ["command"],
                    conditions: conditions
                )
            )
        }

        return [
            "description": "Win11: Windows Editing & Ctrl->Cmd Shortcuts (Non-Terminal Apps)",
            "manipulators": manipulators
        ]
    }

    private static func basic(
        fromKey: String,
        fromMods: [String],
        optionalMods: [String] = [],
        toKey: String,
        toMods: [String],
        conditions: [[String: Any]] = []
    ) -> [String: Any] {
        var modifiers: [String: Any] = [:]
        if !fromMods.isEmpty {
            modifiers["mandatory"] = fromMods
        }
        if !optionalMods.isEmpty {
            modifiers["optional"] = optionalMods
        }

        var fromDict: [String: Any] = ["key_code": fromKey]
        if !modifiers.isEmpty {
            fromDict["modifiers"] = modifiers
        }

        var toEntry: [String: Any] = ["key_code": toKey]
        if !toMods.isEmpty {
            toEntry["modifiers"] = toMods
        }

        var result: [String: Any] = [
            "type": "basic",
            "from": fromDict,
            "to": [toEntry]
        ]
        if !conditions.isEmpty {
            result["conditions"] = conditions
        }
        return result
    }
}
