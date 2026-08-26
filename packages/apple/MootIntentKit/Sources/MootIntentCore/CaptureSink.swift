import Foundation
import AriaMCP   // JSONValue

// MARK: - CaptureSink  (A4b — Share Sheet submit-in)
//
// The submit-in logic for shared content: take a shared item (text, a URL,
// a selection from almost any app) and file it as a verbatim drawer. This is
// the capture path's reusable core, shared by CaptureDrawerIntent and the
// host-side drain of the Share-Sheet handoff.
//
// The Share Extension targets (Mootx01-Share-iOS / -macOS, declared in
// project.yml with sources in ShareExtension/) do NOT call this directly —
// they run in their own process and must not open the estate. They enqueue
// into ShareInboxSpool; the HOST app drains the spool through this sink
// (see ShareInboxDrain in MootGateway).

public struct CaptureSink: Sendable {

    public init() {}

    /// A normalized piece of shared content. A Share Extension maps the
    /// system's NSItemProvider payloads onto this; the gateway stays free of
    /// UIKit/AppKit share types. Codable because the Share Extension hands
    /// items to the host app through the ShareInboxSpool (a file per item in
    /// the app-group container) — the extension process never opens the estate.
    public struct SharedItem: Sendable, Codable {
        public let text: String
        /// Subject-matter location; defaults to an inbox-style room so shared
        /// captures land somewhere predictable.
        public let location: String
        /// The one-sentence assertion `moot_file_memory` requires, when the
        /// sharing surface knows one. A Share Extension often does — a shared
        /// web page carries a document title, a shared mail message a subject
        /// line — and a title the user already saw beats anything derivable
        /// from the body. `nil` means "derive it" (see `capture`).
        ///
        /// Optional so that adding it is wire-compatible: a synthesised
        /// `Codable` decodes a missing key for an Optional property as `nil`,
        /// so items already spooled in the live app-group container by an
        /// older build still drain — they take the derived-subject path.
        public let subject: String?

        public init(text: String, location: String = "shared", subject: String? = nil) {
            self.text = text
            self.location = location
            self.subject = subject
        }
    }

    /// File one shared item as a verbatim drawer via the ARIA tool surface.
    /// Returns the human-readable result text (the filed-memory confirmation).
    public func capture(_ item: SharedItem, using caller: any MootToolCalling) async throws -> String {
        // `subject` is required by the tool: it is the assertion the dense
        // recall row renders, so a capture without one is refused outright.
        //
        // This sink is the surface with the LEAST material to build one from —
        // a Share-Sheet payload normalised to `SharedItem` is a body and a
        // room name. When the extension supplied a subject (a page or message
        // title) it is used verbatim; otherwise it is derived from the body's
        // leading sentence, which states what the content opens with rather
        // than what it claims. The improvement path is the extension passing
        // `SharedItem.subject` from the NSItemProvider's title attributes, not
        // a cleverer derivation here.
        let subject = CaptureSubject.resolve(supplied: item.subject, body: item.text)
        let result = await caller.callTool("moot_file_memory", arguments: [
            "content": .string(item.text),
            "subject": .string(subject),
            "location": .string(item.location),
        ])
        if result.isError {
            throw IntentToolError.substrateRefused(result.text)
        }
        return result.text
    }
}
