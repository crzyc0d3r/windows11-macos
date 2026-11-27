import AppKit
import Observation
import SwiftUI
import Win11ShellCore

@MainActor
@Observable
public final class StartMenuState {
    public var searchQuery: String = ""
    public var showAllApps: Bool = false
    public var showPowerMenu: Bool = false
    public var focusSearchToken: Int = 0
}

@MainActor
public final class StartMenuController {
    private let model: RunningAppsModel
    private let system: SystemControlsBridge
    private let state = StartMenuState()
    private var panel: FocusableFloatingPanel?
    private var outsideMonitor: Any?

    public var isVisible: Bool {
        panel?.isVisible ?? false
    }

    public init(model: RunningAppsModel, system: SystemControlsBridge) {
        self.model = model
        self.system = system
    }

    public func toggle(focusSearch: Bool = false, on screen: NSScreen? = nil) {
        if let panel, panel.isVisible {
            if focusSearch {
                state.focusSearchToken += 1
                return
            }
            dismiss()
        } else {
            show(focusSearch: focusSearch, on: screen)
        }
    }

    public func show(focusSearch: Bool = false, on screen: NSScreen? = nil) {
        model.refreshInstalledApps()
        model.refreshRecentFiles()
        state.searchQuery = ""
        state.showAllApps = false
        state.showPowerMenu = false
        if focusSearch {
            state.focusSearchToken += 1
        }

        if panel == nil {
            let p = FocusableFloatingPanel(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 660),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            p.level = .popUpMenu
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.contentView = NSHostingView(rootView: StartMenuView(
                model: model,
                system: system,
                state: state,
                onDismiss: { [weak self] in
                    self?.dismiss()
                }
            ))
            panel = p
        }

        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first
        if let targetScreen, let panel {
            let frame = targetScreen.frame
            let x: CGFloat
            if model.config.taskbarAlignment == .left {
                x = frame.minX + 12
            } else {
                x = frame.midX - (panel.frame.width / 2)
            }
            let y = frame.minY + CGFloat(model.config.taskbarHeight) + 12
            panel.setFrameOrigin(NSPoint(x: max(frame.minX + 8, min(x, frame.maxX - panel.frame.width - 8)), y: y))
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: false)
        }

        installOutsideClickMonitor()
    }

    public func dismiss() {
        panel?.orderOut(nil)
        removeOutsideClickMonitor()
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                let loc = NSEvent.mouseLocation
                if !panel.frame.contains(loc) {
                    self.dismiss()
                }
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideMonitor {
            NSEvent.removeMonitor(outsideMonitor)
            self.outsideMonitor = nil
        }
    }
}

private struct StartMenuView: View {
    let model: RunningAppsModel
    let system: SystemControlsBridge
    @Bindable var state: StartMenuState
    let onDismiss: () -> Void
    @FocusState private var searchFocused: Bool

    private var filteredApps: [InstalledAppEntry] {
        AppCatalog.filterApps(model.installedApps, query: state.searchQuery, hideFinder: true)
    }

