import Foundation
import Testing
@testable import ShelfDrop
import ShelfDropCore

func makeTemporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@MainActor
func makeViewModel(
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

func makeItem(in directory: URL, named name: String) throws -> ShelfItem {
    let url = directory.appendingPathComponent(name)
    try Data(name.utf8).write(to: url)
    let catalog = FileCatalogService()
    return try #require(catalog.makeShelfItems(urls: [url]).first)
}

func storeSnapshot(in directory: URL) -> AppSnapshot {
    ShelfStore(baseDirectory: directory).load().snapshot
}
