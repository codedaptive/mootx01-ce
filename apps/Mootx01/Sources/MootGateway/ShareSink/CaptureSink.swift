import Foundation
import AriaMCP   // JSONValue

// MARK: - CaptureSink  (A4b — Share Sheet submit-in)
//
// The submit-in logic a Share Extension would call: take shared content
// (text, a URL, a selection from almost any app) and file it as a verbatim
// drawer. This is the capture path's reusable core, separated from the
// App Intent so the (future) `NSExtension` Share Extension target and the
// CaptureDrawerIntent share one implementation.
//
// SHELL: the logic is complete and tested in-process; what's missing is the
// Share Extension *target* (an NSExtension principal class in an app bundle),
// which SwiftPM cannot declare. When that bundle exists, its share handler is
// three lines: build a SharedItem, call `capture`, show the result.

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
    public func capture(_ item: SharedItem, using bridge: MootBridge) async throws -> String {
        let call = await bridge.callTool("moot_file_memory", arguments: [
            "content": .string(item.text),
            "location": .string(item.location),
        ])
        if call.isError {
            throw GatewayIntentError.substrateRefused(call.text)
        }
        return call.text
    }
}
