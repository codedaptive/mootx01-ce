import Foundation
import IntellectusLib
import OSLog
import CryptoKit
import CorpusKit
import EngramLib
import LocusKit
import PersistenceKit
import VectorKit
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateTypes

/// Result from `GeniusLocusKit.runExpungeIntegritySweep(_:now:)`.
///
/// Aggregates per-row outcomes from the crash-window sweep without
/// aborting on per-row errors. A non-empty `perRowErrors` signals that
/// at least one row could not be sealed after the re-delete attempt;
/// those rows are not in `remediatedCount` or `orphanedCount`.
public struct ExpungeIntegritySweepResult: Sendable, Equatable {
    /// Rows where the cross-kit re-delete succeeded AND the sweep
    /// audit-seal succeeded. These rows are fully remediated.
    public var remediatedCount: Int = 0

    /// Rows where the cross-kit re-delete failed but the sweep
    /// audit-seal succeeded. The vector embedding may still be
    /// present; the audit trail records the orphaned state.
    public var orphanedCount: Int = 0

    /// Per-row error strings where the audit seal also failed.
    /// These rows could not be remediated or documented in the audit
    /// trail; manual intervention may be required.
    public var perRowErrors: [String] = []

    public init() {}
}

/// The unified nine-verb surface on `GeniusLocusKit`.
///
/// Per the architecture spec §7.8 and the engineering cookbook §10,
/// the substrate's vocabulary is nine verbs: `capture`, `recall`,
/// `mutate`, `withdraw`, `expunge`, `reanchor`, `learn`, `propose`,
/// and `associate`. This extension expresses each verb once on the
/// GeniusLocusKit actor. Each verb takes an `EstateHandle` (so the
/// caller addresses one estate per call) plus a typed frame, looks
/// the estate up through `estate(for:)`, dispatches to LocusKit's
/// `Estate` verb surface, and surfaces the result. The GLK actor's
/// isolation serializes verb dispatch per kit instance; each LocusKit
/// `Estate` is itself an actor and serializes its own writes.
///
/// Audit emission happens through LocusKit's existing per-kit audit
/// path; the unified single-log-per-estate is wired via GLK-03 and the
/// standing-signals scheduler via GLK-04.
///
/// Error mapping: all nine verbs dispatch to live LocusKit estate
/// methods. A verb whose dependency is genuinely unavailable surfaces
/// `LocusKitError.notSupported` (or an `.invalidContent` carrying
/// "not yet implemented"); the GLK boundary re-raises that as
/// `VerbError.notSupportedByEstate(verb:)` so callers see a single
/// case. State-axis mutations rejected by the lifecycle automaton (an
/// illegal source state) and other LocusKit failures flow through as
/// `VerbError.underlyingEstateFailure(verb:reason:)`.
public extension GeniusLocusKit {

    /// Logger reused across verb dispatch. The static logger on the
    /// actor is private; declaring a local computed accessor keeps the
    /// fleet-standard subsystem/category in one place per CLAUDE.md.
    private static var verbLog: Logger {
        Logger(subsystem: "com.mootx01.kit", category: "GeniusLocusKit")
    }

    // MARK: - Mount-state gate

    /// Require that `handle` is in the `.mounted` state before accepting a verb call.
    ///
    /// Quiesced and draining estates have signalled intent to stop accepting new
    /// work (the ARIA_MCP admin plane calls quiesce/drain before close). Any verb
    /// dispatched after quiesce must be rejected with `estateQuiesced` so callers
    /// receive a clear refusal rather than an unexpected success or a race against
    /// close. This is the planned security hardening for the quiesce lifecycle:
    /// the error case existed since the error enum was authored but was never wired
    /// to the dispatch path.
    ///
    /// A handle with no entry in `mountStates` (estate opened before this gate was
    /// introduced, or a handle that slipped through) is treated as `.mounted` so
    /// existing callers are not broken by a nil-map miss.
    ///
    /// - Parameters:
    ///   - handle: The estate handle being addressed.
    ///   - verb: The verb name, included in the error for diagnostics.
    /// - Throws: `GeniusLocusKitError.estateQuiesced` if the estate is quiesced or draining.
    internal func requireMounted(_ handle: EstateHandle, verb: String) throws {
        switch mountStates[handle] {
        case .quiesced, .draining:
            throw GeniusLocusKitError.estateQuiesced(estateUUID: handle.estateUUID)
        case .mounted, .unmounted, .none:
            // .mounted is the expected fast path.
            // .unmounted: estate is in early-lifecycle state; let estate(for:) handle
            //   the stale-handle error rather than adding a second error type here.
            // nil: handle unmapped in mountStates dict; treat as mounted so existing
            //   callers are not broken by a map-miss (fail-open is safer than spurious rejection).
            break
        }
    }

    // MARK: - capture

    /// File a new drawer into the estate addressed by `handle`.
    ///
    /// - Returns: the stored `Drawer` with its generated id and all
    ///   bitmap fields populated.
    /// - Throws:
    ///   - `GeniusLocusKitError.estateNotOpen` if `handle` is stale.
    ///   - `VerbError.underlyingEstateFailure` on any LocusKit failure.
    func capture(_ handle: EstateHandle, _ frame: CaptureFrame) async throws -> Drawer {
        try requireMounted(handle, verb: "capture")
        let estate = try estate(for: handle)
        do {
            return try await estate.capture(frame)
        } catch {
            throw remap(verb: "capture", estateID: handle.estateUUID.uuidString, error: error)
        }
    }

    // MARK: - recall

    /// Recall rows from the estate addressed by `handle`.
    ///
    /// This is the legacy shim preserved for callers that do not need
    /// explicit mode/scoring control. It routes through the Recall Director
    /// with `mode: .locusOnly, scoring: .raw, origin: .internal` and returns
    /// the hydrated drawers from the result, matching the prior flat-array contract.
    ///
    /// Callers that need multi-lane or scored recall, or that originate from the
    /// ARIA boundary and should enqueue dreaming items, use
    /// `recall(_ handle:, _ request: GLKRecallRequest)` directly with
    /// `origin: .external` set on the request (B-10a enforcement).
    ///
    /// B-10a: this shim always passes `origin: .internal`, so dreaming items
    /// are NEVER enqueued for calls through this path. Only the ARIA_MCP boundary
    /// passes `origin: .external`; the dreaming enqueue lives in the scored
    /// `recall(_:_:)` method and fires only on external-origin requests.
    ///
    /// - Returns: drawers matching the frame's filter chain, in the
    ///   ordering the frame requested.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if `handle` is stale.
    func recall(_ handle: EstateHandle, _ frame: RecallFrame) async throws -> [Drawer] {
        try requireMounted(handle, verb: "recall")
        let result = try await recall(handle, GLKRecallRequest(
            frame: frame,
            mode: .locusOnly,
            scoring: .raw,
            limit: frame.limit ?? 50,
            fallback: .failClosed,
            origin: .internal
        ))
        return result.drawers
    }

    // MARK: - resolveNodeNames

    /// Resolve parent-node IDs to `(wing, room)` display-name pairs from
    /// the estate's node tree. Read-only convenience for callers that hold
    /// drawers and need human-readable room names without direct estate
    /// access. Delegates to `Estate.resolveNodeNames(parentNodeIds:)`.
    ///
    /// - Returns: a dictionary mapping each input parentNodeId to its
    ///   `(wing: String, room: String)` display names. IDs not found in the
    ///   node tree are absent from the result.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if `handle` is stale.
    func resolveNodeNames(
        _ handle: EstateHandle,
        parentNodeIds: [String]
    ) async throws -> [String: (wing: String, room: String)] {
        let estate = try estate(for: handle)
        return try await estate.resolveNodeNames(parentNodeIds: parentNodeIds)
    }

    // MARK: - recallTunnels

    /// Recall the tunnels originating in `wing` from the estate addressed
    /// by `handle`, unioned with any host-tree containment edges from a
    /// registered `GLKNodeTopologyProvider`.
    ///
    /// Resolves the handle through `estate(for:)` and returns the
    /// non-tombstoned drawer-to-drawer tunnels whose source is `wing`,
    /// in stable filed-at order. These edges are the graph the structural
    /// reasoning-lens recipes (keystones, constellation, free association,
    /// tunnel successor) read; the recipe layer never reaches the substrate
    /// directly. Read-only; a wing with no tunnels reads empty.
    ///
    /// G1 — read-once-and-freeze: when a `GLKNodeTopologyProvider` is registered
    /// for `handle`, `provider.treeEdges(scope: nil)` is called EXACTLY ONCE
    /// at the top of this method. The result is frozen into a local constant
    /// before the estate tunnel read begins. No subsequent provider call is
    /// made during this method or any downstream computation that consumes
    /// the returned array. The deterministic recall/lens path sees only the
    /// frozen snapshot.
    ///
    /// G4 — topology boundary: the provider supplies ONLY edge topology
    /// (parent/child id pairs). No node content crosses this boundary.
    ///
    /// G5 — wing-scoped privacy boundary (secfix/c-glk-remaining Part 5):
    /// after treeEdges returns the full estate forest, this method filters to
    /// only edges whose child node resolves to the queried `wing` via
    /// `estate.resolveNodeNames`. Without this filter, foreign-wing room nodes
    /// would be injected as synthetic tunnels falsely labelled with `wing`,
    /// leaking topology across wing boundaries. Root→wing-node edges are
    /// silently excluded because wing-level nodes are structural containers,
    /// not room-level nodes, and do not appear in resolveNodeNames results.
    ///
    /// B-1 — layer discipline: the structural lenses (CognitionKit) call
    /// this method and receive the unioned edge set. They never import or
    /// reference `GLKNodeTopologyProvider` directly.
    ///
    /// When no provider is registered, the method returns only stored
    /// tunnels — existing behaviour is unchanged (no-provider path is
    /// identical to pre-.nodeTreeNative behaviour).
    ///
    /// `includingRestricted` forwards to the LocusKit tunnel sensitivity
    /// gate's one sanctioned widening: the vault export's private-scope
    /// opt-in. Default keeps the no-claims Normal-tier ceiling; secret-tier
    /// edges are excluded unconditionally either way.
    ///
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if `handle` is stale.
    func recallTunnels(
        _ handle: EstateHandle, wing: String,
        includingRestricted: Bool = false
    ) async throws -> [Tunnel] {
        let estate = try estate(for: handle)

        // G1 — read-once-and-freeze. Call treeEdges exactly once here;
        // no provider method is called again during this recall or by any
        // consumer of the returned array.
        //
        // G5 — wing-scoped privacy: the raw treeEdges result covers the
        // FULL estate forest (all wings, all rooms). We resolve the child
        // node IDs through estate.resolveNodeNames — a single batched
        // NodeStore read — and keep only edges whose child maps to `wing`.
        // This is NOT a second treeEdges call; G1 is fully satisfied.
        let frozenTreeEdges: [(parent: String, child: String)]
        if let provider = nodeTopologyProviders[handle] {
            let allEdges = await provider.treeEdges(scope: nil)
            if allEdges.isEmpty {
                frozenTreeEdges = []
            } else {
                // Collect all unique child node IDs from the raw edge set.
                // These are the candidates to test for wing membership.
                let childIds = Array(Set(allEdges.map { $0.child }))
                // Resolve child IDs to (wing, room) labels via the estate's
                // NodeStore. Room-level nodes (depth 2: wing → room) are mapped;
                // wing-level nodes (depth 1: root → wing) are structural containers
                // and are not returned here — their edges are therefore excluded,
                // which is correct (root→wing edges carry no wing-specific meaning).
                let childNameMap = try await estate.resolveNodeNames(parentNodeIds: childIds)
                // Build the set of child IDs confirmed to belong to this wing.
                let wingLocalChildIds = Set(childNameMap.compactMap { id, pair in
                    pair.wing == wing ? id : nil
                })
                // Filter: only edges where the child is a room node of this wing.
                // Foreign-wing room nodes and unresolvable IDs are excluded.
                frozenTreeEdges = allEdges.filter { wingLocalChildIds.contains($0.child) }
            }
        } else {
            // No provider registered — empty tree edge set, existing behaviour
            // unchanged. Structural lenses see only stored tunnel edges.
            frozenTreeEdges = []
        }

        // Read stored tunnels from the estate.
        let storedTunnels = try await estate.tunnelsFromWing(
            wing, includingRestricted: includingRestricted)

        // No tree edges → return stored tunnels only (identical to pre-registration
        // behaviour; proved unchanged by test nodeTreeNative_noProvider_behaviorUnchanged).
        guard !frozenTreeEdges.isEmpty else {
            return storedTunnels
        }

        // Union: append synthetic containment tunnels from the frozen tree snapshot.
        // Each tree edge (parent, child) becomes a Tunnel with:
        //   - label: "containment" — the tag a lens uses to weight tree-vs-graph edges
        //   - kind: .references — the closest existing TunnelKind vocabulary entry;
        //     TunnelKind does not have a dedicated `containment` case (LocusKit is
        //     immutable from this layer), so the label is the discriminator.
        //   - sourceDrawerId / targetDrawerId: the node ids (parent → child direction)
        //   - filedAt: .distantPast — synthetic tunnels have no real filing time;
        //     .distantPast keeps them stable-sortable below real tunnels
        //   - addedBy: "nodeTopologyProvider" — provenance marker
        // All bitmap fields are 0 (default active/normal state).
        let synthetic: [Tunnel] = frozenTreeEdges.map { edge in
            Tunnel(
                id: "containment:\(edge.parent):\(edge.child)",
                sourceWing: wing,
                sourceRoom: "topology",
                sourceDrawerId: edge.parent,
                targetWing: wing,
                targetRoom: "topology",
                targetDrawerId: edge.child,
                label: "containment",
                kind: .references,
                adjectiveBitmap: 0,
                operationalBitmap: 0,
                provenanceBitmap: 0,
                addedBy: "nodeTopologyProvider",
                filedAt: .distantPast
            )
        }

        return storedTunnels + synthetic
    }

