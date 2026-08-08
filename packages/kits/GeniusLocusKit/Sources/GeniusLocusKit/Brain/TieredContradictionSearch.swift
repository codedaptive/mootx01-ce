// TieredContradictionSearch.swift
//
// MXE-CT3 P2 — the tiered contradiction lanes and the synthesis
// assembler. One search verb, two modes:
//
//   single tier N — run ONLY that tier's lane and answer its question
//     in isolation (no cross-tier dedup: a purpose-run answers its own
//     question, so a pair that is also a tier-1 proof still appears in
//     a tier-3 run).
//   synthesis (tier == nil) — run all three lanes, then assemble:
//     duplicates promote to their highest tier, lower tiers backfill
//     from their over-fetch, and the three sections render in tier
//     order 1, 2, 3 — NEVER interleaved into one ranked list. Tiers
//     are epistemic classes, not score bands: a strong tier-3 lexical
//     cue never outranks a weak tier-1 typed proof.
//
// The tiers (P1, SubstrateML `ConflictCueKind.contradictionTier`):
//
//   Tier 1 — typed proof. `conflictProjectionSweep`'s
//     ProvenContradiction findings (retrieval proposes; typed
//     constraints prove). No lexical score exists here — ranking is
//     recency of the most recent endpoint event.
//   Tier 2 — structural lexical cues: negation_asymmetry,
//     marker_revision, word_exclusion.
//   Tier 3 — value divergence (value_divergence): same claim shape,
//     different value.
//
// Retrieval runs ONCE per search: the tier-2 and tier-3 lanes share a
// single `contradictionCandidatePairs` pass (the hunter's retrieval,
// factored out in ContradictionHunt.swift) — never two passes over the
// estate. Tier 1 reads the typed sweep, which is its own pure read.
//
// This surface is read-and-report ONLY: no tunnel proposals, no
// writes, no lifecycle transitions. The WRITE half lives in
// ConflictTunnelLifecycle.swift (`proposeConflictTunnels` files
// tier-labeled proposals out of the same `lexicalTierScan` pass) and
// TunnelReviewLadder.swift (the P2.5 endorse/object review ladder).
// Rust twin: rust/src/brain/tiered_contradiction_search.rs
// (pure core) + the coordinator's `tiered_contradiction_search` seam.

import Foundation
import LocusKit
import SubstrateML

// MARK: - Tier vocabulary

/// The three epistemic classes a contradiction finding can carry.
/// Named `ContradictionTier` (not `Tier`) to avoid colliding with the
/// existing `MatrixTier`. Raw values are the wire tier numbers from
/// P1's `ConflictCueKind.contradictionTier` mapping.
public enum ContradictionTier: Int, Sendable, Equatable, Hashable, CaseIterable, Comparable {
    /// Tier 1 — a typed-lane proof (ConflictProjectionSweep
    /// ProvenContradiction). The strongest class: constraints proved
    /// the conflict; no lexical score applies.
    case typedProven = 1
    /// Tier 2 — structural lexical cues (negation_asymmetry,
    /// marker_revision, word_exclusion).
    case lexicalStructural = 2
    /// Tier 3 — lexical value divergence (value_divergence).
    case lexicalValue = 3

