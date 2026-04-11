import AppKit
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

private enum ScopedFileAccess {
    static func makeBookmarkData(for url: URL) -> Data? {
        try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func withResolvedURL<T>(url: URL, bookmarkData: Data?, _ body: (URL) throws -> T) throws -> T {
        guard let bookmarkData else {
            return try body(url)
        }

        var isStale = false
        let resolvedURL = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        let didStartAccess = resolvedURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                resolvedURL.stopAccessingSecurityScopedResource()
            }
        }

        return try body(resolvedURL)
    }
}

private func withAccessibleURL<T>(for item: ShelfItem, _ body: (URL) throws -> T) throws -> T {
    try ScopedFileAccess.withResolvedURL(url: item.url, bookmarkData: item.bookmarkData, body)
}

public struct ShelfStoreLoadResult {
    public let snapshot: AppSnapshot
    public let warning: String?

    public init(snapshot: AppSnapshot, warning: String? = nil) {
        self.snapshot = snapshot
        self.warning = warning
    }
}

public final class ShelfStore {
    private static let writeProtectionMessage = "Saved shelf state appears corrupted and was preserved. ShelfDrop will not overwrite state.json until it loads successfully again."

    private let snapshotURL: URL
    private let fileManager: FileManager
    private var writeProtectionReason: String?

    public init(baseDirectory: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.snapshotURL = baseDirectory.appendingPathComponent("state.json")
    }

    public func load() -> ShelfStoreLoadResult {
        guard fileManager.fileExists(atPath: snapshotURL.path) else {
            writeProtectionReason = nil
            return ShelfStoreLoadResult(snapshot: AppSnapshot(sessions: [ShelfSession()], recentDestinations: [], selectedSessionID: nil))
        }

        do {
            let data = try Data(contentsOf: snapshotURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(AppSnapshot.self, from: data)
            writeProtectionReason = nil
            return ShelfStoreLoadResult(snapshot: snapshot)
        } catch {
            writeProtectionReason = Self.writeProtectionMessage
            return ShelfStoreLoadResult(
                snapshot: AppSnapshot(sessions: [ShelfSession()], recentDestinations: [], selectedSessionID: nil),
                warning: "Could not decode saved shelf state: \(error.localizedDescription). \(Self.writeProtectionMessage)"
            )
        }
    }

    public func save(_ snapshot: AppSnapshot) throws {
        if let writeProtectionReason {
            throw NSError(
                domain: "ShelfDrop.Store",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: writeProtectionReason]
            )
        }
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
        urls.compactMap { loadItem(from: $0, bookmarkData: nil, allowFallback: true) }
    }

    public func refresh(item: ShelfItem) -> ShelfItem? {
        if let bookmarkData = item.bookmarkData {
            return loadItem(from: item.url, bookmarkData: bookmarkData, allowFallback: false)
                ?? loadItem(from: item.url, bookmarkData: nil, allowFallback: false)
        }
        return loadItem(from: item.url, bookmarkData: nil, allowFallback: false)
    }

    private func loadItem(from url: URL, bookmarkData: Data?, allowFallback: Bool) -> ShelfItem? {
        if let loaded = try? catalogedItem(from: url, bookmarkData: bookmarkData) {
            return loaded
        }

        guard allowFallback else { return nil }
        return fallbackItem(from: url, bookmarkData: bookmarkData)
    }

    private func catalogedItem(from url: URL, bookmarkData: Data?) throws -> ShelfItem {
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

        return try ScopedFileAccess.withResolvedURL(url: url, bookmarkData: bookmarkData) { resolvedURL in
            let values = try resolvedURL.resourceValues(forKeys: keys)
            let reachable = (try? resolvedURL.checkResourceIsReachable()) ?? false
            let refreshedBookmark = ScopedFileAccess.makeBookmarkData(for: resolvedURL) ?? bookmarkData

            return ShelfItem(
                url: resolvedURL,
                bookmarkData: refreshedBookmark,
                displayName: values.name ?? resolvedURL.lastPathComponent,
                fileExtension: resolvedURL.pathExtension,
                kindDescription: values.localizedTypeDescription ?? inferredKind(for: resolvedURL),
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
        }
    }

    private func fallbackItem(from url: URL, bookmarkData: Data?) -> ShelfItem? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return ShelfItem(
            url: url,
            bookmarkData: bookmarkData ?? ScopedFileAccess.makeBookmarkData(for: url),
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

    private func inferredKind(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension) {
            return type.localizedDescription ?? type.identifier
        }
        return url.pathExtension.uppercased().isEmpty ? "File" : url.pathExtension.uppercased()
    }
}

public final class DuplicateDetectionService {
    private let fingerprintCache = NSCache<NSString, NSString>()

    public init() {}

    public struct ScanResult: Hashable {
        public let groups: [DuplicateGroup]
        public let issues: [PreflightIssue]

