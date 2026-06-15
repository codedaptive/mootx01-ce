import Foundation
import SubstrateML
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

/// Compiles a `RecallFrame.filterChain` into the bitmap operator
/// primitives and evaluates it against drawer rows. Per spec § 7.9.
///
/// The evaluator runs a four-stage pipeline against the row set
/// `Estate.recall` hands it:
///
/// 1. Default insertion (§ 7.9.5) — prepend the four implicit
///    filters (`.sensitivityAtMost(.elevated)`, `.trustworthy`,
///    `.userConfirmed`, `.currentlyBelieve`) for any concern the
///    caller did not constrain. Tombstone exclusion is always
///    enforced and is independent of the chain (state == 9 rejected
///    at the bitmap tier).
/// 2. Bitmap-tier evaluation (§ 7.9.2 / § 7.9.3) — each Filter case
///    compiles to a predicate over `(adjectiveBitmap,
///    operationalBitmap, provenance)` and is applied via
///    `andMask` / `thresholdCompare` / `shiftExtract`. Historical
///    reconstruction folds the row's audit log via
///    `AuditLogFold.projectStateAt` (cookbook § 5.3) when
///    `frame.asOf` is non-nil; state is keyed on HLC.
/// 3. Structured tier (§ 7.9.4 step 3) — `.inRoom`, `.inWing`,
///    `.lineageID`, `.createdAfter`, `.createdBefore`,
///    `.latticeAnchor`, `.latticeUnder`, `.wikidataConcept`.
/// 4. Content tier (§ 7.9.4 step 4) — `.contentMatches` via
///    `localizedCaseInsensitiveContains`.
///
/// Fingerprint pruning (§ 7.9.4 step 1) runs ahead of these tiers in
/// the recall path. `containerSurvives` tests the chain's set-bit
/// filters against a container's OR fingerprint (spec § 11.5), so a
/// container whose fingerprint lacks a required bit is dropped before
/// its rows are fetched. The test is sound, it never drops a container
/// holding a match, and conservative, it prunes only on set-bit
/// filters such as `.hasFeatureFlag`; threshold filters cannot prune
/// through an OR and fall through to the per-row scan.
///
/// Entry point: `BitmapEvaluator.evaluate(frame:drawers:store:)`.
///
/// Declared `internal` rather than `public` because `DrawerStore` is
/// internal — the substrate handle never crosses the kit boundary,
/// so neither can a function that takes it. Public callers reach this
/// pipeline through `Estate.recall(_:)` in `EstateVerbs.swift`.
struct BitmapEvaluator {

    // MARK: - Layout constants (derived from §§ 5.5–5.6 and Q1_DECISION_PROVENANCE_BITMAP.md)
    //
    // Mirrors the accessor decoders on `Drawer` exactly. These constants
    // are deliberately private — the evaluator's translation table, not
    // part of the public surface. A schema bump (`bitmap_layout_version`)
    // moves them in lock-step with the per-axis accessors.

    // Adjective bitmap (`Drawer.adjectiveBitmap`, cookbook §2.3).
    // F11 cascade (2026-05-27): 4-bit → 6-bit fields per I-15.
    private static let adjStateMask:       Int64 = 0x3F          // bits 0–5
    private static let adjStateShift:      Int   = 0
    private static let adjSensMask:        Int64 = 0x3F << 6     // 0xFC0,  bits 6–11
    private static let adjSensShift:       Int   = 6
    private static let adjExportMask:      Int64 = 0x3F << 12    // 0x3F000, bits 12–17
    private static let adjExportShift:     Int   = 12
    private static let adjTrustMask:       Int64 = 0x3F << 18    // 0xFC0000, bits 18–23
    private static let adjTrustShift:      Int   = 18

