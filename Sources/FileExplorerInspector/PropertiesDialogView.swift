import AppKit
import FileExplorerCore
import FileExplorerDesign
import SwiftUI

public struct PropertiesDialogView: View {
    public let store: ExplorerStore

    private enum PropertiesTab: String, CaseIterable {
        case general = "General"
        case security = "Security"
        case details = "Details"
    }

    @Environment(\.fluentTheme) private var theme
    @State private var selectedTab: PropertiesTab = .general
    @State private var resolvedItem: FileItem?
    @State private var enrichedInfo: EnrichedInspectorInfo?
    @State private var isCalculatingFolder: Bool = false

    @State private var draftName: String = ""
    @State private var draftReadOnly: Bool = false
    @State private var draftHidden: Bool = false
    @State private var draftPermissions: POSIXPermissions = POSIXPermissions(mode: 0o644)

    @State private var originalName: String = ""
    @State private var originalReadOnly: Bool = false
    @State private var originalHidden: Bool = false
    @State private var originalPermissions: POSIXPermissions = POSIXPermissions(mode: 0o644)
    @State private var statusBanner: String?

    public init(store: ExplorerStore) {
        self.store = store
    }

    public var body: some View {
        if let targetURL = store.propertiesTargetURL {
            ZStack {
                Color.black.opacity(theme.colorScheme == .dark ? 0.45 : 0.25)
                    .ignoresSafeArea()
                    .onTapGesture {
                        store.dismissProperties()
                    }

                dialogCard(for: targetURL)
            }
            .task(id: targetURL) {
                await loadState(for: targetURL)
            }
        }
    }

    private func dialogCard(for targetURL: URL) -> some View {
        let item = resolvedItem ?? InspectorFormatters.resolveItem(for: targetURL, in: store)
        return VStack(spacing: 0) {
            dialogTitleBar(item: item)
            tabStrip
            Divider()
                .overlay(theme.palette.borderSubtle)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch selectedTab {
                    case .general:
                        generalTab(item: item)
                    case .security:
                        securityTab(item: item)
                    case .details:
                        detailsTab(item: item)
                    }
                }
                .padding(16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let statusBanner {
                Text(statusBanner)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.palette.accentBlue)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }

            Divider()
                .overlay(theme.palette.borderSubtle)

            footerButtons(item: item)
        }
        .frame(width: 400, height: 520)
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

