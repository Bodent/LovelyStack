import AppKit
import SwiftUI

@main
struct ShelfDropAppMain: App {
    @StateObject private var container = AppContainer.shared

    var body: some Scene {
        WindowGroup("ShelfDrop", id: "main") {
            ShelfRootView(viewModel: container.model)
                .frame(minWidth: 1180, minHeight: 760)
                .background(WindowChromeConfigurator())
        }
        .defaultSize(width: 1260, height: 820)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

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

private struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            configureWindow(for: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configureWindow(for: nsView)
        }
    }

    private func configureWindow(for view: NSView) {
        guard !ProcessInfo.processInfo.isRunningTests else { return }
        guard let window = view.window else { return }

        window.title = "ShelfDrop"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.styleMask.insert(.fullSizeContentView)

        if #available(macOS 11.0, *) {
            window.titlebarSeparatorStyle = .none
        }
    }
}

private extension ProcessInfo {
    var isRunningTests: Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }
}
