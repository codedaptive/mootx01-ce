import Foundation

// QualityEngine.swift — orchestrates the search/filter quality benchmark
// against two LIVE MCP products, using the wiki-quality known-target fixture as
// ground truth. The pure scoring lives in QualityScoring; this file only drives
// the products and maps their results back to corpus ids, then hands ranked
// lists to the scorer.
//
// Pipeline (per product, then head-to-head):
//   1. LOAD   — write every corpus article to BOTH products. mootx01:
//               location=clusterId, sensitivity=(sensitive→restricted, else
//               normal). contender: wing=tag.wing, room=tag.room. Each write's
//               returned product id is recorded in the CorpusIDResolver
//               (mootx01 echoes a UUID; the contender's add returns a drawer_id),
//               and the article body is indexed for the content fallback.
//   2. CONFIRM— mootx01 only: call moot_confirm_memory on the corpus records
//               whose tag confirmation=="confirmed" (confirmation is NOT
//               settable at file time; it is a post-load pass).
//   3. RETRIEVAL — for each of the fixture queries, search both products with
//               query.text, map ranked hits → corpus ids, score recall@k / MRR
//               / nDCG / precision@k against the query's ground truth.
//   4. FILTER — score only what each product can actually filter:
//               mootx01 confirmation (search filter:userConfirmed) and
//               contender wing (list_drawers wing=<Wing>). Sensitivity / lattice
//               are NOT search-filterable on mootx01, so those corpus
//               filter-tests are recorded as skipped, never faked.
//
// SCRATCH BOUNDARY (security): both products are launched against SCRATCH data
// dirs by the config the caller supplies (MOOTX01_DATA_DIR=/tmp/... and
// contender-mcp --contender-dir /tmp/...). This engine WRITES to both products, so the
// caller MUST point them at scratch backends — the real palace is never a valid
// target. The engine cannot enforce this (the command string is operator
// input, same trust level as a CLI arg); the quality subcommand's help and
// CONFIG.md state the scratch requirement plainly.

/// The recall depth requested from each product per query. 10 is the deepest
/// scoring cut-off (recall@10 / precision@10 / nDCG@10), so 10 results suffice
/// for every metric — there is no benefit to pulling more than the deepest cut.
private let retrievalLimit = 10

/// Drives the quality benchmark against two live products.
struct QualityEngine {
    let moot: MCPClient
    let mootVerbs: EndpointConfig.VerbMap
    let contender: MCPClient
    let contenderVerbs: EndpointConfig.VerbMap
    let fixture: QualityFixture
    /// Echoed back into the report so a partial run is labelled as such.
    let limitedToClusters: Int?

