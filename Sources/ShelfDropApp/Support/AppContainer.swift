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
    @Published var rememberedIngestTargetSessionID: UUID
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
        self.rememberedIngestTargetSessionID = snapshot.rememberedIngestTargetSessionID ?? snapshot.sessions[0].id
        self.recentDestinations = snapshot.recentDestinations
        if loadResult.warning == nil {
            persist()
        }
        rebuildVisibleItems()
        recalculateReview()
    }

    var selectedSessionIndex: Int {
        sessions.firstIndex(where: { $0.id == rememberedIngestTargetSessionID }) ?? 0
    }

    var selectedSession: ShelfSession {
        get { sessions[selectedSessionIndex] }
        set { sessions[selectedSessionIndex] = newValue }
    }

    var selectedSessionID: UUID {
        get { rememberedIngestTargetSessionID }
        set { rememberedIngestTargetSessionID = newValue }
    }

    var defaultSceneSelectionID: UUID {
        if sessions.contains(where: { $0.id == rememberedIngestTargetSessionID }) {
            return rememberedIngestTargetSessionID
        }
        return sessions[0].id
    }

    func session(matching sessionID: UUID) -> ShelfSession? {
        sessions.first(where: { $0.id == sessionID })
    }

    func items(in sessionID: UUID) -> [ShelfItem] {
        session(matching: sessionID)?.items ?? []
    }

    var selectedItems: [ShelfItem] {
        selectedSession.items.filter { selectedItemIDs.contains($0.id) }
    }

    func selectedItems(in sessionID: UUID, matching itemIDs: Set<UUID>) -> [ShelfItem] {
        items(in: sessionID).filter { itemIDs.contains($0.id) }
    }

    func review(for sessionID: UUID) -> BatchPreview {
        actions.review(items: items(in: sessionID))
    }

    var pinnedSessions: [ShelfSession] {
        sessions.filter(\.isPinned)
    }

    var recentSessions: [ShelfSession] {
        sessions.filter { !$0.isPinned }
    }

    @Published var canUndo: Bool = false

    @discardableResult
    func createShelf() -> UUID {
        sessions.insert(ShelfSession(title: "Shelf \(sessions.count + 1)"), at: 0)
        rememberedIngestTargetSessionID = sessions[0].id
        selectedItemIDs.removeAll()
        persist()
        rebuildVisibleItems()
        recalculateReview()
        return sessions[0].id
    }

    @discardableResult
    func deleteShelf(sessionID: UUID) -> UUID {
        guard let deleteIndex = sessions.firstIndex(where: { $0.id == sessionID }) else {
            return defaultSceneSelectionID
        }

        let deletingRememberedTarget = rememberedIngestTargetSessionID == sessionID
        sessions.remove(at: deleteIndex)

        if sessions.isEmpty {
            let replacement = ShelfSession()
            sessions = [replacement]
            rememberedIngestTargetSessionID = replacement.id
            selectedItemIDs.removeAll()
            persist()
            rebuildVisibleItems()
            recalculateReview()
            return replacement.id
        }

        let replacementIndex = min(deleteIndex, sessions.count - 1)
        let replacementSelectionID = sessions[replacementIndex].id

        if deletingRememberedTarget {
            rememberedIngestTargetSessionID = replacementSelectionID
            selectedItemIDs.removeAll()
        }

        persist()
        rebuildVisibleItems()
        recalculateReview()
        return replacementSelectionID
    }

    func togglePinSelectedShelf() {
        togglePin(sessionID: rememberedIngestTargetSessionID)
    }

    func togglePin(sessionID: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[sessionIndex].isPinned.toggle()
        sessions[sessionIndex].updatedAt = Date()
        persist()
    }

    func renameSelectedShelf(_ title: String) {
        _ = renameSelectedShelfTitle(title)
    }

    @discardableResult
    func renameSelectedShelfTitle(_ title: String) -> String {
        renameShelfTitle(title, for: rememberedIngestTargetSessionID)
    }

    @discardableResult
    func renameShelfTitle(_ title: String, for sessionID: UUID) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return session(matching: sessionID)?.title ?? selectedSession.title
        }

        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }) else {
            return selectedSession.title
        }

        sessions[sessionIndex].title = trimmed
        sessions[sessionIndex].updatedAt = Date()
        persist()
        return sessions[sessionIndex].title
    }

    func select(sessionID: UUID) {
        rememberIngestTarget(sessionID: sessionID)
        selectedItemIDs.removeAll()
        rebuildVisibleItems()
        recalculateReview()
    }

    func rememberIngestTarget(sessionID: UUID) {
        guard sessions.contains(where: { $0.id == sessionID }) else { return }
        rememberedIngestTargetSessionID = sessionID
        persist()
    }

    func addFiles(urls: [URL]) {
        guard !urls.isEmpty else { return }
        do {
            let result = try addFiles(urls: urls, to: rememberedIngestTargetSessionID)
            guard !result.addedItems.isEmpty else { return }
            selectedItemIDs = Set(result.addedItems.map(\.id))
            rebuildVisibleItems()
            recalculateReview()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func addFiles(urls: [URL], to sessionID: UUID) throws -> ShelfIngestResult {
        let result = try ingest.add(urls: urls, targetSessionID: sessionID)
        applySnapshot(result.snapshot, refreshItems: false, preserveSelectedItems: false)
        return result
    }

    func removeSelectedFromShelf() {
        guard !selectedItemIDs.isEmpty else { return }
        removeItems(withIDs: selectedItemIDs, from: rememberedIngestTargetSessionID)
        selectedItemIDs.removeAll()
    }

    func removeItems(withIDs itemIDs: Set<UUID>, from sessionID: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[sessionIndex].items.removeAll { itemIDs.contains($0.id) }
        sessions[sessionIndex].updatedAt = Date()
        persist()
        rebuildVisibleItems()
        recalculateReview()
    }

    func clearShelf() {
        clearShelf(sessionID: rememberedIngestTargetSessionID)
        selectedItemIDs.removeAll()
    }

    func clearShelf(sessionID: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[sessionIndex].items.removeAll()
        sessions[sessionIndex].updatedAt = Date()
        persist()
        rebuildVisibleItems()
        recalculateReview()
    }

    func revealSelectedInFinder() {
        revealInFinder(sessionID: rememberedIngestTargetSessionID, itemIDs: selectedItemIDs)
    }

    func revealInFinder(sessionID: UUID, itemIDs: Set<UUID>) {
        let urls = selectedItems(in: sessionID, matching: itemIDs).map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func copySelectedPaths() {
        copyPaths(sessionID: rememberedIngestTargetSessionID, itemIDs: selectedItemIDs)
    }

    func copyPaths(sessionID: UUID, itemIDs: Set<UUID>) {
        let paths = selectedItems(in: sessionID, matching: itemIDs).map(\.url.path).joined(separator: "\n")
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths, forType: .string)
    }

    func openQuickLook() {
        openQuickLook(sessionID: rememberedIngestTargetSessionID, itemIDs: selectedItemIDs)
    }

    func openQuickLook(sessionID: UUID, itemIDs: Set<UUID>) {
        let urls = selectedItems(in: sessionID, matching: itemIDs).map(\.url)
        guard !urls.isEmpty else { return }
        if urls.count == 1 {
            NSWorkspace.shared.open(urls[0])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    func performUndo() {
        performUndo(
            in: rememberedIngestTargetSessionID,
            started: { [weak self] in
                self?.isBusy = true
            },
            finished: { [weak self] message in
                guard let self else { return }
                self.isBusy = false
                self.pendingPreview = nil
                if let message {
                    self.errorMessage = message
                }
            }
        )
    }

    func performUndo(
        in sessionID: UUID,
        started: @escaping () -> Void,
        finished: @escaping (String?) -> Void
    ) {
        runAction(
            operation: { actions in
                try await actions.undoLastBatch()
            },
            applyResult: { mutation in
                if let mutation {
                    self.apply(mutation, to: sessionID)
                }
            },
            started: started,
            finished: finished
        )
    }

    func previewMove(destination: URL, mode: FileOperationMode) {
        pendingPreview = makeMovePreview(
            sessionID: rememberedIngestTargetSessionID,
            itemIDs: selectedItemIDs,
            destination: destination,
            mode: mode
        )
    }

    func previewArchive(root: URL) {
        pendingPreview = makeArchivePreview(
            sessionID: rememberedIngestTargetSessionID,
            itemIDs: selectedItemIDs,
            root: root,
            strategy: archiveStrategy
        )
    }

    func previewRename() {
        pendingPreview = makeRenamePreview(
            sessionID: rememberedIngestTargetSessionID,
            itemIDs: selectedItemIDs,
            pattern: renamePattern
        )
    }

    func previewMetadata() {
        pendingPreview = makeMetadataPreview(
            sessionID: rememberedIngestTargetSessionID,
            itemIDs: selectedItemIDs,
            request: metadataRequest
        )
    }

    func previewSafeDelete() {
        pendingPreview = makeSafeDeletePreview(
            sessionID: rememberedIngestTargetSessionID,
            itemIDs: selectedItemIDs
        )
    }

    func previewZip(destination: URL, baseName: String) {
        pendingPreview = makeZipPreview(
            sessionID: rememberedIngestTargetSessionID,
            itemIDs: selectedItemIDs,
            destination: destination,
            baseName: baseName
        )
    }

    func previewImageTransform(destination: URL) {
        pendingPreview = makeImageTransformPreview(
            sessionID: rememberedIngestTargetSessionID,
            itemIDs: selectedItemIDs,
            plan: imageTransformPlan,
            destination: destination
        )
    }

    func previewCreatePDF(destination: URL, baseName: String) {
        pendingPreview = makePDFPreview(
            sessionID: rememberedIngestTargetSessionID,
            itemIDs: selectedItemIDs,
            destination: destination,
            baseName: baseName
        )
    }

    func makeMovePreview(
        sessionID: UUID,
        itemIDs: Set<UUID>,
        destination: URL,
        mode: FileOperationMode
    ) -> PendingPreview {
        let items = selectedItems(in: sessionID, matching: itemIDs)
        let preview = actions.previewMove(items: items, to: destination, mode: mode)
        return PendingPreview(
            preview: preview,
            action: .move(sessionID: sessionID, itemIDs: items.map(\.id), destination: destination, mode: mode)
        )
    }

    func makeArchivePreview(
        sessionID: UUID,
        itemIDs: Set<UUID>,
        root: URL,
        strategy: ArchiveStrategy
    ) -> PendingPreview {
        let items = selectedItems(in: sessionID, matching: itemIDs)
        let preview = actions.previewArchive(items: items, root: root, strategy: strategy)
        return PendingPreview(
            preview: preview,
            action: .archive(sessionID: sessionID, itemIDs: items.map(\.id), root: root, strategy: strategy)
        )
    }

    func makeRenamePreview(
        sessionID: UUID,
        itemIDs: Set<UUID>,
        pattern: RenamePattern
    ) -> PendingPreview {
        let items = selectedItems(in: sessionID, matching: itemIDs)
        let preview = actions.previewRename(items: items, pattern: pattern)
        return PendingPreview(
            preview: preview,
            action: .rename(sessionID: sessionID, itemIDs: items.map(\.id), pattern: pattern)
        )
    }

    func makeMetadataPreview(
        sessionID: UUID,
        itemIDs: Set<UUID>,
        request: MetadataEditRequest
    ) -> PendingPreview {
        let items = selectedItems(in: sessionID, matching: itemIDs)
        let preview = actions.previewMetadata(items: items, request: request)
        return PendingPreview(
            preview: preview,
            action: .metadata(sessionID: sessionID, itemIDs: items.map(\.id), request: request)
        )
    }

    func makeSafeDeletePreview(sessionID: UUID, itemIDs: Set<UUID>) -> PendingPreview {
        let items = selectedItems(in: sessionID, matching: itemIDs)
        let preview = actions.previewSafeDelete(items: items)
        return PendingPreview(
            preview: preview,
            action: .safeDelete(sessionID: sessionID, itemIDs: items.map(\.id))
        )
    }

    func makeZipPreview(
        sessionID: UUID,
        itemIDs: Set<UUID>,
        destination: URL,
        baseName: String
    ) -> PendingPreview {
        let items = selectedItems(in: sessionID, matching: itemIDs)
        let preview = actions.previewZip(items: items, destinationDirectory: destination, baseName: baseName)
        return PendingPreview(
            preview: preview,
            action: .zip(sessionID: sessionID, itemIDs: items.map(\.id), destination: destination, baseName: baseName)
        )
    }

    func makeImageTransformPreview(
        sessionID: UUID,
        itemIDs: Set<UUID>,
        plan: ImageTransformPlan,
        destination: URL
    ) -> PendingPreview {
        let items = selectedItems(in: sessionID, matching: itemIDs)
        let preview = actions.previewImageTransform(items: items, plan: plan, destinationDirectory: destination)
        return PendingPreview(
            preview: preview,
            action: .imageTransform(sessionID: sessionID, itemIDs: items.map(\.id), plan: plan, destination: destination)
        )
    }

    func makePDFPreview(
        sessionID: UUID,
        itemIDs: Set<UUID>,
        destination: URL,
        baseName: String
    ) -> PendingPreview {
        let items = selectedItems(in: sessionID, matching: itemIDs)
        let preview = actions.previewPDF(from: items, destinationDirectory: destination, baseName: baseName)
        return PendingPreview(
            preview: preview,
            action: .createPDF(sessionID: sessionID, itemIDs: items.map(\.id), destination: destination, baseName: baseName)
        )
    }

    func dismissPreview() {
        pendingPreview = nil
    }

    func confirmPendingPreview() {
        guard let pendingPreview else { return }
        confirm(
            pendingPreview,
            started: { [weak self] in
                self?.isBusy = true
            },
            finished: { [weak self] message in
                guard let self else { return }
                self.isBusy = false
                self.pendingPreview = nil
                if let message {
                    self.errorMessage = message
                }
            }
        )
    }

    func confirm(
        _ pendingPreview: PendingPreview,
        started: @escaping () -> Void,
        finished: @escaping (String?) -> Void
    ) {
        guard let items = resolveItems(for: pendingPreview.action) else {
            finished("The selected items changed after this preview was generated. Run the preview again before executing.")
            return
        }

        let sessionID = pendingPreview.action.sessionID

        switch pendingPreview.action {
        case let .move(_, _, destination, mode):
            runAction(
                operation: { actions in
                    try await actions.executeMove(items: items, to: destination, mode: mode)
                },
                applyResult: { mutation in
                    self.remember(destination: destination)
                    self.apply(mutation, to: sessionID)
                },
                started: started,
                finished: finished
            )
        case let .archive(_, _, root, strategy):
            runAction(
                operation: { actions in
                    try await actions.executeArchive(items: items, root: root, strategy: strategy)
                },
                applyResult: { mutation in
                    self.remember(destination: root)
                    self.apply(mutation, to: sessionID)
                },
                started: started,
                finished: finished
            )
        case let .rename(_, _, pattern):
            runAction(
                operation: { actions in
                    try await actions.executeRename(items: items, pattern: pattern)
                },
                applyResult: { mutation in
                    self.apply(mutation, to: sessionID)
                },
                started: started,
                finished: finished
            )
        case let .metadata(_, _, request):
            runAction(
                operation: { actions in
                    try await actions.executeMetadata(items: items, request: request)
                },
                applyResult: { mutation in
                    self.apply(mutation, to: sessionID)
                },
                started: started,
                finished: finished
            )
        case .safeDelete:
            runAction(
                operation: { actions in
                    try await actions.executeSafeDelete(items: items)
                },
                applyResult: { mutation in
                    self.apply(mutation, to: sessionID)
                },
                started: started,
                finished: finished
            )
        case let .zip(_, _, destination, baseName):
            runAction(
                operation: { actions in
                    try await actions.executeZip(items: items, destinationDirectory: destination, baseName: baseName)
                },
                applyResult: { mutation in
                    self.remember(destination: destination)
                    self.apply(mutation, to: sessionID)
                },
                started: started,
                finished: finished
            )
        case let .imageTransform(_, _, plan, destination):
            runAction(
                operation: { actions in
                    try await actions.executeImageTransform(items: items, plan: plan, destinationDirectory: destination)
                },
                applyResult: { mutation in
                    self.remember(destination: destination)
                    self.apply(mutation, to: sessionID)
                },
                started: started,
                finished: finished
            )
        case let .createPDF(_, _, destination, baseName):
            runAction(
                operation: { actions in
                    try await actions.executePDF(from: items, destinationDirectory: destination, baseName: baseName)
                },
                applyResult: { mutation in
                    self.remember(destination: destination)
                    self.apply(mutation, to: sessionID)
                },
                started: started,
                finished: finished
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
        applyResult: @escaping (Result) -> Void,
        started: @escaping () -> Void,
        finished: @escaping (String?) -> Void
    ) {
        started()
        let actions = self.actions
        Task { [weak self] in
            guard let self else { return }
            var failureMessage: String?
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try await operation(actions)
                }.value
                applyResult(result)
            } catch {
                failureMessage = error.localizedDescription
            }
            canUndo = await actions.canUndo
            finished(failureMessage)
        }
    }

    private func apply(_ mutation: BatchMutation) {
        apply(mutation, to: rememberedIngestTargetSessionID)
    }

    private func apply(_ mutation: BatchMutation, to sessionID: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }) else { return }

        var updatedItems = sessions[sessionIndex].items

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

        sessions[sessionIndex].items = updatedItems.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        sessions[sessionIndex].updatedAt = Date()
        if rememberedIngestTargetSessionID == sessionID {
            selectedItemIDs.subtract(mutation.removedItemIDs)
        }
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
        rememberedIngestTargetSessionID = normalized.rememberedIngestTargetSessionID ?? normalized.sessions[0].id
        recentDestinations = normalized.recentDestinations

        if preserveSelectedItems {
            let validItemIDs = Set(session(matching: defaultSceneSelectionID)?.items.map(\.id) ?? [])
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
        let rememberedIngestTargetSessionID = normalizedSessions.contains(where: { $0.id == snapshot.rememberedIngestTargetSessionID })
            ? snapshot.rememberedIngestTargetSessionID
            : normalizedSessions[0].id

        return AppSnapshot(
            sessions: normalizedSessions,
            recentDestinations: snapshot.recentDestinations,
            rememberedIngestTargetSessionID: rememberedIngestTargetSessionID
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
                rememberedIngestTargetSessionID: rememberedIngestTargetSessionID
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
