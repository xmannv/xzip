import Cocoa
import UniformTypeIdentifiers
import XZIPCore

/// Share extension: lets users compress files/documents shared from other apps.
///
/// Design: like the Finder extension, this stays thin — it collects the shared
/// file URLs and hands them to the main app via the `xzip://` scheme. The app's
/// queue and engines do the work.
class ShareViewController: NSViewController {

    override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        Task { await collectAndForward() }
    }

    private func collectAndForward() async {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            complete()
            return
        }

        var paths: [String] = []
        for item in items {
            for provider in item.attachments ?? [] where
                provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                if let url = try? await loadFileURL(from: provider) {
                    // Copy into the shared App Group container before forwarding.
                    // Many source apps (Mail, Photos, sandboxed apps) hand us a
                    // file in the extension's own tmp/Inbox, which the system
                    // reclaims the instant we complete the request — the main app
                    // would then read a path that no longer exists. Staging first
                    // keeps the file alive; fall back to the in-place path (Finder
                    // shares) if the container is unavailable.
                    let forwarded = XZIPAppGroup.stage(url) ?? url
                    paths.append(forwarded.path)
                }
            }
        }

        if !paths.isEmpty,
           let url = AppCommand.compress(paths: paths, presetID: nil, quick: false, format: nil).url {
            NSWorkspace.shared.open(url)
        }
        complete()
    }

    private func loadFileURL(from provider: NSItemProvider) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
                if let error { continuation.resume(throwing: error); return }
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func complete() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
