import Foundation
import Testing
@testable import ShelfDrop
import ShelfDropCore

@MainActor
@Test("deleting a non-selected shelf leaves the current selection unchanged")
func deletingNonSelectedShelfKeepsSelection() throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let firstItem = try makeItem(in: directory, named: "first.txt")
    let secondItem = try makeItem(in: directory, named: "second.txt")
    let first = ShelfSession(title: "First", items: [firstItem])
    let second = ShelfSession(title: "Second", items: [secondItem])
    let (viewModel, _) = try makeViewModel(
        in: directory,
        snapshot: AppSnapshot(sessions: [first, second], recentDestinations: [])
    )

    viewModel.select(sessionID: second.id)
    viewModel.selectedItemIDs = [secondItem.id]

    viewModel.deleteShelf(sessionID: first.id)

    #expect(viewModel.sessions.map(\.id) == [second.id])
    #expect(viewModel.selectedSessionID == second.id)
    #expect(viewModel.selectedItemIDs == [secondItem.id])
}

@MainActor
@Test("selecting a shelf persists the remembered target")
func selectingShelfPersistsRememberedTarget() throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = ShelfSession(title: "First")
    let second = ShelfSession(title: "Second")
    let (viewModel, store) = try makeViewModel(
        in: directory,
        snapshot: AppSnapshot(sessions: [first, second], recentDestinations: [])
    )

    viewModel.select(sessionID: second.id)
    let snapshot = store.load().snapshot

    #expect(snapshot.rememberedIngestTargetSessionID == second.id)
}

@MainActor
@Test("scene selection stays local and does not rewrite the remembered ingest target")
func sceneSelectionDoesNotPersistRememberedTarget() throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = ShelfSession(title: "First")
    let second = ShelfSession(title: "Second")
    let (viewModel, store) = try makeViewModel(
        in: directory,
        snapshot: AppSnapshot(sessions: [first, second], recentDestinations: [])
    )
    let sceneState = ShelfSceneState(viewModel: viewModel)

    sceneState.select(sessionID: second.id)

    #expect(sceneState.selectedSessionID == second.id)
    #expect(store.load().snapshot.rememberedIngestTargetSessionID == first.id)
}

@MainActor
@Test("deleting the selected shelf selects the next remaining shelf")
func deletingSelectedShelfSelectsNextShelf() throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = ShelfSession(title: "First", items: [try makeItem(in: directory, named: "first.txt")])
    let secondItem = try makeItem(in: directory, named: "second.txt")
    let second = ShelfSession(title: "Second", items: [secondItem])
    let third = ShelfSession(title: "Third", items: [try makeItem(in: directory, named: "third.txt")])
    let (viewModel, _) = try makeViewModel(
        in: directory,
        snapshot: AppSnapshot(sessions: [first, second, third], recentDestinations: [])
    )

    viewModel.select(sessionID: second.id)
    viewModel.selectedItemIDs = [secondItem.id]

    viewModel.deleteShelf(sessionID: second.id)

    #expect(viewModel.sessions.map(\.id) == [first.id, third.id])
    #expect(viewModel.selectedSessionID == third.id)
    #expect(viewModel.selectedItemIDs.isEmpty)
    #expect(storeSnapshot(in: directory).rememberedIngestTargetSessionID == third.id)
}

@MainActor
@Test("deleting the selected last shelf falls back to the previous shelf")
func deletingSelectedLastShelfSelectsPreviousShelf() throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = ShelfSession(title: "First", items: [try makeItem(in: directory, named: "first.txt")])
    let second = ShelfSession(title: "Second", items: [try makeItem(in: directory, named: "second.txt")])
    let (viewModel, store) = try makeViewModel(
        in: directory,
        snapshot: AppSnapshot(sessions: [first, second], recentDestinations: [])
    )

    viewModel.select(sessionID: second.id)

    viewModel.deleteShelf(sessionID: second.id)

    #expect(viewModel.sessions.map(\.id) == [first.id])
    #expect(viewModel.selectedSessionID == first.id)
    #expect(store.load().snapshot.rememberedIngestTargetSessionID == first.id)
}