    // State cluster predicate per cookbook §2.3:
    //   cluster(state) = (state >> 4) & 0x3
    //   0 = Cluster A (active / pending / contested / accepted)
    //   1 = Cluster B (superseded / decayed / withdrawn / expired)
    //   2 = Cluster C (rejected / tombstoned)
    private static let stateClusterShift:  Int   = 4
    private static let stateClusterMask:   Int64 = 0x3
    private static let stateClusterA:      Int64 = 0      // currently believed
    private static let stateClusterB:      Int64 = 1      // knew past
    private static let stateClusterC:      Int64 = 2      // terminal
    private static let stateTombstone:     Int64 = 33     // State.tombstoned.rawValue per cookbook §2.3

    // Trust threshold (§ 6.4): `trust < 4` is trustworthy
    // (verbatim / observed / imported / canonical). Cookbook §2.3 trust
    // raws 0–6 are still contiguous, so this threshold is unchanged.
    private static let trustThreshold:     Int64 = 4

    // Provenance bitmap (`Drawer.provenance`, cookbook §2.5 v0.6)
    // F13 cascade (2026-05-27): bumped all fields to 6-bit floor and
    // shifted per cookbook §2.5 layout.
    private static let provSourceMask:     Int64 = 0x3F          // bits 0–5
    private static let provSourceShift:    Int   = 0
    private static let provChannelMask:    Int64 = 0xFC0         // bits 6–11
    private static let provChannelShift:   Int   = 6
    private static let provCaptureChannelMask:  Int64 = 0x3F000  // bits 12–17 (NEW)
    private static let provCaptureChannelShift: Int   = 12
    private static let provConfirmMask:    Int64 = 0xFC0000      // bits 18–23
    private static let provConfirmShift:   Int   = 18
    private static let provConfidenceMask: Int64 = 0x3F000000    // bits 24–29
    private static let provConfidenceShift: Int  = 24
    private static let provSensitivityMask: Int64 = 0xFC0000000  // bits 30–35 (NEW)
    private static let provSensitivityShift: Int  = 30
    private static let provEnrichmentMask: Int64 = 0x3F000000000 // bits 36–41 (NEW)
    private static let provEnrichmentShift: Int   = 36
    // Confirmation threshold for `.userConfirmed` (cookbook §9.4):
    // confirmation >= userConfirmed (raw 1 per cookbook §2.5).
    // Filters out unconfirmed=0 only; passes user/automated/peer/actuator.
    private static let provUserConfirmed:  Int64 = 1

    // Operational bitmap (`Drawer.operationalBitmap`, cookbook §2.4 v0.6)
    // F12 cascade (2026-05-27): bumped to 6-bit fields per cookbook §2.4.
    private static let opChannelMask:      Int64 = 0x3F      // bits 0–5
    private static let opChannelShift:     Int   = 0
    private static let opContentKindMask:  Int64 = 0xFC0     // bits 6–11
    private static let opContentKindShift: Int   = 6

    // MARK: - Public entry point

