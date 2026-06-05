import Foundation
import GeniusLocusKit
import LocusKit

/// Dispatch a parsed `tools/call` against one or more GeniusLocusKit
/// estates opened in the same kit instance.
///
/// The dispatcher carries one `GeniusLocusKit` reference and a map of
/// the estates it can address, keyed by `estateUUID`. One of those is
/// the default estate. Each tool call is routed by name through the
/// five-tier AI-client interface, the federation tool, recipe tools,
/// lens tools, and vault tools. Outcomes — success payloads or substrate
/// refusals — map to MCP `tools/call` result shapes; out-of-band failures
/// (unknown tool, malformed arguments, unknown `estateID`) surface as
/// JSON-RPC error responses instead.
///
/// ## Multi-estate addressing and the I-13 boundary
///
/// Every estate this dispatcher addresses is already `open` in the one
/// `GeniusLocusKit` actor on this device — entries in the kit's
/// in-process registry. Routing by `estateID` selects among *locally*
/// open estates; it never crosses a device or process boundary. This
/// is the ARIA access surface where federation is *mediated* (spec
/// invariant I-13); the substrate-to-substrate mechanism does not live
/// here. The single-estate v1.0 path is preserved exactly: a caller
/// that omits `estateID` targets the default estate, byte-for-byte as
/// before multi-estate addressing existed.
///
/// The estate map and kit are captured immutably; the dispatcher is not
/// an actor because all mutable state lives inside `GeniusLocusKit`,
/// which is itself an actor and serializes its per-estate work. Adding
/// an estate produces a new dispatcher (`registering(_:)`) rather than
/// mutating in place, keeping the value semantics of a `Sendable`
/// struct. The dispatcher's methods are async because every downstream
/// call into the kit is async.
public struct ToolDispatcher: Sendable {
    public let kit: GeniusLocusKit

    /// The default estate's handle — the target when a tool call omits
    /// `estateID`. Retained as a stored property so the v1.0
    /// single-estate construction and any reader of `.handle` are
    /// unchanged.
    public let handle: EstateHandle

    /// Every estate this dispatcher can address, keyed by `estateUUID`.
    /// Seeded with the default estate by `init(kit:handle:)`; grown by
    /// `registering(_:)`.
    private let estates: [UUID: EstateHandle]

    /// Construct a single-estate dispatcher. `handle` is registered as
    /// the sole addressable estate and is the default target for calls
    /// that omit `estateID`. This is the v1.0 path; every existing
    /// construction site uses exactly this initializer.
    public init(kit: GeniusLocusKit, handle: EstateHandle) {
        self.kit = kit
        self.handle = handle
        self.estates = [handle.estateUUID: handle]
    }

    /// Return a dispatcher that also addresses `additional`, with the
    /// same default estate. Value-semantic (returns a new dispatcher)
    /// because `ToolDispatcher` is an immutable `Sendable` struct; the
    /// kit reference and default `handle` are carried over unchanged.
    /// Re-registering an estate already present replaces its entry,
    /// which is harmless because handles are keyed by a stable UUID.
    public func registering(_ additional: EstateHandle) -> ToolDispatcher {
        var next = estates
        next[additional.estateUUID] = additional
        return ToolDispatcher(kit: kit, handle: handle, estates: next)
    }

    /// Private designated initializer carrying an explicit estate map.
    /// Used by `registering(_:)`; the public `init(kit:handle:)` is the
    /// only construction path external callers use.
    private init(kit: GeniusLocusKit, handle: EstateHandle, estates: [UUID: EstateHandle]) {
        self.kit = kit
        self.handle = handle
        self.estates = estates
    }

