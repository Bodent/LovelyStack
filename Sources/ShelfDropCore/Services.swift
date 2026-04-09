import AppKit
import CryptoKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public final class ShelfStore {
    private let snapshotURL: URL
    private let fileManager: FileManager

    public init(baseDirectory: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.snapshotURL = baseDirectory.appendingPathComponent("state.json")
    }

    public func load() -> AppSnapshot {
        guard fileManager.fileExists(atPath: snapshotURL.path) else {
            return AppSnapshot(sessions: [ShelfSession()], recentDestinations: [])
        }

        do {
            let data = try Data(contentsOf: snapshotURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(AppSnapshot.self, from: data)
        } catch {
            return AppSnapshot(sessions: [ShelfSession()], recentDestinations: [])
        }
    }

    public func save(_ snapshot: AppSnapshot) throws {
        try fileManager.createDirectory(at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: snapshotURL, options: .atomic)
    }
}

public final class FileCatalogService {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func makeShelfItems(urls: [URL]) -> [ShelfItem] {
        urls.compactMap(loadItem(from:))
    }

    public func refresh(item: ShelfItem) -> ShelfItem? {
        loadItem(from: item.url)
    }

    private func loadItem(from url: URL) -> ShelfItem? {
        let keys: Set<URLResourceKey> = [
            .creationDateKey,
            .contentModificationDateKey,
            .fileSizeKey,
            .isAliasFileKey,
            .isDirectoryKey,
            .isPackageKey,
            .isRegularFileKey,
            .isUbiquitousItemKey,
            .isUserImmutableKey,
            .localizedTypeDescriptionKey,
            .nameKey,
            .tagNamesKey,
            .volumeIsInternalKey,
        ]

        do {
            let values = try url.resourceValues(forKeys: keys)
            let reachable = (try? url.checkResourceIsReachable()) ?? false

            return ShelfItem(
                url: url,
                displayName: values.name ?? url.lastPathComponent,
                fileExtension: url.pathExtension,
                kindDescription: values.localizedTypeDescription ?? inferredKind(for: url),
                byteSize: Int64(values.fileSize ?? 0),
                createdAt: values.creationDate,
                modifiedAt: values.contentModificationDate,
                isDirectory: values.isDirectory ?? false,
                isPackage: values.isPackage ?? false,
                isAlias: values.isAliasFile ?? false,
                isUbiquitous: values.isUbiquitousItem ?? false,
                isExternalVolume: !(values.volumeIsInternal ?? true),
                isLocked: values.isUserImmutable ?? false,
                isReachable: reachable,
                tags: values.tagNames ?? []
            )
        } catch {
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return ShelfItem(
                url: url,
                displayName: url.lastPathComponent,
                fileExtension: url.pathExtension,
                kindDescription: inferredKind(for: url),
                byteSize: 0,
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
        }
    }

    private func inferredKind(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension) {
            return type.localizedDescription ?? type.identifier
        }
        return url.pathExtension.uppercased().isEmpty ? "File" : url.pathExtension.uppercased()
    }
}

public final class DuplicateDetectionService {
    public init() {}

    public func findExactDuplicates(in items: [ShelfItem]) -> [DuplicateGroup] {
        let candidates = Dictionary(grouping: items.filter { !$0.isDirectory && $0.byteSize > 0 }, by: \.byteSize)
        var groups = [DuplicateGroup]()

        for (size, sameSizeItems) in candidates where sameSizeItems.count > 1 {
            var fingerprinted = [String: [ShelfItem]]()
            for item in sameSizeItems {
                guard let fingerprint = try? fingerprint(for: item.url) else { continue }
                fingerprinted[fingerprint, default: []].append(item)
            }
            for (fingerprint, matches) in fingerprinted where matches.count > 1 {
                groups.append(DuplicateGroup(id: fingerprint, itemIDs: matches.map(\.id), byteSize: size))
            }
        }

        return groups.sorted { lhs, rhs in
            lhs.byteSize > rhs.byteSize
        }
    }

    private func fingerprint(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = try? handle.read(upToCount: 1024 * 256)
            if let chunk, !chunk.isEmpty {
                hasher.update(data: chunk)
                return true
            }
            return false
        }) {}

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public final class FilePreflightService {
    private let duplicateService: DuplicateDetectionService

    public init(duplicateService: DuplicateDetectionService = DuplicateDetectionService()) {
        self.duplicateService = duplicateService
    }

    public func review(items: [ShelfItem], plannedDestinations: [UUID: URL] = [:]) -> BatchPreview {
        var issues = [PreflightIssue]()

        for item in items {
            if !item.isReachable {
                issues.append(.init(itemID: item.id, kind: .unreachable, severity: .error, message: "\(item.displayName) is no longer reachable."))
            }
            if item.isLocked {
                issues.append(.init(itemID: item.id, kind: .lockedFile, severity: .warning, message: "\(item.displayName) is locked and may reject metadata changes."))
            }
            if item.isAlias {
                issues.append(.init(itemID: item.id, kind: .alias, severity: .warning, message: "\(item.displayName) is an alias. Confirm the target before filing."))
            }
            if item.isUbiquitous {
                issues.append(.init(itemID: item.id, kind: .iCloudPlaceholder, severity: .warning, message: "\(item.displayName) is in iCloud and may need downloading first."))
            }
            if item.isExternalVolume {
                issues.append(.init(itemID: item.id, kind: .externalVolume, severity: .warning, message: "\(item.displayName) lives on an external volume. Keep the disk mounted during the action."))
            }
            if let destination = plannedDestinations[item.id], destination != item.url, FileManager.default.fileExists(atPath: destination.path) {
                issues.append(.init(itemID: item.id, kind: .destinationConflict, severity: .error, message: "Destination already exists for \(item.displayName)."))
            }
        }

        return BatchPreview(
            title: "Review",
            changes: [],
            issues: issues,
            duplicateGroups: duplicateService.findExactDuplicates(in: items)
        )
    }
}

public struct FinderMetadataSnapshot: Hashable {
    public let tags: [String]
    public let comment: String?
    public let label: FinderLabelColor

    public init(tags: [String], comment: String?, label: FinderLabelColor) {
        self.tags = tags
        self.comment = comment
        self.label = label
    }
}

public final class FinderMetadataService {
    public init() {}

    public func snapshot(for url: URL) -> FinderMetadataSnapshot {
        let values = try? url.resourceValues(forKeys: [.tagNamesKey])
        return FinderMetadataSnapshot(
            tags: values?.tagNames ?? [],
            comment: finderComment(for: url),
            label: finderLabel(for: url)
        )
    }

    public func apply(_ request: MetadataEditRequest, to url: URL) throws {
        let nsURL = url as NSURL
        try nsURL.setResourceValue(request.tags, forKey: .tagNamesKey)
        try setFinderComment(request.comment ?? "", for: url)
        try setFinderLabel(request.label, for: url)
    }

    public func restore(_ snapshot: FinderMetadataSnapshot, to url: URL) throws {
        try apply(.init(tags: snapshot.tags, comment: snapshot.comment, label: snapshot.label), to: url)
    }

    private func finderComment(for url: URL) -> String? {
        let script = """
        tell application "Finder"
            set theItem to POSIX file "\(escapedForAppleScript(url.path))" as alias
            return comment of theItem
        end tell
        """
        return executeAppleScript(script)?.stringValue
    }

    private func finderLabel(for url: URL) -> FinderLabelColor {
        let script = """
        tell application "Finder"
            set theItem to POSIX file "\(escapedForAppleScript(url.path))" as alias
            return label index of theItem
        end tell
        """
        let value = Int(executeAppleScript(script)?.int32Value ?? 0)
        return FinderLabelColor(finderIndex: value)
    }

    private func setFinderComment(_ comment: String, for url: URL) throws {
        let script = """
        tell application "Finder"
            set theItem to POSIX file "\(escapedForAppleScript(url.path))" as alias
            set comment of theItem to "\(escapedForAppleScript(comment))"
        end tell
        """
        try runAppleScript(script)
    }

    private func setFinderLabel(_ label: FinderLabelColor, for url: URL) throws {
        let script = """
        tell application "Finder"
            set theItem to POSIX file "\(escapedForAppleScript(url.path))" as alias
            set label index of theItem to \(label.finderIndex)
        end tell
        """
        try runAppleScript(script)
    }

    private func executeAppleScript(_ source: String) -> NSAppleEventDescriptor? {
        var errorInfo: NSDictionary?
        let script = NSAppleScript(source: source)
        return script?.executeAndReturnError(&errorInfo)
    }

    private func runAppleScript(_ source: String) throws {
        var errorInfo: NSDictionary?
        let script = NSAppleScript(source: source)
        script?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            throw NSError(domain: "ShelfDrop.Metadata", code: 1, userInfo: errorInfo as? [String: Any])
        }
    }

    private func escapedForAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

public final class ImageTransformService {
    public init() {}

    public func transform(items: [ShelfItem], plan: ImageTransformPlan, destinationDirectory: URL) throws -> [URL] {
        var outputs = [URL]()
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        for item in items where item.isImage {
            let sourceURL = item.url
            guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else { continue }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: plan.maxPixelSize ?? 4096,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { continue }

            let basename = sourceURL.deletingPathExtension().lastPathComponent
            let outputURL = destinationDirectory.appendingPathComponent("\(basename).\(plan.outputFormat.fileExtension)")
            guard !FileManager.default.fileExists(atPath: outputURL.path) else {
                throw NSError(domain: "ShelfDrop.ImageTransform", code: 2, userInfo: [NSLocalizedDescriptionKey: "Destination exists for \(outputURL.lastPathComponent)."])
            }

            guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, plan.outputFormat.utiIdentifier, 1, nil) else {
                continue
            }

            var properties: [CFString: Any] = [:]
            if plan.outputFormat == .jpeg {
                properties[kCGImageDestinationLossyCompressionQuality] = plan.compressionQuality
            }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw NSError(domain: "ShelfDrop.ImageTransform", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to write \(outputURL.lastPathComponent)."])
            }

            if !plan.stripMetadata, let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) {
                let outputSource = CGImageSourceCreateWithURL(outputURL as CFURL, nil)
                _ = outputSource
                let destinationWithMetadata = CGImageDestinationCreateWithURL(outputURL as CFURL, plan.outputFormat.utiIdentifier, 1, nil)
                if let destinationWithMetadata {
                    CGImageDestinationAddImage(destinationWithMetadata, image, metadata)
                    _ = CGImageDestinationFinalize(destinationWithMetadata)
                }
            }

            outputs.append(outputURL)
        }

        return outputs
    }

    public func createPDF(from items: [ShelfItem], destinationURL: URL) throws -> URL {
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw NSError(domain: "ShelfDrop.PDF", code: 2, userInfo: [NSLocalizedDescriptionKey: "Destination exists for \(destinationURL.lastPathComponent)."])
        }

        var mediaBox = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        guard let consumer = CGDataConsumer(url: destinationURL as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw NSError(domain: "ShelfDrop.PDF", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create PDF context."])
        }

        for item in items where item.isImage {
            guard let image = NSImage(contentsOf: item.url),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { continue }
            let size = CGSize(width: cgImage.width, height: cgImage.height)
            let pageBox = CGRect(origin: .zero, size: size)
            context.beginPDFPage([kCGPDFContextMediaBox as String: pageBox] as CFDictionary)
            context.draw(cgImage, in: pageBox)
            context.endPDFPage()
        }
        context.closePDF()

        return destinationURL
    }
}