        public init(groups: [DuplicateGroup], issues: [PreflightIssue]) {
            self.groups = groups
            self.issues = issues
        }
    }

    public func findExactDuplicates(in items: [ShelfItem]) -> [DuplicateGroup] {
        scanExactDuplicates(in: items).groups
    }

    public func scanExactDuplicates(in items: [ShelfItem]) -> ScanResult {
        let candidates = Dictionary(grouping: items.filter { !$0.isDirectory && $0.byteSize > 0 }, by: \.byteSize)
        var groups = [DuplicateGroup]()
        var issues = [PreflightIssue]()

        for (size, sameSizeItems) in candidates where sameSizeItems.count > 1 {
            var fingerprinted = [String: [ShelfItem]]()
            for item in sameSizeItems {
                guard let fingerprint = try? fingerprint(for: item) else {
                    issues.append(
                        PreflightIssue(
                            itemID: item.id,
                            kind: .duplicateCheckUnavailable,
                            severity: .warning,
                            message: "Could not read \(item.displayName) to check for duplicates. Re-add it if access was lost after relaunch."
                        )
                    )
                    continue
                }
                fingerprinted[fingerprint, default: []].append(item)
            }
            for (fingerprint, matches) in fingerprinted where matches.count > 1 {
                groups.append(DuplicateGroup(id: fingerprint, itemIDs: matches.map(\.id), byteSize: size))
            }
        }

        return ScanResult(
            groups: groups.sorted { lhs, rhs in
                lhs.byteSize > rhs.byteSize
            },
            issues: issues
        )
    }

    private func fingerprint(for item: ShelfItem) throws -> String {
        let cacheKey = fingerprintCacheKey(for: item) as NSString
        if let cached = fingerprintCache.object(forKey: cacheKey) {
            return cached as String
        }

        return try withAccessibleURL(for: item) { resolvedURL in
            let handle = try FileHandle(forReadingFrom: resolvedURL)
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
            let fingerprint = digest.map { String(format: "%02x", $0) }.joined()
            fingerprintCache.setObject(fingerprint as NSString, forKey: cacheKey)
            return fingerprint
        }
    }

    private func fingerprintCacheKey(for item: ShelfItem) -> String {
        let modificationStamp = item.modifiedAt?.timeIntervalSinceReferenceDate ?? 0
        return "\(item.url.standardizedFileURL.resolvingSymlinksInPath().path)|\(item.byteSize)|\(modificationStamp)"
    }
}

public final class FilePreflightService {
    private let fileManager: FileManager
    private let duplicateService: DuplicateDetectionService

    public init(
        fileManager: FileManager = .default,
        duplicateService: DuplicateDetectionService = DuplicateDetectionService()
    ) {
        self.fileManager = fileManager
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
            if let destination = plannedDestinations[item.id], destination != item.url, fileManager.fileExists(atPath: destination.path) {
                issues.append(.init(itemID: item.id, kind: .destinationConflict, severity: .error, message: "Destination already exists for \(item.displayName)."))
            }
        }

        let duplicateScan = duplicateService.scanExactDuplicates(in: items)
        issues.append(contentsOf: duplicateScan.issues)

        return BatchPreview(
            title: "Review",
            changes: [],
            issues: issues,
            duplicateGroups: duplicateScan.groups
        )
    }
}

public struct FinderMetadataSnapshot: Hashable, Sendable {
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
    private let executeScript: (String) throws -> NSAppleEventDescriptor?

    public init(executeScript: @escaping (String) throws -> NSAppleEventDescriptor? = FinderMetadataService.liveExecuteAppleScript) {
        self.executeScript = executeScript
    }