    /// Evaluate `frame` against `drawers`.
    ///
    /// `drawers` is the pre-fetched non-tombstoned row set — fingerprint
    /// pruning (§ 7.9.4 step 1) is deferred to LOCI_V035_18, so today's
    /// caller (`Estate.recall`) hands in `store.allDrawers()`. The
    /// evaluator handles tombstone exclusion at the bitmap tier in case
    /// the caller's pre-filter ever loosens.
    ///
    /// - Parameters:
    ///   - frame: the caller's recall frame.
    ///   - drawers: all drawers under consideration.
    ///   - store: the backing substrate; used for `auditEventsForRow`
    ///     lookups during historical reconstruction via
    ///     `AuditLogFold.projectStateAt`. Ignored when `frame.asOf` is nil.
    /// - Returns: the ordered, filtered slice of drawers ready for
    ///   `RecallStream` to page out.
    /// - Throws: Propagates substrate errors from `DrawerStore.auditEventsForRow`
    ///   during historical reconstruction.
    static func evaluate(
        frame: RecallFrame,
        drawers: [Drawer],
        store: DrawerStore
    ) async throws -> [Drawer] {
        let chain = insertDefaults(frame.filterChain)

        // 1. Per-row bitmap evaluation, with historical reconstruction
        //    when `asOf` is set. Reconstruction touches the substrate;
        //    keeping it inside the loop means rows that fail an earlier
        //    bitmap predicate after reconstruction still pay only their
        //    own audit-row scan, not the entire corpus's.
        var candidates: [Drawer] = []
        candidates.reserveCapacity(drawers.count)
        for drawer in drawers {
            let (adj, op, prov): (Int64, Int64, Int64)
            if let asOf = frame.asOf {
                // Fold the row's audit log up to `asOf` (HLC) — one
                // projection returns all three column snapshots in a
                // single pass (DECISION_CLOCK_TRIANGLE: state evolves
                // in HLC order; wall-clock is not a fold axis).
                let projected = try await reconstructAt(
                    rowID: drawer.id, asOf: asOf, store: store)
                if let p = projected {
                    adj = p.adjectiveBitmap
                    op = p.operationalBitmap
                    prov = p.provenanceBitmap
                } else {
                    // No events at or before asOf — the row had no
                    // state yet; skip it from the historical view.
                    continue
                }
            } else {
                adj = drawer.adjectiveBitmap
                op = drawer.operationalBitmap
                prov = drawer.provenance
            }
            if evaluateBitmapTier(chain: chain, adj: adj, op: op, prov: prov) {
                candidates.append(drawer)
            }
        }

        // 2. Structured-tier filters (room/wing/time/lattice).
        candidates = candidates.filter {
            evaluateStructuredTier(chain: chain, drawer: $0)
        }

        // 3. Content-tier filters (substring match).
        candidates = try candidates.filter {
            try evaluateContentTier(chain: chain, drawer: $0)
        }

        // 4. Ordering.
        return sort(candidates, ordering: frame.ordering)
    }

    // MARK: - Default insertion (§ 7.9.5)

    /// Prepend the four default filters for any concern the caller did
    /// not constrain. Insertion is order-stable but the precise position
    /// is not observable — `evaluateBitmapTier` ANDs the entire chain.
    ///
    /// Each default has a classifier that recognises any Filter case
    /// covering that concern; this includes the named-defaults
    /// (`.currentlyBelieve`, `.trustworthy`, `.userConfirmed`) and the
    /// general cases that constrain the same axis (`.state`,
    /// `.trustAtMost`, `.sensitivity`, etc.), so a caller saying
    /// "give me only `.contested` state" suppresses the
    /// `.currentlyBelieve` default rather than ANDing both.
    private static func insertDefaults(_ chain: [Filter]) -> [Filter] {
        var result = chain
        if !chain.contains(where: isBitmapStateFilter) {
            result.insert(.currentlyBelieve, at: 0)
        }
        if !chain.contains(where: isBitmapTrustFilter) {
            result.insert(.trustworthy, at: 0)
        }
        if !chain.contains(where: isBitmapProvFilter) {
            result.insert(.userConfirmed, at: 0)
        }
        if !chain.contains(where: isBitmapSensitivityFilter) {
            // Sensitivity default — ceiling is `.elevated`, the Normal-tier
            // ceiling per ADR-007 Decision 2 / VK-TIER-01 mapping (Normal
            // tier = normal + elevated; restricted = Private tier; secret =
            // Secret tier). `restricted` and `secret` are excluded from
            // default recall. This is the no-claims posture: § 9.2
            // access claims (future ARIA_MCP) can LOWER the ceiling when a
            // caller's grant set does not include elevated content. Conditional
            // on absence so an explicit sensitivity constraint from the caller
            // suppresses this default rather than AND-ing against it.
            result.insert(.sensitivityAtMost(.elevated), at: 0)
        }
        return result
    }

    private static func isBitmapStateFilter(_ f: Filter) -> Bool {
        switch f {
        case .currentlyBelieve, .usedToBelieve, .knewOnceAndErased,
             .state, .stateInCluster:
            return true
        case .all(let fs), .any(let fs):
            return fs.contains(where: isBitmapStateFilter)
        case .not(let inner):
            return isBitmapStateFilter(inner)
        default:
            return false
        }
    }