    /// Resolve the estate a tool call targets from its `estateID`
    /// argument. The default (omitted `estateID`) returns the default
    /// estate's handle, so the single-estate v1.0 behavior is identical
    /// to today. A present `estateID` must be a UUID string naming a
    /// registered estate; a malformed or unregistered value is an
    /// out-of-band client error (`invalidParams`), consistent with the
    /// other enum decoders in this file.
    private func resolveHandle(_ args: [String: JSONValue]) throws -> EstateHandle {
        guard let raw = args["estateID"]?.stringValue else {
            return handle
        }
        guard let uuid = UUID(uuidString: raw) else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Malformed estateID (not a UUID): \(raw)"
            )
        }
        guard let resolved = estates[uuid] else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Unknown estateID: \(raw)"
            )
        }
        return resolved
    }

    /// Run the tool named `name` with the JSON `arguments` object.
    /// Returns the MCP `tools/call` result payload as a `JSONValue`
    /// (a `content` array of text blocks plus an `isError` flag).
    /// Throws `JSONRPCError` only for out-of-band conditions (unknown
    /// tool, missing required argument, malformed JSON). Substrate
    /// refusals (`VerbError.notSupportedByEstate`, `.expungeNotConfirmed`)
    /// come back as a result with `isError == true` rather than as a
    /// JSON-RPC error: the call did reach the substrate, the substrate
    /// said no, the client should see why.
    ///
    /// Dispatch order: teachme pre-check → federation → recipe → lens → vault → interface → methodNotFound → hint injection.
    public func dispatch(name: String, arguments: JSONValue) async throws -> JSONValue {
        let args = arguments.objectValue ?? [:]
        do {
            // teachme: true — return the usage guide without touching the estate.
            // Intercepted before any runner fires so no side effects occur.
            if args["teachme"]?.boolValue == true {
                return Self.textResult(TeachmeGuides.guide(for: name))
            }
            // Route to the appropriate runner and capture the result so
            // the coaching engine can inspect it before it is returned.
            let runnerResult: JSONValue
            if name == Self.federatedSearchToolName {
                // Federation tool above the interface tier — matched by name.
                runnerResult = try await runFederatedSearch(args)
            } else if RecipeTools.isRecipeTool(name) {
                // CognitionKit behaviour-recipe tools dispatched by name.
                runnerResult = try await RecipeTools.dispatch(
                    name: name, args: args, kit: kit, defaultHandle: handle,
                    resolveHandle: resolveHandle)
            } else if LensTools.isLensTool(name) {
                // Reasoning-lens tools dispatched by name.
                runnerResult = try await LensTools.dispatch(
                    name: name, args: args, kit: kit, defaultHandle: handle,
                    resolveHandle: resolveHandle)
            } else if VaultTools.isVaultTool(name) {
                // VaultKit control-surface tools dispatched by name.
                runnerResult = try await VaultTools.dispatch(
                    name: name, args: args, kit: kit, defaultHandle: handle,
                    resolveHandle: resolveHandle)
            } else if InterfaceTools.isInterfaceTool(name) {
                // Five-tier AI-client interface tools dispatched by name.
                runnerResult = try await InterfaceTools.dispatch(
                    name: name, args: args, dispatcher: self)
            } else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.methodNotFound,
                    message: "Unknown tool: \(name)"
                )
            }
            // Append a coaching hint to non-error results when a trigger fires.
            return applyHint(name: name, args: args, to: runnerResult)
        } catch let error as JSONRPCError {
            throw error
        } catch let error as VerbError {
            // VerbError covers the substrate's own refusals. Emit as a
            // tool-call result with isError set so the client can act on
            // them without losing the call ID.
            return Self.errorResult(describe(error))
        } catch let error as GeniusLocusKitError {
            return Self.errorResult(describe(error))
        } catch {
            // Anything else is genuinely out of band.
            throw JSONRPCError(
                code: JSONRPCErrorCode.toolDispatchFailure,
                message: "\(error)"
            )
        }
    }

    // MARK: - Hint injection

    /// Append a coaching hint to a successful tool result when `CoachingEngine`
    /// detects a suboptimal call pattern. Returns the result unchanged when
    /// `isError == true` or when no trigger fires.
    private func applyHint(name: String, args: [String: JSONValue], to result: JSONValue) -> JSONValue {
        guard let obj = result.objectValue,
              obj["isError"]?.boolValue == false,
              let text = obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue else {
            return result
        }
        guard let hint = CoachingEngine.hint(name: name, args: args, resultText: text) else {
            return result
        }
        return Self.textResult(text + "\nhint: " + hint)
    }

    // MARK: - Federation tool

    /// Tool name for the grant-authorized cross-estate federated search.
    /// Renamed from `crossEstateRecallToolName` (MCP-INT-01) to use the
    /// AI-client-oriented vocabulary.
    public static let federatedSearchToolName = "moot_federated_search"

    /// Run `moot_federated_search`: a grant-authorized federated read that
    /// fans across the locally-open estates the caller is entitled to
    /// read, narrows each contribution to its grant's scope, and returns
    /// the per-estate contributions.
    ///
    /// Authorization is NOT performed here. The per-estate grant gate
    /// lives entirely in GLK's `federatedRecall` — this is the I-13
    /// boundary in practice: ARIA mediates *which* locally-open estates
    /// to attempt; GLK enforces *whether* each read is granted.
    /// A per-estate `.crossEstateReadRefused` is the expected "not granted"
    /// signal and is skipped. If no estate authorizes the caller, the
    /// call is refused cleanly with an `errorResult`.
    private func runFederatedSearch(_ args: [String: JSONValue]) async throws -> JSONValue {
        let requester = try resolveRequester(args)
        let filter = try decodeFilter(args["filter"])
        let hydration = try decodeHydration(args["hydrationLevel"])
        let ordering = try decodeOrdering(args["ordering"])
        let limit = args["limit"]?.integerValue.map(Int.init)
        let frame = RecallFrame(
            filterChain: [filter],
            hydrationLevel: hydration,
            limit: limit,
            ordering: ordering
        )
        // Visit candidate sources sorted by UUID so the assembled text is
        // deterministic across runs, independent of map iteration order.
        let candidates = estates.values
            .filter { $0.estateUUID != requester.estateUUID }
            .sorted { $0.estateUUID.uuidString < $1.estateUUID.uuidString }
        var sections: [String] = []
        for source in candidates {
            let result: FederatedRecallResult
            do {
                result = try await kit.federatedRecall(frame, from: source, requestedBy: requester)
            } catch let error as GeniusLocusKitError {
                if case .crossEstateReadRefused = error { continue }
                throw error
            }
            let scoped = Self.narrow(result.drawers, to: result.grant.scope)
            sections.append(Self.renderContribution(
                source: source, grant: result.grant, drawers: scoped
            ))
        }
        guard !sections.isEmpty else {
            return Self.errorResult(
                "federated_search refused: no open estate holds an active grant naming the requester."
            )
        }
        return Self.textResult(sections.joined(separator: "\n\n"))
    }

    // MARK: - Federation helpers

    /// Resolve the requester estate from the required `requesterEstateID`
    /// argument. Must name a registered, locally-open estate.
    private func resolveRequester(_ args: [String: JSONValue]) throws -> EstateHandle {
        let raw = try requireString(args, "requesterEstateID")
        guard let uuid = UUID(uuidString: raw) else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Malformed requesterEstateID (not a UUID): \(raw)"
            )
        }
        guard let resolved = estates[uuid] else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Unknown requesterEstateID: \(raw)"
            )
        }
        return resolved
    }

    /// Narrow a source estate's recalled drawers to the rows inside the
    /// authorizing grant's scope (DECISION §10 answer assembly).
    ///
    /// PRIMARY enforcement is in GLK: `CrossEstateFederation.federatedRecall`
    /// already filtered drawers by `grant.contentLevel` before this is called.
    /// This narrowing is defense-in-depth secondary at the ARIA surface.
    private static func narrow(_ drawers: [Drawer], to scope: GrantScope) -> [Drawer] {
        switch scope {
        case .wholeEstate:
            return drawers
        case .wing(let name):
            return drawers.filter { $0.wing == name }
        case .room(let name):
            return drawers.filter { $0.room == name }
        case .latticeSubtree(let code):
            // A drawer is inside the subtree when its UDC code equals `code`
            // or descends from it on a dot boundary. The `+ "."` guard prevents
            // a bare-prefix false match (e.g. "00" vs "001").
            return drawers.filter { $0.udcCode == code || $0.udcCode.hasPrefix(code + ".") }
        case .singleRow(let id):
            return drawers.filter { $0.id == id.uuidString }
        }
    }

    /// Format one estate's authorized contribution for the federated response.
    private static func renderContribution(
        source: EstateHandle, grant: Grant, drawers: [Drawer]
    ) -> String {
        let header = "estate \(source.estateName) [\(source.estateUUID)] — grant \(grant.id), \(drawers.count) row(s)"
        let lines = drawers.prefix(50).map { drawer in
            "\(drawer.id)  [\(drawer.room)]  \(drawer.content.prefix(80))"
        }
        return ([header] + lines).joined(separator: "\n")
    }

    // MARK: - Argument decoders

    func requireString(_ args: [String: JSONValue], _ key: String) throws -> String {
        guard let value = args[key]?.stringValue else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Missing required string argument: \(key)"
            )
        }
        return value
    }

    func decodeChannel(_ value: JSONValue?) throws -> CaptureChannel {
        guard let name = value?.stringValue else { return .importedFile }
        switch name {
        case "typed": return .typed
        case "voiced": return .voiced
        case "ocr": return .ocr
        case "importedFile": return .importedFile
        case "sensor": return .sensor
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Unknown channel: \(name)"
            )
        }
    }

    func decodeSensitivity(_ value: JSONValue?) throws -> AdjectiveSensitivity {
        guard let name = value?.stringValue else { return .normal }
        switch name {
        case "normal": return .normal
        case "elevated": return .elevated
        case "restricted": return .restricted
        case "secret": return .secret
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Unknown sensitivity: \(name)"
            )
        }
    }

    /// Decode the optional `classificationScheme` arg for a capture.
    /// Absent defaults to `.udc`, preserving the prior bare-UDC behavior.
    func decodeClassificationScheme(_ value: JSONValue?) throws -> ClassificationScheme {
        guard let name = value?.stringValue else { return .udc }
        guard let scheme = ClassificationScheme(rawValue: name) else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Unknown classification scheme: \(name)"
            )
        }
        return scheme
    }

    func decodeContentKind(_ value: JSONValue?) throws -> ContentKind {
        guard let name = value?.stringValue else { return .prose }
        switch name {
        case "prose": return .prose
        case "code": return .code
        case "transcript": return .transcript
        case "list": return .list
        case "structuredJSON": return .structuredJSON
        case "imageCaption": return .imageCaption
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Unknown content kind: \(name)"
            )
        }
    }

    func decodeFilter(_ value: JSONValue?) throws -> Filter {
        guard let name = value?.stringValue else { return .unconfirmed }
        switch name {
        case "unconfirmed": return .unconfirmed
        case "userConfirmed": return .userConfirmed
        case "exportable": return .exportable
        case "contained": return .contained
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Unknown filter: \(name)"
            )
        }
    }

    func decodeHydration(_ value: JSONValue?) throws -> HydrationLevel {
        guard let name = value?.stringValue else { return .structured }
        switch name {
        case "structured": return .structured
        case "full": return .full
        case "bitmapOnly": return .bitmapOnly
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Unknown hydration level: \(name)"
            )
        }
    }

    func decodeOrdering(_ value: JSONValue?) throws -> Ordering {
        guard let name = value?.stringValue else { return .byCaptureTimeDesc }
        switch name {
        case "byCaptureTimeDesc": return .byCaptureTimeDesc
        case "byCaptureTimeAsc": return .byCaptureTimeAsc
        case "byRoomAsc": return .byRoomAsc
        case "byRelevanceDesc": return .byRelevanceDesc
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Unknown ordering: \(name)"
            )
        }
    }

    func decodeMutationKind(_ name: String) throws -> MutationKind {
        switch name {
        case "confirm": return .confirm
        case "reject": return .reject
        case "contest": return .contest
        case "resolve": return .resolve
        case "supersede": return .supersede
        case "revive": return .revive
        case "accept": return .accept
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Unsupported mutation kind: \(name)"
            )
        }
    }

    // MARK: - Result helpers

    /// MCP `tools/call` success result with a single text content block.
    public static func textResult(_ text: String) -> JSONValue {
        .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(text),
                ])
            ]),
            "isError": .bool(false),
        ])
    }

    /// MCP `tools/call` failure result. Substrate refusals come back
    /// here rather than as JSON-RPC errors so the client retains the
    /// call ID and can render the message in a tool-output panel.
    public static func errorResult(_ text: String) -> JSONValue {
        .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(text),
                ])
            ]),
            "isError": .bool(true),
        ])
    }

    private func describe(_ error: VerbError) -> String {
        switch error {
        case .notSupportedByEstate(let verb):
            return "Verb \(verb) is declared on the GLK surface but not yet implemented by the substrate."
        case .expungeNotConfirmed(let rowID):
            return "expunge of \(rowID) requires confirmation=true."
        case .emptyReanchor(let rowID):
            return "reanchor of \(rowID) requires at least one of toRoom or toUDC."
        case .underlyingEstateFailure(let verb, let reason):
            return "\(verb) failed: \(reason)"
        case .rejectedByLexicon(let verb, let noun):
            return "verb \(verb) is not accepted on noun \(noun) by the AriaLexicon acceptance matrix."
        }
    }

    private func describe(_ error: GeniusLocusKitError) -> String {
        "GeniusLocusKit error: \(error)"
    }
}

