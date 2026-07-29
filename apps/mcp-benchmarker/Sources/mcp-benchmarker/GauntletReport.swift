import Foundation

// GauntletReport.swift — aggregation + rendering of a gauntlet run (Phase 2.2).
//
// A run produces, per STRATEGY COLUMN (contender search; mootx01 raw / rrf /
// matrixAware), a set of per-needle NeedleScores. This file aggregates those
// into the per-tier and per-strategy tables the plan requires (line 136) and
// renders the human report, including the verbatim "Definition of superior"
// header (plan lines 139-141) and the worst-10-failures appendix with full
// request/response retained.
//
// Aggregation is pure: it consumes NeedleScores and emits numbers. No live
// contact, no Date() — the run label (a fixed date string) is passed in by the
// CLI so the report path and header are deterministic.

/// The aggregate for one strategy over one tier (or over ALL tiers when `tier`
/// is nil): mean found@k, MRR, mean completeness, mean contamination, and
/// latency mean/p95. The hard-gate fields are means over the needles in scope.
struct StrategyTierAggregate: Sendable, Equatable {
    /// nil = aggregate across every tier (the per-strategy overall row).
    let tier: NoiseTier?
    let needleCount: Int
    /// Mean found@k (fraction of needles found within k), keyed by k.
    let foundAtK: [Int: Double]
    /// Mean reciprocal rank (MRR) over the needles in scope.
    let mrr: Double
    /// Mean completeness (fraction of needles whose full record byte-matched).
    let completeness: Double
    /// Mean contamination (distractors per needle in top-k).
    let meanContamination: Double
    let latencyMeanSeconds: Double
    let latencyP95Seconds: Double

    /// Builds the aggregate from a slice of per-needle scores.
    static func from(tier: NoiseTier?, scores: [NeedleScore], kValues: [Int]) -> StrategyTierAggregate {
        let n = scores.count
        guard n > 0 else {
            var zeros: [Int: Double] = [:]
            for k in kValues { zeros[k] = 0 }
            return StrategyTierAggregate(tier: tier, needleCount: 0, foundAtK: zeros,
                                         mrr: 0, completeness: 0, meanContamination: 0,
                                         latencyMeanSeconds: 0, latencyP95Seconds: 0)
        }
        var found: [Int: Double] = [:]
        for k in kValues {
            let hits = scores.reduce(0) { $0 + (($1.foundAtK[k] ?? false) ? 1 : 0) }
            found[k] = Double(hits) / Double(n)
        }
        let mrr = scores.reduce(0.0) { $0 + $1.reciprocalRank } / Double(n)
        let completeness = scores.reduce(0.0) { $0 + $1.completeness } / Double(n)
        let contamination = scores.reduce(0.0) { $0 + Double($1.contamination) } / Double(n)
        let latencies = scores.map(\.latencySeconds).sorted()
        let latMean = latencies.reduce(0, +) / Double(n)
        // p95 by nearest-rank on the sorted samples (same convention as Timing).
        let p95Index = min(latencies.count - 1, Int((Double(latencies.count) * 0.95).rounded(.up)) - 1)
        let latP95 = latencies[max(0, p95Index)]
        return StrategyTierAggregate(tier: tier, needleCount: n, foundAtK: found,
                                     mrr: mrr, completeness: completeness,
                                     meanContamination: contamination,
                                     latencyMeanSeconds: latMean, latencyP95Seconds: latP95)
    }
}

/// One strategy column's full result: its name, every per-needle score, and the
/// per-tier + overall aggregates.
struct StrategyResult: Sendable {
    /// The column name, e.g. "contender", "mootx01:raw", "mootx01:rrf",
    /// "mootx01:matrixAware".
    let name: String
    /// Whether this column is a mootx01 strategy (used by the superiority check
    /// to identify mootx01's best column vs the contender baseline).
    let isMootx01: Bool
    let scores: [NeedleScore]
    let perTier: [StrategyTierAggregate]
    let overall: StrategyTierAggregate

    static func build(name: String, isMootx01: Bool, scores: [NeedleScore],
                      kValues: [Int]) -> StrategyResult {
        var perTier: [StrategyTierAggregate] = []
        for tier in NoiseTier.allCases {
            let slice = scores.filter { $0.tier == tier }
            if slice.isEmpty { continue }
            perTier.append(.from(tier: tier, scores: slice, kValues: kValues))
        }
        let overall = StrategyTierAggregate.from(tier: nil, scores: scores, kValues: kValues)
        return StrategyResult(name: name, isMootx01: isMootx01, scores: scores,
                              perTier: perTier, overall: overall)
    }
}