    private func dialogTitleBar(item: FileItem) -> some View {
        HStack(spacing: 8) {
            FluentIconView(kind: .forItem(item), size: 16, isSymlink: item.isSymlink)
            Text("\(item.displayName) Properties")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
            Spacer()
            Button {
                store.dismissProperties()
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
        .frame(height: 38)
        .background(theme.palette.commandBar)
    }

    private var tabStrip: some View {
        HStack(spacing: 4) {
            ForEach(PropertiesTab.allCases, id: \.self) { tab in
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

    @ViewBuilder
    private func generalTab(item: FileItem) -> some View {
        let meta = enrichedInfo?.metadata
        HStack(spacing: 12) {
            FileThumbnailView(item: item, size: 48)
            TextField("Name", text: $draftName)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.palette.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(theme.palette.contentCanvas)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(theme.palette.borderSubtle, lineWidth: 1)
                )
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(theme.palette.inputBottomStroke)
                        .frame(height: 1)
                        .padding(.horizontal, 2)
                }
                .disabled(item.url.path == "/")
        }

        Divider().overlay(theme.palette.borderSubtle)

        VStack(alignment: .leading, spacing: 8) {
            InspectorKeyValueRow(label: "Type of file:", value: item.typeDescription)
            if !item.isDirectory || item.isPackage {
                InspectorKeyValueRow(
                    label: "Opens with:",
                    value: meta?.defaultAppName ?? "Default Application"
                )
            }
        }

        Divider().overlay(theme.palette.borderSubtle)

        VStack(alignment: .leading, spacing: 8) {
            InspectorKeyValueRow(
                label: "Location:",
                value: item.url.deletingLastPathComponent().path
            )

            if item.isDirectory && !item.isPackage {
                if let folderBytes = meta?.folderSizeBytes {
                    let files = meta?.folderFileCount ?? item.childCount ?? 0
                    let folders = meta?.folderSubfolderCount ?? 0
                    InspectorKeyValueRow(
                        label: "Size:",
                        value: InspectorFormatters.formatDetailedBytes(folderBytes)
                    )
                    InspectorKeyValueRow(
                        label: "Contains:",
                        value: "\(files) Files, \(folders) Folders"
                    )
                } else {
                    InspectorKeyValueRow(
                        label: "Size:",
                        value: isCalculatingFolder ? "Calculating..." : "—"
                    )
                }
            } else {
                InspectorKeyValueRow(
                    label: "Size:",
                    value: InspectorFormatters.formatDetailedBytes(item.size)
                )
                let onDisk = enrichedInfo?.allocatedSizeBytes ?? item.size
                InspectorKeyValueRow(
                    label: "Size on disk:",
                    value: InspectorFormatters.formatDetailedBytes(onDisk)
                )
            }
        }

        Divider().overlay(theme.palette.borderSubtle)

        VStack(alignment: .leading, spacing: 8) {
            InspectorKeyValueRow(label: "Created:", value: InspectorFormatters.formatDate(item.dateCreated))
            InspectorKeyValueRow(label: "Modified:", value: InspectorFormatters.formatDate(item.dateModified))
        }

        Divider().overlay(theme.palette.borderSubtle)

        HStack(alignment: .top, spacing: 8) {
            Text("Attributes:")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.palette.textSecondary)
                .frame(width: 96, alignment: .leading)

            HStack(spacing: 18) {
                Toggle("Read-only", isOn: $draftReadOnly)
                    .toggleStyle(FluentCheckboxToggleStyle())
                Toggle("Hidden", isOn: $draftHidden)
                    .toggleStyle(FluentCheckboxToggleStyle())
            }
        }
    }

    private func securityTab(item: FileItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("POSIX Permissions")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.palette.textPrimary)
                    Text(item.url.lastPathComponent)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineLimit(1)
                }

                Spacer()

                HStack(spacing: 6) {
                    Text("0\(draftPermissions.octalString)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.palette.accentBlue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(theme.palette.selectionFill)
                        )

                    Text(draftPermissions.symbolicString)
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.palette.textPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(theme.palette.cardSurface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(theme.palette.borderSubtle, lineWidth: 1)
                        )
                }
            }

            InspectorSectionCard {
                VStack(spacing: 0) {
                    HStack {
                        Text("Subject")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Read")
                            .frame(width: 54)
                        Text("Write")
                            .frame(width: 54)
                        Text("Execute")
                            .frame(width: 58)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.palette.textSecondary)
                    .padding(.bottom, 8)

                    Divider().overlay(theme.palette.borderSubtle)

                    permissionRow(
                        subject: "Owner",
                        read: bindingForPermission(\.ownerRead),
                        write: bindingForPermission(\.ownerWrite),
                        execute: bindingForPermission(\.ownerExecute)
                    )
                    Divider().overlay(theme.palette.borderSubtle)
                    permissionRow(
                        subject: "Group",
                        read: bindingForPermission(\.groupRead),
                        write: bindingForPermission(\.groupWrite),
                        execute: bindingForPermission(\.groupExecute)
                    )
                    Divider().overlay(theme.palette.borderSubtle)
                    permissionRow(
                        subject: "Everyone",
                        read: bindingForPermission(\.othersRead),
                        write: bindingForPermission(\.othersWrite),
                        execute: bindingForPermission(\.othersExecute)
                    )
                }
            }

