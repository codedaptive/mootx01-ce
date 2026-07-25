import Foundation
import AriaMCP        // JSONValue
import MootIntentKit  // MootToolCalling

// MARK: - ReviewSurfaceReading  (FAB5-G1 — the read seam under every builder)
//
// The builders depend on this narrow protocol, never on a concrete transport.
// Two reasons, and the first is structural:
//
//  1. MISSION CORRECTION. The mission text says the builders read the estate
//     "via the resident daemon's local API the app already uses
//     (DaemonController)". They cannot: `DaemonController` is defined in
//     Sources/GatewayUI (see GatewayUI/DaemonController.swift), GatewayUI
//     depends on MootGateway and never the reverse, and the type is @MainActor
//     and macOS-only. A MootGateway-side module reaching it would invert the
//     package graph. The actual in-target seam to the ARIA tool surface is
//     `MootToolCalling` (MootIntentKit), which `MootBridge` conforms to — the
//     same seam the FAB5-H1 workers read through. `MootToolCallingReviewReader`
//     below adapts it. Callers that already hold a DaemonController-driven
//     bridge pass that bridge; the daemon vs embedded transport choice is
//     MootBridge's business, not the Review module's.
//  2. Fixture testing. A stub conformance replays recorded tool responses, so
//     builder behaviour is verified without a live estate.
//
// Read verbs only, by construction: the protocol takes a tool NAME, but the only
// names the builders ever pass come from `ReviewSurface`, which contains no
// mutation verb.

/// One tool response, reduced to what the review layer needs.
public struct ReviewToolResponse: Sendable, Equatable {
    /// Concatenated text of the response's content blocks.
    public let text: String
    /// True when the substrate or the ARIA surface refused the call. Builders
    /// turn a refusal into a section notice — they never throw and never retry.
    public let isError: Bool

    public init(text: String, isError: Bool) {
        self.text = text
        self.isError = isError
    }
}

/// The seam the four builders read the estate through.
public protocol ReviewSurfaceReading: Sendable {
    /// Invoke a read-only ARIA tool by its registered name.
    ///
    /// Conformances must not throw: a transport failure is reported as
    /// `ReviewToolResponse(text: <reason>, isError: true)` so a single dead
    /// surface degrades one section instead of failing the whole review.
    func call(_ surface: ReviewSurface, arguments: [String: JSONValue]) async -> ReviewToolResponse
}

// MARK: - MootToolCallingReviewReader

/// Adapts the app's live tool surface (`MootBridge`, or any `MootToolCalling`)
/// to `ReviewSurfaceReading`. This is the production reader.
public struct MootToolCallingReviewReader: ReviewSurfaceReading {
    private let caller: any MootToolCalling

    /// - Parameter caller: the live bridge. `MootToolCalling` refines `Actor`, so
    ///   the existential is `Sendable` and this struct is safely `Sendable` too.
    public init(caller: any MootToolCalling) {
        self.caller = caller
    }

    public func call(_ surface: ReviewSurface, arguments: [String: JSONValue]) async -> ReviewToolResponse {
        let result = await caller.callTool(surface.rawValue, arguments: arguments)
        return ReviewToolResponse(text: result.text, isError: result.isError)
    }
}

// MARK: - Argument rendering

extension ReviewProvenance {
    /// Stringify tool arguments for the audit record. `JSONValue` is not
    /// `Codable`-stable for provenance display, and provenance must survive a
    /// JSON round-trip for FAB5-K1, so values are rendered to text once at
    /// capture time. Scalars render bare — the audit record reads as
    /// `wing: Agentic Memory` and `topK: 5`, not `wing: "Agentic Memory"` and
    /// `topK: integer(5)`. Doubles use `String(_:)` (f64 shortest round-trip),
    /// matching the text the Rust twin emits for the same value.
    static func renderArguments(_ arguments: [String: JSONValue]) -> [String: String] {
        arguments.reduce(into: [:]) { out, pair in
            switch pair.value {
            case .string(let value): out[pair.key] = value
            case .integer(let value): out[pair.key] = String(value)
            case .double(let value): out[pair.key] = String(value)
            case .bool(let value): out[pair.key] = String(value)
            case .null: out[pair.key] = "null"
            // Arrays and objects have no bare rendering; no builder passes one
            // today, and a structural dump is still a faithful audit record.
            case .array, .object: out[pair.key] = String(describing: pair.value)
            }
        }
    }
}
