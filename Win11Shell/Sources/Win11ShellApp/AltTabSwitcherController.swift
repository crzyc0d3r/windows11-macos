import AppKit
import CoreGraphics
import Observation
import SwiftUI
import Win11ShellCore

public struct AltTabWindowItem: Identifiable, @unchecked Sendable {
    public var id: String { "\(info.pid)-\(info.windowID)-\(fallbackIndex)" }
    public let fallbackIndex: Int
    public let bundleID: String
    public let appName: String
    public let appIcon: NSImage
    public let info: AXWindowInfo
    public var thumbnail: NSImage?
}

@MainActor
@Observable
public final class AltTabSwitcherState {
    public var items: [AltTabWindowItem] = []
    public var selectedIndex: Int = 0
}

@MainActor
public final class AltTabSwitcherController {
    private static let excludedBundleIDs: Set<String> = [
        "com.apple.finder",
        "com.hackedple.win11shell"
    ]

    private let model: RunningAppsModel
    private let state = AltTabSwitcherState()
    private var panel: NonActivatingFloatingPanel?
    private var thumbnailTask: Task<Void, Never>?
    private var activeSessionID = UUID()

    public private(set) var isVisible: Bool = false

    public init(model: RunningAppsModel) {
        self.model = model
    }

    public func step(reverse: Bool) {
        if !isVisible {
            let mruItems = collectMRUWindows()
            guard !mruItems.isEmpty else { return }

            state.items = mruItems
            if mruItems.count > 1 {
                state.selectedIndex = reverse ? (mruItems.count - 1) : 1
            } else {
                state.selectedIndex = 0
            }

            isVisible = true
            presentPanel()
            startThumbnailLoads()
            return
        }

        let count = state.items.count
        guard count > 0 else {
            cancel()
            return
        }
        if reverse {
            state.selectedIndex = (state.selectedIndex - 1 + count) % count
        } else {
            state.selectedIndex = (state.selectedIndex + 1) % count
        }
    }

    public func commitSelection() {
        guard isVisible else { return }
        let items = state.items
        let idx = state.selectedIndex
        cancel()
        if items.indices.contains(idx) {
            AccessibilityBridge.focusWindow(items[idx].info)
        }
    }

    public func cancel() {
        thumbnailTask?.cancel()
        thumbnailTask = nil
        activeSessionID = UUID()
        isVisible = false
        panel?.orderOut(nil)
        state.items = []
        state.selectedIndex = 0
    }

    private func focusItem(_ item: AltTabWindowItem) {
        cancel()
        AccessibilityBridge.focusWindow(item.info)
    }

    private func closeItem(_ item: AltTabWindowItem) {
        AccessibilityBridge.pressCloseButton(item.info.element)
        guard let idx = state.items.firstIndex(where: { $0.id == item.id }) else { return }
        state.items.remove(at: idx)
        if state.items.isEmpty {
            cancel()
            return
        }
        if state.selectedIndex >= state.items.count {
            state.selectedIndex = state.items.count - 1
        }
        layoutAndCenterPanel()
    }

    private func collectMRUWindows() -> [AltTabWindowItem] {
        let regularApps = NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular
                && app.bundleIdentifier.map { !Self.excludedBundleIDs.contains($0) } ?? false
        }

        var appsByPID: [pid_t: NSRunningApplication] = [:]
        var axWindowsByPID: [pid_t: [AXWindowInfo]] = [:]
        for app in regularApps {
            let pid = app.processIdentifier
            appsByPID[pid] = app
            axWindowsByPID[pid] = AccessibilityBridge.standardWindows(for: pid)
        }

        var items: [AltTabWindowItem] = []
        var usedAXIndices: [pid_t: Set<Int>] = [:]
        var fallbackCounter = 0

        // Enumerate on-screen windows in front-to-back MRU Z-order first.
        if let cgList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for entry in cgList {
                let layer = (entry[kCGWindowLayer as String] as? Int) ?? -1
                guard layer == 0,
                      let pidNum = entry[kCGWindowOwnerPID as String] as? NSNumber,
                      let app = appsByPID[pid_t(pidNum.int32Value)],
                      let axList = axWindowsByPID[app.processIdentifier]
                else {
                    continue
                }

                let pid = app.processIdentifier
                let wid = CGWindowID((entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
                let cgTitle = (entry[kCGWindowName as String] as? String) ?? ""

                var matchedIdx: Int?
                if wid != 0 {
                    matchedIdx = axList.enumerated().first { idx, info in
                        !(usedAXIndices[pid]?.contains(idx) ?? false) && info.windowID == wid
                    }?.offset
                }
                if matchedIdx == nil && !cgTitle.isEmpty {
                    matchedIdx = axList.enumerated().first { idx, info in
                        !(usedAXIndices[pid]?.contains(idx) ?? false) && info.title == cgTitle
                    }?.offset
                }

                guard let idx = matchedIdx else { continue }
                usedAXIndices[pid, default: []].insert(idx)

                let bundleID = app.bundleIdentifier ?? ""
                items.append(AltTabWindowItem(
                    fallbackIndex: fallbackCounter,
                    bundleID: bundleID,
                    appName: app.localizedName ?? bundleID,
                    appIcon: AppIconCache.icon(forBundleID: bundleID, url: app.bundleURL, size: 48),
                    info: axList[idx],
                    thumbnail: nil
                ))
                fallbackCounter += 1
            }
        }

        // Append remaining minimized/hidden/off-space windows sorted with frontmost app first.
        let frontPID = model.frontmostPID
        let orderedPIDs = regularApps
            .map(\.processIdentifier)
            .sorted { a, b in
                if a == frontPID { return true }
                if b == frontPID { return false }
                return a < b
            }

        for pid in orderedPIDs {
            guard let app = appsByPID[pid], let axList = axWindowsByPID[pid] else { continue }
            let bundleID = app.bundleIdentifier ?? ""
            let icon = AppIconCache.icon(forBundleID: bundleID, url: app.bundleURL, size: 48)
            for (idx, info) in axList.enumerated() {
                if usedAXIndices[pid]?.contains(idx) == true { continue }
                items.append(AltTabWindowItem(
                    fallbackIndex: fallbackCounter,
                    bundleID: bundleID,
                    appName: app.localizedName ?? bundleID,
                    appIcon: icon,
                    info: info,
                    thumbnail: nil
                ))
                fallbackCounter += 1
            }
        }

        return items
    }