public final class FileActionService {
    private let fileManager: FileManager
    private let preflightService: FilePreflightService
    private let metadataService: FinderMetadataService
    private let imageService: ImageTransformService
    private let trashDirectory: URL
    private var undoBatches = [UndoBatch]()

    public init(
        baseDirectory: URL,
        fileManager: FileManager = .default,
        preflightService: FilePreflightService = FilePreflightService(),
        metadataService: FinderMetadataService = FinderMetadataService(),
        imageService: ImageTransformService = ImageTransformService()
    ) {
        self.fileManager = fileManager
        self.preflightService = preflightService
        self.metadataService = metadataService
        self.imageService = imageService
        self.trashDirectory = baseDirectory.appendingPathComponent("AppTrash", isDirectory: true)
    }

    public var canUndo: Bool {
        !undoBatches.isEmpty
    }

    public func review(items: [ShelfItem]) -> BatchPreview {
        preflightService.review(items: items)
    }

    public func previewMove(items: [ShelfItem], to destination: URL, mode: FileOperationMode) -> BatchPreview {
        let destinations = Dictionary(uniqueKeysWithValues: items.map { item in
            (item.id, destination.appendingPathComponent(item.url.lastPathComponent))
        })
        let preflight = preflightService.review(items: items, plannedDestinations: destinations)
        return BatchPreview(
            title: mode == .move ? "Move Preview" : "Copy Preview",
            changes: items.map {
                PlannedChange(itemID: $0.id, sourceURL: $0.url, destinationURL: destinations[$0.id], summary: "\(mode == .move ? "Move" : "Copy") \($0.displayName)")
            },
            issues: preflight.issues,
            duplicateGroups: preflight.duplicateGroups
        )
    }

