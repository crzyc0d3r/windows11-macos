import FileExplorerCore
import FileExplorerDesign
import SwiftUI

public struct SettingsOptionsDialogView: View {
    public let store: ExplorerStore

    private enum OptionsTab: String, CaseIterable {
        case appearance = "Appearance"
        case view = "View"
        case general = "General"
    }

    @Environment(\.fluentTheme) private var theme
    @State private var selectedTab: OptionsTab = .appearance
    @State private var copiedCommandTag: String?

    public init(store: ExplorerStore) {
        self.store = store
    }

    public var body: some View {
        if store.isSettingsOpen {
            ZStack {
                Color.black.opacity(theme.colorScheme == .dark ? 0.45 : 0.25)
                    .ignoresSafeArea()
                    .onTapGesture {
                        store.closeSettings()
                    }

                modalCard
            }
        }
    }

    private var modalCard: some View {
        VStack(spacing: 0) {
            titleBar
            tabBar
            Divider().overlay(theme.palette.borderSubtle)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch selectedTab {
                    case .appearance:
                        appearanceSection
                        finderIntegrationSection
                    case .view:
                        viewOptionsSection
                    case .general:
                        generalOptionsSection
                        finderIntegrationSection
                    }
                }
                .padding(16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(theme.palette.borderSubtle)
            footerBar
        }
        .frame(width: 480, height: 540)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.palette.elevatedFlyout)
        )
        .background(
            MicaBackground(variant: .mica)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.palette.borderSubtle, lineWidth: 1)
        )
        .shadow(
            color: Color.black.opacity(theme.colorScheme == .dark ? 0.50 : 0.22),
            radius: 24,
            x: 0,
            y: 12
        )
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "gearshape")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(theme.palette.accentBlue)

            Text("Folder Options & Appearance")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary)

            Spacer()

            Button {
                store.closeSettings()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.palette.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(theme.palette.commandBar)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(OptionsTab.allCases, id: \.self) { tab in
                let isSelected = selectedTab == tab
                Button {
                    selectedTab = tab
                } label: {
                    VStack(spacing: 5) {
                        Text(tab.rawValue)
                            .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? theme.palette.textPrimary : theme.palette.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 6)

                        Capsule()
                            .fill(isSelected ? theme.palette.accentBlue : Color.clear)
                            .frame(height: 2.5)
                            .padding(.horizontal, 10)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .background(theme.palette.commandBar)
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorSectionCard(title: "Theme") {
                HStack(spacing: 8) {
                    ForEach(AppTheme.allCases, id: \.self) { choice in
                        let isSelected = store.settings.theme == choice
                        Button {
                            store.updateSettings { $0.theme = choice }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: themeIcon(for: choice))
                                    .font(.system(size: 12))
                                Text(choice.displayTitle)
                                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            }
                            .foregroundStyle(isSelected ? theme.palette.accentBlue : theme.palette.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(isSelected ? theme.palette.selectionFill : theme.palette.contentCanvas)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(isSelected ? theme.palette.accentBlue.opacity(0.6) : theme.palette.borderSubtle, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            InspectorSectionCard(title: "Accent Color") {
                HStack(spacing: 14) {
                    ForEach(AccentColorChoice.allCases, id: \.self) { choice in
                        let isSelected = store.settings.accentColor == choice
                        let swatch = swatchColor(for: choice)
                        Button {
                            store.updateSettings { $0.accentColor = choice }
                        } label: {
                            VStack(spacing: 5) {
                                ZStack {
                                    Circle()
                                        .fill(swatch)
                                        .frame(width: 26, height: 26)
                                    if isSelected {
                                        Circle()
                                            .stroke(theme.palette.textPrimary, lineWidth: 2)
                                            .frame(width: 32, height: 32)
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                                Text(shortAccentLabel(choice))
                                    .font(.system(size: 10.5, weight: isSelected ? .semibold : .regular))
                                    .foregroundStyle(isSelected ? theme.palette.textPrimary : theme.palette.textSecondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var viewOptionsSection: some View {
        InspectorSectionCard(title: "Files and Folders") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Compact view (decrease space between items)", isOn: settingBinding(\.compactView))
                    .toggleStyle(FluentCheckboxToggleStyle())

                Toggle("Use check boxes to select items", isOn: settingBinding(\.showCheckboxes))
                    .toggleStyle(FluentCheckboxToggleStyle())

                Toggle("Show file name extensions", isOn: settingBinding(\.showFileExtensions))
                    .toggleStyle(FluentCheckboxToggleStyle())

                Toggle(
                    "Show hidden files and folders",
                    isOn: Binding(
                        get: { store.settings.showHiddenFiles },
                        set: { newValue in
                            if store.settings.showHiddenFiles != newValue {
                                store.toggleHiddenFiles()
                            }
                        }
                    )
                )
                .toggleStyle(FluentCheckboxToggleStyle())

                Toggle("Show navigation pane", isOn: settingBinding(\.showNavigationPane))
                    .toggleStyle(FluentCheckboxToggleStyle())
            }
        }
    }

    private var generalOptionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorSectionCard(title: "Open File Explorer to") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(LaunchTarget.allCases, id: \.self) { target in
                        let isSelected = store.settings.launchTarget == target
                        Button {
                            store.updateSettings { $0.launchTarget = target }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                                    .font(.system(size: 14))
                                    .foregroundStyle(isSelected ? theme.palette.accentBlue : theme.palette.textSecondary)
                                Text(target.displayTitle)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(theme.palette.textPrimary)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            InspectorSectionCard(title: "Click items as follows") {
                VStack(alignment: .leading, spacing: 8) {
                    clickModeRow(title: "Double-click to open an item (single-click to select)", singleClick: false)
                    clickModeRow(title: "Single-click to open an item (point to select)", singleClick: true)
                }
            }
        }
    }

    private func clickModeRow(title: String, singleClick: Bool) -> some View {
        let isSelected = store.settings.singleClickToOpen == singleClick
        return Button {
            store.updateSettings { $0.singleClickToOpen = singleClick }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? theme.palette.accentBlue : theme.palette.textSecondary)
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.palette.textPrimary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var finderIntegrationSection: some View {
        let status = readNSFileViewerStatus()
        let bundleID = Bundle.main.bundleIdentifier ?? "com.fileexplorer.app"
        let setupCmd = "defaults write -g NSFileViewer -string \(bundleID)"
        let revertCmd = "defaults delete -g NSFileViewer"

        return InspectorSectionCard(title: "macOS Finder Replacement (NSFileViewer)") {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Text("Status:")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.palette.textSecondary)
                    Text(status.label)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(status.isActive ? theme.palette.accentBlue : theme.palette.textPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(status.isActive ? theme.palette.selectionFill : theme.palette.hoverFill)
                        )
                    Spacer()
                }

                Text("Run in Terminal to register or revert File Explorer as the default folder viewer:")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.palette.textSecondary)

                commandCopyBox(tag: "setup", title: "Enable", command: setupCmd)
                commandCopyBox(tag: "revert", title: "Revert", command: revertCmd)
            }
        }
    }

    private func commandCopyBox(tag: String, title: String, command: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(theme.palette.textSecondary)
                .frame(width: 42, alignment: .leading)

            Text(command)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                InspectorFormatters.copyStringToPasteboard(command)
                copiedCommandTag = tag
            } label: {
                Text(copiedCommandTag == tag ? "Copied" : "Copy")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.palette.accentBlue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(theme.palette.selectionFill)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.palette.contentCanvas)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(theme.palette.borderSubtle, lineWidth: 1)
        )
    }

    private var footerBar: some View {
        HStack {
            Button {
                store.resetSettingsToDefaults()
            } label: {
                Text("Restore Defaults")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.textPrimary)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(theme.palette.cardSurface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(theme.palette.borderSubtle, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                store.closeSettings()
            } label: {
                Text("Done")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.colorScheme == .dark ? Color.black : Color.white)
                    .frame(minWidth: 78)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(theme.palette.accentBlue)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(theme.palette.commandBar)
    }

    private func settingBinding(_ keyPath: WritableKeyPath<ExplorerSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { newValue in
                store.updateSettings { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    private func themeIcon(for choice: AppTheme) -> String {
        switch choice {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    private func swatchColor(for choice: AccentColorChoice) -> Color {
        let isDark = theme.colorScheme == .dark
        return FluentPalette.light(accent: choice).accentBlue
            .opacity(1)
            .resolvedColorFallback(choice: choice, isDark: isDark)
    }

    private func shortAccentLabel(_ choice: AccentColorChoice) -> String {
        switch choice {
        case .windowsBlue: return "Blue"
        case .teal: return "Teal"
        case .purple: return "Purple"
        case .amber: return "Amber"
        case .rose: return "Rose"
        }
    }

    private func readNSFileViewerStatus() -> (isActive: Bool, label: String) {
        if store.snapshotMode {
            return (false, "Default (Finder)")
        }
        if let value = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["NSFileViewer"] as? String,
           !value.isEmpty {
            let bundleID = Bundle.main.bundleIdentifier ?? "com.fileexplorer.app"
            if value == bundleID {
                return (true, "Active (File Explorer)")
            }
            return (true, "Custom (\(value))")
        }
        return (false, "Default (Finder)")
    }
}

private extension Color {
    func resolvedColorFallback(choice: AccentColorChoice, isDark: Bool) -> Color {
        if isDark {
            return FluentPalette.dark(accent: choice).accentBlue
        }
        return FluentPalette.light(accent: choice).accentBlue
    }
}
