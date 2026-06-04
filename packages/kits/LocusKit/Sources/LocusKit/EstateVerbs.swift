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
        //   bits 0–5   capture_channel (contiguous raw 0…5)
        //   bits 6–11  content_kind    (contiguous raw 0…6)
        //   bits 12–23 feature_flags   (OptionSet bitset, cookbook §2.4)
        // Per DrawerOperational.swift / spec § 5.6.
        // F18 atomic centralization: compose via BitField.writeField rather
        // than open-coded shift placement.
        //
        // DrawerFeatureFlags rawValues are pre-shifted (e.g. `hasLinks` is
        // `1 << 15`), so merging them is a direct bitwise OR masked to the
        // 12-bit feature region 0xFFF000 — the inverse of the
        // `DrawerFeatureFlags(rawValue: extractField(op,12,12) << 12)` decoder.
        let opBitmap = BitField.writeField(
            Int64(frame.kind.rawValue),
            into: BitField.writeField(Int64(frame.channel.rawValue),
                                      into: 0, shift: 0, width: 6),
            shift: 6, width: 6
        ) | (frame.featureFlags.rawValue & 0xFFF000)

        // Adjective bitmap assembly:
        //   bits 0–5  state             (default 0 = .active)
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

    /// File a new standalone **tunnel** (graph edge) into the estate.
    ///
    /// `capture` is legal on exactly two nouns — drawer and tunnel
    /// (AriaLexiconLib `Acceptance.swift`). This overload is the tunnel
    /// entry point; the `CaptureFrame` overload above handles drawers.
    ///
    /// Until this verb landed, a tunnel was only ever born as a side effect
    /// of the drawer supersession cascade (`DrawerStore.addDrawerWithCascade`).
    /// This is the standalone path, and it is deliberately byte-identical to
    /// the row the cascade writes: it builds a `Tunnel` with the same
    /// all-zero bitmap defaults and files it through `DrawerStore.addTunnel`,
    /// which — exactly like the cascade's tunnel write — performs a bare row
    /// insert. One tunnel shape, two entry points (mission VERB-CAP-01,
    /// Known Ambiguity 1).
    ///
    /// ## Genesis-event treatment
    ///
    /// Drawer capture emits a gated genesis `AuditEvent` (`gatedCapture` →
    /// `AuditGate.admit`). The supersession cascade does **not** emit such
    /// an event for the tunnel it files — `addDrawerWithCascade` inserts the
    /// tunnel row directly via `rowStore.insert`, with no audit entry, and
    /// `DrawerStore.addTunnel` does the same. Source is ground truth
    /// (mission "Read First"): to stay byte-identical to what the cascade
    /// produces — the mission's load-bearing requirement, and the explicit
    /// "do not create a divergent tunnel-creation path" gate — standalone
    /// tunnel capture matches the cascade and files via the bare-insert
    /// `addTunnel`. (The mission text's "mirror drawer capture's genesis
    /// event" reflects a doc/source drift: cascade-born tunnels carry no
    /// genesis event, so mirroring drawer capture literally would *create*
    /// the divergence the mission forbids. See the completion report.)
    ///
    /// `Date()` is called once at this public boundary — mirroring the
    /// drawer overload and CLAUDE.md's deterministic-time rule.
    ///
    /// - Parameter frame: tunnel-capture slots. Both endpoints' `wing` and
    ///   `room`, plus `label` and `addedBy`, must be non-empty; throws
    ///   `LocusKitError.invalidContent` otherwise — an edge missing an
    ///   endpoint is not a well-formed tunnel.
    /// - Returns: the stored `Tunnel` with its generated id.
    func capture(_ frame: TunnelCaptureFrame) async throws -> Tunnel {
        guard !frame.sourceWing.isEmpty else {
            throw LocusKitError.invalidContent("sourceWing must not be empty")
        }
        guard !frame.sourceRoom.isEmpty else {
            throw LocusKitError.invalidContent("sourceRoom must not be empty")
        }
        guard !frame.targetWing.isEmpty else {
            throw LocusKitError.invalidContent("targetWing must not be empty")
        }
        guard !frame.targetRoom.isEmpty else {
            throw LocusKitError.invalidContent("targetRoom must not be empty")
        }
        guard !frame.label.isEmpty else {
            throw LocusKitError.invalidContent("label must not be empty")
        }
        guard !frame.addedBy.isEmpty else {
            throw LocusKitError.invalidContent("addedBy must not be empty")
        }

        let now = Date()
        // Encode originClass into bits 6–8 of the tunnel operational bitmap.
        // The decoder (`Tunnel.originClass` in TunnelOperational.swift) uses
        // `BitField.extractField(operationalBitmap, shift:6, width:3)`, so
        // this write is the exact inverse. Default `.userExplicit` (raw 0)
        // produces 0, preserving byte-identical all-zero defaults for
        // existing callers (spec § 5.6 / cookbook §2.4).
        let opBitmap = BitField.writeField(
            Int64(frame.originClass.rawValue),
            into: 0, shift: 6, width: 3
        )
        let tunnel = Tunnel(
            id: UUID().uuidString,
            sourceWing: frame.sourceWing,
            sourceRoom: frame.sourceRoom,
            sourceDrawerId: frame.sourceDrawerId,
            targetWing: frame.targetWing,
            targetRoom: frame.targetRoom,
            targetDrawerId: frame.targetDrawerId,
            label: frame.label,
            kind: frame.kind,
            operationalBitmap: opBitmap,
            addedBy: frame.addedBy,
            filedAt: now
        )
        try await store.addTunnel(tunnel)
        return tunnel
    }

    /// Internal test peek used to verify a captured tunnel after a verb
    /// call. Mirrors `_peekDrawer`. Internal so `@testable import LocusKit`
    /// reaches it; production callers do not.
    internal func _peekTunnel(id: String) async throws -> Tunnel? {
        try await store.getTunnel(id: id)
    }

    /// Internal test helper: non-tombstoned tunnels from a source wing/room
    /// (delegates to `DrawerStore.tunnelsFrom`).
    internal func _tunnelsFrom(wing: String, room: String) async throws -> [Tunnel] {
        try await store.tunnelsFrom(wing: wing, room: room)
    }

    /// Internal test helper: non-tombstoned tunnels to a target wing
    /// (delegates to `DrawerStore.tunnelsTo`).
    internal func _tunnelsTo(wing: String) async throws -> [Tunnel] {
        try await store.tunnelsTo(wing: wing)
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
    /// during reconstruction) collapse to an empty result set here —
    /// `recall` is non-throwing per spec
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

    // MARK: - mutate

    /// Mutate a row along one of its mutation axes per cookbook §7.8.3.
    ///
    /// ## Confirmation axis
    /// `.confirm` moves the confirmation axis (provenance bits 18–23,
    /// cookbook §2.5) to `.userConfirmed` via `DrawerStore.mutateProvenance`.
    ///
    /// ## State axis
    /// All other cases move the row's `State` (adjectiveBitmap bits 0–5)
    /// via `DrawerStore.mutateState`, which validates the transition against
    /// the canonical automaton (cookbook §9.2) and emits one sealed
    /// `AuditEvent` atomically. Illegal transitions throw
    /// `LocusKitError.invalidContent` (gate rejects) or
    /// `LocusKitError.disciplineViolation` (guard rejects). Guards:
    ///   - `.resolve`: requires current state == `.contested`
    ///   - `.accept`: requires trust ≥ `.canonical` (S-1, cookbook §9.5.1)
    ///   - `.revive`: requires current state in Cluster B (isKnewPast)
    ///
    /// ## Adjective axis
    /// `.correctSensitivity` and `.correctTrust` recompose adjectiveBitmap
    /// using `BitField.writeField` at the correct shift/width and persist
    /// via `DrawerStore.mutateAdjective`. Only valid when state==active
    /// (the automaton gate enforces this via RowVerb.mutate).
    ///
    /// `Date()` is called at each case arm (once per logical mutation).
    /// The prior state is read before any store write, so the timestamp
    /// is scoped to the single bitmap operation it audits.
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

        case .reject:
            guard try await store.getDrawer(id: rowID) != nil else {
                throw LocusKitError.drawerNotFound(id: rowID)
            }
            // pending → reject → rejected per automaton §9.2.
            let changedBy = (try? await store.readManifest().ownerIdentifier) ?? ""
            try await store.mutateState(
                drawerId: rowID,
                to: .rejected,
                via: .reject,
                changedBy: changedBy.isEmpty ? "estate" : changedBy,
                reason: payload ?? "rejected via Estate.mutate",
                now: Date()
            )

        case .contest:
            guard try await store.getDrawer(id: rowID) != nil else {
                throw LocusKitError.drawerNotFound(id: rowID)
            }
            // active/pending → contest → contested per automaton §9.2.
            let changedBy = (try? await store.readManifest().ownerIdentifier) ?? ""
            try await store.mutateState(
                drawerId: rowID,
                to: .contested,
                via: .contest,
                changedBy: changedBy.isEmpty ? "estate" : changedBy,
                reason: payload ?? "contested via Estate.mutate",
                now: Date()
            )

        case .resolve:
            guard let drawer = try await store.getDrawer(id: rowID) else {
                throw LocusKitError.drawerNotFound(id: rowID)
            }
            // Guard: resolve is only legal from .contested per automaton
            // (contested → resolveContest → active). Any other prior state
            // throws before touching the store.
            guard drawer.state == .contested else {
                throw LocusKitError.invalidContent(
                    "resolve: only valid from .contested (current: \(drawer.state))"
                )
            }
            let changedBy = (try? await store.readManifest().ownerIdentifier) ?? ""
            try await store.mutateState(
                drawerId: rowID,
                to: .active,
                via: .resolveContest,
                changedBy: changedBy.isEmpty ? "estate" : changedBy,
                reason: payload ?? "resolved via Estate.mutate",
                now: Date()
            )

        case .accept:
            guard let drawer = try await store.getDrawer(id: rowID) else {
                throw LocusKitError.drawerNotFound(id: rowID)
            }
            // S-1 pre-check (cookbook §9.5.1): accepted rows require trust ≥
            // canonical. Raising this guard before the store call produces a
            // clearer diagnostic than the raw invariant message the gate emits.
            guard drawer.trust >= .canonical else {
                throw LocusKitError.invalidContent(
                    "accept: S-1 requires trust ≥ .canonical (current: \(drawer.trust))"
                )
            }
            // active → promote → accepted per automaton §9.2.
            let changedBy = (try? await store.readManifest().ownerIdentifier) ?? ""
            try await store.mutateState(
                drawerId: rowID,
                to: .accepted,
                via: .promote,
                changedBy: changedBy.isEmpty ? "estate" : changedBy,
                reason: payload ?? "accepted via Estate.mutate",
                now: Date()
            )

        case .supersede:
            guard try await store.getDrawer(id: rowID) != nil else {
                throw LocusKitError.drawerNotFound(id: rowID)
            }
            // active/accepted → supersede → superseded per automaton §9.2.
            let changedBy = (try? await store.readManifest().ownerIdentifier) ?? ""
            try await store.mutateState(
                drawerId: rowID,
                to: .superseded,
                via: .supersede,
                changedBy: changedBy.isEmpty ? "estate" : changedBy,
                reason: payload ?? "superseded via Estate.mutate",
                now: Date()
            )

        case .revive:
            guard let drawer = try await store.getDrawer(id: rowID) else {
                throw LocusKitError.drawerNotFound(id: rowID)
            }
            // Guard: revive is only valid from Cluster B (historical) states
            // per ARCH SPEC §6.2. Cluster A (active/pending/contested/accepted)
            // and Cluster C (rejected/tombstoned) are not eligible.
            guard drawer.isKnewPast else {
                throw LocusKitError.invalidContent(
                    "revive: only valid from Cluster B states (decayed, withdrawn, expired, superseded); current: \(drawer.state)"
                )
            }
            // The canonical automaton (cookbook §9.2) supports only
            // decayed → observe → active. Withdrawn, expired, and superseded
            // → active are not in the automaton table; those attempts surface
            // as a gate discipline violation. See LOCUSKIT_SPEC_v0.8.md §revive;
            // a follow-up mission must extend SubstrateLib.RowStateAutomaton
            // to support withdrawn/expired/superseded → active.
            let changedBy = (try? await store.readManifest().ownerIdentifier) ?? ""
            try await store.mutateState(
                drawerId: rowID,
                to: .active,
                via: .observe,
                changedBy: changedBy.isEmpty ? "estate" : changedBy,
                reason: payload ?? "revived via Estate.mutate",
                now: Date()
            )

        case .correctSensitivity(let sensitivity):
            guard let drawer = try await store.getDrawer(id: rowID) else {
                throw LocusKitError.drawerNotFound(id: rowID)
            }
            // Sensitivity lives in adjectiveBitmap bits 6–11 (cookbook §2.3,
            // 6-bit scale-gapped field; raws 0/16/32/48 for the four tiers).
            let newAdjective = BitField.writeField(
                Int64(sensitivity.rawValue),
                into: drawer.adjectiveBitmap,
                shift: 6, width: 6
            )
            let changedBy = (try? await store.readManifest().ownerIdentifier) ?? ""
            try await store.mutateAdjective(
                drawerId: rowID,
                newAdjective: newAdjective,
                changedBy: changedBy.isEmpty ? "estate" : changedBy,
                reason: payload ?? "sensitivity corrected via Estate.mutate",
                now: Date()
            )

        case .correctTrust(let trust):
            guard let drawer = try await store.getDrawer(id: rowID) else {
                throw LocusKitError.drawerNotFound(id: rowID)
            }
            // Trust lives in adjectiveBitmap bits 18–23 (cookbook §2.3,
            // 6-bit gradient field; raws 0–6 for verbatim through ambient).
            let newAdjective = BitField.writeField(
                Int64(trust.rawValue),
                into: drawer.adjectiveBitmap,
                shift: 18, width: 6
            )
            let changedBy = (try? await store.readManifest().ownerIdentifier) ?? ""
            try await store.mutateAdjective(
                drawerId: rowID,
                newAdjective: newAdjective,
                changedBy: changedBy.isEmpty ? "estate" : changedBy,
                reason: payload ?? "trust corrected via Estate.mutate",
                now: Date()
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

    // MARK: - propose

    /// Create a proposal targeting a row in the estate.
    ///
    /// Validates that the target drawer exists, assembles the `operationalBitmap`
    /// from the supplied `ProposeFrame.kind` (bits 0–5) and a `.drawer` target
    /// object type (bits 6–11), sets `adjectiveBitmap` state to `.pending`,
    /// derives `candidateState` and `latticeAnchor` from the target drawer, then
    /// calls `DrawerStore.addProposal`. Per cookbook §10.7.
    ///
    /// - Parameters:
    ///   - frame: propose slots. `frame.target` must be non-empty and identify an
    ///     existing drawer; throws `LocusKitError.drawerNotFound` otherwise.
    ///   - now: deterministic write timestamp (passed from the outermost public
    ///     boundary per CLAUDE.md deterministic-clock rule).
    /// - Returns: the stored `Proposal` with its generated id and bitmaps set.
    /// - Throws: `LocusKitError.drawerNotFound` if `frame.target` does not exist.
    public func propose(_ frame: ProposeFrame, now: Date) async throws -> Proposal {
        guard !frame.target.isEmpty else {
            throw LocusKitError.invalidContent("propose target must not be empty")
        }
        guard let targetDrawer = try await store.getDrawer(id: frame.target) else {
            throw LocusKitError.drawerNotFound(id: frame.target)
        }

        // Operational bitmap: ProposalKind at bits 0–5, ProposalTargetObjectType
        // (.drawer = 0) at bits 6–11. The remaining axes default to 0 (confirmation
        // .human, generated-by .dreamingDaemon, confidence .null) — the propose verb
        // does not yet carry those slots (a later sub-mission wires them through the
        // Brain layer ProposalFrame).
        let opBitmap = BitField.writeField(
            Int64(ProposalTargetObjectType.drawer.rawValue),
            into: BitField.writeField(Int64(frame.kind.rawValue), into: 0, shift: 0, width: 6),
            shift: 6,
            width: 6
        )

        // Adjective bitmap: set state to .pending (bits 0–5, raw value 1).
        let adjBitmap = BitField.writeField(
            Int64(State.pending.rawValue),
            into: 0,
            shift: 0,
            width: 6
        )

        // candidateState derives from the target drawer's current adjectiveBitmap —
        // the accept path will apply this to the target if confirmed.
        let candidateState = targetDrawer.adjectiveBitmap

        // latticeAnchor is assembled from the target drawer's four anchor fields.
        // Drawer stores the fields individually; LatticeAnchor is the composite type.
        let latticeAnchor = LatticeAnchor(
            udcCode: targetDrawer.udcCode,
            udcFacets: targetDrawer.udcFacets,
            wikidataQID: targetDrawer.wikidataQID,
            wikidataQidsSecondary: targetDrawer.wikidataQidsSecondary
        )

        let proposal = Proposal(
            targetRowID: frame.target,
            justification: frame.justification,
            candidateState: candidateState,
            latticeAnchor: latticeAnchor,
            adjectiveBitmap: adjBitmap,
            operationalBitmap: opBitmap,
            filedAt: now
        )
        try await store.addProposal(proposal)
        return proposal
    }

    // MARK: - associate

    /// Create an association between two rows in the estate.
    ///
    /// Validates both endpoints, looks up both drawers, derives spatial
    /// coordinates and `latticeAnchor` from endpoint A (the source), sets
    /// state to `.active` (associations are born active, not pending), and
    /// calls `DrawerStore.addAssociation`. Per cookbook §10.8.
    ///
    /// - Parameters:
    ///   - frame: associate slots. `frame.a` and `frame.b` must be non-empty
    ///     and identify existing drawers; throws `LocusKitError.drawerNotFound`
    ///     on any missing endpoint.
    ///   - now: deterministic write timestamp.
    /// - Returns: the stored `Association` with its generated id and bitmaps set.
    public func associate(_ frame: AssociateFrame, now: Date) async throws -> Association {
        guard !frame.a.isEmpty else {
            throw LocusKitError.invalidContent("associate endpoint a must not be empty")
        }
        guard !frame.b.isEmpty else {
            throw LocusKitError.invalidContent("associate endpoint b must not be empty")
        }
        guard let drawerA = try await store.getDrawer(id: frame.a) else {
            throw LocusKitError.drawerNotFound(id: frame.a)
        }
        guard let drawerB = try await store.getDrawer(id: frame.b) else {
            throw LocusKitError.drawerNotFound(id: frame.b)
        }

        // Association label derives from endpoint A's room and endpoint B's room —
        // a human-readable summary of what is being connected.
        let label = "\(drawerA.room)→\(drawerB.room)"

        // Adjective bitmap: state .active is the zero baseline (raw value 0),
        // so adjectiveBitmap = 0. Associations are born active, not pending.
        // (Cookbook §10.8: "associations are born active.")

        // LatticeAnchor derives from endpoint A (the source drawer), which is
        // the conventional anchor point for a directed association.
        let latticeAnchor = LatticeAnchor(
            udcCode: drawerA.udcCode,
            udcFacets: drawerA.udcFacets,
            wikidataQID: drawerA.wikidataQID,
            wikidataQidsSecondary: drawerA.wikidataQidsSecondary
        )

        let association = Association(
            id: UUID().uuidString,
            sourceWing: drawerA.wing,
            sourceRoom: drawerA.room,
            sourceDrawerId: drawerA.id,
            targetWing: drawerB.wing,
            targetRoom: drawerB.room,
            targetDrawerId: drawerB.id,
            label: label,
            latticeAnchor: latticeAnchor,
            addedBy: "associate",
            filedAt: now
        )
        try await store.addAssociation(association)
        return association
    }

    // MARK: - learn

    /// Bring an external reference into the estate by handle.
    ///
    /// Constructs a `LearnedReference` with `sourceCatalogID` set to the frame's
    /// handle (v1 placeholder — `SourceCatalogEntry` is spec-only, not yet
    /// implemented), sentinel `latticeAnchor` ("0" UDC code per Known Ambiguity),
    /// and `addedBy = "learn"`. Per cookbook §10.9 / spec § 7.8.2.
    ///
    /// - Parameters:
    ///   - frame: learn slots. `frame.handle` must be non-empty.
    ///   - now: deterministic write timestamp.
    /// - Returns: the stored `LearnedReference` with its generated id.
    /// - Throws: `LocusKitError.invalidContent` if `frame.handle` is empty.
    public func learn(_ frame: LearnFrame, now: Date) async throws -> LearnedReference {
        guard !frame.handle.isEmpty else {
            throw LocusKitError.invalidContent("learn handle must not be empty")
        }

        // Trust .canonical is the adjectiveBitmap encoding for a learned
        // reference — grounding-driven content carries canonical trust.
        // Cookbook §2.3: trust axis at bits 18–23 of adjectiveBitmap.
        // Trust.canonical raw value = 3.
        let adjBitmap = BitField.writeField(
            Int64(Trust.canonical.rawValue),
            into: 0,
            shift: 18,
            width: 6
        )

        // Sentinel lattice anchor ("0" UDC code) per Known Ambiguity —
        // SourceCatalogEntry is spec-only; the enrichment daemon will
        // resolve the real anchor when it runs.
        let ref = LearnedReference(
            id: UUID().uuidString,
            sourceCatalogID: frame.handle,   // v1 placeholder — no SourceCatalogEntry yet
            handle: frame.handle,
            latticeAnchor: LatticeAnchor(udcCode: "0"),
            adjectiveBitmap: adjBitmap,
            addedBy: "learn",
            filedAt: now
        )
        try await store.addLearnedReference(ref)
        return ref
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