    private static func isBitmapTrustFilter(_ f: Filter) -> Bool {
        switch f {
        case .trustworthy, .requiresConfirmation, .trust, .trustAtMost:
            return true
        case .all(let fs), .any(let fs):
            return fs.contains(where: isBitmapTrustFilter)
        case .not(let inner):
            return isBitmapTrustFilter(inner)
        default:
            return false
        }
    }

    private static func isBitmapProvFilter(_ f: Filter) -> Bool {
        switch f {
        case .userConfirmed, .automatedConfirmedOnly, .unconfirmed,
             .sourceType, .channel, .confidenceAtLeast:
            return true
        case .all(let fs), .any(let fs):
            return fs.contains(where: isBitmapProvFilter)
        case .not(let inner):
            return isBitmapProvFilter(inner)
        default:
            return false
        }
    }

    private static func isBitmapSensitivityFilter(_ f: Filter) -> Bool {
        switch f {
        case .sensitivity, .sensitivityAtMost:
            return true
        case .all(let fs), .any(let fs):
            return fs.contains(where: isBitmapSensitivityFilter)
        case .not(let inner):
            return isBitmapSensitivityFilter(inner)
        default:
            return false
        }
    }

    // MARK: - Container pruning (§ 7.9.4 step 1)

    /// Whether the chain carries any filter that container pruning can
    /// act on. When false no container can be excluded, so the recall
    /// path scans the corpus directly and pays no per-container fetch
    /// overhead for the common threshold-only chain.
    static func chainHasPrunableFilter(_ chain: [Filter]) -> Bool {
        chain.contains { filterIsPrunable($0) }
    }

    /// Whether the chain carries any content-tier predicate (`.contentMatches`
    /// or a composition containing one). When true the recall path must load
    /// drawers at `.full` hydration so the content body is available for the
    /// substring match. When false the no-blob `.structured` projection is
    /// sufficient — the bitmap and structured tiers have no need for the blob.
    ///
    /// This is the per-query hydration decision: loading content blobs for
    /// every drawer on every unfiltered query is O(N_blob) data transferred
    /// out of storage; skipping it when no content predicate is present
    /// eliminates the dominant per-query I/O cost on large estates.
    static func chainHasContentPredicate(_ chain: [Filter]) -> Bool {
        chain.contains { isContentFilter($0) }
    }

    private static func filterIsPrunable(_ filter: Filter) -> Bool {
        switch filter {
        case .hasFeatureFlag:
            return true
        case .all(let fs), .any(let fs):
            return fs.contains { filterIsPrunable($0) }
        case .not(let f):
            return filterIsPrunable(f)
        default:
            return false
        }
    }

    /// Whether a container might hold a row that satisfies the chain,
    /// given its OR fingerprint. Returns false only when the chain
    /// provably cannot be satisfied by any row in the container. Sound,
    /// because the OR covers every active row, so a set bit absent from
    /// the OR is absent from every row.
    static func containerSurvives(chain: [Filter],
                                  fingerprint: ContainerFingerprint) -> Bool {
        !chain.contains { containerProvablyExcludes($0, fingerprint) }
    }

    /// Whether the fingerprint proves no row can satisfy this filter.
    /// Only set-bit filters yield a proof: a required bit absent from
    /// the OR is absent from every row. Threshold and value filters
    /// cannot be decided from an OR, so they never exclude a container.
    private static func containerProvablyExcludes(
        _ filter: Filter, _ fp: ContainerFingerprint
    ) -> Bool {
        switch filter {
        case .hasFeatureFlag(let f):
            // Matches when (op & f.rawValue) != 0, so no row can match
            // when the operational OR shares no bit with the flag set.
            return (fp.operational & f.rawValue) == 0
        case .all(let fs):
            // Conjunction: excluded if any conjunct is unsatisfiable.
            return fs.contains { containerProvablyExcludes($0, fp) }
        case .any(let fs):
            // Disjunction: excluded only if every disjunct is unsatisfiable.
            return !fs.isEmpty && fs.allSatisfy { containerProvablyExcludes($0, fp) }
        default:
            // not(...), threshold, value, and structured filters give no
            // sound exclusion from an OR fingerprint.
            return false
        }
    }

