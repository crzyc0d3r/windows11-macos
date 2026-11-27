import FileExplorerCore
import SwiftUI

public extension Color {
    /// Creates a SwiftUI Color from a 24-bit sRGB hex literal (e.g. `0x0067C0`).
    init(fluentHex hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

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

    /// Exact Windows 11 24H2 Light Mode palette.
    public static func light(accent: AccentColorChoice = .windowsBlue) -> FluentPalette {
        let accentColor = accentColorValue(for: accent, isDark: false)
        return FluentPalette(
            mica: Color(fluentHex: 0xE8E8E8),
            micaAlt: Color(fluentHex: 0xDADADA),
            commandBar: Color(fluentHex: 0xF9F9F9),
            navPane: Color(fluentHex: 0xF3F3F3),
            contentCanvas: Color(fluentHex: 0xFFFFFF),
            statusBar: Color(fluentHex: 0xF3F3F3),
            cardSurface: Color(fluentHex: 0xFCFCFC),
            elevatedFlyout: Color(fluentHex: 0xFCFCFC),
            borderSubtle: Color(fluentHex: 0xE5E5E5),
            inputBottomStroke: Color(fluentHex: 0x8A8A8A),
            textPrimary: Color(fluentHex: 0x1A1A1A),
            textSecondary: Color(fluentHex: 0x5F5F5F),
            hoverFill: Color.black.opacity(0.04),
            selectionFill: accentColor.opacity(0.12),
            accentBlue: accentColor,
            dangerRed: Color(fluentHex: 0xC42B1C)
        )
    }

    /// Exact Windows 11 24H2 Dark Mode palette.
    public static func dark(accent: AccentColorChoice = .windowsBlue) -> FluentPalette {
        let accentColor = accentColorValue(for: accent, isDark: true)
        return FluentPalette(
            mica: Color(fluentHex: 0x181818),
            micaAlt: Color(fluentHex: 0x0A0A0A),
            commandBar: Color(fluentHex: 0x202020),
            navPane: Color(fluentHex: 0x1F1F1F),
            contentCanvas: Color(fluentHex: 0x191919),
            statusBar: Color(fluentHex: 0x1C1C1C),
            cardSurface: Color(fluentHex: 0x2C2C2C),
            elevatedFlyout: Color(fluentHex: 0x2C2C2C),
            borderSubtle: Color.white.opacity(0.08),
            inputBottomStroke: Color.white.opacity(0.22),
            textPrimary: Color(fluentHex: 0xFFFFFF),
            textSecondary: Color(fluentHex: 0xA8A8A8),
            hoverFill: Color.white.opacity(0.06),
            selectionFill: accentColor.opacity(0.16),
            accentBlue: accentColor,
            dangerRed: Color(fluentHex: 0xFF99A4)
        )
    }

    public static func accentColorValue(for choice: AccentColorChoice, isDark: Bool) -> Color {
        switch (choice, isDark) {
        case (.windowsBlue, false): return Color(fluentHex: 0x0067C0)
        case (.windowsBlue, true):  return Color(fluentHex: 0x60CDFF)
        case (.teal, false):        return Color(fluentHex: 0x00787A)
        case (.teal, true):         return Color(fluentHex: 0x4DD0D3)
        case (.purple, false):      return Color(fluentHex: 0x744DC5)
        case (.purple, true):       return Color(fluentHex: 0xB894F6)
        case (.amber, false):       return Color(fluentHex: 0xC27000)
        case (.amber, true):        return Color(fluentHex: 0xFCB941)
        case (.rose, false):        return Color(fluentHex: 0xC02A63)
        case (.rose, true):         return Color(fluentHex: 0xF678A8)
        }
    }
}

public extension FluentPalette {
    /// Stronger selection fill (hover on selected row or active focus).
    var selectionHoverFill: Color {
        accentBlue.opacity(0.18)
    }

    /// Subtle pressed control fill.
    var pressedFill: Color {
        hoverFill.opacity(1.5)
    }

    /// Active tab & address row surface color (`#F3F3F3` Light / `#2C2C2C` Dark).
    func activeTabSurface(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(fluentHex: 0x2C2C2C) : Color(fluentHex: 0xF3F3F3)
    }

    /// Translucent Mica Alt tab bar overlay (`#E8E8E8` 82% Light / `#181818` 88% Dark).
    func tabBarTranslucent(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(fluentHex: 0x181818, opacity: 0.88)
            : Color(fluentHex: 0xE8E8E8, opacity: 0.82)
    }

    /// Solid danger fill (`#C42B1C` Light / `#E81123` Dark).
    func dangerSolid(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(fluentHex: 0xE81123) : Color(fluentHex: 0xC42B1C)
    }

    /// Drive capacity bar blue (`#0067C0` Light / `#60CDFF` Dark).
    func capacityBlue(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(fluentHex: 0x60CDFF) : Color(fluentHex: 0x0067C0)
    }

    /// Subtle input control fill (`#FFFFFF` Light / `#272727` Dark).
    func inputFill(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(fluentHex: 0x272727) : Color(fluentHex: 0xFFFFFF)
    }
}

public struct FluentTheme: Sendable {
    public let colorScheme: ColorScheme
    public let accentChoice: AccentColorChoice
    public let palette: FluentPalette
    public let isCompact: Bool

    public var isDark: Bool { colorScheme == .dark }
    public var rowHeight: CGFloat { isCompact ? 26 : 32 }
    public var cornerRadiusSmall: CGFloat { 4 }
    public var cornerRadiusMedium: CGFloat { 6 }
    public var cornerRadiusLarge: CGFloat { 8 }
    public var cornerRadiusTab: CGFloat { 8 }

    public var activeTabSurface: Color { palette.activeTabSurface(for: colorScheme) }
    public var tabBarTranslucent: Color { palette.tabBarTranslucent(for: colorScheme) }
    public var dangerSolid: Color { palette.dangerSolid(for: colorScheme) }
    public var capacityBlue: Color { palette.capacityBlue(for: colorScheme) }
    public var inputFill: Color { palette.inputFill(for: colorScheme) }

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
