import AppKit
import SwiftUI

@main
struct ShelfDropAppMain: App {
    @NSApplicationDelegateAdaptor(ShelfDropAppDelegate.self) private var appDelegate
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
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                DispatchQueue.main.async {
                    let urls = FolderPicker.chooseFiles()
                    viewModel.addFiles(urls: urls)
                }
            }

            Divider()

            if !viewModel.selectedSession.items.isEmpty {
                Text("\(viewModel.selectedSession.items.count) items on import target")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Import target is empty")
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
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WindowChromeTrackingView {
        let view = WindowChromeTrackingView(frame: .zero)
        view.onWindowAvailable = { window in
            context.coordinator.configure(window)
        }
        return view
    }

    func updateNSView(_ nsView: WindowChromeTrackingView, context: Context) {
        context.coordinator.configure(nsView.window)
    }

    final class Coordinator {
        private weak var configuredWindow: NSWindow?

        @MainActor
        func configure(_ window: NSWindow?) {
            guard !ProcessInfo.processInfo.isRunningTests else { return }
            guard let window else { return }
            guard configuredWindow !== window else { return }

            configuredWindow = window
            window.title = "ShelfDrop"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.styleMask.insert(.fullSizeContentView)

            if #available(macOS 11.0, *) {
                window.titlebarSeparatorStyle = .none
            }
        }
    }
}

private final class WindowChromeTrackingView: NSView {
    var onWindowAvailable: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowAvailable?(window)
    }
}

private extension ProcessInfo {
    var isRunningTests: Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }
}
