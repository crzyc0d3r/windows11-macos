import AppKit
import FileExplorerCore
import FileExplorerDesign
import SwiftUI

/// Windows 11 24H2 Command Bar (~48px tall) positioned directly below `AddressBarRowView`.
struct CommandBarView: View {
    let store: ExplorerStore

    @Environment(\.fluentTheme) private var theme

    private let barHeight: CGFloat = 48

    var body: some View {
        HStack(spacing: 4) {
            if store.activeTab.location == .recycleBin {
                recycleBinActions
            } else {
                standardActions
            }

            Spacer(minLength: 8)

            rightPanePills
        }
        .padding(.horizontal, 12)
        .frame(height: barHeight)
        .background(theme.palette.commandBar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.palette.borderSubtle)
                .frame(height: 1)
        }
    }

    // MARK: - Recycle Bin Contextual Bar

    private var recycleBinActions: some View {
        HStack(spacing: 4) {
            CommandBarTextButton(
                title: "Empty Recycle Bin",
                systemName: "trash.slash",
                isEnabled: !store.isTrashEmpty
            ) {
                store.emptyTrash()
            }

            toolbarDivider

            CommandBarTextButton(
                title: "Restore the selected items",
                systemName: "arrow.uturn.backward",
                isEnabled: !store.selectedItems.isEmpty
            ) {
                store.restoreFromTrash(urls: store.selectedItems.map(\.url))
            }

            CommandBarTextButton(
                title: "Restore all items",
                systemName: "arrow.uturn.backward.circle",
                isEnabled: !store.currentItems.isEmpty
            ) {
                store.restoreFromTrash(urls: store.currentItems.map(\.url))
            }

            toolbarDivider

            sortMenu
            viewMenu
        }
    }

    // MARK: - Standard Command Bar

    private var standardActions: some View {
        let canCreateInLocation = store.activeTab.location.urlIfFolder != nil
        let hasSelection = !store.selectedItems.isEmpty
        let primarySelection = store.primarySelectedItem

        return HStack(spacing: 4) {
            newMenu(isEnabled: canCreateInLocation)

            toolbarDivider

            HStack(spacing: 2) {
                ChromeIconButton(
                    systemName: "scissors",
                    size: 32,
                    iconSize: 13.5,
                    isEnabled: hasSelection,
                    tooltip: "Cut (⌘X)"
                ) {
                    store.cutSelectedItems()
                }

                ChromeIconButton(
                    systemName: "doc.on.doc",
                    size: 32,
                    iconSize: 13.5,
                    isEnabled: hasSelection,
                    tooltip: "Copy (⌘C)"
                ) {
                    store.copySelectedItems()
                }

                ChromeIconButton(
                    systemName: "doc.on.clipboard",
                    size: 32,
                    iconSize: 13.5,
                    isEnabled: store.clipboardPayload != nil && canCreateInLocation,
                    tooltip: "Paste (⌘V)"
                ) {
                    store.pasteIntoCurrentFolder()
                }

                ChromeIconButton(
                    systemName: "pencil",
                    size: 32,
                    iconSize: 13.5,
                    isEnabled: primarySelection != nil,
                    tooltip: "Rename (F2)"
                ) {
                    if let item = primarySelection {
                        store.beginInlineRename(for: item.url)
                    }
                }

                ShareMenuButton(
                    urls: store.selectedItems.map(\.url),
                    isSnapshotMode: store.snapshotMode,
                    isDisabled: !hasSelection
                )

                ChromeIconButton(
                    systemName: "trash",
                    size: 32,
                    iconSize: 13.5,
                    isEnabled: hasSelection,
                    tooltip: "Delete (⌘⌫)"
                ) {
                    store.deleteSelectedItems()
                }
            }

            toolbarDivider

            sortMenu
            viewMenu
            moreMenu
        }
    }

    // MARK: - + New ▾ Menu

    private func newMenu(isEnabled: Bool) -> some View {
        Menu {
            Button {
                store.newFolder()
            } label: {
                Label("Folder", systemImage: "folder.badge.plus")
            }

            Divider()

            Button {
                store.newFile(named: "New Text Document", fileExtension: "txt")
            } label: {
                Label("Text Document (.txt)", systemImage: "doc.plaintext")
            }

            Button {
                store.newFile(named: "New Markdown Document", fileExtension: "md")
            } label: {
                Label("Markdown Document (.md)", systemImage: "doc.text")
            }

            Button {
                store.newFile(named: "New JSON File", fileExtension: "json")
            } label: {
                Label("JSON File (.json)", systemImage: "curlybraces")
            }

            Button {
                store.newFile(named: "script", fileExtension: "sh")
            } label: {
                Label("Shell Script (.sh)", systemImage: "terminal")
            }

            Button {
                store.newFile(named: "New Rich Text Document", fileExtension: "rtf")
            } label: {
                Label("Rich Text Document (.rtf)", systemImage: "doc.richtext")
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isEnabled ? theme.palette.accentBlue : theme.palette.textSecondary.opacity(0.4))
                Text("New")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(isEnabled ? theme.palette.textPrimary : theme.palette.textSecondary.opacity(0.4))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.palette.textSecondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!isEnabled)
        .help("Create a new item in the current folder")
    }

    // MARK: - ⇅ Sort ▾ Menu

    private var sortMenu: some View {
        Menu {
            Section("Sort by") {
                ForEach(SortField.allCases, id: \.self) { field in
                    Button {
                        store.setSort(field: field)
                    } label: {
                        HStack {
                            Text(field.displayTitle)
                            if store.activeTab.sortField == field {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            Divider()

            Button {
                store.setSort(field: store.activeTab.sortField, order: .ascending)
            } label: {
                HStack {
                    Text("Ascending")
                    if store.activeTab.sortOrder == .ascending {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Button {
                store.setSort(field: store.activeTab.sortField, order: .descending)
            } label: {
                HStack {
                    Text("Descending")
                    if store.activeTab.sortOrder == .descending {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            Menu("Group by") {
                ForEach(GroupByField.allCases, id: \.self) { groupField in
                    Button {
                        store.setGroupBy(groupField)
                    } label: {
                        HStack {
                            Text(groupField.displayTitle)
                            if store.activeTab.groupBy == groupField {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 12, weight: .medium))
                Text("Sort")
                    .font(.system(size: 12.5, weight: .regular))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.palette.textSecondary)
            }
            .foregroundStyle(theme.palette.textPrimary)
            .padding(.horizontal, 8)
            .frame(height: 32)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort and group items")
    }

    // MARK: - ⊞ View ▾ Menu

    private var viewMenu: some View {
        Menu {
            ForEach(ViewMode.allCases, id: \.self) { mode in
                Button {
                    store.setViewMode(mode)
                } label: {
                    HStack {
                        Label(mode.displayTitle, systemImage: mode.iconSystemName)
                        if store.activeTab.viewMode == mode {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            Divider()

            Button {
                store.toggleCompactView()
            } label: {
                HStack {
                    Text("Compact view")
                    if store.settings.compactView {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Menu("Show") {
                Button {
                    store.toggleNavigationPane()
                } label: {
                    HStack {
                        Text("Navigation pane")
                        if store.settings.showNavigationPane {
                            Image(systemName: "checkmark")
                        }
                    }
                }

                Button {
                    store.setRightPaneMode(.details)
                } label: {
                    HStack {
                        Text("Details pane")
                        if store.settings.rightPaneMode == .details {
                            Image(systemName: "checkmark")
                        }
                    }
                }

                Button {
                    store.setRightPaneMode(.preview)
                } label: {
                    HStack {
                        Text("Preview pane")
                        if store.settings.rightPaneMode == .preview {
                            Image(systemName: "checkmark")
                        }
                    }
                }

                Divider()

                Button {
                    store.toggleCheckboxes()
                } label: {
                    HStack {
                        Text("Item check boxes")
                        if store.settings.showCheckboxes {
                            Image(systemName: "checkmark")
                        }
                    }
                }

                Button {
                    store.toggleFileExtensions()
                } label: {
                    HStack {
                        Text("File name extensions")
                        if store.settings.showFileExtensions {
                            Image(systemName: "checkmark")
                        }
                    }
                }

                Button {
                    store.toggleHiddenFiles()
                } label: {
                    HStack {
                        Text("Hidden items")
                        if store.settings.showHiddenFiles {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 12, weight: .medium))
                Text("View")
                    .font(.system(size: 12.5, weight: .regular))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.palette.textSecondary)
            }
            .foregroundStyle(theme.palette.textPrimary)
            .padding(.horizontal, 8)
            .frame(height: 32)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Change layout and visibility options")
    }

    // MARK: - ⋯ More Menu

    private var moreMenu: some View {
        let hasSelection = !store.selectedItems.isEmpty
        let canExtract = store.selectedItems.count == 1 && store.selectedItems.first?.kind == .archive
        let propertiesTarget = store.primarySelectedItem?.url ?? store.activeTab.location.urlIfFolder

        return Menu {
            Button {
                store.undo()
            } label: {
                Text(store.undoDescription.map { "Undo \($0)" } ?? "Undo")
            }
            .disabled(!store.canUndo)

            Button {
                store.redo()
            } label: {
                Text(store.redoDescription.map { "Redo \($0)" } ?? "Redo")
            }
            .disabled(!store.canRedo)

            Divider()

            Button("Select all") {
                store.selectAll()
            }
            .disabled(store.currentItems.isEmpty)

            Button("Select none") {
                store.deselectAll()
            }
            .disabled(!hasSelection)

            Button("Invert selection") {
                store.invertSelection()
            }
            .disabled(store.currentItems.isEmpty)

            Divider()

            Button("Compress to ZIP file") {
                store.zipSelectedItems()
            }
            .disabled(!hasSelection)

            Button("Extract all") {
                if let archive = store.selectedItems.first {
                    store.extractArchive(at: archive.url)
                }
            }
            .disabled(!canExtract)

            Divider()

            Button("Properties") {
                if let target = propertiesTarget {
                    store.showProperties(for: target)
                }
            }
            .disabled(propertiesTarget == nil)

            Button("Options...") {
                store.openSettings()
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary)
                .frame(width: 28, height: 32)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("See more")
    }

    // MARK: - Right Details / Preview Toggle Pill

    private var rightPanePills: some View {
        HStack(spacing: 4) {
            PaneTogglePillButton(
                title: "Details",
                systemName: "sidebar.right",
                isActive: store.settings.rightPaneMode == .details
            ) {
                store.setRightPaneMode(.details)
            }

            PaneTogglePillButton(
                title: "Preview",
                systemName: "eye",
                isActive: store.settings.rightPaneMode == .preview
            ) {
                store.setRightPaneMode(.preview)
            }
        }
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(theme.palette.borderSubtle)
            .frame(width: 1, height: 20)
            .padding(.horizontal, 4)
    }
}

// MARK: - Command Bar Helpers

private struct CommandBarTextButton: View {
    let title: String
    let systemName: String
    let isEnabled: Bool
    let action: () -> Void

    @Environment(\.fluentTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 12.5, weight: .medium))
                Text(title)
                    .font(.system(size: 12.5, weight: .regular))
            }
            .foregroundStyle(isEnabled ? theme.palette.textPrimary : theme.palette.textSecondary.opacity(0.4))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: theme.cornerRadiusSmall, style: .continuous)
                    .fill(isEnabled && isHovered ? theme.palette.hoverFill : .clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private struct PaneTogglePillButton: View {
    let title: String
    let systemName: String
    let isActive: Bool
    let action: () -> Void

    @Environment(\.fluentTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemName)
                    .font(.system(size: 12, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
            }
            .foregroundStyle(isActive ? theme.palette.accentBlue : theme.palette.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? theme.palette.selectionFill : (isHovered ? theme.palette.hoverFill : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isActive ? theme.palette.accentBlue.opacity(0.35) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .help("Toggle \(title) pane")
    }
}