    // MARK: - findNearestDistilled

    /// Find the nearest distilled-tier vectors to `engram` in the estate
    /// addressed by `handle`.
    ///
    /// Thin wrapper over `VectorStore.findNearest` scoped to the
    /// `"distillation-features-v1"` model lane. Called by the DistilledRecall
    /// recipe for no-inference Hamming NN on the distilled tier — the probe
    /// Engram is produced by `DistillationPipeline.queryFingerprint`, so no
    /// embedding model call is needed at search time.
    ///
    /// - Parameters:
    ///   - handle: the estate to search. Must be open in this kit.
    ///   - engram: the Hamming probe fingerprint (structural feature fingerprint).
    ///   - limit: maximum nearest-neighbour results to return.
    ///     A `limit` of 0 returns an empty array without error.
    /// - Returns: `[VectorMatch]` sorted by ascending Hamming distance.
    /// - Throws:
    ///   - `GeniusLocusKitError.estateNotOpen` if `handle` is stale.
    ///   - `VerbError.notSupportedByEstate` if no VectorStore is registered
    ///     for this estate.
    ///   - `VerbError.underlyingEstateFailure` wrapping any `VectorKitError`
    ///     surfaced by `VectorStore.findNearest`.
    func findNearestDistilled(
        _ handle: EstateHandle,
        engram: Engram,
        limit: Int
    ) async throws -> [VectorMatch] {
        // Validate that the handle is open before accessing the VectorStore.
        // estateNotOpen is thrown here if the handle is stale — matching the
        // error contract of every other verb surface method.
        _ = try estate(for: handle)
        guard let vectorStore = vectorStores[handle] else {
            // Estate is open but no VectorStore is registered. The distillation
            // tier requires a VectorStore; raise notSupportedByEstate so callers
            // receive a typed, structured error rather than an empty result.
            throw VerbError.notSupportedByEstate(verb: "findNearestDistilled")
        }
        // Dispatch to the distillation lane. modelID is the fixed string for the
        // structural fingerprint lane — no semantic embedding model is involved.
        // limit: 0 returns [] without error (VectorStore.findNearest guards
        // limit > 0 internally). VectorKitError is caught and re-raised as
        // VerbError.underlyingEstateFailure so callers see a unified error type —
        // parity of the Rust port's `.map_err` wrapper.
        do {
            return try await vectorStore.findNearest(
                probe: engram,
                modelID: "distillation-features-v1",
                limit: limit
            )
        } catch {
            throw VerbError.underlyingEstateFailure(
                verb: "findNearestDistilled",
                reason: "\(error)"
            )
        }
    }

    // MARK: - recallKGFacts

    /// Recall all active kg-fact rows from the estate addressed by `handle`.
    ///
    /// Returns the kg-facts in the RowState Cluster-A (active) set —
    /// `g_state_cluster < RowState.activeClusterUpperBoundRaw` (16) —
    /// ordered by `filedAt` ascending. Delegates to `Estate.allKGFacts`.
    /// Peer of the Rust `EstateCoordinator::recall_kg_facts`.
    ///
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if `handle` is stale.
    func recallKGFacts(_ handle: EstateHandle) async throws -> [KGFact] {
        let estate = try estate(for: handle)
        return try await estate.allKGFacts()
    }

    // MARK: - recallKGFactTimeline

    /// Recall ALL kg-fact rows from the estate — active and retired — in
    /// chronological order, suitable for powering the `moot_fact_timeline` tool.
    ///
    /// Unlike `recallKGFacts`, which applies the RowState Cluster-A active-only
    /// filter (`g_state_cluster < RowState.activeClusterUpperBoundRaw`, 16),
    /// this method reads every row that was ever filed, including facts
    /// in `withdrawn`, `expired`, `decayed`, `superseded`, `rejected`, and
    /// `tombstoned` states.  The full lifecycle history lets callers trace how
    /// structured knowledge in the estate evolved over time.
    ///
    /// Optional `entity` filter: when non-nil, only facts whose `subject` or
    /// `object` contains the given string (case-insensitive) are returned.
    /// Matching is done in Swift after the SQL fetch — entity vocabulary is
    /// free-form and no SQL index covers substring containment.
    ///
    /// Delegates to `Estate.allKGFactsIncludingRetired`.
    /// Peer of the Rust `EstateCoordinator::recall_kg_fact_timeline`.
    ///
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if `handle` is stale.
    func recallKGFactTimeline(
        _ handle: EstateHandle,
        entity: String? = nil
    ) async throws -> [KGFact] {
        let estate = try estate(for: handle)
        var facts = try await estate.allKGFactsIncludingRetired()
        if let entity = entity, !entity.isEmpty {
            let lower = entity.lowercased()
            facts = facts.filter {
                $0.subject.lowercased().contains(lower) ||
                $0.object.lowercased().contains(lower)
            }
        }
        return facts
    }

    // MARK: - captureKGFact

    /// File a KGFact triple into the estate addressed by `handle`.
    ///
    /// `sourceDrawerID` is the drawer this fact was extracted from; pass `""`
    /// for freestanding facts not anchored to a specific drawer (the MCP
    /// interface convention for agent-asserted triples). `DrawerStore.addKGFact`
    /// accepts `""` as an unanchored sentinel per the GLK-VERB-EXT-01 relaxation.
    ///
    /// `now` is the capture instant. Always pass `Date()` at non-test call sites;
    /// the parameter exists to keep the method deterministic under test, matching
    /// the fleet "pass now as a parameter" discipline.
    ///
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if `handle` is stale.
    func captureKGFact(
        _ handle: EstateHandle,
        subject: String,
        predicate: String,
        object: String,
        sourceDrawerID: String = "",
        now: Date
    ) async throws -> KGFact {
        let store = try await ensureKGStore(for: handle)
        let fact = KGFact(
            subject: subject,
            predicate: predicate,
            object: object,
            sourceDrawerID: sourceDrawerID,
            filedAt: now
        )
        try await store.addKGFact(fact)
        return fact
    }

    // MARK: - retireKGFact

    /// Retire a KGFact by transitioning its state to withdrawn.
    ///
    /// Retirement is a state transition (not a delete): the row remains in the
    /// estate for audit purposes. `State.withdrawn` (rawValue 18) lands in
    /// RowState Cluster B (at/above the active upper bound
    /// `RowState.activeClusterUpperBoundRaw`, 16), which exits the
    /// active-recall filter in `allKGFacts`. Routes through
    /// `DrawerStore.withdrawKGFact` directly —
    /// `Estate.withdraw` is Drawer-specific and does not handle KGFact rowIDs.
    ///
    /// - Throws: `GeniusLocusKitError.estateNotOpen`, or
    ///   `VerbError.underlyingEstateFailure` if the row is not found.
    func retireKGFact(
        _ handle: EstateHandle,
        rowID: String
    ) async throws {
        let store = try await ensureKGStore(for: handle)
        do {
            try await store.withdrawKGFact(id: rowID)
        } catch {
            throw remap(verb: "retireKGFact", estateID: handle.estateUUID.uuidString, error: error)
        }
    }

    // MARK: - recallDiaryEntries

    /// Recall all non-tombstoned diary entries from the estate addressed by
    /// `handle`, ordered by `filedAt` ascending.
    ///
    /// Delegates to `Estate.allDiaryEntries`. Peer of the Rust
    /// `EstateCoordinator::recall_diary_entries`.
    ///
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if `handle` is stale.
    func recallDiaryEntries(_ handle: EstateHandle) async throws -> [DiaryEntry] {
        let estate = try estate(for: handle)
        return try await estate.allDiaryEntries()
    }

    // MARK: - recallProposals

