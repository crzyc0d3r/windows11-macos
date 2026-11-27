import AppKit
import FileExplorerCore
import FileExplorerDesign
import Observation
import SwiftUI

// MARK: - Window Session Coordinator

@MainActor
@Observable
final class ExplorerWindowCoordinator {
    static let shared = ExplorerWindowCoordinator()

    var windows: [WindowSession] = []
    var activeWindowID: UUID?

    struct WindowSession: Identifiable {
        let id: UUID
        let store: ExplorerStore
    }

    var activeStore: ExplorerStore? {
        if let activeWindowID, let match = windows.first(where: { $0.id == activeWindowID }) {
            return match.store
        }
        return windows.first?.store
    }

    func registerPrimaryStoreIfNeeded(_ store: ExplorerStore) -> UUID {
        if let existing = windows.first(where: { $0.store === store }) {
            return existing.id
        }
        let session = WindowSession(id: UUID(), store: store)
        windows.append(session)
        activeWindowID = session.id
        return session.id
    }

    @discardableResult
    func createWindow(initialLocation: ExplorerLocation? = nil, detachedTab: ExplorerTab? = nil) -> WindowSession {
        let store = ExplorerStore()
        if let detachedTab {
            store.tabs = [detachedTab]
            store.activeTabID = detachedTab.id
            store.refresh()
        } else if let initialLocation {
            store.navigate(to: initialLocation)
        }
        let session = WindowSession(id: UUID(), store: store)
        windows.append(session)
        activeWindowID = session.id
        return session
    }

    func openFolderURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if let store = activeStore {
            for (index, url) in urls.enumerated() {
                if index == 0 {
                    store.navigate(to: .folder(url))
                } else {
                    store.newTab(at: .folder(url), activate: true)
                }
            }
        } else {
            _ = createWindow(initialLocation: .folder(urls[0]))
        }
    }

    func closeSession(id: UUID) {
        windows.removeAll { $0.id == id }
        if activeWindowID == id {
            activeWindowID = windows.first?.id
        }
    }
}

final class ExplorerAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        let folderURLs = urls.map { url in
            url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        }
        Task { @MainActor in
            ExplorerWindowCoordinator.shared.openFolderURLs(folderURLs)
        }
    }
}

// MARK: - App Entry Point

@main
struct FileExplorerApp: App {
    @NSApplicationDelegateAdaptor(ExplorerAppDelegate.self) private var appDelegate
    @State private var primaryStore = ExplorerStore()
    @State private var coordinator = ExplorerWindowCoordinator.shared
    @Environment(\.openWindow) private var openWindow

    init() {
        Self.handleCLIIfRequested()
    }

