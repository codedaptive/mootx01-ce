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
    /// Recall drawers as App-Intents-free values from `moot_memory_search`'s
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
    ) async -> [RecalledDrawer] {
        var arguments: [String: JSONValue] = [
            "query": .string(query),
            "limit": .integer(Int64(limit)),
        ]
        if publicOnly {
            arguments["filter"] = .string("exportable")
        }
        let result = await callTool("moot_memory_search", arguments: arguments)
        guard !result.isError else { return [] }
        return StructuredRecallResults.drawers(from: result.structured)
    }
}

// MARK: - StructuredRecallResults
//
// Builds plain recalled-drawer values from the `structuredContent` block of a
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

/// One admissible structured row returned by the recall family.
///
/// This value intentionally has no AppIntents conformance. Community code can
/// consume recall safely, while the Pro Apple-surface layer may project it to
/// `DrawerEntity` when Siri or Shortcuts requires an AppEntity.
public struct RecalledDrawer: Sendable, Equatable, Identifiable {
    public let id: String
    /// The drawer's subject, the one text every admissible search row carries
    /// (ARIA_MCP_SPEC § 8.3 base row). Redacted rows carry the server's marker.
    public let subject: String?
    /// The best content span the rerank picked, when the row has one distinct
    /// from the subject.
    public let bestSpan: String?
    /// The room, when the server resolved the drawer's node name.
    public let room: String?
    /// The body. Present only on the memory-get depths that return it; a search
    /// row never carries it (spec § 8 invariants), so a consumer that wants the
    /// body hydrates by id.
    public let content: String?

    public init(id: String, subject: String? = nil, bestSpan: String? = nil,
                room: String? = nil, content: String? = nil) {
        self.id = id
        self.subject = subject
        self.bestSpan = bestSpan
        self.room = room
        self.content = content
    }

    /// The most complete text the row itself carries: the body when the surface
    /// returned one, else the best span, else the subject. Never composed from
    /// anything the row did not say; empty only for a row with no text at all.
    public var excerpt: String { content ?? bestSpan ?? subject ?? "" }
}

public enum StructuredRecallResults {
    /// Decode `structuredContent.results` rows into recalled-drawer values.
    ///
    /// A row is admissible when it carries text of its own: a `subject` (every
    /// rendered search row) or a `content` (the memory-get depths). Gated rows,
    /// which the server emits as opaque id-only stubs, and anything malformed
    /// are skipped, never guessed at. Restricted/secret rows arrive with the
    /// server's redaction markers already in the subject and content slots, so
    /// no body needs re-gating here. Optional fields are absent, never null,
    /// when the text column rendered the placeholder (spec § 8 invariants).
    public static func drawers(from structured: JSONValue?) -> [RecalledDrawer] {
        guard let results = structured?.objectValue?["results"]?.arrayValue else { return [] }
        return results.compactMap { row -> RecalledDrawer? in
            guard let object = row.objectValue,
                  let id = object["id"]?.stringValue else { return nil }
            let subject = object["subject"]?.stringValue
            let content = object["content"]?.stringValue
            guard subject != nil || content != nil else { return nil }
            return RecalledDrawer(
                id: id,
                subject: subject,
                bestSpan: object["bestSpan"]?.stringValue,
                room: object["room"]?.stringValue,
                content: content)
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