// MARK: - Server-owned defaults

extension ToolDispatcher {
    /// Default lattice anchor applied by the server when the caller supplies
    /// a `location` string instead of explicit UDC coordinates. The UDC
    /// "000.000" root is the general-knowledge default per the substrate spec.
    static let defaultLatticeAnchor = LatticeAnchor.udc("000.000")

    /// Embedding model ID placeholder. GeniusLocusKit has no
    /// `defaultEmbeddingModelID` property; "default" signals to the substrate
    /// that a concrete model will be bound when the embedding pipeline runs.
    static let defaultEmbeddingModelID = "default"
}

// MARK: - InterfaceTools

/// Static dispatch table for the five-tier AI-client interface tools.
///
/// Each of the 19 interface tools has a named `run*` function on
/// `ToolDispatcher`; this type routes from name to function, isolating
/// the dispatch logic from the tool-name string constants.
enum InterfaceTools {

    private static let names: Set<String> = [
        // Tier 1 — Core Memory
        "moot_file_memory", "moot_memory_search", "moot_update_memory",
        "moot_withdraw_memory", "moot_erase_memory", "moot_confirm_memory",
        "moot_move_memory",
        // Tier 2 — Connections
        "moot_link_memories", "moot_connection_search", "moot_connection_map",
        // Tier 3 — Knowledge Graph
        "moot_file_fact", "moot_fact_search", "moot_retire_fact",
        "moot_fact_timeline",
        // Tier 4 — Journal
        "moot_write_journal", "moot_read_journal",
        // Tier 5 — Estate
        "moot_estate_status", "moot_estate_map", "moot_estate_ping",
    ]

