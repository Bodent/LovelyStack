import AppKit
import Foundation
import ShelfDropCore

@MainActor
final class AppContainer: ObservableObject {
    static let shared = AppContainer()

    let supportDirectory: URL
    let store: ShelfStore
    let catalog: FileCatalogService
    let actions: FileActionService
    @Published var model: ShelfViewModel
    private var externalChangeObserver: NSObjectProtocol?

    private init() {
        let supportRoot = SharedShelfStorage.baseDirectory()
        self.supportDirectory = supportRoot
        self.store = ShelfStore(baseDirectory: supportRoot)
        self.catalog = FileCatalogService()
        self.actions = FileActionService(baseDirectory: supportRoot)
        self.model = ShelfViewModel(store: store, catalog: catalog, actions: actions)
        let model = self.model
        self.externalChangeObserver = DistributedNotificationCenter.default().addObserver(
            forName: ShelfStateChangeBroadcaster.notificationName,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                model.reloadFromStore()
            }
        }
    }
}

@MainActor
final class ShelfViewModel: ObservableObject {
    @Published var sessions: [ShelfSession]
    @Published var selectedSessionID: UUID
    @Published var selectedItemIDs = Set<UUID>()
    @Published var recentDestinations: [URL]
    @Published var review: BatchPreview = .init(title: "Review", changes: [], issues: [], duplicateGroups: [])
    @Published var pendingPreview: PendingPreview?
    @Published var errorMessage: String?
    @Published var searchText = "" {
        didSet {
            rebuildVisibleItems()
        }
    }
    @Published var renamePattern = RenamePattern()
    @Published var metadataRequest = MetadataEditRequest()
    @Published var imageTransformPlan = ImageTransformPlan()
    @Published var archiveStrategy: ArchiveStrategy = .createdMonth
    @Published var isBusy = false
    @Published private(set) var visibleItems: [ShelfItem] = []
    private(set) var loadWarning: String?
    private var selectedSessionSearchIndex = [UUID: String]()

    private let store: ShelfStore
    private let catalog: FileCatalogService
    private let actions: FileActionService
    private let ingest: ShelfIngestService

    init(store: ShelfStore, catalog: FileCatalogService, actions: FileActionService) {
        self.store = store
        self.catalog = catalog
        self.actions = actions
        self.ingest = ShelfIngestService(store: store, catalog: catalog)

        let loadResult = store.load()
        self.loadWarning = loadResult.warning

        let snapshot = Self.normalizedSnapshot(
            from: loadResult.snapshot,
            refreshItems: true,
            catalog: catalog
        )
        self.sessions = snapshot.sessions
        self.selectedSessionID = snapshot.selectedSessionID ?? snapshot.sessions[0].id
        self.recentDestinations = snapshot.recentDestinations
        if loadResult.warning == nil {
            persist()
        }
        rebuildVisibleItems()
        recalculateReview()
    }

    var selectedSessionIndex: Int {
        sessions.firstIndex(where: { $0.id == selectedSessionID }) ?? 0
    }

    var selectedSession: ShelfSession {
        get { sessions[selectedSessionIndex] }
        set { sessions[selectedSessionIndex] = newValue }
    }

    var selectedItems: [ShelfItem] {
        selectedSession.items.filter { selectedItemIDs.contains($0.id) }
    }

    var pinnedSessions: [ShelfSession] {
        sessions.filter(\.isPinned)
    }

    var recentSessions: [ShelfSession] {
        sessions.filter { !$0.isPinned }
    }

    @Published var canUndo: Bool = false

    func createShelf() {
        sessions.insert(ShelfSession(title: "Shelf \(sessions.count + 1)"), at: 0)
        selectedSessionID = sessions[0].id
        selectedItemIDs.removeAll()
        persist()
        rebuildVisibleItems()
        recalculateReview()
    }

    func deleteShelf(sessionID: UUID) {
        guard let deleteIndex = sessions.firstIndex(where: { $0.id == sessionID }) else { return }

        let deletingSelectedShelf = selectedSessionID == sessionID
        sessions.remove(at: deleteIndex)

        if sessions.isEmpty {
            let replacement = ShelfSession()
            sessions = [replacement]
            selectedSessionID = replacement.id
            selectedItemIDs.removeAll()
            persist()
            rebuildVisibleItems()
            recalculateReview()
            return
        }

        if deletingSelectedShelf {
            let replacementIndex = min(deleteIndex, sessions.count - 1)
            selectedSessionID = sessions[replacementIndex].id
            selectedItemIDs.removeAll()
        }

        persist()
        rebuildVisibleItems()
        recalculateReview()
    }

    func togglePinSelectedShelf() {
        selectedSession.isPinned.toggle()
        selectedSession.updatedAt = Date()
        persist()
    }

