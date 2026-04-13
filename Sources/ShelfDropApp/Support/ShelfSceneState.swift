import Combine
import Foundation
import ShelfDropCore

@MainActor
final class ShelfSceneState: ObservableObject {
    @Published var selectedSessionID: UUID
    @Published var selectedItemIDs = Set<UUID>()
    @Published var review: BatchPreview
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

    private let viewModel: ShelfViewModel
    private var selectedSessionSearchIndex = [UUID: String]()
    private var cancellables = Set<AnyCancellable>()

    init(viewModel: ShelfViewModel) {
        self.viewModel = viewModel
        self.selectedSessionID = viewModel.defaultSceneSelectionID
        self.review = viewModel.review(for: viewModel.defaultSceneSelectionID)
        rebuildVisibleItems()
        observeViewModel()
    }

    var selectedSession: ShelfSession {
        viewModel.session(matching: selectedSessionID)
            ?? viewModel.session(matching: viewModel.defaultSceneSelectionID)
            ?? viewModel.selectedSession
    }

    var selectedItems: [ShelfItem] {
        viewModel.selectedItems(in: selectedSessionID, matching: selectedItemIDs)
    }

    var pinnedSessions: [ShelfSession] {
        viewModel.sessions.filter(\.isPinned)
    }

    var recentSessions: [ShelfSession] {
        viewModel.sessions.filter { !$0.isPinned }
    }

    var recentDestinations: [URL] {
        viewModel.recentDestinations
    }

    var canUndo: Bool {
        viewModel.canUndo
    }

    func clearError() {
        errorMessage = nil
        viewModel.errorMessage = nil
    }

    func select(sessionID: UUID) {
        guard selectedSessionID != sessionID else { return }
        selectedSessionID = sessionID
        selectedItemIDs.removeAll()
        rebuildDerivedState()
    }

    func createShelf() {
        selectedSessionID = viewModel.createShelf()
        selectedItemIDs.removeAll()
        rebuildDerivedState()
    }

    @discardableResult
    func createShelf(title: String) -> String {
        createShelf()
        return renameShelfTitle(title, for: selectedSessionID)
    }

    func deleteShelf(sessionID: UUID) {
        let remainingSelection = viewModel.deleteShelf(sessionID: sessionID)
        if selectedSessionID == sessionID || viewModel.session(matching: selectedSessionID) == nil {
            selectedSessionID = remainingSelection
            selectedItemIDs.removeAll()
        }
        rebuildDerivedState()
    }

    @discardableResult
    func renameSelectedShelfTitle(_ title: String) -> String {
        renameShelfTitle(title, for: selectedSessionID)
    }

    @discardableResult
    func renameShelfTitle(_ title: String, for sessionID: UUID) -> String {
        let resolvedTitle = viewModel.renameShelfTitle(title, for: sessionID)
        rebuildDerivedState()
        return resolvedTitle
    }

    func togglePinSelectedShelf() {
        viewModel.togglePin(sessionID: selectedSessionID)
    }

    func addFiles(urls: [URL]) {
        guard !urls.isEmpty else { return }
        do {
            let result = try viewModel.addFiles(urls: urls, to: selectedSessionID)
            selectedItemIDs = Set(result.addedItems.map(\.id))
            rebuildDerivedState()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeSelectedFromShelf() {
        guard !selectedItemIDs.isEmpty else { return }
        viewModel.removeItems(withIDs: selectedItemIDs, from: selectedSessionID)
        selectedItemIDs.removeAll()
        rebuildDerivedState()
    }

    func clearShelf() {
        viewModel.clearShelf(sessionID: selectedSessionID)
        selectedItemIDs.removeAll()
        rebuildDerivedState()
    }

    func revealSelectedInFinder() {
        viewModel.revealInFinder(sessionID: selectedSessionID, itemIDs: selectedItemIDs)
    }

    func copySelectedPaths() {
        viewModel.copyPaths(sessionID: selectedSessionID, itemIDs: selectedItemIDs)
    }

    func openQuickLook() {
        viewModel.openQuickLook(sessionID: selectedSessionID, itemIDs: selectedItemIDs)
    }

    func performUndo() {
        viewModel.performUndo(
            in: selectedSessionID,
            started: { [weak self] in
                self?.isBusy = true
            },
            finished: { [weak self] message in
                guard let self else { return }
                self.isBusy = false
                if let message {
                    self.errorMessage = message
                }
            }
        )
    }

    func previewMove(destination: URL, mode: FileOperationMode) {
        pendingPreview = viewModel.makeMovePreview(
            sessionID: selectedSessionID,
            itemIDs: selectedItemIDs,
            destination: destination,
            mode: mode
        )
    }

    func previewArchive(root: URL) {
        pendingPreview = viewModel.makeArchivePreview(
            sessionID: selectedSessionID,
            itemIDs: selectedItemIDs,
            root: root,
            strategy: archiveStrategy
        )
    }

    func previewRename() {
        pendingPreview = viewModel.makeRenamePreview(
            sessionID: selectedSessionID,
            itemIDs: selectedItemIDs,
            pattern: renamePattern
        )
    }

    func previewMetadata() {
        pendingPreview = viewModel.makeMetadataPreview(
            sessionID: selectedSessionID,
            itemIDs: selectedItemIDs,
            request: metadataRequest
        )
    }

    func previewSafeDelete() {
        pendingPreview = viewModel.makeSafeDeletePreview(
            sessionID: selectedSessionID,
            itemIDs: selectedItemIDs
        )
    }

    func previewZip(destination: URL, baseName: String) {
        pendingPreview = viewModel.makeZipPreview(
            sessionID: selectedSessionID,
            itemIDs: selectedItemIDs,
            destination: destination,
            baseName: baseName
        )
    }

    func previewImageTransform(destination: URL) {
        pendingPreview = viewModel.makeImageTransformPreview(
            sessionID: selectedSessionID,
            itemIDs: selectedItemIDs,
            plan: imageTransformPlan,
            destination: destination
        )
    }

    func previewCreatePDF(destination: URL, baseName: String) {
        pendingPreview = viewModel.makePDFPreview(
            sessionID: selectedSessionID,
            itemIDs: selectedItemIDs,
            destination: destination,
            baseName: baseName
        )
    }

    func dismissPreview() {
        pendingPreview = nil
    }

    func confirmPendingPreview() {
        guard let pendingPreview else { return }
        viewModel.confirm(
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

    private func observeViewModel() {
        viewModel.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.synchronizeWithModel()
            }
            .store(in: &cancellables)

        viewModel.$errorMessage
            .receive(on: RunLoop.main)
            .sink { [weak self] message in
                guard let self, let message else { return }
                self.errorMessage = message
            }
            .store(in: &cancellables)
    }

    private func synchronizeWithModel() {
        if viewModel.session(matching: selectedSessionID) == nil {
            selectedSessionID = viewModel.defaultSceneSelectionID
        }

        let validItemIDs = Set(viewModel.items(in: selectedSessionID).map(\.id))
        selectedItemIDs = selectedItemIDs.intersection(validItemIDs)
        rebuildDerivedState()
    }

    private func rebuildDerivedState() {
        rebuildVisibleItems()
        review = viewModel.review(for: selectedSessionID)
    }

    private func rebuildVisibleItems() {
        let items = viewModel.items(in: selectedSessionID)
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