    public func snapshot(for url: URL) throws -> FinderMetadataSnapshot {
        let values = try? url.resourceValues(forKeys: [.tagNamesKey])
        return FinderMetadataSnapshot(
            tags: values?.tagNames ?? [],
            comment: try finderComment(for: url),
            label: try finderLabel(for: url)
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

    private func finderComment(for url: URL) throws -> String? {
        let script = """
        tell application "Finder"
            set theItem to POSIX file \(appleScriptStringLiteral(url.path)) as alias
            return comment of theItem
        end tell
        """
        return try descriptor(for: script).stringValue
    }

    private func finderLabel(for url: URL) throws -> FinderLabelColor {
        let script = """
        tell application "Finder"
            set theItem to POSIX file \(appleScriptStringLiteral(url.path)) as alias
            return label index of theItem
        end tell
        """
        let value = Int(try descriptor(for: script).int32Value)
        return FinderLabelColor(finderIndex: value)
    }

    private func setFinderComment(_ comment: String, for url: URL) throws {
        let script = """
        tell application "Finder"
            set theItem to POSIX file \(appleScriptStringLiteral(url.path)) as alias
            set comment of theItem to \(appleScriptStringLiteral(comment))
        end tell
        """
        try runAppleScript(script)
    }

    private func setFinderLabel(_ label: FinderLabelColor, for url: URL) throws {
        let script = """
        tell application "Finder"
            set theItem to POSIX file \(appleScriptStringLiteral(url.path)) as alias
            set label index of theItem to \(label.finderIndex)
        end tell
        """
        try runAppleScript(script)
    }

    public static func liveExecuteAppleScript(_ source: String) throws -> NSAppleEventDescriptor? {
        var errorInfo: NSDictionary?
        let script = NSAppleScript(source: source)
        guard let script else {
            throw NSError(
                domain: "ShelfDrop.Metadata",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not compile the AppleScript used to access Finder metadata."]
            )
        }
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            throw NSError(domain: "ShelfDrop.Metadata", code: 1, userInfo: errorInfo as? [String: Any])
        }
        return descriptor
    }

    private func descriptor(for source: String) throws -> NSAppleEventDescriptor {
        if let descriptor = try executeScript(source) {
            return descriptor
        }
        throw NSError(
            domain: "ShelfDrop.Metadata",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Finder did not return metadata for the requested item."]
        )
    }

    private func runAppleScript(_ source: String) throws {
        _ = try descriptor(for: source)
    }

    func appleScriptStringLiteral(_ value: String) -> String {
        var segments = [String]()
        var currentSegment = String()
        currentSegment.reserveCapacity(value.count)

        var previousWasCarriageReturn = false
        for scalar in value.unicodeScalars {
            if previousWasCarriageReturn, scalar == "\n" {
                previousWasCarriageReturn = false
                continue
            }

            previousWasCarriageReturn = false

            switch scalar {
            case "\r":
                segments.append("\"\(currentSegment)\"")
                currentSegment.removeAll(keepingCapacity: true)
                previousWasCarriageReturn = true
            case "\n":
                segments.append("\"\(currentSegment)\"")
                currentSegment.removeAll(keepingCapacity: true)
            case "\\":
                currentSegment.append("\\\\")
            case "\"":
                currentSegment.append("\\\"")
            default:
                currentSegment.unicodeScalars.append(scalar)
            }
        }

        segments.append("\"\(currentSegment)\"")

        return segments.isEmpty ? "\"\"" : segments.joined(separator: " & linefeed & ")
    }
}

public final class ImageTransformService {
    private let fileManager: FileManager
    private let ciContext: CIContext

    public init(fileManager: FileManager = .default, ciContext: CIContext = CIContext()) {
        self.fileManager = fileManager
        self.ciContext = ciContext
    }

    public func transform(items: [ShelfItem], plan: ImageTransformPlan, destinationDirectory: URL) throws -> [URL] {
        var outputs = [URL]()
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        for item in items where item.isImage {
            let outputURL = try withAccessibleURL(for: item) { sourceURL in
                guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
                    throw NSError(domain: "ShelfDrop.ImageTransform", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not read \(item.displayName)."])
                }
                let image = try decodeImage(from: source, itemName: item.displayName, plan: plan)

                let basename = sourceURL.deletingPathExtension().lastPathComponent
                let outputURL = destinationDirectory.appendingPathComponent("\(basename).\(plan.outputFormat.fileExtension)")
                guard !fileManager.fileExists(atPath: outputURL.path) else {
                    throw NSError(domain: "ShelfDrop.ImageTransform", code: 2, userInfo: [NSLocalizedDescriptionKey: "Destination exists for \(outputURL.lastPathComponent)."])
                }

                guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, plan.outputFormat.utiIdentifier, 1, nil) else {
                    throw NSError(domain: "ShelfDrop.ImageTransform", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create \(outputURL.lastPathComponent)."])
                }

                let properties = sanitizedProperties(for: source, image: image, plan: plan)
                CGImageDestinationAddImage(destination, image, properties as CFDictionary)
                guard CGImageDestinationFinalize(destination) else {
                    throw NSError(domain: "ShelfDrop.ImageTransform", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to write \(outputURL.lastPathComponent)."])
                }

                return outputURL
            }

            outputs.append(outputURL)
        }

        return outputs
    }

    public func createPDF(from items: [ShelfItem], destinationURL: URL) throws -> URL {
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw NSError(domain: "ShelfDrop.PDF", code: 2, userInfo: [NSLocalizedDescriptionKey: "Destination exists for \(destinationURL.lastPathComponent)."])
        }

        var mediaBox = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        guard let consumer = CGDataConsumer(url: destinationURL as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw NSError(domain: "ShelfDrop.PDF", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create PDF context."])
        }

        for item in items where item.isImage {
            let cgImage = try withAccessibleURL(for: item) { sourceURL in
                guard let image = NSImage(contentsOf: sourceURL),
                      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                else {
                    throw NSError(domain: "ShelfDrop.PDF", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not read \(item.displayName)."])
                }
                return cgImage
            }
            let size = CGSize(width: cgImage.width, height: cgImage.height)
            let pageBox = CGRect(origin: .zero, size: size)
            context.beginPDFPage([kCGPDFContextMediaBox as String: pageBox] as CFDictionary)
            context.draw(cgImage, in: pageBox)
            context.endPDFPage()
        }
        context.closePDF()

        return destinationURL
    }

    private func decodeImage(from source: CGImageSource, itemName: String, plan: ImageTransformPlan) throws -> CGImage {
        if let maxPixelSize = plan.maxPixelSize {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw NSError(domain: "ShelfDrop.ImageTransform", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not decode \(itemName)."])
            }
            return image
        }

        guard let rawImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(domain: "ShelfDrop.ImageTransform", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not decode \(itemName)."])
        }

        let orientation = sourceOrientation(for: source)
        guard orientation != .up else {
            return rawImage
        }

        let ciImage = CIImage(cgImage: rawImage).oriented(orientation)
        guard let orientedImage = ciContext.createCGImage(ciImage, from: ciImage.extent.integral) else {
            throw NSError(domain: "ShelfDrop.ImageTransform", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not normalize orientation for \(itemName)."])
        }
        return orientedImage
    }

    private func sanitizedProperties(for source: CGImageSource, image: CGImage, plan: ImageTransformPlan) -> [CFString: Any] {
        var properties = [CFString: Any]()
        if !plan.stripMetadata,
           let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            properties.merge(metadata) { current, _ in current }
            properties[kCGImagePropertyPixelWidth] = image.width
            properties[kCGImagePropertyPixelHeight] = image.height
            properties[kCGImagePropertyOrientation] = 1

            if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                properties[kCGImagePropertyTIFFDictionary] = tiff
            }
        }
        if plan.outputFormat == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = plan.compressionQuality
        }
        return properties
    }