    func renameSelectedShelf(_ title: String) {
        _ = renameSelectedShelfTitle(title)
    }

    @discardableResult
    func renameSelectedShelfTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return selectedSession.title
        }

        selectedSession.title = trimmed
        selectedSession.updatedAt = Date()
        persist()
        return selectedSession.title
    }

    func select(sessionID: UUID) {
        selectedSessionID = sessionID
        selectedItemIDs.removeAll()
        persist()
        rebuildVisibleItems()
        recalculateReview()
    }

    func addFiles(urls: [URL]) {
        guard !urls.isEmpty else { return }
        do {
            let result = try ingest.add(urls: urls, targetSessionID: selectedSessionID)
            guard !result.addedItems.isEmpty else { return }
            applySnapshot(result.snapshot, refreshItems: false, preserveSelectedItems: false)
            selectedItemIDs = Set(result.addedItems.map(\.id))
            rebuildVisibleItems()
            recalculateReview()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeSelectedFromShelf() {
        guard !selectedItemIDs.isEmpty else { return }
        selectedSession.items.removeAll { selectedItemIDs.contains($0.id) }
        selectedSession.updatedAt = Date()
        selectedItemIDs.removeAll()
        persist()
        rebuildVisibleItems()
        recalculateReview()
    }

    func clearShelf() {
        selectedSession.items.removeAll()
        selectedSession.updatedAt = Date()
        selectedItemIDs.removeAll()
        persist()
        rebuildVisibleItems()
        recalculateReview()
    }

    func revealSelectedInFinder() {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func copySelectedPaths() {
        let paths = selectedItems.map(\.url.path).joined(separator: "\n")
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths, forType: .string)
    }

    func openQuickLook() {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        if urls.count == 1 {
            NSWorkspace.shared.open(urls[0])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    func performUndo() {
        runAction(
            operation: { actions in
                try await actions.undoLastBatch()
            },
            applyResult: { mutation in
                if let mutation {
                    self.apply(mutation)
                }
            }
        )
    }

    func previewMove(destination: URL, mode: FileOperationMode) {
        let items = selectedItems
        let preview = actions.previewMove(items: items, to: destination, mode: mode)
        presentPreview(
            preview,
            action: .move(sessionID: selectedSessionID, itemIDs: items.map(\.id), destination: destination, mode: mode)
        )
    }

    func previewArchive(root: URL) {
        let items = selectedItems
        let strategy = archiveStrategy
        let preview = actions.previewArchive(items: items, root: root, strategy: strategy)
        presentPreview(
            preview,
            action: .archive(sessionID: selectedSessionID, itemIDs: items.map(\.id), root: root, strategy: strategy)
        )
    }

    func previewRename() {
        let items = selectedItems
        let pattern = renamePattern
        let preview = actions.previewRename(items: items, pattern: pattern)
        presentPreview(
            preview,
            action: .rename(sessionID: selectedSessionID, itemIDs: items.map(\.id), pattern: pattern)
        )
    }

    func previewMetadata() {
        let items = selectedItems
        let request = metadataRequest
        let preview = actions.previewMetadata(items: items, request: request)
        presentPreview(
            preview,
            action: .metadata(sessionID: selectedSessionID, itemIDs: items.map(\.id), request: request)
        )
    }

    func previewSafeDelete() {
        let items = selectedItems
        let preview = actions.previewSafeDelete(items: items)
        presentPreview(
            preview,
            action: .safeDelete(sessionID: selectedSessionID, itemIDs: items.map(\.id))
        )
    }

    func previewZip(destination: URL, baseName: String) {
        let items = selectedItems
        let preview = actions.previewZip(items: items, destinationDirectory: destination, baseName: baseName)
        presentPreview(
            preview,
            action: .zip(sessionID: selectedSessionID, itemIDs: items.map(\.id), destination: destination, baseName: baseName)
        )
    }

    func previewImageTransform(destination: URL) {
        let items = selectedItems
        let plan = imageTransformPlan
        let preview = actions.previewImageTransform(items: items, plan: plan, destinationDirectory: destination)
        presentPreview(
            preview,
            action: .imageTransform(sessionID: selectedSessionID, itemIDs: items.map(\.id), plan: plan, destination: destination)
        )
    }

    func previewCreatePDF(destination: URL, baseName: String) {
        let items = selectedItems
        let preview = actions.previewPDF(from: items, destinationDirectory: destination, baseName: baseName)
        presentPreview(
            preview,
            action: .createPDF(sessionID: selectedSessionID, itemIDs: items.map(\.id), destination: destination, baseName: baseName)
        )
    }

    func dismissPreview() {
        pendingPreview = nil
    }

    func confirmPendingPreview() {
        guard let pendingPreview else { return }
        guard let items = resolveItems(for: pendingPreview.action) else {
            self.pendingPreview = nil
            errorMessage = "The selected items changed after this preview was generated. Run the preview again before executing."
            return
        }

        switch pendingPreview.action {
        case let .move(_, _, destination, mode):
            runAction(
                operation: { actions in
                    try await actions.executeMove(items: items, to: destination, mode: mode)
                },
                applyResult: { mutation in
                    self.remember(destination: destination)
                    self.apply(mutation)
                }
            )
        case let .archive(_, _, root, strategy):
            runAction(
                operation: { actions in
                    try await actions.executeArchive(items: items, root: root, strategy: strategy)
                },
                applyResult: { mutation in
                    self.remember(destination: root)
                    self.apply(mutation)
                }
            )
        case let .rename(_, _, pattern):
            runAction(
                operation: { actions in
                    try await actions.executeRename(items: items, pattern: pattern)
                },
                applyResult: { mutation in
                    self.apply(mutation)
                }
            )
        case let .metadata(_, _, request):
            runAction(
                operation: { actions in
                    try await actions.executeMetadata(items: items, request: request)
                },
                applyResult: { mutation in
                    self.apply(mutation)
                }
            )
        case .safeDelete:
            runAction(
                operation: { actions in
                    try await actions.executeSafeDelete(items: items)
                },
                applyResult: { mutation in
                    self.apply(mutation)
                }
            )
        case let .zip(_, _, destination, baseName):
            runAction(
                operation: { actions in
                    try await actions.executeZip(items: items, destinationDirectory: destination, baseName: baseName)
                },
                applyResult: { mutation in
                    self.remember(destination: destination)
                    self.apply(mutation)
                }
            )
        case let .imageTransform(_, _, plan, destination):
            runAction(
                operation: { actions in
                    try await actions.executeImageTransform(items: items, plan: plan, destinationDirectory: destination)
                },
                applyResult: { mutation in
                    self.remember(destination: destination)
                    self.apply(mutation)
                }
            )
        case let .createPDF(_, _, destination, baseName):
            runAction(
                operation: { actions in
                    try await actions.executePDF(from: items, destinationDirectory: destination, baseName: baseName)
                },
                applyResult: { mutation in
                    self.remember(destination: destination)
                    self.apply(mutation)
                }
            )
        }
    }

    func reloadFromStore() {
        let loadResult = store.load()
        loadWarning = loadResult.warning

        if let warning = loadResult.warning {
            errorMessage = warning
        }

        applySnapshot(loadResult.snapshot, refreshItems: true, preserveSelectedItems: true)
    }

    private func remember(destination: URL) {
        recentDestinations.removeAll { $0 == destination }
        recentDestinations.insert(destination, at: 0)
        recentDestinations = Array(recentDestinations.prefix(6))
        persist()
    }

    private func presentPreview(_ preview: BatchPreview, action: PendingBatchAction) {
        pendingPreview = PendingPreview(preview: preview, action: action)
    }

    private func runAction<Result: Sendable>(
        operation: @escaping @Sendable (FileActionService) async throws -> Result,
        applyResult: @escaping (Result) -> Void
    ) {
        isBusy = true
        let actions = self.actions
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try await operation(actions)
                }.value
                applyResult(result)
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
            pendingPreview = nil
            canUndo = await actions.canUndo
        }
    }

    private func apply(_ mutation: BatchMutation) {
        var updatedItems = selectedSession.items

        updatedItems.removeAll { mutation.removedItemIDs.contains($0.id) || mutation.removedURLs.contains($0.url) }
        updatedItems = updatedItems.map { item in
            var updated = item
            if let newURL = mutation.updatedItemLocations[item.id] {
                updated.url = newURL
                return catalog.refresh(item: updated) ?? updated
            }
            if mutation.refreshedItemIDs.contains(item.id) {
                return catalog.refresh(item: item) ?? item
            }
            return item
        }

        let additions = catalog.makeShelfItems(urls: mutation.createdURLs + mutation.restoredURLs)
        let existingURLs = Set(updatedItems.map(\.url))
        let filteredAdditions = additions.filter { !existingURLs.contains($0.url) }
        updatedItems.append(contentsOf: filteredAdditions)

        selectedSession.items = updatedItems.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        selectedSession.updatedAt = Date()
        selectedItemIDs.subtract(mutation.removedItemIDs)
        persist()
        rebuildVisibleItems()
        recalculateReview()
    }

    private func recalculateReview() {
        review = actions.review(items: selectedSession.items)
    }

    private func applySnapshot(_ snapshot: AppSnapshot, refreshItems: Bool, preserveSelectedItems: Bool) {
        let previousSelectedItems = selectedItemIDs
        let normalized = Self.normalizedSnapshot(
            from: snapshot,
            refreshItems: refreshItems,
            catalog: catalog
        )

        sessions = normalized.sessions
        selectedSessionID = normalized.selectedSessionID ?? normalized.sessions[0].id
        recentDestinations = normalized.recentDestinations

        if preserveSelectedItems {
            let validItemIDs = Set(selectedSession.items.map(\.id))
            selectedItemIDs = previousSelectedItems.intersection(validItemIDs)
        } else {
            selectedItemIDs.removeAll()
        }

        rebuildVisibleItems()
        recalculateReview()
    }

    private func resolveItems(for action: PendingBatchAction) -> [ShelfItem]? {
        guard let session = sessions.first(where: { $0.id == action.sessionID }) else {
            return nil
        }

        let itemsByID = Dictionary(uniqueKeysWithValues: session.items.map { ($0.id, $0) })
        let items = action.itemIDs.compactMap { itemsByID[$0] }
        guard items.count == action.itemIDs.count else {
            return nil
        }
        return items
    }

    private static func normalizedSnapshot(
        from snapshot: AppSnapshot,
        refreshItems: Bool,
        catalog: FileCatalogService
    ) -> AppSnapshot {
        let restoredSessions = snapshot.sessions.isEmpty ? [ShelfSession()] : snapshot.sessions
        let normalizedSessions = refreshItems
            ? restoredSessions.map { refreshSession($0, catalog: catalog) }
            : restoredSessions
        let selectedSessionID = normalizedSessions.contains(where: { $0.id == snapshot.selectedSessionID })
            ? snapshot.selectedSessionID
            : normalizedSessions[0].id

        return AppSnapshot(
            sessions: normalizedSessions,
            recentDestinations: snapshot.recentDestinations,
            selectedSessionID: selectedSessionID
        )
    }

    private static func refreshSession(_ session: ShelfSession, catalog: FileCatalogService) -> ShelfSession {
        var refreshedSession = session
        refreshedSession.items = session.items.map { item in
            catalog.refresh(item: item) ?? item
        }
        return refreshedSession
    }

    private func persist() {
        do {
            let snapshot = AppSnapshot(
                sessions: sessions,
                recentDestinations: recentDestinations,
                selectedSessionID: selectedSessionID
            )
            try store.save(snapshot)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func rebuildVisibleItems() {
        let items = selectedSession.items
        selectedSessionSearchIndex = Dictionary(uniqueKeysWithValues: items.map { item in
            (item.id, searchableText(for: item))
        })

        let query = normalizedSearchQuery(searchText)
        guard !query.isEmpty else {
            visibleItems = items
            return
        }

        visibleItems = items.filter { item in
            selectedSessionSearchIndex[item.id]?.contains(query) == true
        }
    }

    private func searchableText(for item: ShelfItem) -> String {
        ([item.displayName, item.kindDescription] + item.tags)
            .joined(separator: " ")
            .localizedLowercase
    }

    private func normalizedSearchQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
    }
}

struct PendingPreview: Identifiable {
    let id = UUID()
    let preview: BatchPreview
    let action: PendingBatchAction
}

enum PendingBatchAction {
    case move(sessionID: UUID, itemIDs: [UUID], destination: URL, mode: FileOperationMode)
    case archive(sessionID: UUID, itemIDs: [UUID], root: URL, strategy: ArchiveStrategy)
    case rename(sessionID: UUID, itemIDs: [UUID], pattern: RenamePattern)
    case metadata(sessionID: UUID, itemIDs: [UUID], request: MetadataEditRequest)
    case safeDelete(sessionID: UUID, itemIDs: [UUID])
    case zip(sessionID: UUID, itemIDs: [UUID], destination: URL, baseName: String)
    case imageTransform(sessionID: UUID, itemIDs: [UUID], plan: ImageTransformPlan, destination: URL)
    case createPDF(sessionID: UUID, itemIDs: [UUID], destination: URL, baseName: String)

    var sessionID: UUID {
        switch self {
        case let .move(sessionID, _, _, _),
             let .archive(sessionID, _, _, _),
             let .rename(sessionID, _, _),
             let .metadata(sessionID, _, _),
             let .safeDelete(sessionID, _),
             let .zip(sessionID, _, _, _),
             let .imageTransform(sessionID, _, _, _),
             let .createPDF(sessionID, _, _, _):
            sessionID
        }
    }

    var itemIDs: [UUID] {
        switch self {
        case let .move(_, itemIDs, _, _),
             let .archive(_, itemIDs, _, _),
             let .rename(_, itemIDs, _),
             let .metadata(_, itemIDs, _),
             let .safeDelete(_, itemIDs),
             let .zip(_, itemIDs, _, _),
             let .imageTransform(_, itemIDs, _, _),
             let .createPDF(_, itemIDs, _, _):
            itemIDs
        }
    }
}
