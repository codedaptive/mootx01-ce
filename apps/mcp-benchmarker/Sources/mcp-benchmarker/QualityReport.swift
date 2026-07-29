import Foundation

// QualityReport.swift — the report the `quality` benchmark emits.
//
// It carries, per product, the aggregate retrieval metrics and the per-filter
// precision/recall, plus a head-to-head verdict per metric (which product won,
// by how much) and the bottom-line answer to "which delivers the results an AI
// wants." Codable so it round-trips to --report <path> and renders to stdout.

/// One product's filter result in the report.
struct FilterResult: Codable, Sendable {
    let testId: String          // the filter-test id (e.g. confirmation-confirmed)
    let filterExpression: String // the filter as applied (e.g. userConfirmed, wing=...)
    let precision: Double
    let recall: Double
    let f1: Double
    let returnedCount: Int
    let expectedCount: Int
    let truePositives: Int
}

/// One product's whole quality result: retrieval metrics + filter results.
struct ProductQuality: Codable, Sendable {
    let name: String
    let recallAt1: Double
    let recallAt5: Double
    let recallAt10: Double
    let mrr: Double
    let ndcgAt10: Double
    let precisionAt5: Double
    let precisionAt10: Double
    let queryCount: Int
    let filters: [FilterResult]
    /// Corpus records written + confirmed (load-pass bookkeeping).
    let writtenCount: Int
    let confirmedCount: Int

    init(name: String, retrieval: RetrievalMetrics, filters: [FilterResult],
         writtenCount: Int, confirmedCount: Int) {
        self.name = name
        self.recallAt1 = retrieval.recallAt1
        self.recallAt5 = retrieval.recallAt5
        self.recallAt10 = retrieval.recallAt10
        self.mrr = retrieval.mrr
        self.ndcgAt10 = retrieval.ndcgAt10
        self.precisionAt5 = retrieval.precisionAt5
        self.precisionAt10 = retrieval.precisionAt10
        self.queryCount = retrieval.queryCount
        self.filters = filters
        self.writtenCount = writtenCount
        self.confirmedCount = confirmedCount
    }
}

/// One head-to-head metric line: the metric name, each product's value, and the
/// winner. A "tie" winner is emitted when the values are within an epsilon.
struct HeadToHead: Codable, Sendable {
    let metric: String
    let mootValue: Double
    let contenderValue: Double
    let winner: String          // mootx01 | contender | tie

    /// Builds a head-to-head where HIGHER is better (all quality metrics are).
    /// A difference within `eps` is a tie. `eps` is small but non-zero so two
    /// numerically-equal means do not arbitrarily pick a "winner".
    static func higherWins(metric: String, moot: Double, contender: Double,
                           eps: Double = 1e-9) -> HeadToHead {
        let winner: String
        if abs(moot - contender) <= eps {
            winner = "tie"
        } else {
            winner = moot > contender ? "mootx01" : "contender"
        }
        return HeadToHead(metric: metric, mootValue: moot,
                          contenderValue: contender, winner: winner)
    }
}

/// The full quality report.
struct QualityReport: Codable, Sendable {
    /// True when only a subset of clusters was run (--limit-clusters); the
    /// renderer flags the report as a partial/validation run so a small-slice
    /// result is never mistaken for the full corpus run.
    let limitedToClusters: Int?
    let clusterCount: Int
    let articleCount: Int

    let mootx01: ProductQuality
    let contender: ProductQuality

    /// Per-retrieval-metric head-to-head (higher wins). Filter results are NOT
    /// in the head-to-head because the two products filter on DIFFERENT axes
    /// (mootx01 confirmation vs the contender's wing) that are not comparable head to
    /// head; they are reported per product instead.
    let headToHead: [HeadToHead]

    /// Notes carried into the report: which corpus filter-tests were skipped and
    /// why (sensitivity / lattice are not search-filterable on mootx01).
    let notes: [String]

    /// Encodes to pretty, key-sorted JSON for stable diffs.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func load(from url: URL) throws -> QualityReport {
        try JSONDecoder().decode(QualityReport.self, from: Data(contentsOf: url))
    }

    /// Renders a human-readable summary for stdout, ending in the bottom-line
    /// verdict: which product won the most retrieval metrics.
    func rendered() -> String {
        var out = "mcp-benchmarker quality report\n"
        if let n = limitedToClusters {
            out += String(format: "  *** PARTIAL RUN: limited to %d of %d clusters — NOT the full corpus ***\n",
                          n, clusterCount)
        }
        out += String(format: "  corpus: %d clusters, %d articles, %d queries\n",
                      clusterCount, articleCount, mootx01.queryCount)

        out += renderProduct(mootx01)
        out += renderProduct(contender)

        out += "\n  head-to-head (retrieval, higher wins):\n"
        var mootWins = 0, contenderWins = 0
        for h in headToHead {
            out += String(format: "    %@  mootx01 %.4f  vs  contender %.4f  → %@\n",
                          h.metric.padding(toLength: 14, withPad: " ", startingAt: 0) as NSString,
                          h.mootValue, h.contenderValue, h.winner as NSString)
            if h.winner == "mootx01" { mootWins += 1 }
            else if h.winner == "contender" { contenderWins += 1 }
        }

        out += "\n  filter quality (per product, axes are not comparable head-to-head):\n"
        out += renderFilters(product: mootx01)
        out += renderFilters(product: contender)

        if !notes.isEmpty {
            out += "\n  notes:\n"
            for note in notes { out += "    - \(note)\n" }
        }

        // Bottom line: the answer the mission asks for.
        out += "\n  BOTTOM LINE — which delivers the results an AI wants:\n"
        let verdict: String
        if mootWins > contenderWins {
            verdict = String(format: "    mootx01 wins %d of %d retrieval metrics.", mootWins, headToHead.count)
        } else if contenderWins > mootWins {
            verdict = String(format: "    contender wins %d of %d retrieval metrics.", contenderWins, headToHead.count)
        } else {
            verdict = String(format: "    split decision — %d–%d across %d retrieval metrics.",
                             mootWins, contenderWins, headToHead.count)
        }
        out += verdict + "\n"
        return out
    }

    private func renderProduct(_ p: ProductQuality) -> String {
        var s = String(format: "\n  [%@]  (wrote %d, confirmed %d)\n",
                       p.name as NSString, p.writtenCount, p.confirmedCount)
        s += String(format: "    recall@1=%.4f  recall@5=%.4f  recall@10=%.4f\n",
                    p.recallAt1, p.recallAt5, p.recallAt10)
        s += String(format: "    MRR=%.4f  nDCG@10=%.4f  P@5=%.4f  P@10=%.4f\n",
                    p.mrr, p.ndcgAt10, p.precisionAt5, p.precisionAt10)
        return s
    }

    private func renderFilters(product p: ProductQuality) -> String {
        guard !p.filters.isEmpty else {
            return "    [\(p.name)] no filter tests applicable\n"
        }
        var s = ""
        for f in p.filters {
            s += String(format: "    [%@] %@: P=%.4f R=%.4f F1=%.4f (tp=%d, ret=%d, exp=%d)\n",
                        p.name as NSString, f.testId as NSString,
                        f.precision, f.recall, f.f1,
                        f.truePositives, f.returnedCount, f.expectedCount)
        }
        return s
    }
}
