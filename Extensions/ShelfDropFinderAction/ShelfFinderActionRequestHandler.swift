import Foundation
import ShelfDropCore
import UniformTypeIdentifiers

@MainActor
final class ShelfFinderActionRequestHandler: NSObject, @preconcurrency NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let inputItems = context.inputItems
        Task { @MainActor in
            do {
                let urls = try await Self.extractInputURLs(from: inputItems)
                guard !urls.isEmpty else {
                    let error = NSError(
                        domain: "ShelfDrop.FinderAction",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "No files or folders were provided to ShelfDrop."]
                    )
                    ShelfIngestFeedback.scheduleFailure(message: error.localizedDescription)
                    context.cancelRequest(withError: error)
                    return
                }

                let store = ShelfStore(baseDirectory: SharedShelfStorage.baseDirectory())
                let ingest = ShelfIngestService(store: store)
                let result = try ingest.add(urls: urls)

                ShelfStateChangeBroadcaster.post()
                ShelfIngestFeedback.scheduleSuccess(result: result)
                context.completeRequest(returningItems: nil)
            } catch {
                ShelfIngestFeedback.scheduleFailure(message: error.localizedDescription)
                context.cancelRequest(withError: error)
            }
        }
    }

    private static func extractInputURLs(from items: [Any]) async throws -> [URL] {
        let providers = items
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }

        guard !providers.isEmpty else {
            return []
        }

        var urls = [URL]()
        for provider in providers {
            if let url = try await loadFileURL(from: provider) {
                urls.append(url)
            }
        }

        var seen = Set<URL>()
        return urls.filter { seen.insert($0).inserted }
    }

    @MainActor
    private static func loadFileURL(from provider: NSItemProvider) async throws -> URL? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL?, Error>) in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                switch item {
                case let url as URL:
                    continuation.resume(returning: url)
                case let url as NSURL:
                    continuation.resume(returning: url as URL)
                case let data as Data:
                    continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                case let string as String:
                    continuation.resume(returning: URL(string: string))
                case nil:
                    continuation.resume(returning: nil)
                default:
                    continuation.resume(
                        throwing: NSError(
                            domain: "ShelfDrop.FinderAction",
                            code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Finder provided an unsupported file reference."]
                        )
                    )
                }
            }
        }
    }
}
