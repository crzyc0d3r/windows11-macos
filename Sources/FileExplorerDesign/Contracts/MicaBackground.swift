import AppKit
import SwiftUI

public enum MicaVariant: Sendable, Hashable {
    case mica
    case micaAlt
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
            VisualEffectRepresentable(variant: variant)
            tintColor
        }
        .ignoresSafeArea()
    }

    private var tintColor: Color {
        switch variant {
        case .mica:
            return theme.palette.mica.opacity(0.72)
        case .micaAlt:
            return theme.palette.micaAlt.opacity(0.80)
        case .acrylic:
            return theme.palette.elevatedFlyout.opacity(0.76)
        }
    }
}

private struct VisualEffectRepresentable: NSViewRepresentable {
    let variant: MicaVariant

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.material = material(for: variant)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material(for: variant)
    }

    private func material(for variant: MicaVariant) -> NSVisualEffectView.Material {
        switch variant {
        case .mica:
            return .windowBackground
        case .micaAlt:
            return .sidebar
        case .acrylic:
            return .popover
        }
    }
}
