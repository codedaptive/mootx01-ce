import Foundation
import AppIntents
import AriaMCP   // JSONValue, for building tool arguments

// MARK: - RecallDrawerIntent  (verb: recall · A4a serve-out · READ)
//
// The serve-out leg: read drawers back by criteria. Reach when registered:
// Siri, Spotlight, Shortcuts, the Action Button. perform() routes through
// moot_memory_search and honors the export-policy gate: with
// `publicOnly == true` it sets `filter:exportable`, exposing only drawers
// marked public (§6.2). See the half-wired-export-policy edge — until a
// caller path sets a drawer public, exportable recall returns nothing, which
// is itself the finding.
//
// The intent returns the recall as spoken/return dialog text. It does NOT
// return [DrawerEntity] yet: the tool surface answers in text content blocks,
// not structured drawers (the "tool results are text" edge). Wiring a typed
// [DrawerEntity] result is the small post-WWDC finish once a structured
// recall tool exists — the slot is here.

public struct RecallDrawerIntent: AppIntent {

    public static let title: LocalizedStringResource = "Recall Memories"

    public static let description = IntentDescription(
        "Read memories back from the MOOT by a query, honoring the export policy.",
        categoryName: "Memory"
    )

    /// The search query. Maps to moot_memory_search `query`.
    @Parameter(title: "Query")
    public var query: String

    /// When true, restrict to drawers marked exportable/public (the serve-out
    /// gate). Maps to moot_memory_search `filter:exportable`.
    @Parameter(title: "Public memories only", default: false)
    public var publicOnly: Bool

    public init() {}

    public init(query: String, publicOnly: Bool = false) {
        self.query = query
        self.publicOnly = publicOnly
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let bridge = try await GatewayRuntime.shared.bridge()
        var arguments: [String: JSONValue] = ["query": .string(query)]
        if publicOnly {
            // The export-policy gate: only public/exportable drawers leave.
            arguments["filter"] = .string("exportable")
        }
        let call = await bridge.callTool("moot_memory_search", arguments: arguments)
        if call.isError {
            throw GatewayIntentError.substrateRefused(call.text)
        }
        return .result(value: call.text, dialog: IntentDialog(stringLiteral: call.text))
    }
}
