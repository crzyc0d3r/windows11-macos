import SwiftUI

// MARK: - Fluent Toolbar Button

/// Windows 11 Fluent command bar / toolbar button with hover and press feedback.
public struct FluentToolbarButton<Label: View>: View {
    private let isEnabled: Bool
    private let isSelected: Bool
    private let action: () -> Void
    private let label: () -> Label

    @Environment(\.fluentTheme) private var theme
    @State private var isHovering = false

    public init(
        isEnabled: Bool = true,
        isSelected: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.isEnabled = isEnabled
        self.isSelected = isSelected
        self.action = action
        self.label = label
    }

    public var body: some View {
        Button(action: action) {
            label()
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(backgroundFill)
                .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadiusSmall, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: theme.cornerRadiusSmall, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: isSelected ? 1 : 0)
                )
        }
        .buttonStyle(FluentPressableButtonStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.40)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var backgroundFill: Color {
        if isSelected {
            return theme.palette.selectionFill
        }
        if isHovering && isEnabled {
            return theme.palette.hoverFill
        }
        return .clear
    }

    private var borderColor: Color {
        isSelected ? theme.palette.accentBlue.opacity(0.35) : .clear
    }
}

public extension FluentToolbarButton where Label == AnyView {
    init(
        _ title: String? = nil,
        systemImage: String,
        isEnabled: Bool = true,
        isSelected: Bool = false,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) {
        self.init(isEnabled: isEnabled, isSelected: isSelected, action: action) {
            AnyView(
                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(tint ?? .primary)
                    if let title, !title.isEmpty {
                        Text(title)
                            .font(.system(size: 12.5, weight: .regular))
                    }
                }
            )
        }
    }
}

private struct FluentPressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Fluent Pill Toggle Button

/// Windows 11 pill/capsule toggle button for panes, filters, and mode switches.
public struct FluentPillToggleButton: View {
    public let title: String
    public let systemImage: String?
    public let isOn: Bool
    public let action: () -> Void

    @Environment(\.fluentTheme) private var theme
    @State private var isHovering = false

    public init(
        _ title: String,
        systemImage: String? = nil,
        isOn: Bool,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isOn = isOn
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .medium))
                }
                if !title.isEmpty {
                    Text(title)
                        .font(.system(size: 12, weight: isOn ? .semibold : .regular))
                }
            }
            .foregroundStyle(isOn ? theme.palette.accentBlue : theme.palette.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(backgroundFill)
            .clipShape(Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        isOn ? theme.palette.accentBlue.opacity(0.42) : theme.palette.borderSubtle,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(FluentPressableButtonStyle())
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var backgroundFill: Color {
        if isOn {
            return theme.palette.selectionFill
        }
        return isHovering ? theme.palette.hoverFill : .clear
    }
}

// MARK: - Fluent Active Indicator Pill

/// Windows 11 3px accent indicator pill for selected sidebar rows or active tabs.
public struct FluentActiveIndicatorPill: View {
    public enum Orientation: Sendable {
        case vertical
        case horizontal
    }

    public let isActive: Bool
    public let orientation: Orientation
    public let length: CGFloat
    public let thickness: CGFloat
    public let color: Color?

    @Environment(\.fluentTheme) private var theme

    public init(
        isActive: Bool = true,
        orientation: Orientation = .vertical,
        length: CGFloat = 16,
        thickness: CGFloat = 3,
        color: Color? = nil
    ) {
        self.isActive = isActive
        self.orientation = orientation
        self.length = length
        self.thickness = thickness
        self.color = color
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: thickness * 0.5, style: .continuous)
            .fill(color ?? theme.palette.accentBlue)
            .frame(
                width: orientation == .vertical ? thickness : length,
                height: orientation == .vertical ? length : thickness
            )
            .scaleEffect(
                x: orientation == .horizontal ? (isActive ? 1 : 0.2) : 1,
                y: orientation == .vertical ? (isActive ? 1 : 0.2) : 1
            )
            .opacity(isActive ? 1 : 0)
            .animation(.easeOut(duration: 0.14), value: isActive)
    }
}

// MARK: - Fluent Capacity Bar

/// Windows 11 storage capacity progress bar: blue below 90%, red `#C42B1C` at >= 90%.
public struct FluentCapacityBar: View {
    public let fraction: Double
    public let height: CGFloat
    public let cornerRadius: CGFloat

    @Environment(\.fluentTheme) private var theme

    public init(
        fraction: Double,
        height: CGFloat = 10,
        cornerRadius: CGFloat = 3
    ) {
        self.fraction = min(1.0, max(0.0, fraction))
        self.height = height
        self.cornerRadius = cornerRadius
    }

    private var isCritical: Bool {
        fraction >= 0.90
    }

    private var fillColor: Color {
        if isCritical {
            return Color(fluentHex: 0xC42B1C)
        }
        return theme.capacityBlue
    }

    private var trackColor: Color {
        theme.isDark ? Color.white.opacity(0.12) : Color(fluentHex: 0xE5E5E5)
    }

    public var body: some View {
        GeometryReader { proxy in
            let width = max(0, proxy.size.width)
            let fillWidth = fraction > 0 ? max(height * 0.6, width * fraction) : 0

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(trackColor)

                if fillWidth > 0 {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(fillColor)
                        .frame(width: min(width, fillWidth))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(theme.palette.borderSubtle, lineWidth: 0.75)
            )
        }
        .frame(height: height)
    }
}

// MARK: - Fluent Divider

/// Subtle 1px Fluent divider matching Windows 11 24H2 stroke tokens.
public struct FluentDivider: View {
    public enum Orientation: Sendable {
        case horizontal
        case vertical
    }

    public let orientation: Orientation

    @Environment(\.fluentTheme) private var theme

    public init(_ orientation: Orientation = .horizontal) {
        self.orientation = orientation
    }

    public var body: some View {
        Rectangle()
            .fill(theme.palette.borderSubtle)
            .frame(
                width: orientation == .vertical ? 1 : nil,
                height: orientation == .horizontal ? 1 : nil
            )
    }
}

// MARK: - Fluent Pin Badge

/// Crisp Quick Access pin badge indicator.
public struct FluentPinBadge: View {
    public let isPinned: Bool
    public let size: CGFloat

    @Environment(\.fluentTheme) private var theme

    public init(isPinned: Bool = true, size: CGFloat = 11) {
        self.isPinned = isPinned
        self.size = size
    }

    public var body: some View {
        Image(systemName: isPinned ? "pin.fill" : "pin")
            .font(.system(size: size, weight: .semibold))
            .rotationEffect(.degrees(45))
            .foregroundStyle(isPinned ? theme.palette.accentBlue : theme.palette.textSecondary)
            .accessibilityLabel(isPinned ? "Pinned" : "Unpinned")
    }
}