    public func executeMove(items: [ShelfItem], to destination: URL, mode: FileOperationMode) throws -> BatchMutation {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        var mutation = BatchMutation(title: mode == .move ? "Moved files" : "Copied files")
        var undoSteps = [UndoStep]()

        for item in items {
            let output = destination.appendingPathComponent(item.url.lastPathComponent)
            guard !fileManager.fileExists(atPath: output.path) else {
                throw NSError(domain: "ShelfDrop.Move", code: 1, userInfo: [NSLocalizedDescriptionKey: "Destination already exists for \(item.displayName)."])
            }
            if mode == .move {
                try fileManager.moveItem(at: item.url, to: output)
                mutation.updatedItemLocations[item.id] = output
                undoSteps.append(.move(from: item.url, to: output))
            } else {
                try fileManager.copyItem(at: item.url, to: output)
                mutation.createdURLs.append(output)
                undoSteps.append(.removeCreated(output))
            }
        }

        undoBatches.append(.init(title: mutation.title, steps: undoSteps))
        return mutation
    }

    public func previewArchive(items: [ShelfItem], root: URL, strategy: ArchiveStrategy) -> BatchPreview {
        let destinations = Dictionary(uniqueKeysWithValues: items.map { item in
            (item.id, archiveDestination(for: item, root: root, strategy: strategy))
        })
        let preflight = preflightService.review(items: items, plannedDestinations: destinations)
        return BatchPreview(
            title: "Archive Preview",
            changes: items.map {
                PlannedChange(itemID: $0.id, sourceURL: $0.url, destinationURL: destinations[$0.id], summary: "Archive \($0.displayName)")
            },
            issues: preflight.issues,
            duplicateGroups: preflight.duplicateGroups
        )
    }

