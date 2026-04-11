import AppKit
import ShelfDropCore

final class ShelfDropAppDelegate: NSObject, NSApplicationDelegate {
    private let servicesProvider = ShelfServicesProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = servicesProvider
    }
}

final class ShelfServicesProvider: NSObject {
    @objc(addToShelf:userData:error:)
    func addToShelf(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error outError: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) {
        do {
            let urls = fileURLs(from: pasteboard)
            guard !urls.isEmpty else {
                throw NSError(
                    domain: "ShelfDrop.Services",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "No files or folders were provided by Finder."]
                )
            }

            let store = ShelfStore(baseDirectory: SharedShelfStorage.baseDirectory())
            let ingest = ShelfIngestService(store: store)
            let result = try ingest.add(urls: urls)

            ShelfStateChangeBroadcaster.post()
            ShelfIngestFeedback.scheduleSuccess(result: result)
        } catch {
            outError?.pointee = error.localizedDescription as NSString
            ShelfIngestFeedback.scheduleFailure(message: error.localizedDescription)
        }
    }

    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        guard let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
            return []
        }

        return objects.filter(\.isFileURL)
    }
}
