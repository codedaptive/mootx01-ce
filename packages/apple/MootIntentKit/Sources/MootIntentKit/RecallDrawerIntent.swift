import Foundation
import AppIntents
import AriaMCP   // JSONValue, for building tool arguments

// MARK: - RecallDrawerIntent  (verb: recall · A4a serve-out · READ)
//
// The serve-out leg: read drawers back by criteria. Available through Siri,
// Spotlight, Shortcuts, and the Action Button once the host app bundle
// registers this package's intents. perform() routes through moot_memory_search
// and honors the export-policy gate: with `publicOnly == true` it sets
// `filter:exportable`, exposing only drawers marked public (§6.2).
//
// Export-policy write path (DEBT-1, resolved): callers can supply
// `exportability: "public"` to `moot_file_memory` to birth a public drawer,
// or use `moot_update_memory` with `mutation: "correctExportability(public)"`
// to promote an existing private drawer. Both ports are live; `filter:exportable`
// returns correctly populated results after either write path is used.
//
// Return type: the intent returns a typed [DrawerEntity] value (parsed from
// the moot_memory_search response lines via MootToolCalling.parseDrawerLines)
// plus the full response text as dialog. Shortcuts can chain the entities
// into a next step (act-on-drawer); Siri reads the dialog. One tool call
// feeds both — the parse is gateway-layer, no extra ARIA round-trip.

public struct RecallDrawerIntent: MootEstateIntent {

    public static let title: LocalizedStringResource = "Recall Memories"
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @available(anyAppleOS 27.0, *)
    public static let allowedExecutionTargets: IntentExecutionTargets = .main

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

    /// The tool caller injected by the host. `nil` triggers the runtime fallback.
    public var caller: (any MootToolCalling)?

    public init() {}

    public init(query: String, publicOnly: Bool = false, caller: (any MootToolCalling)? = nil) {
        self.query = query
        self.publicOnly = publicOnly
        self.caller = caller
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[DrawerEntity]> {
        let c = try await resolvedCaller()
        var arguments: [String: JSONValue] = ["query": .string(query)]
        if publicOnly {
            // The export-policy gate: only public/exportable drawers leave.
            arguments["filter"] = .string("exportable")
        }
        let result = await c.callTool("moot_memory_search", arguments: arguments)
        if result.isError { throw IntentToolError.substrateRefused(result.text) }
        // One tool call feeds both outputs: the typed entities Shortcuts
        // chains on, and the verbatim response text Siri speaks.
        let drawers = Self.entities(from: result)
        return .result(value: drawers, dialog: IntentDialog(stringLiteral: result.text))
    }

    /// The typed-result composition perform() delegates to: parse the
    /// moot_memory_search response into DrawerEntity values. Split out so the
    /// headless package tests can exercise it (perform() needs the App
    /// Intents runtime).
    public static func entities(from result: IntentCallResult) -> [DrawerEntity] {
        guard !result.isError else { return [] }
        return DrawerLineParser.parse(result.text)
    }

    @MainActor
    private func resolvedCaller() async throws -> any MootToolCalling {
        if let caller { return caller }
        return try await IntentRuntimeBridge.shared.bridge()
    }
}
