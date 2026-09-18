import Foundation

// GauntletReport.swift — aggregation + rendering of a gauntlet run (Phase 2.2).
//
// A run produces, per STRATEGY COLUMN (the injected baseline's search when
// present; mootx01 raw / rrf / matrixAware; the precise composition grid), a
// set of per-needle NeedleScores. This file aggregates those
// into the per-tier and per-strategy tables the plan requires (line 136) and
// renders the human report. The report header is extensible: a lane may
// inject a headerEpilogue (a two-endpoint extension lane uses this
// to add its evaluation header); moot-only runs render without one. The
// worst-10-failures appendix retains full request/response.
//
// Aggregation is pure: it consumes NeedleScores and emits numbers. No live
// contact, no Date() — the run label (a fixed date string) is passed in by the
// CLI so the report path and header are deterministic.

/// The aggregate for one strategy over one tier (or over ALL tiers when `tier`
/// is nil): mean found@k, MRR, mean completeness, mean contamination, and
/// latency mean/p95. The hard-gate fields are means over the needles in scope.
public struct StrategyTierAggregate: Sendable, Equatable {
    /// nil = aggregate across every tier (the per-strategy overall row).
    public let tier: NoiseTier?
    public let needleCount: Int
    /// Mean found@k (fraction of needles found within k), keyed by k.
    public let foundAtK: [Int: Double]
    /// Mean reciprocal rank (MRR) over the needles in scope.
    public let mrr: Double
    /// Mean completeness (fraction of needles whose full record byte-matched).
    public let completeness: Double
    /// Mean contamination (distractors per needle in top-k).
    public let meanContamination: Double
    public let latencyMeanSeconds: Double
    public let latencyP95Seconds: Double

