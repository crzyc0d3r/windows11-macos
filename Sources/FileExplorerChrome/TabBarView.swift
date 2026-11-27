import AppKit
import FileExplorerCore
import FileExplorerDesign
import SwiftUI
import UniformTypeIdentifiers

/// Top Windows 11 24H2 browser-style tab strip (~40px tall) over `.micaAlt`.
struct TabBarView: View {
    let store: ExplorerStore
    var onMoveTabToNewWindow: ((ExplorerTab) -> Void)?

    @Environment(\.fluentTheme) private var theme
    @State private var hoveredTabID: UUID?
    @State private var draggedTabID: UUID?
    @State private var isAddButtonHovered = false

    private let tabBarHeight: CGFloat = 40

    var body: some View {
        ZStack(alignment: .bottom) {
            MicaBackground(variant: .micaAlt)

            // Subtle bottom hairline behind inactive tabs; the active tab sits on top and masks it.
            Rectangle()
                .fill(theme.palette.borderSubtle)
                .frame(height: 1)

            HStack(spacing: 0) {
                // Leave ~78px clear on the left for macOS traffic lights (close / minimize / zoom).
                WindowDragArea()
                    .frame(width: 78, height: tabBarHeight)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(Array(store.tabs.enumerated()), id: \.element.id) { index, tab in
                            let isActive = tab.id == store.activeTabID
                            let nextIsActive = index + 1 < store.tabs.count
                                && store.tabs[index + 1].id == store.activeTabID
                            let isHovered = hoveredTabID == tab.id
                            let nextIsHovered = index + 1 < store.tabs.count
                                && hoveredTabID == store.tabs[index + 1].id

                            TabItemView(
                                tab: tab,
                                index: index,
                                totalCount: store.tabs.count,
                                isActive: isActive,
                                isHovered: isHovered,
                                showTrailingSeparator: !isActive && !isHovered && !nextIsActive && !nextIsHovered && index < store.tabs.count - 1,
                                isTrashEmpty: store.isTrashEmpty,
                                onSelect: {
                                    store.selectTab(id: tab.id)
                                },
                                onClose: {
                                    store.closeTab(id: tab.id)
                                },
                                onDuplicate: {
                                    store.duplicateTab(id: tab.id)
                                },
                                onCloseOthers: {
                                    store.closeOtherTabs(keeping: tab.id)
                                },
                                onCloseToRight: {
                                    closeTabsToRight(of: index)
                                },
                                onMoveToNewWindow: onMoveTabToNewWindow.map { callback in
                                    { callback(tab) }
                                },
                                onHoverChanged: { hovering in
                                    hoveredTabID = hovering ? tab.id : (hoveredTabID == tab.id ? nil : hoveredTabID)
                                }
                            )
                            .zIndex(isActive ? 2 : 0)
                            .onDrag {
                                draggedTabID = tab.id
                                return NSItemProvider(object: tab.id.uuidString as NSString)
                            }
                            .onDrop(
                                of: [.text],
                                delegate: TabReorderDropDelegate(
                                    targetTabID: tab.id,
                                    store: store,
                                    draggedTabID: $draggedTabID
                                )
                            )
                        }

                        addTabButton
                            .padding(.leading, 4)
                            .padding(.bottom, 5)
                    }
                    .frame(height: tabBarHeight, alignment: .bottom)
                }
                .frame(height: tabBarHeight)

                // Draggable titlebar region in the empty trailing space.
                WindowDragArea()
                    .frame(minWidth: 32, maxWidth: .infinity, minHeight: tabBarHeight, maxHeight: tabBarHeight)
            }
        }
        .frame(height: tabBarHeight)
    }

    private var addTabButton: some View {
        Button {
            store.newTab(at: .home)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.palette.textPrimary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: theme.cornerRadiusSmall, style: .continuous)
                        .fill(isAddButtonHovered ? theme.palette.hoverFill : .clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isAddButtonHovered = hovering
        }
        .help("New tab (⌘T)")
    }

    private func closeTabsToRight(of index: Int) {
        let idsToClose = store.tabs.dropFirst(index + 1).map(\.id)
        for id in idsToClose.reversed() {
            store.closeTab(id: id)
        }
    }
}

// MARK: - Individual Tab View

private struct TabItemView: View {
    let tab: ExplorerTab
    let index: Int
    let totalCount: Int
    let isActive: Bool
    let isHovered: Bool
    let showTrailingSeparator: Bool
    let isTrashEmpty: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onDuplicate: () -> Void
    let onCloseOthers: () -> Void
    let onCloseToRight: () -> Void
    let onMoveToNewWindow: (() -> Void)?
    let onHoverChanged: (Bool) -> Void

    @Environment(\.fluentTheme) private var theme
    @State private var isCloseHovered = false

    private let flareRadius: CGFloat = 8
    private let topCornerRadius: CGFloat = 8