/// A retained worst-case failure: the needle, the strategy that failed it, and
/// the full request/response kept for inspection (plan line 137).
struct RetainedFailure: Sendable {
    let strategyName: String
    let needleID: String
    let tier: NoiseTier
    let query: String
    /// The full JSON-RPC request sent (pretty string).
    let request: String
    /// The full raw response text the backend returned.
    let response: String
    /// Why it is a failure: not found at the deepest k, or incomplete.
    let reason: String
    /// A sort key — higher is worse. Failures are sorted descending by severity
    /// so the worst are surfaced first. Used to pick the worst 10.
    let severity: Double
}

/// The complete gauntlet run report.
struct GauntletRunReport: Sendable {
    let seed: UInt64
    let runLabel: String
    let kValues: [Int]
    let distractorsPerNeedle: Int
    let tierCounts: [NoiseTier: Int]
    let strategies: [StrategyResult]
    /// Up to ten retained worst failures across all strategies.
    let worstFailures: [RetainedFailure]
    /// True when the DegeneracyGuard ran and returned healthy for every backend.
    /// A guard refusal aborts before a report is built, so a built report always
    /// has this true — it is recorded for the header so the artifact states it.
    let guardHealthy: Bool
    /// When true, the precise-recall composition columns were skipped (--quick).
    /// The rendered header carries a clear banner so a quick-mode artifact is
    /// never mistaken for a full ablation run.
    var quickMode: Bool = false

    // MARK: — Provenance (stale-report detection)

    /// The git SHA of the repo at the time this run was produced. Set to
    /// "unknown" when the working directory has no git history (e.g. a
    /// distribution zip). A SHA mismatch between the report and the current HEAD
    /// is the signal that a report is stale relative to the code under test.
    var gitSHA: String = "unknown"
    /// Dirty (modified/staged/untracked) path count in the working tree at run
    /// time. "Right commit, dirty half-applied worker" is a real repo state —
    /// provenance must say so. -1 = git unavailable; nil = not recorded.
    var gitDirtyCount: Int? = nil
    /// ISO8601 timestamp at which the run was started. Passed in from the CLI
    /// so the report itself is deterministic and testable.
    var runTimestamp: String = ""
    /// The full list of column names that were evaluated in this run, in
    /// enumeration order. Self-describing: presence of "dense-fused" and absence
    /// of the removed "vector" alias makes the column set readable from the JSON
    /// artifact without re-running the benchmarker.
    var columnsRun: [String] = []
    /// The composition names from GauntletRunner.compositionNames at the time of
    /// the run. Records which exact ablation grid was active so an artifact can
    /// be matched back to the grid it measured, even if the grid has since changed.
    var compositionListVersion: [String] = []

    /// The verbatim definition-of-superior text (plan lines 139-141). Public and
    /// constant so the header always carries it word-for-word.
    static let definitionOfSuperior =
        "Definition of superior: mootx01's best strategy wins or ties the contender baseline "
        + "on found@k, MRR, and completeness on EVERY tier, with strictly better "
        + "contamination or latency, before any claim is made."

    /// Evaluates the definition-of-superior against the aggregates and returns a
    /// human verdict line. mootx01's BEST column (by overall found@1) is compared
    /// against the contender column tier by tier. This is a measurement, not a
    /// claim generator — it states whether the bar is met, and if not, why.
    func superiorityVerdict() -> String {
        guard let baseline = strategies.first(where: { !$0.isMootx01 }) else {
            return "superiority: NOT EVALUABLE — no contender baseline column present"
        }
        let mootColumns = strategies.filter(\.isMootx01)
        guard !mootColumns.isEmpty else {
            return "superiority: NOT EVALUABLE — no mootx01 columns present"
        }
        // mootx01's best column by overall found@1 (the hard gate's primary axis).
        let best = mootColumns.max { a, b in
            (a.overall.foundAtK[1] ?? 0) < (b.overall.foundAtK[1] ?? 0)
        }!

        // Per-tier check: best must WIN OR TIE on found@k (every k), MRR, and
        // completeness on EVERY tier.
        var failingTiers: [String] = []
        for tier in NoiseTier.allCases {
            guard let bAgg = best.perTier.first(where: { $0.tier == tier }),
                  let mAgg = baseline.perTier.first(where: { $0.tier == tier }) else { continue }
            var tierLost = false
            for k in kValues where (bAgg.foundAtK[k] ?? 0) < (mAgg.foundAtK[k] ?? 0) - 1e-9 {
                tierLost = true
            }
            if bAgg.mrr < mAgg.mrr - 1e-9 { tierLost = true }
            if bAgg.completeness < mAgg.completeness - 1e-9 { tierLost = true }
            if tierLost { failingTiers.append(tier.rawValue) }
        }
        if !failingTiers.isEmpty {
            return "superiority: NOT MET — mootx01 best column '\(best.name)' is beaten by "
                + "contender on tier(s) \(failingTiers.joined(separator: ", ")) "
                + "(found@k / MRR / completeness). No claim may be made."
        }
        // Tie-or-win on every tier met. Now require STRICTLY better contamination
        // OR latency overall.
        let betterContam = best.overall.meanContamination < baseline.overall.meanContamination - 1e-9
        let betterLatency = best.overall.latencyP95Seconds < baseline.overall.latencyP95Seconds - 1e-9
        if betterContam || betterLatency {
            let edge = betterContam ? "contamination" : "latency"
            return "superiority: MET — mootx01 best column '\(best.name)' ties-or-wins every tier on "
                + "found@k/MRR/completeness AND is strictly better on \(edge)."
        }
        return "superiority: NOT MET — mootx01 best column '\(best.name)' ties-or-wins every tier but "
            + "is not strictly better on contamination OR latency. No claim may be made."
    }