    public func executeArchive(items: [ShelfItem], root: URL, strategy: ArchiveStrategy) throws -> BatchMutation {
        var mutation = BatchMutation(title: "Archived files")
        var undoSteps = [UndoStep]()

        for item in items {
            let output = archiveDestination(for: item, root: root, strategy: strategy)
            try fileManager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard !fileManager.fileExists(atPath: output.path) else {
                throw NSError(domain: "ShelfDrop.Archive", code: 1, userInfo: [NSLocalizedDescriptionKey: "Archive destination already exists for \(item.displayName)."])
            }
            try fileManager.moveItem(at: item.url, to: output)
            mutation.updatedItemLocations[item.id] = output
            undoSteps.append(.move(from: item.url, to: output))
        }

        undoBatches.append(.init(title: mutation.title, steps: undoSteps))
        return mutation
    }

    public func previewRename(items: [ShelfItem], pattern: RenamePattern) -> BatchPreview {
        let previews = RenamePlanner.previews(for: items, pattern: pattern)
        let preflight = preflightService.review(items: items, plannedDestinations: Dictionary(uniqueKeysWithValues: previews.map { ($0.itemID, $0.destinationURL) }))
        return BatchPreview(
            title: "Rename Preview",
            changes: previews.map {
                PlannedChange(itemID: $0.itemID, sourceURL: $0.sourceURL, destinationURL: $0.destinationURL, summary: "Rename to \($0.newFilename)")
            },
            issues: preflight.issues,
            duplicateGroups: preflight.duplicateGroups
        )
    }

    public func executeRename(items: [ShelfItem], pattern: RenamePattern) throws -> BatchMutation {
        let previews = RenamePlanner.previews(for: items, pattern: pattern)
        var mutation = BatchMutation(title: "Renamed files")
        var undoSteps = [UndoStep]()

        for preview in previews {
            guard !fileManager.fileExists(atPath: preview.destinationURL.path) || preview.destinationURL == preview.sourceURL else {
                throw NSError(domain: "ShelfDrop.Rename", code: 1, userInfo: [NSLocalizedDescriptionKey: "Destination already exists for \(preview.newFilename)."])
            }
            try fileManager.moveItem(at: preview.sourceURL, to: preview.destinationURL)
            mutation.updatedItemLocations[preview.itemID] = preview.destinationURL
            undoSteps.append(.move(from: preview.sourceURL, to: preview.destinationURL))
        }

        undoBatches.append(.init(title: mutation.title, steps: undoSteps))
        return mutation
    }