    static func isInterfaceTool(_ name: String) -> Bool {
        names.contains(name)
    }

    static func dispatch(
        name: String,
        args: [String: JSONValue],
        dispatcher: ToolDispatcher
    ) async throws -> JSONValue {
        switch name {
        // Tier 1
        case "moot_file_memory":       return try await dispatcher.runFileMemory(args)
        case "moot_memory_search":     return try await dispatcher.runMemorySearch(args)
        case "moot_update_memory":     return try await dispatcher.runUpdateMemory(args)
        case "moot_withdraw_memory":   return try await dispatcher.runWithdrawMemory(args)
        case "moot_erase_memory":      return try await dispatcher.runEraseMemory(args)
        case "moot_confirm_memory":    return try await dispatcher.runConfirmMemory(args)
        case "moot_move_memory":       return try await dispatcher.runMoveMemory(args)
        // Tier 2
        case "moot_link_memories":     return try await dispatcher.runLinkMemories(args)
        case "moot_connection_search": return try await dispatcher.runConnectionSearch(args)
        case "moot_connection_map":    return try await dispatcher.runConnectionMap(args)
        // Tier 3
        case "moot_file_fact":         return try await dispatcher.runFileFact(args, now: Date())
        case "moot_fact_search":       return try await dispatcher.runFactSearch(args)
        case "moot_retire_fact":       return try await dispatcher.runRetireFact(args)
        case "moot_fact_timeline":     return try await dispatcher.runFactTimeline(args)
        // Tier 4
        case "moot_write_journal":     return try await dispatcher.runWriteJournal(args, now: Date())
        case "moot_read_journal":      return try await dispatcher.runReadJournal(args)
        // Tier 5
        case "moot_estate_status":     return try await dispatcher.runEstateStatus(args)
        case "moot_estate_map":        return try await dispatcher.runEstateMap(args)
        case "moot_estate_ping":        return try await dispatcher.runEstatePing(args)
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.methodNotFound,
                message: "No handler bound for interface tool \(name)"
            )
        }
    }
}

