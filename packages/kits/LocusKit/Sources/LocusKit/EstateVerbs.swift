import Foundation
import SubstrateML
import SubstrateKernel
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
import SubstrateLib
import SubstrateTypes

/// Estate verbs — `capture`, `recall`, `mutate`, `withdraw`,
/// `expunge`, `reanchor`, `learn`. Per spec § 7.8.1.
///
/// `capture`, `withdraw`, and `recall` are implemented. `recall`
/// returns a paged `RecallStream` over non-tombstoned drawers with
/// `frame.limit` driving page size and `frame.hydrationLevel`
/// controlling content stripping (spec § 7.8.4 / § 7.3 / § 7.4);
/// `filterChain`, `ordering`, and `asOf` are applied by
/// `BitmapEvaluator.evaluate` per spec § 7.9 (default insertion,
/// bitmap-tier predicates, structured-tier filters, content-tier
/// filters, ordering, historical reconstruction).
/// `expunge` is implemented (cookbook §10.5, via
/// `DrawerStore.expungeGated`). `mutate`, `reanchor`, and `learn`
/// throw `LocusKitError.invalidContent` until their owning mission
/// ships them.
///
/// Declared as `extension Estate` rather than inline in `Estate.swift`
/// to keep the mission-13 lifecycle surface stable while adding the
/// verb surface in mission 14 — a deliberate splitting of blast
/// radius. The extension reaches `Estate.store` (declared `internal`
/// in Estate.swift specifically for this extension's call sites).
public extension Estate {

    // MARK: - capture

