import Foundation

// QualityCorpus.swift — loaders for the wiki-quality known-target fixture and
// the product-id ↔ corpus-id correlation map the engine builds at load time.
//
// The fixture lives at tools/mcp-benchmarker/fixtures/wiki-quality/ :
//   fixture/corpus.jsonl   — one CorpusRecord per line (299)
//   fixture/queries.json   — 60 QualityQuery records (known-target rankings)
//   fixture/filter-tests.json — 7 FilterTest records (exact expected id sets)
//   articles/<id>.txt      — full article body text
//
// The corpus records carry an absolute `path` (e.g. /tmp/wiki-corpus/...) that
// reflects where the fixture was ASSEMBLED, not where it lives in this repo, so
// article bodies are read from <fixturesRoot>/articles/<id>.txt rather than
// from that path. This keeps the fixture relocatable.

// MARK: - Fixture record shapes

/// One corpus article record, decoded from a line of corpus.jsonl.
struct CorpusRecord: Codable, Sendable {
    let id: String
    let title: String
    let clusterId: String
    let role: String          // target | distractor | member
    let wordCount: Int
    let tags: Tags

    /// The tag map. Only the fields the benchmark uses are decoded; extra keys
    /// in the JSON are ignored by Codable.
    struct Tags: Codable, Sendable {
        let confirmation: String   // confirmed | unconfirmed
        let sensitivity: String    // normal | sensitive
        let latticeAnchor: String  // equals clusterId
        let wing: String           // contender wing (1:1 with cluster)
        let room: String           // equals role
    }
}

/// One known-target query, decoded from queries.json. Only the fields the
/// scorer needs are decoded (`farIds` is the full out-of-cluster set and is not
/// needed for scoring — far ids are simply "not target and not close", i.e.
/// graded irrelevant, which the scorer derives from absence).
struct QualityQuery: Codable, Sendable {
    let queryId: String
    let text: String
    let expectTargetId: String
    let closeIds: [String]
    let kind: String           // paraphrase | fact
    let clusterId: String
}

/// One filter test, decoded from filter-tests.json. `mootFilter` is always
/// present (`<key>=<value>` over the tags map); `contenderFilter` is present
/// only for the wing tests (`wing=<Wing Name>`). `expectIds` is the exact set a
/// correct filter must return.
struct FilterTest: Codable, Sendable {
    let id: String
    let mootFilter: String
    let contenderFilter: String?
    let expectIds: [String]
}

// MARK: - Loaded fixture bundle

/// The whole fixture, loaded and validated, plus the resolved root for reading
/// article bodies.
struct QualityFixture: Sendable {
    let root: URL                       // <repo>/tools/mcp-benchmarker/fixtures/wiki-quality
    let records: [CorpusRecord]
    let queries: [QualityQuery]
    let filterTests: [FilterTest]

    /// corpus id → record, for O(1) ground-truth lookups during scoring.
    let recordByID: [String: CorpusRecord]

    /// Loads every fixture file under `root`. Throws MCPError with a precise
    /// message if a file is missing or malformed so a bad fixture path fails at
    /// load, not mid-run.
    static func load(root: URL) throws -> QualityFixture {
        let fixtureDir = root.appendingPathComponent("fixture")

        // corpus.jsonl: one JSON object per non-empty line.
        let corpusURL = fixtureDir.appendingPathComponent("corpus.jsonl")
        let corpusText = try String(contentsOf: corpusURL, encoding: .utf8)
        let decoder = JSONDecoder()
        var records: [CorpusRecord] = []
        for rawLine in corpusText.split(separator: "\n", omittingEmptySubsequences: true) {
            let data = Data(rawLine.utf8)
            do {
                records.append(try decoder.decode(CorpusRecord.self, from: data))
            } catch {
                throw MCPError(description: "corpus.jsonl: failed to decode a record: \(error)")
            }
        }
        guard !records.isEmpty else {
            throw MCPError(description: "corpus.jsonl at \(corpusURL.path) is empty")
        }

        let queriesURL = fixtureDir.appendingPathComponent("queries.json")
        let queries = try decoder.decode([QualityQuery].self,
                                         from: try Data(contentsOf: queriesURL))

        let filterURL = fixtureDir.appendingPathComponent("filter-tests.json")
        let filterTests = try decoder.decode([FilterTest].self,
                                             from: try Data(contentsOf: filterURL))

        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })

        return QualityFixture(root: root,
                              records: records,
                              queries: queries,
                              filterTests: filterTests,
                              recordByID: byID)
    }

    /// Reads the full article body for a corpus id from
    /// <root>/articles/<id>.txt. The corpus record's own `path` field is NOT
    /// used (it points at the fixture's assembly-time location); the body is
    /// always read relative to the loaded fixture root so the fixture relocates.
    func articleText(for id: String) throws -> String {
        let url = root.appendingPathComponent("articles").appendingPathComponent("\(id).txt")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The distinct cluster ids in corpus order (first appearance). Used by
    /// `--limit-clusters` to take a stable small slice.
    var clustersInOrder: [String] {
        var seen = Set<String>()
        var order: [String] = []
        for r in records where !seen.contains(r.clusterId) {
            seen.insert(r.clusterId)
            order.append(r.clusterId)
        }
        return order
    }

    /// A copy of the fixture narrowed to the first `n` clusters (corpus order).
    /// Records, queries, and filter tests are all filtered to those clusters.
    /// Wing filter tests survive only when their cluster is in the slice; the
    /// tag filter tests (confirmation / sensitivity) have their `expectIds`
    /// narrowed to the sliced clusters so they remain scorable on the subset.
    func limited(toClusters n: Int) -> QualityFixture {
        guard n > 0, n < clustersInOrder.count else { return self }
        let keep = Set(clustersInOrder.prefix(n))

        let keptRecords = records.filter { keep.contains($0.clusterId) }
        let keptQueries = queries.filter { keep.contains($0.clusterId) }
        let keptIDs = Set(keptRecords.map(\.id))

        // Narrow each filter test's expected set to the kept ids. A wing test
        // whose cluster is out of slice ends up with an empty expected set, so
        // drop it (it is no longer a meaningful test on this subset). Tag tests
        // (confirmation/sensitivity) keep whatever expected ids fall in slice.
        let keptFilters: [FilterTest] = filterTests.compactMap { test in
            let narrowed = test.expectIds.filter { keptIDs.contains($0) }
            let isWing = test.contenderFilter != nil
            if isWing && narrowed.isEmpty { return nil }
            return FilterTest(id: test.id,
                              mootFilter: test.mootFilter,
                              contenderFilter: test.contenderFilter,
                              expectIds: narrowed)
        }

        let byID = Dictionary(uniqueKeysWithValues: keptRecords.map { ($0.id, $0) })
        return QualityFixture(root: root,
                              records: keptRecords,
                              queries: keptQueries,
                              filterTests: keptFilters,
                              recordByID: byID)
    }
}