    /// Lower tier number = higher epistemic class.
    public static func < (lhs: ContradictionTier, rhs: ContradictionTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Findings

/// One finding in a tiered report. A tagged union in struct clothing:
/// tiers 2/3 carry the lexical fields (cueKind, score, snippets) and
/// tier 1 carries the typed-proof fields (ruleID, resultID,
/// coordinateDigest, sensitivityCeilingRaw); the other side's fields
/// are nil. Kept as one flat type so the per-tier sections share a
/// report shape and the assembler stays generic over tiers.
public struct TierFinding: Sendable, Equatable {
    public let tier: ContradictionTier
    /// Case-canonical unordered drawer-pair key
    /// (`TieredContradictionCore.pairKey`) — the assembler's dedup
    /// identity across tiers AND ports.
    public let pairKey: String
    /// Endpoint drawer IDs in canonical order (case-insensitively
    /// smaller first, matching `pairKey`'s ordering). Original casing
    /// is preserved — these must round-trip to storage lookups.
    public let drawerA: String
    public let drawerB: String
    /// Tiers 2/3: `ConflictCueKind` raw value ("negation_asymmetry",
    /// ...). Tier 1: nil (a typed proof has a rule, not a cue).
    public let cueKind: String?
    /// Tier 1: the typed rule that proved the pair. Tiers 2/3: nil.
    public let ruleID: String?
    /// Tiers 2/3: the cue score. Tier 1: nil — a typed proof has NO
    /// score; its lane ranks by endpoint recency, and the absence of a
    /// score is load-bearing (nothing may fold tiers into one ranked
    /// list by comparing across this field).
    public let score: Float?
    /// Tiers 2/3: endpoint content snippets, capped at
    /// `GeniusLocusKit.huntSnippetLimit` — the same bound the hunter's
    /// borderline feed carries. Ordered to match drawerA/drawerB.
    /// Tier 1: nil (typed findings never carry content).
    public let sourceSnippet: String?
    public let targetSnippet: String?
    /// Tier 1: pair-order-invariant stable result identity from the
    /// sweep's `ConflictOutcome`. Tiers 2/3: nil.
    public let resultID: String?
    /// Tier 1: the coordinate digest for redacted rendering (the
    /// restricted line names the coordinate only through this digest).
    /// Tiers 2/3: nil.
    public let coordinateDigest: String?
    /// Tier 1: the sweep's per-finding sensitivity ceiling, carried
    /// through UNCHANGED (raw `AdjectiveSensitivity` value, fail-closed
    /// to `.secret` upstream when unresolvable — see
    /// `ConflictSweepCore.ceiling`). Tiers 2/3: nil — their endpoints
    /// already passed the hunter's hardcoded `.elevated` ceiling
    /// before screening.
    public let sensitivityCeilingRaw: Int?
}

// MARK: - Report

/// Which question this report answers.
public enum TieredSearchMode: Sendable, Equatable {
    /// One lane ran; its section is the whole answer. No cross-tier
    /// dedup was applied.
    case single(ContradictionTier)
    /// All three lanes ran; sections were assembled with
    /// promote-to-highest-tier dedup and over-fetch backfill.
    case synthesis
}

/// Per-lane bookkeeping. `fetched` is what the lane kept after its
/// fetch cap (K / 2K / 3K); `returned` is the section length;
/// `promotedAway` counts fetched findings removed because the same
/// pair exists at a higher tier; `backfilled` counts returned findings
/// that sat beyond the lane's first `topK` ranks and moved up because
/// earlier findings promoted away.
public struct TierLaneCounts: Sendable, Equatable {
    public let fetched: Int
    public let returned: Int
    public let promotedAway: Int
    public let backfilled: Int

    static let zero = TierLaneCounts(
        fetched: 0, returned: 0, promotedAway: 0, backfilled: 0)
}

/// Truncation and availability diagnostics — every place a bounded
/// pass may have dropped candidates is visible here, never silent.
public struct TieredSearchDiagnostics: Sendable, Equatable {
    /// False when a lexical lane ran and the estate has no registered
    /// VectorStore (the lexical lanes are honest no-ops, matching the
    /// hunter's reporting). A tier-1-only run reports true — the typed
    /// lane needs no vector store.
    public let vectorStoreAvailable: Bool
    /// Probe IDs scanned by the shared lexical retrieval pass (0 when
    /// no lexical lane ran).
    public let probesScanned: Int
    /// The typed sweep's coordinate buckets that hit the bucket cap
    /// (0 when tier 1 did not run).
    public let sweepTruncatedBuckets: Int
    /// Qualifying candidates seen per lane BEFORE the fetch cap —
    /// candidates > fetched means the cap truncated that lane.
    public let tier1Candidates: Int
    public let tier2Candidates: Int
    public let tier3Candidates: Int
    /// Tier-1 proven findings excluded by the search's sensitivity
    /// posture (ceiling above `.elevated`). Counted apart so the
    /// gate's activity is visible in the report — the same reason the
    /// typed proposal loop counts `ceilingSkipped` separately.
    public let tier1CeilingFiltered: Int

    static let empty = TieredSearchDiagnostics(
        vectorStoreAvailable: true, probesScanned: 0, sweepTruncatedBuckets: 0,
        tier1Candidates: 0, tier2Candidates: 0, tier3Candidates: 0,
        tier1CeilingFiltered: 0)
}

/// One tiered search's outcome. Deterministic for a given estate
/// state: every section is sorted on an explicit key, so retrieval
/// iteration order cannot leak into the report.
public struct TieredContradictionReport: Sendable, Equatable {
    public let mode: TieredSearchMode
    /// Per-tier sections, ALWAYS in tier order 1, 2, 3 and never
    /// interleaved — tiers are epistemic classes, and the report shape
    /// enforces that a strong tier-3 cannot outrank a weak tier-1.
    public let tier1: [TierFinding]
    public let tier2: [TierFinding]
    public let tier3: [TierFinding]
    public let tier1Counts: TierLaneCounts
    public let tier2Counts: TierLaneCounts
    public let tier3Counts: TierLaneCounts
    public let diagnostics: TieredSearchDiagnostics

    /// Section accessor keyed by tier (the sections themselves stay
    /// explicit fields so the 1-2-3 ordering is structural, not a
    /// dictionary-iteration accident).
    public func findings(for tier: ContradictionTier) -> [TierFinding] {
        switch tier {
        case .typedProven: return tier1
        case .lexicalStructural: return tier2
        case .lexicalValue: return tier3
        }
    }

    public func counts(for tier: ContradictionTier) -> TierLaneCounts {
        switch tier {
        case .typedProven: return tier1Counts
        case .lexicalStructural: return tier2Counts
        case .lexicalValue: return tier3Counts
        }
    }

    static func empty(mode: TieredSearchMode) -> TieredContradictionReport {
        TieredContradictionReport(
            mode: mode, tier1: [], tier2: [], tier3: [],
            tier1Counts: .zero, tier2Counts: .zero, tier3Counts: .zero,
            diagnostics: .empty)
    }
}

// MARK: - Pure core

/// The pure half of the tiered search: pair-key canonicalization,
/// lane ranking, fetch caps, and the synthesis assembler. Estate reads
/// happen in the verb; everything here is deterministic on its inputs
/// so tests drive it without an estate and the Rust twin mirrors
/// functions, not a verb (the `ConflictSweepCore` pattern).
public enum TieredContradictionCore {

    /// Hard ceiling on `topK` — a DoS bound, not a tuning knob. The
    /// lexical lanes over-fetch at 3×topK, so this cap bounds a single
    /// search at 150 screened findings per lane no matter what the
    /// caller (ultimately the MCP layer) asks for. Input validation is
    /// the MCP layer's job; the engine guards anyway (a7ac773eb /
    /// edbb0298b precedent: unbounded "all" modes got caps).
    public static let topKCeiling = 50

    /// Clamp a requested `topK` to the engine's bounds. Non-positive
    /// requests yield 0 — the verb answers them with a deterministic
    /// empty report rather than trapping or guessing a default.
    public static func effectiveTopK(_ requested: Int) -> Int {
        requested <= 0 ? 0 : min(requested, topKCeiling)
    }

    /// Per-tier fetch budget: tier 1 fetches exactly topK (its lane is
    /// the promotion target and never loses findings to dedup); tiers
    /// 2 and 3 over-fetch at 2× and 3× so synthesis can backfill what
    /// promotion removes. Deeper tiers over-fetch more because they
    /// sit below MORE promotion sources (tier 3 loses pairs to both
    /// tier 1 and tier 2; tier 2 only to tier 1).
    public static func fetchBudget(for tier: ContradictionTier, topK: Int) -> Int {
        topK * tier.rawValue
    }

    /// Case-canonical unordered drawer-pair key.
    ///
    /// BOTH IDs are lowercased before ordering and joining. Swift's
    /// `UUID.uuidString` is UPPERCASE while Rust's `Uuid::to_string()`
    /// is lowercase — the exact mismatch that made a Rust walk lane
    /// silently return 0 results against lowercase storage keys
    /// (precedent c95910dff). Canonicalizing case here means the same
    /// logical pair keys identically across ports and across tiers
    /// (a tier-1 key built from sweep sourceDrawerIDs matches a
    /// tier-2/3 key built from hydrated drawer IDs regardless of how
    /// either surface cased the UUID).
    ///
    /// Deliberately DISTINCT from `GeniusLocusKit.pairKey`, which is
    /// case-sensitive and already baked into settled-tunnel dedup and
    /// accepted-supersession matching — changing that key's semantics
    /// is a separate blast radius this wave does not own. This key
    /// exists only inside tiered reports and their assembly.
    public static func pairKey(_ a: String, _ b: String) -> String {
        let la = a.lowercased()
        let lb = b.lowercased()
        return la < lb ? "\(la)||\(lb)" : "\(lb)||\(la)"
    }

    /// Order an endpoint pair to match `pairKey`'s canonical ordering:
    /// case-insensitively smaller first; ties (IDs differing only by
    /// case) fall back to the raw comparison so the order is still
    /// total and deterministic.
    public static func orderedPair(_ x: String, _ y: String) -> (a: String, b: String) {
        let lx = x.lowercased()
        let ly = y.lowercased()
        if lx == ly { return x <= y ? (x, y) : (y, x) }
        return lx < ly ? (x, y) : (y, x)
    }

    /// Rank + trim the tier-1 lane. Tier 1 has NO score — proofs do
    /// not come in strengths at this surface — so the lane ranks by
    /// the most recent endpoint event time (newest first): the proof
    /// whose evidence is freshest answers "what contradicts right now"
    /// best. Event times are EPOCH SECONDS in both ports (the sweep's
    /// KI-003 identity domain) so the cross-port order agrees.
    /// Tie-break: `resultID` ascending — stable and pair-order-
    /// invariant by construction.
    ///
    /// A finding with NO resolvable endpoint event time ranks oldest
    /// (`Int64.min`): a hydration gap is not evidence of recency, and
    /// pushing unresolved findings down keeps them from crowding out
    /// findings with real timestamps. They are still returned when
    /// room remains — resolution failure redacts rank, not existence.
    public static func rankAndTrimTier1(
        _ findings: [ConflictFinding],
        eventTimeSecondsBySourceDrawer: [String: Int64],
        topK: Int
    ) -> [TierFinding] {
        let keyed = findings.map { finding -> (finding: ConflictFinding, latest: Int64) in
            let resolved = finding.outcome.sourceDrawerIDs
                .compactMap { eventTimeSecondsBySourceDrawer[$0] }
            return (finding, resolved.max() ?? Int64.min)
        }
        let ranked = keyed.sorted {
            if $0.latest != $1.latest { return $0.latest > $1.latest }
            return $0.finding.outcome.resultID < $1.finding.outcome.resultID
        }
        return ranked.prefix(topK).map { tierFinding(fromProven: $0.finding) }
    }

    /// Rank a lexical lane (tier 2 or 3): cue score descending —
    /// stronger cues first — with `pairKey` ascending as the
    /// deterministic tie-break. The retrieval pass's iteration order
    /// is NOT deterministic (see `ContradictionCandidateSet.pairs`);
    /// this sort is what makes the report reproducible.
    public static func rankLexical(_ findings: [TierFinding]) -> [TierFinding] {
        findings.sorted {
            let s0 = $0.score ?? 0
            let s1 = $1.score ?? 0
            if s0 != s1 { return s0 > s1 }
            return $0.pairKey < $1.pairKey
        }
    }

    /// Map one typed proven finding into the tier-1 report shape,
    /// carrying the sweep's sensitivity ceiling through unchanged.
    static func tierFinding(fromProven finding: ConflictFinding) -> TierFinding {
        // The evaluator always emits exactly two sorted sourceDrawerIDs
        // for a pairwise outcome; the verb guards count == 2 before
        // ranking, so the indexing here cannot trap.
        let ids = finding.outcome.sourceDrawerIDs
        let ordered = orderedPair(ids[0], ids[1])
        return TierFinding(
            tier: .typedProven,
            pairKey: pairKey(ordered.a, ordered.b),
            drawerA: ordered.a,
            drawerB: ordered.b,
            cueKind: nil,
            ruleID: finding.outcome.ruleID,
            score: nil,
            sourceSnippet: nil,
            targetSnippet: nil,
            resultID: finding.outcome.resultID,
            coordinateDigest: finding.outcome.coordinateDigest,
            sensitivityCeilingRaw: finding.sensitivityCeilingRaw)
    }

    /// The synthesis assembly: three ranked+trimmed lane lists in,
    /// three deduplicated sections out.
    public struct SynthesisAssembly: Sendable, Equatable {
        public let tier1: [TierFinding]
        public let tier2: [TierFinding]
        public let tier3: [TierFinding]
        public let tier1Counts: TierLaneCounts
        public let tier2Counts: TierLaneCounts
        public let tier3Counts: TierLaneCounts
    }

    /// Assemble the synthesis report from the three lanes' fetched
    /// lists. Pure — no I/O, unit-testable on hand-built findings.
    ///
    /// Promotion: a pair present in a higher tier's FETCHED list is
    /// removed from every lower tier's candidates. Membership is keyed
    /// on the fetched list (not just the returned window) because a
    /// tier-1-proven pair is tier-1 CLASS even when the tier-1 section
    /// is full — rendering it lower down would misstate its epistemic
    /// standing. Tier 2 only loses pairs upward to tier 1; tier 3
    /// loses to both. (With the current single-cue screen a pair
    /// cannot sit in both lexical lanes at once — `ConflictCue`
    /// returns one kind — but the assembler stays generic rather than
    /// leaning on that: the tier-2-shadows-tier-3 rule is contract,
    /// not coincidence.)
    ///
    /// Backfill: each lower tier then fills to `topK` from its own
    /// over-fetch (the 2×/3× budgets exist for exactly this), and the
    /// count of findings that moved up from beyond the first `topK`
    /// ranks is recorded per tier.
    ///
    /// Sections are returned in tier order and NEVER merged into one
    /// ranked list: tiers are epistemic classes, and a strong tier-3
    /// never outranks a weak tier-1.
    public static func assembleSynthesis(
        tier1Fetched: [TierFinding],
        tier2Fetched: [TierFinding],
        tier3Fetched: [TierFinding],
        topK: Int
    ) -> SynthesisAssembly {
        // Tier 1 — the promotion target. Fetch budget is exactly topK,
        // nothing above it removes findings, so the section is the
        // fetched list (defensively re-trimmed) with zero promotion
        // and zero backfill by construction.
        let tier1 = Array(tier1Fetched.prefix(topK))
        let tier1Counts = TierLaneCounts(
            fetched: tier1Fetched.count, returned: tier1.count,
            promotedAway: 0, backfilled: 0)

        let tier1Keys = Set(tier1Fetched.map(\.pairKey))
        let (tier2, tier2Counts) = dedupeAndBackfill(
            tier2Fetched, removing: tier1Keys, topK: topK)

        let tier12Keys = tier1Keys.union(tier2Fetched.map(\.pairKey))
        let (tier3, tier3Counts) = dedupeAndBackfill(
            tier3Fetched, removing: tier12Keys, topK: topK)

        return SynthesisAssembly(
            tier1: tier1, tier2: tier2, tier3: tier3,
            tier1Counts: tier1Counts, tier2Counts: tier2Counts,
            tier3Counts: tier3Counts)
    }

    /// One lower lane's promotion + backfill step. Ranks are the input
    /// order (the lane was ranked before trimming); `backfilled`
    /// counts survivors whose original rank sat at or beyond `topK` —
    /// the findings the over-fetch existed to hold in reserve.
    private static func dedupeAndBackfill(
        _ fetched: [TierFinding],
        removing promotedKeys: Set<String>,
        topK: Int
    ) -> ([TierFinding], TierLaneCounts) {
        var promotedAway = 0
        var kept: [(rank: Int, finding: TierFinding)] = []
        for (rank, finding) in fetched.enumerated() {
            if promotedKeys.contains(finding.pairKey) {
                promotedAway += 1
            } else {
                kept.append((rank, finding))
            }
        }
        let window = kept.prefix(topK)
        let backfilled = window.filter { $0.rank >= topK }.count
        return (
            window.map(\.finding),
            TierLaneCounts(
                fetched: fetched.count, returned: window.count,
                promotedAway: promotedAway, backfilled: backfilled))
    }
}

// MARK: - Verb

public extension GeniusLocusKit {

    /// Run one tiered contradiction search over `handle`.
    ///
    /// - Parameters:
    ///   - handle: Open estate handle.
    ///   - tier: `nil` runs synthesis (all three lanes + assembler);
    ///     a specific tier runs ONLY that lane, with no cross-tier
    ///     dedup — the purpose-run answers its own question.
    ///   - topK: Findings per returned section. Clamped to
    ///     `TieredContradictionCore.topKCeiling`; non-positive returns
    ///     an empty report deterministically.
    ///   - modelID: Embedding-model partition for the lexical
    ///     retrieval's drawer-keyed lane — same contract as
    ///     `huntContradictions`.
    ///   - probeLimit: Probe budget for the lexical retrieval pass.
    ///   - now: Deterministic clock supplied by the caller (fleet
    ///     clock discipline). The search is a pure read and files
    ///     nothing, so `now` is currently unconsumed — it is part of
    ///     the signature so the ARIA seam and any future watermarking
    ///     never need a signature break.
    func tieredContradictionSearch(
        in handle: EstateHandle,
        tier: ContradictionTier? = nil,
        topK: Int = 10,
        modelID: String = "minilm-v6",
        probeLimit: Int = 50,
        now: Date
    ) async throws -> TieredContradictionReport {
        _ = now // Read-only pass — see the parameter doc above.
        let mode: TieredSearchMode = tier.map { .single($0) } ?? .synthesis
        let effectiveK = TieredContradictionCore.effectiveTopK(topK)
        guard effectiveK > 0 else { return .empty(mode: mode) }

        let runTier1 = tier == nil || tier == .typedProven
        let runLexical = tier == nil
            || tier == .lexicalStructural || tier == .lexicalValue

        // ---- Tier 1 lane: the typed proving sweep ----
        var tier1Fetched: [TierFinding] = []
        var tier1Candidates = 0
        var tier1CeilingFiltered = 0
        var sweepTruncatedBuckets = 0
        if runTier1 {
            let sweep = try await conflictProjectionSweep(in: handle)
            sweepTruncatedBuckets = sweep.truncatedBuckets
            // Match BitmapEvaluator's default recall posture: callers
            // without an explicit sensitivity grant may only mine the Normal
            // tier (normal + elevated). Restricted/secret rows must not be
            // screened, proposed, or echoed as borderline snippets.
            // Applied here to the TYPED lane's output for the same reason
            // the typed proposal loop applies it: this verb is an
            // ungranted read surface, and even a content-free finding
            // (result id + coordinate digest + endpoint ids) discloses
            // more than the renderer's redacted line for a restricted
            // pair. The ceiling compares RAW values — never a decoded
            // tier, which coerces beyond-spec raws back to normal — and
            // the sweep's ceiling already fails closed to `.secret` on
            // any unresolvable endpoint, so a hydration gap cannot pass
            // this gate. Findings that DO pass carry their ceiling
            // through unchanged for finer-grained rendering downstream.
            let eligible = sweep.proven.filter {
                $0.outcome.sourceDrawerIDs.count == 2
                    && $0.sensitivityCeilingRaw <= AdjectiveSensitivity.elevated.rawValue
            }
            tier1CeilingFiltered = sweep.proven.count - eligible.count
            tier1Candidates = eligible.count

            // Endpoint event times for recency ranking, through the
            // same hydration seam the sweep verb itself uses (one
            // batched `hydrateBodies` — no parallel read path), in the
            // same epoch-second domain (KI-003) as the Rust twin.
            let estate = try estate(for: handle)
            let endpointIDs = Array(Set(eligible.flatMap { $0.outcome.sourceDrawerIDs }))
            var eventSeconds: [String: Int64] = [:]
            if !endpointIDs.isEmpty {
                for drawer in try await estate.hydrateBodies(ids: endpointIDs) {
                    eventSeconds[drawer.id] =
                        Int64(drawer.eventTime.timeIntervalSince1970.rounded(.down))
                }
            }
            tier1Fetched = TieredContradictionCore.rankAndTrimTier1(
                eligible,
                eventTimeSecondsBySourceDrawer: eventSeconds,
                topK: TieredContradictionCore.fetchBudget(
                    for: .typedProven, topK: effectiveK))
        }

        // ---- Tiers 2/3: ONE shared lexical retrieval pass ----
        // Factored into `lexicalTierScan` (below) so the P2.5 tier-2/3
        // proposal filing in `proposeConflictTunnels` classifies out of
        // the IDENTICAL pass — one retrieval, one cue screen, two
        // consumers.
        var scan = LexicalLaneScan.empty
        if runLexical {
            scan = try await lexicalTierScan(
                in: handle, modelID: modelID, probeLimit: probeLimit)
        }
        let tier2Ranked = scan.tier2Ranked
        let tier3Ranked = scan.tier3Ranked
        let tier2Candidates = scan.tier2Candidates
        let tier3Candidates = scan.tier3Candidates
        let probesScanned = scan.probesScanned
        let vectorStoreAvailable = scan.vectorStoreAvailable
        let tier2Fetched = Array(tier2Ranked.prefix(
            TieredContradictionCore.fetchBudget(for: .lexicalStructural, topK: effectiveK)))
        let tier3Fetched = Array(tier3Ranked.prefix(
            TieredContradictionCore.fetchBudget(for: .lexicalValue, topK: effectiveK)))

        let diagnostics = TieredSearchDiagnostics(
            vectorStoreAvailable: vectorStoreAvailable,
            probesScanned: probesScanned,
            sweepTruncatedBuckets: sweepTruncatedBuckets,
            tier1Candidates: tier1Candidates,
            tier2Candidates: tier2Candidates,
            tier3Candidates: tier3Candidates,
            tier1CeilingFiltered: tier1CeilingFiltered)

        switch mode {
        case .synthesis:
            let assembly = TieredContradictionCore.assembleSynthesis(
                tier1Fetched: tier1Fetched,
                tier2Fetched: tier2Fetched,
                tier3Fetched: tier3Fetched,
                topK: effectiveK)
            return TieredContradictionReport(
                mode: mode,
                tier1: assembly.tier1, tier2: assembly.tier2, tier3: assembly.tier3,
                tier1Counts: assembly.tier1Counts,
                tier2Counts: assembly.tier2Counts,
                tier3Counts: assembly.tier3Counts,
                diagnostics: diagnostics)

        case .single(let requested):
            // Purpose-run: this lane's top `topK`, NO cross-tier dedup.
            // A pair that is also a tier-1 proof still appears in a
            // tier-3 run — the caller asked "what tier-3 signals
            // exist", and hiding the pair because a stronger class
            // also holds it would answer a different question.
            let lane: [TierFinding]
            switch requested {
            case .typedProven: lane = tier1Fetched
            case .lexicalStructural: lane = tier2Fetched
            case .lexicalValue: lane = tier3Fetched
            }
            let returned = Array(lane.prefix(effectiveK))
            let laneCounts = TierLaneCounts(
                fetched: lane.count, returned: returned.count,
                promotedAway: 0, backfilled: 0)
            return TieredContradictionReport(
                mode: mode,
                tier1: requested == .typedProven ? returned : [],
                tier2: requested == .lexicalStructural ? returned : [],
                tier3: requested == .lexicalValue ? returned : [],
                tier1Counts: requested == .typedProven ? laneCounts : .zero,
                tier2Counts: requested == .lexicalStructural ? laneCounts : .zero,
                tier3Counts: requested == .lexicalValue ? laneCounts : .zero,
                diagnostics: diagnostics)
        }
    }
}

// MARK: - Shared lexical lane scan

/// One lexical retrieval pass's classified output — the tier-2/3 half
/// of the tiered search, factored so `tieredContradictionSearch` (the
/// read verb) and `proposeConflictTunnels` (the P2.5 filing pass)
/// consume the IDENTICAL retrieval + cue screen. `tier2Ranked` /
/// `tier3Ranked` are ranked (`rankLexical`) and UNCAPPED — each
/// consumer applies its own fetch budget.
internal struct LexicalLaneScan: Sendable {
    let vectorStoreAvailable: Bool
    let probesScanned: Int
    /// Qualifying candidates seen per lane BEFORE any cap.
    let tier2Candidates: Int
    let tier3Candidates: Int
    let tier2Ranked: [TierFinding]
    let tier3Ranked: [TierFinding]

    static let empty = LexicalLaneScan(
        vectorStoreAvailable: true, probesScanned: 0,
        tier2Candidates: 0, tier3Candidates: 0,
        tier2Ranked: [], tier3Ranked: [])
}

internal extension GeniusLocusKit {

    /// Run the shared lexical retrieval pass and classify candidates
    /// into tier-2/3 findings. Same retrieval the hunter runs (probe
    /// sampling + kNN lane + BM25 corpus lane), executed ONCE — both
    /// lexical tiers classify out of this single candidate set.
    /// Proximity uses the hunter's same 64 default (the cue screen is
    /// the precision gate; proximity only bounds the candidate set).
    /// Rust twin: `EstateCoordinator::lexical_tier_scan`.
    func lexicalTierScan(
        in handle: EstateHandle,
        modelID: String,
        probeLimit: Int
    ) async throws -> LexicalLaneScan {
        let candidates = try await contradictionCandidatePairs(
            in: handle, modelID: modelID, probeLimit: probeLimit,
            proximityThreshold: 64)

        // Batched late hydration through the hunter's same gated seam:
        // load every candidate body once.
        let estate = try estate(for: handle)
        let allIDs = Array(Set(candidates.pairs.flatMap { [$0.a, $0.b] }))
        var drawersByID: [String: Drawer] = [:]
        if !allIDs.isEmpty {
            for drawer in try await estate.hydrateBodies(ids: allIDs) {
                drawersByID[drawer.id] = drawer
            }
        }

        var tier2: [TierFinding] = []
        var tier3: [TierFinding] = []
        for pair in candidates.pairs {
            guard let a = drawersByID[pair.a], let b = drawersByID[pair.b],
                  a.tombstonedAt == nil, b.tombstonedAt == nil else { continue }
            // Match BitmapEvaluator's default recall posture: callers
            // without an explicit sensitivity grant may only mine the Normal
            // tier (normal + elevated). Restricted/secret rows must not be
            // screened, proposed, or echoed as borderline snippets.
            guard a.adjectiveSensitivity.rawValue <= AdjectiveSensitivity.elevated.rawValue,
                  b.adjectiveSensitivity.rawValue <= AdjectiveSensitivity.elevated.rawValue
            else { continue }

            let cue = ConflictCue.evaluate(a.content, b.content)
            // P1's classifier: structural cues → tier 2, value
            // divergence → tier 3, none → nil. The lexical screen never
            // yields tier 1 (proof is the typed lane's job), so an
            // unexpected mapping is dropped rather than misfiled.
            guard let cueTier = cue.kind.contradictionTier,
                  let tierClass = ContradictionTier(rawValue: cueTier),
                  tierClass != .typedProven else { continue }

            let ordered = TieredContradictionCore.orderedPair(a.id, b.id)
            let first = drawersByID[ordered.a] ?? a
            let second = drawersByID[ordered.b] ?? b
            let finding = TierFinding(
                tier: tierClass,
                pairKey: TieredContradictionCore.pairKey(a.id, b.id),
                drawerA: ordered.a,
                drawerB: ordered.b,
                cueKind: cue.kind.rawValue,
                ruleID: nil,
                score: cue.score,
                sourceSnippet: String(first.content.prefix(Self.huntSnippetLimit)),
                targetSnippet: String(second.content.prefix(Self.huntSnippetLimit)),
                resultID: nil,
                coordinateDigest: nil,
                sensitivityCeilingRaw: nil)
            switch tierClass {
            case .lexicalStructural: tier2.append(finding)
            case .lexicalValue: tier3.append(finding)
            case .typedProven: break // unreachable per the guard above
            }
        }
        return LexicalLaneScan(
            vectorStoreAvailable: candidates.vectorStoreAvailable,
            probesScanned: candidates.probeIDs.count,
            tier2Candidates: tier2.count,
            tier3Candidates: tier3.count,
            tier2Ranked: TieredContradictionCore.rankLexical(tier2),
            tier3Ranked: TieredContradictionCore.rankLexical(tier3))
    }
}