    private var pinnedEntries: [InstalledAppEntry] {
        model.config.pinnedBundleIDs.compactMap { bid in
            if let found = model.installedApps.first(where: { $0.bundleID == bid }) {
                return found
            }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                return InstalledAppEntry(
                    bundleID: bid,
                    name: url.deletingPathExtension().lastPathComponent,
                    url: url
                )
            }
            return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search Box
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search for apps, settings, and files", text: $state.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .focused($searchFocused)
                    .onSubmit {
                        if let first = filteredApps.first {
                            model.launchApp(entry: first)
                            onDismiss()
                        }
                    }
                if !state.searchQuery.isEmpty {
                    Button {
                        state.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 26)
            .padding(.top, 24)
            .padding(.bottom, 18)

            if !state.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                searchResultsSection
            } else if state.showAllApps {
                allAppsSection
            } else {
                pinnedAndRecommendedSection
            }

            Spacer(minLength: 0)

            // Footer Bar
            HStack {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.25))
                            .frame(width: 30, height: 30)
                        Text(String(NSFullUserName().prefix(1)).uppercased())
                            .font(.system(size: 13, weight: .semibold))
                    }
                    Text(NSFullUserName())
                        .font(.system(size: 12.5, weight: .medium))
                }

                Spacer()

                Button {
                    state.showPowerMenu.toggle()
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 34, height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(state.showPowerMenu ? 0.14 : 0.06))
                        )
                }
                .buttonStyle(.plain)
                .popover(isPresented: $state.showPowerMenu, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        PowerActionRow(title: "Lock", symbol: "lock") { onDismiss(); system.lockScreen() }
                        PowerActionRow(title: "Sleep", symbol: "moon") { onDismiss(); system.sleepSystem() }
                        PowerActionRow(title: "Restart", symbol: "arrow.clockwise") { onDismiss(); system.restartSystem() }
                        PowerActionRow(title: "Shut down", symbol: "power") { onDismiss(); system.shutDownSystem() }
                        Divider()
                        PowerActionRow(title: "Sign out", symbol: "rectangle.portrait.and.arrow.right") { onDismiss(); system.signOutUser() }
                    }
                    .padding(8)
                    .frame(width: 170)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .background(Color.black.opacity(0.16))
        }
        .frame(width: 640, height: 660)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThickMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                )
        )
        .onAppear {
            searchFocused = true
        }
        .onChange(of: state.focusSearchToken) { _, _ in
            searchFocused = true
        }
        .onExitCommand {
            onDismiss()
        }
    }

    private var pinnedAndRecommendedSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Pinned")
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer()
                Button {
                    state.showAllApps = true
                } label: {
                    HStack(spacing: 4) {
                        Text("All apps")
                            .font(.system(size: 11.5, weight: .medium))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 30)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 14) {
                ForEach(pinnedEntries) { app in
                    StartAppTile(app: app, isPinned: true, onLaunch: {
                        model.launchApp(entry: app)
                        onDismiss()
                    }, onTogglePin: {
                        model.togglePin(bundleID: app.bundleID)
                    })
                }
            }
            .padding(.horizontal, 26)

            Divider().padding(.horizontal, 26).padding(.vertical, 4)

            HStack {
                Text("Recommended")
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer()
                Button("Open Explorer") {
                    model.launchOrActivate(bundleID: model.config.fileExplorerBundleID)
                    onDismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 30)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(model.recentFiles.prefix(6)) { file in
                    Button {
                        NSWorkspace.shared.open(file.url)
                        onDismiss()
                    } label: {
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                                .resizable()
                                .frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                Text(file.folderName)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 26)
        }
    }

    private var allAppsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("All apps")
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer()
                Button {
                    state.showAllApps = false
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Back")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 30)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(filteredApps) { app in
                        StartAppListRow(
                            app: app,
                            isPinned: model.isPinned(app.bundleID),
                            onLaunch: {
                                model.launchApp(entry: app)
                                onDismiss()
                            },
                            onTogglePin: {
                                model.togglePin(bundleID: app.bundleID)
                            }
                        )
                    }
                }
                .padding(.horizontal, 26)
            }
        }
    }

    private var searchResultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Best match")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 30)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(filteredApps.prefix(15)) { app in
                        StartAppListRow(
                            app: app,
                            isPinned: model.isPinned(app.bundleID),
                            onLaunch: {
                                model.launchApp(entry: app)
                                onDismiss()
                            },
                            onTogglePin: {
                                model.togglePin(bundleID: app.bundleID)
                            }
                        )
                    }
                    if filteredApps.isEmpty {
                        Text("No matching apps found")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(.top, 20)
                            .padding(.horizontal, 8)
                    }
                }
                .padding(.horizontal, 26)
            }
        }
    }
}

private struct StartAppTile: View {
    let app: InstalledAppEntry
    let isPinned: Bool
    let onLaunch: () -> Void
    let onTogglePin: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onLaunch) {
            VStack(spacing: 6) {
                Image(nsImage: AppIconCache.icon(forBundleID: app.bundleID, url: app.url, size: 36))
                    .resizable()
                    .frame(width: 34, height: 34)
                Text(app.name)
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(height: 28, alignment: .top)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovered ? Color.primary.opacity(0.10) : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Open", action: onLaunch)
            Button(isPinned ? "Unpin from Start" : "Pin to Start", action: onTogglePin)
        }
    }
}

private struct StartAppListRow: View {
    let app: InstalledAppEntry
    let isPinned: Bool
    let onLaunch: () -> Void
    let onTogglePin: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onLaunch) {
            HStack(spacing: 12) {
                Image(nsImage: AppIconCache.icon(forBundleID: app.bundleID, url: app.url, size: 24))
                    .resizable()
                    .frame(width: 24, height: 24)
                Text(app.name)
                    .font(.system(size: 13))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovered ? Color.primary.opacity(0.10) : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Open", action: onLaunch)
            Button(isPinned ? "Unpin from Taskbar & Start" : "Pin to Taskbar & Start", action: onTogglePin)
        }
    }
}

private struct PowerActionRow: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12.5))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(hovered ? Color.primary.opacity(0.10) : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
