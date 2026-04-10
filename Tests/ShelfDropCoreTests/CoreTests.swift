import Foundation
import ShelfDropCore
import Testing

@Test("exact duplicates are grouped by hash")
func duplicateDetectionFindsIdenticalFiles() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let a = directory.appendingPathComponent("a.txt")
    let b = directory.appendingPathComponent("b.txt")
    let c = directory.appendingPathComponent("c.txt")
    try Data("same".utf8).write(to: a)
    try Data("same".utf8).write(to: b)
    try Data("other".utf8).write(to: c)

    let catalog = FileCatalogService()
    let items = catalog.makeShelfItems(urls: [a, b, c])
    let service = DuplicateDetectionService()

    let groups = service.findExactDuplicates(in: items)
    #expect(groups.count == 1)
    #expect(groups.first?.itemIDs.count == 2)
}

@Test("duplicate scan warns when candidate files cannot be read")
func duplicateDetectionSurfacesHashFailures() {
    let missingA = ShelfItem(
        url: URL(fileURLWithPath: "/tmp/missing-a.bin"),
        displayName: "missing-a.bin",
        fileExtension: "bin",
        kindDescription: "Binary",
        byteSize: 32,
        createdAt: nil,
        modifiedAt: nil,
        isDirectory: false,
        isPackage: false,
        isAlias: false,
        isUbiquitous: false,
        isExternalVolume: false,
        isLocked: false,
        isReachable: true,
        tags: []
    )
    let missingB = ShelfItem(
        url: URL(fileURLWithPath: "/tmp/missing-b.bin"),
        displayName: "missing-b.bin",
        fileExtension: "bin",
        kindDescription: "Binary",
        byteSize: 32,
        createdAt: nil,
        modifiedAt: nil,
        isDirectory: false,
        isPackage: false,
        isAlias: false,
        isUbiquitous: false,
        isExternalVolume: false,
        isLocked: false,
        isReachable: true,
        tags: []
    )

    let service = DuplicateDetectionService()
    let scan = service.scanExactDuplicates(in: [missingA, missingB])

    #expect(scan.groups.isEmpty)
    #expect(scan.issues.count == 2)
    #expect(scan.issues.allSatisfy { $0.kind == .duplicateCheckUnavailable && $0.severity == .warning })
}

@Test("rename planner strips prefixes and removable text, then adds numbering")
func renamePlannerBuildsExpectedFilenames() {
    let item = ShelfItem(
        url: URL(fileURLWithPath: "/tmp/IMG_1234-test.PNG"),
        displayName: "IMG_1234-test.PNG",
        fileExtension: "PNG",
        kindDescription: "Image",
        byteSize: 4,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
        isDirectory: false,
        isPackage: false,
        isAlias: false,
        isUbiquitous: false,
        isExternalVolume: false,
        isLocked: false,
        isReachable: true,
        tags: []
    )
    let pattern = RenamePattern(
        prefixesToRemove: ["IMG_"],
        textToRemove: ["-test"],
        separator: .underscore,
        caseStyle: .lower,
        includeCounter: true,
        counterStart: 7,
        dateSource: .created,
        customPrefix: "receipt",
        customSuffix: "scan"
    )

    let preview = RenamePlanner.previews(for: [item], pattern: pattern)

    #expect(preview.count == 1)
    #expect(preview[0].newFilename == "receipt_2023-11-14_1234_scan_007.PNG")
}

@Test("preflight reports destination conflicts")
func preflightReportsDestinationConflict() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let source = directory.appendingPathComponent("source.txt")
    let conflict = directory.appendingPathComponent("target.txt")
    try Data("hello".utf8).write(to: source)
    try Data("existing".utf8).write(to: conflict)

    let catalog = FileCatalogService()
    let item = try #require(catalog.makeShelfItems(urls: [source]).first)
    let service = FilePreflightService()

    let preview = service.review(items: [item], plannedDestinations: [item.id: conflict])

    #expect(preview.issues.contains(where: { $0.kind == .destinationConflict && $0.severity == .error }))
}