@MainActor
@Test("deleting the final remaining shelf creates a fresh empty replacement shelf")
func deletingFinalShelfCreatesEmptyReplacement() throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let item = try makeItem(in: directory, named: "only.txt")
    let session = ShelfSession(title: "Only", items: [item])
    let (viewModel, _) = try makeViewModel(
        in: directory,
        snapshot: AppSnapshot(sessions: [session], recentDestinations: [])
    )

    let currentItemID = try #require(viewModel.selectedSession.items.first?.id)
    viewModel.selectedItemIDs = [currentItemID]
    viewModel.deleteShelf(sessionID: session.id)

    #expect(viewModel.sessions.count == 1)
    #expect(viewModel.selectedSessionID != session.id)
    #expect(viewModel.selectedSession.title == "New Shelf")
    #expect(viewModel.selectedSession.items.isEmpty)
    #expect(viewModel.selectedItemIDs.isEmpty)
    #expect(viewModel.review.changes.isEmpty)
    #expect(viewModel.review.issues.isEmpty)
    #expect(viewModel.review.duplicateGroups.isEmpty)
}

@MainActor
@Test("deleting the final shelf persists a valid replacement snapshot")
func deletingFinalShelfPersistsReplacementSnapshot() throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let session = ShelfSession(title: "Only", items: [try makeItem(in: directory, named: "only.txt")])
    let (viewModel, store) = try makeViewModel(
        in: directory,
        snapshot: AppSnapshot(sessions: [session], recentDestinations: [])
    )

    viewModel.deleteShelf(sessionID: session.id)
    let snapshot = store.load().snapshot

    #expect(snapshot.sessions.count == 1)
    #expect(snapshot.sessions[0].id == viewModel.selectedSessionID)
    #expect(snapshot.sessions[0].items.isEmpty)
    #expect(snapshot.rememberedIngestTargetSessionID == viewModel.selectedSessionID)
}

@MainActor
@Test("reloadFromStore applies external ingest to the remembered shelf")
func reloadFromStoreAppliesExternalIngest() throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = ShelfSession(title: "First")
    let second = ShelfSession(title: "Second")
    let snapshot = AppSnapshot(
        sessions: [first, second],
        recentDestinations: [],
        rememberedIngestTargetSessionID: second.id
    )
    let (viewModel, store) = try makeViewModel(in: directory, snapshot: snapshot)
    let incomingURL = directory.appendingPathComponent("incoming.txt")
    try Data("incoming".utf8).write(to: incomingURL)

    viewModel.select(sessionID: second.id)

    let ingest = ShelfIngestService(store: store)
    let result = try ingest.add(urls: [incomingURL])

    #expect(result.targetSessionID == second.id)

    viewModel.reloadFromStore()

    #expect(viewModel.selectedSessionID == second.id)
    #expect(viewModel.selectedSession.items.contains(where: { testFileURLsMatch($0.url, incomingURL) }))
}

@MainActor
@Test("confirming a stale preview requires rerunning the preview")
func stalePendingPreviewIsRejected() throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let item = try makeItem(in: directory, named: "draft.txt")
    let session = ShelfSession(title: "Inbox", items: [item])
    let (viewModel, _) = try makeViewModel(
        in: directory,
        snapshot: AppSnapshot(sessions: [session], recentDestinations: [])
    )

    let currentItemID = try #require(viewModel.selectedSession.items.first?.id)
    viewModel.selectedItemIDs = [currentItemID]
    viewModel.previewRename()
    #expect(viewModel.pendingPreview != nil)

    viewModel.clearShelf()
    viewModel.confirmPendingPreview()

    #expect(viewModel.pendingPreview == nil)
    #expect(viewModel.errorMessage?.contains("Run the preview again") == true)
}

@MainActor
@Test("blank shelf title commits back to the current title")
func blankShelfTitleFallsBackToCurrentTitle() throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let session = ShelfSession(title: "Receipts")
    let (viewModel, _) = try makeViewModel(
        in: directory,
        snapshot: AppSnapshot(sessions: [session], recentDestinations: [])
    )

    let resolvedTitle = viewModel.renameSelectedShelfTitle("   ")

    #expect(resolvedTitle == "Receipts")
    #expect(viewModel.selectedSession.title == "Receipts")
}

private func makeTemporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@MainActor
private func makeViewModel(
    in directory: URL,
    snapshot: AppSnapshot
) throws -> (ShelfViewModel, ShelfStore) {
    let store = ShelfStore(baseDirectory: directory)
    try store.save(snapshot)
    let viewModel = ShelfViewModel(
        store: store,
        catalog: FileCatalogService(),
        actions: FileActionService(baseDirectory: directory)
    )
    return (viewModel, store)
}

private func makeItem(in directory: URL, named name: String) throws -> ShelfItem {
    let url = directory.appendingPathComponent(name)
    try Data(name.utf8).write(to: url)
    let catalog = FileCatalogService()
    return try #require(catalog.makeShelfItems(urls: [url]).first)
}

private func storeSnapshot(in directory: URL) -> AppSnapshot {
    ShelfStore(baseDirectory: directory).load().snapshot
}
