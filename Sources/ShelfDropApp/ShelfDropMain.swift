import AppKit
import SwiftUI

@main
struct ShelfDropAppMain: App {
    @StateObject private var container = AppContainer.shared

    var body: some Scene {
        WindowGroup("ShelfDrop", id: "main") {
            ShelfRootView(viewModel: container.model)
                .frame(minWidth: 1180, minHeight: 760)
        }
        .defaultSize(width: 1260, height: 820)
        .windowResizability(.contentSize)

        MenuBarExtra("ShelfDrop", systemImage: "square.stack.3d.up.fill") {
            MenuBarExtraView(viewModel: container.model)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarExtraView: View {
    @ObservedObject var viewModel: ShelfViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("Open Shelf") {
                openWindow(id: "main")
            }

            Button("Add Files…") {
                let urls = FolderPicker.chooseFiles()
                viewModel.addFiles(urls: urls)
                openWindow(id: "main")
            }

            Divider()

            if !viewModel.selectedSession.items.isEmpty {
                Text("\(viewModel.selectedSession.items.count) items on current shelf")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Current shelf is empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 220)
    }
}
