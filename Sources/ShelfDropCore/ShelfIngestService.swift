import Foundation
#if canImport(UserNotifications)
@preconcurrency import UserNotifications
#endif

public enum ShelfSharedConfiguration {
    public static let appGroupIdentifier = "group.com.lovelystack.shared"
    public static let supportDirectoryName = "LovelyStack"
    public static let stateDidChangeNotificationName = "com.lovelystack.ShelfDrop.stateDidChange"
}

public enum SharedShelfStorage {
    public static func baseDirectory(fileManager: FileManager = .default) -> URL {
        if let appGroupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: ShelfSharedConfiguration.appGroupIdentifier) {
            return appGroupURL.appendingPathComponent(ShelfSharedConfiguration.supportDirectoryName, isDirectory: true)
        }

        if let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return appSupportURL.appendingPathComponent(ShelfSharedConfiguration.supportDirectoryName, isDirectory: true)
        }

        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(ShelfSharedConfiguration.supportDirectoryName, isDirectory: true)
    }
}

public enum ShelfStateChangeBroadcaster {
    public static let notificationName = Notification.Name(ShelfSharedConfiguration.stateDidChangeNotificationName)

    public static func post() {
        DistributedNotificationCenter.default().postNotificationName(
            notificationName,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}

public struct ShelfIngestResult: Sendable {
    public let addedItems: [ShelfItem]
    public let duplicateCount: Int
    public let skippedCount: Int
    public let targetSessionID: UUID
    public let targetTitle: String
    public let snapshot: AppSnapshot

    public init(
        addedItems: [ShelfItem],
        duplicateCount: Int,
        skippedCount: Int,
        targetSessionID: UUID,
        targetTitle: String,
        snapshot: AppSnapshot
    ) {
        self.addedItems = addedItems
        self.duplicateCount = duplicateCount
        self.skippedCount = skippedCount
        self.targetSessionID = targetSessionID
        self.targetTitle = targetTitle
        self.snapshot = snapshot
    }

    public var addedCount: Int {
        addedItems.count
    }
}

public final class ShelfIngestService {
    private let store: ShelfStore
    private let catalog: FileCatalogService

    public init(store: ShelfStore, catalog: FileCatalogService = FileCatalogService()) {
        self.store = store
        self.catalog = catalog
    }

    public func add(urls: [URL], targetSessionID: UUID? = nil) throws -> ShelfIngestResult {
        let loadResult = store.load()
        var snapshot = loadResult.snapshot

        if snapshot.sessions.isEmpty {
            let replacement = ShelfSession()
            snapshot.sessions = [replacement]
            snapshot.selectedSessionID = replacement.id
        }

        let requestedTargetID = targetSessionID ?? snapshot.selectedSessionID
        let sessionIndex = snapshot.sessions.firstIndex(where: { $0.id == requestedTargetID }) ?? 0

        let loadedItems = catalog.makeShelfItems(urls: urls)
        var session = snapshot.sessions[sessionIndex]
        var existingURLs = Set(session.items.map(\.url))
        let dedupedItems = loadedItems.filter { existingURLs.insert($0.url).inserted }

        session.items.append(contentsOf: dedupedItems)
        if !dedupedItems.isEmpty {
            session.updatedAt = Date()
        }

        snapshot.sessions[sessionIndex] = session
        snapshot.selectedSessionID = session.id
        try store.save(snapshot)

        return ShelfIngestResult(
            addedItems: dedupedItems,
            duplicateCount: loadedItems.count - dedupedItems.count,
            skippedCount: max(0, urls.count - loadedItems.count),
            targetSessionID: session.id,
            targetTitle: session.title,
            snapshot: snapshot
        )
    }
}

public enum ShelfIngestFeedback {
    public static func scheduleSuccess(result: ShelfIngestResult) {
        let body: String
        switch (result.addedCount, result.duplicateCount, result.skippedCount) {
        case (0, let duplicates, let skipped) where duplicates > 0 || skipped > 0:
            body = "No new items were added to \(result.targetTitle). \(duplicates) duplicate(s), \(skipped) skipped."
        default:
            body = "\(result.addedCount) item(s) added to \(result.targetTitle). \(result.duplicateCount) duplicate(s), \(result.skippedCount) skipped."
        }

        schedule(title: "ShelfDrop", body: body)
    }

    public static func scheduleFailure(message: String) {
        schedule(title: "ShelfDrop could not add files", body: message)
    }

    private static func schedule(title: String, body: String) {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = nil

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
            )
            center.add(request)
        }
        #endif
    }
}
