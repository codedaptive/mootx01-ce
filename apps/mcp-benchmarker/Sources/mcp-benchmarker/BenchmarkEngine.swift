import Foundation

// BenchmarkEngine.swift — verifies the manifest against the target and
// scores both divergence axes.
//
// For each verification query (one per transferred manifest entry):
//   - query the target, timing into the recall series;
//   - confirm the expected id is present and at rank 1, timing the
//     confirmation into the verification series;
//   - accumulate the found ids for the aggregate Jaccard set divergence;
//   - optionally query the source for the same probe and score rank
//     divergence between the source's and target's rankings.
//
// The manifest is the ground truth: "did this item land and rank" is judged
// against the manifest's expected rank-1 id, not against the source's live
// state at benchmark time.
//
// CROSS-SERVER ID ASYMMETRY (the head-to-head reality): the source and target
// mint ids in disjoint spaces — the contender's `search` returns no id at all, and
// the target assigns its own UUID on write. So source-vs-target rank
// divergence cannot be scored by id. When `--compare-source` is set, the
// rank comparison is therefore computed over the recall CONTENT order
// (normalized text) rather than ids, which is the only identity shared across
// the two servers' search results. The source query is still timed every
// probe so the report shows source recall latency for the head-to-head.

/// Verifies a transfer and produces the benchmark report.
struct BenchmarkEngine {
    let source: MCPClient
    let target: MCPClient
    let sourceVerbs: EndpointConfig.VerbMap
    let targetVerbs: EndpointConfig.VerbMap
    /// When true, also query the source per probe to compute source-vs-target
    /// rank divergence. When false, rank divergence is scored against the
    /// manifest's single expected rank-1 id only.
    let compareSourceRanking: Bool
    /// How many worst-diverging queries to retain in the report tail.
    let worstQueryRetention: Int

    init(source: MCPClient,
         target: MCPClient,
         sourceVerbs: EndpointConfig.VerbMap,
         targetVerbs: EndpointConfig.VerbMap,
         compareSourceRanking: Bool = false,
         worstQueryRetention: Int = 10) {
        self.source = source
        self.target = target
        self.sourceVerbs = sourceVerbs
        self.targetVerbs = targetVerbs
        self.compareSourceRanking = compareSourceRanking
        self.worstQueryRetention = worstQueryRetention
    }

    /// Runs the benchmark over the manifest's verification queries.
    func run(manifest: Manifest) async throws -> BenchmarkReport {
        var timing = TimingCollection()
        // Seed the capture series from the manifest, where the transfer
        // subcommand persisted the per-write capture latencies.
        for latency in manifest.captureLatencies {
            timing.record(latency, into: .capture)
        }
        let queries = manifest.verificationQueries(verbMap: targetVerbs)

        // Expected set: every transferred id the manifest claims should be
        // recoverable on the target.
        let expectedIDs = Set(queries.map(\.expectedRank1ID))
        var foundIDs = Set<String>()

        var rankDivergences: [Double] = []
        var diverging: [BenchmarkReport.DivergingQuery] = []

        for query in queries {
            // Recall: time the target query. Build the query argument from the
            // target verbMap's query key and parse via its result format.
            let recallStart = DispatchTime.now()
            let targetResult = try await target.callTool(
                query.queryTool,
                arguments: [targetVerbs.queryArg: .string(query.queryText)],
                format: targetVerbs.resultFormat)
            timing.record(elapsedSeconds(since: recallStart), into: .recall)

            // Verification: time the confirmation that the expected id is
            // present and at rank 1.
            let verifyStart = DispatchTime.now()
            let targetIDs = targetResult.orderedIDs
            let rankOnePresent = targetIDs.first == query.expectedRank1ID
            if targetIDs.contains(query.expectedRank1ID) {
                foundIDs.insert(query.expectedRank1ID)
            }
            timing.record(elapsedSeconds(since: verifyStart), into: .verification)

            // Rank divergence. Source and target mint ids in disjoint spaces,
            // so when comparing the source the order identity is recall CONTENT
            // (normalized), not id. Without comparison, the reference is the
            // manifest's single expected rank-1 id against the target ids.
            let divergence: Double
            if compareSourceRanking {
                // Time the source query for the head-to-head latency, then
                // compare content order between the two servers' recall.
                let sourceStart = DispatchTime.now()
                let sourceResult = try await source.callTool(
                    sourceVerbs.query,
                    arguments: [sourceVerbs.queryArg: .string(query.queryText)],
                    format: sourceVerbs.resultFormat)
                timing.record(elapsedSeconds(since: sourceStart), into: .sourceRecall)
                divergence = rankDivergence(
                    expected: Self.normalizedContentOrder(sourceResult.items),
                    got: Self.normalizedContentOrder(targetResult.items))
            } else {
                divergence = rankDivergence(expected: [query.expectedRank1ID], got: targetIDs)
            }
            rankDivergences.append(divergence)

            diverging.append(BenchmarkReport.DivergingQuery(
                expectedRank1ID: query.expectedRank1ID,
                rankDivergence: divergence,
                rankOnePresent: rankOnePresent
            ))
        }

        let jaccard = jaccardDivergence(expected: expectedIDs, got: foundIDs)
        let meanRank = rankDivergences.isEmpty
            ? 0.0
            : rankDivergences.reduce(0, +) / Double(rankDivergences.count)

        // Retain the worst-diverging tail, highest rank divergence first.
        let worst = Array(diverging.sorted { $0.rankDivergence > $1.rankDivergence }
                                   .prefix(worstQueryRetention))

        return BenchmarkReport(
            capture: BenchmarkReport.summary(for: .capture, from: timing),
            recall: BenchmarkReport.summary(for: .recall, from: timing),
            verification: BenchmarkReport.summary(for: .verification, from: timing),
            // sourceRecall is populated only when --compare-source ran; it is
            // the source server's recall latency for the head-to-head, sitting
            // alongside the target's `recall` series.
            sourceRecall: BenchmarkReport.summary(for: .sourceRecall, from: timing),
            jaccardSetDivergence: jaccard,
            meanRankDivergence: meanRank,
            worstDivergingQueries: worst
        )
    }

    /// Maps result items to a normalized content order for cross-server rank
    /// comparison. Content is the only identity shared between two servers
    /// whose ids live in disjoint spaces, so the rank-divergence input is the
    /// list of normalized content strings in returned order. Normalization
    /// (trim + lowercase + collapse internal whitespace) absorbs incidental
    /// formatting differences (e.g. the contender's truncated previews vs full
    /// MOOTx01 content) on the shared prefix that survives both.
    static func normalizedContentOrder(_ items: [MCPResultItem]) -> [String] {
        items.compactMap { item in
            guard let content = item.content else { return nil }
            let collapsed = content
                .lowercased()
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            // Compare on a bounded prefix so a server that truncates content
            // (e.g. the contender's `content_preview`) still matches the same item from a
            // server that returns it in full.
            return String(collapsed.prefix(64))
        }
    }

    /// Monotonic elapsed seconds since a start mark.
    private func elapsedSeconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }
}