    var body: some View {
        ZStack(alignment: .trailing) {
            tabBackground
                .overlay(alignment: .center) {
                    HStack(spacing: 8) {
                        FluentIconView(
                            kind: FluentIconKind(
                                locationIcon: tab.location.iconKind,
                                isTrashEmpty: isTrashEmpty
                            ),
                            size: 14
                        )

                        Text(tab.title)
                            .font(.system(size: 12, weight: isActive ? .medium : .regular))
                            .foregroundStyle(isActive ? theme.palette.textPrimary : theme.palette.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 2)

                        if totalCount > 1 && (isActive || isHovered) {
                            closeButton
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, isActive ? 2 : 0)
                }

            if showTrailingSeparator {
                Rectangle()
                    .fill(theme.palette.borderSubtle)
                    .frame(width: 1, height: 16)
                    .padding(.vertical, 9)
            }
        }
        .frame(minWidth: 110, idealWidth: 185, maxWidth: 220)
        .frame(height: isActive ? 34 : 32)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .onHover { hovering in
            onHoverChanged(hovering)
        }
        .contextMenu {
            Button("Duplicate tab", action: onDuplicate)
            if let onMoveToNewWindow {
                Button("Move tab to new window", action: onMoveToNewWindow)
                    .disabled(totalCount <= 1)
            }
            Divider()
            Button("Close tab", action: onClose)
                .disabled(totalCount <= 1)
            Button("Close other tabs", action: onCloseOthers)
                .disabled(totalCount <= 1)
            Button("Close tabs to the right", action: onCloseToRight)
                .disabled(index >= totalCount - 1)
        }
    }

    @ViewBuilder
    private var tabBackground: some View {
        if isActive {
            ZStack {
                Win11ActiveTabShape(topRadius: topCornerRadius, flareRadius: flareRadius)
                    .fill(theme.activeTabAndAddressSurface)

                Win11ActiveTabBorderShape(topRadius: topCornerRadius, flareRadius: flareRadius)
                    .stroke(theme.palette.borderSubtle, lineWidth: 1)
            }
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered ? theme.palette.hoverFill : .clear)
                .padding(.horizontal, 3)
                .padding(.bottom, 3)
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.palette.textSecondary)
                .frame(width: 18, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isCloseHovered ? theme.palette.hoverFill : .clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isCloseHovered = hovering
        }
        .help("Close tab (⌘W)")
    }
}

// MARK: - Windows 11 Inverted-Shoulder Active Tab Shapes

private struct Win11ActiveTabShape: Shape {
    let topRadius: CGFloat
    let flareRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let r = min(topRadius, w * 0.25, h * 0.4)
        let f = min(flareRadius, h * 0.4)

        var p = Path()
        p.move(to: CGPoint(x: -f, y: h))
        p.addQuadCurve(to: CGPoint(x: 0, y: h - f), control: CGPoint(x: 0, y: h))
        p.addLine(to: CGPoint(x: 0, y: r))
        p.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: w - r, y: 0))
        p.addQuadCurve(to: CGPoint(x: w, y: r), control: CGPoint(x: w, y: 0))
        p.addLine(to: CGPoint(x: w, y: h - f))
        p.addQuadCurve(to: CGPoint(x: w + f, y: h), control: CGPoint(x: w, y: h))
        p.closeSubpath()
        return p
    }
}

private struct Win11ActiveTabBorderShape: Shape {
    let topRadius: CGFloat
    let flareRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let r = min(topRadius, w * 0.25, h * 0.4)
        let f = min(flareRadius, h * 0.4)

        var p = Path()
        p.move(to: CGPoint(x: -f, y: h))
        p.addQuadCurve(to: CGPoint(x: 0, y: h - f), control: CGPoint(x: 0, y: h))
        p.addLine(to: CGPoint(x: 0, y: r))
        p.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: w - r, y: 0))
        p.addQuadCurve(to: CGPoint(x: w, y: r), control: CGPoint(x: w, y: 0))
        p.addLine(to: CGPoint(x: w, y: h - f))
        p.addQuadCurve(to: CGPoint(x: w + f, y: h), control: CGPoint(x: w, y: h))
        return p
    }
}

// MARK: - Tab Reordering Drop Delegate

private struct TabReorderDropDelegate: DropDelegate {
    let targetTabID: UUID
    let store: ExplorerStore
    @Binding var draggedTabID: UUID?

    func dropEntered(info: DropInfo) {
        guard let draggedID = draggedTabID,
              draggedID != targetTabID,
              let fromIndex = store.tabs.firstIndex(where: { $0.id == draggedID }),
              let toIndex = store.tabs.firstIndex(where: { $0.id == targetTabID }) else {
            return
        }
        let destination = toIndex > fromIndex ? toIndex + 1 : toIndex
        withAnimation(.easeInOut(duration: 0.14)) {
            store.moveTab(from: fromIndex, to: destination)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedTabID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
