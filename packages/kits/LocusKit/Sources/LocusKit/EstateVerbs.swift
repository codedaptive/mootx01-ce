import Foundation
import IntellectusLib
import SubstrateML
import SubstrateKernel
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
import SubstrateLib
import SubstrateTypes

/// Estate verbs — `capture`, `recall`, `mutate`, `withdraw`,
/// `expunge`, `reanchor`, `learn`. Per spec § 7.8.1.
///
/// All seven verbs are implemented. `recall`
/// returns a paged `RecallStream` over non-tombstoned drawers with
/// `frame.limit` driving page size and `frame.hydrationLevel`
/// controlling content stripping (spec § 7.8.4 / § 7.3 / § 7.4);
/// `filterChain`, `ordering`, and `asOf` are applied by
/// `BitmapEvaluator.evaluate` per spec § 7.9 (default insertion,
/// bitmap-tier predicates, structured-tier filters, content-tier
/// filters, ordering, historical reconstruction).
/// `expunge` is implemented (cookbook §10.5, via
/// `DrawerStore.expungeGated`). `mutate` and `reanchor` are live
/// mutation verbs; `learn` derives a `LearnedReference` from a
/// `SourceCatalogEntry` (spec § 7.8.1).
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
        //   bits 0–5   state             (default 0 = .active)
        //   bits 6–11  adjective_sensitivity (scale-gapped raw 0/16/32/48)
        //   bits 12–17 exportability     (scale-gapped raw 0 = .private_, 32 = .public_)
        //   bits 18–23 trust             (default 0 = .verbatim)
        // Both sensitivity and exportability use scale-gapped raw values; each
        // is written into its 6-bit window via BitField.writeField, which masks
        // the value to the window width before placing it. Per Adjectives.swift /
        // cookbook §2.3.
        let adjBitmap = BitField.writeField(
            Int64(frame.exportability.rawValue),
            into: BitField.writeField(
                Int64(frame.sensitivity.rawValue),
                into: 0, shift: 6, width: 6),
            shift: 12, width: 6)

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
        // Notify the topology worker that a drawer was captured in this estate.
        // NounType.drawer.rawValue = 0 (wire-stable per SubstrateTypes/NounType.swift).
        Intellectus.report(.event(
            kind: .capture,
            nounType: Int(NounType.drawer.rawValue),
            rowID: drawer.id,
            estate: estateUUID.uuidString,
            ts: now.timeIntervalSince1970
        ))
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
        // Notify the topology worker that a tunnel was captured in this estate.
        // NounType.tunnel.rawValue = 1 (wire-stable per SubstrateTypes/NounType.swift).
        Intellectus.report(.event(
            kind: .capture,
            nounType: Int(NounType.tunnel.rawValue),
            rowID: tunnel.id,
            estate: estateUUID.uuidString,
            ts: now.timeIntervalSince1970
        ))
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

    /// Maximum candidate rows materialised from the estate per recall call.
    ///
    /// The GLK RecallDirector drains up to `frontierK = min(max(limit*4,64),256)`
    /// rows from the stream before scoring/MMR. Capping the scan at 256 means
    /// the first 256 rows in filedAt order are produced — the identical drained
    /// set the director gets today from a full-estate scan, since it takes
    /// the first N from that same ordered sequence. This converts the locus
    /// lane from O(N_estate) to O(256) both in storage I/O and in trace writes.
    static let recallCandidateCap = 256

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
    /// The evaluator's throwable failure modes (substrate errors during
    /// reconstruction), and every internal read in `liveRows`, are SURFACED
    /// as a named stage on `RecallStream.degradedStages` rather than
    /// silently collapsing to an empty result. `recall` is non-throwing per
    /// spec § 7.8.1, so the stream — not a thrown error — is the failure
    /// boundary: a GENUINE-EMPTY estate emits an empty stream with NO
    /// degraded stage, while a FAILED internal read emits an empty stream
    /// WITH the failing stage named, so the two are distinguishable.
    /// Fingerprint pruning
    /// (§ 7.9.4 step 1) runs first: when the chain carries a prunable
    /// filter, `liveRows` drops wings and rooms whose OR fingerprint
    /// cannot satisfy it and fetches rows only from survivors.
    ///
    /// ## Performance: four O(N) → O(256) / O(limit) fixes applied here
    ///
    /// 1. **Bounded scan** — `liveRows` caps at `max(limit, recallCandidateCap)`
    ///    rows. Director callers (limit ~20) keep the 256 bound; explicit
    ///    large-limit callers (e.g. VaultBridge limit 10_000_000) get a true
    ///    full scan so no drawer is silently truncated.
    ///
    /// 2. **No-blob load** — `liveRows` loads at `.structured` (content blob
    ///    omitted) when the filter chain has no content-tier predicate. Content
    ///    blobs are not needed for bitmap or structured-tier evaluation. For
    ///    `.full` callers the matched IDs are re-fetched with the blob; for
    ///    `.structured` and `.bitmapOnly` callers the no-blob rows are returned
    ///    directly (`.structured` callers receive `content = ""` per spec § 7.3
    ///    which defines structured as "bitmap columns + structured-row fields
    ///    only, no blob reads"; `.bitmapOnly` rows also carry `content = ""`).
    ///
    /// 3. **Opt-in trace writes** — `frame.traceLimit` controls whether trace
    ///    rows are written at all. nil (the default) writes ZERO trace rows,
    ///    eliminating write amplification for internal and VaultBridge-style
    ///    scans. When set, at most `min(traceLimit, filtered.count)` rows are
    ///    traced — the reward sweep cares only about what was returned to the
    ///    caller. One batch insert; never one INSERT per row.
    func recall(_ frame: RecallFrame) async -> RecallStream {
        // `now` is stamped once at the verb boundary per CLAUDE.md's
        // deterministic-engine rule. The trace rows record recalledAt
        // so the reward sweep can group rows by recall session.
        let now = Date()

        // Internal-read failures are SURFACED, not silently swallowed.
        // A failed read produces an empty `rows` for a reason OTHER than
        // "no matches"; recording the named stage here lets the caller
        // (GLK RecallDirector) tell a FAILED recall from a GENUINE-EMPTY
        // estate (spec § 7.8.1). `recall` stays non-throwing: the channel
        // is the stream's `degradedStages`, not a thrown error.
        //
        // Consume the single-use fault seam once at the top so a forced
        // fault drives exactly the targeted read on this call and is
        // cleared for the next.
        let forcedRead = _testForceInternalReadError
        _testForceInternalReadError = nil

        var degradedStages: [String] = []
        let live: [Drawer]
        do {
            live = try await liveRows(for: frame, forcedFault: forcedRead)
        } catch let err as RecallInternalReadFailure {
            // A named internal read inside liveRows failed. Surface its
            // stage; the recall continues with an empty candidate set so
            // the caller still gets a (degraded) stream rather than a throw.
            degradedStages.append(err.stage)
            live = []
        } catch {
            // Any other internal error from liveRows still degrades rather
            // than silently returning a genuine-looking empty. Attribute it
            // to the live-rows read — the only liveRows failure not already
            // named above.
            degradedStages.append(RecallStage.liveRowsReadFailed)
            live = []
        }

        let filtered: [Drawer]
        if degradedStages.isEmpty {
            // Only attempt evaluation when liveRows succeeded; on a failed
            // read `live` is empty and evaluation would just re-confirm empty.
            let forceBitmapEval = forcedRead == .bitmapEval
            do {
                if forceBitmapEval {
                    throw RecallInternalReadFailure(stage: RecallStage.bitmapEvalFailed)
                }
                filtered = try await BitmapEvaluator.evaluate(
                    frame: frame, drawers: live, store: store
                )
            } catch {
                // BitmapEvaluator's throwable failure modes (substrate errors
                // during historical reconstruction) DEGRADE rather than masquerade
                // as a genuine-empty result.
                degradedStages.append(RecallStage.bitmapEvalFailed)
                filtered = []
            }
        } else {
            filtered = []
        }

        // Write trace rows only when the caller opts in via frame.traceLimit.
        // nil (the default) writes ZERO rows — internal scans, VaultBridge
        // scans, and any other non-reward caller do not participate in the
        // reward cycle and must not accumulate trace rows.
        //
        // When traceLimit is set, write at most min(traceLimit, filtered.count)
        // rows for the rows surfaced to the caller. This is the "later two-source
        // reward" hook from NEURONKIT_SPEC §3.1: the reward path later sets
        // used = true for rows the caller acted on, enabling Bradley-Terry to
        // distinguish acted-on rows from ignored ones (cookbook §8.12).
        // One transaction for the batch — never one INSERT per row.
        //
        // FAIL-CLOSED: a trace-write fault does NOT throw and does NOT empty the
        // result — recall stays non-throwing (spec §7.8.1) and the caller still
        // receives its rows. But a DROPPED trace is the reward sweep's missing
        // input, so it is SURFACED as `recall.trace_write_failed` on the same
        // degradedStages channel the internal-read failures use, rather than
        // silently swallowed. Genuine success records nothing.
        if let traceLimit = frame.traceLimit, !filtered.isEmpty {
            let traceItems = filtered.prefix(min(traceLimit, filtered.count)).map { drawer in
                RecallTraceItem(
                    target: drawer.id,
                    recalledAt: now,
                    score: nil,   // ordered-by-capture-time recalls carry no score
                    operationalBitmap: 0)
            }
            do {
                // TEST-ONLY seam: a forced `.traceWrite` fault drives this write
                // to fail without a genuinely-broken store, exercising the
                // surfacing path. No production caller arms it.
                if forcedRead == .traceWrite {
                    throw RecallInternalReadFailure(stage: RecallStage.traceWriteFailed)
                }
                try await store.insertRecallTraces(Array(traceItems))
            } catch {
                degradedStages.append(RecallStage.traceWriteFailed)
            }
        }

        let pageSize = frame.limit ?? RecallStream.defaultPageSize
        return RecallStream(
            rows: filtered,
            pageSize: pageSize,
            hydrationLevel: frame.hydrationLevel,
            degradedStages: degradedStages
        )
    }

    /// Stable stage identifiers for recall internal-read failures.
    /// Centralised so the strings cannot drift from the Rust port or from
    /// `RecallStream.degradedStages`' documented vocabulary.
    enum RecallStage {
        static let liveRowsReadFailed = "locus.liveRows.readFailed"
        static let roomFingerprintsReadFailed = "locus.roomFingerprints.readFailed"
        static let roomDrawerReadFailed = "locus.roomDrawerRead.readFailed"
        static let bitmapEvalFailed = "locus.bitmapEval.failed"
        /// The opt-in recall-trace WRITE (`store.insertRecallTraces`) failed.
        /// recall stays non-throwing and STILL returns its rows — the lost
        /// trace is surfaced here so the reward sweep's missing input is
        /// observable rather than silent. Distinct namespace (`recall.`, not
        /// `locus.`) because this is a write-side reward-path fault, not an
        /// internal-read failure that emptied the result.
        static let traceWriteFailed = "recall.trace_write_failed"
    }

    /// Private carrier for a NAMED internal-read failure inside `liveRows`.
    /// Lets `liveRows` report exactly which read failed (room-fingerprints
    /// vs. room-drawer-read vs. the bounded scan) without widening the
    /// public `LocusKitError` surface — `recall` catches it and records the
    /// `stage` on the stream.
    struct RecallInternalReadFailure: Error {
        let stage: String
    }

    /// The live (non-tombstoned) rows the per-row evaluator must
    /// consider. This is where fingerprint pruning (§ 7.9.4 step 1)
    /// happens, and where the three structural perf fixes apply:
    ///
    /// **No-blob filter pass:** when the filter chain has no content-tier
    /// predicate (`.contentMatches` or a composition containing one),
    /// the corpus scan loads rows at `.structured` hydration — the content
    /// blob column is projected away at the storage tier and never
    /// transferred for the filter step. Bitmap and structured-tier
    /// evaluation have no need for the blob, so this is always safe. Only
    /// when a content predicate is present does the scan fall back to
    /// `.full` so the substring match has the body available.
    ///
    /// After filtering, if the frame's `hydrationLevel` is `.full` AND the
    /// filter pass ran no-blob, the matching drawer IDs are re-fetched at
    /// `.full` so the caller receives the content body. For `.structured`
    /// and `.bitmapOnly` callers the no-blob rows are returned directly —
    /// per spec § 7.3, `.structured` is "bitmap columns + structured-row
    /// fields only, no blob reads", so `content = ""` is the correct result
    /// (not a deficiency). `.bitmapOnly` callers also receive `content = ""`.
    /// The re-fetch is on the small matched set (≤ cap rows), not the full
    /// estate — O(result) not O(estate), and only for `.full` callers.
    ///
    /// **Bounded scan:** the scan bound is `max(frame.limit ?? 0,
    /// recallCandidateCap)`. Director-style callers with limit ~20 keep the
    /// 256 floor; explicit large-limit callers (e.g. VaultBridge limit
    /// 10_000_000) get a true full scan so no drawer is silently truncated.
    /// The non-pruning path passes this bound to the storage layer;
    /// the fingerprint-pruning path applies it via `prefix(scanBound)` after
    /// collection so both paths return identically bounded sets.
    ///
    /// The fingerprint-pruning path (`drawersIn`) is already restricted to
    /// surviving rooms before fetching rows; the rooms that survive a prunable
    /// filter are typically a small fraction of the estate.
    private func liveRows(for frame: RecallFrame, forcedFault: Estate.RecallInternalRead?) async throws -> [Drawer] {
        // Whether the filter chain needs the content body for evaluation.
        // When false the filter pass loads at .structured (no-blob).
        let needsContentForFilter = BitmapEvaluator.chainHasContentPredicate(frame.filterChain)

        // Whether the caller will receive content blobs in the result.
        // Only .full callers need the blob re-fetched after a no-blob scan.
        // .structured callers receive content = "" per spec § 7.3 (structured
        // is "no blob reads" — the empty string is correct, not a gap).
        // .bitmapOnly callers also get content = "" (RecallStream strips it).
        // Eagerly loading blobs for .structured callers is pure waste:
        // RecallStream passes .structured rows through unchanged, so the
        // empty-content no-blob row is exactly what the spec requires.
        let callerNeedsBlob = frame.hydrationLevel == .full

        // The hydration level for the filter/scan pass:
        //   - If the chain has a content predicate, we need the blob now.
        //   - Otherwise load no-blob (.structured); only .full callers
        //     will trigger a re-fetch on the small matched set below.
        let scanHydration: HydrationLevel = needsContentForFilter ? .full : .structured

        // Scan bound: respect explicit large-limit callers (e.g. VaultBridge
        // full-estate scans with limit 10_000_000) while keeping a 256-row
        // floor for director-style callers that do not set an explicit limit.
        // This fixes the data-integrity bug where limit > 256 would be silently
        // truncated to 256, causing VaultBridge to miss drawers #257+.
        let scanBound = max(frame.limit ?? 0, Estate.recallCandidateCap)

        var candidates: [Drawer]
        if BitmapEvaluator.chainHasPrunableFilter(frame.filterChain) {
            // Fingerprint-pruning path: walk surviving rooms and fetch their
            // rows. `drawersIn` already excludes tombstoned rows. Collect
            // up to scanBound candidates, then apply prefix so both paths
            // produce identically bounded sets.
            // Note: `drawersIn` always loads full hydration (it does not take
            // a hydration parameter); for .full callers this is the correct
            // superset. For .structured and .bitmapOnly callers the blob is
            // loaded unnecessarily but the pruning path is already a small
            // fraction of the estate — the dominant cost is the SQL scan, not
            // the blob transfer on a pruned set.
            // Room-fingerprint enumeration. A failure here means the pruning
            // path cannot decide which rooms survive — surface it as a named
            // stage rather than silently scanning nothing.
            let entries: [(wing: String, room: String, fingerprint: ContainerFingerprint)]
            do {
                if forcedFault == .roomFingerprints {
                    throw RecallInternalReadFailure(stage: RecallStage.roomFingerprintsReadFailed)
                }
                entries = try await containerFP.roomLevelEntries()
            } catch let err as RecallInternalReadFailure {
                throw err
            } catch {
                throw RecallInternalReadFailure(stage: RecallStage.roomFingerprintsReadFailed)
            }
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
                // Surviving-room drawer read. A failure here means a room that
                // SHOULD contribute rows silently contributed none — surface it
                // as a named stage instead of returning a short result that
                // looks like a genuine match set.
                do {
                    if forcedFault == .roomDrawerRead {
                        throw RecallInternalReadFailure(stage: RecallStage.roomDrawerReadFailed)
                    }
                    rows.append(contentsOf: try await store.drawersIn(wing: entry.wing, room: entry.room))
                } catch let err as RecallInternalReadFailure {
                    throw err
                } catch {
                    throw RecallInternalReadFailure(stage: RecallStage.roomDrawerReadFailed)
                }
            }
            // Apply bound after collection: both paths emit at most scanBound rows.
            candidates = Array(rows.prefix(scanBound))
        } else {
            // No pruning possible: bounded corpus scan in filedAt order.
            // Uses scanHydration — no-blob when there is no content predicate.
            // Tombstoned rows are included in the scan, so filter them here.
            // A scan failure is surfaced as the live-rows stage rather than
            // masquerading as a genuine-empty corpus.
            do {
                if forcedFault == .liveRows {
                    throw RecallInternalReadFailure(stage: RecallStage.liveRowsReadFailed)
                }
                candidates = (try await store.allDrawers(hydrationLevel: scanHydration, limit: scanBound))
                    .filter { $0.tombstonedAt == nil }
            } catch let err as RecallInternalReadFailure {
                throw err
            } catch {
                throw RecallInternalReadFailure(stage: RecallStage.liveRowsReadFailed)
            }
        }

        // Re-fetch at .full only when the filter pass ran no-blob AND the
        // caller is a .full caller who needs content bodies. .structured and
        // .bitmapOnly callers get the no-blob rows directly — content = ""
        // is the correct per-spec result for both of those tiers.
        // Re-fetch is on the small matched set only (≤ cap rows), keeping
        // blob transfer O(result) rather than O(estate).
        if !needsContentForFilter && callerNeedsBlob && !candidates.isEmpty {
            let ids = candidates.map(\.id)
            let hydrated = try await store.getDrawers(ids: ids, hydrationLevel: .full)
            // Re-order to match candidates order (getDrawers returns unspecified order).
            let hydratedById = Dictionary(uniqueKeysWithValues: hydrated.map { ($0.id, $0) })
            candidates = candidates.compactMap { hydratedById[$0.id] }
        }

        return candidates
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
    /// `true` to proceed. Estate-level toggles (a GDPR-style
    /// per-estate "expunge_allowed" one-way ratchet) are not in
    /// cookbook today and not enforced here; they layer on top of
    /// this primitive when ratified.
    ///
    /// The cross-kit vector delete (§10.5 second postcondition) is
    /// GLK's orchestration responsibility — now implemented; see
    /// GENIUSLOCUSKIT_SPEC_v0.8 §B-2a.
    /// LocusKit's expunge is the storage-layer half: it tombstones the
    /// drawer, zeroes the content, and seals the audit event. GLK's
    /// `VerbSurface.expunge` calls `Corpus.remove` and (for `.glk`
    /// estates) `VectorStore.deleteAllVectors` after this method returns,
    /// completing the two-step privacy delete. Callers that bypass GLK
    /// and reach the estate directly must perform their own vector cleanup.
    ///
    /// Throws:
    ///   - `LocusKitError.invalidContent("expunge requires confirmation")`
    ///     if `confirmation == false`
    ///   - `LocusKitError.drawerNotFound(id:)` if the row does not exist
    ///   - `LocusKitError.invalidContent("expunge rejected by gate: ...")`
    ///     if the prior state cannot transition via `.tombstone`
    ///     (notably: accepted rows, per S-3)
    ///
    /// When `sealAudit` is `true` (default), the audit event seals
    /// atomically inside the storage transaction — correct for direct
    /// callers that own the full expunge. When `false`, the gate-produced
    /// event is returned so the caller (GLK `VerbSurface.expunge`) can
    /// seal it after its own cross-kit orchestration step, satisfying the
    /// §B-2a audit-seal ordering contract: success audit only after the
    /// full two-step privacy delete.
    @discardableResult
    func expunge(
        rowID: RowID,
        reason: String,
        confirmation: Bool,
        now: Date = Date(),
        sealAudit: Bool = true
    ) async throws -> AuditEvent? {
        guard confirmation else {
            throw LocusKitError.invalidContent(
                "expunge requires confirmation: true (destructive op)"
            )
        }
        guard try await store.getDrawer(id: rowID) != nil else {
            throw LocusKitError.drawerNotFound(id: rowID)
        }
        let changedBy = (try? await store.readManifest().ownerIdentifier) ?? ""
        return try await store.expungeGated(
            drawerId: rowID,
            changedBy: changedBy.isEmpty ? "estate" : changedBy,
            reason: reason.isEmpty ? "expunged via Estate.expunge" : reason,
            now: now,
            sealAudit: sealAudit
        )
    }

    /// Seal the success audit event for an expunge whose storage phase
    /// was run with `sealAudit: false`.
    ///
    /// GLK calls this after the cross-kit vector delete completes
    /// successfully. The `event` is the value returned by
    /// `expunge(sealAudit:false)`.
    ///
    /// Deterministic: the caller threads the same `now` the verb received.
    func sealExpungeAudit(_ event: AuditEvent) async throws {
        try await store.sealExpungeAudit(event)
    }

    /// Seal a cross-kit-orphan audit event for an expunge whose storage
    /// phase succeeded but whose cross-kit vector delete (step 2) failed.
    ///
    /// GLK calls this on `crossKitVectorDeleteFailed` before rethrowing.
    /// The `event` is the value returned by `expunge(sealAudit:false)`.
    /// The orphan event uses verb `"expungeOrphan"` so audit consumers
    /// can distinguish a clean expunge from a partial one by reading the
    /// substrate audit trail.
    ///
    /// Deterministic: the caller threads the same `now` the verb received.
    func sealExpungeOrphanAudit(
        rowID: RowID,
        successEvent: AuditEvent,
        now: Date
    ) async throws {
        let changedBy = (try? await store.readManifest().ownerIdentifier) ?? ""
        try await store.sealExpungeOrphanAudit(
            drawerId: rowID,
            successEvent: successEvent,
            changedBy: changedBy.isEmpty ? "estate" : changedBy,
            now: now
        )
    }

    /// Seal a synthetic "expungeOrphan" audit event for a crash-window row.
    ///
    /// Called by the GLK `runExpungeIntegritySweep` maintenance function after
    /// re-attempting the cross-kit vector delete. Unlike `sealExpungeOrphanAudit`,
    /// this path constructs the audit event from the current drawer state rather
    /// than from the original gate event (which was lost in the crash window).
    ///
    /// Deterministic: `now` is millis since UNIX epoch, threaded in by the
    /// sweep; never calls Date() here.
    func sealExpungeOrphanAuditSynthetic(rowID: RowID, now: Int64) async throws {
        let changedBy = (try? await store.readManifest().ownerIdentifier) ?? ""
        try await store.sealExpungeOrphanForSweep(
            drawerId: rowID,
            changedBy: changedBy.isEmpty ? "estate" : changedBy,
            now: now
        )
    }

    /// Query for tombstoned drawers that have no sealed "tombstone" or
    /// "expungeOrphan" audit event.
    ///
    /// Used by the GLK `runExpungeIntegritySweep` maintenance function to
    /// enumerate rows in the crash-window state (tombstoned storage, silent
    /// audit trail). The caller re-attempts the cross-kit delete and seals
    /// a synthetic orphan audit for each returned row.
    ///
    /// - Throws: `LocusKitError` when the underlying storage query fails.
    func tombstonedRowsWithoutExpungeAudit() async throws -> [Drawer] {
        try await store.tombstonedRowsWithoutExpungeAudit()
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
    /// `.correctSensitivity`, `.correctTrust`, and `.correctExportability`
    /// recompose adjectiveBitmap using `BitField.writeField` at the correct
    /// shift/width and persist via `DrawerStore.mutateAdjective`. Only valid
    /// when state==active (the automaton gate enforces this via RowVerb.mutate).
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
            // revive restores a terminal-but-recoverable row to active.
            // Legality is decided per source state (cookbook §9.3, §6.2):
            //
            //   decayed   → active   LEGAL (re-observation revives)
            //   withdrawn → active   LEGAL (unwithdraw an explicit retraction)
            //   expired   → active   LEGAL (TTL revive; no fresh TTL until a
            //                               later mutation sets one)
            //   superseded→ active   CONDITIONAL on the lineage rule below
            //   active/pending/contested/accepted   REFUSED (not historical —
            //                               a live row has nothing to revive)
            //   rejected  → active   REFUSED (a review verdict; the recovery
            //                               path is re-propose, not revive)
            //   tombstoned→ active   REFUSED (hard delete; content is erased
            //                               and unrecoverable)
            //
            // Each refusal is a real domain rule surfaced as
            // `disciplineViolation` naming the rule — never `notSupported`.
            switch drawer.state {
            case .decayed, .withdrawn, .expired:
                // Unconditionally recoverable Cluster-B states.
                break
            case .superseded:
                // Lineage rule (cookbook §6.2): a superseded row was
                // replaced by a successor sharing its lineageID. If that
                // successor (or a later link) still lives — i.e. some row
                // in this lineage is in Cluster A — reviving the predecessor
                // would put TWO active rows at the same lineage head. That
                // is a domain contradiction, so revive refuses and names
                // the conflicting successor. When NO living successor
                // remains (it was itself withdrawn/expired/decayed or
                // tombstoned/expunged), the head is vacant and the
                // predecessor may legally reclaim it.
                if let successorID = try await store.livingSuccessorInLineage(
                    lineageID: drawer.lineageID, excludingID: rowID
                ) {
                    throw LocusKitError.disciplineViolation(
                        from: drawer.state.rawValue,
                        to: State.active.rawValue,
                        reason: "revive: superseded row has a living successor "
                            + "(\(successorID)) holding the lineage head; revive the "
                            + "lineage head or withdraw/expunge the successor first"
                    )
                }
            case .active, .pending, .contested, .accepted:
                // Cluster A — already live; nothing to revive.
                throw LocusKitError.disciplineViolation(
                    from: drawer.state.rawValue,
                    to: State.active.rawValue,
                    reason: "revive: row is already live (\(drawer.state)); "
                        + "revive applies only to historical Cluster-B states"
                )
            case .rejected:
                // Cluster C — a review verdict, not a recoverable historical
                // state. Re-entry is via re-proposal, not revive.
                throw LocusKitError.disciplineViolation(
                    from: drawer.state.rawValue,
                    to: State.active.rawValue,
                    reason: "revive: rejected rows are not revivable; a rejection "
                        + "is a review verdict — re-propose the content instead"
                )
            case .tombstoned:
                // Cluster C terminal — content has been erased; the row is
                // gone in every sense but the audit trail.
                throw LocusKitError.disciplineViolation(
                    from: drawer.state.rawValue,
                    to: State.active.rawValue,
                    reason: "revive: tombstoned rows are unrecoverable; the "
                        + "content blob has been expunged"
                )
            }
            // decayed/withdrawn/expired/superseded(head vacant) → active.
            // The automaton legalizes all four via .observe (re-observation
            // revives); the lineage contradiction for superseded was caught
            // above, so by here the transition is unconditionally legal.
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

        case .correctExportability(let exportability):
            guard let drawer = try await store.getDrawer(id: rowID) else {
                throw LocusKitError.drawerNotFound(id: rowID)
            }
            // Exportability lives in adjectiveBitmap bits 12–17 (cookbook §2.3,
            // 6-bit scale-gapped field; raw 0 = private_, raw 32 = public_).
            // writeField clears that 6-bit window and ORs in the new value,
            // preserving all other adjective axes (state, sensitivity, trust,
            // obligation flags). This is the write-side counterpart to the
            // existing `Drawer.exportability` read accessor in Adjectives.swift
            // (DEBT-1: this is the mutation path that sets the exportability bit).
            let newAdjective = BitField.writeField(
                Int64(exportability.rawValue),
                into: drawer.adjectiveBitmap,
                shift: 12, width: 6
            )
            let changedBy = (try? await store.readManifest().ownerIdentifier) ?? ""
            try await store.mutateAdjective(
                drawerId: rowID,
                newAdjective: newAdjective,
                changedBy: changedBy.isEmpty ? "estate" : changedBy,
                reason: payload ?? "exportability corrected via Estate.mutate",
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

    /// Update a drawer's lattice anchor with a deterministic timestamp.
    ///
    /// The enrichment-completion analogue of `reanchor`: the caller (the
    /// Q-ID-completion acceptance path) supplies the new anchor — typically
    /// the drawer's existing anchor with a resolved `wikidataQID` filled in —
    /// and an explicit `now`, so the anchor write is deterministic per the
    /// CLAUDE.md no-`Date()`-in-engines rule. Writes the anchor delta and an
    /// audit row atomically via `DrawerStore.reanchorGated`.
    ///
    /// - Parameters:
    ///   - rowID: the drawer whose anchor to update.
    ///   - toLattice: the new lattice anchor (with the resolved Q-ID).
    ///   - changedBy: audit provenance — the agent driving the update.
    ///   - now: deterministic write timestamp.
    /// - Throws: `LocusKitError.drawerNotFound` if the row is absent.
    func reanchorAnchor(
        rowID: RowID,
        toLattice: LatticeAnchor,
        changedBy: String,
        now: Date
    ) async throws {
        guard try await store.getDrawer(id: rowID) != nil else {
            throw LocusKitError.drawerNotFound(id: rowID)
        }
        try await store.reanchorGated(
            drawerId: rowID,
            toRoom: nil,
            toLattice: toLattice,
            changedBy: changedBy,
            reason: "anchor Q-ID resolved via enrichment-proposal acceptance",
            now: now
        )
    }

    // MARK: - propose

    /// Create a proposal targeting a row in the estate.
    ///
    /// Validates that the target drawer exists, assembles the `operationalBitmap`
    /// from `ProposeFrame.kind` (bits 0–5), a `.drawer` target object type
    /// (bits 6–11), and the three provenance axes `frame.confirmation`
    /// (bits 12–17), `frame.generatedBy` (bits 18–23), and `frame.confidence`
    /// (bits 24–29), sets `adjectiveBitmap` state to `.pending`, derives
    /// `candidateState` and `latticeAnchor` from the target drawer, then calls
    /// `DrawerStore.addProposal`. Per cookbook §§2.4, 10.7.
    ///
    /// - Parameters:
    ///   - frame: propose slots. `frame.target` must be non-empty and identify an
    ///     existing drawer; throws `LocusKitError.drawerNotFound` otherwise.
    ///   - now: deterministic write timestamp (passed from the outermost public
    ///     boundary per CLAUDE.md deterministic-clock rule).
    /// - Returns: the stored `Proposal` with its generated id and bitmaps set.
    /// - Throws: `LocusKitError.drawerNotFound` if `frame.target` does not exist.
    func propose(_ frame: ProposeFrame, now: Date) async throws -> Proposal {
        guard !frame.target.isEmpty else {
            throw LocusKitError.invalidContent("propose target must not be empty")
        }
        guard let targetDrawer = try await store.getDrawer(id: frame.target) else {
            throw LocusKitError.drawerNotFound(id: frame.target)
        }

        // Operational bitmap, five typed axes per cookbook §2.4, each packed into
        // its own 6-bit window via the conformance-gated BitField.writeField:
        //   bits 0–5   ProposalKind             = frame.kind
        //   bits 6–11  ProposalTargetObjectType = .drawer (propose targets a drawer)
        //   bits 12–17 ProposalConfirmationSource = frame.confirmation
        //   bits 18–23 ProposalGeneratedByClass   = frame.generatedBy
        //   bits 24–29 ProposalConfidenceBucket   = frame.confidence
        // The three provenance axes default (.human / .dreamingDaemon / .null) to
        // their raw-0 values, so a frame that leaves them unset yields the same
        // bitmap as before the slots were wired. The read accessors in
        // ProposalOperational.swift (confirmationSource / generatedByClass /
        // confidenceBucket) decode these exact positions.
        var opBitmap = BitField.writeField(Int64(frame.kind.rawValue), into: 0, shift: 0, width: 6)
        opBitmap = BitField.writeField(Int64(ProposalTargetObjectType.drawer.rawValue), into: opBitmap, shift: 6, width: 6)
        opBitmap = BitField.writeField(Int64(frame.confirmation.rawValue), into: opBitmap, shift: 12, width: 6)
        opBitmap = BitField.writeField(Int64(frame.generatedBy.rawValue), into: opBitmap, shift: 18, width: 6)
        opBitmap = BitField.writeField(Int64(frame.confidence.rawValue), into: opBitmap, shift: 24, width: 6)

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
    func associate(_ frame: AssociateFrame, now: Date) async throws -> Association {
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

    /// Bring an external reference into the estate, grounded against its
    /// source. Per spec § 7.8.2 / cookbook §10.9.
    ///
    /// The reference's genuine lattice anchor is derived from
    /// `frame.source` — a `SourceCatalogEntry` carries the source's
    /// classified lattice position, which the learned reference inherits.
    /// No sentinel anchor is ever fabricated (P1 mandate, Bob's board
    /// item 7). The verb:
    ///
    /// 1. Validates `frame.handle` is non-empty — the only fail-loud path
    ///    on a normal beta call. An empty handle is genuinely invalid input
    ///    (`LocusKitError.invalidContent`).
    /// 2. Catalogs `frame.source` durably if no entry already holds its
    ///    handle (so the same source is cataloged once and reused), then
    ///    resolves the catalog entry whose anchor the reference inherits.
    /// 3. Writes a `LearnedReference` anchored to the catalog entry's
    ///    genuine anchor, with `sourceCatalogID` pointing at it and the
    ///    operational bitmap encoding `mode` (bit 12) and `refreshPolicy`
    ///    (bits 0–5) per cookbook § 2.4.
    ///
    /// - Parameters:
    ///   - frame: learn slots (source, handle, mode, refresh policy).
    ///   - now: deterministic write timestamp.
    /// - Returns: the persisted `LearnedReference`.
    /// - Throws: `LocusKitError.invalidContent` if `frame.handle` is empty;
    ///   substrate errors from the underlying writes.
    func learn(_ frame: LearnFrame, now: Date) async throws -> LearnedReference {
        // Fail loud only on genuinely invalid input. An empty reference
        // handle has nothing to point at — there is no reference to learn.
        guard !frame.handle.isEmpty else {
            throw LocusKitError.invalidContent("learn: handle must not be empty")
        }

        // Resolve (or catalog) the source. The source carries the genuine
        // anchor; cataloging is idempotent by source handle so repeated
        // learns from one source share a single catalog entry.
        let catalogEntry: SourceCatalogEntry
        if let existing = try await store.sourceCatalogEntry(forHandle: frame.source.handle) {
            catalogEntry = existing
        } else {
            try await store.addSourceCatalogEntry(frame.source)
            catalogEntry = frame.source
        }

        // Encode mode (bit 12) and refresh policy (bits 0–5) into the
        // operational bitmap per cookbook § 2.4. The source acquisition
        // axis (bits 13–18) maps from the catalog entry's kind so the
        // reference records the channel it arrived through.
        var operational: Int64 = 0
        operational = BitField.writeField(
            Int64(frame.refreshPolicy.rawValue), into: operational, shift: 0, width: 6)
        operational = BitField.writeFlag(
            frame.mode == .byIngestion, into: operational, bit: 12)
        operational = BitField.writeField(
            Int64(catalogEntry.kind.rawValue), into: operational, shift: 13, width: 6)

        let reference = LearnedReference(
            id: UUID().uuidString,
            sourceCatalogID: catalogEntry.id,
            handle: frame.handle,
            // Genuine anchor, inherited from the source's catalog entry —
            // never a sentinel.
            latticeAnchor: catalogEntry.latticeAnchor,
            operationalBitmap: operational,
            addedBy: "learn",
            filedAt: now
        )
        try await store.addLearnedReference(reference)
        return reference
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

    /// Update a drawer's provenance bitmap. The only production call site is
    /// the maintenance daemon's enrichment-status retry path (Board item 14),
    /// which flips the enrichment-status field (bits 36-41, cookbook §2.5)
    /// from `qid_pending` to `qid_completed` on a successful Q-ID retry. The
    /// write is audited atomically by `DrawerStore.mutateProvenance`.
    ///
    /// Determinism: `now` is the caller-supplied timestamp; never reads `Date()`
    /// internally per CLAUDE.md.
    ///
    /// - Parameters:
    ///   - rowID: the drawer whose provenance bitmap to update.
    ///   - newProvenance: the full new provenance bitmap (caller constructs it
    ///     from the current value via `BitField.writeField`).
    ///   - changedBy: audit provenance — the agent driving the update.
    ///   - reason: optional human-readable reason written into the audit row.
    ///   - now: deterministic write timestamp.
    /// - Throws: `LocusKitError.drawerNotFound` if the row is absent.
    public func mutateProvenance(
        rowID: RowID,
        newProvenance: Int64,
        changedBy: String,
        reason: String? = nil,
        now: Date
    ) async throws {
        try await store.mutateProvenance(
            drawerId: rowID,
            newProvenance: newProvenance,
            changedBy: changedBy,
            reason: reason,
            now: now
        )
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

    /// Test-only helper. Drives a validated state transition via
    /// `DrawerStore.mutateState`, writing one sealed audit row. Tests use
    /// this to stage the dream-maintenance states (`.decayed`, `.expired`)
    /// that no consumer-facing verb reaches — `decay`/`expire` are
    /// dreaming-daemon transitions, not `MutationKind` cases — so the
    /// revive verb can be exercised from every legal source state.
    /// Internal so `@testable import LocusKit` reaches it; production
    /// callers do not.
    internal func _mutateState(
        rowID: RowID, to: State, via: RowVerb, now: Date
    ) async throws {
        try await store.mutateState(
            drawerId: rowID,
            to: to,
            via: via,
            changedBy: "test-helper",
            reason: "test-fixture",
            now: now
        )
    }

    /// Test-only helper. Returns the count of sealed audit events for a
    /// row, so tests can assert that a verb appended exactly one. Internal
    /// so `@testable import LocusKit` reaches it; production callers do not.
    internal func _auditEventCount(rowID: RowID) async throws -> Int {
        guard let uuid = UUID(uuidString: rowID) else { return 0 }
        return try await store.auditEventCountForRow(uuid)
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
