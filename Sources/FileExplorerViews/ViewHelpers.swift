import AppKit
import FileExplorerCore
import FileExplorerDesign
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Formatting & Display Helpers

@MainActor
enum ExplorerViewFormatting {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    private static let driveFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useTB]
        formatter.countStyle = .decimal
        formatter.includesUnit = true
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    static func displayName(for item: FileItem, showExtensions: Bool) -> String {
        if showExtensions || item.isDirectory || item.isPackage || item.fileExtension.isEmpty {
            return item.displayName
        }
        let extSuffix = ".\(item.fileExtension)"
        if item.displayName.lowercased().hasSuffix(extSuffix.lowercased()),
           item.displayName.count > extSuffix.count {
            return String(item.displayName.dropLast(extSuffix.count))
        }
        return item.displayName
    }

    static func formattedSize(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: bytes)
    }

    static func formattedDriveSpace(_ bytes: Int64) -> String {
        driveFormatter.string(fromByteCount: bytes)
    }

    static func formattedDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    static func isCut(_ item: FileItem, in store: ExplorerStore) -> Bool {
        guard let payload = store.clipboardPayload, payload.operation == .cut else {
            return false
        }
        return payload.urls.contains(item.url)
    }

    static func iconKind(for pinned: PinnedFolder) -> FluentIconKind {
        if let iconName = pinned.iconName {
            switch iconName.lowercased() {
            case "desktop": return .desktop
            case "downloads": return .downloads
            case "documents": return .documents
            case "pictures": return .pictures
            case "music": return .music
            case "videos", "movies": return .videos
            case "applications": return .applications
            case "home": return .home
            default: break
            }
        }
        return FluentIconKind(locationIcon: ExplorerLocation.folder(pinned.url).iconKind)
    }
}

// MARK: - Drag & Drop URL Extraction

@MainActor
enum ExplorerDropHelper {
    static func extractFileURLs(
        from providers: [NSItemProvider],
        completion: @escaping @MainActor ([URL]) -> Void
    ) {
        let fileTypeID = UTType.fileURL.identifier
        let matching = providers.filter { $0.hasItemConformingToTypeIdentifier(fileTypeID) }
        guard !matching.isEmpty else {
            Task { @MainActor in completion([]) }
            return
        }

        let collector = URLDropCollector(expectedCount: matching.count, completion: completion)
        for provider in matching {
            provider.loadDataRepresentation(forTypeIdentifier: fileTypeID) { data, _ in
                let parsedURL: URL?
                if let data {
                    parsedURL = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    parsedURL = nil
                }
                Task { @MainActor in
                    collector.record(parsedURL)
                }
            }
        }
    }

    @MainActor
    static func handleDrop(
        providers: [NSItemProvider],
        into destinationFolder: URL,
        store: ExplorerStore
    ) -> Bool {
        let isCopy = NSEvent.modifierFlags.contains(.option)
        extractFileURLs(from: providers) { urls in
            let valid = urls.filter { $0 != destinationFolder && $0.deletingLastPathComponent() != destinationFolder }
            guard !valid.isEmpty else { return }
            if isCopy {
                store.copyItems(valid, to: destinationFolder)
            } else {
                store.moveItems(urls: valid, to: destinationFolder)
            }
        }
        return true
    }
}

@MainActor
private final class URLDropCollector {
    private var remaining: Int
    private var urls: [URL] = []
    private let completion: @MainActor ([URL]) -> Void

    init(expectedCount: Int, completion: @escaping @MainActor ([URL]) -> Void) {
        self.remaining = expectedCount
        self.completion = completion
    }

    func record(_ url: URL?) {
        if let url {
            urls.append(url)
        }
        remaining -= 1
        if remaining <= 0 {
            completion(urls)
        }
    }
}

// MARK: - Item Frame Preference Key (Marquee Selection)

struct ItemFramePreferenceKey: PreferenceKey {
    static let defaultValue: [URL: CGRect] = [:]

    static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    func reportItemFrame(url: URL, in coordinateSpace: String = "ContentCanvasSpace") -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ItemFramePreferenceKey.self,
                    value: [url: proxy.frame(in: .named(coordinateSpace))]
                )
            }
        )
    }
}

// MARK: - Right-Click Detector Overlay (Transparent to Left-Clicks & Drags)

struct RightClickHandlerOverlay: NSViewRepresentable {
    let onRightClick: () -> Void

    func makeNSView(context: Context) -> RightClickDetectorNSView {
        let view = RightClickDetectorNSView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ nsView: RightClickDetectorNSView, context: Context) {
        nsView.onRightClick = onRightClick
    }
}