    /// File a new drawer into the estate.
    ///
    /// Translates `CaptureFrame` slots into a storage `Drawer` and
    /// writes it via `DrawerStore.addDrawer`. If `frame.lineageID` is
    /// non-nil and an active predecessor with that lineage exists,
    /// the supersession cascade fires atomically (spec § 6.2 / § 6.3)
    /// inside `DrawerStore.addDrawerWithCascade`: the predecessor's
    /// state flips to `.superseded` through `mutateState` (which
    /// appends one sealed `AuditEvent`), and a `supersedes` tunnel is
    /// created — all inside one `.serializable` transaction. If
    /// `frame.lineageID` is nil, a
    /// fresh `UUID()` is stamped so each drawer is its own lineage
    /// per § 5.10.
    ///
    /// Per spec § 7.8.1. `Date()` is called once at this boundary —
    /// the outermost public entry point — and passed downward to
    /// internal `DrawerStore` methods that accept a `now:` parameter
    /// (consistent with CLAUDE.md's deterministic-time rule).
    ///
    /// - Parameter frame: capture slots. `frame.content`, `frame.room`,
    ///   `frame.latticeAnchor.udcCode`, `frame.addedBy`, and
    ///   `frame.embeddingModelID` must all be non-empty; throws
    ///   `LocusKitError.invalidContent` if any are empty. The UDC
    ///   requirement is invariant I-5.
    /// - Returns: the stored `Drawer` with its generated id and all
    ///   bitmap fields populated.
    func capture(_ frame: CaptureFrame) async throws -> Drawer {
        guard !frame.content.isEmpty else {
            throw LocusKitError.invalidContent("content must not be empty")
        }
        guard !frame.room.isEmpty else {
            throw LocusKitError.invalidContent("room must not be empty")
        }
        guard !frame.latticeAnchor.udcCode.isEmpty else {
            throw LocusKitError.invalidContent(
                "latticeAnchor.udcCode must not be empty (spec I-5)"
            )
        }
        guard !frame.addedBy.isEmpty else {
            throw LocusKitError.invalidContent("addedBy must not be empty")
        }
        guard !frame.embeddingModelID.isEmpty else {
            throw LocusKitError.invalidContent("embeddingModelID must not be empty")
        }

        // Operational bitmap assembly:
        //   bits 0–3  capture_channel (contiguous raw 0…4)
        //   bits 4–7  content_kind    (contiguous raw 0…5)
        // Per DrawerOperational.swift / spec § 5.6.
        // F18 atomic centralization: compose via BitField.writeField rather
        // than open-coded `<< 6` placement.
        let opBitmap = BitField.writeField(
            Int64(frame.kind.rawValue),
            into: BitField.writeField(Int64(frame.channel.rawValue),
                                      into: 0, shift: 0, width: 6),
            shift: 6, width: 6
        )

        // Adjective bitmap assembly:
        //   bits 0–3  state             (default 0 = .active)
        //   bits 6–11  adjective_sensitivity (scale-gapped raw 0/16/32/48)
        //   bits 12–17 exportability     (default 0 = .private_)
        //   bits 18–23 trust              (default 0 = .verbatim)
        // The sensitivity raw values are scale-gapped (0/16/32/48), so they
        // are shifted left 6 to land in the bits-6–11 window. Per
        // Adjectives.swift / cookbook §2.3.
        // F18 atomic centralization: cookbook §2.3 sensitivity at bits 6–11.
        let adjBitmap = BitField.writeField(
            Int64(frame.sensitivity.rawValue),
            into: 0, shift: 6, width: 6)

        // Provenance bitmap assembly (cookbook §2.5 layout):
        //   bits 0–5   sourceType            (SourceType raw)
        //   bits 6–11  channel               (provenance Channel raw)
        //   bits 30–35 sensitivity           (provenance Sensitivity raw)
        // Other provenance slots (captureChannel mirror, confirmation,
        // confidence, enrichmentStatus) are populated by downstream
        // daemons or held at zero by default.
        let provenanceBitmap = BitField.writeField(
            Int64(frame.provenanceSensitivity.rawValue),
            into: BitField.writeField(
                Int64(frame.provenanceChannel.rawValue),
                into: BitField.writeField(
                    Int64(frame.sourceType.rawValue),
                    into: 0, shift: 0, width: 6),
                shift: 6, width: 6),
            shift: 30, width: 6
        )

        let now = Date()
        let drawer = Drawer(
            content: frame.content,
            wing: try await defaultWing(),
            room: frame.room,
            addedBy: frame.addedBy,
            filedAt: now,
            // Two-clock ingest (ING-01): a caller doing bulk historical
            // ingestion supplies frame.eventTime (the original authorship
            // date); streaming capture leaves it nil, so event time and
            // ingest time coincide at `now`.
            eventTime: frame.eventTime ?? now,
            embeddingModelID: frame.embeddingModelID,
            provenance: provenanceBitmap,
            adjectiveBitmap: adjBitmap,
            operationalBitmap: opBitmap,
            lineageID: frame.lineageID ?? UUID(),
            udcCode: frame.latticeAnchor.udcCode,
            udcFacets: frame.latticeAnchor.udcFacets,
            wikidataQID: frame.latticeAnchor.wikidataQID,
            wikidataQidsSecondary: frame.latticeAnchor.wikidataQidsSecondary
        )
        try await store.addDrawer(drawer, now: now)
        // Maintain the per-container OR aggregate (spec section 11.5)
        // so recall pruning stays current. The stored bitmaps equal
        // the drawer's fields, addDrawer does not rewrite them.
        try await containerFP.orIn(
            wing: drawer.wing, room: drawer.room,
            adjective: drawer.adjectiveBitmap,
            operational: drawer.operationalBitmap,
            provenance: drawer.provenance,
            now: now)
        return drawer
    }

    // MARK: - recall

