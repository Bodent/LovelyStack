import Foundation
import Testing
@testable import ShelfDropCore

@Test("snapshot round-trips the remembered selected shelf")
func appSnapshotRoundTripsSelectedSessionID() throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let session = ShelfSession(title: "Inbox")
    let snapshot = AppSnapshot(
        sessions: [session],
        recentDestinations: [],
        selectedSessionID: session.id
    )
    let store = ShelfStore(baseDirectory: directory)

    try store.save(snapshot)
    let reloaded = store.load().snapshot

    #expect(reloaded.selectedSessionID == session.id)
}

@Test("ingest adds files to the remembered shelf")
func shelfIngestAddsToRememberedShelf() throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = ShelfSession(title: "First")
    let second = ShelfSession(title: "Second")
    let store = ShelfStore(baseDirectory: directory)
    try store.save(AppSnapshot(sessions: [first, second], recentDestinations: [], selectedSessionID: second.id))

    let incomingURL = directory.appendingPathComponent("incoming.txt")
    try Data("hello".utf8).write(to: incomingURL)

    let ingest = ShelfIngestService(store: store)
    let result = try ingest.add(urls: [incomingURL])
    let snapshot = store.load().snapshot

    #expect(result.targetSessionID == second.id)
    #expect(result.addedCount == 1)
    #expect(snapshot.selectedSessionID == second.id)
    #expect(snapshot.sessions[1].items.contains(where: { $0.url == incomingURL }))
}

@Test("ingest falls back when the remembered shelf no longer exists")
func shelfIngestFallsBackToFirstShelf() throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = ShelfSession(title: "First")
    let store = ShelfStore(baseDirectory: directory)
    try store.save(
        AppSnapshot(
            sessions: [first],
            recentDestinations: [],
            selectedSessionID: UUID()
        )
    )

    let incomingURL = directory.appendingPathComponent("incoming.txt")
    try Data("hello".utf8).write(to: incomingURL)

    let ingest = ShelfIngestService(store: store)
    let result = try ingest.add(urls: [incomingURL])
    let snapshot = store.load().snapshot

    #expect(result.targetSessionID == first.id)
    #expect(snapshot.selectedSessionID == first.id)
}

@Test("ingest dedupes files already present on the target shelf")
func shelfIngestDedupesExistingURLs() throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let incomingURL = directory.appendingPathComponent("existing.txt")
    try Data("hello".utf8).write(to: incomingURL)

    let existingItem = try makeItem(in: directory, named: "existing.txt")
    let session = ShelfSession(title: "Inbox", items: [existingItem])
    let store = ShelfStore(baseDirectory: directory)
    try store.save(AppSnapshot(sessions: [session], recentDestinations: [], selectedSessionID: session.id))

    let ingest = ShelfIngestService(store: store)
    let result = try ingest.add(urls: [incomingURL])

    #expect(result.addedCount == 0)
    #expect(result.duplicateCount == 1)
}

@Test("ingest accepts both files and folders")
func shelfIngestAcceptsFilesAndFolders() throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("file.txt")
    let folderURL = directory.appendingPathComponent("Folder", isDirectory: true)
    try Data("hello".utf8).write(to: fileURL)
    try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

    let session = ShelfSession(title: "Inbox")
    let store = ShelfStore(baseDirectory: directory)
    try store.save(AppSnapshot(sessions: [session], recentDestinations: [], selectedSessionID: session.id))

    let ingest = ShelfIngestService(store: store)
    let result = try ingest.add(urls: [fileURL, folderURL])

    #expect(result.addedCount == 2)
    #expect(result.addedItems.contains(where: { $0.url == fileURL && !$0.isDirectory }))
    #expect(result.addedItems.contains(where: { $0.url == folderURL && $0.isDirectory }))
}

private func makeTemporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeItem(in directory: URL, named name: String) throws -> ShelfItem {
    let url = directory.appendingPathComponent(name)
    let catalog = FileCatalogService()
    return try #require(catalog.makeShelfItems(urls: [url]).first)
}
