import Foundation
import Testing
@testable import FileExplorerCore

@Suite("FileOperationsEngine, Conflict Resolution, Undo/Redo & ZIP Tests")
struct FileOperationsAndUndoTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fe-test-ops-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Create folder and template files with unique naming and rename")
    func createAndRename() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = FileOperationsEngine()

        let folder1 = try await engine.createFolder(in: dir, named: "Projects")
        let folder2 = try await engine.createFolder(in: dir, named: "Projects")
        #expect(folder1.lastPathComponent == "Projects")
        #expect(folder2.lastPathComponent == "Projects (2)")

        let mdFile = try await engine.createFile(in: dir, named: "README", fileExtension: "md")
        let mdContent = try String(contentsOf: mdFile, encoding: .utf8)
        #expect(mdFile.lastPathComponent == "README.md")
        #expect(mdContent.contains("# README"))

        let jsonFile = try await engine.createFile(in: dir, named: "config", fileExtension: "json")
        let jsonContent = try String(contentsOf: jsonFile, encoding: .utf8)
        #expect(jsonContent.contains("{"))

        let shFile = try await engine.createFile(in: dir, named: "build", fileExtension: "sh")
        let shPerms = FileSystemService.readPOSIXPermissions(at: shFile)
        #expect(shPerms?.ownerExecute == true)

        let renamed = try await engine.renameItem(at: folder1, to: "Work")
        #expect(renamed.lastPathComponent == "Work")
        #expect(FileManager.default.fileExists(atPath: renamed.path))
        #expect(!FileManager.default.fileExists(atPath: folder1.path))

        // Case-only rename on APFS
        let caseRenamed = try await engine.renameItem(at: renamed, to: "work")
        #expect(caseRenamed.lastPathComponent == "work")
    }

    @Test("Copy and move honor conflict resolutions: replace, skip, keepBoth, and applyToAll")
    func copyMoveConflictResolution() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let src = dir.appendingPathComponent("src", isDirectory: true)
        let dst = dir.appendingPathComponent("dst", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)

        let engine = FileOperationsEngine()

        let aSrc = src.appendingPathComponent("a.txt")
        let aDst = dst.appendingPathComponent("a.txt")
        try Data("NEW_A".utf8).write(to: aSrc)
        try Data("OLD_A".utf8).write(to: aDst)

        // 1. .skip leaves destination untouched
        _ = try await engine.copyItems(urls: [aSrc], to: dst, onConflict: { _ in (.skip, false) })
        #expect(try String(contentsOf: aDst, encoding: .utf8) == "OLD_A")

        // 2. .keepBoth creates "a (2).txt"
        let kept = try await engine.copyItems(urls: [aSrc], to: dst, onConflict: { _ in (.keepBoth, false) })
        #expect(kept.count == 1)
        #expect(kept[0].lastPathComponent == "a (2).txt")
        #expect(try String(contentsOf: aDst, encoding: .utf8) == "OLD_A")
        #expect(try String(contentsOf: kept[0], encoding: .utf8) == "NEW_A")

        // 3. .replace overwrites destination
        _ = try await engine.copyItems(urls: [aSrc], to: dst, onConflict: { _ in (.replace, false) })
        #expect(try String(contentsOf: aDst, encoding: .utf8) == "NEW_A")

        // 4. applyToAll prompts only once for multiple conflicts
        let bSrc = src.appendingPathComponent("b.txt")
        let bDst = dst.appendingPathComponent("b.txt")
        try Data("NEW_B".utf8).write(to: bSrc)
        try Data("OLD_B".utf8).write(to: bDst)
        try Data("OLD_A_2".utf8).write(to: aDst)

        let promptCounter = PromptCounter()
        let moved = try await engine.moveItems(urls: [aSrc, bSrc], to: dst, onConflict: { _ in
            await promptCounter.increment()
            return (.replace, true)
        })
        #expect(moved.count == 2)
        #expect(await promptCounter.count == 1)
        #expect(try String(contentsOf: aDst, encoding: .utf8) == "NEW_A")
        #expect(try String(contentsOf: bDst, encoding: .utf8) == "NEW_B")
        #expect(!FileManager.default.fileExists(atPath: aSrc.path))
    }

    @Test("ZIP compress and extract via /usr/bin/ditto preserves contents")
    func zipCompressAndExtract() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let folder = dir.appendingPathComponent("Bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("hello zip".utf8).write(to: folder.appendingPathComponent("hello.txt"))

        let engine = FileOperationsEngine()
        let zipURL = try await engine.compressToZIP(urls: [folder])
        #expect(zipURL.pathExtension == "zip")
        #expect(FileManager.default.fileExists(atPath: zipURL.path))

        let extractTarget = dir.appendingPathComponent("Extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extractTarget, withIntermediateDirectories: true)
        let extractedDir = try await engine.extractArchive(at: zipURL, to: extractTarget)

        let extractedFile = extractedDir.appendingPathComponent("Bundle/hello.txt")
        #expect(FileManager.default.fileExists(atPath: extractedFile.path))
        #expect(try String(contentsOf: extractedFile, encoding: .utf8) == "hello zip")
    }

    @MainActor
    @Test("ExplorerStore real-filesystem undo and redo work for rename, move, newFolder, and trash-restore")
    func undoAndRedoLifecycle() async throws {
        let workspace = try makeTempDir()
        let persistenceDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: persistenceDir)
        }

        let store = ExplorerStore(persistenceDirectory: persistenceDir)
        store.navigate(to: .folder(workspace))
        await store.refreshAsync()

        // New folder -> Undo -> Redo
        let createdFolder = await store.performNewFolder(named: "Alpha", beginRename: false)
        #expect(createdFolder != nil)
        #expect(store.canUndo == true)
        #expect(FileManager.default.fileExists(atPath: createdFolder!.path))

        await store.performUndo()
        #expect(!FileManager.default.fileExists(atPath: createdFolder!.path))
        #expect(store.canRedo == true)

        await store.performRedo()
        #expect(FileManager.default.fileExists(atPath: createdFolder!.path))

        // Rename -> Undo -> Redo
        let renamedFolder = await store.performRenameItem(at: createdFolder!, to: "Beta")
        #expect(renamedFolder?.lastPathComponent == "Beta")
        #expect(FileManager.default.fileExists(atPath: renamedFolder!.path))

        await store.performUndo()
        #expect(FileManager.default.fileExists(atPath: createdFolder!.path))
        #expect(!FileManager.default.fileExists(atPath: renamedFolder!.path))

        await store.performRedo()
        #expect(FileManager.default.fileExists(atPath: renamedFolder!.path))

        // Move file -> Undo -> Redo
        let docURL = workspace.appendingPathComponent("doc.txt")
        try Data("data".utf8).write(to: docURL)
        let movedPairs = await store.performMoveItems(urls: [docURL], to: renamedFolder!)
        #expect(movedPairs.count == 1)
        let movedURL = renamedFolder!.appendingPathComponent("doc.txt")
        #expect(FileManager.default.fileExists(atPath: movedURL.path))
        #expect(!FileManager.default.fileExists(atPath: docURL.path))

        await store.performUndo()
        #expect(FileManager.default.fileExists(atPath: docURL.path))
        #expect(!FileManager.default.fileExists(atPath: movedURL.path))

        await store.performRedo()
        #expect(FileManager.default.fileExists(atPath: movedURL.path))

        // Delete to trash -> Undo restores -> Permanent delete cleans up
        await store.performDeleteItems(urls: [movedURL])
        #expect(!FileManager.default.fileExists(atPath: movedURL.path))

        await store.performUndo()
        #expect(FileManager.default.fileExists(atPath: movedURL.path))
    }
}

private actor PromptCounter {
    var count = 0
    func increment() { count += 1 }
}