    /// Renders the full human report (header + per-tier tables + per-strategy
    /// aggregate + worst-10 appendix).
    func rendered() -> String {
        var out = ""
        out += "================ MOOT RETRIEVAL GAUNTLET — v1 ================\n"
        if quickMode {
            out += "⚠  QUICK MODE — precise ablation grid skipped (composition columns omitted)\n"
            out += "   Re-run without --quick for the full ablation grid (~25 min).\n\n"
        }
        out += "seed:                 \(seed)\n"
        out += "run label:            \(runLabel)\n"
        // Provenance block — makes every artifact self-describing for stale-report detection.
        out += "git SHA:              \(gitSHA)\n"
        let dirtyDesc: String
        switch gitDirtyCount {
        case .none: dirtyDesc = "(not recorded)"
        case .some(-1): dirtyDesc = "unknown (git unavailable)"
        case .some(0):  dirtyDesc = "CLEAN"
        case .some(let n): dirtyDesc = "DIRTY (\(n) paths) — source may not match the SHA above"
        }
        out += "working tree:         \(dirtyDesc)\n"
        out += "run timestamp:        \(runTimestamp.isEmpty ? "(not set)" : runTimestamp)\n"
        out += "found@k depths:       \(kValues.map(String.init).joined(separator: ", "))\n"
        out += "distractors/needle:   \(distractorsPerNeedle)\n"
        let tierProfile = NoiseTier.allCases
            .compactMap { t in (tierCounts[t]).map { "\(t.rawValue)=\($0)" } }
            .joined(separator: " ")
        out += "tier profile:         \(tierProfile)\n"
        out += "DegeneracyGuard:      \(guardHealthy ? "HEALTHY (ran on every backend)" : "NOT HEALTHY")\n"
        // Column inventory — lets a reader verify the full set without re-running.
        let colLine = columnsRun.isEmpty ? "(not recorded)" : columnsRun.joined(separator: ", ")
        out += "columns run:          \(colLine)\n"
        // Composition list version — identifies the exact ablation grid measured.
        let compLine = compositionListVersion.isEmpty
            ? "(not recorded)"
            : compositionListVersion.joined(separator: ", ")
        out += "composition grid:     \(compLine)\n"
        out += "\n" + Self.definitionOfSuperior + "\n\n"
        out += superiorityVerdict() + "\n\n"

        // Per-tier table: one block per tier, every strategy as a row.
        out += "---------------- PER-TIER RESULTS ----------------\n"
        for tier in NoiseTier.allCases {
            let hasTier = strategies.contains { $0.perTier.contains { $0.tier == tier } }
            if !hasTier { continue }
            out += "\nTier \(tier.rawValue):\n"
            out += rowHeader()
            for s in strategies {
                if let agg = s.perTier.first(where: { $0.tier == tier }) {
                    out += row(name: s.name, agg: agg)
                }
            }
        }

        // Per-strategy aggregate (across all tiers).
        out += "\n---------------- PER-STRATEGY AGGREGATE (all tiers) ----------------\n"
        out += rowHeader()
        for s in strategies {
            out += row(name: s.name, agg: s.overall)
        }

        // The ablation LEADERBOARD: per tier and aggregate, every column ranked
        // by found@1 (the precision gap's primary axis), then MRR, then
        // found@10, with the tier's winning column named. This is the ablation's
        // answer — reality's ranking of the compositions, not a guess.
        out += "\n" + leaderboard()

        // Worst-10 failures appendix.
        out += "\n---------------- WORST 10 FAILURES (full request/response retained) ----------------\n"
        if worstFailures.isEmpty {
            out += "(none — every needle was found and complete on every strategy)\n"
        }
        for (i, f) in worstFailures.enumerated() {
            out += "\n[\(i + 1)] strategy=\(f.strategyName) needle=\(f.needleID) tier=\(f.tier.rawValue) "
                + "reason=\(f.reason)\n"
            out += "    query:    \(f.query)\n"
            out += "    request:  \(f.request)\n"
            out += "    response: \(truncateForLog(f.response))\n"
        }
        out += "\n=============================================================\n"
        return out
    }