    private func sourceOrientation(for source: CGImageSource) -> CGImagePropertyOrientation {
        guard let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawValue = metadata[kCGImagePropertyOrientation] as? UInt32,
              let orientation = CGImagePropertyOrientation(rawValue: rawValue)
        else {
            return .up
        }
        return orientation
    }
}

extension DuplicateDetectionService: @unchecked Sendable {}
extension FilePreflightService: @unchecked Sendable {}
extension FinderMetadataService: @unchecked Sendable {}
extension ImageTransformService: @unchecked Sendable {}

public actor FileActionService {
    private let maxUndoBatches = 20
    private let maxUndoSteps = 1_000
    nonisolated(unsafe) private let fileManager: FileManager
    nonisolated private let preflightService: FilePreflightService
    nonisolated private let metadataService: FinderMetadataService
    nonisolated private let imageService: ImageTransformService
    nonisolated private let trashDirectory: URL
    private var undoBatches = [UndoBatch]()

    public init(
        baseDirectory: URL,
        fileManager: FileManager = .default,
        preflightService: FilePreflightService = FilePreflightService(),
        metadataService: FinderMetadataService = FinderMetadataService(),
        imageService: ImageTransformService? = nil
    ) {
        self.fileManager = fileManager
        self.preflightService = preflightService
        self.metadataService = metadataService
        self.imageService = imageService ?? ImageTransformService(fileManager: fileManager)
        self.trashDirectory = baseDirectory.appendingPathComponent("AppTrash", isDirectory: true)
    }

    public var canUndo: Bool {
        !undoBatches.isEmpty
    }

    public nonisolated func review(items: [ShelfItem]) -> BatchPreview {
        preflightService.review(items: items)
    }

    public nonisolated func previewMove(items: [ShelfItem], to destination: URL, mode: FileOperationMode) -> BatchPreview {
        let action = RelocationBatchAction(
            title: mode == .move ? "Move Preview" : "Copy Preview",
            mutationTitle: mode == .move ? "Moved files" : "Copied files",
            items: items,
            destination: { destination.appendingPathComponent($0.url.lastPathComponent) },
            summary: { item, _ in "\(mode == .move ? "Move" : "Copy") \(item.displayName)" },
            createParentDirectories: false,
            conflictError: { item, _ in
                NSError(
                    domain: "ShelfDrop.Move",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Destination already exists for \(item.displayName)."]
                )
            },
            operation: mode == .move ? .move : .copy
        )
        return preview(action)
    }

    public func executeMove(items: [ShelfItem], to destination: URL, mode: FileOperationMode) throws -> BatchMutation {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let action = RelocationBatchAction(
            title: mode == .move ? "Move Preview" : "Copy Preview",
            mutationTitle: mode == .move ? "Moved files" : "Copied files",
            items: items,
            destination: { destination.appendingPathComponent($0.url.lastPathComponent) },
            summary: { item, _ in "\(mode == .move ? "Move" : "Copy") \(item.displayName)" },
            createParentDirectories: false,
            conflictError: { item, _ in
                NSError(
                    domain: "ShelfDrop.Move",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Destination already exists for \(item.displayName)."]
                )
            },
            operation: mode == .move ? .move : .copy
        )
        return try execute(action)
    }

    public nonisolated func previewArchive(items: [ShelfItem], root: URL, strategy: ArchiveStrategy) -> BatchPreview {
        preview(
            RelocationBatchAction(
                title: "Archive Preview",
                mutationTitle: "Archived files",
                items: items,
                destination: { [self] in archiveDestination(for: $0, root: root, strategy: strategy) },
                summary: { item, _ in "Archive \(item.displayName)" },
                createParentDirectories: true,
                conflictError: { item, _ in
                    NSError(
                        domain: "ShelfDrop.Archive",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Archive destination already exists for \(item.displayName)."]
                    )
                },
                operation: .move
            )
        )
    }

    public func executeArchive(items: [ShelfItem], root: URL, strategy: ArchiveStrategy) throws -> BatchMutation {
        try execute(
            RelocationBatchAction(
                title: "Archive Preview",
                mutationTitle: "Archived files",
                items: items,
                destination: { [self] in archiveDestination(for: $0, root: root, strategy: strategy) },
                summary: { item, _ in "Archive \(item.displayName)" },
                createParentDirectories: true,
                conflictError: { item, _ in
                    NSError(
                        domain: "ShelfDrop.Archive",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Archive destination already exists for \(item.displayName)."]
                    )
                },
                operation: .move
            )
        )
    }

    public nonisolated func previewRename(items: [ShelfItem], pattern: RenamePattern) -> BatchPreview {
        let previews = RenamePlanner.previews(for: items, pattern: pattern)
        let validationIssues = validationIssues(for: items)
        let plannedDestinations = validationIssues.isEmpty ? makeDestinationMap(for: previews, id: \.itemID, destination: \.destinationURL) : [:]
        return buildPreview(
            title: "Rename Preview",
            changes: previews.map {
                PlannedChange(itemID: $0.itemID, sourceURL: $0.sourceURL, destinationURL: $0.destinationURL, summary: "Rename to \($0.newFilename)")
            },
            reviewItems: items,
            plannedDestinations: plannedDestinations,
            extraIssues: validationIssues
        )
    }

    public func executeRename(items: [ShelfItem], pattern: RenamePattern) throws -> BatchMutation {
        try ensureUniqueItemIDs(in: items)
        let previews = RenamePlanner.previews(for: items, pattern: pattern)
        return try executeItemBatch(
            title: "Renamed files",
            items: items,
            refreshedItemIDs: Set(items.map(\.id))
        ) { item, mutation in
            guard let preview = previews.first(where: { $0.itemID == item.id }) else { return nil }
            guard !fileManager.fileExists(atPath: preview.destinationURL.path) || preview.destinationURL == preview.sourceURL else {
                throw NSError(domain: "ShelfDrop.Rename", code: 1, userInfo: [NSLocalizedDescriptionKey: "Destination already exists for \(preview.newFilename)."])
            }
            let (destinationURL, step): (URL, UndoStep) = try withAccessibleURL(for: item) { sourceURL in
                let dest = sourceURL.deletingLastPathComponent().appendingPathComponent(preview.newFilename)
                try fileManager.moveItem(at: sourceURL, to: dest)
                return (dest, .move(from: sourceURL, to: dest))
            }
            mutation.updatedItemLocations[item.id] = destinationURL
            return step
        }
    }

    public nonisolated func previewMetadata(items: [ShelfItem], request: MetadataEditRequest) -> BatchPreview {
        buildPreview(
            title: "Metadata Preview",
            changes: items.map {
                PlannedChange(
                    itemID: $0.id,
                    sourceURL: $0.url,
                    destinationURL: nil,
                    summary: "Apply \(request.label.displayName) label, \(request.tags.count) tag(s), and Finder comment"
                )
            },
            reviewItems: items
        )
    }

    public func executeMetadata(items: [ShelfItem], request: MetadataEditRequest) throws -> BatchMutation {
        try ensureUniqueItemIDs(in: items)
        return try executeItemBatch(
            title: "Updated metadata",
            items: items,
            refreshedItemIDs: Set(items.map(\.id))
        ) { item, _ in
            try withAccessibleURL(for: item) { sourceURL in
                let snapshot = try metadataService.snapshot(for: sourceURL)
                try metadataService.apply(request, to: sourceURL)
                return .restoreMetadata(url: sourceURL, snapshot: snapshot)
            }
        }
    }

    public nonisolated func previewSafeDelete(items: [ShelfItem]) -> BatchPreview {
        let batchDirectory = trashDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return buildPreview(
            title: "Safe Delete Preview",
            changes: safeDeletePlans(for: items, batchDirectory: batchDirectory).map { plan in
                PlannedChange(
                    itemID: plan.item.id,
                    sourceURL: plan.item.url,
                    destinationURL: plan.trashURL,
                    summary: "Move \(plan.item.displayName) into ShelfDrop recovery trash"
                )
            },
            reviewItems: items
        )
    }

    public func executeSafeDelete(items: [ShelfItem]) throws -> BatchMutation {
        try ensureUniqueItemIDs(in: items)
        try fileManager.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        let batchDirectory = trashDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let plans = safeDeletePlans(for: items, batchDirectory: batchDirectory)
        try fileManager.createDirectory(at: batchDirectory, withIntermediateDirectories: true)

        return try executeItemBatch(
            title: "Safely deleted files",
            items: items,
            refreshedItemIDs: Set(items.map(\.id))
        ) { item, mutation in
            guard let plan = plans.first(where: { $0.item.id == item.id }) else { return nil }
            let step: UndoStep = try withAccessibleURL(for: item) { sourceURL in
                try fileManager.moveItem(at: sourceURL, to: plan.trashURL)
                return .restoreFromSafeDelete(original: sourceURL, trashURL: plan.trashURL, batchDirectory: batchDirectory)
            }
            mutation.removedItemIDs.insert(item.id)
            return step
        }
    }

    public nonisolated func previewZip(items: [ShelfItem], destinationDirectory: URL, baseName: String) -> BatchPreview {
        let outputURL = destinationDirectory.appendingPathComponent("\(baseName).zip")
        var issues = [PreflightIssue]()
        if fileManager.fileExists(atPath: outputURL.path) {
            issues.append(destinationConflictIssue(for: outputURL))
        }
        return buildPreview(
            title: "Zip Preview",
            changes: [PlannedChange(itemID: nil, sourceURL: destinationDirectory, destinationURL: outputURL, summary: "Create \(outputURL.lastPathComponent)")],
            reviewItems: items,
            extraIssues: issues
        )
    }

    public func executeZip(items: [ShelfItem], destinationDirectory: URL, baseName: String) throws -> BatchMutation {
        try ensureUniqueItemIDs(in: items)
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let outputURL = destinationDirectory.appendingPathComponent("\(baseName).zip")
        guard !fileManager.fileExists(atPath: outputURL.path) else {
            throw NSError(domain: "ShelfDrop.Zip", code: 1, userInfo: [NSLocalizedDescriptionKey: "Destination already exists for \(outputURL.lastPathComponent)."])
        }

        let staging = destinationDirectory.appendingPathComponent(".zip-staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        for item in items {
            try withAccessibleURL(for: item) { sourceURL in
                try fileManager.copyItem(at: sourceURL, to: staging.appendingPathComponent(sourceURL.lastPathComponent))
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", staging.path, outputURL.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ShelfDrop.Zip", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "ditto failed to create the ZIP archive."])
        }

        return finishCreatedFilesMutation(title: "Created ZIP", createdURLs: [outputURL])
    }