    /// Recall rows matching the filter chain. Per spec § 7.8.1 / § 7.9.
    ///
    /// Fetches the non-tombstoned drawer set (`tombstonedAt == nil`)
    /// from the substrate and hands it to `BitmapEvaluator.evaluate`,
    /// which applies default-filter insertion (§ 7.9.5), bitmap-tier
    /// predicates (§ 7.9.2 / § 7.9.3), structured-tier filters
    /// (§ 7.9.4 step 3), content-tier filters (§ 7.9.4 step 4),
    /// ordering, and historical reconstruction via
    /// `AuditLogFold.projectStateAt` (cookbook § 5.3) when
    /// `frame.asOf` is set; state is keyed on HLC.
    ///
    /// The evaluator's throwable failure modes (substrate errors
    /// during reconstruction; `.nearVector` without VectorKit) collapse
    /// to an empty result set here — `recall` is non-throwing per spec
    /// § 7.8.1 because the stream itself is the failure boundary
    /// (an empty page-1-is-last sequence is the documented signal that
    /// no rows matched, regardless of whether the cause was an empty
    /// corpus or a substrate fault). Callers that need to distinguish
    /// the two go through the substrate directly. Fingerprint pruning
    /// (§ 7.9.4 step 1) runs first: when the chain carries a prunable
    /// filter, `liveRows` drops wings and rooms whose OR fingerprint
    /// cannot satisfy it and fetches rows only from survivors.
    func recall(_ frame: RecallFrame) async -> RecallStream {
        // `now` is stamped once at the verb boundary per CLAUDE.md's
        // deterministic-engine rule. The trace rows record recalledAt
        // so the reward sweep can group rows by recall session.
        let now = Date()
        let live = (try? await liveRows(for: frame)) ?? []
        let filtered = (try? await BitmapEvaluator.evaluate(
            frame: frame, drawers: live, store: store
        )) ?? []
        // Record one RecallTraceItem per returned row (used = false).
        // This is the "later two-source reward" hook from
        // NEURONKIT_SPEC §3.1: the reward path later sets used = true
        // for rows the caller acted on, enabling Bradley-Terry to
        // distinguish acted-on rows from ignored ones (cookbook §8.12).
        // Failures are silenced (try?) so a storage fault does not
        // break the caller's recall result.
        for drawer in filtered {
            let traceItem = RecallTraceItem(
                target: drawer.id,
                recalledAt: now,
                score: nil,   // ordered-by-capture-time recalls carry no score
                operationalBitmap: 0)
            try? await store.insertRecallTrace(traceItem)
        }
        let pageSize = frame.limit ?? RecallStream.defaultPageSize
        return RecallStream(
            rows: filtered,
            pageSize: pageSize,
            hydrationLevel: frame.hydrationLevel
        )
    }

    /// The live (non-tombstoned) rows the per-row evaluator must
    /// consider. This is where fingerprint pruning (§ 7.9.4 step 1)
    /// happens.
    ///
    /// When the chain carries no prunable filter, no container can be
    /// excluded, so a single corpus scan is cheaper than walking
    /// containers. When it does, walk the per-container OR fingerprints:
    /// a wing-level test can drop a whole wing in one comparison, and a
    /// room-level test drops a room, before any of their rows are
    /// fetched. Rows come only from surviving rooms. `drawersIn`
    /// excludes tombstoned rows, so the result is already live.
    ///
    /// Soundness rests on the maintenance contract: the fingerprint set
    /// covers every active container (backfill on open, OR-in per
    /// capture) and over-approximates each container's bits, so a
    /// survivor is never wrongly dropped. An absent wing fingerprint is
    /// treated as surviving, never as empty.
    private func liveRows(for frame: RecallFrame) async throws -> [Drawer] {
        guard BitmapEvaluator.chainHasPrunableFilter(frame.filterChain) else {
            return (try await store.allDrawers()).filter { $0.tombstonedAt == nil }
        }
        let entries = try await containerFP.roomLevelEntries()
        var wingSurvives: [String: Bool] = [:]
        var rows: [Drawer] = []
        for entry in entries {
            let survivesWing: Bool
            if let cached = wingSurvives[entry.wing] {
                survivesWing = cached
            } else {
                let wingFP = try await containerFP.get(
                    wing: entry.wing,
                    room: ContainerFingerprintStore.wingRollupRoom)
                survivesWing = wingFP.map {
                    BitmapEvaluator.containerSurvives(chain: frame.filterChain, fingerprint: $0)
                } ?? true
                wingSurvives[entry.wing] = survivesWing
            }
            guard survivesWing else { continue }
            guard BitmapEvaluator.containerSurvives(
                chain: frame.filterChain, fingerprint: entry.fingerprint) else { continue }
            rows.append(contentsOf: try await store.drawersIn(wing: entry.wing, room: entry.room))
        }
        return rows
    }

