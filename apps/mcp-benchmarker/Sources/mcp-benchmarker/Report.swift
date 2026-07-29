import Foundation

// Report.swift — the JSON report the benchmark run emits.
//
// The report carries the three timing series (mean / p95 / sample count
// each), the two divergence aggregates, and a retained tail of the worst-
// diverging queries with their ids so a human can inspect what diverged.

/// The benchmark report. Codable so it round-trips to report.json and can be
/// reloaded by the `report` subcommand for human rendering.
struct BenchmarkReport: Codable, Sendable {

    /// One timing series summarized for the report.
    struct SeriesSummary: Codable, Sendable {
        let kind: String
        let mean: Double
        let p95: Double
        let sampleCount: Int
    }

    /// A query retained in the worst-diverging tail, with the manifest id it
    /// was probing and the rank divergence it exhibited.
    struct DivergingQuery: Codable, Sendable {
        let expectedRank1ID: String
        let rankDivergence: Double
        /// Whether the expected id was present at rank 1 on the target.
        let rankOnePresent: Bool
    }

    let capture: SeriesSummary
    let recall: SeriesSummary
    let verification: SeriesSummary
    /// The source server's recall latency, populated only by a
    /// `--compare-source` run. Its `sampleCount` is 0 on a target-only run, in
    /// which case the renderer omits the line. This is the contender side of
    /// the head-to-head latency comparison.
    let sourceRecall: SeriesSummary
    /// Aggregate Jaccard set divergence across the full expected-vs-found id
    /// sets. 0.0 = every expected item landed; 1.0 = none did.
    let jaccardSetDivergence: Double
    /// Mean rank divergence across all verification queries. 0.0 = order
    /// preserved everywhere; 1.0 = order fully reversed everywhere.
    let meanRankDivergence: Double
    let worstDivergingQueries: [DivergingQuery]

    // Custom Codable so a report.json written before `sourceRecall` existed
    // (a target-only run from an older build) still decodes, defaulting the
    // source-recall series to an empty zero-sample summary.
    private enum CodingKeys: String, CodingKey {
        case capture, recall, verification, sourceRecall
        case jaccardSetDivergence, meanRankDivergence, worstDivergingQueries
    }

    init(capture: SeriesSummary,
         recall: SeriesSummary,
         verification: SeriesSummary,
         sourceRecall: SeriesSummary,
         jaccardSetDivergence: Double,
         meanRankDivergence: Double,
         worstDivergingQueries: [DivergingQuery]) {
        self.capture = capture
        self.recall = recall
        self.verification = verification
        self.sourceRecall = sourceRecall
        self.jaccardSetDivergence = jaccardSetDivergence
        self.meanRankDivergence = meanRankDivergence
        self.worstDivergingQueries = worstDivergingQueries
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.capture = try c.decode(SeriesSummary.self, forKey: .capture)
        self.recall = try c.decode(SeriesSummary.self, forKey: .recall)
        self.verification = try c.decode(SeriesSummary.self, forKey: .verification)
        self.sourceRecall = try c.decodeIfPresent(SeriesSummary.self, forKey: .sourceRecall)
            ?? SeriesSummary(kind: TimingSeriesKind.sourceRecall.rawValue,
                             mean: 0, p95: 0, sampleCount: 0)
        self.jaccardSetDivergence = try c.decode(Double.self, forKey: .jaccardSetDivergence)
        self.meanRankDivergence = try c.decode(Double.self, forKey: .meanRankDivergence)
        self.worstDivergingQueries = try c.decode([DivergingQuery].self, forKey: .worstDivergingQueries)
    }

    /// Builds a series summary from a timing series.
    static func summary(for kind: TimingSeriesKind, from timing: TimingCollection) -> SeriesSummary {
        let series = timing.series(kind)
        return SeriesSummary(kind: kind.rawValue,
                             mean: series.mean,
                             p95: series.p95,
                             sampleCount: series.count)
    }

    /// Encodes the report to pretty-printed, key-sorted JSON for stable
    /// diffs across runs.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Loads a report from a report.json file.
    static func load(from url: URL) throws -> BenchmarkReport {
        try JSONDecoder().decode(BenchmarkReport.self, from: Data(contentsOf: url))
    }

    /// Renders the report as a human-readable summary for stdout.
    func rendered() -> String {
        func line(_ s: SeriesSummary) -> String {
            // Latencies are in seconds; show milliseconds for readability.
            // Pad the label explicitly — %@ does not honor a width flag on
            // Darwin Foundation, so manual padding keeps the columns aligned.
            let label = s.kind.padding(toLength: 13, withPad: " ", startingAt: 0)
            return String(format: "  %@ mean %8.2f ms   p95 %8.2f ms   n=%d",
                          label as NSString, s.mean * 1000, s.p95 * 1000, s.sampleCount)
        }
        var out = "mcp-benchmarker report\n"
        out += line(capture) + "\n"
        out += line(recall) + "\n"
        out += line(verification) + "\n"
        // sourceRecall only appears for a --compare-source run; on a target-
        // only run it has zero samples, so omit it rather than show a 0 ms row.
        if sourceRecall.sampleCount > 0 {
            out += line(sourceRecall) + "\n"
            // Head-to-head latency call-out: target recall vs source recall.
            let speedup = sourceRecall.mean > 0 ? sourceRecall.mean / max(recall.mean, 1e-12) : 0
            out += String(format: "  recall speedup (source/target mean): %.2fx\n", speedup)
        }
        out += String(format: "  jaccard set divergence:  %.4f\n", jaccardSetDivergence)
        out += String(format: "  mean rank divergence:    %.4f\n", meanRankDivergence)
        if !worstDivergingQueries.isEmpty {
            out += "  worst-diverging queries:\n"
            for q in worstDivergingQueries {
                out += String(format: "    id=%@  rankDiv=%.4f  rank1=%@\n",
                              q.expectedRank1ID as NSString,
                              q.rankDivergence,
                              (q.rankOnePresent ? "yes" : "no") as NSString)
            }
        }
        return out
    }
}
