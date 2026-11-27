import AppKit
import SwiftUI

public enum MicaVariant: Sendable, Hashable {
    case mica
    case micaAlt
    case commandBar
    case navPane
    case acrylic
}

public struct MicaBackground: View {
    public let variant: MicaVariant

    @Environment(\.fluentTheme) private var theme

    public init(variant: MicaVariant = .mica) {
        self.variant = variant
    }

    public var body: some View {
        ZStack {
            opaqueFallbackColor
            VisualEffectRepresentable(variant: variant, colorScheme: theme.colorScheme)
            translucentTintColor
        }
        .ignoresSafeArea()
    }

    /// Explicit opaque Fluent fallback so offscreen NSWindow / ImageRenderer snapshots
    /// never render blank or transparent.
    private var opaqueFallbackColor: Color {
        switch variant {
        case .mica:
            return theme.palette.mica
        case .micaAlt:
            return theme.palette.micaAlt
        case .commandBar:
            return theme.palette.commandBar
        case .navPane:
            return theme.palette.navPane
        case .acrylic:
            return theme.palette.elevatedFlyout
        }
    }

    /// Translucent Windows 11 surface tint layered over NSVisualEffectView.
    private var translucentTintColor: Color {
        switch variant {
        case .mica:
            return theme.isDark
                ? Color(fluentHex: 0x181818, opacity: 0.88)
                : Color(fluentHex: 0xE8E8E8, opacity: 0.82)
        case .micaAlt:
            return theme.isDark
                ? Color(fluentHex: 0x181818, opacity: 0.88)
                : Color(fluentHex: 0xE8E8E8, opacity: 0.82)
        case .commandBar:
            return theme.palette.commandBar.opacity(theme.isDark ? 0.88 : 0.86)
        case .navPane:
            return theme.palette.navPane.opacity(theme.isDark ? 0.84 : 0.82)
        case .acrylic:
            return theme.palette.elevatedFlyout.opacity(theme.isDark ? 0.86 : 0.84)
        }
    }
}

private struct VisualEffectRepresentable: NSViewRepresentable {
    let variant: MicaVariant
    let colorScheme: ColorScheme

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: NSVisualEffectView) {
        view.material = material(for: variant)
        view.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
    }

    private func material(for variant: MicaVariant) -> NSVisualEffectView.Material {
        switch variant {
        case .mica, .micaAlt, .commandBar:
            return .headerView
        case .navPane:
            return .sidebar
        case .acrylic:
            return .popover
        }
    }
}