    /// Builds the aggregate from a slice of per-needle scores.
    public static func from(tier: NoiseTier?, scores: [NeedleScore], kValues: [Int]) -> StrategyTierAggregate {
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
public struct StrategyResult: Sendable {
    /// The column name, e.g. "mootx01:raw", "mootx01:rrf", "precise:text",
    /// or the injected baseline column's name when one was supplied.
    public let name: String
    /// Whether this column is a mootx01 strategy (distinguishes moot columns
    /// from an injected baseline column in downstream evaluation).
    public let isMootx01: Bool
    public let scores: [NeedleScore]
    public let perTier: [StrategyTierAggregate]
    public let overall: StrategyTierAggregate

    public static func build(name: String, isMootx01: Bool, scores: [NeedleScore],
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
public struct RetainedFailure: Sendable {
    public let strategyName: String
    public let needleID: String
    public let tier: NoiseTier
    public let query: String
    /// The full JSON-RPC request sent (pretty string).
    public let request: String
    /// The full raw response text the backend returned.
    public let response: String
    /// Why it is a failure: not found at the deepest k, or incomplete.
    public let reason: String
    /// A sort key — higher is worse. Failures are sorted descending by severity
    /// so the worst are surfaced first. Used to pick the worst 10.
    public let severity: Double
}

/// The complete gauntlet run report.
public struct GauntletRunReport: Sendable {
    public let seed: UInt64
    public let runLabel: String
    public let kValues: [Int]
    public let distractorsPerNeedle: Int
    public let tierCounts: [NoiseTier: Int]
    public let strategies: [StrategyResult]
    /// Up to ten retained worst failures across all strategies.
    public let worstFailures: [RetainedFailure]
    /// True when the DegeneracyGuard ran and returned healthy for every backend.
    /// A guard refusal aborts before a report is built, so a built report always
    /// has this true — it is recorded for the header so the artifact states it.
    public let guardHealthy: Bool
    /// When true, the precise-recall composition columns were skipped (--quick).
    /// The rendered header carries a clear banner so a quick-mode artifact is
    /// never mistaken for a full ablation run.
    public var quickMode: Bool = false


    /// A caller-supplied block rendered between the header and the per-tier
    /// tables (a caller supplying a baseline column inserts its evaluation text
    /// here; a moot-only run leaves it empty and the report renders without it).
    public var headerEpilogue: String = ""

    public init(seed: UInt64, runLabel: String, kValues: [Int],
                distractorsPerNeedle: Int, tierCounts: [NoiseTier: Int],
                strategies: [StrategyResult], worstFailures: [RetainedFailure],
                guardHealthy: Bool, quickMode: Bool = false) {
        self.seed = seed
        self.runLabel = runLabel
        self.kValues = kValues
        self.distractorsPerNeedle = distractorsPerNeedle
        self.tierCounts = tierCounts
        self.strategies = strategies
        self.worstFailures = worstFailures
        self.guardHealthy = guardHealthy
        self.quickMode = quickMode
    }

    // MARK: — Provenance (stale-report detection)

    /// The git SHA of the repo at the time this run was produced. Set to
    /// "unknown" when the working directory has no git history (e.g. a
    /// distribution zip). A SHA mismatch between the report and the current HEAD
    /// is the signal that a report is stale relative to the code under test.
    public var gitSHA: String = "unknown"
    /// Dirty (modified/staged/untracked) path count in the working tree at run
    /// time. "Right commit, dirty half-applied worker" is a real repo state —
    /// provenance must say so. -1 = git unavailable; nil = not recorded.
    public var gitDirtyCount: Int? = nil
    /// ISO8601 timestamp at which the run was started. Passed in from the CLI
    /// so the report itself is deterministic and testable.
    public var runTimestamp: String = ""
    /// The full list of column names that were evaluated in this run, in
    /// enumeration order. Self-describing: presence of "dense-fused" and absence
    /// of the removed "vector" alias makes the column set readable from the JSON
    /// artifact without re-running the benchmarker.
    public var columnsRun: [String] = []
    /// The composition names from GauntletRunner.compositionNames at the time of
    /// the run. Records which exact ablation grid was active so an artifact can
    /// be matched back to the grid it measured, even if the grid has since changed.
    public var compositionListVersion: [String] = []
    // MARK: Machine provenance (additive — JB-01)
    /// Machine profile and mootx01 version captured at run start. Set post-init
    /// by the caller (same pattern as gitSHA / headerEpilogue). Nil when not set.
    public var runEnvironment: RunEnvironment? = nil

    // MARK: Lane standard fields (C1/C4/C5/C6 — benchmark reset 2026-08-13)

    /// Estate storage shape for this run: "disk" (SQLite, default) or "ram"
    /// (--in-memory, C1). Set post-init from the CLI's --shape flag.
    public var shape: String = "disk"

    /// How the DegeneracyGuard was sampled during this run. "once" = the guard
    /// probed the backend once before scoring began (C5; the gauntlet's guard is
    /// structurally once-per-run — one estate, one probe batch). Set post-init.
    public var guardSampling: String = "once"

    /// Effective parallel units for this run. Always 1 for the gauntlet: the run
    /// shares one mootx01 process and one MCP connection; concurrent MCP calls to
    /// a single stdio connection are not safe. C6 is documented as serial-stays for
    /// this lane. Set post-init.
    public var parallelUnits: Int = 1

    /// The moot_timing_report text sampled from the estate at the run's settle
    /// point (after load + dream, before needle scoring). Nil when the tool was
    /// unavailable or the capture failed (capture failures never abort the run —
    /// C4 is observability, not a gate). Set inside GauntletRunner.run().
    public var timingReport: String? = nil

    /// How the timing report was sampled. "once-per-run" for the gauntlet: a
    /// single shared estate means one settle point covers the whole run (as
    /// opposed to the per-unit-estate lanes which sample once-per-leg).
    public var timingSampling: String = "once-per-run"

    /// The estate manifest `schema_version` for artifacts in this run.
    /// Per BENCHMARK_PROTOCOL §9 this appears in every report header so the
    /// historical table can carry the column and old vs new schema artifacts
    /// are unambiguously identified. Defaults to `currentEstateSchemaVersion`
    /// (the compile-time constant) and is carried as a field so callers can
    /// override it when replaying a report from a stored artifact.
    public var estateSchemaVersion: String = currentEstateSchemaVersion

    /// Renders the full human report (header + per-tier tables + per-strategy
    /// aggregate + worst-10 appendix).
    public func rendered() -> String {
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
        out += "shape:                \(shape)\n"
        out += "parallel units:       \(parallelUnits) (serial — shared backend, single MCP connection)\n"
        out += "DegeneracyGuard:      \(guardHealthy ? "HEALTHY (ran on every backend)" : "NOT HEALTHY") [\(guardSampling)]\n"
        // Column inventory — lets a reader verify the full set without re-running.
        let colLine = columnsRun.isEmpty ? "(not recorded)" : columnsRun.joined(separator: ", ")
        out += "columns run:          \(colLine)\n"
        // Composition list version — identifies the exact ablation grid measured.
        let compLine = compositionListVersion.isEmpty
            ? "(not recorded)"
            : compositionListVersion.joined(separator: ", ")
        out += "composition grid:     \(compLine)\n"
        // Per BENCHMARK_PROTOCOL §9: estate schema version in every report
        // header so the historical table carries the column.
        out += "estate schema ver:    \(estateSchemaVersion)\n"
        // Caller-supplied evaluation text, when one was given. A
        // moot-only run has no epilogue and renders straight into the tables.
        if !headerEpilogue.isEmpty {
            out += "\n" + headerEpilogue + "\n\n"
        } else {
            out += "\n"
        }

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