// MARK: - Tier 1: Core Memory runners

extension ToolDispatcher {

    /// `moot_file_memory` — file a new memory drawer into the estate.
    ///
    /// The server owns infrastructure fields: lattice anchor (UDC "000.000"),
    /// embedding model ("default"), capture channel (.importedFile), source
    /// type (.agent), and addedBy (derived from the session handle). The caller
    /// supplies only the content and a free-form location hint.
    func runFileMemory(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let content = try requireString(args, "content")
        let location = try requireString(args, "location")
        let sensitivity = try decodeSensitivity(args["sensitivity"])
        let kind = try decodeContentKind(args["kind"])
        let eventTime: Date? = args["event_time"]?.stringValue.flatMap {
            ISO8601DateFormatter().date(from: $0)
        }
        // location is a caller-facing subject-matter hint; map it to the
        // room field (structural coordinate). Wing defaults to "memories";
        // future routing logic can refine this per estate topology.
        let room = location
        let frame = CaptureFrame(
            content: content,
            channel: Self.defaultChannel,
            room: room,
            latticeAnchor: Self.defaultLatticeAnchor,
            addedBy: Self.serverAddedBy,
            embeddingModelID: Self.defaultEmbeddingModelID,
            sensitivity: sensitivity,
            kind: kind,
            provenanceChannel: .mcpAgent,
            sourceType: .imported,
            eventTime: eventTime
        )
        let drawer = try await kit.capture(handle, frame)
        return Self.textResult([
            "filed memory \(drawer.id)",
            "room: \(drawer.room)",
            "lineage: \(drawer.lineageID.uuidString)",
        ].joined(separator: "\n"))
    }

    /// `moot_memory_search` — hybrid BM25+vector recall over the estate.
    ///
    /// Routes through the Recall Director (GLKRecallRequest) using the
    /// `unionBest` mode and `matrixAware` scoring by default, giving the
    /// AI client the best available ranked results without exposing the
    /// multi-lane machinery.
    func runMemorySearch(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let query = try requireString(args, "query")
        let rawLimit = args["limit"]?.integerValue.map(Int.init) ?? 20
        let filter = try decodeFilter(args["filter"])
        let explain = args["explain"]?.boolValue ?? false
        let scoringStr = args["scoring"]?.stringValue ?? "matrixAware"
        let scoring = GLKRecallScoring(rawValue: scoringStr) ?? .matrixAware
        let frame = RecallFrame(
            filterChain: [filter],
            hydrationLevel: .structured,
            limit: rawLimit,
            ordering: .byRelevanceDesc
        )
        let request = GLKRecallRequest(
            frame: frame,
            mode: .unionBest,
            scoring: scoring,
            limit: rawLimit,
            fallback: .allowDegraded,
            queryText: query
        )
        let result = try await kit.recall(handle, request)
        var lines: [String] = ["found \(result.hits.count) memory(s)"]
        for hit in result.hits.prefix(50) {
            let preview = hit.drawer?.content.prefix(120) ?? "(not hydrated)"
            let room = hit.drawer?.room ?? "?"
            lines.append("\(hit.id)  [\(room)]  \(preview)")
            if explain {
                for line in hit.explanation { lines.append("  \(line)") }
            }
        }
        return Self.textResult(lines.joined(separator: "\n"))
    }

    /// `moot_update_memory` — apply a named mutation to a memory.
    func runUpdateMemory(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let rowID = try requireString(args, "id")
        let mutationName = try requireString(args, "mutation")
        let kind = try decodeMutationKind(mutationName)
        let payload = args["note"]?.stringValue
        let frame = MutateFrame(rowID: rowID, kind: kind, payload: payload)
        try await kit.mutate(handle, frame)
        return Self.textResult("updated memory \(rowID) (\(mutationName))")
    }