    /// Recall all proposals from the estate addressed by `handle`, ordered
    /// by `filedAt` ascending.
    ///
    /// Delegates to `Estate.allProposals`. Peer of the Rust
    /// `EstateCoordinator::recall_proposals`.
    ///
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if `handle` is stale.
    func recallProposals(_ handle: EstateHandle) async throws -> [Proposal] {
        let estate = try estate(for: handle)
        return try await estate.allProposals()
    }

    // MARK: - recallAssociations

    /// Recall all non-tombstoned associations from the estate addressed by
    /// `handle`, ordered by `filedAt` ascending.
    ///
    /// Delegates to `Estate.allAssociations`. Peer of the Rust
    /// `EstateCoordinator::recall_associations`.
    ///
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if `handle` is stale.
    func recallAssociations(_ handle: EstateHandle) async throws -> [Association] {
        let estate = try estate(for: handle)
        return try await estate.allAssociations()
    }

    // MARK: - recallLearnedReferences

    /// Recall all non-tombstoned learned references from the estate addressed
    /// by `handle`, ordered by `filedAt` ascending.
    ///
    /// Delegates to `Estate.allLearnedReferences`. Peer of the Rust
    /// `EstateCoordinator::recall_learned_references`.
    ///
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if `handle` is stale.
    func recallLearnedReferences(_ handle: EstateHandle) async throws -> [LearnedReference] {
        let estate = try estate(for: handle)
        return try await estate.allLearnedReferences()
    }

    // MARK: - tombstonedLineageIDs

    /// The set of lineage IDs whose drawer rows have been permanently erased
    /// (tombstoned via the `expunge` verb — cluster C: `tombstonedAt IS NOT NULL`).
    ///
    /// Delegates to `Estate.tombstonedLineageIDs()` → `DrawerStore.tombstonedLineageIDs()`,
    /// which uses a storage-tier `.isNotNull` predicate on `tombstonedAt` and reads the
    /// `lineageID` column directly from raw rows — it does NOT parse `tombstonedAt` as a
    /// timestamp. This design is deliberately format-agnostic: `expungeGated` stamps
    /// `tombstonedAt` via `ISO8601DateFormatter()` (no fractional seconds), while
    /// `LKISO8601.date(from:)` requires fractional seconds; parsing the stored value
    /// would silently return `nil` and make cluster C rows appear live.
    ///
    /// The recall pipeline's `liveRows` pre-filters `tombstonedAt == nil`, so cluster C
    /// rows are invisible to any `recall`-based query. This method surfaces them through
    /// the storage predicate path that bypasses the recall pipeline.
    ///
    /// This is the B-1-compliant GLK passthrough: VaultKit reaches tombstoned rows
    /// through GeniusLocusKit, never by importing LocusKit's DrawerStore directly.
    /// Parity of the Rust `EstateCoordinator::tombstoned_lineage_ids`.
    ///
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if `handle` is stale;
    ///   any LocusKit failure propagated from `DrawerStore.tombstonedLineageIDs`.
    func tombstonedLineageIDs(_ handle: EstateHandle) async throws -> Set<UUID> {
        let estate = try estate(for: handle)
        // Delegates to Estate.tombstonedLineageIDs() → DrawerStore.tombstonedLineageIDs(),
        // which reads lineageID directly from storage using an isNotNull predicate at the
        // storage tier. This avoids parsing the tombstonedAt timestamp, which sidesteps a
        // format mismatch between ISO8601DateFormatter() (no fractional seconds, used by
        // expungeGated to stamp tombstonedAt) and LKISO8601 (fractional-seconds format,
        // used by optDate to parse it back). A parse failure would silently decode
        // tombstonedAt as nil, making cluster C rows appear live to the Swift filter.
        return try await estate.tombstonedLineageIDs()
    }

    // MARK: - mutate

    /// Apply a named mutation to a drawer in the estate addressed by
    /// `handle`.
    ///
    /// Dispatches to `LocusKit.Estate.mutate(rowID:kind:payload:)`, which
    /// implements every `MutationKind` as a real transition through the
    /// established mutate machinery (bitmap mutation + one sealed audit row):
    ///   - `.confirm` moves the confirmation axis (provenance bits 18–23)
    ///     to `.userConfirmed`.
    ///   - `.reject` / `.contest` / `.resolve` / `.supersede` / `.revive`
    ///     (and `.accept`) move the row's `State` axis through the canonical
    ///     lifecycle automaton (cookbook §9.2), each guarded by its legal
    ///     source state.
    ///
    /// An illegal source state fails loud: the automaton gate raises a
    /// `LocusKitError.invalidContent` (guard pre-check) or
    /// `.disciplineViolation` (automaton table miss), which the GLK boundary
    /// re-raises as `VerbError.underlyingEstateFailure(verb: "mutate", …)`.
    ///
    /// `.revive` accepts any Cluster B source (decayed / withdrawn / expired /
    /// superseded); only `decayed → active` is in the automaton table today,
    /// so a withdrawn/expired/superseded source fails loud per the validator
    /// (see `LocusKit.Estate.mutate`).
    func mutate(_ handle: EstateHandle, _ frame: MutateFrame) async throws {
        try requireMounted(handle, verb: "mutate")
        let estate = try estate(for: handle)
        do {
            try await estate.mutate(rowID: frame.rowID, kind: frame.kind, payload: frame.payload)
        } catch {
            throw remap(verb: "mutate", estateID: handle.estateUUID.uuidString, error: error)
        }
    }

    // MARK: - withdraw

    /// Withdraw a drawer in the estate addressed by `handle` — move its
    /// `State` axis to `.withdrawn`. The substrate writes a
    /// bitmap-audit row atomically with the UPDATE.
    func withdraw(_ handle: EstateHandle, _ frame: WithdrawFrame) async throws {
        try requireMounted(handle, verb: "withdraw")
        let estate = try estate(for: handle)
        do {
            try await estate.withdraw(rowID: frame.rowID, reason: frame.reason)
        } catch {
            throw remap(verb: "withdraw", estateID: handle.estateUUID.uuidString, error: error)
        }
    }

    // MARK: - expunge

    /// Tombstone a drawer in the estate addressed by `handle`, zeroize its
    /// content blob, and purge its vector embedding(s) from VectorKit/CorpusKit.
    ///
    /// Raises `VerbError.expungeNotConfirmed` at the GLK boundary when
    /// `frame.confirmation` is false; the substrate is not reached.
    ///
    /// With confirmation, dispatches in two steps followed by an audit seal.
    /// The audit seal ordering satisfies §B-2a: the success audit event is
    /// appended ONLY after both steps complete, so the audit log never
    /// records success when the cross-kit vector delete failed.
    ///
    /// **Step 1 — Storage expunge (LocusKit):** tombstones the drawer row and
    /// zeroes its content blob atomically. The audit event is NOT sealed here;
    /// it is returned for the deferred seal in step 3.
    /// Failure raises `VerbError` via `remap` and the cross-kit step is not
    /// attempted. Validation (confirmation flag, S-3 gate, row existence) runs
    /// inside LocusKit before any mutation — the vector is not touched until
    /// step 2 confirms the storage half completed.
    ///
    /// **Step 2 — Cross-kit vector delete (GLK orchestration, fail-closed):**
    /// when a `Corpus` is registered, calls `corpus.expunge(sourceID:)` to scrub
    /// verbatim chunk text and purge BM25 index entries and all vector embeddings. When a standalone
    /// `VectorStore` is also registered (`.glk` estate), additionally calls
    /// `vectorStore.deleteAllVectors` to invalidate the standalone store's
    /// resident array (the corpus and the standalone store share backing storage
    /// but maintain separate in-memory indexes; both must be updated). Failure
    /// here seals an `"expungeOrphan"` audit event (honest record of partial
    /// completion) and then raises `VerbError.crossKitVectorDeleteFailed`.
    ///
    /// **Step 3 — Audit seal:** on success, seals the gate-produced `"tombstone"`
    /// event from step 1. On step-2 failure, seals an `"expungeOrphan"` event
    /// that bridges to `UnifiedAuditVerb.expunge` in the GLK unified log, making
    /// the partial outcome detectable via the substrate audit trail.
    ///
    /// When no Corpus or VectorStore is registered (`.locusOnly`), Step 2 is a
    /// no-op and the success audit seals immediately after step 1.
    ///
    /// **`now` threading:** the same `Date` value flows through all three steps
    /// so HLC stamps are monotone and deterministic — `Date()` is never called
    /// inside the engine (spec I-6).
    func expunge(_ handle: EstateHandle, _ frame: ExpungeFrame, now: Date = Date()) async throws {
        try requireMounted(handle, verb: "expunge")
        guard frame.confirmation else {
            throw VerbError.expungeNotConfirmed(rowID: frame.rowID)
        }
        let estate = try estate(for: handle)

        // Step 1 — LocusKit storage expunge (deferred seal).
        //
        // The audit event is NOT sealed here. It is returned for the deferred
        // seal in step 3 so the audit log only records success after the
        // cross-kit delete (§B-2a ordering). Storage failure remaps via remap
        // and aborts; the cross-kit step is never reached.
        // expungeReturningUnsealedEvent always returns a non-nil event on
        // success; nil would indicate a DrawerStore contract violation.
        let unsealedEvent: AuditEvent
        do {
            // Force-unwrap is a deliberate programmer-error trap:
            // expungeReturningUnsealedEvent guarantees a non-nil return on
            // success; nil means a contract violation in DrawerStore that must
            // not be silently swallowed. The named method (not the former
            // sealAudit: false parameter) is the only valid deferred-seal path
            // (secfix/ws2-coredelete).
            unsealedEvent = try await estate.expungeReturningUnsealedEvent(
                rowID: frame.rowID,
                reason: frame.reason,
                confirmation: frame.confirmation,
                now: now
            )!
        } catch let e as LocusKitError {
            throw remap(verb: "expunge", estateID: handle.estateUUID.uuidString, error: e)
        } catch {
            throw remap(verb: "expunge", estateID: handle.estateUUID.uuidString, error: error)
        }

        // Step 2 — Cross-kit vector delete (fail-closed; must not be silent).
        //
        // GLK is the composition layer responsible for coordinating the cross-kit
        // vector delete on expunge (GENIUSLOCUSKIT_SPEC_v0.8 §B-2a). The audit
        // seal moves to step 3 so the audit log reflects the true outcome of the
        // full two-step delete.
        //
        // Fan-out: delete vectors for ALL lineage versions, not just the head.
        // The storage expunge (step 1) already walked the lineage chain and
        // scrubbed content for every version. Here we mirror that walk for the
        // cross-kit vector stores.
        let lineageIds = try await estate.lineageChain(for: frame.rowID)
        let idsToDelete = lineageIds.isEmpty ? [frame.rowID] : lineageIds
        let corpus = corpusKits[handle]
        let vectorStore = vectorStores[handle]

        if corpus != nil || vectorStore != nil {
            do {
                for deleteId in idsToDelete {
                    if let corpus {
                        // Expunge: zero verbatim chunk text AND remove from recall
                        // (BM25 + internal vector index). sourceID == drawer.id
                        // (EncodeIntake G4). expunge() is the hard-delete variant of
                        // remove() — it calls scrubText first so verbatim content is
                        // erased even if the subsequent recall-removal steps fail.
                        // (secfix/ws2-coredelete: destruction contract)
                        try await corpus.expunge(sourceID: deleteId)
                    }
                    if let vectorStore, let corpus {
                        // Invalidate the standalone VectorStore's resident slot
                        // so findNearest does not surface the deleted vector.
                        let modelID = await corpus.modelID
                        try await vectorStore.deleteAllVectors(
                            itemID: deleteId,
                            modelID: modelID
                        )
                    } else if let vectorStore {
                        throw VerbError.crossKitVectorDeleteFailed(
                            rowID: deleteId,
                            reason: "standalone VectorStore registered without a Corpus — modelID unavailable for deleteAllVectors; manual cleanup required for estate \(handle.estateUUID.uuidString)"
                        )
                    }
                }
            } catch let e as VerbError {
                // Step 2 failed: seal an "expungeOrphan" audit event (honest record
                // that storage succeeded but cross-kit delete did not), then rethrow.
                // The row is tombstoned and its content is zeroed; the caller must not
                // report it as fully deleted because the vector embedding survived.
                do {
                    try await estate.sealExpungeOrphanAudit(
                        rowID: frame.rowID,
                        successEvent: unsealedEvent,
                        now: now
                    )
                } catch {
                    // Orphan-seal failure: the storage expunge is committed and the
                    // vector delete failed, but the audit trail also could not record
                    // the orphan state. Log at fault level so operators can identify
                    // and remediate dangling vectors via the row ID + estate.
                    Self.verbLog.fault(
                        "expunge orphan-audit seal failed — rowID=\(frame.rowID, privacy: .public) estate=\(handle.estateUUID.uuidString, privacy: .public) sealError=\(error.localizedDescription, privacy: .public)"
                    )
                }
                throw e
            } catch {
                // Wrap unknown cross-kit errors, seal the orphan audit, then rethrow.
                do {
                    try await estate.sealExpungeOrphanAudit(
                        rowID: frame.rowID,
                        successEvent: unsealedEvent,
                        now: now
                    )
                } catch let sealError {
                    // Same as the VerbError path above: log at fault level so operators
                    // can scrape the log for dangling-vector remediation.
                    Self.verbLog.fault(
                        "expunge orphan-audit seal failed — rowID=\(frame.rowID, privacy: .public) estate=\(handle.estateUUID.uuidString, privacy: .public) sealError=\(sealError.localizedDescription, privacy: .public)"
                    )
                }
                throw VerbError.crossKitVectorDeleteFailed(
                    rowID: frame.rowID,
                    reason: error.localizedDescription
                )
            }
        }

        // Step 3 — Seal the success audit event.
        //
        // Both the storage expunge (step 1) and the cross-kit vector delete
        // (step 2) succeeded. Seal the gate-produced "tombstone" event now so
        // the audit log truthfully records a complete expunge. This ordering
        // satisfies §B-2a: success audit only after the full two-step delete.
        try await estate.sealExpungeAudit(unsealedEvent)
    }

