import AppKit
import Foundation
import Testing
@testable import FileExplorerCore

@Suite("ExplorerStore Live Integration, Tabs, Navigation & DirectoryWatcher Tests")
struct ExplorerStoreLiveTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fe-test-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor
    @Test("Tab lifecycle, back/forward/up stacks, and session persistence work")
    func tabLifecycleAndNavigation() async throws {
        let dirA = try makeTempDir()
        let dirB = try makeTempDir()
        let subB = dirB.appendingPathComponent("SubB", isDirectory: true)
        try FileManager.default.createDirectory(at: subB, withIntermediateDirectories: true)
        let persistenceDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
            try? FileManager.default.removeItem(at: persistenceDir)
        }

        var settings = ExplorerSettings.default
        settings.launchTarget = .lastSession
        let pb = NSPasteboard.withUniqueName()
        let store = ExplorerStore(persistenceDirectory: persistenceDir, settings: settings, pasteboard: pb)
        store.updateSettings { $0.launchTarget = .lastSession }

        store.navigate(to: .folder(dirA))
        #expect(store.activeTab.location == .folder(dirA))
        #expect(store.activeTab.canGoBack == true)

        store.navigate(to: .folder(subB))
        #expect(store.activeTab.location == .folder(subB))

        store.goUp()
        #expect(store.activeTab.location == .folder(dirB))

        store.goBack()
        #expect(store.activeTab.location == .folder(subB))
        #expect(store.activeTab.canGoForward == true)

        store.goForward()
        #expect(store.activeTab.location == .folder(dirB))

        let firstTabID = store.activeTabID
        store.newTab(at: .folder(dirA))
        #expect(store.tabs.count == 2)
        let secondTabID = store.activeTabID
        #expect(secondTabID != firstTabID)

        store.duplicateTab(id: secondTabID)
        #expect(store.tabs.count == 3)
        store.moveTab(from: 2, to: 0)
        #expect(store.tabs[0].id == store.activeTabID)

        store.closeOtherTabs(keeping: secondTabID)
        #expect(store.tabs.count == 1)
        #expect(store.activeTabID == secondTabID)

        // Restore session in a fresh ExplorerStore
        let restoredStore = ExplorerStore(persistenceDirectory: persistenceDir, pasteboard: pb)
        #expect(restoredStore.tabs.count == 1)
        #expect(restoredStore.activeTab.location == .folder(dirA))
    }

    @MainActor
    @Test("ExplorerStore interactive conflict resolution resumes suspended copy operation")
    func interactiveConflictResolution() async throws {
        let dir = try makeTempDir()
        let persistenceDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: persistenceDir)
        }

        let src = dir.appendingPathComponent("src", isDirectory: true)
        let dst = dir.appendingPathComponent("dst", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)

        let srcFile = src.appendingPathComponent("hello.txt")
        let dstFile = dst.appendingPathComponent("hello.txt")
        try Data("SRC".utf8).write(to: srcFile)
        try Data("DST".utf8).write(to: dstFile)

        let store = ExplorerStore(persistenceDirectory: persistenceDir, pasteboard: NSPasteboard.withUniqueName())
        store.navigate(to: .folder(dst))
        await store.refreshAsync()

        let copyTask = Task { @MainActor in
            await store.performCopyItems([srcFile], to: dst)
        }

        // Wait briefly for pendingConflict to appear
        for _ in 0..<40 {
            if store.pendingConflict != nil { break }
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(store.pendingConflict?.destinationURL.lastPathComponent == "hello.txt")

        store.resolveConflict(.keepBoth, applyToAll: false)
        let copied = await copyTask.value
        #expect(copied.count == 1)
        #expect(copied[0].lastPathComponent == "hello (2).txt")
        #expect(try String(contentsOf: dstFile, encoding: .utf8) == "DST")
    }

    @MainActor
    @Test("DirectoryWatcher triggers debounced callback when files change")
    func directoryWatcherDebouncedCallback() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let watcher = DirectoryWatcher(debounceInterval: .milliseconds(80))
        var callCount = 0
        watcher.watch(url: dir) {
            callCount += 1
        }

        // Rapidly create two files; debounce should coalesce them
        try Data("1".utf8).write(to: dir.appendingPathComponent("one.txt"))
        try Data("2".utf8).write(to: dir.appendingPathComponent("two.txt"))

        for _ in 0..<30 {
            if callCount > 0 { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        watcher.stop()
        #expect(callCount >= 1)
    }

    @MainActor
    @Test("ExplorerStore clipboard cut+paste moves file and clears cut state")
    func storeClipboardCutPaste() async throws {
        let dir = try makeTempDir()
        let persistenceDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: persistenceDir)
        }

        let src = dir.appendingPathComponent("src", isDirectory: true)
        let dst = dir.appendingPathComponent("dst", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)

        let itemURL = src.appendingPathComponent("moveMe.txt")
        try Data("payload".utf8).write(to: itemURL)

        let store = ExplorerStore(persistenceDirectory: persistenceDir, pasteboard: NSPasteboard.withUniqueName())
        store.cutItems(urls: [itemURL])
        #expect(store.clipboardPayload?.operation == .cut)

        await store.performPaste(into: dst)
        #expect(store.clipboardPayload == nil)
        #expect(!FileManager.default.fileExists(atPath: itemURL.path))
        #expect(FileManager.default.fileExists(atPath: dst.appendingPathComponent("moveMe.txt").path))
    }
}
