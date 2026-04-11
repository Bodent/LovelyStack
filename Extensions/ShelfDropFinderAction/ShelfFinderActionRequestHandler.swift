import AppKit
import Foundation
import ShelfDropCore
import UniformTypeIdentifiers

private final class URLLoadResultBox: NSObject, @unchecked Sendable {
    let result: Result<URL?, Error>

    init(result: Result<URL?, Error>) {
        self.result = result
    }
}

private final class URLLoadCompletionRelay: NSObject, @unchecked Sendable {
    private let completion: (Result<URL?, Error>) -> Void

    init(completion: @escaping (Result<URL?, Error>) -> Void) {
        self.completion = completion
    }

    func dispatch(_ result: Result<URL?, Error>) {
        if Thread.isMainThread {
            completion(result)
            return
        }

        performSelector(onMainThread: #selector(deliver(_:)), with: URLLoadResultBox(result: result), waitUntilDone: false)
    }

    @objc private func deliver(_ box: URLLoadResultBox) {
        completion(box.result)
    }
}

final class ShelfFinderActionRequestHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        extractInputURLs(from: context.inputItems) { result in
            switch result {
            case .success(let urls):
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

                do {
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

            case .failure(let error):
                ShelfIngestFeedback.scheduleFailure(message: error.localizedDescription)
                context.cancelRequest(withError: error)
            }
        }
    }

    private func extractInputURLs(
        from items: [Any],
        completion: @escaping (Result<[URL], Error>) -> Void
    ) {
        let providers = items
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }

        guard !providers.isEmpty else {
            completion(.success([]))
            return
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var urls = [URL]()
        var firstError: Error?

        for provider in providers {
            group.enter()
            loadFileURL(from: provider) { result in
                lock.lock()
                defer { lock.unlock() }

                switch result {
                case .success(let url):
                    if let url {
                        urls.append(url)
                    }
                case .failure(let error):
                    if firstError == nil {
                        firstError = error
                    }
                }

                group.leave()
            }
        }

        group.notify(queue: .main) {
            if let firstError {
                completion(.failure(firstError))
                return
            }

            var seen = Set<URL>()
            let deduped = urls.filter { seen.insert($0).inserted }
            completion(.success(deduped))
        }
    }

    private func loadFileURL(
        from provider: NSItemProvider,
        completion: @escaping (Result<URL?, Error>) -> Void
    ) {
        let relay = URLLoadCompletionRelay(completion: completion)
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            let result: Result<URL?, Error>
            if let error {
                result = .failure(error)
            } else {
                switch item {
                case let url as URL:
                    result = .success(url)
                case let url as NSURL:
                    result = .success(url as URL)
                case let data as Data:
                    result = .success(URL(dataRepresentation: data, relativeTo: nil))
                case let string as String:
                    result = .success(URL(string: string))
                case nil:
                    result = .success(nil)
                default:
                    result = .failure(
                        NSError(
                            domain: "ShelfDrop.FinderAction",
                            code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Finder provided an unsupported file reference."]
                        )
                    )
                }
            }

            relay.dispatch(result)
        }
    }
}