    // MARK: - Expunge integrity sweep

    /// Run the expunge integrity sweep for a single estate.
    ///
    /// The sweep detects tombstoned rows that have no sealed "tombstone" or
    /// "expungeOrphan" audit event — the crash-window scenario where step 1
    /// of the §B-2a expunge (LocusKit storage tombstone+scrub) ran, but the
    /// process crashed before step 3 (the audit seal) completed.
    ///
    /// For each crash-window row, the sweep:
    ///   1. Re-attempts the cross-kit vector+corpus delete (same logic as the
    ///      normal expunge step 2).
    ///   2. Seals a synthetic "expungeOrphan" audit event via
    ///      `sealExpungeOrphanAuditSynthetic` to close the audit gap.
    ///      Both the success and failure paths seal the orphan event — the
    ///      original gate event was lost in the crash and cannot be recovered.
    ///
    /// Returns a partial-success result: per-row errors are collected rather
    /// than propagated, so a single-row failure does not abort the sweep.
    /// A fatal error (the orphan query itself fails) propagates directly.
    ///
    /// This is a maintenance function, not a verb. Callers should invoke it
    /// at application startup or on a periodic maintenance timer, AFTER all
    /// per-estate Corpus and VectorStore instances have been registered (they
    /// are registered after `open`, not during it).
    ///
    /// Deterministic: `now` is the caller's wall-clock snapshot; the sweep
    /// does not call `Date()` internally.
    ///
    /// - Parameters:
    ///   - handle: the open estate to sweep.
    ///   - now: sweep wall-clock snapshot.
    /// - Returns: a `ExpungeIntegritySweepResult` with counts and any
    ///   per-row seal errors.
    /// - Throws: `GeniusLocusKitError.underlyingEstateFailure` when the
    ///   orphan-set query itself fails (estate is unusable for sweep).
    func runExpungeIntegritySweep(
        _ handle: EstateHandle,
        now: Date = Date()
    ) async throws -> ExpungeIntegritySweepResult {
        let estate = try estate(for: handle)

        // Query for tombstoned rows without an expunge audit. Fatal on error:
        // we cannot enumerate the orphan set to sweep it.
        let orphanedRows: [LocusKit.Drawer]
        do {
            orphanedRows = try await estate.tombstonedRowsWithoutExpungeAudit()
        } catch {
            throw GeniusLocusKitError.underlyingEstateFailure(
                reason: "expunge integrity sweep: orphan-query failed for estate \(handle.estateUUID.uuidString): \(error)"
            )
        }

        guard !orphanedRows.isEmpty else {
            // No-op: every tombstoned row already has an audit. Common case
            // on a healthy estate; zero work done.
            return ExpungeIntegritySweepResult()
        }

        let corpus = corpusKits[handle]
        let vectorStore = vectorStores[handle]
        let nowMillis = Int64(now.timeIntervalSince1970 * 1000)
        var result = ExpungeIntegritySweepResult()

        for drawer in orphanedRows {
            let rowID = drawer.id

            // Re-attempt the cross-kit vector+corpus delete (step 2 of the
            // original §B-2a expunge). Mirrors the normal expunge step 2.
            // Uses expunge() instead of remove() to also scrub chunk text
            // (secfix/ws2-coredelete: sweep must enforce the full destruction
            // contract, not just recall suppression).
            var deleteError: Error? = nil
            if corpus != nil || vectorStore != nil {
                do {
                    if let corpus {
                        // Hard-delete: scrub chunk text AND remove from recall.
                        try await corpus.expunge(sourceID: rowID)
                    }
                    if let vectorStore {
                        if let corpus {
                            let modelID = await corpus.modelID
                            try await vectorStore.deleteAllVectors(itemID: rowID, modelID: modelID)
                        } else {
                            // Standalone VectorStore without Corpus: modelID unavailable.
                            // The delete cannot complete; this row remains orphaned.
                            // Mirrors the live expunge path (§B-2a), which raises
                            // crossKitVectorDeleteFailed in the same scenario.
                            throw VerbError.crossKitVectorDeleteFailed(
                                rowID: rowID,
                                reason: "standalone VectorStore registered without a Corpus — modelID unavailable for deleteAllVectors; manual cleanup required"
                            )
                        }
                    }
                } catch {
                    deleteError = error
                }
            } else {
                // Neither corpus nor vectorStore is registered for this estate.
                // No cross-kit stores are active, so there is no in-scope data to
                // delete. The audit seal below closes the gap. Note: if corpus or
                // vector stores were registered at capture time but have since been
                // deprovisioned (e.g. after a restart), any residual data in those
                // stores is outside the sweep's reach — the estate operator must
                // ensure consistent provisioning across restarts.
                Self.verbLog.info(
                    "expunge integrity sweep: neither corpus nor vectorStore registered for estate \(handle.estateUUID.uuidString, privacy: .public) — sealing audit without cross-kit cleanup for rowID=\(rowID, privacy: .public)"
                )
            }

            // Seal a synthetic "expungeOrphan" audit in both cases.
            // The original gate event was lost in the crash window; the
            // "expungeOrphan" verb closes the audit gap honestly.
            do {
                try await estate.sealExpungeOrphanAuditSynthetic(rowID: rowID, now: nowMillis)
                if deleteError == nil {
                    result.remediatedCount += 1
                } else {
                    result.orphanedCount += 1
                }
            } catch {
                // Seal also failed: note the per-row error; do not abort the sweep.
                let desc: String
                if let de = deleteError {
                    desc = "\(rowID): re-delete failed (\(de)); sweep audit-seal also failed: \(error)"
                } else {
                    desc = "\(rowID): re-delete succeeded but sweep audit-seal failed: \(error)"
                }
                result.perRowErrors.append(desc)
            }
        }

        return result
    }

    // MARK: - reanchor

    /// Move a drawer's lattice anchor or its room within the estate
    /// addressed by `handle`. At least one of `toRoom` or `toLattice`
    /// must be present; an empty reanchor raises `VerbError.emptyReanchor`
    /// at the GLK boundary before dispatch.
    func reanchor(_ handle: EstateHandle, _ frame: ReanchorFrame) async throws {
        try requireMounted(handle, verb: "reanchor")
        guard frame.toRoom != nil || frame.toWing != nil || frame.toLattice != nil else {
            throw VerbError.emptyReanchor(rowID: frame.rowID)
        }
        let estate = try estate(for: handle)
        do {
            try await estate.reanchor(
                rowID: frame.rowID,
                toRoom: frame.toRoom,
                toWing: frame.toWing,
                toLattice: frame.toLattice
            )
        } catch {
            throw remap(verb: "reanchor", estateID: handle.estateUUID.uuidString, error: error)
        }
    }

    // MARK: - learn

    /// Ingest a learned reference into the estate addressed by `handle`.
    ///
    /// `learn` is grounding-driven per AriaLexicon's flow taxonomy: it
    /// pulls authoritative external reference content into the substrate.
    /// Delegates to `Estate.learn`, which derives the reference's genuine
    /// lattice anchor from `frame.source` (a `SourceCatalogEntry`) — never a
    /// sentinel — and persists a `LearnedReference`. Per cookbook §10.9 /
    /// spec § 7.8.2.
    ///
    /// - Returns: the persisted `LearnedReference`.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if `handle` is stale;
    ///   `VerbError` mapped from `LocusKitError.invalidContent` when
    ///   `frame.handle` is empty (the only fail-loud path on a valid call).
    @discardableResult
    func learn(_ handle: EstateHandle, _ frame: LearnFrame) async throws -> LocusKit.LearnedReference {
        try requireMounted(handle, verb: "learn")
        let estate = try estate(for: handle)
        do {
            return try await estate.learn(frame, now: Date())
        } catch {
            throw remap(verb: "learn", estateID: handle.estateUUID.uuidString, error: error)
        }
    }

