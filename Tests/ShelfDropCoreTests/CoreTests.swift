import AppKit
import Foundation
import ImageIO
import Testing
@testable import ShelfDropCore

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
    #expect(preview[0].newFilename == "receipt_2023-11-14_1234_scan_007.png")
}

@Test("rename planner removes anchored prefixes by matched range")
func renamePlannerRemovesAnchoredPrefixUsingMatchedRange() {
    let item = ShelfItem(
        url: URL(fileURLWithPath: "/tmp/e\u{301}clair.png"),
        displayName: "e\u{301}clair.png",
        fileExtension: "png",
        kindDescription: "Image",
        byteSize: 4,
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
    let pattern = RenamePattern(
        prefixesToRemove: ["E\u{301}"],
        textToRemove: [],
        separator: .underscore,
        caseStyle: .keep,
        includeCounter: false,
        counterStart: 1,
        dateSource: .none,
        customPrefix: "",
        customSuffix: ""
    )

    let preview = RenamePlanner.previews(for: [item], pattern: pattern)

    #expect(preview.count == 1)
    #expect(preview[0].newFilename == "clair.png")
}

@Test("rename planner title case uses the selected separator and preserves extension case")
func renamePlannerTitleCaseUsesConfiguredSeparator() {
    let item = ShelfItem(
        url: URL(fileURLWithPath: "/tmp/client-note_test.JPG"),
        displayName: "client-note_test.JPG",
        fileExtension: "JPG",
        kindDescription: "Image",
        byteSize: 4,
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
    let pattern = RenamePattern(
        prefixesToRemove: [],
        textToRemove: [],
        separator: .dash,
        caseStyle: .title,
        includeCounter: false,
        counterStart: 1,
        dateSource: .none,
        customPrefix: "",
        customSuffix: ""
    )

    let preview = RenamePlanner.previews(for: [item], pattern: pattern)

    #expect(preview.count == 1)
    #expect(preview[0].newFilename == "Client-Note-Test.JPG")
}

@Test("rename planner removes repeated anchored prefixes across case and normalization differences")
func renamePlannerRemovesRepeatedAnchoredPrefixes() {
    let item = ShelfItem(
        url: URL(fileURLWithPath: "/tmp/img_E\u{301}IMG_receipt.png"),
        displayName: "img_E\u{301}IMG_receipt.png",
        fileExtension: "png",
        kindDescription: "Image",
        byteSize: 4,
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
    let pattern = RenamePattern(
        prefixesToRemove: ["IMG_", "E\u{301}"],
        textToRemove: [],
        separator: .underscore,
        caseStyle: .keep,
        includeCounter: false,
        counterStart: 1,
        dateSource: .none,
        customPrefix: "",
        customSuffix: ""
    )

    let preview = RenamePlanner.previews(for: [item], pattern: pattern)

    #expect(preview.count == 1)
    #expect(preview[0].newFilename == "receipt.png")
}

@Test("rename planner title case only transforms the cleaned basename body")
func renamePlannerTitleCasePreservesCustomTokensAndDateFormatting() {
    let item = ShelfItem(
        url: URL(fileURLWithPath: "/tmp/client-note_test.JPG"),
        displayName: "client-note_test.JPG",
        fileExtension: "JPG",
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
        prefixesToRemove: [],
        textToRemove: [],
        separator: .underscore,
        caseStyle: .title,
        includeCounter: false,
        counterStart: 1,
        dateSource: .created,
        customPrefix: "preFIX",
        customSuffix: "postFIX"
    )

    let preview = RenamePlanner.previews(for: [item], pattern: pattern)

    #expect(preview.count == 1)
    #expect(preview[0].newFilename == "preFIX_2023-11-14_Client_Note_Test_postFIX.JPG")
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

@Test("corrupted shelf state returns a warning without overwriting the file")
func shelfStoreWarnsOnCorruptedState() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let stateURL = directory.appendingPathComponent("state.json")
    let corruptedJSON = "{ definitely-not-json".data(using: .utf8)!
    try corruptedJSON.write(to: stateURL)

    let store = ShelfStore(baseDirectory: directory)
    let result = store.load()
    let storedData = try Data(contentsOf: stateURL)

    #expect(result.warning != nil)
    #expect(result.snapshot.sessions.count == 1)
    #expect(result.snapshot.recentDestinations.isEmpty)
    #expect(storedData == corruptedJSON)
}

@Test("corrupted shelf state blocks future saves until the file loads successfully")
func shelfStoreBlocksWritesUntilCorruptionIsCleared() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let stateURL = directory.appendingPathComponent("state.json")
    try Data("{ broken".utf8).write(to: stateURL)

    let store = ShelfStore(baseDirectory: directory)
    let loadResult = store.load()
    #expect(loadResult.warning != nil)

    do {
        try store.save(AppSnapshot(sessions: [ShelfSession(title: "Recovered")], recentDestinations: []))
        Issue.record("Expected save to be blocked while the on-disk state remains corrupted")
    } catch {
        #expect(error.localizedDescription.contains("preserved"))
        #expect(error.localizedDescription.contains("state.json"))
    }

    try store.save(AppSnapshot(sessions: [ShelfSession(title: "Fixed")], recentDestinations: []), to: stateURL)
    let repairedLoad = store.load()

    #expect(repairedLoad.warning == nil)
    try store.save(AppSnapshot(sessions: [ShelfSession(title: "Recovered")], recentDestinations: []))
}

@Test("batch previews and execution block duplicate internal item IDs")
func fileActionServiceBlocksDuplicateItemIDs() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let destination = directory.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let sharedID = UUID()
    let firstURL = directory.appendingPathComponent("first.txt")
    let secondURL = directory.appendingPathComponent("second.txt")
    try Data("one".utf8).write(to: firstURL)
    try Data("two".utf8).write(to: secondURL)

    let first = ShelfItem(
        id: sharedID,
        url: firstURL,
        displayName: "first.txt",
        fileExtension: "txt",
        kindDescription: "Text",
        byteSize: 3,
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
    let second = ShelfItem(
        id: sharedID,
        url: secondURL,
        displayName: "second.txt",
        fileExtension: "txt",
        kindDescription: "Text",
        byteSize: 3,
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

    let actions = FileActionService(baseDirectory: directory)
    let preview = actions.previewMove(items: [first, second], to: destination, mode: .move)

    #expect(preview.hasBlockingIssues)
    #expect(preview.issues.contains(where: { $0.kind == .internalValidation && $0.severity == .error }))

    do {
        _ = try await actions.executeMove(items: [first, second], to: destination, mode: .move)
        Issue.record("Expected duplicate ID execution validation to throw")
    } catch {
        #expect(error.localizedDescription.contains("internal ID"))
    }
}

@Test("finder metadata escapes multiline strings for AppleScript")
func finderMetadataEscapesMultilineAppleScriptStrings() {
    let service = FinderMetadataService()

    let literal = service.appleScriptStringLiteral("Line 1\nLine \"2\"")

    #expect(literal.contains("linefeed"))
    #expect(literal.contains("\"Line 1\""))
    #expect(literal.contains("\\\"2\\\""))
}

@Test("metadata batch surfaces Finder snapshot failures")
func metadataBatchPropagatesFinderSnapshotFailure() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("sample.txt")
    try Data("content".utf8).write(to: fileURL)

    let catalog = FileCatalogService()
    let item = try #require(catalog.makeShelfItems(urls: [fileURL]).first)
    let metadataService = FinderMetadataService { _ in
        throw NSError(domain: "Test.Metadata", code: 99, userInfo: [NSLocalizedDescriptionKey: "Apple events unavailable"])
    }
    let actions = FileActionService(baseDirectory: directory, metadataService: metadataService)

    do {
        _ = try await actions.executeMetadata(items: [item], request: MetadataEditRequest())
        Issue.record("Expected metadata execution to fail when Finder snapshot reads fail")
    } catch {
        #expect(error.localizedDescription.contains("Apple events unavailable"))
    }
}

@Test("image transform preview warns when non-image items are selected")
func imageTransformPreviewWarnsForSkippedSelections() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let outputDirectory = directory.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let imageURL = directory.appendingPathComponent("sample.png")
    let textURL = directory.appendingPathComponent("notes.txt")
    try makePNG(at: imageURL)
    try Data("notes".utf8).write(to: textURL)

    let catalog = FileCatalogService()
    let items = catalog.makeShelfItems(urls: [imageURL, textURL])
    let actions = FileActionService(baseDirectory: directory)

    let preview = actions.previewImageTransform(items: items, plan: ImageTransformPlan(), destinationDirectory: outputDirectory)

    #expect(preview.changes.count == 1)
    #expect(preview.issues.contains(where: { $0.kind == .unsupportedSelection && $0.severity == .warning }))
}

@Test("image transform writes a decodable output when metadata is preserved")
func imageTransformWritesSingleDecodableOutput() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let outputDirectory = directory.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let imageURL = directory.appendingPathComponent("sample.png")
    try makePNG(at: imageURL)

    let catalog = FileCatalogService()
    let item = try #require(catalog.makeShelfItems(urls: [imageURL]).first)
    let outputs = try ImageTransformService().transform(
        items: [item],
        plan: ImageTransformPlan(outputFormat: .jpeg, maxPixelSize: 128, compressionQuality: 0.8, stripMetadata: false),
        destinationDirectory: outputDirectory
    )

    #expect(outputs.count == 1)
    #expect(FileManager.default.fileExists(atPath: outputs[0].path))
    #expect(CGImageSourceCreateWithURL(outputs[0] as CFURL, nil) != nil)
}

