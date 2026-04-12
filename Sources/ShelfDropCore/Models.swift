import Foundation
import UniformTypeIdentifiers

public struct ShelfItem: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var url: URL
    public var bookmarkData: Data?
    public var displayName: String
    public var fileExtension: String
    public var kindDescription: String
    public var byteSize: Int64
    public var createdAt: Date?
    public var modifiedAt: Date?
    public var isDirectory: Bool
    public var isPackage: Bool
    public var isAlias: Bool
    public var isUbiquitous: Bool
    public var isExternalVolume: Bool
    public var isLocked: Bool
    public var isReachable: Bool
    public var tags: [String]

    public init(
        id: UUID = UUID(),
        url: URL,
        bookmarkData: Data? = nil,
        displayName: String,
        fileExtension: String,
        kindDescription: String,
        byteSize: Int64,
        createdAt: Date?,
        modifiedAt: Date?,
        isDirectory: Bool,
        isPackage: Bool,
        isAlias: Bool,
        isUbiquitous: Bool,
        isExternalVolume: Bool,
        isLocked: Bool,
        isReachable: Bool,
        tags: [String]
    ) {
        self.id = id
        self.url = url
        self.bookmarkData = bookmarkData
        self.displayName = displayName
        self.fileExtension = fileExtension
        self.kindDescription = kindDescription
        self.byteSize = byteSize
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isAlias = isAlias
        self.isUbiquitous = isUbiquitous
        self.isExternalVolume = isExternalVolume
        self.isLocked = isLocked
        self.isReachable = isReachable
        self.tags = tags
    }

    public var isImage: Bool {
        UTType(filenameExtension: fileExtension)?.conforms(to: .image) ?? false
    }

    public var isPDF: Bool {
        UTType(filenameExtension: fileExtension)?.conforms(to: .pdf) ?? false
    }

    public var isArchiveCandidate: Bool {
        !isDirectory && !isPackage
    }
}

public struct ShelfSession: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var isPinned: Bool
    public var items: [ShelfItem]

    public init(
        id: UUID = UUID(),
        title: String = "New Shelf",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isPinned: Bool = false,
        items: [ShelfItem] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        self.items = items
    }
}

public enum FinderLabelColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case gray
    case green
    case purple
    case blue
    case yellow
    case red
    case orange

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: "None"
        case .gray: "Gray"
        case .green: "Green"
        case .purple: "Purple"
        case .blue: "Blue"
        case .yellow: "Yellow"
        case .red: "Red"
        case .orange: "Orange"
        }
    }

    public var finderIndex: Int {
        switch self {
        case .none: 0
        case .gray: 1
        case .green: 2
        case .purple: 3
        case .blue: 4
        case .yellow: 5
        case .red: 6
        case .orange: 7
        }
    }

    public init(finderIndex: Int) {
        switch finderIndex {
        case 1: self = .gray
        case 2: self = .green
        case 3: self = .purple
        case 4: self = .blue
        case 5: self = .yellow
        case 6: self = .red
        case 7: self = .orange
        default: self = .none
        }
    }
}

public struct MetadataEditRequest: Codable, Hashable, Sendable {
    public var tags: [String]
    public var comment: String?
    public var label: FinderLabelColor

    public init(tags: [String] = [], comment: String? = nil, label: FinderLabelColor = .none) {
        self.tags = tags
        self.comment = comment
        self.label = label
    }
}

public enum RenameCaseStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case keep
    case lower
    case upper
    case title

    public var id: String { rawValue }
}

public enum RenameSeparator: String, Codable, CaseIterable, Identifiable, Sendable {
    case space = " "
    case dash = "-"
    case underscore = "_"

    public var id: String { rawValue }

    public var joiner: String { rawValue }

    public var displayName: String {
        switch self {
        case .space: "Space"
        case .dash: "Dash"
        case .underscore: "Underscore"
        }
    }
}

public enum RenameDateSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case created
    case modified

    public var id: String { rawValue }
}

public struct RenamePattern: Codable, Hashable, Sendable {
    public var prefixesToRemove: [String]
    public var textToRemove: [String]
    public var separator: RenameSeparator
    public var caseStyle: RenameCaseStyle
    public var includeCounter: Bool
    public var counterStart: Int
    public var dateSource: RenameDateSource
    public var customPrefix: String
    public var customSuffix: String

    public init(
        prefixesToRemove: [String] = ["IMG_", "DSC_", "Screenshot "],
        textToRemove: [String] = [],
        separator: RenameSeparator = .underscore,
        caseStyle: RenameCaseStyle = .keep,
        includeCounter: Bool = false,
        counterStart: Int = 1,
        dateSource: RenameDateSource = .none,
        customPrefix: String = "",
        customSuffix: String = ""
    ) {
        self.prefixesToRemove = prefixesToRemove
        self.textToRemove = textToRemove
        self.separator = separator
        self.caseStyle = caseStyle
        self.includeCounter = includeCounter
        self.counterStart = counterStart
        self.dateSource = dateSource
        self.customPrefix = customPrefix
        self.customSuffix = customSuffix
    }
}

public enum ArchiveStrategy: String, Codable, CaseIterable, Identifiable, Sendable {
    case createdMonth
    case modifiedMonth
    case fileType

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .createdMonth: "Created Month"
        case .modifiedMonth: "Modified Month"
        case .fileType: "File Type"
        }
    }
}

public enum FileOperationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case move
    case copy

    public var id: String { rawValue }
}