    // MARK: - propose

    /// Create a proposal targeting a row in the estate addressed by `handle`.
    ///
    /// Maps the Brain layer's `GeniusLocusKit.ProposalKind` routing label to
    /// the substrate's `LocusKit.ProposalKind` bitmap axis via
    /// `mapBrainKindToSubstrate`, constructs a `LocusKit.ProposeFrame`, and
    /// delegates to `Estate.propose`. Any LocusKit failure is remapped to
    /// `VerbError.underlyingEstateFailure` via `remap`. Per cookbook §10.7.
    @discardableResult
    func propose(_ handle: EstateHandle, _ frame: ProposeFrame) async throws -> LocusKit.Proposal {
        try requireMounted(handle, verb: "propose")
        let estate = try estate(for: handle)
        let locusKind = Self.mapBrainKindToSubstrate(frame.kind)
        let locusFrame = LocusKit.ProposeFrame(
            target: frame.target,
            kind: locusKind,
            justification: frame.justification
        )
        do {
            return try await estate.propose(locusFrame, now: Date())
        } catch {
            throw remap(verb: "propose", estateID: handle.estateUUID.uuidString, error: error)
        }
    }

    // MARK: - associate

    /// Create an association between two rows in the estate addressed by `handle`.
    ///
    /// Constructs a `LocusKit.AssociateFrame` from the GLK-level frame and
    /// delegates to `Estate.associate`. Any LocusKit failure is remapped to
    /// `VerbError.underlyingEstateFailure` via `remap`. Per cookbook §10.8.
    @discardableResult
    func associate(_ handle: EstateHandle, _ frame: AssociateFrame) async throws -> LocusKit.Association {
        try requireMounted(handle, verb: "associate")
        let estate = try estate(for: handle)
        let locusFrame = LocusKit.AssociateFrame(
            a: frame.a,
            b: frame.b,
            weight: frame.weight
        )
        do {
            return try await estate.associate(locusFrame, now: Date())
        } catch {
            throw remap(verb: "associate", estateID: handle.estateUUID.uuidString, error: error)
        }
    }

    // MARK: - Kind mapping

    /// Maps the Brain layer's `GeniusLocusKit.ProposalKind` (routing-queue
    /// labels used by standing signals and NeuronKit) to the substrate's
    /// `LocusKit.ProposalKind` (cookbook §2.4 bitmap axis). The two
    /// vocabularies operate at different altitudes; this function is the
    /// single translation point per the mission's two-vocabulary architecture.
    ///
    /// Mapping rules (Brain label → substrate axis):
    ///   - byReferenceDrift     → .newTunnel (closest structural analogue)
    ///   - tournamentUpdate     → .mutateDrawer
    ///   - miningPattern        → .miningPatternAdjustment
    ///   - disciplineViolation  → .recordObservation
    ///   - mutateCandidate      → .mutateDrawer
    ///   - amend                → .mutateDrawer
    ///   - testPropose          → .newTunnel (test scaffold)
    ///   - other                → .newTunnel (safe fallback)
    private static func mapBrainKindToSubstrate(
        _ brainKind: ProposalKind
    ) -> LocusKit.ProposalKind {
        switch brainKind {
        case .byReferenceDrift:    return .newTunnel
        case .tournamentUpdate:    return .mutateDrawer
        case .miningPattern:       return .miningPatternAdjustment
        case .disciplineViolation: return .recordObservation
        case .mutateCandidate:     return .mutateDrawer
        // Enrichment / Q-ID assignment mutates the target drawer's anchor,
        // so it maps to the substrate's drawer-mutation axis.
        case .enrichment:          return .mutateDrawer
        case .amend:               return .mutateDrawer
        case .testPropose:         return .newTunnel
        case .other:               return .newTunnel
        }
    }

    // MARK: - verifyAuditChain

    /// Verify the integrity of the unified audit log for the estate
    /// addressed by `handle`.
    ///
    /// Pulls the latest audit rows from the estate's LocusKit tier
    /// (`feedAuditLog`) so the check runs against current history, then
    /// runs `AuditChainVerifier` over the merged log. Returns an
    /// `AuditChainReport` per NEURONKIT_SPEC §3.5 / invariant C-12:
    /// `valid == false` with `firstBrokenAt` set on the first broken
    /// entry, `valid == true` and `firstBrokenAt == nil` on a clean
    /// chain (including an empty one).
    ///
    /// The §3.5 monitor may also emit an `AuditIntegrityProposal` on a
    /// break; that autonomic side effect belongs to the NeuronKit
    /// mission that wraps this verb (the spec note is preserved here so
    /// the wiring is explicit), and is not produced in GLK-03.
    ///
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if `handle` is
    ///   stale; any LocusKit failure surfaced while feeding the log.
    func verifyAuditChain(_ handle: EstateHandle) async throws -> AuditChainReport {
        // Resolve the handle up front so a stale handle raises
        // estateNotOpen before any storage work, matching the other verbs.
        _ = try estate(for: handle)
        // Bug 1 fix (ADR025-AUDITLOG-GOVERNOR): auditLog(for:) now reads directly
        // from the _storagekit_audit table via a single bounded SQL query —
        // the former feedAuditLog N+1 call is gone; the log is populated here.
        let log = try await auditLog(for: handle)
        return AuditChainVerifier.verify(log)
    }

    // MARK: - glkDeriveBranch (from estate handle)

    /// Derive a COW branch from the estate addressed by `handle`.
    ///
    /// All rows currently in the parent estate are copied into a fresh
    /// in-memory branch estate at derivation time. The parent is never
    /// modified by branch operations — spec invariant I-15.
    ///
    /// - Parameters:
    ///   - name: Human-readable label for the new branch.
    ///   - handle: The estate to derive from. Must be open in this kit.
    /// - Returns: An active `BranchHandle` with `lineageDepth == 1`.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if `handle` is stale.
    /// Maximum number of simultaneously ACTIVE branches this kit will hold.
    /// Each active branch retains a full in-memory copy of its parent's rows,
    /// so an unbounded active set is a memory-exhaustion vector for any caller
    /// that can trigger derivation. Terminal branches (won/merged/discarded)
    /// release their rows and do not count. Mirrors Rust `MAX_ACTIVE_BRANCHES`.
    static let maxActiveBranches = 64

    /// Refuse a new derivation when the active-branch quota is reached.
    /// Terminal branches have released their rows and do not count.
    private func checkActiveBranchQuota() throws {
        let active = branches.values.filter { $0.status == .active }.count
        guard active < Self.maxActiveBranches else {
            throw GeniusLocusKitError.activeBranchQuotaExceeded(
                active: active, maximum: Self.maxActiveBranches)
        }
    }

    func glkDeriveBranch(name: String, from handle: EstateHandle) async throws -> any BranchHandle {
        try checkActiveBranchQuota()
        let parentEstate = try estate(for: handle)
        let snapshotRows = try await recallRows(from: parentEstate)
        let branch = try await EstateBranch(
            name: name,
            parentEstate: parentEstate,
            snapshotRows: snapshotRows,
            lineageDepth: 1
        )
        branches[branch.branchID] = branch
        Self.verbLog.debug("glkDeriveBranch '\(name, privacy: .public)' from estate \(handle.estateUUID, privacy: .public)")
        return branch
    }

    /// Derive a COW branch from an existing branch (branch-of-branch).
    ///
    /// All rows currently in `parentBranch` are copied into a fresh
    /// in-memory branch estate. The new branch's `lineageDepth` is
    /// `parentBranch.lineageDepth + 1`.
    ///
    /// - Parameters:
    ///   - name: Human-readable label for the new branch.
    ///   - parentBranch: The branch to derive from.
    /// - Returns: An active `BranchHandle` with depth incremented by 1.
    func glkDeriveBranch(name: String, fromBranch parentBranch: any BranchHandle) async throws -> any BranchHandle {
        // Cast to the concrete type to access `branchEstate` for row recall.
        // Registry membership check ensures the parent branch was derived by
        // THIS kit instance; branches from a different GeniusLocusKit actor
        // may pass the type cast but are not tracked here.
        try checkActiveBranchQuota()
        guard let concreteBranch = parentBranch as? EstateBranch else {
            throw GeniusLocusKitError.branchNotTracked(branchID: parentBranch.branchID)
        }
        guard branches[concreteBranch.branchID] != nil else {
            throw GeniusLocusKitError.branchNotTracked(branchID: concreteBranch.branchID)
        }
        let snapshotRows = try await recallRows(from: concreteBranch.branchEstate)
        let branch = try await EstateBranch(
            name: name,
            parentEstate: concreteBranch.branchEstate,
            snapshotRows: snapshotRows,
            lineageDepth: concreteBranch.lineageDepth + 1
        )
        branches[branch.branchID] = branch
        Self.verbLog.debug("glkDeriveBranch '\(name, privacy: .public)' from branch '\(parentBranch.name, privacy: .public)'")
        return branch
    }

    // MARK: - glkPromoteBranch