    /// Render the ablation leaderboard: for each tier T1-T5 and the aggregate,
    /// every column ranked descending by (found@1, MRR, found@10), with the
    /// winning column named. The ranking key is lexicographic — found@1 leads
    /// (the precision gap's primary axis), MRR breaks found@1 ties, found@10
    /// breaks those; the column name is the final deterministic tie-break so the
    /// ordering is stable run-to-run. This is the ablation's output: an
    /// enumeration ranked by reality, keeping every composition.
    private func leaderboard() -> String {
        var out = "---------------- ABLATION LEADERBOARD (ranked by found@1, then MRR, then found@10) ----------------\n"
        let deepest = kValues.max() ?? 10

        // Build the per-tier blocks, then the aggregate block.
        var blocks: [(label: String, rows: [(name: String, agg: StrategyTierAggregate)])] = []
        for tier in NoiseTier.allCases {
            var rows: [(String, StrategyTierAggregate)] = []
            for s in strategies {
                if let agg = s.perTier.first(where: { $0.tier == tier }) {
                    rows.append((s.name, agg))
                }
            }
            if !rows.isEmpty { blocks.append(("Tier \(tier.rawValue)", rows)) }
        }
        blocks.append(("AGGREGATE (all tiers)", strategies.map { ($0.name, $0.overall) }))

        for block in blocks {
            let ranked = block.rows.sorted { lhs, rhs in
                let l = lhs.1, r = rhs.1
                let lf1 = l.foundAtK[1] ?? 0, rf1 = r.foundAtK[1] ?? 0
                if abs(lf1 - rf1) > 1e-9 { return lf1 > rf1 }
                if abs(l.mrr - r.mrr) > 1e-9 { return l.mrr > r.mrr }
                let lfd = l.foundAtK[deepest] ?? 0, rfd = r.foundAtK[deepest] ?? 0
                if abs(lfd - rfd) > 1e-9 { return lfd > rfd }
                return lhs.0 < rhs.0   // deterministic name tie-break
            }
            out += "\n\(block.label) — winner: \(ranked.first?.name ?? "(none)")\n"
            out += "  rank  " + rowHeader().drop(while: { $0 == " " })
            for (i, entry) in ranked.enumerated() {
                out += String(format: "  %2d. ", i + 1) + row(name: entry.name, agg: entry.1).drop(while: { $0 == " " })
            }
        }
        return out
    }

    private func rowHeader() -> String {
        var h = "  strategy".padding(toLength: 26, withPad: " ", startingAt: 0)
        for k in kValues { h += "f@\(k)".padding(toLength: 8, withPad: " ", startingAt: 0) }
        h += "MRR".padding(toLength: 8, withPad: " ", startingAt: 0)
        h += "compl".padding(toLength: 8, withPad: " ", startingAt: 0)
        h += "contam".padding(toLength: 8, withPad: " ", startingAt: 0)
        h += "lat_ms".padding(toLength: 9, withPad: " ", startingAt: 0)
        h += "p95_ms\n"
        return h
    }

    private func row(name: String, agg: StrategyTierAggregate) -> String {
        var r = "  \(name)".padding(toLength: 26, withPad: " ", startingAt: 0)
        for k in kValues {
            r += String(format: "%.2f", agg.foundAtK[k] ?? 0).padding(toLength: 8, withPad: " ", startingAt: 0)
        }
        r += String(format: "%.3f", agg.mrr).padding(toLength: 8, withPad: " ", startingAt: 0)
        r += String(format: "%.2f", agg.completeness).padding(toLength: 8, withPad: " ", startingAt: 0)
        r += String(format: "%.2f", agg.meanContamination).padding(toLength: 8, withPad: " ", startingAt: 0)
        r += String(format: "%.1f", agg.latencyMeanSeconds * 1000).padding(toLength: 9, withPad: " ", startingAt: 0)
        r += String(format: "%.1f", agg.latencyP95Seconds * 1000) + "\n"
        return r
    }

    /// Bounds a retained response in the rendered text so the report stays
    /// readable; the full untruncated response lives in the JSON sidecar.
    private func truncateForLog(_ s: String) -> String {
        let oneLine = s.replacingOccurrences(of: "\n", with: " ⏎ ")
        return oneLine.count > 400 ? String(oneLine.prefix(400)) + " …[truncated]" : oneLine
    }
}