    public nonisolated func previewImageTransform(items: [ShelfItem], plan: ImageTransformPlan, destinationDirectory: URL) -> BatchPreview {
        let imageItems = items.filter(\.isImage)
        let skippedItems = items.filter { !$0.isImage }
        let outputs = imageItems.map {
            destinationDirectory.appendingPathComponent("\($0.url.deletingPathExtension().lastPathComponent).\(plan.outputFormat.fileExtension)")
        }
        let validationIssues = validationIssues(for: imageItems)
        let plannedDestinations = validationIssues.isEmpty ? makeDestinationMap(for: imageItems, destination: {
            destinationDirectory.appendingPathComponent("\($0.url.deletingPathExtension().lastPathComponent).\(plan.outputFormat.fileExtension)")
        }) : [:]
        let skippedIssues = skippedItems.map {
            PreflightIssue(
                itemID: $0.id,
                kind: .unsupportedSelection,
                severity: .warning,
                message: "\($0.displayName) is not an image and will be skipped."
            )
        }
        return buildPreview(
            title: "Image Transform Preview",
            changes: zip(imageItems, outputs).map {
                PlannedChange(itemID: $0.0.id, sourceURL: $0.0.url, destinationURL: $0.1, summary: "Create \($0.1.lastPathComponent)")
            },
            reviewItems: imageItems,
            plannedDestinations: plannedDestinations,
            extraIssues: skippedIssues + validationIssues
        )
    }