    var body: some Scene {
        WindowGroup(id: "main-explorer") {
            MainExplorerWindowView(
                store: primaryStore,
                onMoveTabToNewWindow: { tab in
                    detachTabToNewWindow(tab, from: primaryStore)
                }
            )
            .onAppear {
                let id = coordinator.registerPrimaryStoreIfNeeded(primaryStore)
                coordinator.activeWindowID = id
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .commands {
            explorerMenuCommands
        }

        WindowGroup(id: "detached-explorer", for: UUID.self) { $sessionID in
            if let sessionID,
               let session = coordinator.windows.first(where: { $0.id == sessionID }) {
                MainExplorerWindowView(
                    store: session.store,
                    onMoveTabToNewWindow: { tab in
                        detachTabToNewWindow(tab, from: session.store)
                    }
                )
                .onAppear {
                    coordinator.activeWindowID = session.id
                }
                .onDisappear {
                    coordinator.closeSession(id: session.id)
                }
            } else {
                Text("Window closed")
                    .frame(width: 320, height: 180)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
    }

    private func detachTabToNewWindow(_ tab: ExplorerTab, from sourceStore: ExplorerStore) {
        if sourceStore.tabs.count > 1 {
            sourceStore.closeTab(id: tab.id)
        }
        let session = coordinator.createWindow(detachedTab: tab)
        openWindow(id: "detached-explorer", value: session.id)
    }

    // MARK: - macOS Menu Bar Commands

    @CommandsBuilder
    private var explorerMenuCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") {
                activeStore.newTab(at: .home, activate: true)
            }
            .keyboardShortcut("t", modifiers: .command)

            Button("New Window") {
                let session = coordinator.createWindow(initialLocation: .home)
                openWindow(id: "detached-explorer", value: session.id)
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("New Folder") {
                activeStore.newFolder()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Divider()

            Button("Close Tab") {
                activeStore.closeTab(id: activeStore.activeTabID)
            }
            .keyboardShortcut("w", modifiers: .command)

            Divider()

            Button("Properties") {
                if let item = activeStore.primarySelectedItem {
                    activeStore.showProperties(for: item.url)
                } else if let folderURL = activeStore.activeTab.location.urlIfFolder {
                    activeStore.showProperties(for: folderURL)
                }
            }
            .keyboardShortcut("i", modifiers: .command)

            Button("Reveal in Finder") {
                if let url = activeStore.primarySelectedItem?.url ?? activeStore.activeTab.location.urlIfFolder {
                    activeStore.revealInFinder(url)
                }
            }
        }

        CommandGroup(replacing: .appSettings) {
            Button("Folder Options & Appearance...") {
                activeStore.openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(replacing: .undoRedo) {
            Button(activeStore.undoDescription.map { "Undo \($0)" } ?? "Undo") {
                activeStore.undo()
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!activeStore.canUndo)

            Button(activeStore.redoDescription.map { "Redo \($0)" } ?? "Redo") {
                activeStore.redo()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!activeStore.canRedo)
        }

        CommandGroup(replacing: .pasteboard) {
            Button("Cut") {
                activeStore.cutSelectedItems()
            }
            .keyboardShortcut("x", modifiers: .command)
            .disabled(activeStore.selectedItems.isEmpty)

            Button("Copy") {
                activeStore.copySelectedItems()
            }
            .keyboardShortcut("c", modifiers: .command)
            .disabled(activeStore.selectedItems.isEmpty)

            Button("Paste") {
                activeStore.pasteIntoCurrentFolder()
            }
            .keyboardShortcut("v", modifiers: .command)
            .disabled(activeStore.clipboardPayload == nil)

            Button("Duplicate") {
                activeStore.duplicateSelectedItems()
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(activeStore.selectedItems.isEmpty)

            Button("Select All") {
                activeStore.selectAll()
            }
            .keyboardShortcut("a", modifiers: .command)

            Divider()

            Button("Move to Trash") {
                activeStore.deleteSelectedItems()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(activeStore.selectedItems.isEmpty)
        }

        CommandMenu("View") {
            ForEach(ViewMode.allCases, id: \.self) { mode in
                Button(mode.displayTitle) {
                    activeStore.setViewMode(mode)
                }
            }

            Divider()

            Button("Toggle Navigation Pane") {
                activeStore.toggleNavigationPane()
            }

            Button("Toggle Details Pane") {
                activeStore.setRightPaneMode(.details)
            }

            Button("Toggle Preview Pane") {
                activeStore.setRightPaneMode(.preview)
            }

            Divider()

            Button("Compact View") {
                activeStore.toggleCompactView()
            }

            Button("Show Hidden Files") {
                activeStore.toggleHiddenFiles()
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])

            Button("Refresh") {
                activeStore.refresh()
            }
            .keyboardShortcut("r", modifiers: .command)
        }

        CommandMenu("Go") {
            Button("Back") {
                activeStore.goBack()
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(!activeStore.activeTab.canGoBack)

            Button("Forward") {
                activeStore.goForward()
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(!activeStore.activeTab.canGoForward)

            Button("Enclosing Folder") {
                activeStore.goUp()
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(!activeStore.activeTab.canGoUp)

            Button("Edit Location") {
                activeStore.beginEditingPath()
            }
            .keyboardShortcut("l", modifiers: .command)

            Divider()

            Button("Home") {
                activeStore.navigate(to: .home)
            }

            Button("This Mac") {
                activeStore.navigate(to: .thisPC)
            }

            Button("Gallery") {
                activeStore.navigate(to: .gallery)
            }

            Button("Trash") {
                activeStore.navigate(to: .recycleBin)
            }
        }
    }

    private var activeStore: ExplorerStore {
        coordinator.activeStore ?? primaryStore
    }

    // MARK: - CLI Modes

    private static func handleCLIIfRequested() {
        let args = Array(CommandLine.arguments.dropFirst())

        if let idx = args.firstIndex(of: "--snapshot-dir") {
            let path = args.indices.contains(idx + 1) ? args[idx + 1] : "./snapshots"
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            do {
                try MainActor.assumeIsolated {
                    try SnapshotRunner.run(outputDirectory: url)
                }
                print("Snapshots generated in \(url.path)")
                exit(0)
            } catch {
                fputs("Snapshot error: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }

        if let idx = args.firstIndex(of: "--generate-icon") {
            guard args.indices.contains(idx + 1) else {
                fputs("Usage: --generate-icon <png-path>\n", stderr)
                exit(1)
            }
            let url = URL(fileURLWithPath: (args[idx + 1] as NSString).expandingTildeInPath)
            do {
                try AppIconRenderer.renderAppIconPNG(to: url, size: 1024)
                print("Generated app icon at \(url.path)")
                exit(0)
            } catch {
                fputs("Icon generation error: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }

        if args.contains("--smoke-test") {
            do {
                try MainActor.assumeIsolated {
                    try runSmokeTest()
                }
                print("Smoke test passed.")
                exit(0)
            } catch {
                fputs("Smoke test failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
    }

    @MainActor
    private static func runSmokeTest() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileExplorerSmoke-\(UUID().uuidString)", isDirectory: true)
        let workspace = tempDir.appendingPathComponent("Workspace", isDirectory: true)
        let persistence = tempDir.appendingPathComponent("Persistence", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: persistence, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ExplorerStore(persistenceDirectory: persistence, settings: .default)
        store.navigate(to: .folder(workspace))
        store.newFolder(named: "SmokeFolder")
        let iconURL = tempDir.appendingPathComponent("icon.png")
        try AppIconRenderer.renderAppIconPNG(to: iconURL, size: 256)
        guard FileManager.default.fileExists(atPath: iconURL.path) else {
            throw NSError(domain: "SmokeTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Icon PNG missing"])
        }
    }
}