    // MARK: - withdraw

    /// Withdraw a drawer — move its `State` axis to `.withdrawn`.
    ///
    /// Composes the new adjective bitmap by clearing bits 0–3 with
    /// `& ~0xF` and OR-ing in `State.withdrawn.rawValue`, preserving
    /// the upper adjective axes (sensitivity / exportability / trust).
    /// `DrawerStore.mutateState(.withdrawn, via: .retract)` updates
    /// the projection and appends one sealed `AuditEvent` atomically
    /// — there is no observable window in which the state flip
    /// exists without its audit event.
    ///
    /// - Parameters:
    ///   - rowID: the drawer's `id`.
    ///   - reason: optional free-text justification, written verbatim
    ///     into the audit row's `reason` column.
    func withdraw(rowID: RowID, reason: String? = nil) async throws {
        guard let drawer = try await store.getDrawer(id: rowID) else {
            throw LocusKitError.drawerNotFound(id: rowID)
        }
        // Withdrawal is a STATE transition (active/pending/contested/…
        // → withdrawn via `retract`), so it MUST go through mutateState,
        // which validates the transition against the automaton. The
        // earlier path wrote the state bits through mutateAdjective,
        // bypassing that validation — the write gate now forbids moving
        // state through a field edit, so this is the correct route.
        let changedBy = (try? await store.readManifest().ownerIdentifier) ?? ""
        try await store.mutateState(
            drawerId: rowID,
            to: .withdrawn,
            via: .retract,
            changedBy: changedBy.isEmpty ? "estate" : changedBy,
            reason: reason ?? "withdrawn via Estate.withdraw",
            now: Date()
        )
        _ = drawer
    }

    // MARK: - expunge

    /// Expunge a row (hard remove). Per cookbook §10.5: tombstones
    /// the row, zeroes its content blob, sets the
    /// `dreaming_recalc_required` worklist marker (adjective bit 26)
    /// synchronously, leaves aggregates untouched (§9.5.1: already
    /// de-identified statistical roll-ups), and emits a sealed audit
    /// event so the fact-of-expunge is preserved (v0.35 I-6).
    ///
    /// Cookbook preconditions: "None beyond row existing." The
    /// `confirmation: Bool` parameter is a caller-supplied safety
    /// check; expunge is destructive (the verbatim content is gone
    /// after this call returns) so the API requires an explicit
    /// `true` to proceed. Estate-level toggles (the GDPR-style
    /// per-estate "expunge_allowed" one-way ratchet from F17 second
    /// pass item 2) are not in cookbook today and not enforced here;
    /// they layer on top of this primitive when ratified.
    ///
    /// The cross-kit RAG vector delete (§10.5 second postcondition)
    /// is GLK's orchestration responsibility (F17 second pass item 4)
    /// and is not invoked from here; LocusKit's expunge is the
    /// storage-layer half. Until GLK orchestration lands, callers
    /// who maintain a separate vector index must delete the
    /// corresponding vector themselves.
    ///
    /// Throws:
    ///   - `LocusKitError.invalidContent("expunge requires confirmation")`
    ///     if `confirmation == false`
    ///   - `LocusKitError.drawerNotFound(id:)` if the row does not exist
    ///   - `LocusKitError.invalidContent("expunge rejected by gate: ...")`
    ///     if the prior state cannot transition via `.tombstone`
    ///     (notably: accepted rows, per S-3)
    func expunge(
        rowID: RowID,
        reason: String,
        confirmation: Bool
    ) async throws {
        guard confirmation else {
            throw LocusKitError.invalidContent(
                "expunge requires confirmation: true (destructive op)"
            )
        }
        guard try await store.getDrawer(id: rowID) != nil else {
            throw LocusKitError.drawerNotFound(id: rowID)
        }
        let changedBy = (try? await store.readManifest().ownerIdentifier) ?? ""
        try await store.expungeGated(
            drawerId: rowID,
            changedBy: changedBy.isEmpty ? "estate" : changedBy,
            reason: reason.isEmpty ? "expunged via Estate.expunge" : reason,
            now: Date()
        )
    }