    /// Runs the whole pipeline and returns the report.
    func run() async throws -> QualityReport {
        // --- 1. LOAD both products, building each product's id resolver. ---
        var mootResolver = CorpusIDResolver()
        var contenderResolver = CorpusIDResolver()
        var mootWritten = 0
        var contenderWritten = 0
        // mootx01 product-id per corpus id, needed for the confirm pass (confirm
        // takes the product's own row id, not the corpus id).
        var mootProductID: [String: String] = [:]

        for record in fixture.records {
            let body = try fixture.articleText(for: record.id)
            mootResolver.indexArticle(corpusID: record.id, body: body)
            contenderResolver.indexArticle(corpusID: record.id, body: body)

            // mootx01 write: location = clusterId; sensitivity mapped per the
            // mission rule (corpus "sensitive" → product "restricted", else
            // "normal"). confirmation is NOT set here — it is the confirm pass.
            let mootSensitivity = record.tags.sensitivity == "sensitive" ? "restricted" : "normal"
            let mootResult = try await moot.callTool(
                mootVerbs.write,
                arguments: [
                    mootVerbs.contentArg: .string(body),
                    "location": .string(record.clusterId),
                    "sensitivity": .string(mootSensitivity),
                ],
                format: mootVerbs.resultFormat)
            if let pid = mootResult.writeAssignedID {
                mootResolver.recordWrite(productID: pid, corpusID: record.id)
                mootProductID[record.id] = pid
            }
            mootWritten += 1

            // contender write: wing = tag.wing, room = tag.room.
            let contenderResult = try await contender.callTool(
                contenderVerbs.write,
                arguments: [
                    contenderVerbs.contentArg: .string(body),
                    "wing": .string(record.tags.wing),
                    "room": .string(record.tags.room),
                ],
                format: contenderVerbs.resultFormat)
            // The contender's add returns a drawer_id; record it when present so a
            // later hit that echoes the drawer id resolves by id (else by
            // content). The drawer id parses as the write's first ordered id.
            if let pid = contenderResult.writeAssignedID ?? contenderResult.orderedIDs.first {
                contenderResolver.recordWrite(productID: pid, corpusID: record.id)
            }
            contenderWritten += 1
        }

        // --- 2. CONFIRM pass (mootx01 only). ---
        // confirmation is not settable at file time, so set it now on the
        // records the fixture marks confirmed, by their product row id.
        var mootConfirmed = 0
        for record in fixture.records where record.tags.confirmation == "confirmed" {
            guard let pid = mootProductID[record.id] else { continue }
            // moot_confirm_memory takes the row id. Result is ignored; a failure
            // to confirm one row should not abort the run, so swallow per-row
            // errors and let the confirmation filter score reflect reality.
            _ = try? await moot.callTool(
                "moot_confirm_memory",
                arguments: ["id": .string(pid)],
                format: mootVerbs.resultFormat)
            mootConfirmed += 1
        }

        // --- 3. RETRIEVAL scoring for both products. ---
        let mootScored = try await scoreRetrieval(client: moot, verbs: mootVerbs,
                                                  resolver: mootResolver)
        let contenderScored = try await scoreRetrieval(client: contender, verbs: contenderVerbs,
                                                       resolver: contenderResolver)
        let mootRetrieval = aggregateRetrieval(mootScored)
        let contenderRetrieval = aggregateRetrieval(contenderScored)

        // --- 4. FILTER scoring (only what each product can filter). ---
        var notes: [String] = []
        let mootFilters = try await scoreMootFilters(resolver: mootResolver, notes: &notes)
        let contenderFilters = try await scoreContenderFilters(resolver: contenderResolver)

        // --- assemble the report + head-to-head. ---
        let mootProduct = ProductQuality(name: "mootx01", retrieval: mootRetrieval,
                                         filters: mootFilters,
                                         writtenCount: mootWritten, confirmedCount: mootConfirmed)
        let contenderProduct = ProductQuality(name: "contender", retrieval: contenderRetrieval,
                                              filters: contenderFilters,
                                              writtenCount: contenderWritten, confirmedCount: 0)

        let headToHead = [
            HeadToHead.higherWins(metric: "recall@1", moot: mootRetrieval.recallAt1, contender: contenderRetrieval.recallAt1),
            HeadToHead.higherWins(metric: "recall@5", moot: mootRetrieval.recallAt5, contender: contenderRetrieval.recallAt5),
            HeadToHead.higherWins(metric: "recall@10", moot: mootRetrieval.recallAt10, contender: contenderRetrieval.recallAt10),
            HeadToHead.higherWins(metric: "MRR", moot: mootRetrieval.mrr, contender: contenderRetrieval.mrr),
            HeadToHead.higherWins(metric: "nDCG@10", moot: mootRetrieval.ndcgAt10, contender: contenderRetrieval.ndcgAt10),
            HeadToHead.higherWins(metric: "P@5", moot: mootRetrieval.precisionAt5, contender: contenderRetrieval.precisionAt5),
            HeadToHead.higherWins(metric: "P@10", moot: mootRetrieval.precisionAt10, contender: contenderRetrieval.precisionAt10),
        ]

        return QualityReport(
            limitedToClusters: limitedToClusters,
            clusterCount: fixture.clustersInOrder.count,
            articleCount: fixture.records.count,
            mootx01: mootProduct,
            contender: contenderProduct,
            headToHead: headToHead,
            notes: notes)
    }

    // MARK: - Retrieval

    /// Searches `client` for every fixture query and maps ranked hits → corpus
    /// ids via `resolver`, producing one ScoredQuery per query for the scorer.
    private func scoreRetrieval(client: MCPClient,
                                verbs: EndpointConfig.VerbMap,
                                resolver: CorpusIDResolver) async throws -> [ScoredQuery] {
        var scored: [ScoredQuery] = []
        for query in fixture.queries {
            let result = try await client.callTool(
                verbs.query,
                arguments: [
                    verbs.queryArg: .string(query.text),
                    "limit": .number(Double(retrievalLimit)),
                ],
                format: verbs.resultFormat)
            // Map the ranked result items → corpus ids (unresolvable hits
            // dropped); build the ground truth from the query's target + close.
            let ranked = resolver.resolveRanked(result.items)
            let truth = QueryTruth(targetId: query.expectTargetId,
                                   closeIds: Set(query.closeIds))
            scored.append(ScoredQuery(truth: truth, rankedCorpusIDs: ranked))
        }
        return scored
    }