@Test("image transform keeps full resolution when no resize is requested")
func imageTransformPreservesOriginalDimensionsWithoutResize() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let outputDirectory = directory.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let imageURL = directory.appendingPathComponent("wide.png")
    try makePNG(at: imageURL, size: CGSize(width: 4100, height: 8))

    let catalog = FileCatalogService()
    let item = try #require(catalog.makeShelfItems(urls: [imageURL]).first)
    let outputs = try ImageTransformService().transform(
        items: [item],
        plan: ImageTransformPlan(outputFormat: .png, maxPixelSize: nil, compressionQuality: 1.0, stripMetadata: true),
        destinationDirectory: outputDirectory
    )

    #expect(outputs.count == 1)
    #expect(try imageSize(at: outputs[0]) == CGSize(width: 4100, height: 8))
}

@Test("image transform resizes when maxPixelSize is set")
func imageTransformRespectsResizeLimit() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let outputDirectory = directory.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let imageURL = directory.appendingPathComponent("sample.png")
    try makePNG(at: imageURL, size: CGSize(width: 600, height: 200))

    let catalog = FileCatalogService()
    let item = try #require(catalog.makeShelfItems(urls: [imageURL]).first)
    let outputs = try ImageTransformService().transform(
        items: [item],
        plan: ImageTransformPlan(outputFormat: .png, maxPixelSize: 128, compressionQuality: 1.0, stripMetadata: true),
        destinationDirectory: outputDirectory
    )

    let size = try imageSize(at: try #require(outputs.first))
    #expect(max(size.width, size.height) <= 128)
}