    // MARK: - Stubs (implemented in later missions)

    /// Mutate a row along one of its mutation axes.
    ///
    /// `.confirm` moves the confirmation axis (provenance bits 18–23,
    /// cookbook §2.5) to `.userConfirmed`: read the drawer, recompose the
    /// provenance bitmap with the confirmation field set via
    /// `BitField.writeField` (every other provenance axis — sourceType,
    /// channel, captureChannel, confidence, sensitivityAtCapture,
    /// enrichmentStatus — is preserved untouched), and persist through
    /// `DrawerStore.mutateProvenance`, which routes the gated column write
    /// and appends one sealed `AuditEvent` atomically.
    ///
    /// The state-axis kinds (`.reject` / `.contest` / `.resolve` /
    /// `.supersede` / `.revive`) move the row's *state*, not its
    /// confirmation, so they belong on the `mutateState` automaton path;
    /// that path is not yet wired here, so they throw `.invalidContent`
    /// carrying the "not yet implemented" marker GLK's surface remaps to
    /// `VerbError.notSupportedByEstate`.
    ///
    /// `now` is taken as `Date()` here, matching `withdraw`; the
    /// confirmation transition itself is deterministic (a pure function of
    /// the prior bitmap), only the audit row's timestamp is clock-derived.
    func mutate(
        rowID: RowID,
        kind: MutationKind,
        payload: String? = nil
    ) async throws {
        switch kind {
        case .confirm:
            guard let drawer = try await store.getDrawer(id: rowID) else {
                throw LocusKitError.drawerNotFound(id: rowID)
            }
            // Confirmation lives in provenance bits 18–23; writeField clears
            // that field and ORs in userConfirmed, leaving the other
            // provenance axes intact.
            let newProvenance = BitField.writeField(
                Int64(Confirmation.userConfirmed.rawValue),
                into: drawer.provenance,
                shift: 18, width: 6
            )
            let changedBy = (try? await store.readManifest().ownerIdentifier) ?? ""
            try await store.mutateProvenance(
                drawerId: rowID,
                newProvenance: newProvenance,
                changedBy: changedBy.isEmpty ? "estate" : changedBy,
                reason: "confirmed via Estate.mutate",
                now: Date()
            )
        default:
            // State-axis mutations are not yet wired; the "not yet
            // implemented" marker is the sentinel the GLK surface keys on to
            // raise notSupportedByEstate rather than underlyingEstateFailure.
            throw LocusKitError.invalidContent(
                "mutate: state-axis kinds not yet implemented (only confirm)"
            )
        }
    }

