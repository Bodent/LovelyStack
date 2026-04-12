import Foundation
import Testing
@testable import ShelfDrop
import ShelfDropCore

@MainActor
@Test("two windows can keep different visible shelf selections")
func multipleScenesMaintainIndependentSelections() throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = ShelfSession(title: "First")
    let second = ShelfSession(title: "Second")
    let third = ShelfSession(title: "Third")
    let (viewModel, store) = try makeViewModel(
        in: directory,
        snapshot: AppSnapshot(
            sessions: [first, second, third],
            recentDestinations: [],
            rememberedIngestTargetSessionID: first.id
        )
    )

    let leftWindow = ShelfSceneState(viewModel: viewModel)
    let rightWindow = ShelfSceneState(viewModel: viewModel)

    leftWindow.select(sessionID: second.id)
    rightWindow.select(sessionID: third.id)

    #expect(leftWindow.selectedSessionID == second.id)
    #expect(rightWindow.selectedSessionID == third.id)
    #expect(store.load().snapshot.rememberedIngestTargetSessionID == first.id)
}

@MainActor
@Test("deleting a visible shelf in one window keeps the remembered import target intact")
func deletingVisibleShelfDoesNotRewriteRememberedImportTarget() throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = ShelfSession(title: "First")
    let second = ShelfSession(title: "Second")
    let third = ShelfSession(title: "Third")
    let (viewModel, store) = try makeViewModel(
        in: directory,
        snapshot: AppSnapshot(
            sessions: [first, second, third],
            recentDestinations: [],
            rememberedIngestTargetSessionID: first.id
        )
    )

    let sceneState = ShelfSceneState(viewModel: viewModel)
    sceneState.select(sessionID: second.id)

    sceneState.deleteShelf(sessionID: second.id)

    #expect(store.load().snapshot.rememberedIngestTargetSessionID == first.id)
    #expect(sceneState.selectedSessionID != second.id)
}

@Test("inspector expansion is scene-local and not backed by app storage")
func inspectorExpansionUsesSceneStorageOnly() throws {
    let source = try repositoryTextFile("Sources/ShelfDropApp/Views/ShelfRootView.swift")

    #expect(source.contains("@SceneStorage(\"inspector.expanded.preview\")"))
    #expect(source.contains("@SceneStorage(\"inspector.expanded.filing\")"))
    #expect(source.contains("@SceneStorage(\"inspector.expanded.rename\")"))
    #expect(source.contains("@SceneStorage(\"inspector.expanded.metadata\")"))
    #expect(source.contains("@SceneStorage(\"inspector.expanded.transforms\")"))
    #expect(source.contains("@SceneStorage(\"inspector.expanded.issues\")"))
    #expect(!source.contains("@AppStorage(\"inspector.expanded"))
}

@Test("shelf root backgrounds stay in SwiftUI without AppKit cleanup shims")
func paneBackgroundsAvoidAppKitCleanupShims() throws {
    let source = try repositoryTextFile("Sources/ShelfDropApp/Views/ShelfRootView.swift")

    #expect(source.contains(".background(WindowSurfaceBackground())"))
    #expect(source.contains(".background(CenterPaneBackground())"))
    #expect(source.contains(".background(InspectorPaneBackground())"))
    #expect(!source.contains("NSViewRepresentable"))
    #expect(!source.contains("NSViewControllerRepresentable"))
    #expect(!source.contains("drawsBackground"))
    #expect(!source.contains("BackgroundClearer"))
    #expect(!source.contains("HostBackgroundConfigurator"))
}