// MARK: - Product-id ↔ corpus-id correlation

/// Maps the ids a product mints on write back to the corpus ids that are the
/// ground truth. Two channels:
///   1. write-time: when a write echoes its assigned id (mootx01
///      `filed memory <UUID>`), record productID → corpusID directly.
///   2. content fallback: when a search result carries no usable product id, or
///      an id never seen at write time, match on a normalized content prefix —
///      the only identity shared when ids are not echoed (e.g. the contender's
///      search returns content with no stable id in the hit).
///
/// The fallback indexes each corpus article by a normalized prefix of its body;
/// a search hit's content is normalized the same way and looked up. Content is
/// the bridge identity because the same article text was written to both
/// products, so a hit's text prefix identifies its corpus id regardless of
/// which product returned it.
struct CorpusIDResolver: Sendable {
    /// productID → corpusID, populated from write responses that echo an id.
    private var byProductID: [String: String] = [:]
    /// normalized-content-prefix → corpusID, the fallback identity.
    private var byContentPrefix: [String: String] = [:]

    /// How many leading normalized characters identify an article. 80 chars of
    /// the (whitespace-collapsed, lowercased) body is well past the title line
    /// and into the distinctive lead sentence, so collisions across 299
    /// articles are not expected; a collision would simply make the later
    /// article unresolvable by content (it still resolves by echoed id).
    private static let prefixLength = 80

    /// Normalizes text for the content-prefix index: lowercase, collapse all
    /// whitespace runs to single spaces, trim, take the leading prefix. Applied
    /// identically to article bodies (at index time) and to search-hit content
    /// (at resolve time) so the two line up on the shared lead text.
    static func normalizedPrefix(_ text: String) -> String {
        let collapsed = text
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(collapsed.prefix(prefixLength))
    }

    /// Indexes one corpus article body under its corpus id for content
    /// fallback. Called once per article as it is loaded for writing.
    mutating func indexArticle(corpusID: String, body: String) {
        let key = Self.normalizedPrefix(body)
        // First write wins so an accidental prefix collision does not silently
        // remap an already-indexed article.
        if byContentPrefix[key] == nil {
            byContentPrefix[key] = corpusID
        }
    }

    /// Records a product-assigned id for a corpus id (from a write response
    /// that echoes its id, e.g. mootx01).
    mutating func recordWrite(productID: String, corpusID: String) {
        byProductID[productID] = corpusID
    }

    /// Resolves one search-result item to its corpus id: first by echoed
    /// product id, then by content prefix. Returns nil when neither resolves
    /// (an unmappable hit, which the scorer drops — it earns no credit).
    func resolve(item: MCPResultItem) -> String? {
        if let pid = item.id, let corpusID = byProductID[pid] {
            return corpusID
        }
        if let content = item.content {
            return byContentPrefix[Self.normalizedPrefix(content)]
        }
        return nil
    }

    /// Resolves a ranked list of result items to corpus ids in rank order,
    /// dropping unresolvable hits. The compaction means an unmappable hit never
    /// occupies a rank slot in the scored list — it is as if the product had
    /// not returned it (the conservative choice; see QualityScoring header).
    func resolveRanked(_ items: [MCPResultItem]) -> [String] {
        items.compactMap { resolve(item: $0) }
    }
}