    /// Reanchor a drawer to a different room and/or lattice position.
    ///
    /// Moves the row's placement: `toRoom` changes the `room` column;
    /// `toLattice` updates `udcCode`, `udcFacets`, `wikidataQID`, and
    /// `wikidataQidsSecondary`. At least one must be supplied (belt-and-
    /// suspenders guard; the primary empty check is GLK's `VerbError.emptyReanchor`
    /// boundary before dispatch). An absent row throws `drawerNotFound`.
    ///
    /// The placement change is persisted via `DrawerStore.reanchorGated`,
    /// which reads the current row in a transaction, admits a `.mutate`
    /// (active→active self-loop) event through `AuditGate.admit` carrying
    /// the anchor delta in `priorLatticeAnchor` / `afterLatticeAnchor`, and
    /// writes the updated columns + the sealed audit event atomically.
    /// The row's three bitmaps (adjective, operational, provenance) are left
    /// unchanged.
    ///
    /// - Parameters:
    ///   - rowID: the drawer's `id`.
    ///   - toRoom: optional new room name.
    ///   - toLattice: optional new lattice anchor.
    func reanchor(
        rowID: RowID,
        toRoom: RoomID? = nil,
        toLattice: LatticeAnchor? = nil
    ) async throws {
        guard toRoom != nil || toLattice != nil else {
            throw LocusKitError.invalidContent(
                "reanchor requires toRoom or toLattice"
            )
        }
        guard try await store.getDrawer(id: rowID) != nil else {
            throw LocusKitError.drawerNotFound(id: rowID)
        }
        let changedBy = (try? await store.readManifest().ownerIdentifier) ?? ""
        try await store.reanchorGated(
            drawerId: rowID,
            toRoom: toRoom,
            toLattice: toLattice,
            changedBy: changedBy.isEmpty ? "estate" : changedBy,
            reason: "reanchored via Estate.reanchor",
            now: Date()
        )
    }

    /// Register a learned reference. Implemented in LOCI_V035_19.
    func learn(_ frame: LearnFrame) async throws {
        throw LocusKitError.invalidContent(
            "learn not yet implemented — see LOCI_V035_19"
        )
    }

    // MARK: - Internals

    /// Internal Sendable peek used by tests to verify drawer state
    /// after a verb call. `DrawerStore` is not `Sendable`, so the
    /// store reference itself cannot exit the actor; the returned
    /// `Drawer?` is `Sendable` and crosses the boundary safely.
    /// Not part of the public API — declared `internal` so that
    /// `@testable import LocusKit` reaches it while production
    /// callers do not.
    internal func _peekDrawer(id: RowID) async throws -> Drawer? {
        try await store.getDrawer(id: id)
    }

    /// Test-only helper. Overwrites a drawer's `provenance` bitmap via
    /// `DrawerStore.mutateProvenance`, writing an audit row for the
    /// change. Tests use this to stage provenance combinations
    /// (`.userConfirmed`, `.automatedConfirmedOnly`, etc.) that `capture`
    /// does not yet expose through `CaptureFrame`. Internal so
    /// `@testable import LocusKit` reaches it; production callers do not.
    internal func _setProvenance(rowID: RowID, newProvenance: Int64) async throws {
        try await store.mutateProvenance(
            drawerId: rowID,
            newProvenance: newProvenance,
            changedBy: "test-helper",
            reason: "test-fixture",
            now: Date()
        )
    }

    /// Test-only helper. Overwrites a drawer's `adjectiveBitmap` via
    /// `DrawerStore.mutateAdjective`, writing an audit row. Lets tests
    /// stage trust / sensitivity combinations not exposed through
    /// `CaptureFrame`. Internal so `@testable import LocusKit` reaches
    /// it; production callers do not.
    internal func _setAdjective(rowID: RowID, newAdjective: Int64) async throws {
        try await store.mutateAdjective(
            drawerId: rowID,
            newAdjective: newAdjective,
            changedBy: "test-helper",
            reason: "test-fixture",
            now: Date()
        )
    }

    /// Default wing name derived from the manifest's owner identifier.
    /// Used by `capture` when the caller does not pass an explicit
    /// wing (which is currently always — `CaptureFrame` has no wing
    /// slot at the MVP milestone; rooms partition within the
    /// owner-default wing).
    ///
    /// Throws if the manifest cannot be read; the failure surfaces as
    /// a substrate error rather than a silent default.
    private func defaultWing() async throws -> String {
        let owner = try await store.readManifest().ownerIdentifier
        return "wing_\(owner.isEmpty ? "default" : owner)"
    }
}