    /// Promote a branch into the parent estate, replacing it.
    ///
    /// All drawers in the branch that were added after derivation
    /// (i.e., not in `snapshotIDs`) are re-captured into the parent
    /// estate. The branch status transitions to `.won`.
    ///
    /// - Parameters:
    ///   - branch: The branch to promote. Must be in `.active` status.
    ///   - handle: The parent estate handle to promote into.
    /// - Throws:
    ///   - `GeniusLocusKitError.branchNotTracked` if `branch` was not
    ///     created by this kit instance.
    ///   - `GeniusLocusKitError.estateNotOpen` if `handle` is stale.
    func glkPromoteBranch(_ branch: any BranchHandle, replacing handle: EstateHandle) async throws {
        guard let concreteBranch = branch as? EstateBranch else {
            throw GeniusLocusKitError.branchNotTracked(branchID: branch.branchID)
        }
        // Registry check: reject branches from a different kit instance that
        // pass the type cast but are not tracked by this actor.
        guard branches[concreteBranch.branchID] != nil else {
            throw GeniusLocusKitError.branchNotTracked(branchID: concreteBranch.branchID)
        }
        // Lifecycle guard: the doc contract above ("Must be in `.active`
        // status") was previously unenforced, which let a DISCARDED branch —
        // e.g. one the migration benchmark disqualified for silent concept
        // loss — be promoted by any caller holding its id (C-5 bypass).
        guard concreteBranch.status == .active else {
            throw GeniusLocusKitError.branchNotActive(
                branchID: concreteBranch.branchID, status: concreteBranch.status)
        }
        // Validate the handle before the E-2 guard: estate(for:) throws
        // .estateNotOpen for a stale handle, surfacing the error before the
        // promotion-target check. The estate itself is not used directly here
        // because capture routes through the GLK mode-aware verb (not estate.capture).
        _ = try estate(for: handle)
        // E-2 guard: the destination must be the branch's parent estate, so
        // promotion cannot silently move content across an estate (and key)
        // boundary.
        try await assertPromotionTarget(concreteBranch, into: handle)

        // Recall all current branch rows and identify those added after
        // derivation (not in snapshotIDs). `.full` hydration is required
        // because the rows are immediately re-captured into the parent estate
        // via `Estate.capture`, which requires non-empty content. Per spec § 7.3,
        // `.structured` returns `content = ""` (no blob reads), so using
        // `.structured` here would fail the capture guard for every promoted row.
        let frame = RecallFrame(
            filterChain: [.unconfirmed],
            hydrationLevel: .full,
            ordering: .byCaptureTimeDesc
        )
        let branchRows = try await concreteBranch.recall(frame)
        let newRows = branchRows.filter { !concreteBranch.snapshotIDs.contains($0.id) }

        // Re-capture each new row into the parent estate. A new ID is
        // minted for each because CaptureFrame has no id field and
        // Estate.store is internal to LocusKit. Content fidelity is
        // preserved; ID correlation is done by content string in tests.
        // mode: .regular routes through the GLK encode pipeline so promoted
        // drawers become BM25/vector searchable via the drain worker — a
        // direct parentEstate.capture() bypass the Corpus feed entirely.
        //
        // Resolve parentNodeId → (wing, room) names once for all new rows.
        // Drawer no longer carries wing/room stored properties (node-tree
        // migration); wing and room are both recovered from the BRANCH
        // estate's node tree (branch rows have parentNodeIds pointing to
        // branch-local nodes, not parent estate nodes).
        //
        // Wing integrity (ADR-016): all security/placement/lifecycle fields
        // are preserved on promotion so non-default-wing rows re-file into
        // the correct wing rather than silently falling back to defaultWing().
        // lineageID is intentionally NOT preserved — see derivation comment.
        let branchNodeIds = Array(Set(newRows.map(\.parentNodeId)))
        let branchNodeNames = try await concreteBranch.branchEstate.resolveNodeNames(parentNodeIds: branchNodeIds)
        for row in newRows {
            let names = branchNodeNames[row.parentNodeId]
            let wingName = names?.wing       // nil → CaptureFrame defaults to defaultWing()
            let roomName = names?.room ?? ""
            let captureFrame = CaptureFrame(
                content: row.content,
                channel: row.captureChannel,
                room: roomName,
                latticeAnchor: LatticeAnchor(
                    udcCode: row.udcCode,
                    udcFacets: row.udcFacets,
                    wikidataQID: row.wikidataQID,
                    wikidataQidsSecondary: row.wikidataQidsSecondary
                ),
                addedBy: row.addedBy,
                embeddingModelID: row.embeddingModelID,
                sensitivity: row.adjectiveSensitivity,
                kind: row.contentKind,
                provenanceChannel: row.channel,
                sourceType: row.sourceType,
                provenanceSensitivity: row.sensitivity,
                confirmation: row.confirmation,
                confidence: row.confidence,
                eventTime: row.eventTime,
                featureFlags: row.featureFlags,
                exportability: row.exportability,
                wing: wingName
            )
            _ = try await capture(handle, captureFrame, mode: .regular)
        }

        // Transition the branch to .won, then release its now-redundant row
        // copy (the promoted rows live in the parent estate). The O(1) .won
        // shell stays in the registry.
        concreteBranch.setStatus(.won)
        try await concreteBranch.releaseRows()
        Self.verbLog.debug("glkPromoteBranch '\(branch.name, privacy: .public)' → .won (\(newRows.count) rows promoted)")
    }

    // MARK: - glkMergeDrawers

    /// Cherry-pick specific drawers from a branch into the parent estate.
    ///
    /// Only the drawers whose `id` appears in `drawerIDs` are copied
    /// into the parent. Non-selected branch rows are not propagated.
    /// The branch status transitions to `.merged`.
    ///
    /// - Parameters:
    ///   - drawerIDs: Branch-estate IDs of drawers to merge.
    ///   - branch: The source branch.
    ///   - handle: The destination parent estate handle.
    /// - Returns: A `MergeReport` listing merged, skipped, and conflict IDs.
    @discardableResult
    func glkMergeDrawers(
        _ drawerIDs: [RowID],
        from branch: any BranchHandle,
        into handle: EstateHandle
    ) async throws -> MergeReport {
        guard let concreteBranch = branch as? EstateBranch else {
            throw GeniusLocusKitError.branchNotTracked(branchID: branch.branchID)
        }
        // Registry check: reject branches from a different kit instance that
        // pass the type cast but are not tracked by this actor.
        guard branches[concreteBranch.branchID] != nil else {
            throw GeniusLocusKitError.branchNotTracked(branchID: concreteBranch.branchID)
        }
        // Lifecycle guard: same invariant as glkPromoteBranch — terminal
        // branches (won/merged/discarded) are read-only history and cannot
        // cherry-pick content into the parent.
        guard concreteBranch.status == .active else {
            throw GeniusLocusKitError.branchNotActive(
                branchID: concreteBranch.branchID, status: concreteBranch.status)
        }
        // Validate the handle before the E-2 guard: estate(for:) throws
        // .estateNotOpen for a stale handle, surfacing the error before the
        // promotion-target check. The estate itself is not used directly here
        // because capture routes through the GLK mode-aware verb (not estate.capture).
        _ = try estate(for: handle)
        // E-2 guard: cherry-pick merge must target the branch's parent estate,
        // not an arbitrary one.
        try await assertPromotionTarget(concreteBranch, into: handle)

        // Recall all branch rows to find the requested ones. `.full` hydration
        // is required because each selected row is immediately re-captured into
        // the parent estate via `Estate.capture`, which requires non-empty content.
        // Per spec § 7.3, `.structured` returns `content = ""` (no blob reads),
        // so using `.structured` here would fail the capture guard for every
        // cherry-picked row.
        let frame = RecallFrame(
            filterChain: [.unconfirmed],
            hydrationLevel: .full,
            ordering: .byCaptureTimeDesc
        )
        let branchRows = try await concreteBranch.recall(frame)
        let rowsByID = Dictionary(uniqueKeysWithValues: branchRows.map { ($0.id, $0) })

        // Resolve parentNodeId → (wing, room) names once for all branch rows.
        // Drawer no longer carries wing/room stored properties (node-tree
        // migration); wing and room are both recovered from the BRANCH
        // estate's node tree (branch rows have parentNodeIds pointing to
        // branch-local nodes, not parent estate nodes).
        //
        // Wing integrity (ADR-016): all security/placement/lifecycle fields
        // are preserved on merge so non-default-wing rows re-file into the
        // correct wing rather than silently falling back to defaultWing().
        // lineageID is intentionally NOT preserved — see derivation comment.
        let mergeNodeIdSet = Array(Set(branchRows.map(\.parentNodeId)))
        let mergeNodeNames = try await concreteBranch.branchEstate.resolveNodeNames(parentNodeIds: mergeNodeIdSet)

        var merged: [DrawerID] = []
        var skipped: [DrawerID] = []

        for id in drawerIDs {
            guard let row = rowsByID[id] else {
                skipped.append(id)
                continue
            }
            // mode: .regular routes through the GLK encode pipeline so merged
            // drawers become BM25/vector searchable via the drain worker — a
            // direct parentEstate.capture() would bypass the Corpus feed entirely.
            // Wing and room both resolved from the node tree (Drawer no longer
            // stores wing/room); wing nil → CaptureFrame defaults to defaultWing().
            let names = mergeNodeNames[row.parentNodeId]
            let wingName = names?.wing
            let roomName = names?.room ?? ""
            let captureFrame = CaptureFrame(
                content: row.content,
                channel: row.captureChannel,
                room: roomName,
                latticeAnchor: LatticeAnchor(
                    udcCode: row.udcCode,
                    udcFacets: row.udcFacets,
                    wikidataQID: row.wikidataQID,
                    wikidataQidsSecondary: row.wikidataQidsSecondary
                ),
                addedBy: row.addedBy,
                embeddingModelID: row.embeddingModelID,
                sensitivity: row.adjectiveSensitivity,
                kind: row.contentKind,
                provenanceChannel: row.channel,
                sourceType: row.sourceType,
                provenanceSensitivity: row.sensitivity,
                confirmation: row.confirmation,
                confidence: row.confidence,
                eventTime: row.eventTime,
                featureFlags: row.featureFlags,
                exportability: row.exportability,
                wing: wingName
            )
            _ = try await capture(handle, captureFrame, mode: .regular)
            merged.append(id)
        }

        // Transition the branch to .merged, then release the row copy (the
        // merged rows live in the parent estate now). The O(1) .merged shell
        // stays in the registry.
        concreteBranch.setStatus(.merged)
        try await concreteBranch.releaseRows()
        Self.verbLog.debug("glkMergeDrawers '\(branch.name, privacy: .public)' → .merged (\(merged.count) merged, \(skipped.count) skipped)")

        return MergeReport(merged: merged, conflicts: [], skipped: skipped)
    }

    // MARK: - branchHandle(for:)

    /// Resolve a tracked branch by its `BranchID` to its `BranchHandle`.
    ///
    /// Branches are retained in the kit's registry through every lifecycle
    /// state (active / won / merged / discarded) from `glkDeriveBranch`
    /// until the kit is released (the audit trail must remain reachable,
    /// I-15). This read accessor lets a *stateless* caller recover a live
    /// handle from a `BranchID` a prior call surfaced — notably the
    /// ARIA_MCP recipe surface, where a recipe's `run` and its
    /// human-confirmed promotion arrive as two separate stateless
    /// `tools/call` invocations against one long-lived kit. Returns nil
    /// when no branch with that id was derived by this kit instance.
    ///
    /// Read-only: it neither mints nor mutates branch state. Promotion,
    /// merge, and discard still flow through `glkPromoteBranch` /
    /// `glkMergeDrawers` / `BranchHandle.discard()` — the write surface is
    /// unchanged.
    func branchHandle(for branchID: BranchID) -> (any BranchHandle)? {
        branches[branchID]
    }

    // MARK: - markRecallUsed