    public func executeImageTransform(items: [ShelfItem], plan: ImageTransformPlan, destinationDirectory: URL) throws -> BatchMutation {
        try ensureUniqueItemIDs(in: items)
        let outputs = try imageService.transform(items: items, plan: plan, destinationDirectory: destinationDirectory)
        return finishCreatedFilesMutation(title: "Converted images", createdURLs: outputs)
    }

    public nonisolated func previewPDF(from items: [ShelfItem], destinationDirectory: URL, baseName: String) -> BatchPreview {
        let outputURL = destinationDirectory.appendingPathComponent("\(baseName).pdf")
        var issues = [PreflightIssue]()
        if fileManager.fileExists(atPath: outputURL.path) {
            issues.append(destinationConflictIssue(for: outputURL))
        }
        return buildPreview(
            title: "Create PDF Preview",
            changes: [PlannedChange(itemID: nil, sourceURL: destinationDirectory, destinationURL: outputURL, summary: "Create \(outputURL.lastPathComponent) from \(items.count) image(s)")],
            reviewItems: items,
            extraIssues: issues
        )
    }

    public func executePDF(from items: [ShelfItem], destinationDirectory: URL, baseName: String) throws -> BatchMutation {
        try ensureUniqueItemIDs(in: items)
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let outputURL = destinationDirectory.appendingPathComponent("\(baseName).pdf")
        _ = try imageService.createPDF(from: items, destinationURL: outputURL)
        return finishCreatedFilesMutation(title: "Created PDF", createdURLs: [outputURL])
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
            case let .restoreFromSafeDelete(original, trashURL, _):
                if fileManager.fileExists(atPath: trashURL.path) {
                    try fileManager.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileManager.moveItem(at: trashURL, to: original)
                    mutation.restoredURLs.append(original)
                }
                try removeDirectoryIfEmpty(at: trashURL.deletingLastPathComponent())
                try removeDirectoryIfEmpty(at: trashDirectory)
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

    nonisolated private func archiveDestination(for item: ShelfItem, root: URL, strategy: ArchiveStrategy) -> URL {
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

    private func recordUndoBatch(title: String, steps: [UndoStep]) {
        undoBatches.append(.init(title: title, steps: steps))
        var discardedBatches = [UndoBatch]()

        while undoBatches.count > maxUndoBatches || undoBatches.totalStepCount > maxUndoSteps {
            discardedBatches.append(undoBatches.removeFirst())
        }

        for batch in discardedBatches {
            cleanupDiscardedUndoBatchResources(batch)
        }
    }

    private func finishCreatedFilesMutation(title: String, createdURLs: [URL]) -> BatchMutation {
        recordUndoBatch(title: title, steps: createdURLs.map(UndoStep.removeCreated))
        return BatchMutation(title: title, createdURLs: createdURLs)
    }

    private func removeDirectoryIfEmpty(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        if contents.isEmpty {
            try fileManager.removeItem(at: url)
        }
    }

    private func cleanupDiscardedUndoBatchResources(_ batch: UndoBatch) {
        let safeDeleteDirectories = Set(batch.steps.compactMap { step -> URL? in
            guard case let .restoreFromSafeDelete(_, _, batchDirectory) = step else {
                return nil
            }
            return batchDirectory
        })

        for directory in safeDeleteDirectories where fileManager.fileExists(atPath: directory.path) {
            try? fileManager.removeItem(at: directory)
        }
        try? removeDirectoryIfEmpty(at: trashDirectory)
    }

    nonisolated private func buildPreview(
        title: String,
        changes: [PlannedChange],
        reviewItems: [ShelfItem],
        plannedDestinations: [UUID: URL] = [:],
        extraIssues: [PreflightIssue] = []
    ) -> BatchPreview {
        let preflight = preflightService.review(items: reviewItems, plannedDestinations: plannedDestinations)
        return BatchPreview(
            title: title,
            changes: changes,
            issues: preflight.issues + extraIssues,
            duplicateGroups: preflight.duplicateGroups
        )
    }

    nonisolated private func preview(_ action: RelocationBatchAction) -> BatchPreview {
        let validationIssues = validationIssues(for: action.items)
        let plannedDestinations = validationIssues.isEmpty ? makeDestinationMap(for: action.items, destination: action.destination) : [:]
        let changes = action.items.map { item in
            let outputURL = action.destination(item)
            return PlannedChange(
                itemID: item.id,
                sourceURL: item.url,
                destinationURL: outputURL,
                summary: action.summary(item, outputURL)
            )
        }
        return buildPreview(
            title: action.title,
            changes: changes,
            reviewItems: action.items,
            plannedDestinations: plannedDestinations,
            extraIssues: validationIssues
        )
    }

    private func execute(_ action: RelocationBatchAction) throws -> BatchMutation {
        try ensureUniqueItemIDs(in: action.items)
        return try executeItemBatch(
            title: action.mutationTitle,
            items: action.items,
            refreshedItemIDs: Set(action.items.map(\.id))
        ) { item, mutation in
            let outputURL = action.destination(item)
            if action.createParentDirectories {
                try fileManager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            guard !fileManager.fileExists(atPath: outputURL.path) else {
                throw action.conflictError(item, outputURL)
            }

            let step: UndoStep = try withAccessibleURL(for: item) { sourceURL in
                switch action.operation {
                case .move:
                    try fileManager.moveItem(at: sourceURL, to: outputURL)
                    return .move(from: sourceURL, to: outputURL)
                case .copy:
                    try fileManager.copyItem(at: sourceURL, to: outputURL)
                    return .removeCreated(outputURL)
                }
            }

            switch action.operation {
            case .move:
                mutation.updatedItemLocations[item.id] = outputURL
            case .copy:
                mutation.createdURLs.append(outputURL)
            }
            return step
        }
    }

    private func executeItemBatch(
        title: String,
        items: [ShelfItem],
        refreshedItemIDs: Set<UUID> = [],
        body: (ShelfItem, inout BatchMutation) throws -> UndoStep?
    ) throws -> BatchMutation {
        var mutation = BatchMutation(title: title, refreshedItemIDs: refreshedItemIDs)
        var undoSteps = [UndoStep]()

        for item in items {
            if let step = try body(item, &mutation) {
                undoSteps.append(step)
            }
        }

        recordUndoBatch(title: mutation.title, steps: undoSteps)
        return mutation
    }

    nonisolated private func destinationConflictIssue(for url: URL) -> PreflightIssue {
        PreflightIssue(
            itemID: nil,
            kind: .destinationConflict,
            severity: .error,
            message: "Destination already exists for \(url.lastPathComponent)."
        )
    }

    nonisolated private func validationIssues(for items: [ShelfItem]) -> [PreflightIssue] {
        duplicateItemIDIssue(in: items).map { [$0] } ?? []
    }

    nonisolated private func duplicateItemIDIssue(in items: [ShelfItem]) -> PreflightIssue? {
        let uniqueIDs = Set(items.map(\.id))
        guard uniqueIDs.count != items.count else { return nil }
        return PreflightIssue(
            itemID: nil,
            kind: .internalValidation,
            severity: .error,
            message: "Some selected shelf items share the same internal ID. Remove and re-add them before running this batch."
        )
    }

    nonisolated private func ensureUniqueItemIDs(in items: [ShelfItem]) throws {
        guard duplicateItemIDIssue(in: items) == nil else {
            throw NSError(
                domain: "ShelfDrop.Validation",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Some selected shelf items share the same internal ID. Remove and re-add them before running this batch."]
            )
        }
    }

    nonisolated private func makeDestinationMap(
        for items: [ShelfItem],
        destination: (ShelfItem) -> URL
    ) -> [UUID: URL] {
        var destinations = [UUID: URL]()
        destinations.reserveCapacity(items.count)
        for item in items {
            destinations[item.id] = destination(item)
        }
        return destinations
    }

    nonisolated private func makeDestinationMap<Entry>(
        for entries: [Entry],
        id: KeyPath<Entry, UUID>,
        destination: KeyPath<Entry, URL>
    ) -> [UUID: URL] {
        var destinations = [UUID: URL]()
        destinations.reserveCapacity(entries.count)
        for entry in entries {
            destinations[entry[keyPath: id]] = entry[keyPath: destination]
        }
        return destinations
    }

    nonisolated private func makeItemMap(for items: [ShelfItem]) -> [UUID: ShelfItem] {
        var itemsByID = [UUID: ShelfItem]()
        itemsByID.reserveCapacity(items.count)
        for item in items {
            itemsByID[item.id] = item
        }
        return itemsByID
    }

    nonisolated private func safeDeletePlans(for items: [ShelfItem], batchDirectory: URL) -> [SafeDeletePlanEntry] {
        var usedNames = Set<String>()
        return items.map { item in
            let filename = uniquedFilename(for: item.url.lastPathComponent, usedNames: &usedNames)
            return SafeDeletePlanEntry(item: item, trashURL: batchDirectory.appendingPathComponent(filename))
        }
    }

    nonisolated private func uniquedFilename(for originalName: String, usedNames: inout Set<String>) -> String {
        guard !usedNames.contains(originalName) else {
            let url = URL(fileURLWithPath: originalName)
            let stem = url.deletingPathExtension().lastPathComponent
            let fileExtension = url.pathExtension
            var counter = 2
            while true {
                let candidate = fileExtension.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(fileExtension)"
                if usedNames.insert(candidate).inserted {
                    return candidate
                }
                counter += 1
            }
        }
        usedNames.insert(originalName)
        return originalName
    }

}

private struct RelocationBatchAction {
    let title: String
    let mutationTitle: String
    let items: [ShelfItem]
    let destination: (ShelfItem) -> URL
    let summary: (ShelfItem, URL) -> String
    let createParentDirectories: Bool
    let conflictError: (ShelfItem, URL) -> NSError
    let operation: RelocationOperation
}

private enum RelocationOperation {
    case move
    case copy
}

private struct UndoBatch: Sendable {
    let title: String
    let steps: [UndoStep]
}

private extension Array where Element == UndoBatch {
    var totalStepCount: Int {
        reduce(0) { $0 + $1.steps.count }
    }
}

private struct SafeDeletePlanEntry: Sendable {
    let item: ShelfItem
    let trashURL: URL
}

private enum UndoStep: Sendable {
    case move(from: URL, to: URL)
    case restoreFromSafeDelete(original: URL, trashURL: URL, batchDirectory: URL)
    case removeCreated(URL)
    case restoreMetadata(url: URL, snapshot: FinderMetadataSnapshot)
}
