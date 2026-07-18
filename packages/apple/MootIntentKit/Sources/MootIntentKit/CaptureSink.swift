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

        public init(text: String, location: String = "shared") {
            self.text = text
            self.location = location
        }
    }

    /// File one shared item as a verbatim drawer via the ARIA tool surface.
    /// Returns the human-readable result text (the filed-memory confirmation).
    public func capture(_ item: SharedItem, using caller: any MootToolCalling) async throws -> String {
        let result = await caller.callTool("moot_file_memory", arguments: [
            "content": .string(item.text),
            "location": .string(item.location),
        ])
        if result.isError {
            throw IntentToolError.substrateRefused(result.text)
        }
        return result.text
    }
}
