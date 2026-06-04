import Foundation
import AriaLexiconLib
import GeniusLocusKit
import LocusKit

/// Dispatch a parsed `tools/call` against one or more GeniusLocusKit
/// estates opened in the same kit instance.
///
/// The dispatcher carries one `GeniusLocusKit` reference and a map of
/// the estates it can address, keyed by `estateUUID`. One of those is
/// the default estate. Each tool name decodes back to a `(Verb, Noun)`
/// pair, the arguments object decodes into the matching GLK frame, the
/// call's target estate is resolved from the optional `estateID`
/// argument (absent ⇒ default estate), and the verb method on
/// `GeniusLocusKit` runs against that estate. Outcomes — success
/// payloads or substrate refusals — map to MCP `tools/call` result
/// shapes; out-of-band failures (unknown tool, malformed arguments,
/// unknown `estateID`) surface as JSON-RPC error responses instead.
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
    /// other enum decoders in this file (it is the caller addressing a
    /// thing that is not there, not the substrate refusing a request).
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
    public func dispatch(name: String, arguments: JSONValue) async throws -> JSONValue {
        let args = arguments.objectValue ?? [:]
        do {
            // Federation tools sit ABOVE the lexicon projection: they
            // have no (verb, noun) pair, so they are matched by name
            // before parseToolName — which would otherwise reject a
            // non-lexicon name as methodNotFound. cross_estate_recall is
            // the one such tool today (see ToolProjection for the
            // matching descriptor it advertises in tools/list).
            if name == Self.crossEstateRecallToolName {
                return try await runCrossEstateRecall(args)
            }
            // CognitionKit behaviour-recipe tools sit above the lexicon
            // projection (provenance `.recipe`), so they are matched by
            // name before parseToolName — which would reject a non-lexicon
            // name as methodNotFound. RecipeTools owns their decode + run.
            if RecipeTools.isRecipeTool(name) {
                return try await RecipeTools.dispatch(
                    name: name, args: args, kit: kit, defaultHandle: handle,
                    resolveHandle: resolveHandle)
            }
            // Reasoning-lens tools: one hard-bound tool per cataloged
            // lens recipe, matched by name above the lexicon projection
            // like the recipe tools (LENS_DISCOVERABILITY_DECISION v2.0).
            if LensTools.isLensTool(name) {
                return try await LensTools.dispatch(
                    name: name, args: args, kit: kit, defaultHandle: handle,
                    resolveHandle: resolveHandle)
            }
            // VaultKit control-surface tools (`moot_vault_*`) sit above the
            // lexicon projection (provenance `.vault`): no (verb, noun)
            // pair, so they are matched by name before parseToolName would
            // reject them. VaultTools owns their decode + run.
            if VaultTools.isVaultTool(name) {
                return try await VaultTools.dispatch(
                    name: name, args: args, kit: kit, defaultHandle: handle,
                    resolveHandle: resolveHandle)
            }
            guard let (verb, noun) = parseToolName(name) else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.methodNotFound,
                    message: "Unknown tool: \(name)"
                )
            }
            guard Acceptance.accepts(noun, verb), ToolProjection.surfaces(verb) else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.methodNotFound,
                    message: "Tool \(name) is not on the projected surface"
                )
            }
            switch (verb, noun) {
            case (.capture, .drawer):
                return try await runCaptureDrawer(args)
            case (.capture, .tunnel):
                return try await runCaptureTunnel(args)
            case (.recall, .drawer):
                return try await runRecallDrawer(args)
            case (.recall, .tunnel):
                return try await runRecallTunnel(args)
            case (.recall, .kgFact):
                return try await runRecallKGFacts(args)
            case (.recall, .diaryEntry):
                return try await runRecallDiaryEntries(args)
            case (.recall, .proposal):
                return try await runRecallProposals(args)
            case (.recall, .association):
                return try await runRecallAssociations(args)
            case (.recall, .learnedReference):
                return try await runRecallLearnedReferences(args)
            case (.mutate, _):
                return try await runMutate(args, noun: noun)
            case (.withdraw, _):
                return try await runWithdraw(args, noun: noun)
            case (.expunge, _):
                return try await runExpunge(args, noun: noun)
            case (.reanchor, _):
                return try await runReanchor(args, noun: noun)
            case (.learn, _):
                return try await runLearn(args, noun: noun)
            default:
                // All acceptance-matrix (verb, noun) pairs that surface as tools
                // have explicit arms above. This arm fires only when a new (verb,
                // noun) pair is accepted by the lexicon but not yet wired — a
                // missing arm, not a caller error.
                throw JSONRPCError(
                    code: JSONRPCErrorCode.methodNotFound,
                    message: "No handler bound for tool \(name)"
                )
            }
        } catch let error as JSONRPCError {
            throw error
        } catch let error as VerbError {
            // VerbError covers the substrate's own refusals
            // (notSupportedByEstate when the verb's LocusKit
            // implementation is still stubbed; expungeNotConfirmed,
            // emptyReanchor; underlyingEstateFailure). These reach
            // the substrate and bounce back; emit them as tool-call
            // results with isError set so the client can act on them
            // without losing the call ID.
            return Self.errorResult(describe(error))
        } catch let error as GeniusLocusKitError {
            return Self.errorResult(describe(error))
        } catch {
            // Anything else is genuinely out of band — bubble it up as
            // a JSON-RPC error.
            throw JSONRPCError(
                code: JSONRPCErrorCode.toolDispatchFailure,
                message: "\(error)"
            )
        }
    }

    // MARK: - Tool name parsing

    /// Reverse the projection: `verb_noun` (or `noun_verb` for recall)
    /// back to `(Verb, Noun)`. Returns `nil` for any name outside the
    /// projected set, including names whose verb is `propose` or
    /// `associate` (those are not callable tools per § 4).
    public static func parseToolName(_ name: String) -> (Verb, Noun)? {
        // Strip the product namespace prefix (`moot_`) before parsing the
        // ARIA grammar body. Names without it are not projected tools.
        guard name.hasPrefix(ToolProjection.toolNamePrefix) else { return nil }
        let body = String(name.dropFirst(ToolProjection.toolNamePrefix.count))
        let parts = body.split(separator: "_", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        // Try verb_noun first (the action form): parts[0] is the verb.
        if let verb = Verb(rawValue: parts[0]),
           let noun = Noun(rawValue: parts[1]),
           verb != .recall {
            return (verb, noun)
        }
        // Otherwise the query form: parts[0] is the noun, parts[1] is recall.
        if let noun = Noun(rawValue: parts[0]),
           let verb = Verb(rawValue: parts[1]),
           verb == .recall {
            return (verb, noun)
        }
        return nil
    }

    /// Instance forwarder so call sites do not need to qualify the
    /// static. Behaviour identical to `ToolDispatcher.parseToolName(_:)`.
    public func parseToolName(_ name: String) -> (Verb, Noun)? {
        Self.parseToolName(name)
    }

    // MARK: - Per-verb runners

    private func runCaptureDrawer(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let content = try requireString(args, "content")
        let room = try requireString(args, "room")
        let code = try requireString(args, "udcCode")
        let addedBy = try requireString(args, "addedBy")
        let modelID = try requireString(args, "embeddingModelID")
        let channel = try decodeChannel(args["channel"])
        let sensitivity = try decodeSensitivity(args["sensitivity"])
        let kind = try decodeContentKind(args["kind"])
        // Validate the declared classification scheme at the ARIA
        // boundary. The substrate's LatticeAnchor stores a bare code
        // with no scheme tag yet (tagging the storage column is a
        // separate migration, §5.8 dual-scheme model), so both schemes
        // construct the same anchor today; the discriminator's present
        // job is to let a caller DECLARE the scheme and have it
        // validated here. The validated scheme is echoed back so the
        // caller can confirm how its code was interpreted.
        let scheme = try decodeClassificationScheme(args["classificationScheme"])
        let frame = CaptureFrame(
            content: content,
            channel: channel,
            room: room,
            latticeAnchor: .udc(code),
            addedBy: addedBy,
            embeddingModelID: modelID,
            sensitivity: sensitivity,
            kind: kind
        )
        let drawer = try await kit.capture(handle, frame)
        return Self.textResult([
            "captured drawer \(drawer.id)",
            "lineage: \(drawer.lineageID.uuidString)",
            "room: \(drawer.room)",
            "scheme: \(scheme.rawValue)",
        ].joined(separator: "\n"))
    }

    /// Handle moot_capture_tunnel: file a new directed graph edge (tunnel) into
    /// the estate addressed by the optional `estateID` argument.
    ///
    /// Dispatches through `GeniusLocusKit.estate(for:)` → `LocusKit.Estate.capture(_:
    /// TunnelCaptureFrame)` — the same path `TunnelRecallTests.captureTunnel` uses for
    /// test setup, now exposed over the MCP surface. Required args are the six endpoint +
    /// identity slots the TunnelCaptureFrame init mandates: `sourceWing`, `sourceRoom`,
    /// `targetWing`, `targetRoom`, `kind` (used as the relation label), `addedBy`.
    /// Optional `sourceDrawerID` and `targetDrawerID` pin the edge to specific drawer rows.
    ///
    /// The schema for this tool mirrors the Rust leg's `moot_capture_tunnel` descriptor
    /// (rust/src/tool_list.rs lexicon_schema Verb::Capture Noun::Tunnel), so the two
    /// servers advertise byte-identical required arrays and property keys on the wire.
    private func runCaptureTunnel(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let sourceWing = try requireString(args, "sourceWing")
        let sourceRoom = try requireString(args, "sourceRoom")
        let targetWing = try requireString(args, "targetWing")
        let targetRoom = try requireString(args, "targetRoom")
        // `kind` is used as the tunnel's relation label (free-form string), matching
        // the Rust leg's convention: TunnelCaptureFrame::new takes kind_str as the label.
        let kind = try requireString(args, "kind")
        let addedBy = try requireString(args, "addedBy")
        let sourceDrawerID = args["sourceDrawerID"]?.stringValue
        let targetDrawerID = args["targetDrawerID"]?.stringValue
        let frame = TunnelCaptureFrame(
            sourceWing: sourceWing,
            sourceRoom: sourceRoom,
            targetWing: targetWing,
            targetRoom: targetRoom,
            label: kind,
            addedBy: addedBy,
            sourceDrawerId: sourceDrawerID,
            targetDrawerId: targetDrawerID
        )
        // Resolve the estate actor via await (estate(for:) is actor-isolated on
        // GeniusLocusKit), then capture the tunnel via LocusKit.Estate.capture.
        // No GLK kit-level captureTunnel verb exists — GLK exposes recallTunnels
        // for the read but not a matching write wrapper. LocusKit.Estate.capture
        // is the direct write path, the same one TunnelRecallTests.captureTunnel
        // uses for test setup.
        let estate = try await kit.estate(for: handle)
        let tunnel = try await estate.capture(frame)
        return Self.textResult("captured tunnel \(tunnel.id)")
    }

    private func runRecallDrawer(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let filter = try decodeFilter(args["filter"])
        let hydration = try decodeHydration(args["hydrationLevel"])
        let ordering = try decodeOrdering(args["ordering"])
        let rawLimit = args["limit"]?.integerValue.map(Int.init)

        // explain: true — route through the Recall Director (GLKRecallRequest /
        // GLKRecallResult) and append explanation blocks per selected hit.
        // Opt-in only: callers that omit "explain" or pass false get the
        // unchanged legacy path below; no existing behavior is affected.
        if args["explain"]?.boolValue == true {
            let queryText = args["queryText"]?.stringValue
            let effectiveLimit = rawLimit ?? 12
            let frame = RecallFrame(
                filterChain: [filter],
                hydrationLevel: hydration,
                limit: effectiveLimit,
                ordering: ordering
            )
            let request = GLKRecallRequest(
                frame: frame,
                mode: .unionBest,
                scoring: .matrixAware,
                limit: effectiveLimit,
                fallback: .allowDegraded,
                queryText: queryText
            )
            let result = try await kit.recall(handle, request)
            // Build response: header + one row per hit, each followed by
            // its explanation as an indented note block.
            var lines: [String] = ["recalled \(result.hits.count) drawer(s) with explanations"]
            for hit in result.hits.prefix(50) {
                let contentPreview = hit.drawer?.content.prefix(80) ?? "(not hydrated)"
                let room = hit.drawer?.room ?? "?"
                lines.append("\(hit.id)  [\(room)]  \(contentPreview)")
                for expLine in hit.explanation {
                    lines.append("  \(expLine)")
                }
            }
            return Self.textResult(lines.joined(separator: "\n"))
        }

        // Legacy path — unchanged behavior for callers that omit explain.
        let frame = RecallFrame(
            filterChain: [filter],
            hydrationLevel: hydration,
            limit: rawLimit,
            ordering: ordering
        )
        let rows = try await kit.recall(handle, frame)
        // Cap the body so a wide recall does not push the response
        // past JSON-RPC sanity. Clients re-call with `limit` if they
        // want more; this matches MCP's discouraged-large-payload
        // guidance without imposing a hard schema cap.
        let lines = rows.prefix(50).map { drawer -> String in
            "\(drawer.id)  [\(drawer.room)]  \(drawer.content.prefix(80))"
        }
        let header = "recalled \(rows.count) drawer(s)"
        let body = ([header] + lines).joined(separator: "\n")
        return Self.textResult(body)
    }

    /// Handle moot_tunnel_recall: read the outgoing tunnel edges whose source
    /// wing matches the required `wing` argument.
    ///
    /// Dispatches to `GeniusLocusKit.recallTunnels(_:wing:)` — the graph-read
    /// method verified in GeniusLocusKit/Verbs/VerbSurface.swift:115 that
    /// returns all non-tombstoned tunnels originating from `wing` in stable
    /// filed-at order. A wing with no tunnels returns an empty list, not an
    /// error. `wing` is required; its absence is an out-of-band `invalidParams`
    /// consistent with the other required-arg decoders.
    private func runRecallTunnel(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let wing = try requireString(args, "wing")
        let tunnels = try await kit.recallTunnels(handle, wing: wing)
        // Cap the body at 50 rows, matching the drawer recall cap discipline
        // so wide tunnel reads do not push the response past JSON-RPC sanity.
        let lines = tunnels.prefix(50).map { tunnel -> String in
            "\(tunnel.id)  [\(tunnel.sourceWing)/\(tunnel.sourceRoom)]→[\(tunnel.targetWing)/\(tunnel.targetRoom)]  \(tunnel.label)"
        }
        let header = "recalled \(tunnels.count) tunnel(s) from wing \(wing)"
        let body = ([header] + lines).joined(separator: "\n")
        return Self.textResult(body)
    }

    /// Handle moot_kgFact_recall: read all active kg-facts (state cluster < 7)
    /// from the estate. Delegates to `GeniusLocusKit.recallKGFacts`.
    private func runRecallKGFacts(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let facts = try await kit.recallKGFacts(handle)
        let lines = facts.prefix(50).map { f -> String in
            "\(f.id)  [\(f.subject)] \(f.predicate) [\(f.object)]"
        }
        let header = "recalled \(facts.count) kgFact(s)"
        let body = ([header] + lines).joined(separator: "\n")
        return Self.textResult(body)
    }

    /// Handle moot_diaryEntry_recall: read all non-tombstoned diary entries
    /// from the estate. Delegates to `GeniusLocusKit.recallDiaryEntries`.
    private func runRecallDiaryEntries(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let entries = try await kit.recallDiaryEntries(handle)
        let lines = entries.prefix(50).map { e -> String in
            "\(e.id)  [\(e.wing)/\(e.room)]  \(e.entry.prefix(80))"
        }
        let header = "recalled \(entries.count) diaryEntry(s)"
        let body = ([header] + lines).joined(separator: "\n")
        return Self.textResult(body)
    }

    /// Handle moot_proposal_recall: read all proposals from the estate.
    /// Delegates to `GeniusLocusKit.recallProposals`.
    private func runRecallProposals(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let proposals = try await kit.recallProposals(handle)
        let lines = proposals.prefix(50).map { p -> String in
            "\(p.id)  target:\(p.targetRowID)"
        }
        let header = "recalled \(proposals.count) proposal(s)"
        let body = ([header] + lines).joined(separator: "\n")
        return Self.textResult(body)
    }

    /// Handle moot_association_recall: read all non-tombstoned associations
    /// from the estate. Delegates to `GeniusLocusKit.recallAssociations`.
    private func runRecallAssociations(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let associations = try await kit.recallAssociations(handle)
        let lines = associations.prefix(50).map { a -> String in
            "\(a.id)  [\(a.sourceWing)/\(a.sourceRoom)]→[\(a.targetWing)/\(a.targetRoom)]  \(a.label)"
        }
        let header = "recalled \(associations.count) association(s)"
        let body = ([header] + lines).joined(separator: "\n")
        return Self.textResult(body)
    }

    /// Handle moot_learnedReference_recall: read all non-tombstoned learned
    /// references from the estate. Delegates to
    /// `GeniusLocusKit.recallLearnedReferences`.
    private func runRecallLearnedReferences(_ args: [String: JSONValue]) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let refs = try await kit.recallLearnedReferences(handle)
        let lines = refs.prefix(50).map { r -> String in
            "\(r.id)  handle:\(r.handle)"
        }
        let header = "recalled \(refs.count) learnedReference(s)"
        let body = ([header] + lines).joined(separator: "\n")
        return Self.textResult(body)
    }

    private func runMutate(_ args: [String: JSONValue], noun: Noun) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let rowID = try requireString(args, "rowID")
        let kindName = try requireString(args, "kind")
        let kind = try decodeMutationKind(kindName)
        let payload = args["payload"]?.stringValue
        let frame = MutateFrame(rowID: rowID, kind: kind, payload: payload)
        try await kit.mutate(handle, frame)
        return Self.textResult("mutated \(noun.rawValue) \(rowID) (\(kindName))")
    }

    private func runWithdraw(_ args: [String: JSONValue], noun: Noun) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let rowID = try requireString(args, "rowID")
        let reason = args["reason"]?.stringValue
        try await kit.withdraw(handle, WithdrawFrame(rowID: rowID, reason: reason))
        return Self.textResult("withdrew \(noun.rawValue) \(rowID)")
    }

    private func runExpunge(_ args: [String: JSONValue], noun: Noun) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let rowID = try requireString(args, "rowID")
        let reason = try requireString(args, "reason")
        let confirmation = args["confirmation"]?.boolValue ?? false
        try await kit.expunge(handle, ExpungeFrame(rowID: rowID, reason: reason, confirmation: confirmation))
        return Self.textResult("expunged \(noun.rawValue) \(rowID)")
    }

    private func runReanchor(_ args: [String: JSONValue], noun: Noun) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        let rowID = try requireString(args, "rowID")
        let toRoom = args["toRoom"]?.stringValue
        let toLatticeRaw = args["toUDC"]?.stringValue
        let toLattice = toLatticeRaw.map { LatticeAnchor.udc($0) }
        try await kit.reanchor(handle, ReanchorFrame(rowID: rowID, toRoom: toRoom, toLattice: toLattice))
        return Self.textResult("reanchored \(noun.rawValue) \(rowID)")
    }

    private func runLearn(_ args: [String: JSONValue], noun: Noun) async throws -> JSONValue {
        // `estateID` resolves the target estate; `handle` is the
        // LearnFrame's source-reference string (a different argument) —
        // the two never collide.
        let estate = try resolveHandle(args)
        let handleArg = try requireString(args, "handle")
        try await kit.learn(estate, LearnFrame(handle: handleArg))
        return Self.textResult("learned \(noun.rawValue) \(handleArg)")
    }

    // MARK: - Federation tool (above the lexicon projection)

    /// The one federation tool dispatched by name, above the lexicon
    /// projection. It has no AriaLexicon (verb, noun) pair, so `dispatch`
    /// matches it before `parseToolName` and `ToolProjection` advertises
    /// it as an explicit non-projected entry in `tools/list`.
    public static let crossEstateRecallToolName = "moot_cross_estate_recall"

    /// Run `cross_estate_recall`: a grant-authorized federated read that
    /// fans across the locally-open estates the caller is entitled to
    /// read, narrows each contribution to its grant's scope, and returns
    /// the per-estate contributions.
    ///
    /// Authorization is NOT performed here. The per-estate grant gate
    /// lives entirely in GLK's `federatedRecall` — this is the I-13
    /// boundary in practice: ARIA mediates *which* locally-open estates
    /// to attempt; GLK enforces *whether* each read is granted. This
    /// runner iterates the registered estates other than the requester,
    /// calls `federatedRecall` per candidate source, and keeps only the
    /// contributions GLK authorizes. A per-estate `.crossEstateReadRefused`
    /// is the expected "not granted" signal for that estate and is
    /// skipped, not surfaced. If no estate authorizes the caller, the
    /// call is refused cleanly with an `errorResult` (`isError == true`),
    /// matching the A-versus-C refusal discipline
    /// (DECISION_FEDERATION_SHARING_MODEL_2026-05-21 §13): the read
    /// reached the substrate-mediated surface and was refused, so the
    /// client sees why without losing the call ID.
    ///
    /// GLK is the primary grant enforcer. `federatedRecall` applies both
    /// the binary "may the requester read the source" gate and the
    /// content-level sensitivity filter (`grant.contentLevel` vs
    /// `adjectiveSensitivity`). This runner applies answer-assembly
    /// scope narrowing (DECISION §10) as defense-in-depth secondary:
    /// it narrows each contribution to the rows inside its authorizing
    /// grant's scope (a `.room`/`.wing`/`.latticeSubtree`/`.singleRow`
    /// grant must not over-disclose). `FederatedRecallResult` carries
    /// `grant.scope` as advisory metadata so this layer can act on it. The companion §10 obligation — excluding
    /// foreign-provenance rows — is a no-op in this scaffold: each source
    /// estate's `federatedRecall` reads only that estate's own isolated
    /// storage, so no foreign-origin rows are present to exclude. It
    /// becomes live when a cross-estate import path lands (a later
    /// mission); the §10 inference-budget ledger is likewise out of scope
    /// for this scaffold.
    private func runCrossEstateRecall(_ args: [String: JSONValue]) async throws -> JSONValue {
        // The caller identity GLK's grant gate is evaluated against: the
        // requester must be a registered, locally-open estate.
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
                // A refusal means the caller holds no active grant from
                // this source; that estate is simply omitted from the
                // federated answer. Any other GLK error is genuine and
                // propagates to the dispatch error mapper.
                if case .crossEstateReadRefused = error { continue }
                throw error
            }
            let scoped = Self.narrow(result.drawers, to: result.grant.scope)
            sections.append(Self.renderContribution(
                source: source, grant: result.grant, drawers: scoped
            ))
        }

        guard !sections.isEmpty else {
            // A-versus-C refusal: the caller is entitled to read nothing.
            return Self.errorResult(
                "cross_estate_recall refused: no open estate holds an active grant naming the requester."
            )
        }
        return Self.textResult(sections.joined(separator: "\n\n"))
    }

    /// Resolve the requester estate for a federation call from the
    /// required `requesterEstateID` argument. It must name a registered,
    /// locally-open estate; absent/malformed/unknown is an out-of-band
    /// `invalidParams`, consistent with `resolveHandle` and the other
    /// decoders (the caller naming a thing that is not there, not the
    /// substrate refusing a granted request).
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
    /// already filtered drawers by `grant.contentLevel` (sensitivity gate)
    /// before this function is called. This narrowing — scope-subtree
    /// filtering by wing/room/lattice/singleRow — is **defense-in-depth
    /// secondary** at the ARIA surface, not the sole enforcer.
    ///
    /// `.wholeEstate` applies no scope narrowing (all sensitivity-gated rows
    /// pass through); sub-estate scopes honor the grant's spatial boundary.
    private static func narrow(_ drawers: [Drawer], to scope: GrantScope) -> [Drawer] {
        switch scope {
        case .wholeEstate:
            return drawers
        case .wing(let name):
            return drawers.filter { $0.wing == name }
        case .room(let name):
            return drawers.filter { $0.room == name }
        case .latticeSubtree(let code):
            // A drawer is inside the subtree rooted at `code` when its UDC
            // code equals `code` or descends from it on a dot boundary
            // (UDC is dot-decimal: "004" roots "004.42"). The "+ ." guard
            // prevents a bare-prefix false match (e.g. "00" vs "001").
            return drawers.filter { $0.udcCode == code || $0.udcCode.hasPrefix(code + ".") }
        case .singleRow(let id):
            // Grant rows are addressed by UUID; `Drawer.id` is the string
            // form of that identifier.
            return drawers.filter { $0.id == id.uuidString }
        }
    }

    /// Format one estate's authorized contribution: a header naming the
    /// source estate and its authorizing grant, then up to 50 row lines —
    /// the same cap discipline `runRecallDrawer` uses to keep a wide
    /// response within JSON-RPC sanity.
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

    private func requireString(_ args: [String: JSONValue], _ key: String) throws -> String {
        guard let value = args[key]?.stringValue else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Missing required string argument: \(key)"
            )
        }
        return value
    }

    private func decodeChannel(_ value: JSONValue?) throws -> CaptureChannel {
        guard let name = value?.stringValue else { return .typed }
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

    private func decodeSensitivity(_ value: JSONValue?) throws -> AdjectiveSensitivity {
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
    /// Absent defaults to `.udc`, preserving the prior bare-UDC behavior
    /// so no existing caller breaks. An unrecognized scheme is an
    /// out-of-band client error (`invalidParams`), consistent with the
    /// other enum decoders in this file.
    private func decodeClassificationScheme(_ value: JSONValue?) throws -> ClassificationScheme {
        guard let name = value?.stringValue else { return .udc }
        guard let scheme = ClassificationScheme(rawValue: name) else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Unknown classification scheme: \(name)"
            )
        }
        return scheme
    }

    private func decodeContentKind(_ value: JSONValue?) throws -> ContentKind {
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

    private func decodeFilter(_ value: JSONValue?) throws -> Filter {
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

    private func decodeHydration(_ value: JSONValue?) throws -> HydrationLevel {
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

    private func decodeOrdering(_ value: JSONValue?) throws -> Ordering {
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

    private func decodeMutationKind(_ name: String) throws -> MutationKind {
        switch name {
        case "confirm": return .confirm
        case "reject": return .reject
        case "contest": return .contest
        case "resolve": return .resolve
        case "supersede": return .supersede
        case "revive": return .revive
        case "accept": return .accept
        default:
            // correctSensitivity and correctTrust take associated
            // values; the MCP tool surface does not yet expose them.
            // A future schema extension can add tagged variants here.
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
        // The exhaustive switch surfaces every VerbError case as a
        // single sentence the client can render in a tool-output
        // panel. Adding a new case to VerbError will require an arm
        // here; the compiler enforces that without a default branch.
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

/// The classification scheme a lattice-anchor code belongs to.
///
/// Per spec §5.8 (dual-scheme model), an anchor code may be a UDC code
/// or an MDCC code. `capture_drawer` lets a caller declare which scheme
/// its `udcCode` argument uses; `udc` is the default so omitting the
/// discriminator preserves the original UDC-only behavior. The scheme
/// is validated and echoed at the ARIA boundary — the substrate's
/// `LatticeAnchor` does not yet carry a scheme tag (that is a separate
/// storage migration), so this type lives in ARIA_MCP, not LocusKit.
public enum ClassificationScheme: String, Sendable, CaseIterable {
    case udc
    case mdcc
}