    // MARK: - Filters

    /// Scores mootx01's filterable axis: confirmation. The fixture's
    /// confirmation-confirmed test is the one mootx01 can answer via
    /// moot_memory_search(filter:"userConfirmed"). The sensitivity test (and any
    /// lattice test) are NOT search-filterable on mootx01, so they are recorded
    /// in `notes` as skipped — never faked with a wrong filter.
    private func scoreMootFilters(resolver: CorpusIDResolver,
                                  notes: inout [String]) async throws -> [FilterResult] {
        var results: [FilterResult] = []
        for test in fixture.filterTests {
            // Wing tests are the contender's axis, not mootx01's — skip here.
            if test.contenderFilter != nil { continue }
            // mootx01 can only filter confirmation (userConfirmed). The
            // sensitivity tag is stored but not a search filter enum value.
            guard test.mootFilter.hasPrefix("confirmation=") else {
                notes.append("mootx01: filter-test '\(test.id)' skipped — "
                    + "'\(test.mootFilter)' is not a mootx01 search filter "
                    + "(only unconfirmed|userConfirmed|exportable|contained are filterable).")
                continue
            }
            // A broad query plus the userConfirmed filter returns the confirmed
            // set. Use a generic query and a high limit so the filter — not the
            // query relevance — bounds the result. The query text is broad on
            // purpose: the filter is the predicate under test.
            let result = try await moot.callTool(
                mootVerbs.query,
                arguments: [
                    mootVerbs.queryArg: .string("the"),  // broad; filter is the predicate
                    "filter": .string("userConfirmed"),
                    "limit": .number(500),
                ],
                format: mootVerbs.resultFormat)
            let returned = Set(resolver.resolveRanked(result.items))
            let expected = Set(test.expectIds)
            let score = scoreFilter(returned: returned, expected: expected)
            results.append(FilterResult(testId: test.id,
                                        filterExpression: "userConfirmed",
                                        precision: score.precision, recall: score.recall,
                                        f1: score.f1, returnedCount: score.returnedCount,
                                        expectedCount: score.expectedCount,
                                        truePositives: score.truePositives))
        }
        // Lattice is not exposed as a search filter on mootx01 either; the
        // fixture has no explicit lattice filter-test, but record the boundary
        // so the report is explicit about what mootx01 cannot filter.
        notes.append("mootx01: sensitivity and latticeAnchor are stored but not "
            + "search-filterable, so corpus tag-filters on those axes are not scored.")
        return results
    }

    /// Scores the contender's filterable axis: wing. Each wing filter-test lists the
    /// exact cluster membership; list_drawers(wing:) should return exactly that
    /// set. Pagination loops by `offset` until a short/empty page so the full
    /// wing is enumerated (list_drawers caps at 100 per page).
    private func scoreContenderFilters(resolver: CorpusIDResolver) async throws -> [FilterResult] {
        var results: [FilterResult] = []
        for test in fixture.filterTests {
            // Only the wing tests are the contender's axis.
            guard let contenderFilter = test.contenderFilter,
                  contenderFilter.hasPrefix("wing=") else { continue }
            let wing = String(contenderFilter.dropFirst("wing=".count))

            // Paginate the wing. list_drawers truncates content to a preview,
            // so resolution falls back to the drawer id recorded at write time
            // (echoed in the list as drawer_id) or the preview's content prefix.
            var returned = Set<String>()
            var offset = 0
            let pageSize = 100  // list_drawers max
            while true {
                let page = try await contender.callTool(
                    contenderVerbs.list ?? "contender_list_drawers",
                    arguments: [
                        "wing": .string(wing),
                        "limit": .number(Double(pageSize)),
                        "offset": .number(Double(offset)),
                    ],
                    format: contenderVerbs.resultFormat)
                let mapped = resolver.resolveRanked(page.items)
                returned.formUnion(mapped)
                // Stop on a short page (fewer items than a full page) or no items.
                if page.items.count < pageSize { break }
                offset += pageSize
            }

            let expected = Set(test.expectIds)
            let score = scoreFilter(returned: returned, expected: expected)
            results.append(FilterResult(testId: test.id,
                                        filterExpression: contenderFilter,
                                        precision: score.precision, recall: score.recall,
                                        f1: score.f1, returnedCount: score.returnedCount,
                                        expectedCount: score.expectedCount,
                                        truePositives: score.truePositives))
        }
        return results
    }
}
