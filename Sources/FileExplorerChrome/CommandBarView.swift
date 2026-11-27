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
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            } else {
                standardActions
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }

            Spacer(minLength: 8)

            rightPanePills
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
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
        CommandBarPopupButton(
            isEnabled: isEnabled,
            tooltip: "Create a new item in the current folder",
            menuBuilder: { buildNewNSMenu() }
        ) {
            HStack(spacing: 5) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isEnabled ? theme.palette.accentBlue : theme.palette.textSecondary.opacity(0.4))
                Text("New")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(isEnabled ? theme.palette.textPrimary : theme.palette.textSecondary.opacity(0.4))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isEnabled ? theme.palette.textSecondary : theme.palette.textSecondary.opacity(0.4))
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
        }
    }

    // MARK: - ⇅ Sort ▾ Menu

    private var sortMenu: some View {
        CommandBarPopupButton(
            isEnabled: true,
            tooltip: "Sort and group items",
            menuBuilder: { buildSortNSMenu() }
        ) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 12, weight: .medium))
                Text("Sort")
                    .font(.system(size: 12.5, weight: .regular))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.palette.textSecondary)
            }
            .foregroundStyle(theme.palette.textPrimary)
            .padding(.horizontal, 8)
            .frame(height: 32)
        }
    }

    // MARK: - ⊞ View ▾ Menu

    private var viewMenu: some View {
        CommandBarPopupButton(
            isEnabled: true,
            tooltip: "Change layout and visibility options",
            menuBuilder: { buildViewNSMenu() }
        ) {
            HStack(spacing: 5) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 12, weight: .medium))
                Text("View")
                    .font(.system(size: 12.5, weight: .regular))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.palette.textSecondary)
            }
            .foregroundStyle(theme.palette.textPrimary)
            .padding(.horizontal, 8)
            .frame(height: 32)
        }
    }

    // MARK: - ⋯ More Menu

    private var moreMenu: some View {
        CommandBarPopupButton(
            isEnabled: true,
            tooltip: "See more",
            menuBuilder: { buildMoreNSMenu() }
        ) {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary)
                .frame(width: 28, height: 32)
        }
    }

    // MARK: - NSMenu Builders

    private func buildNewNSMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(makeActionItem(title: "Folder", systemImage: "folder.badge.plus") {
            store.newFolder()
        })
        menu.addItem(.separator())
        menu.addItem(makeActionItem(title: "Text Document (.txt)", systemImage: "doc.plaintext") {
            store.newFile(named: "New Text Document", fileExtension: "txt")
        })
        menu.addItem(makeActionItem(title: "Markdown Document (.md)", systemImage: "doc.text") {
            store.newFile(named: "New Markdown Document", fileExtension: "md")
        })
        menu.addItem(makeActionItem(title: "JSON File (.json)", systemImage: "curlybraces") {
            store.newFile(named: "New JSON File", fileExtension: "json")
        })
        menu.addItem(makeActionItem(title: "Shell Script (.sh)", systemImage: "terminal") {
            store.newFile(named: "script", fileExtension: "sh")
        })
        menu.addItem(makeActionItem(title: "Rich Text Document (.rtf)", systemImage: "doc.richtext") {
            store.newFile(named: "New Rich Text Document", fileExtension: "rtf")
        })
        return menu
    }

    private func buildSortNSMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let header = NSMenuItem(title: "Sort by", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        for field in SortField.allCases {
            menu.addItem(makeActionItem(
                title: field.displayTitle,
                isChecked: store.activeTab.sortField == field
            ) {
                store.setSort(field: field)
            })
        }

        menu.addItem(.separator())

        menu.addItem(makeActionItem(
            title: "Ascending",
            isChecked: store.activeTab.sortOrder == .ascending
        ) {
            store.setSort(field: store.activeTab.sortField, order: .ascending)
        })
        menu.addItem(makeActionItem(
            title: "Descending",
            isChecked: store.activeTab.sortOrder == .descending
        ) {
            store.setSort(field: store.activeTab.sortField, order: .descending)
        })

        menu.addItem(.separator())

        let groupMenu = NSMenu()
        groupMenu.autoenablesItems = false
        for groupField in GroupByField.allCases {
            groupMenu.addItem(makeActionItem(
                title: groupField.displayTitle,
                isChecked: store.activeTab.groupBy == groupField
            ) {
                store.setGroupBy(groupField)
            })
        }
        let groupItem = NSMenuItem(title: "Group by", action: nil, keyEquivalent: "")
        groupItem.submenu = groupMenu
        menu.addItem(groupItem)

        return menu
    }

    private func buildViewNSMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        for mode in ViewMode.allCases {
            menu.addItem(makeActionItem(
                title: mode.displayTitle,
                systemImage: mode.iconSystemName,
                isChecked: store.activeTab.viewMode == mode
            ) {
                store.setViewMode(mode)
            })
        }

        menu.addItem(.separator())

        menu.addItem(makeActionItem(
            title: "Compact view",
            isChecked: store.settings.compactView
        ) {
            store.toggleCompactView()
        })

        let showMenu = NSMenu()
        showMenu.autoenablesItems = false
        showMenu.addItem(makeActionItem(
            title: "Navigation pane",
            isChecked: store.settings.showNavigationPane
        ) {
            store.toggleNavigationPane()
        })
        showMenu.addItem(makeActionItem(
            title: "Details pane",
            isChecked: store.settings.rightPaneMode == .details
        ) {
            store.setRightPaneMode(.details)
        })
        showMenu.addItem(makeActionItem(
            title: "Preview pane",
            isChecked: store.settings.rightPaneMode == .preview
        ) {
            store.setRightPaneMode(.preview)
        })
        showMenu.addItem(.separator())
        showMenu.addItem(makeActionItem(
            title: "Item check boxes",
            isChecked: store.settings.showCheckboxes
        ) {
            store.toggleCheckboxes()
        })
        showMenu.addItem(makeActionItem(
            title: "File name extensions",
            isChecked: store.settings.showFileExtensions
        ) {
            store.toggleFileExtensions()
        })
        showMenu.addItem(makeActionItem(
            title: "Hidden items",
            isChecked: store.settings.showHiddenFiles
        ) {
            store.toggleHiddenFiles()
        })

        let showItem = NSMenuItem(title: "Show", action: nil, keyEquivalent: "")
        showItem.submenu = showMenu
        menu.addItem(showItem)

        return menu
    }

    private func buildMoreNSMenu() -> NSMenu {
        let hasSelection = !store.selectedItems.isEmpty
        let canExtract = store.selectedItems.count == 1 && store.selectedItems.first?.kind == .archive
        let propertiesTarget = store.primarySelectedItem?.url ?? store.activeTab.location.urlIfFolder

        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(makeActionItem(
            title: store.undoDescription.map { "Undo \($0)" } ?? "Undo",
            isEnabled: store.canUndo
        ) {
            store.undo()
        })
        menu.addItem(makeActionItem(
            title: store.redoDescription.map { "Redo \($0)" } ?? "Redo",
            isEnabled: store.canRedo
        ) {
            store.redo()
        })
        menu.addItem(.separator())
        menu.addItem(makeActionItem(
            title: "Select all",
            isEnabled: !store.currentItems.isEmpty
        ) {
            store.selectAll()
        })
        menu.addItem(makeActionItem(
            title: "Select none",
            isEnabled: hasSelection
        ) {
            store.deselectAll()
        })
        menu.addItem(makeActionItem(
            title: "Invert selection",
            isEnabled: !store.currentItems.isEmpty
        ) {
            store.invertSelection()
        })
        menu.addItem(.separator())
        menu.addItem(makeActionItem(
            title: "Compress to ZIP file",
            isEnabled: hasSelection
        ) {
            store.zipSelectedItems()
        })
        menu.addItem(makeActionItem(
            title: "Extract all",
            isEnabled: canExtract
        ) {
            if let archive = store.selectedItems.first {
                store.extractArchive(at: archive.url)
            }
        })
        menu.addItem(.separator())
        menu.addItem(makeActionItem(
            title: "Properties",
            isEnabled: propertiesTarget != nil
        ) {
            if let target = propertiesTarget {
                store.showProperties(for: target)
            }
        })
        menu.addItem(makeActionItem(title: "Options...") {
            store.openSettings()
        })
        return menu
    }

    private func makeActionItem(
        title: String,
        systemImage: String? = nil,
        isChecked: Bool = false,
        isEnabled: Bool = true,
        action: @escaping @MainActor () -> Void
    ) -> NSMenuItem {
        let target = MenuClosureTarget(action: action)
        let item = NSMenuItem(title: title, action: #selector(MenuClosureTarget.perform(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = target
        item.isEnabled = isEnabled
        item.state = isChecked ? .on : .off
        if let systemImage {
            item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
        }
        return item
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

// MARK: - Native Popup Menu Button (preserves exact SwiftUI label + chevron.down)

@MainActor
private final class MenuClosureTarget: NSObject {
    let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    @objc func perform(_ sender: Any?) {
        action()
    }
}

private struct CommandBarPopupButton<Label: View>: View {
    let isEnabled: Bool
    let tooltip: String
    let menuBuilder: () -> NSMenu
    @ViewBuilder let label: () -> Label

    @Environment(\.fluentTheme) private var theme
    @State private var isHovered = false
    @State private var anchorView: NSView?

    var body: some View {
        Button {
            guard isEnabled, let anchorView else { return }
            let menu = menuBuilder()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchorView.bounds.height + 4), in: anchorView)
        } label: {
            label()
                .fixedSize(horizontal: true, vertical: false)
                .background(
                    RoundedRectangle(cornerRadius: theme.cornerRadiusSmall, style: .continuous)
                        .fill(isEnabled && isHovered ? theme.palette.hoverFill : .clear)
                )
                .background(PopupAnchorView(anchorView: $anchorView))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(tooltip)
    }
}

private struct PopupAnchorView: NSViewRepresentable {
    @Binding var anchorView: NSView?

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        Task { @MainActor in
            anchorView = view
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if anchorView !== nsView {
            Task { @MainActor in
                anchorView = nsView
            }
        }
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
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .fixedSize(horizontal: true, vertical: false)
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
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .fixedSize(horizontal: true, vertical: false)
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