    public func previewMetadata(items: [ShelfItem], request: MetadataEditRequest) -> BatchPreview {
        let preflight = preflightService.review(items: items)
        return BatchPreview(
            title: "Metadata Preview",
            changes: items.map {
                PlannedChange(
                    itemID: $0.id,
                    sourceURL: $0.url,
                    destinationURL: nil,
                    summary: "Apply \(request.label.displayName) label, \(request.tags.count) tag(s), and Finder comment"
                )
            },
            issues: preflight.issues,
            duplicateGroups: preflight.duplicateGroups
        )
    }

    public func executeMetadata(items: [ShelfItem], request: MetadataEditRequest) throws -> BatchMutation {
        var undoSteps = [UndoStep]()
        for item in items {
            let snapshot = metadataService.snapshot(for: item.url)
            try metadataService.apply(request, to: item.url)
            undoSteps.append(.restoreMetadata(url: item.url, snapshot: snapshot))
        }
        undoBatches.append(.init(title: "Updated metadata", steps: undoSteps))
        return BatchMutation(title: "Updated metadata")
    }

    public func previewSafeDelete(items: [ShelfItem]) -> BatchPreview {
        let preflight = preflightService.review(items: items)
        return BatchPreview(
            title: "Safe Delete Preview",
            changes: items.map {
                let trashURL = trashDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent($0.url.lastPathComponent)
                return PlannedChange(itemID: $0.id, sourceURL: $0.url, destinationURL: trashURL, summary: "Move \($0.displayName) into ShelfDrop recovery trash")
            },
            issues: preflight.issues,
            duplicateGroups: preflight.duplicateGroups
        )
    }

    public func executeSafeDelete(items: [ShelfItem]) throws -> BatchMutation {
        try fileManager.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        var mutation = BatchMutation(title: "Safely deleted files")
        var undoSteps = [UndoStep]()

        for item in items {
            let folder = trashDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let trashURL = folder.appendingPathComponent(item.url.lastPathComponent)
            try fileManager.moveItem(at: item.url, to: trashURL)
            mutation.removedItemIDs.insert(item.id)
            undoSteps.append(.restoreFromSafeDelete(original: item.url, trashURL: trashURL))
        }

        undoBatches.append(.init(title: mutation.title, steps: undoSteps))
        return mutation
    }

    public func previewZip(items: [ShelfItem], destinationDirectory: URL, baseName: String) -> BatchPreview {
        let outputURL = destinationDirectory.appendingPathComponent("\(baseName).zip")
        let preflight = preflightService.review(items: items, plannedDestinations: [:])
        var issues = preflight.issues
        if fileManager.fileExists(atPath: outputURL.path) {
            issues.append(.init(itemID: nil, kind: .destinationConflict, severity: .error, message: "Destination already exists for \(outputURL.lastPathComponent)."))
        }
        return BatchPreview(
            title: "Zip Preview",
            changes: [PlannedChange(itemID: nil, sourceURL: destinationDirectory, destinationURL: outputURL, summary: "Create \(outputURL.lastPathComponent)")],
            issues: issues,
            duplicateGroups: preflight.duplicateGroups
        )
    }