@Test("image transform normalizes orientation metadata when preserving metadata")
func imageTransformSanitizesOrientationMetadata() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let outputDirectory = directory.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let imageURL = directory.appendingPathComponent("oriented.jpg")
    try makeJPEG(at: imageURL, size: CGSize(width: 4, height: 2), orientation: .right)

    let catalog = FileCatalogService()
    let item = try #require(catalog.makeShelfItems(urls: [imageURL]).first)
    let outputURL = try #require(
        ImageTransformService().transform(
            items: [item],
            plan: ImageTransformPlan(outputFormat: .jpeg, maxPixelSize: nil, compressionQuality: 0.8, stripMetadata: false),
            destinationDirectory: outputDirectory
        ).first
    )

    #expect(try imageSize(at: outputURL) == CGSize(width: 2, height: 4))
    let properties = try imageProperties(at: outputURL)
    #expect(properties[kCGImagePropertyPixelWidth] as? Int == 2)
    #expect(properties[kCGImagePropertyPixelHeight] as? Int == 4)
    #expect((properties[kCGImagePropertyOrientation] as? UInt32) == 1)
}

@Test("safe delete undo restores files and removes recovery folders")
func safeDeleteUndoRemovesRecoveryFolders() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("receipt.txt")
    try Data("receipt".utf8).write(to: fileURL)

    let catalog = FileCatalogService()
    let item = try #require(catalog.makeShelfItems(urls: [fileURL]).first)
    let actions = FileActionService(baseDirectory: directory)

    _ = try await actions.executeSafeDelete(items: [item])
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("AppTrash").path))

    let undo = try await actions.undoLastBatch()

    #expect(undo != nil)
    #expect(FileManager.default.fileExists(atPath: fileURL.path))
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("AppTrash").path))
}

