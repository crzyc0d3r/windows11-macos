import AppKit
import FileExplorerCore
import FileExplorerDesign
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Surface Tokens

extension FluentTheme {
    /// Seamless shared surface for the active browser tab and the Address Bar row directly below it.
    var activeTabAndAddressSurface: Color {
        activeTabSurface
    }
}

// MARK: - Window Drag Area

/// Transparent titlebar region that allows dragging the window and double-clicking to zoom.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragNSView {
        WindowDragNSView()
    }

    func updateNSView(_ nsView: WindowDragNSView, context: Context) {}
}

final class WindowDragNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.zoom(nil)
        } else {
            window?.performDrag(with: event)
        }
    }
}

// MARK: - Chrome Toolbar Button

struct ChromeIconButton: View {
    let systemName: String
    var size: CGFloat = 28
    var iconSize: CGFloat = 13
    var isEnabled: Bool = true
    var isActive: Bool = false
    var tooltip: String?
    let action: () -> Void

    @Environment(\.fluentTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(foregroundColor)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: theme.cornerRadiusSmall, style: .continuous)
                        .fill(backgroundColor)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(tooltip ?? "")
    }

    private var foregroundColor: Color {
        if !isEnabled {
            return theme.palette.textSecondary.opacity(0.4)
        }
        if isActive {
            return theme.palette.accentBlue
        }
        return theme.palette.textPrimary
    }

    private var backgroundColor: Color {
        if !isEnabled {
            return .clear
        }
        if isActive {
            return theme.palette.selectionFill
        }
        if isHovered {
            return theme.palette.hoverFill
        }
        return .clear
    }
}

// MARK: - macOS Share Sheet Button

struct ShareMenuButton: View {
    let urls: [URL]
    let isSnapshotMode: Bool
    let isDisabled: Bool

    @Environment(\.fluentTheme) private var theme
    @State private var isHovered = false
    @State private var anchorView: NSView?

    var body: some View {
        Button {
            presentSharePicker()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(isDisabled ? theme.palette.textSecondary.opacity(0.4) : theme.palette.textPrimary)
            .frame(width: 32, height: 32)
            .background(
                RoundedRectangle(cornerRadius: theme.cornerRadiusSmall, style: .continuous)
                    .fill(!isDisabled && isHovered ? theme.palette.hoverFill : .clear)
            )
            .background(ShareAnchorRepresentable(anchorView: $anchorView))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hovering in
            isHovered = hovering
        }
        .help("Share")
    }

    private func presentSharePicker() {
        guard !isSnapshotMode, !urls.isEmpty, let anchorView else { return }
        let picker = NSSharingServicePicker(items: urls)
        picker.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
    }
}

private struct ShareAnchorRepresentable: NSViewRepresentable {
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

// MARK: - Drag & Drop URL Helper

@MainActor
enum ChromeDropHelper {
    static func handleFileURLDrop(
        providers: [NSItemProvider],
        destinationFolder: URL,
        store: ExplorerStore
    ) -> Bool {
        let matching = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !matching.isEmpty else { return false }

        let shouldCopy = NSEvent.modifierFlags.contains(.option)

        Task { @MainActor in
            var droppedURLs: [URL] = []
            for provider in matching {
                if let url = await loadFileURL(from: provider) {
                    droppedURLs.append(url)
                }
            }
            guard !droppedURLs.isEmpty else { return }
            if shouldCopy {
                store.copyItems(droppedURLs, to: destinationFolder)
            } else {
                store.moveItems(urls: droppedURLs, to: destinationFolder)
            }
        }
        return true
    }

    private static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                if let data,
                   let string = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   let url = URL(string: string),
                   url.isFileURL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

// MARK: - Filesystem Folder Helpers (Popovers, Autocomplete & Lazy Tree)

struct FolderChoice: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let name: String
    let iconKind: LocationIconKind
}

@MainActor
enum ChromeFilesystemHelper {
    static func immediateSubfolders(
        of folderURL: URL,
        showHidden: Bool,
        store: ExplorerStore
    ) -> [FolderChoice] {
        if store.snapshotMode || !FileManager.default.fileExists(atPath: folderURL.path) {
            return snapshotSubfolders(of: folderURL, store: store)
        }

        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else {
            return snapshotSubfolders(of: folderURL, store: store)
        }

        var results: [FolderChoice] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true,
                  values.isPackage != true else {
                continue
            }
            let isHidden = (values.isHidden == true) || url.lastPathComponent.hasPrefix(".")
            if !showHidden && isHidden {
                continue
            }
            let locKind = ExplorerLocation.folder(url).iconKind
            results.append(FolderChoice(url: url, name: url.lastPathComponent, iconKind: locKind))
        }

        return results.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func snapshotSubfolders(of folderURL: URL, store: ExplorerStore) -> [FolderChoice] {
        let std = folderURL.standardizedFileURL
        var results: [FolderChoice] = []

        func collectFromNodes(_ nodes: [SidebarTreeNode]) {
            for node in nodes {
                if node.url.standardizedFileURL == std {
                    for child in node.children ?? [] {
                        results.append(FolderChoice(url: child.url, name: child.name, iconKind: child.iconKind))
                    }
                } else if let children = node.children {
                    collectFromNodes(children)
                }
            }
        }
        collectFromNodes(store.sidebarTreeNodes)

        for item in store.currentItems where item.isDirectory && !item.isPackage {
            if item.url.deletingLastPathComponent().standardizedFileURL == std {
                let kind = ExplorerLocation.folder(item.url).iconKind
                if !results.contains(where: { $0.url == item.url }) {
                    results.append(FolderChoice(url: item.url, name: item.name, iconKind: kind))
                }
            }
        }

        return results.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func pathSuggestions(
        for input: String,
        store: ExplorerStore
    ) -> [String] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let specials = ["Home", "Gallery", "This Mac", "Trash", "Network"]

        var candidates: [String] = []
        if trimmed.isEmpty {
            candidates.append(contentsOf: specials)
            candidates.append(contentsOf: store.pinnedFolders.map(\.url.path))
            return Array(candidates.prefix(8))
        }

        let lower = trimmed.lowercased()
        for special in specials where special.lowercased().contains(lower) {
            candidates.append(special)
        }

        for pinned in store.pinnedFolders {
            if pinned.url.path.localizedCaseInsensitiveContains(trimmed)
                || pinned.title.localizedCaseInsensitiveContains(trimmed) {
                candidates.append(pinned.url.path)
            }
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            let url = URL(fileURLWithPath: expanded)
            let parent: URL
            let prefix: String
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir),
               isDir.boolValue,
               expanded.hasSuffix("/") {
                parent = url
                prefix = ""
            } else {
                parent = url.deletingLastPathComponent()
                prefix = url.lastPathComponent.lowercased()
            }

            let subfolders = immediateSubfolders(
                of: parent,
                showHidden: store.settings.showHiddenFiles,
                store: store
            )
            for folder in subfolders {
                if prefix.isEmpty || folder.name.lowercased().hasPrefix(prefix) {
                    candidates.append(folder.url.path)
                }
            }
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }.prefix(8).map { $0 }
    }
}