    /// `moot_withdraw_memory` — soft-remove a memory from active circulation.
    func runWithdrawMemory(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let rowID = try requireString(args, "id")
        let reason = args["reason"]?.stringValue
        try await kit.withdraw(handle, WithdrawFrame(rowID: rowID, reason: reason))
        return Self.textResult("withdrew memory \(rowID)")
    }

    /// `moot_erase_memory` — hard-erase a memory. Requires `confirmed: true`.
    func runEraseMemory(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let rowID = try requireString(args, "id")
        let reason = try requireString(args, "reason")
        // Surface the caller-facing field name "confirmed" but map it to
        // the substrate's ExpungeFrame "confirmation" field.
        let confirmed = args["confirmed"]?.boolValue ?? false
        try await kit.expunge(handle, ExpungeFrame(rowID: rowID, reason: reason, confirmation: confirmed))
        return Self.textResult("erased memory \(rowID)")
    }

    /// `moot_confirm_memory` — shortcut for moot_update_memory with mutation=confirm.
    func runConfirmMemory(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let rowID = try requireString(args, "id")
        let payload = args["note"]?.stringValue
        let frame = MutateFrame(rowID: rowID, kind: .confirm, payload: payload)
        try await kit.mutate(handle, frame)
        return Self.textResult("confirmed memory \(rowID)")
    }

    /// `moot_move_memory` — reanchor a memory to a new location.
    ///
    /// The caller provides a free-form `location` hint; the server maps it
    /// to the substrate's `toRoom` field (same convention as `moot_file_memory`).
    func runMoveMemory(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let rowID = try requireString(args, "id")
        let location = try requireString(args, "location")
        // location maps to room; no UDC change at this surface layer.
        try await kit.reanchor(handle, ReanchorFrame(rowID: rowID, toRoom: location, toLattice: nil))
        return Self.textResult("moved memory \(rowID) to \(location)")
    }
}

// MARK: - Tier 2: Connections runners

extension ToolDispatcher {

    /// Map caller-facing kind strings to the substrate's `TunnelKind` enum.
    ///
    /// The caller vocabulary ("relates", "precedes", etc.) is more natural for
    /// AI clients than the substrate names. Pass-through of substrate names is
    /// also accepted so advanced callers can target specific kinds directly.
    private static func tunnelKind(for kindString: String) -> TunnelKind {
        switch kindString {
        // Caller-friendly vocabulary
        case "relates":     return .references
        case "precedes":    return .blocks
        case "contradicts": return .contradicts
        case "supports":    return .validates
        case "refines":     return .elaborates
        case "exemplifies": return .covers
        case "extends":     return .derivesFrom
        // Pass-through substrate names (for advanced callers)
        case "supersedes":  return .supersedes
        case "references":  return .references
        case "blocks":      return .blocks
        case "validates":   return .validates
        case "derivesFrom": return .derivesFrom
        case "covers":      return .covers
        case "elaborates":  return .elaborates
        case "respondsTo":  return .respondsTo
        default:            return .references
        }
    }

    /// `moot_link_memories` — create a directed connection between two memories.
    ///
    /// Resolves source and target drawer coordinates (wing/room) by looking up
    /// both drawers by ID via `estate.allDrawers()`, then delegates to
    /// `Estate.capture(TunnelCaptureFrame)` — the same path the existing
    /// tunnel tests use. No GLK kit-level captureTunnel verb exists; the
    /// estate actor is the direct write path.
    func runLinkMemories(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let fromID = try requireString(args, "from_id")
        let toID = try requireString(args, "to_id")
        let kindString = try requireString(args, "kind")
        let label = args["label"]?.stringValue ?? kindString
        let kind = Self.tunnelKind(for: kindString)
        // Resolve wing/room by looking up both drawers. `estate.allDrawers()`
        // is public on LocusKit.Estate; GLK has no direct getDrawer(id:) call.
        let estate = try await kit.estate(for: handle)
        let allDrawers = try await estate.allDrawers()
        guard let source = allDrawers.first(where: { $0.id == fromID }) else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Memory not found: \(fromID)"
            )
        }
        guard let target = allDrawers.first(where: { $0.id == toID }) else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Memory not found: \(toID)"
            )
        }
        let frame = TunnelCaptureFrame(
            sourceWing: source.wing,
            sourceRoom: source.room,
            targetWing: target.wing,
            targetRoom: target.room,
            label: label,
            addedBy: Self.serverAddedBy,
            sourceDrawerId: fromID,
            targetDrawerId: toID,
            kind: kind,
            originClass: .derived
        )
        let tunnel = try await estate.capture(frame)
        return Self.textResult("linked \(fromID) → \(toID) via \(label) (\(tunnel.id))")
    }

    /// `moot_connection_search` — find connections going out from a memory.
    ///
    /// Reads all tunnels from the estate and filters by `sourceDrawerId`.
    func runConnectionSearch(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let fromID = try requireString(args, "from_id")
        let estate = try await kit.estate(for: handle)
        let allTunnels = try await estate.allTunnels()
        // Keep only non-tombstoned tunnels originating from this drawer.
        let outgoing = allTunnels.filter {
            $0.sourceDrawerId == fromID && $0.tombstonedAt == nil
        }
        let lines = outgoing.prefix(50).map { t -> String in
            "\(t.id)  → \(t.targetDrawerId ?? "\(t.targetWing)/\(t.targetRoom)")  [\(t.label)]"
        }
        let header = "connections from \(fromID): \(outgoing.count)"
        return Self.textResult(([header] + lines).joined(separator: "\n"))
    }

    /// `moot_connection_map` — find connections pointing to a memory.
    ///
    /// Reads all tunnels from the estate and filters by `targetDrawerId`.
    func runConnectionMap(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let toID = try requireString(args, "to_id")
        let estate = try await kit.estate(for: handle)
        let allTunnels = try await estate.allTunnels()
        // Keep only non-tombstoned tunnels pointing to this drawer.
        let incoming = allTunnels.filter {
            $0.targetDrawerId == toID && $0.tombstonedAt == nil
        }
        let lines = incoming.prefix(50).map { t -> String in
            "\(t.id)  \(t.sourceDrawerId ?? "\(t.sourceWing)/\(t.sourceRoom)") →  [\(t.label)]"
        }
        let header = "connections to \(toID): \(incoming.count)"
        return Self.textResult(([header] + lines).joined(separator: "\n"))
    }
}