    /// Mark recall-trace rows for a drawer target as used within the trace
    /// retention window ending at `now`.
    ///
    /// Per the trace-reward design (DESIGN_TRACE_REWARD_2026-06-12):
    /// ARIA observes that a surfaced drawer was subsequently dereferenced by
    /// the external consumer (a later `withdraw`, `mutate`, `confirm`, `move`,
    /// `link`, or `connection_map` tool call referencing the same id). ARIA
    /// calls this GLK verb to record that experience. The window is
    /// `[now - traceRetention, now]` so any live trace row for that drawer
    /// is caught regardless of which tick it was written on.
    ///
    /// Layer discipline (Interface Rule): ARIA must NOT reach around GLK into
    /// LocusKit. This pass-through is the correct boundary: ARIA → GLK →
    /// LocusKit.
    ///
    /// - Parameters:
    ///   - handle: the estate the drawer lives in. Must be open in this kit.
    ///   - target: the drawer id whose live trace rows to mark used.
    ///   - now:    the current wall time, supplied deterministically by the caller.
    /// - Returns: number of rows whose `used` bit was flipped (0 if none
    ///            or all already marked).
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if `handle` is stale.
    @discardableResult
    func markRecallUsed(_ handle: EstateHandle, target: RowID, now: Date) async throws -> Int {
        let estate = try estate(for: handle)
        // Window: [now - traceRetention, now]. traceRetention mirrors the
        // 30-day prune window in the dreaming daemon so any still-live trace
        // row for that drawer is within scope. Using the full retention window
        // is simpler and matches the design memo § 3 recommendation.
        let since = now.addingTimeInterval(-GeniusLocusKit.traceRetentionSeconds)
        do {
            return try await estate.markRecallTracesUsed(target: target, since: since, now: now)
        } catch {
            throw remap(verb: "markRecallUsed", estateID: handle.estateUUID.uuidString, error: error)
        }
    }

    /// Count all rows in the recall_trace table for the estate addressed by
    /// `handle`. Used by estate-status reporting so trace-table growth is
    /// observable. Returns 0 on an empty table or for a stale handle.
    ///
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if `handle` is stale.
    func countRecallTraces(_ handle: EstateHandle) async throws -> Int {
        let estate = try estate(for: handle)
        do {
            return try await estate.countRecallTraces()
        } catch {
            throw remap(verb: "countRecallTraces", estateID: handle.estateUUID.uuidString, error: error)
        }
    }

    /// Count raw rows in the `drawers` table via SQL `COUNT(*)`, bypassing
    /// all decode logic. Corrupt rows (e.g. a poison timestamp) are still
    /// counted. Used by the vault-export fail-loud path to distinguish
    /// "estate is genuinely empty" from "recall returned 0 because all rows
    /// are corrupt." Delegates to `Estate.countDrawerRows()`. Mirrors Rust
    /// `EstateCoordinator::count_drawer_rows`.
    func countDrawerRows(_ handle: EstateHandle) async throws -> Int {
        let estate = try estate(for: handle)
        do {
            return try await estate.countDrawerRows()
        } catch {
            throw remap(verb: "countDrawerRows", estateID: handle.estateUUID.uuidString, error: error)
        }
    }

    // MARK: - Internal helpers

    /// Return the cached `DrawerStore` for KGFact writes against `handle`,
    /// building one from the retained `Storage` on first use. Mirrors
    /// `ensureDiaryStore(for:)` in `DreamingWrites.swift` and
    /// `ensureGrantSurface(for:)` here: the storage is retained in
    /// `storages[handle]` since `open`; the store is built lazily and cached
    /// in `kgStores[handle]`. Caching is required — `DrawerStore.init` applies
    /// schema migrations and reads the manifest on every instantiation.
    private func ensureKGStore(for handle: EstateHandle) async throws -> DrawerStore {
        if let store = kgStores[handle] { return store }
        guard let storage = storages[handle] else {
            throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
        }
        let store = try await DrawerStore(storage: storage)
        kgStores[handle] = store
        return store
    }

    /// Drain all unconfirmed rows from a LocusKit estate into an array.
    /// Used by `glkDeriveBranch` to snapshot the parent or parent-branch
    /// estate at derivation time.
    ///
    /// `.full` hydration is required because the snapshot rows are immediately
    /// re-captured into the branch estate via `Estate.capture`, which requires
    /// non-empty content. Per spec § 7.3, `.structured` returns `content = ""`
    /// (no blob reads), so a `.structured` snapshot would fail the capture
    /// guard. This is an internal, bounded read: the rows are not returned to
    /// callers, so loading blobs here is O(estate) and intentional.
    private func recallRows(from estate: LocusKit.Estate) async throws -> [Drawer] {
        let frame = RecallFrame(
            filterChain: [.unconfirmed],
            hydrationLevel: .full,
            ordering: .byCaptureTimeDesc
        )
        let stream = await estate.recall(frame)
        var rows: [Drawer] = []
        for await page in stream {
            rows.append(contentsOf: page.rows)
        }
        return rows
    }

    /// Assert a branch is being promoted/merged into the estate it was
    /// derived from (FUP-D, E-2).
    ///
    /// Promotion re-captures branch content into `handle`'s estate. The
    /// destination must equal `branch.parentEstate`; otherwise content would
    /// silently cross an estate boundary — and, under per-estate keys, a key
    /// boundary. `parentEstate` is a `LocusKit.Estate` actor, so reading its
    /// `estateUUID` requires `await`.
    private func assertPromotionTarget(_ branch: EstateBranch, into handle: EstateHandle) async throws {
        let parentUUID = await branch.parentEstate.estateUUID
        guard handle.estateUUID == parentUUID else {
            throw GeniusLocusKitError.invalidPromotionTarget(
                branchID: branch.branchID,
                expectedEstateUUID: parentUUID,
                actualEstateUUID: handle.estateUUID
            )
        }
    }

    // MARK: - Error remapping

    /// Translate an error caught from a LocusKit verb dispatch into a
    /// `VerbError`. A `LocusKitError.notSupported` (or an
    /// `.invalidContent` whose message contains "not yet implemented")
    /// is normalised to `VerbError.notSupportedByEstate(verb:)` so callers
    /// see one case for any genuinely-unsupported dispatch. All nine ARIA
    /// verbs are live; this path remains the generic fallback for any verb
    /// whose dependency is unavailable. Every other LocusKit error becomes
    /// `VerbError.underlyingEstateFailure(verb:reason:)`.
    ///
    /// `GeniusLocusKitError` cases (notably `.estateNotOpen` raised by
    /// `estate(for:)`) are passed through unchanged so callers can
    /// distinguish a stale handle from a verb-level fault.
    ///
    /// When `estateID` is non-empty and monitoring is enabled, emits a
    /// `geniuslocus.estate.verb_error` metric tagged with the verb name
    /// and estate id (GLK_ROLLUPS_001). Off-path cost is one Atomic<Bool>
    /// load (~1 ns) — no impact when monitoring is disabled.
    func remap(verb: String, estateID: String = "", error: Error) -> Error {
        // Telemetry: emit verb error at the GLK boundary (GLK_ROLLUPS_001).
        // Only emitted when estateID is known; GeniusLocusKitError pass-through
        // cases (estateNotOpen) originate before verb dispatch so estateID may
        // be unavailable — those do not emit (they are routing errors, not
        // verb errors, and the caller handles them directly).
        if !estateID.isEmpty {
            Intellectus.report(.metric(
                name: GLKMetricName.verbError,
                value: 1.0,
                tags: ["estate_id": estateID, "verb": verb],
                ts: Date().timeIntervalSince1970
            ))
        }
        if let glkError = error as? GeniusLocusKitError {
            return glkError
        }
        // LocusKitError.notSupported is the canonical fail-loud path for
        // verbs whose dependencies are not yet implemented. Maps to
        // notSupportedByEstate so ARIA callers receive a typed, structured
        // error rather than an opaque underlyingEstateFailure.
        if let locusError = error as? LocusKitError,
           case .notSupported = locusError {
            return VerbError.notSupportedByEstate(verb: verb)
        }
        if let locusError = error as? LocusKitError,
           case .invalidContent(let detail) = locusError,
           detail.contains("not yet implemented") {
            return VerbError.notSupportedByEstate(verb: verb)
        }
        return VerbError.underlyingEstateFailure(verb: verb, reason: "\(error)")
    }
}

// MARK: - Grant surface (GRT-01)

/// The result of issuing a grant.
///
/// `scopeKey` is non-nil only for custody mode 2 (handed-over): the
/// derived scope key is returned to the caller exactly once at issue.
/// For mode 1 (mediated) it is nil — the key stays in the vault.
public struct IssueGrantResult: Sendable {
    public let grant: Grant
    public let scopeKey: Data?
}

public extension GeniusLocusKit {

    /// Issue a federation grant from the estate addressed by `handle`.
    ///
    /// Per DECISION_FEDERATION_SHARING_MODEL_2026-05-21 §6 and Appendix
    /// B. The grant is signed by the estate's Ed25519 identity key, then
    /// persisted to the estate's `grants` table. The scope key is
    /// handled per custody mode: mode 1 retains it in the vault and
    /// returns nil; mode 2 returns it to the caller and retains nothing;
    /// mode 3 (decay-derived) reconstructs and returns it to the caller
    /// and retains nothing (no-vault posture). Mode 3 requires confirmed
    /// IP clearance (`experimentalIPClearanceConfirmed: true`) and raises
    /// `experimentalModeNotActivated` without it.
    ///
    /// - Parameters:
    ///   - handle: the issuing estate. Must be open in this kit.
    ///   - options: grant terms, including the grantee estate id.
    ///   - now: issue instant, supplied so issuance is deterministic and
    ///     testable. Defaults to the current time at the call site.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` for a stale handle;
    ///   `GrantError` for a gated custody mode or a missing identity key.
    func issueGrant(
        _ handle: EstateHandle,
        _ options: GrantOptions,
        now: Date = Date()
    ) async throws -> IssueGrantResult {
        let estate = try estate(for: handle)
        // Gate experimental custody modes before any key or storage work.
        try Self.gateCustody(options.custodyMode)
        let identityKey = try await signingIdentity(for: estate)

        // Build and sign the grant. The default inference budget is the
        // full allotment (1.0); the federation layer debits it later.
        let id = UUID()
        let payload = Grant.canonicalPayload(
            id: id,
            granteeEstateID: options.granteeEstateID,
            scope: options.scope,
            contentLevel: options.contentLevel,
            lifetime: options.lifetime,
            custodyMode: options.custodyMode,
            reSharePermission: options.reSharePermission,
            inferenceRemainingBudget: 1.0,
            issuedAt: now
        )
        let signature = try identityKey.signature(for: payload)
        let grant = Grant(
            id: id,
            granteeEstateID: options.granteeEstateID,
            scope: options.scope,
            contentLevel: options.contentLevel,
            lifetime: options.lifetime,
            custodyMode: options.custodyMode,
            reSharePermission: options.reSharePermission,
            inferenceRemainingBudget: 1.0,
            issuedAt: now,
            signature: signature
        )

        let (store, vault) = try await ensureGrantSurface(for: handle)
        try await store.insert(grant)
        // Pass raw key bytes rather than the CryptoKit PrivateKey so ScopeKeyVault
        // carries no CryptoKit dependency. The signing op above (identityKey.signature)
        // still uses CryptoKit; only the HKDF IKM path is raw bytes.
        let scopeKey = try await vault.issue(grant: grant, identityKeyRawBytes: [UInt8](identityKey.rawRepresentation))
        // Emit the grant-issued audit entry now that the grant is
        // persisted and the scope key is in custody, so the estate's
        // unified chain records the grant lifecycle (FUP-C / GLK-03 seam).
        try await appendGrantAuditEntry(
            verb: .grantIssued,
            grantID: grant.id,
            custodyToken: grant.custodyMode.columnToken,
            before: .null,
            after: .bitmap(Self.grantActiveBit),
            handle: handle,
            now: now
        )
        Self.verbLog.debug("issueGrant \(id, privacy: .public) custody=\(grant.custodyMode.columnToken, privacy: .public)")
        return IssueGrantResult(grant: grant, scopeKey: scopeKey)
    }

