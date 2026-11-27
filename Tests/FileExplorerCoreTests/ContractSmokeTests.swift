import Foundation
import Testing
@testable import FileExplorerCore

@Suite("Frozen Contract Smoke Tests")
struct ContractSmokeTests {
    @Test("POSIXPermissions computes octal and symbolic strings")
    func posixPermissionsFormatting() {
        let perms = POSIXPermissions(mode: 0o755)
        #expect(perms.octalString == "755")
        #expect(perms.symbolicString == "rwxr-xr-x")
        #expect(perms.ownerWrite == true)
        #expect(perms.groupWrite == false)
        #expect(perms.othersExecute == true)
    }

    @Test("ExplorerLocation helpers resolve titles, urls, and icons")
    func explorerLocationHelpers() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let docs = home.appendingPathComponent("Documents", isDirectory: true)
        let loc = ExplorerLocation.folder(docs)
        #expect(loc.displayTitle == "Documents")
        #expect(loc.urlIfFolder == docs)
        #expect(loc.iconKind == .documents)

        let searchLoc = ExplorerLocation.search(query: "roadmap", scope: docs, filters: .default)
        #expect(searchLoc.displayTitle == "Search: roadmap")
        #expect(searchLoc.urlIfFolder == docs)
        #expect(searchLoc.iconKind == .search)
    }

    @MainActor
    @Test("ExplorerStore snapshot fixtures, navigation, selection, and file stubs work")
    func explorerStoreInMemoryLifecycle() {
        let store = ExplorerStore.makeSnapshotPreviewStore()
        #expect(store.snapshotMode == true)
        #expect(!store.currentItems.isEmpty)
        #expect(!store.volumes.isEmpty)
        #expect(!store.pinnedFolders.isEmpty)

        let initialCount = store.currentItems.count
        store.newFolder(named: "Contracts Test")
        #expect(store.currentItems.count == initialCount + 1)
        #expect(store.inlineRenamingURL != nil)

        store.cancelInlineRename()
        #expect(store.inlineRenamingURL == nil)

        store.selectAll()
        #expect(store.selectedItems.count == initialCount + 1)

        store.newTab(at: .thisPC)
        #expect(store.tabs.count == 2)
        #expect(store.activeTab.location == .thisPC)

        store.navigate(to: .gallery)
        #expect(store.activeTab.location == .gallery)
        #expect(store.activeTab.canGoBack == true)

        store.goBack()
        #expect(store.activeTab.location == .thisPC)
        #expect(store.activeTab.canGoForward == true)

        store.goForward()
        #expect(store.activeTab.location == .gallery)

        store.setGroupBy(.type)
        #expect(!store.groupedSections.isEmpty)
    }

    @Test("FileMetadata equality and hashing handle exif tuples")
    func fileMetadataHashable() {
        let item = FileItem(
            url: URL(fileURLWithPath: "/tmp/photo.png"),
            kind: .image,
            isDirectory: false,
            size: 2048
        )
        let m1 = FileMetadata(item: item, dimensions: "1920x1080", exifSummary: [("ISO", "100")])
        let m2 = FileMetadata(item: item, dimensions: "1920x1080", exifSummary: [("ISO", "100")])
        #expect(m1 == m2)
        #expect(m1.hashValue == m2.hashValue)
    }
}
