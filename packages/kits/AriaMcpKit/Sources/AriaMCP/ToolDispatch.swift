import Foundation
import GeniusLocusKit
import LocusKit
// Scoped imports: pull ONLY the lifecycle-cluster classifier from
// SubstrateTypes. A blanket `import SubstrateTypes` collides with LocusKit
// on `LatticeAnchor.udc` (both modules export `LatticeAnchor`), so we import
// just the two enums the fact-timeline tag needs.
import enum SubstrateTypes.RowState
import enum SubstrateTypes.RowStateCluster

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

    /// In-process registry tracking async vault import and export jobs.
    /// Shared across all dispatchers derived from this one via
    /// `registering(_:)` so job polling works regardless of which estate
    /// is the dispatch target. Actor-isolated (Sendable) — safe in the
    /// immutable Sendable struct.
    let jobRegistry: VaultJobRegistry

    /// Session-scoped ledger of drawer ids surfaced by `moot_memory_search`.
    /// Consulted by dereference verbs to trigger reward-trace marking (B-10a).
    /// Actor-isolated (Sendable) — safe in the immutable Sendable struct.
    /// Shared across dispatchers derived via `registering(_:)` so a search
    /// in one estate and a dereference in another within the same session
    /// are still correlated.
    let recallLedger: SurfacedRecallLedger

    /// Construct a single-estate dispatcher. `handle` is registered as
    /// the sole addressable estate and is the default target for calls
    /// that omit `estateID`. This is the v1.0 path; every existing
    /// construction site uses exactly this initializer.
    public init(kit: GeniusLocusKit, handle: EstateHandle) {
        self.kit = kit
        self.handle = handle
        self.estates = [handle.estateUUID: handle]
        self.jobRegistry = VaultJobRegistry()
        self.recallLedger = SurfacedRecallLedger()
    }

    /// Return a dispatcher that also addresses `additional`, with the
    /// same default estate. Value-semantic (returns a new dispatcher)
    /// because `ToolDispatcher` is an immutable `Sendable` struct; the
    /// kit reference and default `handle` are carried over unchanged.
    /// Re-registering an estate already present replaces its entry,
    /// which is harmless because handles are keyed by a stable UUID.
    /// The existing `jobRegistry` is forwarded so polling still works
    /// on dispatchers produced by `registering(_:)`.
    public func registering(_ additional: EstateHandle) -> ToolDispatcher {
        var next = estates
        next[additional.estateUUID] = additional
        return ToolDispatcher(kit: kit, handle: handle, estates: next,
                              jobRegistry: jobRegistry, recallLedger: recallLedger)
    }

    /// Private designated initializer carrying an explicit estate map,
    /// a shared job registry, and a shared recall ledger. Used by
    /// `registering(_:)`; the public `init(kit:handle:)` is the only
    /// construction path external callers use.
    private init(
        kit: GeniusLocusKit, handle: EstateHandle,
        estates: [UUID: EstateHandle], jobRegistry: VaultJobRegistry,
        recallLedger: SurfacedRecallLedger
    ) {
        self.kit = kit
        self.handle = handle
        self.estates = estates
        self.jobRegistry = jobRegistry
        self.recallLedger = recallLedger
    }

    /// Resolve the estate a tool call targets from its `estateID`
    /// argument. The default (omitted `estateID`) returns the default
    /// estate's handle, so the single-estate v1.0 behavior is identical
    /// to today. A present `estateID` must be a UUID string naming a
    /// registered estate; a malformed or unregistered value is an
    /// out-of-band client error (`invalidParams`), consistent with the
    /// other enum decoders in this file.
    private func resolveHandle(_ args: [String: JSONValue]) throws -> EstateHandle {
        guard let raw = try optionalString(args["estateID"], argument: "estateID") else { return handle }
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
            if try optionalBool(args["teachme"], argument: "teachme") == true {
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
                    resolveHandle: resolveHandle, jobRegistry: jobRegistry)
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
        let filterChain = try decodeFilterChain(args["filter"])
        // Absent `hydrationLevel` defaults to .full so content blobs are present
        // in the assembled response text — federated search renders drawer content
        // as a preview and the caller cannot evaluate relevance on empty strings.
        // When present, the value is passed through `decodeHydration` which throws
        // `invalidParams` on unknown strings. This is fail-CLOSED: on a federated
        // and privacy-sensitive surface, unknown garbage must never silently grant
        // maximum content exposure. Mirrors the same validation discipline as the
        // Rust `run_federated_search` parser: absent→Full, valid→honored,
        // invalid→error. Both verticals must be identical.
        let hydration: HydrationLevel
        if args["hydrationLevel"] == nil {
            // Absent: default to .full (content preview requires the content blob).
            hydration = .full
        } else {
            // Present: decode strictly — unknown value → invalidParams (fail-closed).
            hydration = try decodeHydration(args["hydrationLevel"])
        }
        let ordering = try decodeOrdering(args["ordering"])
        let limit = try optionalInt(args["limit"], argument: "limit")
        let frame = RecallFrame(
            filterChain: filterChain,
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

    private func optionalString(_ value: JSONValue?, argument: String) throws -> String? {
        guard let value else { return nil }
        guard let name = value.stringValue else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "\(argument) must be a string; omit it to use the default"
            )
        }
        return name
    }

    private func optionalBool(_ value: JSONValue?, argument: String) throws -> Bool? {
        guard let value else { return nil }
        guard let flag = value.boolValue else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "\(argument) must be a boolean; omit it to use the default"
            )
        }
        return flag
    }

    private func optionalInt(_ value: JSONValue?, argument: String) throws -> Int? {
        guard let value else { return nil }
        guard let raw = value.integerValue else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "\(argument) must be an integer; omit it to use the default"
            )
        }
        return Int(raw)
    }

    func decodeChannel(_ value: JSONValue?) throws -> CaptureChannel {
        guard let name = try optionalString(value, argument: "channel") else { return .importedFile }
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
        guard let name = try optionalString(value, argument: "sensitivity") else { return .normal }
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

    /// Decode the optional `exportability` arg for a capture or update call.
    ///
    /// Absent → `.private_` (privacy-preserving default; all existing callers
    /// continue to produce private drawers — DEBT-1 write-side fix).
    /// Accepted string values mirror the `AdjectiveExportability` case names:
    /// `"private"` → `.private_`, `"public"` → `.public_`.
    func decodeExportability(_ value: JSONValue?) throws -> AdjectiveExportability {
        guard let name = try optionalString(value, argument: "exportability") else { return .private_ }
        switch name {
        case "private": return .private_
        case "public": return .public_
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Unknown exportability: \(name). Accepted values: private, public"
            )
        }
    }

    /// Decode the optional `classificationScheme` arg for a capture.
    /// Absent defaults to `.udc`, preserving the prior bare-UDC behavior.
    func decodeClassificationScheme(_ value: JSONValue?) throws -> ClassificationScheme {
        guard let name = try optionalString(value, argument: "classificationScheme") else { return .udc }
        guard let scheme = ClassificationScheme(rawValue: name) else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Unknown classification scheme: \(name)"
            )
        }
        return scheme
    }

    func decodeContentKind(_ value: JSONValue?) throws -> ContentKind {
        guard let name = try optionalString(value, argument: "kind") else { return .prose }
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

    func decodeFilterChain(_ value: JSONValue?) throws -> [Filter] {
        guard let name = try optionalString(value, argument: "filter") else { return [] }
        switch name {
        case "unconfirmed": return [.unconfirmed]
        case "userConfirmed": return [.userConfirmed]
        case "exportable": return [.exportable]
        case "contained": return [.contained]
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Unknown filter: \(name)"
            )
        }
    }

    func decodeHydration(_ value: JSONValue?) throws -> HydrationLevel {
        // Absent hydrationLevel defaults to .structured.
        // Present but non-string (e.g. a JSON number or null) is a protocol
        // violation — fail loudly with invalidParams rather than silently
        // accepting malformed input as the default. Mirrors the established
        // idiom for decodeFilter, decodeOrdering, and decodeMutationKind in
        // this file, and the Rust decode_hydration_level fix in dispatch.rs.
        guard let name = try optionalString(value, argument: "hydrationLevel") else { return .structured }
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
        guard let name = try optionalString(value, argument: "ordering") else { return .byCaptureTimeDesc }
        switch name {
        case "byCaptureTimeDesc": return .byCaptureTimeDesc
        case "byCaptureTimeAsc": return .byCaptureTimeAsc
        case "byRoomAsc": return .byRoomAsc
        // byRelevanceDesc: LocusKit has no relevance signal in its Ordering
        // enum (that case was removed because LocusKit cannot score). At the
        // ARIA surface the client spelling is preserved as a compatibility
        // input: when a caller sends "byRelevanceDesc", the request is routed
        // to the scored recall path (GLKRecallRequest/recall_scored with
        // mode=unionBest), whose results ARE relevance-ordered by the scoring
        // machinery. The RecallFrame.ordering field is set to byCaptureTimeDesc
        // as a stable tie-break within the scored layer; the final result order
        // is driven by the score values, not the page order.
        // Mirrors Rust decode_ordering in interface_tools.rs.
        case "byRelevanceDesc": return .byCaptureTimeDesc
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
        // Exportability axis — DEBT-1 write path.
        // String spellings mirror decodeExportability: "private" and "public"
        // are the human-readable forms; the substrate enum names (.private_,
        // .public_) use trailing underscores to avoid Swift keyword collisions.
        case "correctExportability(private)": return .correctExportability(.private_)
        case "correctExportability(public)": return .correctExportability(.public_)
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Unsupported mutation kind: \(name). Accepted: confirm, reject, contest, resolve, supersede, revive, accept, correctExportability(private), correctExportability(public)"
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
            // notSupportedByEstate is a runtime refusal from the estate — not
            // a missing implementation. Estates that do not expose a verb (e.g.
            // propose / associate, which are substrate-driven Brain-layer verbs
            // not callable by external clients) return this error by design.
            return "Verb \(verb) is not callable on this estate: the estate refused the operation. propose and associate are substrate-driven verbs; for other verbs, check the estate's configuration."
        case .expungeNotConfirmed(let rowID):
            return "expunge of \(rowID) requires confirmation=true."
        case .emptyReanchor(let rowID):
            return "reanchor of \(rowID) requires at least one of toRoom or toUDC."
        case .underlyingEstateFailure(let verb, let reason):
            return "\(verb) failed: \(reason)"
        case .rejectedByLexicon(let verb, let noun):
            return "verb \(verb) is not accepted on noun \(noun) by the AriaLexicon acceptance matrix."
        case .crossKitVectorDeleteFailed(let rowID, let reason):
            // The LocusKit storage expunge succeeded (verbatim content is gone) but
            // the vector embedding in VectorKit or CorpusKit was NOT deleted. Privacy
            // contract: the expunge is INCOMPLETE. The caller must NOT report this
            // row as fully deleted — the vector embedding is still semantically
            // recoverable. Retry the expunge or surface this error to the user.
            return "expunge of \(rowID) is incomplete: the LocusKit content was removed but the vector embedding survived (\(reason)). Retry the expunge — do not report this row as deleted."
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

    /// Embedding model ID that selects the deterministic vector provider.
    /// GeniusLocusKit resolves "default" to `EmbeddingModelConfig.deterministic`
    /// — the permanent, federation-grade float vector lane (Lane D). The
    /// deterministic provider uses FNV-1a tokenization + FloatSimHash projection,
    /// is model-free, and produces byte-identical vectors cross-device and
    /// cross-port. This is what federation requires: reproducible without any
    /// model bundle or on-device inference runtime.
    ///
    /// The learned semantic vector (MiniLM/MPNet/Gemma model providers) is an
    /// ADDITIVE v1.1 on-device lane — a richer, model-dependent signal that
    /// enhances on-device search but cannot serve as the federation vector
    /// (model-dependent → not reproducible cross-device). It does not replace
    /// the deterministic vector; both coexist as separate lanes.
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
        // Maintenance / admin
        case "moot_reindex":           return try await dispatcher.runReindex(args)
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
        let exportability = try decodeExportability(args["exportability"])
        let kind = try decodeContentKind(args["kind"])
        let eventTime: Date?
        if let rawEventTime = try optionalString(args["event_time"], argument: "event_time") {
            guard let parsed = ISO8601DateFormatter().date(from: rawEventTime) else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "event_time is not a valid ISO8601 instant: \(rawEventTime)"
                )
            }
            eventTime = parsed
        } else {
            eventTime = nil
        }
        // D-A: `impatient` is an execution option on the write verb, mirroring
        // how `scoring` is an option on the recall verb — it is threaded to the
        // GLK verb param, NOT stamped onto the CaptureFrame schema. Default
        // false = regular mode (write returns immediately; encoding is
        // background). True = inline-encode before returning.
        let impatient = try optionalBool(args["impatient"], argument: "impatient") ?? false
        let mode: WriteMode = impatient ? .impatient : .regular
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
            eventTime: eventTime,
            exportability: exportability
        )
        // Mode-aware capture: regular enqueues the encode job (background
        // semantic indexing); impatient encodes inline before returning.
        let drawer = try await kit.capture(handle, frame, mode: mode)
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
    ///
    /// B-10a: origin is set to `.external` so the RecallDirector writes
    /// recall-trace rows for the reward pipeline. The ARIA_MCP boundary is
    /// the ONLY place that sets `.external` — internal callers (dreaming,
    /// lenses, recipes) must NOT. Full hydration is used (content blobs are
    /// needed for the content preview; `.structured` would strip them).
    func runMemorySearch(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let query = try requireString(args, "query")
        let rawLimit = try optionalInt(args["limit"], argument: "limit") ?? 20
        let filterChain = try decodeFilterChain(args["filter"])
        let explain = try optionalBool(args["explain"], argument: "explain") ?? false
        // Decode optional `scoring`. Absent keeps the documented default
        // (matrixAware). An unknown NON-EMPTY string is a client error and
        // fails CLOSED with invalidParams — coercing it to matrixAware would
        // silently run a different scoring mode than asked and hide the typo.
        // Mirrors decodeOrdering (strict) and the Rust run_memory_search.
        let scoring: GLKRecallScoring
        if let scoringStr = try optionalString(args["scoring"], argument: "scoring") {
            guard let decoded = GLKRecallScoring(rawValue: scoringStr) else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "Unknown scoring: \(scoringStr). Valid: raw, rrf, matrixAware"
                )
            }
            scoring = decoded
        } else {
            scoring = .matrixAware
        }
        // Decode optional ordering. "byRelevanceDesc" is a compatibility spelling
        // that routes through the scored recall pipeline — the results ARE
        // relevance-ordered because recall_scored/unionBest ranks by score.
        // All other orderings are decoded strictly; unknown values throw invalidParams.
        // The decoded ordering goes into the RecallFrame as a stable tie-break;
        // the scored path's final order is determined by scores, not page order.
        // Full hydration: the caller is a human-facing AI client; the content
        // preview in the search result requires the content blob. Structured
        // hydration strips content blobs and would render every result as an
        // empty-content preview.
        let ordering = try decodeOrdering(args["ordering"])
        let frame = RecallFrame(
            filterChain: filterChain,
            hydrationLevel: .full,
            limit: rawLimit,
            // ordering: decoded above. byCaptureTimeDesc is the default and the
            // fallback for "byRelevanceDesc". The scored path (unionBest +
            // queryText) produces relevance-ordered results regardless of this
            // tie-break field.
            ordering: ordering
        )
        let request = GLKRecallRequest(
            frame: frame,
            mode: .unionBest,
            scoring: scoring,
            limit: rawLimit,
            fallback: .allowDegraded,
            queryText: query,
            origin: .external  // B-10a: ARIA boundary is external origin
        )
        let result = try await kit.recall(handle, request)
        // Record surfaced drawer ids in the session ledger so dereference verbs
        // can trigger reward-trace marking (DESIGN_TRACE_REWARD_2026-06-12
        // § session-ledger).
        let now = Date()
        let surfacedIDs = result.hits.compactMap { $0.drawer?.id }
        if !surfacedIDs.isEmpty {
            await recallLedger.recordSurfaced(surfacedIDs, at: now)
        }
        var lines: [String] = ["found \(result.hits.count) memory(s)"]
        for hit in result.hits.prefix(50) {
            let preview = hit.drawer?.content.prefix(120) ?? "(not hydrated)"
            let room = hit.drawer?.room ?? "?"
            lines.append("\(hit.id)  [\(room)]  \(preview)")
            if explain {
                for line in hit.explanation { lines.append("  \(line)") }
            }
        }
        // Recall provenance: surface the dense-lane status and any degraded stages
        // so callers can distinguish retrieval quality (DECISION_EMBEDDING_INFERENCE_SEAM_2026-06-12).
        //
        // denseLaneStatus non-nil means the dense float vector lane (Lane D) did not
        // contribute hits. Lane D uses the deterministic embedding provider (FNV-1a
        // tokenization + FloatSimHash projection — permanent federation-grade vector,
        // reproducible and model-free). Callers use this to detect when ranking came
        // from structural/BM25 lanes only rather than the vector lane.
        //
        // The learned semantic vector (MiniLM/MPNet/Gemma) is an ADDITIVE v1.1
        // on-device lane — it does not replace the deterministic lane; both coexist.
        //
        // degradedStages lists every pipeline stage that was skipped due to a recoverable
        // error. An empty array means every attempted stage succeeded (happy path).
        //
        // Format: a single "recall_provenance:" status line, always present, never blank.
        // This lets the LLM caller distinguish:
        //   - vector+structural: denseLaneStatus nil, degradedStages empty
        //     (deterministic Lane D + BM25/structural; capture surface, not learned meaning)
        //   - structural-only or BM25-only fallback: denseLaneStatus set (Lane D dark)
        //   - degraded: degradedStages non-empty
        //   - unavailable: denseLaneStatus "dark:…" and degradedStages may overlap
        let provenanceParts: [String]
        if let darkReason = result.denseLaneStatus {
            // Dense vector lane (Lane D) was dark — ranking came from structural/BM25
            // lanes only. Surface the reason so the caller knows vector scoring did not
            // contribute. Honest-labeling requirement per the embedding ADR.
            provenanceParts = ["dense_lane:\(darkReason)"]
        } else {
            // Lane D active: deterministic vector (FNV-1a + FloatSimHash) + structural/BM25 ranking.
            provenanceParts = ["dense_lane:active"]
        }
        let degradedPart: String
        if result.degradedStages.isEmpty {
            degradedPart = "degraded_stages:none"
        } else {
            degradedPart = "degraded_stages:[\(result.degradedStages.joined(separator: ","))]"
        }
        lines.append("recall_provenance: \((provenanceParts + [degradedPart]).joined(separator: " "))")
        return Self.textResult(lines.joined(separator: "\n"))
    }

    /// Note that a drawer id was "used" (acted upon) by a dereference verb.
    ///
    /// If the id is present in the session ledger (i.e., it was surfaced by a
    /// prior `moot_memory_search` in this session), call `kit.markRecallUsed`
    /// so the dreaming daemon's reward sweep assigns reward 1.0 for that
    /// drawer's trace rows (DESIGN_TRACE_REWARD_2026-06-12).
    ///
    /// Layer discipline: ARIA → GLK → LocusKit. `markRecallUsed` is the GLK
    /// verb; we must not call LocusKit directly.
    ///
    /// Failures are silenced — a reward-marking failure must never break the
    /// dereference verb's primary result.
    private func noteUsage(_ rowID: String, handle: EstateHandle) async {
        guard let entry = await recallLedger.entry(for: rowID) else { return }
        // Use the surfaced-at time as `now` so the retention window is
        // anchored to when the memory was shown, not when it was acted on.
        // This matches the Rust note_usage which passes surfaced_at+1s.
        // We use Date() here (current wall time) because the retention window
        // is 30 days and a same-session dereference is always within that window.
        do {
            _ = try await kit.markRecallUsed(handle, target: rowID, now: entry.surfacedAt)
        } catch {
            // Best-effort: reward marking must not break the primary verb.
        }
    }

    /// `moot_update_memory` — apply a named mutation to a memory.
    func runUpdateMemory(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let rowID = try requireString(args, "id")
        let mutationName = try requireString(args, "mutation")
        let kind = try decodeMutationKind(mutationName)
        let payload = try optionalString(args["note"], argument: "note")
        // Note usage before the primary verb so reward marking is attempted even
        // if the primary verb fails (surfaced id was found, user tried to act on it).
        await noteUsage(rowID, handle: handle)
        let frame = MutateFrame(rowID: rowID, kind: kind, payload: payload)
        try await kit.mutate(handle, frame)
        return Self.textResult("updated memory \(rowID) (\(mutationName))")
    }

    /// `moot_withdraw_memory` — soft-remove a memory from active circulation.
    func runWithdrawMemory(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let rowID = try requireString(args, "id")
        let reason = try optionalString(args["reason"], argument: "reason")
        // Note usage: withdrawing a surfaced drawer means the user acted on it.
        await noteUsage(rowID, handle: handle)
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
        let confirmed = try optionalBool(args["confirmed"], argument: "confirmed") ?? false
        try await kit.expunge(handle, ExpungeFrame(rowID: rowID, reason: reason, confirmation: confirmed))
        return Self.textResult("erased memory \(rowID)")
    }

    /// `moot_confirm_memory` — shortcut for moot_update_memory with mutation=confirm.
    func runConfirmMemory(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let rowID = try requireString(args, "id")
        let payload = try optionalString(args["note"], argument: "note")
        // Note usage: confirming a surfaced drawer means the user acted on it.
        await noteUsage(rowID, handle: handle)
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
        // Note usage: moving a surfaced drawer means the user acted on it.
        await noteUsage(rowID, handle: handle)
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
        let label = try optionalString(args["label"], argument: "label") ?? kindString
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
        let sourceDrawerID = try optionalString(args["source_id"], argument: "source_id") ?? ""
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
        let queryRaw = try optionalString(args["query"], argument: "query")
        let query = queryRaw?.lowercased()
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
            ? "facts matching \"\(queryRaw ?? "")\": \(facts.count)"
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

    /// `moot_fact_timeline` — read all KG facts in chronological order,
    /// including retired ones, to trace how the estate's structured
    /// knowledge evolved.
    ///
    /// Delegates to `GeniusLocusKit.recallKGFactTimeline`, which reads every
    /// row ever filed regardless of lifecycle state (active, withdrawn,
    /// expired, decayed, superseded, rejected, tombstoned).  Each row's
    /// lifecycle tag is derived from the canonical `RowStateAutomaton`
    /// cluster: the state raw in bits 0–5 of `adjectiveBitmap` is classified
    /// by `RowState.cluster(ofRawState:)` (`cluster(s) = (s>>4)&0x3`). Cluster
    /// A is active/believed; clusters B and C are retired. The tag carries the
    /// retired cluster letter, not the raw state.
    ///
    /// Optional `entity` arg: when present, only facts whose subject or
    /// object contains the value (case-insensitive) are returned.  This
    /// matches the Rust port's entity-filter capability so both ports
    /// are parity-aligned on the full tool contract.
    ///
    /// Distinct from `moot_fact_search`, which returns active facts only.

    /// Render a retired lifecycle cluster as its single-letter label for the
    /// fact-timeline tag (`retired(B)` / `retired(C)`). Kept identical to the
    /// Rust port's `cluster_label` so both ports emit byte-identical tags.
    /// Cluster A is never passed here (it renders as the bare `active` tag).
    private static func clusterLabel(_ cluster: RowStateCluster) -> String {
        switch cluster {
        case .a: return "A"
        case .b: return "B"
        case .c: return "C"
        }
    }

    /// Derive the fact-timeline lifecycle tag from an `adjectiveBitmap` value.
    ///
    /// The tag comes from the canonical `RowStateAutomaton` cluster — the SAME
    /// partition (`cluster(s) = (s>>4)&0x3`) the rest of the substrate uses —
    /// never a hand-rolled raw boundary. The state raw lives in bits 0–5 of
    /// `adjectiveBitmap`. Cluster A is the believed/active partition; B
    /// (historical) and C (terminal) are retired. The tag carries the retired
    /// cluster letter, not the raw state, so any future state added inside a
    /// defined cluster classifies correctly. An undefined raw (not one of the
    /// ten cookbook §2.3 states) is reported verbatim as `unknown(raw)`.
    ///
    /// `internal` (not private) so the conformance suite can assert the tag for
    /// every defined state directly against `RowState.cluster`. Mirrors the
    /// Rust `lifecycle_tag_for_adjective_bitmap`.
    static func lifecycleTag(forAdjectiveBitmap adjectiveBitmap: Int64) -> String {
        let stateRaw = UInt8(adjectiveBitmap & 0x3F)
        switch RowState.cluster(ofRawState: stateRaw) {
        case .a:
            return "active"
        case .some(let c):  // .b or .c — both retired
            return "retired(\(clusterLabel(c)))"
        case nil:
            return "unknown(\(stateRaw))"
        }
    }

    func runFactTimeline(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let entity = try optionalString(args["entity"], argument: "entity")
        let facts = try await kit.recallKGFactTimeline(handle, entity: entity)
        let formatter = ISO8601DateFormatter()
        let lines = facts.prefix(200).map { f -> String in
            let filed = formatter.string(from: f.filedAt)
            let lifecycleTag = Self.lifecycleTag(forAdjectiveBitmap: f.adjectiveBitmap)
            return "\(filed)  \(lifecycleTag)  \(f.id)  [\(f.subject)] \(f.predicate) [\(f.object)]"
        }
        let count = facts.count
        let header: String
        if let entity = entity, !entity.isEmpty {
            header = "fact timeline for \"\(entity)\": \(count)"
        } else {
            header = "fact timeline: \(count)"
        }
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
        let agentName = try optionalString(args["agent"], argument: "agent") ?? Self.mcpAgentName
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
        let agentName = try optionalString(args["agent"], argument: "agent") ?? Self.mcpAgentName
        let lastN = try optionalInt(args["last_n"], argument: "last_n") ?? 10
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
    ///
    /// `trace_rows` is included so the reward pipeline's read-log size is
    /// observable — mirrors Rust `run_estate_status` which calls
    /// `count_recall_traces`. Best-effort: a failure here must not break
    /// the status response.
    ///
    /// `sync:` reports the real ConvergenceKit backend state via
    /// `GeniusLocusKit.syncStateToken(for:)`. When no sync engine is
    /// registered the estate is local-only and the field reads
    /// `"sync: local-only"`. The fabricated `"status: connected"` literal
    /// has been removed (OP-1 honesty fix — never fabricate status).
    func runEstateStatus(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let estate = try await kit.estate(for: handle)
        let drawers = try await estate.allDrawers()
        let active = drawers.filter { $0.tombstonedAt == nil }
        let wings = Set(active.map { $0.wing }).sorted()
        let facts = try await kit.recallKGFacts(handle)
        // Trace row count — the reward pipeline's read log size. A read failure
        // must not break the whole status response, but it must NOT be reported
        // as `0`: a fabricated zero is indistinguishable from a genuinely empty
        // trace table and would lie about reward-pipeline depth. On failure the
        // field reads "unavailable" so the consumer can tell "no traces" from
        // "could not read". Mirrors Rust run_estate_status.
        let traceRows: String
        if let count = try? await kit.countRecallTraces(handle) {
            traceRows = String(count)
        } else {
            traceRows = "unavailable"
        }
        // Sync state — read the real ConvergenceKit backend state via GLK.
        // Best-effort: a syncStateToken failure must not break the status
        // response; fall back to "local-only" so the field is always present
        // and honest. "local-only" means no sync engine is wired for this estate.
        let syncToken = (try? await kit.syncStateToken(for: handle)) ?? "local-only"
        let stats = [
            "estate: \(handle.estateName) [\(handle.estateUUID)]",
            "memories: \(active.count) active (\(drawers.count) total)",
            "wings: \(wings.joined(separator: ", "))",
            "kg facts: \(facts.count) active",
            "trace_rows: \(traceRows)",
            "sync: \(syncToken)",
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

    /// `moot_reindex` — enqueue encode jobs for drawers not yet in the Corpus.
    ///
    /// This is a maintenance / admin tool, NOT one of the nine ARIA grammar
    /// verbs. It is used to backfill existing content that was captured before
    /// the dual-path intake wiring landed (or after an accidental data loss in
    /// the BM25/vector indexes). All unindexed drawers are enqueued for
    /// background encoding via the estate's encode queue (the same `.regular`
    /// path as normal captures). Encoding is asynchronous — this call returns
    /// as soon as the jobs are enqueued, not after they complete.
    ///
    /// Idempotent: drawers already in the Corpus BundleStore are skipped.
    /// Callers can poll `moot_estate_status` for encode-queue depth or simply
    /// wait for the background drain worker to settle.
    ///
    /// Returns a summary: how many drawers were enqueued and how many were
    /// already indexed.
    func runReindex(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let now = Date()
        let enqueued = try await kit.reindexMissing(handle: handle, now: now)
        return Self.textResult("reindex: enqueued \(enqueued) drawers for encoding")
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