            HStack(spacing: 8) {
                Text("Presets:")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.palette.textSecondary)
                presetButton("0755", mode: 0o755)
                presetButton("0644", mode: 0o644)
                presetButton("0700", mode: 0o700)
                Spacer()
            }
        }
    }

    private func permissionRow(
        subject: String,
        read: Binding<Bool>,
        write: Binding<Bool>,
        execute: Binding<Bool>
    ) -> some View {
        HStack {
            Text(subject)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(theme.palette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("", isOn: read)
                .labelsHidden()
                .toggleStyle(FluentCheckboxToggleStyle())
                .frame(width: 54)

            Toggle("", isOn: write)
                .labelsHidden()
                .toggleStyle(FluentCheckboxToggleStyle())
                .frame(width: 54)

            Toggle("", isOn: execute)
                .labelsHidden()
                .toggleStyle(FluentCheckboxToggleStyle())
                .frame(width: 58)
        }
        .padding(.vertical, 8)
    }

    private func presetButton(_ label: String, mode: UInt16) -> some View {
        let isActive = (draftPermissions.mode & 0o777) == mode
        return Button {
            draftPermissions = POSIXPermissions(mode: mode)
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(isActive ? theme.palette.accentBlue : theme.palette.textPrimary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isActive ? theme.palette.selectionFill : theme.palette.cardSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(theme.palette.borderSubtle, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func detailsTab(item: FileItem) -> some View {
        let meta = enrichedInfo?.metadata
        var rows: [(String, String)] = [
            ("Name", item.name),
            ("Kind", item.kind.displayName),
            ("Type", item.typeDescription),
            ("Path", item.url.path),
            ("Extension", item.fileExtension.isEmpty ? "—" : ".\(item.fileExtension)"),
            ("Size", item.isDirectory && !item.isPackage ? (meta?.folderSizeBytes.map { InspectorFormatters.formatDetailedBytes($0) } ?? "—") : InspectorFormatters.formatDetailedBytes(item.size)),
            ("Date created", InspectorFormatters.formatDate(item.dateCreated)),
            ("Date modified", InspectorFormatters.formatDate(item.dateModified)),
            ("Permissions", "\(draftPermissions.symbolicString) (0\(draftPermissions.octalString))"),
            ("Read-only", item.isReadOnly ? "Yes" : "No"),
            ("Hidden", item.isHidden ? "Yes" : "No"),
            ("Symbolic link", item.isSymlink ? "Yes" : "No")
        ]

        if let dims = meta?.dimensions {
            rows.append(("Dimensions", dims))
        }
        if let exif = meta?.exifSummary {
            rows.append(contentsOf: exif)
        }
        if let duration = meta?.mediaDuration {
            rows.append(("Duration", duration))
        }
        if let codec = meta?.mediaCodec {
            rows.append(("Codec", codec))
        }
        if let pages = meta?.pdfPageCount {
            rows.append(("PDF Pages", "\(pages)"))
        }
        if let author = enrichedInfo?.pdfAuthor, !author.isEmpty {
            rows.append(("Author", author))
        }
        if let lines = meta?.lineCount {
            rows.append(("Line count", "\(lines)"))
        }
        if let fileCount = meta?.folderFileCount {
            rows.append(("Files inside", "\(fileCount)"))
        }
        if let folderCount = meta?.folderSubfolderCount {
            rows.append(("Subfolders", "\(folderCount)"))
        }
        if let defaultApp = meta?.defaultAppName {
            rows.append(("Opens with", defaultApp))
        }

        return InspectorSectionCard {
            VStack(spacing: 0) {
                HStack {
                    Text("Property")
                        .frame(width: 112, alignment: .leading)
                    Text("Value")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.palette.textSecondary)
                .padding(.bottom, 6)

                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 {
                        Divider().overlay(theme.palette.borderSubtle)
                    }
                    HStack(alignment: .top, spacing: 8) {
                        Text(row.0)
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.palette.textSecondary)
                            .frame(width: 112, alignment: .leading)
                        Text(row.1)
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.palette.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func footerButtons(item: FileItem) -> some View {
        HStack(spacing: 8) {
            Spacer()

            dialogButton("OK", isPrimary: true) {
                if hasChanges {
                    applyChanges(for: item)
                }
                store.dismissProperties()
            }

            dialogButton("Cancel", isPrimary: false) {
                store.dismissProperties()
            }

            dialogButton("Apply", isPrimary: false, isEnabled: hasChanges) {
                applyChanges(for: item)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(theme.palette.commandBar)
    }

    private func dialogButton(
        _ title: String,
        isPrimary: Bool,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: isPrimary ? .semibold : .regular))
                .foregroundStyle(
                    !isEnabled
                        ? theme.palette.textSecondary.opacity(0.45)
                        : (isPrimary ? (theme.colorScheme == .dark ? Color.black : Color.white) : theme.palette.textPrimary)
                )
                .frame(minWidth: 74)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isPrimary ? theme.palette.accentBlue : theme.palette.cardSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(isPrimary ? Color.clear : theme.palette.borderSubtle, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    private var hasChanges: Bool {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        return (!trimmed.isEmpty && trimmed != originalName)
            || draftReadOnly != originalReadOnly
            || draftHidden != originalHidden
            || draftPermissions != originalPermissions
    }

    private func bindingForPermission(_ keyPath: KeyPath<POSIXPermissions, Bool>) -> Binding<Bool> {
        Binding(
            get: { draftPermissions[keyPath: keyPath] },
            set: { newValue in
                draftPermissions = POSIXPermissions(
                    ownerRead: keyPath == \.ownerRead ? newValue : draftPermissions.ownerRead,
                    ownerWrite: keyPath == \.ownerWrite ? newValue : draftPermissions.ownerWrite,
                    ownerExecute: keyPath == \.ownerExecute ? newValue : draftPermissions.ownerExecute,
                    groupRead: keyPath == \.groupRead ? newValue : draftPermissions.groupRead,
                    groupWrite: keyPath == \.groupWrite ? newValue : draftPermissions.groupWrite,
                    groupExecute: keyPath == \.groupExecute ? newValue : draftPermissions.groupExecute,
                    othersRead: keyPath == \.othersRead ? newValue : draftPermissions.othersRead,
                    othersWrite: keyPath == \.othersWrite ? newValue : draftPermissions.othersWrite,
                    othersExecute: keyPath == \.othersExecute ? newValue : draftPermissions.othersExecute
                )
            }
        )
    }

    private func loadState(for targetURL: URL) async {
        selectedTab = .general
        statusBanner = nil
        let item = InspectorFormatters.resolveItem(for: targetURL, in: store)
        resolvedItem = item
        draftName = item.name
        draftReadOnly = item.isReadOnly
        draftHidden = item.isHidden
        draftPermissions = item.posixPermissions ?? POSIXPermissions(mode: item.isDirectory ? 0o755 : 0o644)

        originalName = draftName
        originalReadOnly = draftReadOnly
        originalHidden = draftHidden
        originalPermissions = draftPermissions

        isCalculatingFolder = item.isDirectory && !item.isPackage
        let info = await InspectorMetadataLoader.load(for: item, store: store)
        if !Task.isCancelled {
            enrichedInfo = info
            isCalculatingFolder = false
        }
    }

    private func applyChanges(for item: FileItem) {
        var currentURL = item.url
        let trimmedName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedName.isEmpty && trimmedName != originalName {
            store.renameItem(at: currentURL, to: trimmedName)
            let updatedURL = currentURL.deletingLastPathComponent().appendingPathComponent(trimmedName, isDirectory: item.isDirectory)
            currentURL = updatedURL
            store.showProperties(for: updatedURL)
        }

        if !store.snapshotMode && FileManager.default.fileExists(atPath: currentURL.path) {
            do {
                if draftPermissions != originalPermissions || draftReadOnly != originalReadOnly {
                    try FileManager.default.setAttributes(
                        [
                            .posixPermissions: NSNumber(value: draftPermissions.mode),
                            .immutable: NSNumber(value: draftReadOnly)
                        ],
                        ofItemAtPath: currentURL.path
                    )
                }
                if draftHidden != originalHidden {
                    var resourceValues = URLResourceValues()
                    resourceValues.isHidden = draftHidden
                    var mutableURL = currentURL
                    try mutableURL.setResourceValues(resourceValues)
                }
                store.refresh()
                statusBanner = "Changes applied"
            } catch {
                statusBanner = error.localizedDescription
            }
        } else {
            if let index = store.currentItems.firstIndex(where: { $0.url == currentURL }) {
                let existing = store.currentItems[index]
                store.currentItems[index] = FileItem(
                    url: existing.url,
                    name: existing.name,
                    displayName: existing.displayName,
                    fileExtension: existing.fileExtension,
                    kind: existing.kind,
                    isDirectory: existing.isDirectory,
                    isHidden: draftHidden,
                    isSymlink: existing.isSymlink,
                    isPackage: existing.isPackage,
                    isReadOnly: draftReadOnly,
                    size: existing.size,
                    dateModified: existing.dateModified,
                    dateCreated: existing.dateCreated,
                    childCount: existing.childCount,
                    typeDescription: existing.typeDescription,
                    posixPermissions: draftPermissions
                )
            }
            statusBanner = "Changes applied"
        }

        resolvedItem = InspectorFormatters.resolveItem(for: currentURL, in: store)
        originalName = trimmedName.isEmpty ? originalName : trimmedName
        originalReadOnly = draftReadOnly
        originalHidden = draftHidden
        originalPermissions = draftPermissions
    }
}
