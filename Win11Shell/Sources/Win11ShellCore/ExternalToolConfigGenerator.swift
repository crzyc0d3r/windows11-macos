import Foundation

public struct DefaultsCommand: Equatable, Sendable {
    public let domain: String
    public let key: String
    public let arguments: [String]

    public init(domain: String, key: String, arguments: [String]) {
        self.domain = domain
        self.key = key
        self.arguments = arguments
    }
}

public enum ExternalToolConfigGenerator {
    public static let rectangleBundleID = "com.knollsoft.Rectangle"
    public static let altTabBundleID = "com.lwouis.alt-tab-macos"

    // NSEvent modifier flag masks: Ctrl (262144) | Option (524288) | Command (1048576) = 1835008
    public static let ctrlOptCmdModifierFlags = 1_835_008
    // + Shift (131072) = 1966080
    public static let ctrlOptCmdShiftModifierFlags = 1_966_080

    public static func rectangleCommands(config: Win11Config = .default) -> [DefaultsCommand] {
        let topGap = Int(config.windowBarHeight.rounded())
        let bottomGap = Int(config.taskbarHeight.rounded())

        return [
            DefaultsCommand(domain: rectangleBundleID, key: "screenEdgeGapTop", arguments: ["-int", "\(topGap)"]),
            DefaultsCommand(domain: rectangleBundleID, key: "screenEdgeGapBottom", arguments: ["-int", "\(bottomGap)"]),
            DefaultsCommand(domain: rectangleBundleID, key: "launchOnLogin", arguments: ["-bool", "true"]),
            DefaultsCommand(domain: rectangleBundleID, key: "hideMenubarIcon", arguments: ["-bool", "true"]),
            DefaultsCommand(domain: rectangleBundleID, key: "snapEdgeMarginTop", arguments: ["-int", "5"]),
            DefaultsCommand(domain: rectangleBundleID, key: "snapEdgeMarginBottom", arguments: ["-int", "5"]),
            DefaultsCommand(domain: rectangleBundleID, key: "snapEdgeMarginLeft", arguments: ["-int", "5"]),
            DefaultsCommand(domain: rectangleBundleID, key: "snapEdgeMarginRight", arguments: ["-int", "5"]),
            DefaultsCommand(domain: rectangleBundleID, key: "leftHalf", arguments: ["-dict", "keyCode", "-int", "123", "modifierFlags", "-int", "\(ctrlOptCmdModifierFlags)"]),
            DefaultsCommand(domain: rectangleBundleID, key: "rightHalf", arguments: ["-dict", "keyCode", "-int", "124", "modifierFlags", "-int", "\(ctrlOptCmdModifierFlags)"]),
            DefaultsCommand(domain: rectangleBundleID, key: "maximize", arguments: ["-dict", "keyCode", "-int", "126", "modifierFlags", "-int", "\(ctrlOptCmdModifierFlags)"]),
            // Bind restore to Ctrl+Opt+Cmd+Shift+Down so Win+Down is owned cleanly by Win11Shell
            DefaultsCommand(domain: rectangleBundleID, key: "restore", arguments: ["-dict", "keyCode", "-int", "125", "modifierFlags", "-int", "\(ctrlOptCmdShiftModifierFlags)"])
        ]
    }

    public static func altTabCommands() -> [DefaultsCommand] {
        [
            DefaultsCommand(domain: altTabBundleID, key: "holdShortcut", arguments: ["-string", "⌥"]),
            DefaultsCommand(domain: altTabBundleID, key: "nextWindowShortcut", arguments: ["-string", "⇥"]),
            DefaultsCommand(domain: altTabBundleID, key: "menubarIcon", arguments: ["-string", "3"]),
            DefaultsCommand(domain: altTabBundleID, key: "startAtLogin", arguments: ["-bool", "true"]),
            DefaultsCommand(domain: altTabBundleID, key: "windowDisplayDelay", arguments: ["-string", "0"])
        ]
    }
}
