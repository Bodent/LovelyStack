import AppKit
import SwiftUI

@MainActor
final class ThumbnailProvider: ObservableObject {
    @Published var image: NSImage?

    func load(for url: URL, size: CGSize = CGSize(width: 240, height: 180)) {
        if let loadedImage = NSImage(contentsOf: url) {
            image = loadedImage
        } else {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = size
            image = icon
        }
    }
}

struct ThumbnailView: View {
    let url: URL
    @StateObject private var provider = ThumbnailProvider()

    var body: some View {
        Group {
            if let image = provider.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.secondary.opacity(0.08))
                    .overlay(ProgressView())
            }
        }
        .onAppear {
            provider.load(for: url)
        }
        .onChange(of: url) {
            provider.load(for: url)
        }
    }
}

struct SharingButton: NSViewRepresentable {
    let urls: [URL]

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "Share", target: context.coordinator, action: #selector(Coordinator.showPicker(_:)))
        button.bezelStyle = .rounded
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.urls = urls
        nsView.isEnabled = !urls.isEmpty
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(urls: urls)
    }

    final class Coordinator: NSObject {
        var urls: [URL]

        init(urls: [URL]) {
            self.urls = urls
        }

        @MainActor
        @objc func showPicker(_ sender: NSButton) {
            let picker = NSSharingServicePicker(items: urls)
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        }
    }
}

enum FolderPicker {
    @MainActor
    static func chooseFolder(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.title = title
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    static func chooseFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Shelf"
        panel.title = "Add Files to Shelf"
        return panel.runModal() == .OK ? panel.urls : []
    }
}