final class RightClickDetectorNSView: NSView {
    var onRightClick: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        let isRightClick = event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        guard isRightClick else { return nil }
        return super.hitTest(point)
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            onRightClick?()
        } else {
            super.mouseDown(with: event)
        }
    }
}

// MARK: - Collapsible Windows 11 Section Header

struct Win11SectionHeader: View {
    let title: String
    let count: Int?
    let isCollapsed: Bool
    let onToggle: () -> Void

    @Environment(\.fluentTheme) private var theme
    @State private var isHovered = false

    init(title: String, count: Int? = nil, isCollapsed: Bool, onToggle: @escaping () -> Void) {
        self.title = title
        self.count = count
        self.isCollapsed = isCollapsed
        self.onToggle = onToggle
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.palette.textSecondary)
                    .frame(width: 14, height: 14)

                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)

                if let count {
                    Text("(\(count))")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(theme.palette.textSecondary)
                }

                Rectangle()
                    .fill(theme.palette.borderSubtle)
                    .frame(height: 1)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: theme.cornerRadiusSmall, style: .continuous)
                    .fill(isHovered ? theme.palette.hoverFill : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Inline Rename TextField (Auto-Focus & Stem Selection)

struct InlineRenameField: NSViewRepresentable {
    let item: FileItem
    let font: NSFont
    let alignment: NSTextAlignment
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    init(
        item: FileItem,
        font: NSFont = .systemFont(ofSize: 12.5),
        alignment: NSTextAlignment = .left,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.item = item
        self.font = font
        self.alignment = alignment
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(item: item, onCommit: onCommit, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.stringValue = item.name
        field.font = font
        field.alignment = alignment
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator

        DispatchQueue.main.async {
            guard let window = field.window else { return }
            window.makeFirstResponder(field)
            if let editor = field.currentEditor() as? NSTextView {
                let stemLength = Self.stemLength(for: item)
                editor.selectedRange = NSRange(location: 0, length: stemLength)
            }
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.onCommit = onCommit
        context.coordinator.onCancel = onCancel
    }

    private static func stemLength(for item: FileItem) -> Int {
        let name = item.name as NSString
        guard !item.isDirectory, !item.isPackage else {
            return name.length
        }
        let dotRange = name.range(of: ".", options: .backwards)
        if dotRange.location != NSNotFound, dotRange.location > 0 {
            return dotRange.location
        }
        return name.length
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let item: FileItem
        var onCommit: (String) -> Void
        var onCancel: () -> Void
        private var didFinish = false

        init(item: FileItem, onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
            self.item = item
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                finishCommit(with: control.stringValue)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                finishCancel()
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard !didFinish, let field = obj.object as? NSTextField else { return }
            finishCommit(with: field.stringValue)
        }

        private func finishCommit(with text: String) {
            guard !didFinish else { return }
            didFinish = true
            onCommit(text)
        }

        private func finishCancel() {
            guard !didFinish else { return }
            didFinish = true
            onCancel()
        }
    }
}

// MARK: - Shared Item Interaction Helper

@MainActor
enum ItemInteractionHandler {
    static func handleTap(item: FileItem, store: ExplorerStore, onFocusCanvas: () -> Void) {
        onFocusCanvas()
        let flags = NSEvent.modifierFlags
        let clickCount = NSApp.currentEvent?.clickCount ?? 1

        if clickCount >= 2 {
            store.openItem(item)
            return
        }

        if store.settings.singleClickToOpen && !flags.contains(.command) && !flags.contains(.shift) {
            store.selectItem(url: item.url)
            store.openItem(item)
            return
        }

        store.selectItem(
            url: item.url,
            extending: flags.contains(.shift),
            toggling: flags.contains(.command)
        )
    }

    static func handleRightClick(item: FileItem, store: ExplorerStore, onFocusCanvas: () -> Void) {
        onFocusCanvas()
        if store.activeTab.selectedURLs.contains(item.url) && store.selectedItems.count > 1 {
            store.showContextMenu(for: .selection(store.selectedItems))
        } else {
            store.selectItem(url: item.url)
            store.showContextMenu(for: .item(item))
        }
    }
}

// MARK: - Fluent Checkbox

struct FluentCheckbox: View {
    let isChecked: Bool
    let onToggle: () -> Void

    @Environment(\.fluentTheme) private var theme

    var body: some View {
        Button(action: onToggle) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isChecked ? theme.palette.accentBlue : theme.palette.cardSurface)
                    .frame(width: 16, height: 16)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(
                                isChecked ? theme.palette.accentBlue : theme.palette.inputBottomStroke,
                                lineWidth: 1.2
                            )
                    )

                if isChecked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