@Test("safe delete stores one recovery directory per batch and uniques duplicate filenames")
func safeDeleteUsesSingleBatchDirectory() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let firstFolder = directory.appendingPathComponent("a", isDirectory: true)
    let secondFolder = directory.appendingPathComponent("b", isDirectory: true)
    try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let firstURL = firstFolder.appendingPathComponent("receipt.txt")
    let secondURL = secondFolder.appendingPathComponent("receipt.txt")
    try Data("one".utf8).write(to: firstURL)
    try Data("two".utf8).write(to: secondURL)

    let catalog = FileCatalogService()
    let items = catalog.makeShelfItems(urls: [firstURL, secondURL])
    let actions = FileActionService(baseDirectory: directory)

    _ = try await actions.executeSafeDelete(items: items)

    let trashRoot = directory.appendingPathComponent("AppTrash", isDirectory: true)
    let batchDirectories = try FileManager.default.contentsOfDirectory(at: trashRoot, includingPropertiesForKeys: nil)
    #expect(batchDirectories.count == 1)

    let trashedFiles = try FileManager.default.contentsOfDirectory(at: batchDirectories[0], includingPropertiesForKeys: nil)
    #expect(Set(trashedFiles.map(\.lastPathComponent)) == ["receipt.txt", "receipt 2.txt"])
}

@Test("safe delete evicts old recovery directories with undo history")
func safeDeleteEvictionCleansRecoveryDirectories() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let catalog = FileCatalogService()
    let actions = FileActionService(baseDirectory: directory)

    for index in 0..<21 {
        let fileURL = directory.appendingPathComponent("sample-\(index).txt")
        try Data("content-\(index)".utf8).write(to: fileURL)
        let item = try #require(catalog.makeShelfItems(urls: [fileURL]).first)
        _ = try await actions.executeSafeDelete(items: [item])
    }

    let trashRoot = directory.appendingPathComponent("AppTrash", isDirectory: true)
    let batchDirectories = try FileManager.default.contentsOfDirectory(at: trashRoot, includingPropertiesForKeys: nil)
    #expect(batchDirectories.count == 20)
}

@Test("undo history is capped at twenty batches")
func undoHistoryIsCapped() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let destination = directory.appendingPathComponent("zips", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("sample.txt")
    try Data("content".utf8).write(to: fileURL)

    let catalog = FileCatalogService()
    let item = try #require(catalog.makeShelfItems(urls: [fileURL]).first)
    let actions = FileActionService(baseDirectory: directory)

    for index in 0..<21 {
        _ = try await actions.executeZip(items: [item], destinationDirectory: destination, baseName: "bundle-\(index)")
    }

    var undoCount = 0
    while let _ = try await actions.undoLastBatch() {
        undoCount += 1
    }

    #expect(undoCount == 20)
}

private func makePNG(at url: URL, size: CGSize = CGSize(width: 2, height: 2)) throws {
    let representation = try makeBitmapRepresentation(size: size, color: .systemBlue)
    let pngData = try #require(representation.representation(using: .png, properties: [:]))
    try pngData.write(to: url)
}

private func makeJPEG(at url: URL, size: CGSize, orientation: CGImagePropertyOrientation) throws {
    let representation = try makeBitmapRepresentation(size: size, color: .systemGreen)
    let jpegData = try #require(representation.representation(using: .jpeg, properties: [.compressionFactor: 1.0]))
    let source = try #require(CGImageSourceCreateWithData(jpegData as CFData, nil))
    let cgImage = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, cgImage, [kCGImagePropertyOrientation: orientation.rawValue] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
}

private func makeBitmapRepresentation(size: CGSize, color: NSColor) throws -> NSBitmapImageRep {
    let width = Int(size.width)
    let height = Int(size.height)
    let representation = try #require(
        NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
    )
    let context = try #require(NSGraphicsContext(bitmapImageRep: representation))

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    color.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
    NSGraphicsContext.restoreGraphicsState()

    return representation
}

private func imageSize(at url: URL) throws -> CGSize {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    return CGSize(width: image.width, height: image.height)
}

private func imageProperties(at url: URL) throws -> [CFString: Any] {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
}

private extension ShelfStore {
    func save(_ snapshot: AppSnapshot, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }
}
