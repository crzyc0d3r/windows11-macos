import FileExplorerCore
import FileExplorerDesign
import SwiftUI

public struct FileOperationOverlayView: View {
    public let store: ExplorerStore

    @Environment(\.fluentTheme) private var theme

    public init(store: ExplorerStore) {
        self.store = store
    }

    public var body: some View {
        if !store.activeOperations.isEmpty {
            VStack(alignment: .trailing, spacing: 10) {
                ForEach(store.activeOperations) { op in
                    operationCard(op)
                }
            }
            .padding(.trailing, 16)
            .padding(.bottom, 38)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .allowsHitTesting(true)
        }
    }

    private func operationCard(_ op: FileOperationProgress) -> some View {
        let pct = Int((op.fractionCompleted * 100).rounded())
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.palette.accentBlue)

                Text(op.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)

                Spacer()

                Text("\(pct)%")
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.palette.accentBlue)

                if op.isCancellable {
                    Button {
                        store.cancelOperation(id: op.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(theme.palette.textSecondary)
                            .frame(width: 22, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(theme.palette.hoverFill)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Cancel operation")
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(theme.palette.hoverFill)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(theme.palette.accentBlue)
                        .frame(width: max(4, geo.size.width * op.fractionCompleted))
                        .animation(.easeInOut(duration: 0.2), value: op.fractionCompleted)
                }
            }
            .frame(height: 6)

            HStack(spacing: 8) {
                Text(op.currentItem)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                if op.totalBytes > 0 {
                    Text("\(InspectorFormatters.formatBytes(op.completedBytes)) / \(InspectorFormatters.formatBytes(op.totalBytes))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.palette.textSecondary)
                } else if op.totalItems > 0 {
                    Text("\(op.completedItems) of \(op.totalItems)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.palette.textSecondary)
                }
            }
        }
        .padding(12)
        .frame(width: 340)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.palette.elevatedFlyout)
        )
        .background(
            MicaBackground(variant: .acrylic)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.palette.borderSubtle, lineWidth: 1)
        )
        .shadow(
            color: Color.black.opacity(theme.colorScheme == .dark ? 0.42 : 0.18),
            radius: 14,
            x: 0,
            y: 6
        )
    }
}

public struct ConflictResolutionDialogView: View {
    public let store: ExplorerStore

    @Environment(\.fluentTheme) private var theme
    @State private var applyToAll: Bool = false

    public init(store: ExplorerStore) {
        self.store = store
    }

    public var body: some View {
        if let conflict = store.pendingConflict {
            ZStack {
                Color.black.opacity(theme.colorScheme == .dark ? 0.45 : 0.25)
                    .ignoresSafeArea()

                dialogCard(for: conflict)
            }
            .onChange(of: conflict.id) { _, _ in
                applyToAll = false
            }
        }
    }

    private func dialogCard(for conflict: ConflictRequest) -> some View {
        let targetName = conflict.destinationURL.lastPathComponent
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.orange)

                Text(conflict.isDirectory ? "Replace or Skip Folder" : "Replace or Skip Files")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)

                Spacer()

                Button {
                    store.resolveConflict(.skip, applyToAll: false)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.palette.textSecondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .frame(height: 42)
            .background(theme.palette.commandBar)

            Divider().overlay(theme.palette.borderSubtle)

            VStack(alignment: .leading, spacing: 12) {
                Text("The destination already has \(conflict.isDirectory ? "a folder" : "a file") named \"\(targetName)\"")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.palette.textPrimary)

                HStack(spacing: 10) {
                    endpointCard(title: "Source", url: conflict.sourceURL, isDirectory: conflict.isDirectory)
                    endpointCard(title: "Destination", url: conflict.destinationURL, isDirectory: conflict.isDirectory)
                }

                VStack(spacing: 8) {
                    conflictOptionButton(
                        title: conflict.isDirectory ? "Merge & replace files in destination" : "Replace the file in the destination",
                        subtitle: "Overwrite \"\(targetName)\" with the incoming item",
                        systemImage: "arrow.triangle.2.circlepath"
                    ) {
                        store.resolveConflict(.replace, applyToAll: applyToAll)
                    }

                    conflictOptionButton(
                        title: conflict.isDirectory ? "Skip this folder" : "Skip this file",
                        subtitle: "Leave the existing destination item untouched",
                        systemImage: "forward.end"
                    ) {
                        store.resolveConflict(.skip, applyToAll: applyToAll)
                    }

                    conflictOptionButton(
                        title: "Keep both",
                        subtitle: "Rename incoming item automatically (e.g., \"\(targetName) (2)\")",
                        systemImage: "doc.on.doc"
                    ) {
                        store.resolveConflict(.keepBoth, applyToAll: applyToAll)
                    }
                }
            }
            .padding(16)

            Divider().overlay(theme.palette.borderSubtle)

            HStack {
                Toggle("Do this for all current items", isOn: $applyToAll)
                    .toggleStyle(FluentCheckboxToggleStyle())

                Spacer()

                Button {
                    store.resolveConflict(.skip, applyToAll: false)
                } label: {
                    Text("Cancel")
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.palette.textPrimary)
                        .frame(minWidth: 74)
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
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(theme.palette.commandBar)
        }
        .frame(width: 450)
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
            radius: 22,
            x: 0,
            y: 10
        )
    }

    private func endpointCard(title: String, url: URL, isDirectory: Bool) -> some View {
        let item = InspectorFormatters.resolveItem(for: url, in: store)
        return VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(theme.palette.textSecondary)
            HStack(spacing: 8) {
                FluentIconView(kind: .forItem(item), size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.palette.textPrimary)
                        .lineLimit(1)
                    Text(isDirectory ? "Folder" : InspectorFormatters.formatBytes(item.size))
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.palette.textSecondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.palette.cardSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(theme.palette.borderSubtle, lineWidth: 1)
        )
    }

    private func conflictOptionButton(
        title: String,
        subtitle: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        ConflictActionRow(title: title, subtitle: subtitle, systemImage: systemImage, action: action)
    }
}

private struct ConflictActionRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    @Environment(\.fluentTheme) private var theme
    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.palette.accentBlue)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(theme.palette.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.palette.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovered ? theme.palette.hoverFill : theme.palette.cardSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isHovered ? theme.palette.accentBlue.opacity(0.45) : theme.palette.borderSubtle, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