    // MARK: - Bitmap-tier evaluation (§ 7.9.2 / § 7.9.3)

    /// Tombstone exclusion is enforced here, independent of the chain:
    /// a row with `state == 9` (`State.tombstoned`) never surfaces, even
    /// if the caller's chain would otherwise admit it. Per spec § 7.9.4.
    private static func evaluateBitmapTier(
        chain: [Filter], adj: Int64, op: Int64, prov: Int64
    ) -> Bool {
        let stateVal = shiftExtract(adj, shift: adjStateShift, mask: adjStateMask)
        guard stateVal != stateTombstone else { return false }
        return chain.allSatisfy { evaluateOne($0, adj: adj, op: op, prov: prov) }
    }

    /// Compile a single Filter case to a bitmap-tier predicate. Cases
    /// outside the bitmap tier (structured / content)
    /// pass at this stage; they are evaluated in their respective tiers.
    private static func evaluateOne(
        _ filter: Filter, adj: Int64, op: Int64, prov: Int64
    ) -> Bool {
        switch filter {

        // State axis (adjective bits 0–5). Cluster predicate per cookbook
        // §2.3: `(state >> 4) & 0x3` maps to {0=A currently believed,
        // 1=B knew past, 2=C terminal}.
        case .currentlyBelieve:
            return shiftExtract(adj, shift: stateClusterShift, mask: stateClusterMask) == stateClusterA
        case .usedToBelieve:
            return shiftExtract(adj, shift: stateClusterShift, mask: stateClusterMask) == stateClusterB
        case .knewOnceAndErased:
            return shiftExtract(adj, shift: stateClusterShift, mask: stateClusterMask) == stateClusterC
        case .state(let s):
            return andMask(adj, mask: adjStateMask, expected: Int64(s.rawValue))
        case .stateInCluster(let c):
            let v = shiftExtract(adj, shift: stateClusterShift, mask: stateClusterMask)
            switch c {
            case .knowNow:  return v == stateClusterA
            case .knewPast: return v == stateClusterB
            case .terminal: return v == stateClusterC
            }

        // Trust axis (adjective bits 18–23 per cookbook §2.3)
        case .trustworthy:
            return thresholdCompare(adj, mask: adjTrustMask, shift: adjTrustShift,
                                    op: .lessThan, value: trustThreshold)
        case .requiresConfirmation:
            return thresholdCompare(adj, mask: adjTrustMask, shift: adjTrustShift,
                                    op: .greaterThanOrEqual, value: trustThreshold)
        case .trust(let t):
            return andMask(adj, mask: adjTrustMask,
                           expected: Int64(t.rawValue) << adjTrustShift)
        case .trustAtMost(let t):
            return thresholdCompare(adj, mask: adjTrustMask, shift: adjTrustShift,
                                    op: .lessThanOrEqual, value: Int64(t.rawValue))

        // Adjective sensitivity axis (adjective bits 4–7).
        // Distinct from the provenance sensitivity axis (bits 16–17 of
        // `provenance`); Filter cases route to the adjective axis per
        // spec § 7.9.2 because that is the access-gate-relevant tier.
        case .sensitivity(let s):
            return andMask(adj, mask: adjSensMask,
                           expected: Int64(s.rawValue) << adjSensShift)
        case .sensitivityAtMost(let s):
            return thresholdCompare(adj, mask: adjSensMask, shift: adjSensShift,
                                    op: .lessThanOrEqual, value: Int64(s.rawValue))

        // Exportability axis (adjective bits 8–11)
        case .exportable:
            return andMask(adj, mask: adjExportMask,
                           expected: Int64(AdjectiveExportability.public_.rawValue) << adjExportShift)
        case .contained:
            return andMask(adj, mask: adjExportMask,
                           expected: Int64(AdjectiveExportability.private_.rawValue) << adjExportShift)

        // Provenance — confirmation axis (bits 4–6)
        case .userConfirmed:
            return thresholdCompare(prov, mask: provConfirmMask, shift: provConfirmShift,
                                    op: .greaterThanOrEqual, value: provUserConfirmed)
        case .automatedConfirmedOnly:
            return andMask(prov, mask: provConfirmMask,
                           expected: Int64(Confirmation.automatedConfirmed.rawValue) << provConfirmShift)
        case .unconfirmed:
            return andMask(prov, mask: provConfirmMask, expected: 0)

        // Provenance — other axes
        case .sourceType(let s):
            return andMask(prov, mask: provSourceMask,
                           expected: Int64(s.rawValue) << provSourceShift)
        case .confidenceAtLeast(let c):
            return thresholdCompare(prov, mask: provConfidenceMask, shift: provConfidenceShift,
                                    op: .greaterThanOrEqual, value: Int64(c.rawValue))
        case .channel(let ch):
            return andMask(prov, mask: provChannelMask,
                           expected: Int64(ch.rawValue) << provChannelShift)

        // Operational axes
        case .captureChannel(let c):
            return andMask(op, mask: opChannelMask,
                           expected: Int64(c.rawValue) << opChannelShift)
        case .contentKind(let k):
            return andMask(op, mask: opContentKindMask,
                           expected: Int64(k.rawValue) << opContentKindShift)
        case .hasFeatureFlag(let f):
            // Feature flags are an OptionSet whose rawValue is already
            // bit-positioned; a non-zero intersection means at least one
            // requested flag is set.
            return (op & f.rawValue) != 0

        // Composition — bitmap-tier portion (structured / content cases
        // inside the children pass at this tier and are re-evaluated
        // in the structured / content stages where they belong).
        case .all(let fs):
            return fs.allSatisfy { evaluateOne($0, adj: adj, op: op, prov: prov) }
        case .any(let fs):
            return fs.contains { evaluateOne($0, adj: adj, op: op, prov: prov) }
        case .not(let f):
            return !evaluateOne(f, adj: adj, op: op, prov: prov)

        // Non-bitmap cases — pass at this tier, evaluated in their own
        // tier below. Includes structured (room/wing/time/lattice) and
        // content (.contentMatches).
        default:
            return true
        }
    }