// MARK: - Tier 3: Knowledge Graph runners

extension ToolDispatcher {

    /// `moot_file_fact` — assert a subject–predicate–object triple.
    ///
    /// `now` is sampled at the `InterfaceTools.dispatch` boundary so this
    /// runner is deterministic — it never calls `Date()` itself.
    func runFileFact(_ args: [String: JSONValue], now: Date) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let subject = try requireString(args, "subject")
        let predicate = try requireString(args, "predicate")
        let object = try requireString(args, "object")
        let sourceDrawerID = args["source_id"]?.stringValue ?? ""
        let fact = try await kit.captureKGFact(
            handle,
            subject: subject,
            predicate: predicate,
            object: object,
            sourceDrawerID: sourceDrawerID,
            now: now
        )
        return Self.textResult("filed fact \(fact.id): [\(subject)] \(predicate) [\(object)]")
    }

    /// `moot_fact_search` — retrieve all currently-active KG facts.
    func runFactSearch(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let allFacts = try await kit.recallKGFacts(handle)
        // Optional query: substring match across subject, predicate, and object.
        // Omitting query returns all active facts (the unfiltered case).
        let query = args["query"]?.stringValue?.lowercased()
        let facts = query.map { q in
            allFacts.filter {
                $0.subject.lowercased().contains(q) ||
                $0.predicate.lowercased().contains(q) ||
                $0.object.lowercased().contains(q)
            }
        } ?? allFacts
        let lines = facts.prefix(100).map { f -> String in
            "\(f.id)  [\(f.subject)] \(f.predicate) [\(f.object)]"
        }
        let header = query != nil
            ? "facts matching \"\(args["query"]?.stringValue ?? "")\": \(facts.count)"
            : "facts: \(facts.count)"
        return Self.textResult(([header] + lines).joined(separator: "\n"))
    }

    /// `moot_retire_fact` — invalidate a KG fact by row ID.
    func runRetireFact(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let rowID = try requireString(args, "id")
        try await kit.retireKGFact(handle, rowID: rowID)
        return Self.textResult("retired fact \(rowID)")
    }

    /// `moot_fact_timeline` — read all KG facts including retired ones.
    ///
    /// Uses `recallKGFacts` which returns active facts. The timeline
    /// view is a superset that may include retired facts; for now it
    /// returns the same active set as `moot_fact_search` and notes the
    /// timeline semantics for future expansion.
    func runFactTimeline(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let facts = try await kit.recallKGFacts(handle)
        let lines = facts.prefix(200).map { f -> String in
            let filed = ISO8601DateFormatter().string(from: f.filedAt)
            return "\(filed)  \(f.id)  [\(f.subject)] \(f.predicate) [\(f.object)]"
        }
        let header = "fact timeline: \(facts.count) active"
        return Self.textResult(([header] + lines).joined(separator: "\n"))
    }
}

// MARK: - Tier 4: Journal runners

extension ToolDispatcher {

    /// Server identity written into journal entries filed through the MCP surface.
    private static let mcpAgentName = "mcp-agent"

