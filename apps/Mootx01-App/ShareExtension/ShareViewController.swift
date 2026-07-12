import Foundation
import UniformTypeIdentifiers
import MootIntentKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - ShareViewController  (A4b — the Share-Sheet capture target)
//
// UI-less by design: harvest the shared text/URL, spool it, complete. The
// extension process NEVER opens the estate (one estate, one host — ADR-005);
// it writes one JSON file into the app-group ShareInbox and the host app
// drains that spool through CaptureSink at launch, foregrounding, and each
// mining tick. Content shared while the host is not running is simply
// captured at the next host run — the spool is durable.
//
// Failure posture: no group container or no usable text → cancelRequest with
// the error, so the system's share UI reports failure instead of silently
// dropping the user's content.

@objc(ShareViewController)
final class ShareViewController: PlatformViewController {

    private var processed = false

    #if os(iOS)
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        processOnce()
    }
    #elseif os(macOS)
    override func loadView() {
        view = NSView()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        processOnce()
    }
    #endif

    private func processOnce() {
        guard !processed else { return }
        processed = true
        Task {
            await handleShare()
        }
    }

    private func handleShare() async {
        guard let text = await harvestText(), !text.isEmpty else {
            cancel(reason: "No text or link found in the shared content.")
            return
        }
        do {
            let spool = try ShareInboxSpool.groupSpool()
            try spool.enqueue(.init(text: text, location: "shared"))
            extensionContext?.completeRequest(returningItems: nil)
        } catch {
            cancel(reason: "\(error)")
        }
    }

    /// First URL wins (a shared link's text is usually the page title —
    /// the URL is the durable fact); plain text is the fallback.
    private func harvestText() async -> String? {
        let items = (extensionContext?.inputItems ?? []).compactMap { $0 as? NSExtensionItem }
        let providers = items.flatMap { $0.attachments ?? [] }

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let raw = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) {
                if let url = raw as? URL { return url.absoluteString }
                if let data = raw as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    return url.absoluteString
                }
            }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let raw = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) {
                if let text = raw as? String { return text }
                if let data = raw as? Data, let text = String(data: data, encoding: .utf8) {
                    return text
                }
            }
        }
        return nil
    }

    private func cancel(reason: String) {
        extensionContext?.cancelRequest(withError: NSError(
            domain: "com.codedaptive.mootx01.share",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: reason]))
    }
}

#if os(iOS)
typealias PlatformViewController = UIViewController
#elseif os(macOS)
typealias PlatformViewController = NSViewController
#endif
