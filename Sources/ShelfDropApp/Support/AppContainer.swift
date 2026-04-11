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

    private init() {
        let supportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LovelyStack", isDirectory: true)
        self.supportDirectory = supportRoot
        self.store = ShelfStore(baseDirectory: supportRoot)
        self.catalog = FileCatalogService()
        self.actions = FileActionService(baseDirectory: supportRoot)
        self.model = ShelfViewModel(store: store, catalog: catalog, actions: actions)
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
    @Published var searchText = ""
    @Published var renamePattern = RenamePattern()
    @Published var metadataRequest = MetadataEditRequest()
    @Published var imageTransformPlan = ImageTransformPlan()
    @Published var archiveStrategy: ArchiveStrategy = .createdMonth
    @Published var isBusy = false
    private(set) var loadWarning: String?

    private let store: ShelfStore
    private let catalog: FileCatalogService
    private let actions: FileActionService

    init(store: ShelfStore, catalog: FileCatalogService, actions: FileActionService) {
        self.store = store
        self.catalog = catalog
        self.actions = actions

        let loadResult = store.load()
        self.loadWarning = loadResult.warning

        let snapshot = loadResult.snapshot
        let restoredSessions = snapshot.sessions.isEmpty ? [ShelfSession()] : snapshot.sessions
        let initialSessions = restoredSessions.map { session in
            var refreshedSession = session
            refreshedSession.items = session.items.map { item in
                catalog.refresh(item: item) ?? item
            }
            return refreshedSession
        }
        self.sessions = initialSessions
        self.selectedSessionID = initialSessions[0].id
        self.recentDestinations = snapshot.recentDestinations
        if loadResult.warning == nil {
            persist()
        }
        recalculateReview()
    }

    var selectedSessionIndex: Int {
        sessions.firstIndex(where: { $0.id == selectedSessionID }) ?? 0
    }

    var selectedSession: ShelfSession {
        get { sessions[selectedSessionIndex] }
        set { sessions[selectedSessionIndex] = newValue }
    }

    var visibleItems: [ShelfItem] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return selectedSession.items
        }
        let query = searchText.localizedLowercase
        return selectedSession.items.filter {
            $0.displayName.localizedLowercase.contains(query) ||
            $0.kindDescription.localizedLowercase.contains(query) ||
            $0.tags.joined(separator: " ").localizedLowercase.contains(query)
        }
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
            recalculateReview()
            return
        }

        if deletingSelectedShelf {
            let replacementIndex = min(deleteIndex, sessions.count - 1)
            selectedSessionID = sessions[replacementIndex].id
            selectedItemIDs.removeAll()
        }

        persist()
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
        recalculateReview()
    }

    func addFiles(urls: [URL]) {
        guard !urls.isEmpty else { return }
        let newItems = catalog.makeShelfItems(urls: urls)
        let existingURLs = Set(selectedSession.items.map(\.url))
        let deduped = newItems.filter { !existingURLs.contains($0.url) }
        guard !deduped.isEmpty else { return }
        selectedSession.items.append(contentsOf: deduped)
        selectedSession.updatedAt = Date()
        selectedItemIDs = Set(deduped.map(\.id))
        persist()
        recalculateReview()
    }

    func removeSelectedFromShelf() {
        guard !selectedItemIDs.isEmpty else { return }
        selectedSession.items.removeAll { selectedItemIDs.contains($0.id) }
        selectedSession.updatedAt = Date()
        selectedItemIDs.removeAll()
        persist()
        recalculateReview()
    }

    func clearShelf() {
        selectedSession.items.removeAll()
        selectedSession.updatedAt = Date()
        selectedItemIDs.removeAll()
        persist()
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
        presentPreview(preview) { [weak self, items, destination, mode] in
            guard let self else { return }
            runAction(
                operation: { actions in
                    try await actions.executeMove(items: items, to: destination, mode: mode)
                },
                applyResult: { mutation in
                    self.remember(destination: destination)
                    self.apply(mutation)
                }
            )
        }
    }

    func previewArchive(root: URL) {
        let items = selectedItems
        let strategy = archiveStrategy
        let preview = actions.previewArchive(items: items, root: root, strategy: strategy)
        presentPreview(preview) { [weak self, items, root, strategy] in
            guard let self else { return }
            runAction(
                operation: { actions in
                    try await actions.executeArchive(items: items, root: root, strategy: strategy)
                },
                applyResult: { mutation in
                    self.remember(destination: root)
                    self.apply(mutation)
                }
            )
        }
    }

    func previewRename() {
        let items = selectedItems
        let pattern = renamePattern
        let preview = actions.previewRename(items: items, pattern: pattern)
        presentPreview(preview) { [weak self, items, pattern] in
            guard let self else { return }
            runAction(
                operation: { actions in
                    try await actions.executeRename(items: items, pattern: pattern)
                },
                applyResult: { mutation in
                    self.apply(mutation)
                }
            )
        }
    }

    func previewMetadata() {
        let items = selectedItems
        let request = metadataRequest
        let preview = actions.previewMetadata(items: items, request: request)
        presentPreview(preview) { [weak self, items, request] in
            guard let self else { return }
            runAction(
                operation: { actions in
                    try await actions.executeMetadata(items: items, request: request)
                },
                applyResult: { mutation in
                    self.apply(mutation)
                }
            )
        }
    }

    func previewSafeDelete() {
        let items = selectedItems
        let preview = actions.previewSafeDelete(items: items)
        presentPreview(preview) { [weak self, items] in
            guard let self else { return }
            runAction(
                operation: { actions in
                    try await actions.executeSafeDelete(items: items)
                },
                applyResult: { mutation in
                    self.apply(mutation)
                }
            )
        }
    }

    func previewZip(destination: URL, baseName: String) {
        let items = selectedItems
        let preview = actions.previewZip(items: items, destinationDirectory: destination, baseName: baseName)
        presentPreview(preview) { [weak self, items, destination, baseName] in
            guard let self else { return }
            runAction(
                operation: { actions in
                    try await actions.executeZip(items: items, destinationDirectory: destination, baseName: baseName)
                },
                applyResult: { mutation in
                    self.remember(destination: destination)
                    self.apply(mutation)
                }
            )
        }
    }

    func previewImageTransform(destination: URL) {
        let items = selectedItems
        let plan = imageTransformPlan
        let preview = actions.previewImageTransform(items: items, plan: plan, destinationDirectory: destination)
        presentPreview(preview) { [weak self, items, plan, destination] in
            guard let self else { return }
            runAction(
                operation: { actions in
                    try await actions.executeImageTransform(items: items, plan: plan, destinationDirectory: destination)
                },
                applyResult: { mutation in
                    self.remember(destination: destination)
                    self.apply(mutation)
                }
            )
        }
    }

    func previewCreatePDF(destination: URL, baseName: String) {
        let items = selectedItems
        let preview = actions.previewPDF(from: items, destinationDirectory: destination, baseName: baseName)
        presentPreview(preview) { [weak self, items, destination, baseName] in
            guard let self else { return }
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

    func dismissPreview() {
        pendingPreview = nil
    }

    private func remember(destination: URL) {
        recentDestinations.removeAll { $0 == destination }
        recentDestinations.insert(destination, at: 0)
        recentDestinations = Array(recentDestinations.prefix(6))
        persist()
    }

    private func presentPreview(_ preview: BatchPreview, onConfirm: @escaping () -> Void) {
        pendingPreview = PendingPreview(preview: preview, onConfirm: onConfirm)
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
            return catalog.refresh(item: item) ?? item
        }

        let additions = catalog.makeShelfItems(urls: mutation.createdURLs + mutation.restoredURLs)
        let existingURLs = Set(updatedItems.map(\.url))
        let filteredAdditions = additions.filter { !existingURLs.contains($0.url) }
        updatedItems.append(contentsOf: filteredAdditions)

        selectedSession.items = updatedItems.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        selectedSession.updatedAt = Date()
        selectedItemIDs.subtract(mutation.removedItemIDs)
        persist()
        recalculateReview()
    }

    private func recalculateReview() {
        review = actions.review(items: selectedSession.items)
    }

    private func persist() {
        do {
            let snapshot = AppSnapshot(sessions: sessions, recentDestinations: recentDestinations)
            try store.save(snapshot)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct PendingPreview: Identifiable {
    let id = UUID()
    let preview: BatchPreview
    let onConfirm: () -> Void
}