    /// `moot_write_journal` — write a diary entry for session continuity.
    ///
    /// Encodes `DiaryActorClass.mcpAgent` (raw=2) at bits 7–9 of the
    /// operational bitmap, per DiaryOperational.swift §5.6 layout.
    /// `now` is sampled at the `InterfaceTools.dispatch` boundary so this
    /// runner is deterministic — it never calls `Date()` itself.
    func runWriteJournal(_ args: [String: JSONValue], now: Date) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let entry = try requireString(args, "entry")
        let agentName = args["agent"]?.stringValue ?? Self.mcpAgentName
        // Encode DiaryActorClass.mcpAgent (raw 2) at bits 7–9 (3-bit field).
        let actorBits = Int64(DiaryActorClass.mcpAgent.rawValue) << 7
        let diaryEntry = DiaryEntry(
            agentName: agentName,
            entry: entry,
            topic: "mcp-session",
            wing: "agents",
            room: "diary",
            filedAt: now,
            embeddingModelID: Self.defaultEmbeddingModelID,
            operationalBitmap: actorBits
        )
        try await kit.addDiaryEntry(in: handle, diaryEntry)
        return Self.textResult("wrote journal entry for \(agentName)")
    }

    /// `moot_read_journal` — read recent journal entries for an agent.
    func runReadJournal(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let agentName = args["agent"]?.stringValue ?? Self.mcpAgentName
        let lastN = args["last_n"]?.integerValue.map(Int.init) ?? 10
        let entries = try await kit.readDiaryEntries(in: handle, agentName: agentName, lastN: lastN)
        let lines = entries.map { e -> String in
            let filed = ISO8601DateFormatter().string(from: e.filedAt)
            return "[\(filed)]  \(e.entry.prefix(200))"
        }
        let header = "journal for \(agentName): \(entries.count) entry(s)"
        return Self.textResult(([header] + lines).joined(separator: "\n"))
    }
}

// MARK: - Tier 5: Estate runners

extension ToolDispatcher {

    /// `moot_estate_status` — return a summary of the estate.
    ///
    /// Appends the static `ARIASessionProtocol` block unconditionally
    /// so every cold-start call receives enough context to navigate the
    /// full surface without prior knowledge of ARIA.
    func runEstateStatus(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let estate = try await kit.estate(for: handle)
        let drawers = try await estate.allDrawers()
        let active = drawers.filter { $0.tombstonedAt == nil }
        let wings = Set(active.map { $0.wing }).sorted()
        let facts = try await kit.recallKGFacts(handle)
        let stats = [
            "estate: \(handle.estateName) [\(handle.estateUUID)]",
            "memories: \(active.count) active (\(drawers.count) total)",
            "wings: \(wings.joined(separator: ", "))",
            "kg facts: \(facts.count) active",
            "status: connected",
        ].joined(separator: "\n")
        return Self.textResult(stats + Self.ARIASessionProtocol)
    }

    /// `moot_estate_map` — return the estate's structural map with memory counts.
    func runEstateMap(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let estate = try await kit.estate(for: handle)
        let drawers = try await estate.allDrawers()
        let active = drawers.filter { $0.tombstonedAt == nil }
        // Group by wing then room, counting drawers per location.
        var map: [String: [String: Int]] = [:]
        for d in active {
            map[d.wing, default: [:]][d.room, default: 0] += 1
        }
        var lines: [String] = ["estate map: \(handle.estateName)"]
        for wing in map.keys.sorted() {
            lines.append("  \(wing)/")
            for room in (map[wing] ?? [:]).keys.sorted() {
                let count = map[wing]?[room] ?? 0
                lines.append("    \(room): \(count)")
            }
        }
        return Self.textResult(lines.joined(separator: "\n"))
    }

    /// `moot_estate_ping` — confirm the estate handle is live and the server
    /// process is reachable.
    ///
    /// ARIA_MCP is a long-running stdio process that opens one estate on
    /// startup and holds it for the session. There is no transient
    /// disconnection state: the handle is either registered (open) or not.
    /// This tool resolves the handle — if it succeeds, the estate is live;
    /// if it throws `estateNotOpen`, the server needs restarting. No drawer
    /// scan is performed; this is a true lightweight ping.
    func runEstatePing(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        // Resolving the handle is the entire check. If the estate were not
        // open, resolveHandle would throw estateNotOpen and dispatch would
        // surface it as isError:true before this line runs.
        return Self.textResult(
            "pong: estate \(handle.estateName) [\(handle.estateUUID)] is live"
        )
    }
}

// MARK: - Server defaults (private)

private extension ToolDispatcher {
    /// Default capture channel for server-filed memories: `importedFile` signals
    /// that content was imported through an automated interface (the MCP surface),
    /// not typed directly by a user.
    static let defaultChannel: CaptureChannel = .importedFile

    /// Actor identifier the server writes into rows it files. Uses a stable
    /// constant so the source is identifiable in the audit trail.
    static let serverAddedBy = "aria-mcp-server"
}

// MARK: - ClassificationScheme

/// The classification scheme a lattice-anchor code belongs to.
///
/// Per spec §5.8 (dual-scheme model), an anchor code may be a UDC code
/// or an MDCC code. `moot_file_memory` (and other capture paths) accept
/// a `classificationScheme` discriminator so the scheme can be validated
/// and echoed at the ARIA boundary. The substrate's `LatticeAnchor` does
/// not yet carry a scheme tag (that is a separate storage migration),
/// so this type lives in ARIA_MCP, not LocusKit.
public enum ClassificationScheme: String, Sendable, CaseIterable {
    case udc
    case mdcc
}
