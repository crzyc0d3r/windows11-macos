import FileExplorerCore
import SwiftUI

public struct FluentPalette: Sendable {
    public let mica: Color
    public let micaAlt: Color
    public let commandBar: Color
    public let navPane: Color
    public let contentCanvas: Color
    public let statusBar: Color
    public let cardSurface: Color
    public let elevatedFlyout: Color
    public let borderSubtle: Color
    public let inputBottomStroke: Color
    public let textPrimary: Color
    public let textSecondary: Color
    public let hoverFill: Color
    public let selectionFill: Color
    public let accentBlue: Color
    public let dangerRed: Color

    public init(
        mica: Color,
        micaAlt: Color,
        commandBar: Color,
        navPane: Color,
        contentCanvas: Color,
        statusBar: Color,
        cardSurface: Color,
        elevatedFlyout: Color,
        borderSubtle: Color,
        inputBottomStroke: Color,
        textPrimary: Color,
        textSecondary: Color,
        hoverFill: Color,
        selectionFill: Color,
        accentBlue: Color,
        dangerRed: Color
    ) {
        self.mica = mica
        self.micaAlt = micaAlt
        self.commandBar = commandBar
        self.navPane = navPane
        self.contentCanvas = contentCanvas
        self.statusBar = statusBar
        self.cardSurface = cardSurface
        self.elevatedFlyout = elevatedFlyout
        self.borderSubtle = borderSubtle
        self.inputBottomStroke = inputBottomStroke
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.hoverFill = hoverFill
        self.selectionFill = selectionFill
        self.accentBlue = accentBlue
        self.dangerRed = dangerRed
    }

    public static let light = light(accent: .windowsBlue)
    public static let dark = dark(accent: .windowsBlue)

    public static func light(accent: AccentColorChoice = .windowsBlue) -> FluentPalette {
        let accentColor = accentColorValue(for: accent, isDark: false)
        return FluentPalette(
            mica: Color(red: 0.953, green: 0.961, blue: 0.976),
            micaAlt: Color(red: 0.922, green: 0.933, blue: 0.953),
            commandBar: Color(red: 0.973, green: 0.976, blue: 0.984).opacity(0.88),
            navPane: Color(red: 0.945, green: 0.953, blue: 0.969).opacity(0.78),
            contentCanvas: Color(red: 0.988, green: 0.990, blue: 0.996),
            statusBar: Color(red: 0.953, green: 0.961, blue: 0.976).opacity(0.92),
            cardSurface: Color.white.opacity(0.85),
            elevatedFlyout: Color(red: 0.984, green: 0.988, blue: 0.996),
            borderSubtle: Color.black.opacity(0.075),
            inputBottomStroke: Color.black.opacity(0.45),
            textPrimary: Color(red: 0.102, green: 0.106, blue: 0.118),
            textSecondary: Color(red: 0.365, green: 0.380, blue: 0.420),
            hoverFill: Color.black.opacity(0.045),
            selectionFill: accentColor.opacity(0.16),
            accentBlue: accentColor,
            dangerRed: Color(red: 0.769, green: 0.169, blue: 0.110)
        )
    }

    public static func dark(accent: AccentColorChoice = .windowsBlue) -> FluentPalette {
        let accentColor = accentColorValue(for: accent, isDark: true)
        return FluentPalette(
            mica: Color(red: 0.125, green: 0.129, blue: 0.141),
            micaAlt: Color(red: 0.102, green: 0.106, blue: 0.118),
            commandBar: Color(red: 0.157, green: 0.161, blue: 0.176).opacity(0.86),
            navPane: Color(red: 0.133, green: 0.137, blue: 0.153).opacity(0.76),
            contentCanvas: Color(red: 0.098, green: 0.102, blue: 0.114),
            statusBar: Color(red: 0.125, green: 0.129, blue: 0.141).opacity(0.92),
            cardSurface: Color.white.opacity(0.055),
            elevatedFlyout: Color(red: 0.173, green: 0.176, blue: 0.192),
            borderSubtle: Color.white.opacity(0.085),
            inputBottomStroke: Color.white.opacity(0.50),
            textPrimary: Color(red: 0.961, green: 0.965, blue: 0.976),
            textSecondary: Color(red: 0.678, green: 0.694, blue: 0.725),
            hoverFill: Color.white.opacity(0.065),
            selectionFill: accentColor.opacity(0.24),
            accentBlue: accentColor,
            dangerRed: Color(red: 0.965, green: 0.420, blue: 0.396)
        )
    }

    private static func accentColorValue(for choice: AccentColorChoice, isDark: Bool) -> Color {
        switch (choice, isDark) {
        case (.windowsBlue, false): return Color(red: 0.000, green: 0.404, blue: 0.753)
        case (.windowsBlue, true):  return Color(red: 0.376, green: 0.804, blue: 1.000)
        case (.teal, false):        return Color(red: 0.000, green: 0.471, blue: 0.478)
        case (.teal, true):         return Color(red: 0.302, green: 0.816, blue: 0.827)
        case (.purple, false):      return Color(red: 0.455, green: 0.302, blue: 0.773)
        case (.purple, true):       return Color(red: 0.722, green: 0.580, blue: 0.965)
        case (.amber, false):       return Color(red: 0.761, green: 0.439, blue: 0.000)
        case (.amber, true):        return Color(red: 0.988, green: 0.725, blue: 0.255)
        case (.rose, false):        return Color(red: 0.753, green: 0.165, blue: 0.388)
        case (.rose, true):         return Color(red: 0.965, green: 0.471, blue: 0.659)
        }
    }
}

public struct FluentTheme: Sendable {
    public let colorScheme: ColorScheme
    public let accentChoice: AccentColorChoice
    public let palette: FluentPalette
    public let isCompact: Bool

    public var rowHeight: CGFloat { isCompact ? 26 : 32 }
    public var cornerRadiusSmall: CGFloat { 4 }
    public var cornerRadiusMedium: CGFloat { 6 }
    public var cornerRadiusLarge: CGFloat { 8 }

    public init(
        colorScheme: ColorScheme = .light,
        accentChoice: AccentColorChoice = .windowsBlue,
        isCompact: Bool = false
    ) {
        self.colorScheme = colorScheme
        self.accentChoice = accentChoice
        self.isCompact = isCompact
        self.palette = colorScheme == .dark
            ? FluentPalette.dark(accent: accentChoice)
            : FluentPalette.light(accent: accentChoice)
    }

    public static func resolve(
        theme: AppTheme,
        systemScheme: ColorScheme,
        accent: AccentColorChoice = .windowsBlue,
        compact: Bool = false
    ) -> FluentTheme {
        let resolvedScheme: ColorScheme
        switch theme {
        case .system: resolvedScheme = systemScheme
        case .light: resolvedScheme = .light
        case .dark: resolvedScheme = .dark
        }
        return FluentTheme(colorScheme: resolvedScheme, accentChoice: accent, isCompact: compact)
    }
}

private struct FluentThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue = FluentTheme()
}

public extension EnvironmentValues {
    var fluentTheme: FluentTheme {
        get { self[FluentThemeEnvironmentKey.self] }
        set { self[FluentThemeEnvironmentKey.self] = newValue }
    }
}