    public func executeZip(items: [ShelfItem], destinationDirectory: URL, baseName: String) throws -> BatchMutation {
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let outputURL = destinationDirectory.appendingPathComponent("\(baseName).zip")
        guard !fileManager.fileExists(atPath: outputURL.path) else {
            throw NSError(domain: "ShelfDrop.Zip", code: 1, userInfo: [NSLocalizedDescriptionKey: "Destination already exists for \(outputURL.lastPathComponent)."])
        }

        let staging = destinationDirectory.appendingPathComponent(".zip-staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        for item in items {
            try fileManager.copyItem(at: item.url, to: staging.appendingPathComponent(item.url.lastPathComponent))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", staging.path, outputURL.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ShelfDrop.Zip", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "ditto failed to create the ZIP archive."])
        }

        undoBatches.append(.init(title: "Created ZIP", steps: [.removeCreated(outputURL)]))
        return BatchMutation(title: "Created ZIP", createdURLs: [outputURL])
    }

    public func previewImageTransform(items: [ShelfItem], plan: ImageTransformPlan, destinationDirectory: URL) -> BatchPreview {
        let imageItems = items.filter(\.isImage)
        let outputs = imageItems.map {
            destinationDirectory.appendingPathComponent("\($0.url.deletingPathExtension().lastPathComponent).\(plan.outputFormat.fileExtension)")
        }
        let preflight = preflightService.review(items: imageItems, plannedDestinations: Dictionary(uniqueKeysWithValues: zip(imageItems.map(\.id), outputs)))
        return BatchPreview(
            title: "Image Transform Preview",
            changes: zip(imageItems, outputs).map {
                PlannedChange(itemID: $0.0.id, sourceURL: $0.0.url, destinationURL: $0.1, summary: "Create \($0.1.lastPathComponent)")
            },
            issues: preflight.issues,
            duplicateGroups: preflight.duplicateGroups
        )
    }

    public func executeImageTransform(items: [ShelfItem], plan: ImageTransformPlan, destinationDirectory: URL) throws -> BatchMutation {
        let outputs = try imageService.transform(items: items, plan: plan, destinationDirectory: destinationDirectory)
        undoBatches.append(.init(title: "Converted images", steps: outputs.map(UndoStep.removeCreated)))
        return BatchMutation(title: "Converted images", createdURLs: outputs)
    }

    public func previewPDF(from items: [ShelfItem], destinationDirectory: URL, baseName: String) -> BatchPreview {
        let outputURL = destinationDirectory.appendingPathComponent("\(baseName).pdf")
        let preflight = preflightService.review(items: items)
        var issues = preflight.issues
        if fileManager.fileExists(atPath: outputURL.path) {
            issues.append(.init(itemID: nil, kind: .destinationConflict, severity: .error, message: "Destination already exists for \(outputURL.lastPathComponent)."))
        }
        return BatchPreview(
            title: "Create PDF Preview",
            changes: [PlannedChange(itemID: nil, sourceURL: destinationDirectory, destinationURL: outputURL, summary: "Create \(outputURL.lastPathComponent) from \(items.count) image(s)")],
            issues: issues,
            duplicateGroups: preflight.duplicateGroups
        )
    }

    public func executePDF(from items: [ShelfItem], destinationDirectory: URL, baseName: String) throws -> BatchMutation {
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let outputURL = destinationDirectory.appendingPathComponent("\(baseName).pdf")
        _ = try imageService.createPDF(from: items, destinationURL: outputURL)
        undoBatches.append(.init(title: "Created PDF", steps: [.removeCreated(outputURL)]))
        return BatchMutation(title: "Created PDF", createdURLs: [outputURL])
    }

    public func undoLastBatch() throws -> BatchMutation? {
        guard let batch = undoBatches.popLast() else { return nil }
        var mutation = BatchMutation(title: "Undid \(batch.title)")

        for step in batch.steps.reversed() {
            switch step {
            case let .move(from, to):
                if fileManager.fileExists(atPath: to.path) {
                    try fileManager.moveItem(at: to, to: from)
                }
            case let .restoreFromSafeDelete(original, trashURL):
                if fileManager.fileExists(atPath: trashURL.path) {
                    try fileManager.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileManager.moveItem(at: trashURL, to: original)
                    mutation.restoredURLs.append(original)
                }
            case let .removeCreated(url):
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                    mutation.removedURLs.append(url)
                }
            case let .restoreMetadata(url, snapshot):
                if fileManager.fileExists(atPath: url.path) {
                    try metadataService.restore(snapshot, to: url)
                }
            }
        }

        return mutation
    }

    private func archiveDestination(for item: ShelfItem, root: URL, strategy: ArchiveStrategy) -> URL {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM"

        let folderName: String
        switch strategy {
        case .createdMonth:
            folderName = formatter.string(from: item.createdAt ?? Date())
        case .modifiedMonth:
            folderName = formatter.string(from: item.modifiedAt ?? Date())
        case .fileType:
            folderName = item.kindDescription.replacingOccurrences(of: "/", with: "-")
        }
        return root.appendingPathComponent(folderName, isDirectory: true).appendingPathComponent(item.url.lastPathComponent)
    }
}

private struct UndoBatch {
    let title: String
    let steps: [UndoStep]
}

private enum UndoStep {
    case move(from: URL, to: URL)
    case restoreFromSafeDelete(original: URL, trashURL: URL)
    case removeCreated(URL)
    case restoreMetadata(url: URL, snapshot: FinderMetadataSnapshot)
}
