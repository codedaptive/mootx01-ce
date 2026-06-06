import Foundation
import IntellectusLib
import OSLog
import CryptoKit
import LocusKit
import PersistenceKit
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateTypes

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
/// methods except `mutate`'s non-confirm state-axis kinds (`.reject`,
/// `.contest`, `.resolve`, `.supersede`, `.revive`), which throw
/// `LocusKitError.invalidContent("…not yet implemented")`. The GLK
/// boundary recognises this pattern and re-raises it as
/// `VerbError.notSupportedByEstate(verb:)` so callers see a single
/// case. Other LocusKit failures flow through as
/// `VerbError.underlyingEstateFailure(verb:reason:)`.
public extension GeniusLocusKit {

    /// Logger reused across verb dispatch. The static logger on the
    /// actor is private; declaring a local computed accessor keeps the
    /// fleet-standard subsystem/category in one place per CLAUDE.md.
    private static var verbLog: Logger {
        Logger(subsystem: "com.mootx01.kit", category: "GeniusLocusKit")
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
    /// with `mode: .locusOnly, scoring: .raw` and returns the hydrated drawers
    /// from the result, matching the prior flat-array contract.
    ///
    /// Callers that need multi-lane or scored recall use
    /// `recall(_ handle:, _ request: GLKRecallRequest)` directly.
    ///
    /// - Returns: drawers matching the frame's filter chain, in the
    ///   ordering the frame requested.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if `handle` is stale.
    func recall(_ handle: EstateHandle, _ frame: RecallFrame) async throws -> [Drawer] {
        let result = try await recall(handle, GLKRecallRequest(
            frame: frame,
            mode: .locusOnly,
            scoring: .raw,
            limit: frame.limit ?? 50,
            fallback: .failClosed
        ))
        return result.drawers
    }

    // MARK: - recallTunnels

    /// Recall the tunnels originating in `wing` from the estate addressed
    /// by `handle`, unioned with any host-tree containment edges from a
    /// registered `NodeTopologyProvider`.
    ///
    /// Resolves the handle through `estate(for:)` and returns the
    /// non-tombstoned drawer-to-drawer tunnels whose source is `wing`,
    /// in stable filed-at order. These edges are the graph the structural
    /// reasoning-lens recipes (keystones, constellation, free association,
    /// tunnel successor) read; the recipe layer never reaches the substrate
    /// directly. Read-only; a wing with no tunnels reads empty.
    ///
    /// G1 — read-once-and-freeze: when a `NodeTopologyProvider` is registered
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
    /// B-1 — layer discipline: the structural lenses (CognitionKit) call
    /// this method and receive the unioned edge set. They never import or
    /// reference `NodeTopologyProvider` directly.
    ///
    /// When no provider is registered, the method returns only stored
    /// tunnels — existing behaviour is unchanged (no-provider path is
    /// identical to pre-.nodeTreeNative behaviour).
    ///
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if `handle` is stale.
    func recallTunnels(_ handle: EstateHandle, wing: String) async throws -> [Tunnel] {
        let estate = try estate(for: handle)

        // G1 — read-once-and-freeze. Call treeEdges exactly once here;
        // no provider method is called again during this recall or by any
        // consumer of the returned array.
        let frozenTreeEdges: [(parent: String, child: String)]
        if let provider = nodeTopologyProviders[handle] {
            frozenTreeEdges = await provider.treeEdges(scope: nil)
        } else {
            // No provider registered — empty tree edge set, existing behaviour
            // unchanged. Structural lenses see only stored tunnel edges.
            frozenTreeEdges = []
        }

        // Read stored tunnels from the estate.
        let storedTunnels = try await estate.tunnelsFromWing(wing)

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

    // MARK: - recallKGFacts

    /// Recall all active kg-fact rows from the estate addressed by `handle`.
    ///
    /// Returns kg-facts where state cluster < 7 (active, pre-resolution
    /// states), ordered by `filedAt` ascending. Delegates to
    /// `Estate.allKGFacts`. Peer of the Rust `EstateCoordinator::recall_kg_facts`.
    ///
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if `handle` is stale.
    func recallKGFacts(_ handle: EstateHandle) async throws -> [KGFact] {
        let estate = try estate(for: handle)
        return try await estate.allKGFacts()
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
    /// estate for audit purposes. `State.withdrawn` (rawValue 18) sets
    /// `g_state_cluster` >= 7, which exits the active-recall filter in
    /// `allKGFacts`. Routes through `DrawerStore.withdrawKGFact` directly —
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

    // MARK: - mutate

    /// Apply a named mutation to a drawer in the estate addressed by
    /// `handle`.
    ///
    /// Dispatches to `LocusKit.Estate.mutate(rowID:kind:payload:)`. The
    /// `.confirm` kind is live — it moves the row's confirmation axis to
    /// `.userConfirmed` and returns normally. The state-axis kinds
    /// (`.reject` / `.contest` / `.resolve` / `.supersede` / `.revive`)
    /// are not yet wired and throw `LocusKitError.invalidContent`; the GLK
    /// boundary re-raises those as `VerbError.notSupportedByEstate(verb:
    /// "mutate")` so callers branch on a single case.
    func mutate(_ handle: EstateHandle, _ frame: MutateFrame) async throws {
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
        let estate = try estate(for: handle)
        do {
            try await estate.withdraw(rowID: frame.rowID, reason: frame.reason)
        } catch {
            throw remap(verb: "withdraw", estateID: handle.estateUUID.uuidString, error: error)
        }
    }

    // MARK: - expunge

    /// Tombstone a drawer in the estate addressed by `handle` and
    /// zeroize its content blob.
    ///
    /// Raises `VerbError.expungeNotConfirmed` at the GLK boundary
    /// when `frame.confirmation` is false; the substrate is not
    /// reached. With confirmation, dispatches to LocusKit's implemented
    /// `expunge` (cookbook §10.5); any real failure is remapped to
    /// `VerbError` via `remap`.
    func expunge(_ handle: EstateHandle, _ frame: ExpungeFrame) async throws {
        guard frame.confirmation else {
            throw VerbError.expungeNotConfirmed(rowID: frame.rowID)
        }
        let estate = try estate(for: handle)
        do {
            try await estate.expunge(
                rowID: frame.rowID,
                reason: frame.reason,
                confirmation: frame.confirmation
            )
        } catch {
            throw remap(verb: "expunge", estateID: handle.estateUUID.uuidString, error: error)
        }
    }

    // MARK: - reanchor

    /// Move a drawer's lattice anchor or its room within the estate
    /// addressed by `handle`. At least one of `toRoom` or `toLattice`
    /// must be present; an empty reanchor raises `VerbError.emptyReanchor`
    /// at the GLK boundary before dispatch.
    func reanchor(_ handle: EstateHandle, _ frame: ReanchorFrame) async throws {
        guard frame.toRoom != nil || frame.toLattice != nil else {
            throw VerbError.emptyReanchor(rowID: frame.rowID)
        }
        let estate = try estate(for: handle)
        do {
            try await estate.reanchor(
                rowID: frame.rowID,
                toRoom: frame.toRoom,
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
    /// Delegates to `Estate.learn` and returns the stored `LearnedReference`.
    /// Per cookbook §10.9 / spec § 7.8.2.
    ///
    /// - Returns: the stored `LearnedReference`.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if `handle` is stale;
    ///   `VerbError.underlyingEstateFailure` on any LocusKit failure.
    @discardableResult
    func learn(_ handle: EstateHandle, _ frame: LearnFrame) async throws -> LocusKit.LearnedReference {
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
        // estateNotOpen before any feed work, matching the other verbs.
        _ = try estate(for: handle)
        try await feedAuditLog(for: handle)
        let log = try auditLog(for: handle)
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
    func glkDeriveBranch(name: String, from handle: EstateHandle) async throws -> any BranchHandle {
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
        let parentEstate = try estate(for: handle)
        // E-2 guard: the destination must be the branch's parent estate, so
        // promotion cannot silently move content across an estate (and key)
        // boundary. Runs after estate(for:) so a stale handle still surfaces
        // as .estateNotOpen first.
        try await assertPromotionTarget(concreteBranch, into: handle)

        // Recall all current branch rows and identify those added after
        // derivation (not in snapshotIDs).
        let frame = RecallFrame(
            filterChain: [.unconfirmed],
            hydrationLevel: .structured,
            ordering: .byCaptureTimeDesc
        )
        let branchRows = try await concreteBranch.recall(frame)
        let newRows = branchRows.filter { !concreteBranch.snapshotIDs.contains($0.id) }

        // Re-capture each new row into the parent estate. A new ID is
        // minted for each because CaptureFrame has no id field and
        // Estate.store is internal to LocusKit. Content fidelity is
        // preserved; ID correlation is done by content string in tests.
        for row in newRows {
            let captureFrame = CaptureFrame(
                content: row.content,
                channel: row.captureChannel,
                room: row.room,
                latticeAnchor: LatticeAnchor(
                    udcCode: row.udcCode,
                    udcFacets: row.udcFacets,
                    wikidataQID: row.wikidataQID,
                    wikidataQidsSecondary: row.wikidataQidsSecondary
                ),
                addedBy: row.addedBy,
                embeddingModelID: row.embeddingModelID,
                sensitivity: row.adjectiveSensitivity,
                kind: row.contentKind
            )
            _ = try await parentEstate.capture(captureFrame)
        }

        // Transition the branch to .won.
        concreteBranch.setStatus(.won)
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
        let parentEstate = try estate(for: handle)
        // E-2 guard: cherry-pick merge must target the branch's parent estate,
        // not an arbitrary one. Runs after estate(for:) so a stale handle still
        // surfaces as .estateNotOpen first.
        try await assertPromotionTarget(concreteBranch, into: handle)

        // Recall all branch rows to find the requested ones.
        let frame = RecallFrame(
            filterChain: [.unconfirmed],
            hydrationLevel: .structured,
            ordering: .byCaptureTimeDesc
        )
        let branchRows = try await concreteBranch.recall(frame)
        let rowsByID = Dictionary(uniqueKeysWithValues: branchRows.map { ($0.id, $0) })

        var merged: [DrawerID] = []
        var skipped: [DrawerID] = []

        for id in drawerIDs {
            guard let row = rowsByID[id] else {
                skipped.append(id)
                continue
            }
            let captureFrame = CaptureFrame(
                content: row.content,
                channel: row.captureChannel,
                room: row.room,
                latticeAnchor: LatticeAnchor(
                    udcCode: row.udcCode,
                    udcFacets: row.udcFacets,
                    wikidataQID: row.wikidataQID,
                    wikidataQidsSecondary: row.wikidataQidsSecondary
                ),
                addedBy: row.addedBy,
                embeddingModelID: row.embeddingModelID,
                sensitivity: row.adjectiveSensitivity,
                kind: row.contentKind
            )
            _ = try await parentEstate.capture(captureFrame)
            merged.append(id)
        }

        // Transition the branch to .merged.
        concreteBranch.setStatus(.merged)
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
    private func recallRows(from estate: LocusKit.Estate) async throws -> [Drawer] {
        let frame = RecallFrame(
            filterChain: [.unconfirmed],
            hydrationLevel: .structured,
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
    /// `VerbError`. LocusKit's stubs for mutate/expunge/reanchor/learn
    /// throw `LocusKitError.invalidContent` with a message containing
    /// "not yet implemented"; that pattern is normalised to
    /// `VerbError.notSupportedByEstate(verb:)` so callers see one case
    /// across all stubbed dispatches. Every other LocusKit error
    /// becomes `VerbError.underlyingEstateFailure(verb:reason:)`.
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
    /// and retains nothing (no-vault posture). Either experimental mode
    /// raises `experimentalModeNotActivated` before any key work unless
    /// its `experimentalIPClearanceConfirmed` flag is set; mode 4
    /// (physical decay) then raises `hardwareNotSupported`, its key
    /// mechanic being unimplemented.
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
        appendGrantAuditEntry(
            verb: .grantIssued,
            grantID: grant.id,
            custodyToken: grant.custodyMode.signingToken,
            before: .null,
            after: .bitmap(Self.grantActiveBit),
            handle: handle,
            now: now
        )
        Self.verbLog.debug("issueGrant \(id, privacy: .public) custody=\(grant.custodyMode.signingToken, privacy: .public)")
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
        appendGrantAuditEntry(
            verb: .grantRevoked,
            grantID: grantID,
            custodyToken: stored.grant.custodyMode.signingToken,
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
    /// appended entry cannot break the chain. The append uses the same
    /// default-insert idiom as `feedAuditLog`, and the G-Set dedupes a
    /// re-emitted entry by content hash.
    private func appendGrantAuditEntry(
        verb: UnifiedAuditVerb,
        grantID: UUID,
        custodyToken: String,
        before: UnifiedAuditValue,
        after: UnifiedAuditValue,
        handle: EstateHandle,
        now: Date
    ) {
        let hlc = HLC(
            physicalTime: Int64((now.timeIntervalSince1970 * 1000).rounded()),
            logicalCount: 0,
            nodeID: 0
        )
        let entry = UnifiedAuditEntry(
            tier: .locus,
            hlc: hlc,
            verb: verb,
            rowID: grantID,
            fieldPath: custodyToken,
            beforeValue: before,
            afterValue: after,
            originRowID: nil
        )
        auditLogs[handle, default: UnifiedAuditLog()].add(entry)
    }

    /// Drop the grant surface for a handle on close. The vault is
    /// discarded with all its in-memory mode-1 keys.
    func dropGrantSurface(for handle: EstateHandle) {
        storages[handle] = nil
        grantStores[handle] = nil
        scopeVaults[handle] = nil
    }

    /// Load the estate's Ed25519 signing identity from its manifest.
    /// At-rest unwrapping is the identity transform at the kit layer;
    /// see `ManifestKey.ed25519PrivateKeyWrapped`.
    private func signingIdentity(for estate: LocusKit.Estate) async throws -> Curve25519.Signing.PrivateKey {
        let manifest = try await estate.manifest
        guard let raw = manifest.ed25519PrivateKeyWrapped else {
            throw GeniusLocusKitError.invalidManifest(
                key: ManifestKey.ed25519PrivateKeyWrapped.rawValue,
                detail: "estate has no Ed25519 identity key in its manifest"
            )
        }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    }

    /// Gate the experimental custody modes at the verb boundary. Modes 1
    /// and 2 pass through. Either experimental mode without confirmed IP
    /// clearance raises `experimentalModeNotActivated`. With clearance:
    /// custody mode 3 (decay-derived) now passes through — the Lagrange
    /// key mechanics are implemented (ENC-02), so issuance proceeds and
    /// the scope key is reconstructed in `ScopeKeyVault.issue`. Custody
    /// mode 4 (physical SRAM decay) still raises `hardwareNotSupported`:
    /// its key mechanic is not implemented.
    private static func gateCustody(_ mode: CustodyMode) throws {
        switch mode {
        case .mediated, .handedOver:
            return
        case .decayDerived(_, _, _, let confirmed):
            guard confirmed else { throw GrantError.experimentalModeNotActivated }
            // Clearance confirmed: permit issuance. The decay-derived key
            // is reconstructed in the vault's issue path (ENC-02).
            return
        case .physicalDecay(let confirmed):
            guard confirmed else { throw GrantError.experimentalModeNotActivated }
            throw GrantError.hardwareNotSupported
        }
    }
}
