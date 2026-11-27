import Foundation

public enum UndoableAction: Sendable {
    case rename(from: URL, to: URL)
    case move(pairs: [(from: URL, to: URL)])
    case create(urls: [URL])
    case trash(pairs: [(original: URL, trashed: URL)])

    public var actionTitle: String {
        switch self {
        case .rename(_, let to):
            return "Rename \"\(to.lastPathComponent)\""
        case .move(let pairs):
            return pairs.count == 1 ? "Move \"\(pairs[0].to.lastPathComponent)\"" : "Move \(pairs.count) items"
        case .create(let urls):
            return urls.count == 1 ? "Create \"\(urls[0].lastPathComponent)\"" : "Create \(urls.count) items"
        case .trash(let pairs):
            return pairs.count == 1 ? "Delete \"\(pairs[0].original.lastPathComponent)\"" : "Delete \(pairs.count) items"
        }
    }
}

@MainActor
public final class UndoHistoryManager {
    private var undoStack: [UndoableAction] = []
    private var redoStack: [UndoableAction] = []

    public init() {}

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoDescription: String? { undoStack.last?.actionTitle }
    public var redoDescription: String? { redoStack.last?.actionTitle }

    public func record(_ action: UndoableAction) {
        undoStack.append(action)
        redoStack.removeAll()
    }

    public func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    public func popUndo() -> UndoableAction? {
        undoStack.popLast()
    }

    public func pushRedo(_ action: UndoableAction) {
        redoStack.append(action)
    }

    public func popRedo() -> UndoableAction? {
        redoStack.popLast()
    }

    public func pushUndoWithoutClearingRedo(_ action: UndoableAction) {
        undoStack.append(action)
    }
}