    // MARK: - Structured-tier evaluation (§ 7.9.4 step 3)

    private static func evaluateStructuredTier(
        chain: [Filter], drawer: Drawer
    ) -> Bool {
        chain.allSatisfy { evaluateStructured($0, drawer: drawer) }
    }

    /// Classifier — does `f` (or any of its children) name a
    /// structured-tier concern? Used by the composition cases below
    /// so a `.not(.bitmapFilter)` does not flip to `false` here at
    /// the structured tier. Composition cases that contain no
    /// structured child pass at this tier — the bitmap tier and
    /// content tier handle the children they care about.
    private static func isStructuralFilter(_ f: Filter) -> Bool {
        switch f {
        case .inRoom, .inWing, .lineageID, .createdAfter, .createdBefore,
             .latticeAnchor, .latticeUnder, .wikidataConcept:
            return true
        case .all(let fs), .any(let fs):
            return fs.contains(where: isStructuralFilter)
        case .not(let inner):
            return isStructuralFilter(inner)
        default:
            return false
        }
    }

    private static func evaluateStructured(
        _ filter: Filter, drawer: Drawer
    ) -> Bool {
        switch filter {
        case .inRoom(let r):        return drawer.room == r
        case .inWing(let w):        return drawer.wing == w
        case .lineageID(let l):     return drawer.lineageID == l
        case .createdAfter(let d):  return drawer.filedAt > d
        case .createdBefore(let d): return drawer.filedAt < d
        case .latticeAnchor(let a): return drawer.udcCode == a.udcCode
        case .latticeUnder(let p):  return drawer.udcCode.hasPrefix(p)
        case .wikidataConcept(let q):
            // Match either the primary Q-ID or any secondary in the
            // comma-separated `wikidataQidsSecondary` field. The
            // secondary field is stored as a flat comma-joined string
            // (no whitespace) so a substring match against
            // `,Q-padded,` is safe; for the lead and trailing edge we
            // wrap the field in commas to avoid a `Q1` false-match
            // inside `Q11`.
            if drawer.wikidataQID == q { return true }
            guard let secondary = drawer.wikidataQidsSecondary else { return false }
            return (",\(secondary),").contains(",\(q),")

        // Composition cases evaluate ONLY their structurally-relevant
        // children. A child like `.trustworthy` is a bitmap-tier
        // concern; at the structured tier it is a no-op rather than a
        // pass that `.not` would flip to a false exclusion.
        case .all(let fs):
            return fs
                .filter(isStructuralFilter)
                .allSatisfy { evaluateStructured($0, drawer: drawer) }
        case .any(let fs):
            let structural = fs.filter(isStructuralFilter)
            if structural.isEmpty { return true }
            return structural.contains { evaluateStructured($0, drawer: drawer) }
        case .not(let f):
            if isStructuralFilter(f) { return !evaluateStructured(f, drawer: drawer) }
            return true

        default: return true  // bitmap and content cases pass at this tier
        }
    }