    /// Revoke a grant on the estate addressed by `handle`.
    ///
    /// Writes a revocation record to the `grants` table (best-effort for
    /// mode 2: it does not fault on an offline recipient) and drops any
    /// mode-1 scope key from the vault so subsequent `access` fails
    /// closed (cryptographic clawback).
    ///
    /// - Throws: `GeniusLocusKitError.estateNotOpen` for a stale handle;
    ///   `GrantError.grantNotFound` if no such grant exists.
    func revokeGrant(
        _ handle: EstateHandle,
        grantID: UUID,
        now: Date = Date()
    ) async throws {
        _ = try estate(for: handle)
        let (store, vault) = try await ensureGrantSurface(for: handle)
        // Capture the stored grant (not just its presence) so the audit
        // entry can record the revoked grant's custody-mode token.
        guard let stored = try await store.get(id: grantID) else {
            throw GrantError.grantNotFound(id: grantID)
        }
        try await store.revoke(id: grantID, at: now)
        await vault.revoke(grantID: grantID)
        // Emit the grant-revoked audit entry after the revocation record
        // is written and the mode-1 key is dropped from the vault, so the
        // chain records the lifecycle close (FUP-C / GLK-03 seam).
        try await appendGrantAuditEntry(
            verb: .grantRevoked,
            grantID: grantID,
            custodyToken: stored.grant.custodyMode.columnToken,
            before: .bitmap(Self.grantActiveBit),
            after: .bitmap(0),
            handle: handle,
            now: now
        )
        Self.verbLog.debug("revokeGrant \(grantID, privacy: .public)")
    }
}

// Internal grant-surface plumbing. Kept in a non-public extension so the
// lazy registries and helpers stay module-internal while the verbs above
// are the public surface.
extension GeniusLocusKit {

    /// The estate's grant store, or nil if no grant has been issued yet.
    /// Internal so GRT-01 tests can assert persisted state.
    func grantStore(for handle: EstateHandle) -> GrantStore? { grantStores[handle] }

    /// The estate's scope-key vault, or nil if no grant has been issued
    /// yet. Internal for the same reason as `grantStore(for:)`.
    func scopeVault(for handle: EstateHandle) -> ScopeKeyVault? { scopeVaults[handle] }

    /// Return the estate's grant store and scope vault, building them on
    /// first use over the estate's retained storage. The `GrantStore`
    /// init declares the `grants` table in that storage.
    func ensureGrantSurface(for handle: EstateHandle) async throws -> (GrantStore, ScopeKeyVault) {
        if let store = grantStores[handle], let vault = scopeVaults[handle] {
            return (store, vault)
        }
        guard let storage = storages[handle] else {
            throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
        }
        let store = try await GrantStore(storage: storage)
        let vault = ScopeKeyVault()
        grantStores[handle] = store
        scopeVaults[handle] = vault
        return (store, vault)
    }

    /// Bit 0 of a grant audit entry's bitmap value marks the grant as in
    /// force. A `.grantIssued` entry transitions the value from `.null`
    /// (the grant did not exist) to this bit set; a `.grantRevoked` entry
    /// transitions it from this bit set to `.bitmap(0)` (cleared). The bit
    /// lets the audit projection fold a grant's lifecycle while reusing
    /// the same `.bitmap` value shape `AuditBridge` uses for LocusKit-tier
    /// mutations, rather than introducing a bespoke value case.
    private static let grantActiveBit: UInt64 = 1

    /// Append a grant-lifecycle audit entry to the estate's unified log.
    ///
    /// Wires the seam GLK-03 left for the grant verbs: it declared the
    /// `.grantIssued` / `.grantRevoked` verb cases but no verb emitted
    /// them, so an estate's audit chain showed no grant lifecycle
    /// (AUDIT-01 Zone D / FUP-C). The entry follows the GLK-03 field
    /// convention — grant id in `rowID`, custody-mode token in
    /// `fieldPath` — and carries the active-bit state transition in
    /// `before` / `after`. Tier is `.locus`: grants persist in the
    /// estate's primary (LocusKit-backed) storage. The HLC physical time
    /// is milliseconds since the Unix epoch derived from `now`, matching
    /// `AuditBridge` so a grant entry orders on the same clock as the
    /// LocusKit-tier entries; `verifyAuditChain` sorts by HLC, so the
    /// appended entry cannot break the chain.
    ///
    /// Durable append through the same substrate `AuditEvent` pipeline
    /// `appendSensitivityAuditEntry` uses (SensitivityAuditVerbs.swift):
    /// a synthetic (non-drawer) event whose bitmap slots carry the
    /// `before`/`after` values via `SyntheticAuditValueCodec`
    /// (AuditBridge.swift) rather than real bitmap-column state, decoded
    /// back into a `UnifiedAuditEntry` by `AuditBridge`'s synthetic-verb
    /// path. `storage.auditLog` is the estate's durable, O(N)-bounded
    /// audit store (764b370e) — this append adds one row, not an
    /// in-memory G-Set entry, so the O(N)-RAM goal that migration set
    /// holds. Awaited (not fire-and-forget): a failed durable append on
    /// this security-relevant write path must surface to the caller, not
    /// be silently dropped (issueGrant / revokeGrant are already `async
    /// throws`, so the throw propagates with no signature change there).
    private func appendGrantAuditEntry(
        verb: UnifiedAuditVerb,
        grantID: UUID,
        custodyToken: String,
        before: UnifiedAuditValue,
        after: UnifiedAuditValue,
        handle: EstateHandle,
        now: Date
    ) async throws {
        guard let storage = storages[handle] else {
            throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
        }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        // Synthetic HLC: physical time from `now`, logical 0, node 0 —
        // matches the sensitivity-unlock seam's derivation exactly so a
        // grant entry and a sensitivity entry order on the same clock.
        let hlc = HLC(physicalTime: nowMs, logicalCount: 0, nodeID: 0)
        let (beforeKind, beforePayload) = SyntheticAuditValueCodec.encode(before)
        let (afterKind, afterPayload) = SyntheticAuditValueCodec.encode(after)
        let event = AuditEvent(
            estateUuid: handle.estateUUID,
            rowId: grantID,
            hlc: hlc,
            verb: verb.rawValue,
            beforeBitmaps: (adjective: beforePayload, operational: 0, provenance: beforeKind),
            afterBitmaps: (adjective: afterPayload, operational: 0, provenance: afterKind),
            beforeLatticeAnchor: nil,
            afterLatticeAnchor: SubstrateTypes.LatticeAnchor(udcCode: 0, qidPointer: 0),
            actor: "grant-audit",
            reason: custodyToken
        )
        try await storage.auditLog.append(event)
    }

    /// Drop the grant surface for a handle on close. The vault is
    /// discarded with all its in-memory mode-1 keys.
    func dropGrantSurface(for handle: EstateHandle) {
        storages[handle] = nil
        grantStores[handle] = nil
        scopeVaults[handle] = nil
    }

    /// Load the estate's Ed25519 private signing key from the in-memory cache
    /// populated at `Estate.open` time.
    ///
    /// The private key is loaded from the identity key store (Keychain in
    /// production) by `Estate.open` and held in memory for the lifetime of the
    /// Estate instance. This method reads that cached value — no Keychain
    /// round-trip occurs at signing time (ADR-007, secfix/ed25519-keychain).
    ///
    /// Throws `GeniusLocusKitError.invalidManifest` when the key is absent,
    /// which happens when the estate was opened after a Keychain wipe or was
    /// opened with a key store that did not contain the key.
    private func signingIdentity(for estate: LocusKit.Estate) async throws -> Curve25519.Signing.PrivateKey {
        guard let raw = await estate.retrievePrivateSigningKeyData() else {
            throw GeniusLocusKitError.invalidManifest(
                key: ManifestKey.ed25519PrivateKeyWrapped.rawValue,
                detail: "estate Ed25519 identity key is absent from the key store; " +
                        "the estate may have been opened after a Keychain wipe or " +
                        "with a key store that does not contain the private key"
            )
        }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    }

    /// Return the estate's Ed25519 identity public key in raw-byte form.
    ///
    /// Used as the trust anchor for grant signature verification at the
    /// `federatedRecall` boundary (D9 hardening). Trust derives from the
    /// registry — the key material held in-memory by the Estate instance
    /// since `Estate.open` — not from any field in the grant blob itself.
    /// This matches the registered-key pattern in ConvergenceKit
    /// `FederationSyncEngine.pull()` (F-3 hardening).
    ///
    /// Throws `GeniusLocusKitError.invalidManifest` when the identity key
    /// is absent from the key store (estate opened after a Keychain wipe
    /// or with a key store that did not contain the private key).
    func estateSigningPublicKey(for estate: LocusKit.Estate) async throws -> Data {
        let identity = try await signingIdentity(for: estate)
        return identity.publicKey.rawRepresentation
    }

    /// Gate the experimental custody modes at the verb boundary. Modes 1
    /// and 2 pass through. Mode 3 (decay-derived) requires confirmed IP
    /// clearance (`experimentalIPClearanceConfirmed: true`) and raises
    /// `experimentalModeNotActivated` without it; with clearance it passes
    /// through — the Lagrange key mechanics are implemented (ENC-02). Mode 4
    /// (time-aging) is a shippable software policy with no IP-clearance gate;
    /// it passes through and its decay is enforced on the recall path.
    /// Maximum supported share count for mode-3 (decay-derived) custody.
    /// Bounds the Lagrange interpolation domain to a practical maximum;
    /// larger share sets are rejected at issuance so the vault never
    /// allocates an unbounded polynomial evaluation (planned security
    /// hardening — B1, finding #2).
    private static let maxDecayShares = 255

    private static func gateCustody(_ mode: CustodyMode) throws {
        switch mode {
        case .mediated, .handedOver, .timeAging:
            return
        case .decayDerived(let threshold, let totalShares, _, let confirmed):
            guard confirmed else { throw GrantError.experimentalModeNotActivated }
            // Validate Lagrange parameters before any key or storage work.
            // threshold=0 or totalShares<threshold causes reconstruct() to
            // interpolate an empty point set, producing DecayFieldElement.zero
            // — a constant anyone can precompute, breaking the custody model.
            guard threshold > 0,
                  totalShares >= threshold,
                  totalShares <= maxDecayShares
            else { throw GrantError.invalidCustodyParameters }
            // Clearance confirmed, parameters valid: permit issuance.
            // The decay-derived key is reconstructed in the vault's issue
            // path (ENC-02).
            return
        }
    }
}