public enum ImageOutputFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case jpeg
    case png
    case tiff

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .png: "png"
        case .tiff: "tiff"
        }
    }

    public var utiIdentifier: CFString {
        switch self {
        case .jpeg: "public.jpeg" as CFString
        case .png: "public.png" as CFString
        case .tiff: "public.tiff" as CFString
        }
    }
}

public struct ImageTransformPlan: Codable, Hashable, Sendable {
    public var outputFormat: ImageOutputFormat
    public var maxPixelSize: Int?
    public var compressionQuality: Double
    public var stripMetadata: Bool

    public init(
        outputFormat: ImageOutputFormat = .jpeg,
        maxPixelSize: Int? = nil,
        compressionQuality: Double = 0.82,
        stripMetadata: Bool = true
    ) {
        self.outputFormat = outputFormat
        self.maxPixelSize = maxPixelSize
        self.compressionQuality = compressionQuality
        self.stripMetadata = stripMetadata
    }
}

public enum PreflightSeverity: String, Hashable, Codable, Sendable {
    case warning
    case error
}

public enum PreflightIssueKind: String, Hashable, Codable, Sendable {
    case duplicate
    case duplicateCheckUnavailable
    case destinationConflict
    case internalValidation
    case lockedFile
    case unreachable
    case alias
    case iCloudPlaceholder
    case externalVolume
    case unsupportedSelection
}

public struct PreflightIssue: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let itemID: UUID?
    public let kind: PreflightIssueKind
    public let severity: PreflightSeverity
    public let message: String

    public init(
        id: UUID = UUID(),
        itemID: UUID?,
        kind: PreflightIssueKind,
        severity: PreflightSeverity,
        message: String
    ) {
        self.id = id
        self.itemID = itemID
        self.kind = kind
        self.severity = severity
        self.message = message
    }
}

public struct DuplicateGroup: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let itemIDs: [UUID]
    public let byteSize: Int64

    public init(id: String, itemIDs: [UUID], byteSize: Int64) {
        self.id = id
        self.itemIDs = itemIDs
        self.byteSize = byteSize
    }
}

public struct PlannedChange: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let itemID: UUID?
    public let sourceURL: URL
    public let destinationURL: URL?
    public let summary: String

    public init(
        id: UUID = UUID(),
        itemID: UUID?,
        sourceURL: URL,
        destinationURL: URL?,
        summary: String
    ) {
        self.id = id
        self.itemID = itemID
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.summary = summary
    }
}

public struct BatchPreview: Sendable {
    public var title: String
    public var changes: [PlannedChange]
    public var issues: [PreflightIssue]
    public var duplicateGroups: [DuplicateGroup]

    public init(
        title: String,
        changes: [PlannedChange],
        issues: [PreflightIssue],
        duplicateGroups: [DuplicateGroup]
    ) {
        self.title = title
        self.changes = changes
        self.issues = issues
        self.duplicateGroups = duplicateGroups
    }

    public var hasBlockingIssues: Bool {
        issues.contains(where: { $0.severity == .error })
    }
}

public struct BatchMutation: Sendable {
    public var title: String
    public var updatedItemLocations: [UUID: URL]
    public var removedItemIDs: Set<UUID>
    public var removedURLs: [URL]
    public var createdURLs: [URL]
    public var restoredURLs: [URL]
    public var refreshedItemIDs: Set<UUID>

    public init(
        title: String,
        updatedItemLocations: [UUID: URL] = [:],
        removedItemIDs: Set<UUID> = [],
        removedURLs: [URL] = [],
        createdURLs: [URL] = [],
        restoredURLs: [URL] = [],
        refreshedItemIDs: Set<UUID> = []
    ) {
        self.title = title
        self.updatedItemLocations = updatedItemLocations
        self.removedItemIDs = removedItemIDs
        self.removedURLs = removedURLs
        self.createdURLs = createdURLs
        self.restoredURLs = restoredURLs
        self.refreshedItemIDs = refreshedItemIDs
    }
}

public struct AppSnapshot: Codable, Sendable {
    public var sessions: [ShelfSession]
    public var recentDestinations: [URL]
    public var rememberedIngestTargetSessionID: UUID?

    public init(
        sessions: [ShelfSession],
        recentDestinations: [URL],
        rememberedIngestTargetSessionID: UUID? = nil
    ) {
        self.sessions = sessions
        self.recentDestinations = recentDestinations
        self.rememberedIngestTargetSessionID = rememberedIngestTargetSessionID
    }

    public var selectedSessionID: UUID? {
        get { rememberedIngestTargetSessionID }
        set { rememberedIngestTargetSessionID = newValue }
    }

    private enum CodingKeys: String, CodingKey {
        case sessions
        case recentDestinations
        case rememberedIngestTargetSessionID
        case selectedSessionID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try container.decode([ShelfSession].self, forKey: .sessions)
        recentDestinations = try container.decode([URL].self, forKey: .recentDestinations)
        rememberedIngestTargetSessionID =
            try container.decodeIfPresent(UUID.self, forKey: .rememberedIngestTargetSessionID)
            ?? container.decodeIfPresent(UUID.self, forKey: .selectedSessionID)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessions, forKey: .sessions)
        try container.encode(recentDestinations, forKey: .recentDestinations)
        try container.encodeIfPresent(rememberedIngestTargetSessionID, forKey: .rememberedIngestTargetSessionID)
        try container.encodeIfPresent(rememberedIngestTargetSessionID, forKey: .selectedSessionID)
    }
}