    private func startThumbnailLoads() {
        thumbnailTask?.cancel()
        let session = UUID()
        activeSessionID = session
        let snapshot = state.items

        thumbnailTask = Task { @MainActor [weak self] in
            for item in snapshot {
                if Task.isCancelled { return }
                guard item.info.windowID != 0 else { continue }
                let thumb = await AccessibilityBridge.captureWindowThumbnail(windowID: item.info.windowID)
                guard let self, self.isVisible, self.activeSessionID == session, !Task.isCancelled else {
                    return
                }
                if let thumb, let idx = self.state.items.firstIndex(where: { $0.id == item.id }) {
                    self.state.items[idx].thumbnail = thumb
                }
            }
        }
    }

    private func presentPanel() {
        if panel == nil {
            let p = NonActivatingFloatingPanel(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 220),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.level = .popUpMenu
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.contentView = NSHostingView(rootView: AltTabSwitcherView(
                state: state,
                onSelectCard: { [weak self] item in
                    self?.focusItem(item)
                },
                onCloseCard: { [weak self] item in
                    self?.closeItem(item)
                }
            ))
            panel = p
        }

        layoutAndCenterPanel()
        panel?.orderFrontRegardless()
    }

    private func layoutAndCenterPanel() {
        guard let panel else { return }
        let count = max(1, state.items.count)
        let columns = min(count, 5)
        let rows = min(3, Int(ceil(Double(count) / Double(columns))))

        let cardWidth: CGFloat = 204
        let cardHeight: CGFloat = 152
        let spacing: CGFloat = 12
        let padding: CGFloat = 18

        let width = CGFloat(columns) * cardWidth + CGFloat(max(0, columns - 1)) * spacing + padding * 2
        let height = CGFloat(rows) * cardHeight + CGFloat(max(0, rows - 1)) * spacing + padding * 2 + 24

        panel.setContentSize(NSSize(width: width, height: height))

        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1512, height: 982)
        let origin = NSPoint(
            x: screenFrame.midX - (width / 2),
            y: screenFrame.midY - (height / 2)
        )
        panel.setFrameOrigin(origin)
    }
}

private struct AltTabSwitcherView: View {
    let state: AltTabSwitcherState
    let onSelectCard: (AltTabWindowItem) -> Void
    let onCloseCard: (AltTabWindowItem) -> Void

    private let columns = Array(repeating: GridItem(.fixed(204), spacing: 12), count: 5)

    var body: some View {
        let displayColumns = min(max(1, state.items.count), 5)
        let gridCols = Array(repeating: GridItem(.fixed(204), spacing: 12), count: displayColumns)

        VStack(spacing: 8) {
            ScrollView {
                LazyVGrid(columns: gridCols, spacing: 12) {
                    ForEach(Array(state.items.enumerated()), id: \.element.id) { index, item in
                        AltTabCardView(
                            item: item,
                            isSelected: index == state.selectedIndex,
                            onSelect: { onSelectCard(item) },
                            onClose: { onCloseCard(item) }
                        )
                    }
                }
            }
            .scrollIndicators(.hidden)

            if state.items.indices.contains(state.selectedIndex) {
                let active = state.items[state.selectedIndex]
                Text("\(active.appName) — \(active.info.title.isEmpty ? active.appName : active.info.title)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(18)
        .background(
            ZStack {
                AcrylicBackground(material: .hudWindow, blendingMode: .behindWindow)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.22))
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            )
        )
    }
}

private struct AltTabCardView: View {
    let item: AltTabWindowItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false
    @State private var isCloseHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(nsImage: item.appIcon)
                    .resizable()
                    .frame(width: 14, height: 14)

                Text(item.info.title.isEmpty ? item.appName : item.info.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)

                Spacer(minLength: 4)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(
                            Circle().fill(
                                isCloseHovered
                                    ? Color(red: 0.77, green: 0.17, blue: 0.11)
                                    : Color.primary.opacity(0.14)
                            )
                        )
                        .foregroundStyle(isCloseHovered ? .white : .primary)
                }
                .buttonStyle(.plain)
                .opacity((isHovered || isSelected) ? 1.0 : 0.7)
                .onHover { isCloseHovered = $0 }
            }

            Button(action: onSelect) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.black.opacity(0.28))

                    if let thumb = item.thumbnail {
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    } else {
                        Image(nsImage: item.appIcon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 48, height: 48)
                    }
                }
                .frame(width: 188, height: 108)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .frame(width: 204, height: 152)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    isSelected
                        ? Color.white.opacity(0.16)
                        : (isHovered ? Color.white.opacity(0.09) : Color.white.opacity(0.04))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isSelected
                        ? Color(red: 0.30, green: 0.72, blue: 0.99)
                        : Color.white.opacity(isHovered ? 0.22 : 0.08),
                    lineWidth: isSelected ? 2.5 : 1
                )
        )
        .onHover { isHovered = $0 }
    }
}
