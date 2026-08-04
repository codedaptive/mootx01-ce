import Foundation
import AriaMCP   // JSONValue

// MARK: - MootToolCalling
//
// The sole seam between MootIntentKit and the substrate. Every intent,
// URL router, and share sink calls through this protocol; nothing in this
// package imports GeniusLocusKit, LocusKit, or PersistenceKit directly.
//
// MootBridge (in apps/Mootx01-App/Sources/MootGateway/) conforms to this
// protocol. Test code (in Tests/MootIntentKitTests/) provides a TestBridge
// conformance (a MootBridge-equivalent over a real in-memory estate) so
// perform() exercises actual substrate behaviour. The protocol carries only what the
// intent layer needs: tool calls and the result shape.
//
// `actor` isolation: the intents drive `callTool` from @MainActor contexts;
// the protocol is Sendable-safe because actors are Sendable and all
// conformances must be actors. Concrete conformances use `actor` to
// serialize calls — this is the same constraint MootBridge already satisfies.

/// The call record an intent receives after one tool invocation.
public struct IntentCallResult: Sendable {
    /// Concatenated text from every content[].text block in the tool response.
    public let text: String
    /// The tools/call result's `structuredContent` block, verbatim, when the
    /// tool emitted one. The recall family does (an object carrying a
    /// `results` array of `{id, room, content, subject}` rows); most tools do
    /// not, and transport failures produce no result at all — both leave this
    /// nil. Entity construction reads THIS field, never `text`.
    public let structured: JSONValue?
    /// True when the substrate (or the ARIA surface) refused the operation.
    public let isError: Bool

    /// `structured` defaults to nil because most tools answer in text only;
    /// conformances thread the block through whenever the response carries one.
    public init(text: String, structured: JSONValue? = nil, isError: Bool) {
        self.text = text
        self.structured = structured
        self.isError = isError
    }
}

/// The seam MootIntentKit uses to reach the MOOT. Conforming types live
/// above this package (apps/Mootx01-App/MootGateway/MootBridge) or in test
/// infrastructure. The kit never imports the concrete type.
public protocol MootToolCalling: Actor, Sendable {
    /// Invoke a named moot_* tool with string/bool/integer arguments and
    /// return the result. Arguments are JSONValue so the intents can pass
    /// typed values (string, bool) without reaching into the substrate's
    /// own parameter structs.
    func callTool(_ name: String, arguments: [String: JSONValue]) async -> IntentCallResult
}

// MARK: - Structured recall extension

extension MootToolCalling {
    /// Recall drawers as typed entities from `moot_memory_search`'s
    /// `structuredContent` block — typed `{id, room, content, subject}` rows
    /// built server-side from the drawer rows themselves.
    ///
    /// - Parameters:
    ///   - query: The free-text query sent to moot_memory_search.
    ///   - publicOnly: When true, sets filter:exportable (§6.2 serve-out gate).
    ///   - limit: Maximum hits to request (default 20, capped at 50 by the tool).
    public func recallDrawers(
        query: String,
        publicOnly: Bool = false,
        limit: Int = 20
    ) async -> [DrawerEntity] {
        var arguments: [String: JSONValue] = [
            "query": .string(query),
            "limit": .integer(Int64(limit)),
        ]
        if publicOnly {
            arguments["filter"] = .string("exportable")
        }
        let result = await callTool("moot_memory_search", arguments: arguments)
        guard !result.isError else { return [] }
        return StructuredRecallResults.entities(from: result.structured)
    }
}

// MARK: - StructuredRecallResults
//
// Builds DrawerEntity values from the `structuredContent` block of a
// recall-family tools/call result.
//
// Display text is NEVER a source of entity data. Drawer content is user- and
// import-controlled, and the text block interpolates it verbatim — content
// can embed anything, including lines shaped exactly like the display format,
// so any parse of the text block lets a drawer's CONTENT mint an extra entity
// with an attacker-chosen id and room (Codex finding
// fdce2bc01c4881919babde660cd3ad16). It is also why the display format's
// future is irrelevant here: a display change breaks a text parser silently,
// while the structured block is a declared contract (the tool's
// outputSchema). The structured rows are built server-side from the drawer
// row itself, and JSON field boundaries mean content can never escape its
// slot.

public enum StructuredRecallResults {
    /// Decode `structuredContent.results` rows into DrawerEntity values.
    ///
    /// Only rows carrying `id`, `room`, AND `content` become entities — the
    /// same admissible set the text block renders as full rows. Gated rows
    /// (which the server emits as opaque `{id, subject}` stubs) and anything
    /// malformed are skipped, never guessed at. Restricted/secret rows arrive
    /// with the server's redaction markers already in the content/subject
    /// slots, so no body needs re-gating here.
    public static func entities(from structured: JSONValue?) -> [DrawerEntity] {
        guard let results = structured?.objectValue?["results"]?.arrayValue else { return [] }
        return results.compactMap { row -> DrawerEntity? in
            guard let object = row.objectValue,
                  let id = object["id"]?.stringValue,
                  let room = object["room"]?.stringValue,
                  let content = object["content"]?.stringValue else { return nil }
            return DrawerEntity(id: id, content: content, room: room)
        }
    }
}

// MARK: - IntentToolError

/// Surfaces a substrate refusal from any intent as a thrown error so
/// Shortcuts surfaces the reason rather than silently succeeding.
public enum IntentToolError: Error, CustomLocalizedStringResourceConvertible {
    case substrateRefused(String)

    public var localizedStringResource: LocalizedStringResource {
        switch self {
        case .substrateRefused(let why):
            return "The MOOT refused the operation: \(why)"
        }
    }
}