    // MARK: - Content-tier evaluation (§ 7.9.4 step 4)

    private static func evaluateContentTier(
        chain: [Filter], drawer: Drawer
    ) throws -> Bool {
        for filter in chain where try !evaluateContent(filter, drawer: drawer) {
            return false
        }
        return true
    }

    /// Classifier — does `f` (or any of its children) name a
    /// content-tier concern? Same role as `isStructuralFilter` at the
    /// content tier; keeps a `.not(.bitmapFilter)` from flipping to
    /// `false` here.
    private static func isContentFilter(_ f: Filter) -> Bool {
        switch f {
        case .contentMatches:
            return true
        case .all(let fs), .any(let fs):
            return fs.contains(where: isContentFilter)
        case .not(let inner):
            return isContentFilter(inner)
        default:
            return false
        }
    }

    private static func evaluateContent(
        _ filter: Filter, drawer: Drawer
    ) throws -> Bool {
        switch filter {
        case .contentMatches(let s):
            return drawer.content.localizedCaseInsensitiveContains(s)
        // Composition cases evaluate ONLY content-tier children — see
        // the structured tier's matching classifier for the rationale.
        case .all(let fs):
            for f in fs where isContentFilter(f) {
                if try !evaluateContent(f, drawer: drawer) { return false }
            }
            return true
        case .any(let fs):
            let contentChildren = fs.filter(isContentFilter)
            if contentChildren.isEmpty { return true }
            for f in contentChildren {
                if try evaluateContent(f, drawer: drawer) { return true }
            }
            return false
        case .not(let f):
            if isContentFilter(f) { return try !evaluateContent(f, drawer: drawer) }
            return true
        default:
            return true  // bitmap and structured cases pass at this tier
        }
    }

    // MARK: - Historical reconstruction (cookbook § 5.3)

    /// Reconstruct a row's full bitmap state as of `asOf` (HLC) by
    /// folding the row's audit log via
    /// `AuditLogFold.projectStateAt`. Returns nil when the row has no
    /// events at or before `asOf` (it did not exist yet at that point
    /// — the genesis capture event is the earliest fact in the log).
    private static func reconstructAt(
        rowID: String,
        asOf: HLC,
        store: DrawerStore
    ) async throws -> ProjectedRowState? {
        let rowUuid = try DrawerStore.requireUuid(rowID, label: "rowID")
        let events = try await store.auditEventsForRow(rowUuid)
        return AuditLogFold.projectStateAt(
            rowId: rowUuid, nounType: .drawer, events: events, asOf: asOf)
    }

    // MARK: - Ordering

    private static func sort(_ drawers: [Drawer], ordering: Ordering) -> [Drawer] {
        switch ordering {
        case .byCaptureTimeDesc:
            return drawers.sorted { $0.filedAt > $1.filedAt }
        case .byCaptureTimeAsc:
            return drawers.sorted { $0.filedAt < $1.filedAt }
        case .byRoomAsc:
            return drawers.sorted { $0.room < $1.room }
        }
    }
}
