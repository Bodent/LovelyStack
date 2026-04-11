import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ImageIO

private func makeImageThumbnailData(at url: URL, size: CGSize) -> Data? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        return nil
    }

    let maxPixelSize = max(Int(size.width.rounded()), Int(size.height.rounded())) * 2
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 64),
    ]

    guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        return nil
    }

    let bitmap = NSBitmapImageRep(cgImage: thumbnail)
    return bitmap.representation(using: .png, properties: [:])
}

@MainActor
private enum ThumbnailRepository {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 400
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    static func cacheKey(for url: URL, size: CGSize) -> String {
        let normalizedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        return "\(normalizedURL.path)#\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    }

    static func cachedImage(for url: URL, size: CGSize) -> NSImage? {
        cache.object(forKey: cacheKey(for: url, size: size) as NSString)
    }

    static func loadImage(
        for url: URL,
        size: CGSize,
        completion: @escaping @MainActor (NSImage) -> Void
    ) {
        let key = cacheKey(for: url, size: size)
        if let cached = cache.object(forKey: key as NSString) {
            completion(cached)
            return
        }

        guard isImageURL(url) else {
            let image = fallbackIcon(for: url, size: size)
            cache.setObject(image, forKey: key as NSString, cost: cacheCost(for: image))
            completion(image)
            return
        }

        Task.detached(priority: .utility) {
            let thumbnailData = makeImageThumbnailData(at: url, size: size)
            await MainActor.run {
                let image = thumbnailData.flatMap(NSImage.init(data:)) ?? fallbackIcon(for: url, size: size)
                cache.setObject(image, forKey: key as NSString, cost: cacheCost(for: image))
                completion(image)
            }
        }
    }

    private static func isImageURL(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    private static func fallbackIcon(for url: URL, size: CGSize) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = size
        return icon
    }

    private static func cacheCost(for image: NSImage) -> Int {
        let pixelWidth = max(Int(image.size.width.rounded() * 2), 1)
        let pixelHeight = max(Int(image.size.height.rounded() * 2), 1)
        return pixelWidth * pixelHeight * 4
    }
}

@MainActor
final class ThumbnailProvider: ObservableObject {
    @Published var image: NSImage?
    private var requestedKey: NSString?

    func load(for url: URL, size: CGSize = CGSize(width: 240, height: 180)) {
        let key = ThumbnailRepository.cacheKey(for: url, size: size) as NSString
        requestedKey = key

        if let cached = ThumbnailRepository.cachedImage(for: url, size: size) {
            image = cached
            return
        }

        image = nil
        ThumbnailRepository.loadImage(for: url, size: size) { [weak self] loadedImage in
            guard let self, self.requestedKey == key else { return }
            self.image = loadedImage
        }
    }
}

struct ThumbnailView: View {
    let url: URL
    var size: CGSize = CGSize(width: 240, height: 180)
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
        .task(id: cacheIdentity) {
            provider.load(for: url, size: size)
        }
    }

    private var cacheIdentity: String {
        "\(url.path)#\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
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
