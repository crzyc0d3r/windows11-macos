import Foundation
import Testing
@testable import FileExplorerCore

@Suite("FileSystemService Sorting, Grouping & Enumeration Tests")
struct FileSystemAndGroupingTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fe-test-fs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Directory enumeration reads attributes, hidden files, and symlinks")
    func directoryEnumeration() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sub = dir.appendingPathComponent("Subfolder", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        let visibleFile = dir.appendingPathComponent("notes.md")
        try Data("# Hello\n".utf8).write(to: visibleFile)

        let hiddenFile = dir.appendingPathComponent(".secret")
        try Data("hidden".utf8).write(to: hiddenFile)

        let linkURL = dir.appendingPathComponent("notes-link.md")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: visibleFile)

        let service = FileSystemService()

        let withoutHidden = try service.listDirectory(at: dir, includeHidden: false)
        let namesNoHidden = Set(withoutHidden.map(\.name))
        #expect(namesNoHidden.contains("Subfolder"))
        #expect(namesNoHidden.contains("notes.md"))
        #expect(namesNoHidden.contains("notes-link.md"))
        #expect(!namesNoHidden.contains(".secret"))

        let withHidden = try service.listDirectory(at: dir, includeHidden: true)
        #expect(withHidden.contains(where: { $0.name == ".secret" && $0.isHidden }))

        let linkItem = withHidden.first(where: { $0.name == "notes-link.md" })
        #expect(linkItem?.isSymlink == true)
        #expect(linkItem?.kind == .symlink)

        let mdItem = withHidden.first(where: { $0.name == "notes.md" })
        #expect(mdItem?.kind == .markdown)
        #expect(mdItem?.size == 8)

        let folderItem = withHidden.first(where: { $0.name == "Subfolder" })
        #expect(folderItem?.isDirectory == true)
        #expect(folderItem?.kind == .folder)
    }

    @Test("Smart sorting keeps folders first and uses natural numeric ordering")
    func smartSortingFoldersFirstAndNatural() {
        let base = URL(fileURLWithPath: "/tmp/sort-test")
        let now = Date()
        let items: [FileItem] = [
            FileItem(url: base.appendingPathComponent("file10.txt"), kind: .text, isDirectory: false, size: 100, dateModified: now.addingTimeInterval(-10)),
            FileItem(url: base.appendingPathComponent("file2.txt"), kind: .text, isDirectory: false, size: 500, dateModified: now),
            FileItem(url: base.appendingPathComponent("Zebra", isDirectory: true), kind: .folder, isDirectory: true, dateModified: now.addingTimeInterval(-500), typeDescription: "File folder"),
            FileItem(url: base.appendingPathComponent("Alpha", isDirectory: true), kind: .folder, isDirectory: true, dateModified: now.addingTimeInterval(-100), typeDescription: "File folder")
        ]

        let byNameAsc = FileSystemService.sortItems(items, by: .name, order: .ascending)
        #expect(byNameAsc.map(\.name) == ["Alpha", "Zebra", "file2.txt", "file10.txt"])

        let byNameDesc = FileSystemService.sortItems(items, by: .name, order: .descending)
        #expect(byNameDesc.map(\.name) == ["Zebra", "Alpha", "file10.txt", "file2.txt"])

        let bySizeAsc = FileSystemService.sortItems(items, by: .size, order: .ascending)
        #expect(bySizeAsc.map(\.name) == ["Alpha", "Zebra", "file10.txt", "file2.txt"])

        let byDateDesc = FileSystemService.sortItems(items, by: .dateModified, order: .descending)
        #expect(byDateDesc.map(\.name) == ["Alpha", "Zebra", "file2.txt", "file10.txt"])
    }

    @Test("DateModified grouping produces all Windows 11 date buckets in chronological order")
    func dateModifiedGroupingBuckets() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 1 // Sunday
        // Wednesday, Oct 15, 2025 14:00:00
        let refComponents = DateComponents(year: 2025, month: 10, day: 15, hour: 14)
        let referenceDate = calendar.date(from: refComponents)!

        func makeItem(_ name: String, year: Int, month: Int, day: Int) -> FileItem {
            let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 10))!
            return FileItem(
                url: URL(fileURLWithPath: "/tmp/\(name)"),
                kind: .text,
                isDirectory: false,
                dateModified: date
            )
        }

        let items = [
            makeItem("old.txt", year: 2024, month: 5, day: 1),           // A long time ago
            makeItem("year.txt", year: 2025, month: 3, day: 10),         // Earlier this year
            makeItem("lastMonth.txt", year: 2025, month: 9, day: 20),    // Last month
            makeItem("earlierMonth.txt", year: 2025, month: 10, day: 1), // Earlier this month
            makeItem("lastWeek.txt", year: 2025, month: 10, day: 8),     // Last week (Oct 5-11)
            makeItem("earlierWeek.txt", year: 2025, month: 10, day: 13), // Earlier this week (Oct 12+)
            makeItem("yesterday.txt", year: 2025, month: 10, day: 14),   // Yesterday
            makeItem("today.txt", year: 2025, month: 10, day: 15)        // Today
        ]

        let sections = FileSystemService.groupItems(items, by: .dateModified, referenceDate: referenceDate, calendar: calendar)
        #expect(sections.map(\.title) == [
            "Today",
            "Yesterday",
            "Earlier this week",
            "Last week",
            "Earlier this month",
            "Last month",
            "Earlier this year",
            "A long time ago"
        ])
        #expect(sections[0].items.map(\.name) == ["today.txt"])
        #expect(sections[1].items.map(\.name) == ["yesterday.txt"])
        #expect(sections[2].items.map(\.name) == ["earlierWeek.txt"])
        #expect(sections[3].items.map(\.name) == ["lastWeek.txt"])
        #expect(sections[4].items.map(\.name) == ["earlierMonth.txt"])
        #expect(sections[5].items.map(\.name) == ["lastMonth.txt"])
        #expect(sections[6].items.map(\.name) == ["year.txt"])
        #expect(sections[7].items.map(\.name) == ["old.txt"])
    }

    @Test("Size and Name grouping produce Windows 11 buckets")
    func sizeAndNameGroupingBuckets() {
        let base = URL(fileURLWithPath: "/tmp/buckets")
        let items: [FileItem] = [
            FileItem(url: base.appendingPathComponent("Docs", isDirectory: true), kind: .folder, isDirectory: true, size: 0),
            FileItem(url: base.appendingPathComponent("01_empty.txt"), kind: .text, isDirectory: false, size: 0),
            FileItem(url: base.appendingPathComponent("alpha_tiny.txt"), kind: .text, isDirectory: false, size: 1024),
            FileItem(url: base.appendingPathComponent("beta_small.txt"), kind: .text, isDirectory: false, size: 100_000),
            FileItem(url: base.appendingPathComponent("gamma_medium.bin"), kind: .other, isDirectory: false, size: 10_000_000),
            FileItem(url: base.appendingPathComponent("delta_large.iso"), kind: .diskImage, isDirectory: false, size: 200_000_000),
            FileItem(url: base.appendingPathComponent("_huge.dmg"), kind: .diskImage, isDirectory: false, size: 2_000_000_000)
        ]

        let sizeSections = FileSystemService.groupItems(items, by: .size)
        #expect(sizeSections.map(\.title) == [
            "Folders",
            "Empty (0 KB)",
            "Tiny (0-16 KB)",
            "Small (16 KB-1 MB)",
            "Medium (1-128 MB)",
            "Large (128 MB-1 GB)",
            "Huge (>1 GB)"
        ])

        let nameSections = FileSystemService.groupItems(items, by: .name)
        #expect(nameSections.map(\.title) == ["0-9", "A", "B", "D", "G", "#"])
    }

    @Test("Volume discovery returns at least Macintosh HD")
    func volumeDiscovery() {
        let service = FileSystemService()
        let result = service.discoverVolumes()
        #expect(!result.volumes.isEmpty)
        #expect(result.volumes.contains(where: { $0.url.path == "/" }))
    }
}