public actor FileOperationsEngine {
    public typealias ProgressHandler = @Sendable @MainActor (FileOperationProgress) -> Void
    public typealias ConflictHandler = @Sendable @MainActor (ConflictRequest) async -> (ConflictResolution, Bool)

    private var cancelledOperationIDs = Set<UUID>()

    public init() {}

    public func cancel(operationID: UUID) {
        cancelledOperationIDs.insert(operationID)
    }

    private func isCancelled(_ operationID: UUID) -> Bool {
        cancelledOperationIDs.contains(operationID) || Task.isCancelled
    }

    private func clearCancellation(_ operationID: UUID) {
        cancelledOperationIDs.remove(operationID)
    }

    // MARK: - Basic Creation & Rename

    public func createFolder(in parentURL: URL, named name: String? = nil) throws -> URL {
        let fm = FileManager.default
        let baseName = (name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "New folder"
        let uniqueName = uniqueName(base: baseName, in: parentURL, isFolder: true)
        let targetURL = parentURL.appendingPathComponent(uniqueName, isDirectory: true)
        try fm.createDirectory(at: targetURL, withIntermediateDirectories: false, attributes: nil)
        return targetURL.standardizedFileURL
    }

    public func createFile(in parentURL: URL, named name: String? = nil, fileExtension: String = "txt") throws -> URL {
        let fm = FileManager.default
        let ext = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let defaultStem: String
        switch ext.lowercased() {
        case "md": defaultStem = "New Markdown Document"
        case "json": defaultStem = "New JSON File"
        case "sh": defaultStem = "New Script"
        case "rtf": defaultStem = "New Rich Text Document"
        default: defaultStem = "New Text Document"
        }

        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName: String
        if let trimmedName, !trimmedName.isEmpty {
            if ext.isEmpty || trimmedName.lowercased().hasSuffix(".\(ext.lowercased())") {
                baseName = trimmedName
            } else {
                baseName = "\(trimmedName).\(ext)"
            }
        } else {
            baseName = ext.isEmpty ? defaultStem : "\(defaultStem).\(ext)"
        }

        let uniqueFileName = uniqueName(base: baseName, in: parentURL, isFolder: false)
        let targetURL = parentURL.appendingPathComponent(uniqueFileName, isDirectory: false)
        let templateData = Self.templateData(forExtension: ext, fileName: uniqueFileName)

        let created = fm.createFile(atPath: targetURL.path, contents: templateData, attributes: nil)
        guard created else {
            throw FileSystemError.operationFailed("Could not create \(uniqueFileName).")
        }
        if ext.lowercased() == "sh" {
            try? fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: targetURL.path)
        }
        return targetURL.standardizedFileURL
    }

    public func renameItem(at url: URL, to newName: String) throws -> URL {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            throw FileSystemError.operationFailed("Invalid file name.")
        }
        let source = url.standardizedFileURL
        let destination = source.deletingLastPathComponent().appendingPathComponent(trimmed)
        if source == destination {
            return source
        }
        let fm = FileManager.default
        // Handle case-only rename on case-insensitive APFS via temporary hop
        if source.path.lowercased() == destination.path.lowercased() {
            let tempURL = source.deletingLastPathComponent().appendingPathComponent(".__fe_rename_\(UUID().uuidString)")
            try fm.moveItem(at: source, to: tempURL)
            try fm.moveItem(at: tempURL, to: destination)
        } else {
            if fm.fileExists(atPath: destination.path) {
                throw FileSystemError.operationFailed("An item named \"\(trimmed)\" already exists.")
            }
            try fm.moveItem(at: source, to: destination)
        }
        return destination.standardizedFileURL
    }

    // MARK: - Trash & Delete

    public func moveToTrash(urls: [URL]) throws -> [(original: URL, trashed: URL)] {
        let fm = FileManager.default
        var results: [(original: URL, trashed: URL)] = []
        for url in urls {
            let source = url.standardizedFileURL
            var resultingURL: NSURL?
            try fm.trashItem(at: source, resultingItemURL: &resultingURL)
            if let trashed = resultingURL as URL? {
                results.append((original: source, trashed: trashed.standardizedFileURL))
            }
        }
        return results
    }

    public func restoreFromTrash(pairs: [(trashed: URL, original: URL)]) throws -> [URL] {
        let fm = FileManager.default
        var restored: [URL] = []
        for (trashed, original) in pairs {
            guard fm.fileExists(atPath: trashed.path) else { continue }
            let parent = original.deletingLastPathComponent()
            if !fm.fileExists(atPath: parent.path) {
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            let target: URL
            if fm.fileExists(atPath: original.path) {
                var isDir: ObjCBool = false
                fm.fileExists(atPath: trashed.path, isDirectory: &isDir)
                let unique = uniqueName(base: original.lastPathComponent, in: parent, isFolder: isDir.boolValue)
                target = parent.appendingPathComponent(unique)
            } else {
                target = original
            }
            try fm.moveItem(at: trashed, to: target)
            restored.append(target.standardizedFileURL)
        }
        return restored
    }

    public func permanentDelete(urls: [URL]) throws {
        let fm = FileManager.default
        for url in urls {
            let target = url.standardizedFileURL
            var values = URLResourceValues()
            values.isUserImmutable = false
            var mutableTarget = target
            try? mutableTarget.setResourceValues(values)
            try fm.removeItem(at: target)
        }
    }

    // MARK: - Duplicate, Copy & Move with Progress & Conflict Resolution

    public func duplicateItems(
        urls: [URL],
        operationID: UUID = UUID(),
        onProgress: ProgressHandler? = nil
    ) async throws -> [URL] {
        defer { clearCancellation(operationID) }
        let fm = FileManager.default
        var createdURLs: [URL] = []
        let totalBytes = calculateTotalBytes(for: urls)
        var progress = FileOperationProgress(
            id: operationID,
            title: urls.count == 1 ? "Duplicating \"\(urls[0].lastPathComponent)\"" : "Duplicating \(urls.count) items",
            currentItem: urls.first?.lastPathComponent ?? "",
            completedBytes: 0,
            totalBytes: totalBytes,
            completedItems: 0,
            totalItems: urls.count,
            isCancellable: true
        )
        if let onProgress { await onProgress(progress) }

        for (index, url) in urls.enumerated() {
            if isCancelled(operationID) { throw CancellationError() }
            let source = url.standardizedFileURL
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else { continue }

            let stem = isDir.boolValue ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent
            let ext = isDir.boolValue ? "" : source.pathExtension
            let candidate = ext.isEmpty ? "\(stem) copy" : "\(stem) copy.\(ext)"
            let unique = uniqueName(base: candidate, in: source.deletingLastPathComponent(), isFolder: isDir.boolValue)
            let dest = source.deletingLastPathComponent().appendingPathComponent(unique)

            progress.currentItem = source.lastPathComponent
            if let onProgress { await onProgress(progress) }

            try await copyEntry(
                from: source,
                to: dest,
                operationID: operationID,
                progress: &progress,
                onProgress: onProgress
            )
            createdURLs.append(dest.standardizedFileURL)
            progress.completedItems = index + 1
            if let onProgress { await onProgress(progress) }
        }
        return createdURLs
    }

    public func copyItems(
        urls: [URL],
        to destinationFolder: URL,
        operationID: UUID = UUID(),
        onProgress: ProgressHandler? = nil,
        onConflict: ConflictHandler? = nil
    ) async throws -> [URL] {
        defer { clearCancellation(operationID) }
        let fm = FileManager.default
        let destFolder = destinationFolder.standardizedFileURL
        let totalBytes = calculateTotalBytes(for: urls)
        var progress = FileOperationProgress(
            id: operationID,
            title: urls.count == 1 ? "Copying \"\(urls[0].lastPathComponent)\"" : "Copying \(urls.count) items",
            currentItem: urls.first?.lastPathComponent ?? "",
            completedBytes: 0,
            totalBytes: totalBytes,
            completedItems: 0,
            totalItems: urls.count,
            isCancellable: true
        )
        if let onProgress { await onProgress(progress) }

        var applyAllResolution: ConflictResolution?
        var results: [URL] = []

        for (index, url) in urls.enumerated() {
            if isCancelled(operationID) { throw CancellationError() }
            let source = url.standardizedFileURL
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else { continue }

            var targetURL = destFolder.appendingPathComponent(source.lastPathComponent)
            if source == targetURL {
                let unique = uniqueName(base: source.lastPathComponent, in: destFolder, isFolder: isDir.boolValue)
                targetURL = destFolder.appendingPathComponent(unique)
            } else if fm.fileExists(atPath: targetURL.path) {
                let resolution: ConflictResolution
                if let saved = applyAllResolution {
                    resolution = saved
                } else if let onConflict {
                    let request = ConflictRequest(sourceURL: source, destinationURL: targetURL, isDirectory: isDir.boolValue)
                    let (chosen, applyToAll) = await onConflict(request)
                    if applyToAll { applyAllResolution = chosen }
                    resolution = chosen
                } else {
                    resolution = .keepBoth
                }

                switch resolution {
                case .skip:
                    progress.completedItems = index + 1
                    if let onProgress { await onProgress(progress) }
                    continue
                case .replace:
                    try fm.removeItem(at: targetURL)
                case .keepBoth:
                    let unique = uniqueName(base: targetURL.lastPathComponent, in: destFolder, isFolder: isDir.boolValue)
                    targetURL = destFolder.appendingPathComponent(unique)
                }
            }

            progress.currentItem = source.lastPathComponent
            if let onProgress { await onProgress(progress) }

            try await copyEntry(
                from: source,
                to: targetURL,
                operationID: operationID,
                progress: &progress,
                onProgress: onProgress
            )
            results.append(targetURL.standardizedFileURL)
            progress.completedItems = index + 1
            if let onProgress { await onProgress(progress) }
        }
        return results
    }

    public func moveItems(
        urls: [URL],
        to destinationFolder: URL,
        operationID: UUID = UUID(),
        onProgress: ProgressHandler? = nil,
        onConflict: ConflictHandler? = nil
    ) async throws -> [(from: URL, to: URL)] {
        defer { clearCancellation(operationID) }
        let fm = FileManager.default
        let destFolder = destinationFolder.standardizedFileURL
        let totalBytes = calculateTotalBytes(for: urls)
        var progress = FileOperationProgress(
            id: operationID,
            title: urls.count == 1 ? "Moving \"\(urls[0].lastPathComponent)\"" : "Moving \(urls.count) items",
            currentItem: urls.first?.lastPathComponent ?? "",
            completedBytes: 0,
            totalBytes: totalBytes,
            completedItems: 0,
            totalItems: urls.count,
            isCancellable: true
        )
        if let onProgress { await onProgress(progress) }

        var applyAllResolution: ConflictResolution?
        var movedPairs: [(from: URL, to: URL)] = []

        for (index, url) in urls.enumerated() {
            if isCancelled(operationID) { throw CancellationError() }
            let source = url.standardizedFileURL
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else { continue }

            // Prevent moving a folder into itself
            if isDir.boolValue && (destFolder == source || destFolder.path.hasPrefix(source.path + "/")) {
                throw FileSystemError.operationFailed("Cannot move \"\(source.lastPathComponent)\" into itself.")
            }

            var targetURL = destFolder.appendingPathComponent(source.lastPathComponent)
            if source == targetURL {
                progress.completedItems = index + 1
                if let onProgress { await onProgress(progress) }
                continue
            }

            if fm.fileExists(atPath: targetURL.path) {
                let resolution: ConflictResolution
                if let saved = applyAllResolution {
                    resolution = saved
                } else if let onConflict {
                    let request = ConflictRequest(sourceURL: source, destinationURL: targetURL, isDirectory: isDir.boolValue)
                    let (chosen, applyToAll) = await onConflict(request)
                    if applyToAll { applyAllResolution = chosen }
                    resolution = chosen
                } else {
                    resolution = .keepBoth
                }

                switch resolution {
                case .skip:
                    progress.completedItems = index + 1
                    if let onProgress { await onProgress(progress) }
                    continue
                case .replace:
                    try fm.removeItem(at: targetURL)
                case .keepBoth:
                    let unique = uniqueName(base: targetURL.lastPathComponent, in: destFolder, isFolder: isDir.boolValue)
                    targetURL = destFolder.appendingPathComponent(unique)
                }
            }

            progress.currentItem = source.lastPathComponent
            if let onProgress { await onProgress(progress) }

            let itemBytes = calculateTotalBytes(for: [source])
            do {
                try fm.moveItem(at: source, to: targetURL)
                progress.completedBytes += itemBytes
            } catch {
                // Cross-volume move fallback: copy then delete source
                try await copyEntry(
                    from: source,
                    to: targetURL,
                    operationID: operationID,
                    progress: &progress,
                    onProgress: onProgress
                )
                try fm.removeItem(at: source)
            }
            movedPairs.append((from: source, to: targetURL.standardizedFileURL))
            progress.completedItems = index + 1
            if let onProgress { await onProgress(progress) }
        }

        return movedPairs
    }

    // MARK: - ZIP Compression & Extraction via /usr/bin/ditto

    public func compressToZIP(urls: [URL], archiveName: String? = nil) async throws -> URL {
        guard let first = urls.first else {
            throw FileSystemError.operationFailed("No items selected to compress.")
        }
        let parentDir = first.standardizedFileURL.deletingLastPathComponent()
        let baseName: String
        if let archiveName, !archiveName.isEmpty {
            baseName = archiveName.hasSuffix(".zip") ? archiveName : "\(archiveName).zip"
        } else if urls.count == 1 {
            let stem = first.deletingPathExtension().lastPathComponent
            baseName = "\(stem).zip"
        } else {
            baseName = "Archive.zip"
        }

        let uniqueZipName = uniqueName(base: baseName, in: parentDir, isFolder: false)
        let zipURL = parentDir.appendingPathComponent(uniqueZipName)

        if urls.count == 1 {
            try await runProcess(
                executable: "/usr/bin/ditto",
                arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, zipURL.path]
            )
        } else {
            let fm = FileManager.default
            let stagingDir = fm.temporaryDirectory.appendingPathComponent("fe-zip-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: stagingDir) }

            for url in urls {
                let dest = stagingDir.appendingPathComponent(url.lastPathComponent)
                try fm.copyItem(at: url, to: dest)
            }
            try await runProcess(
                executable: "/usr/bin/ditto",
                arguments: ["-c", "-k", "--sequesterRsrc", stagingDir.path, zipURL.path]
            )
        }
        return zipURL.standardizedFileURL
    }

    public func extractArchive(at archiveURL: URL, to destinationFolder: URL? = nil) async throws -> URL {
        let source = archiveURL.standardizedFileURL
        let parentDir = destinationFolder?.standardizedFileURL ?? source.deletingLastPathComponent()
        let baseFolderName = source.deletingPathExtension().lastPathComponent
        let uniqueFolder = uniqueName(base: baseFolderName, in: parentDir, isFolder: true)
        let extractDir = parentDir.appendingPathComponent(uniqueFolder, isDirectory: true)

        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        try await runProcess(
            executable: "/usr/bin/ditto",
            arguments: ["-x", "-k", source.path, extractDir.path]
        )
        return extractDir.standardizedFileURL
    }

    // MARK: - Internal Helpers

    private func copyEntry(
        from source: URL,
        to destination: URL,
        operationID: UUID,
        progress: inout FileOperationProgress,
        onProgress: ProgressHandler?
    ) async throws {
        if isCancelled(operationID) { throw CancellationError() }
        let fm = FileManager.default
        let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])

        if values?.isSymbolicLink == true {
            let targetPath = try fm.destinationOfSymbolicLink(atPath: source.path)
            try fm.createSymbolicLink(atPath: destination.path, withDestinationPath: targetPath)
            return
        }

        if values?.isDirectory == true {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true, attributes: nil)
            let children = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [])
            for child in children {
                let childDest = destination.appendingPathComponent(child.lastPathComponent)
                try await copyEntry(
                    from: child,
                    to: childDest,
                    operationID: operationID,
                    progress: &progress,
                    onProgress: onProgress
                )
            }
            if let attrs = try? fm.attributesOfItem(atPath: source.path) {
                var filtered: [FileAttributeKey: Any] = [:]
                if let posix = attrs[.posixPermissions] { filtered[.posixPermissions] = posix }
                if let modDate = attrs[.modificationDate] { filtered[.modificationDate] = modDate }
                try? fm.setAttributes(filtered, ofItemAtPath: destination.path)
            }
            return
        }

        try await copyFileWithProgress(
            from: source,
            to: destination,
            operationID: operationID,
            progress: &progress,
            onProgress: onProgress
        )
    }

    private func copyFileWithProgress(
        from source: URL,
        to destination: URL,
        operationID: UUID,
        progress: inout FileOperationProgress,
        onProgress: ProgressHandler?
    ) async throws {
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: source.path)
        let fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

        // Fast copy for small files (< 1 MB)
        if fileSize < 1_048_576 {
            try fm.copyItem(at: source, to: destination)
            progress.completedBytes += fileSize
            if let onProgress { await onProgress(progress) }
            return
        }

        let chunkSize = 512 * 1024
        guard let reader = try? FileHandle(forReadingFrom: source) else {
            try fm.copyItem(at: source, to: destination)
            progress.completedBytes += fileSize
            return
        }
        defer { try? reader.close() }

        guard fm.createFile(atPath: destination.path, contents: nil, attributes: nil),
              let writer = try? FileHandle(forWritingTo: destination) else {
            throw FileSystemError.operationFailed("Unable to write \(destination.lastPathComponent).")
        }

        var completedNormally = false
        defer {
            try? writer.close()
            if !completedNormally {
                try? fm.removeItem(at: destination)
            }
        }

        while true {
            if isCancelled(operationID) {
                throw CancellationError()
            }
            let data = try reader.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty { break }
            try writer.write(contentsOf: data)
            progress.completedBytes += Int64(data.count)
            if let onProgress { await onProgress(progress) }
            await Task.yield()
        }

        completedNormally = true
        if let attrs {
            var copyAttrs: [FileAttributeKey: Any] = [:]
            if let posix = attrs[.posixPermissions] { copyAttrs[.posixPermissions] = posix }
            if let modDate = attrs[.modificationDate] { copyAttrs[.modificationDate] = modDate }
            if let creationDate = attrs[.creationDate] { copyAttrs[.creationDate] = creationDate }
            try? fm.setAttributes(copyAttrs, ofItemAtPath: destination.path)
        }
    }

    private func calculateTotalBytes(for urls: [URL]) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                let vals = try? url.resourceValues(forKeys: [.fileSizeKey])
                total += Int64(vals?.fileSize ?? 0)
            } else if let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [],
                errorHandler: { _, _ in true }
            ) {
                for case let child as URL in enumerator {
                    let vals = try? child.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    if vals?.isRegularFile == true {
                        total += Int64(vals?.fileSize ?? 0)
                    }
                }
            }
        }
        return total
    }

    public func uniqueName(base: String, in directory: URL, isFolder: Bool) -> String {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.appendingPathComponent(base).path) {
            return base
        }

        let stem: String
        let ext: String
        if isFolder || !base.contains(".") {
            stem = base
            ext = ""
        } else {
            let temp = URL(fileURLWithPath: base)
            stem = temp.deletingPathExtension().lastPathComponent
            ext = temp.pathExtension
        }

        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            if !fm.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
                return candidate
            }
            counter += 1
        }
    }

    private static func templateData(forExtension ext: String, fileName: String) -> Data {
        let content: String
        switch ext.lowercased() {
        case "md":
            let title = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
            content = "# \(title)\n\n"
        case "json":
            content = "{\n  \n}\n"
        case "sh":
            content = "#!/usr/bin/env bash\nset -euo pipefail\n\n"
        case "rtf":
            content = "{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Helvetica;}}\\f0\\fs24 }\n"
        default:
            content = ""
        }
        return Data(content.utf8)
    }

    private func runProcess(executable: String, arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            let stderrPipe = Pipe()
            process.standardError = stderrPipe

            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(
                        throwing: FileSystemError.operationFailed(
                            msg?.isEmpty == false ? msg! : "Process exited with status \(proc.terminationStatus)."
                        )
                    )
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
