import Foundation
import AriaMCP   // JSONValue

// MARK: - CaptureSink  (A4b — Share Sheet submit-in)
//
// The submit-in logic a Share Extension calls: take shared content (text, a
// URL, a selection from almost any app) and file it as a verbatim drawer.
// This is the capture path's reusable core, separated from the App Intent so
// the (future) NSExtension Share Extension target and CaptureDrawerIntent
// share one implementation.
//
// The Share Extension target itself (an NSExtension principal class in an app
// bundle) cannot be declared in SwiftPM. When that bundle exists, its share
// handler is three lines: build a SharedItem, call `capture`, show the result.

public struct CaptureSink: Sendable {

    public init() {}

    /// A normalized piece of shared content. A Share Extension maps the
    /// system's NSItemProvider payloads onto this; the gateway stays free of
    /// UIKit/AppKit share types.
    public struct SharedItem: Sendable {
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
