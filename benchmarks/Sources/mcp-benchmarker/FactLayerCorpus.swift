import Foundation

// FactLayerCorpus.swift — deterministic fact-triple corpus for the fact-layer
// supersession capability cell (PR-08, Deliverable 2).
//
// INTERNAL CAPABILITY CELL — OUTSIDE THE FAIRNESS-RULE COMPARATIVE LANE.
//
// This corpus exercises moot-specific structured-fact storage verbs:
//   moot_file_fact   — files a subject/predicate/object triple with metadata
//   moot_retire_fact — retires (supersedes) a fact by ID
//   moot_fact_search — queries filed facts
//   moot_fact_timeline — retrieves the version history of a fact chain
//
// These verbs are NOT part of any public-benchmark fair-comparison lane.
// No other system is scored here — this cell measures a product-specific
// mechanism that only mootx01 exposes. Every report carrying this cell
// MUST carry the `cell_type: "internal_capability"` label so consumers
// know it is not a fairness-rule comparative measurement.
//
// Corpus design:
//   - Deterministic: same seed → same bytes every run, both ports.
//   - Fact chains: each entity has `versionsPerFact` triples filed in
//     chronological order. The latest triple is "current"; all earlier
//     triples are "retired" via moot_retire_fact.
//   - Ground truth: scored by fact IDs, not drawer IDs. A query is a
//     hit when the current fact ID appears in results and no retired
//     fact ID outranks it.
//
// FAIRNESS NOTE: nothing here requires moot_file_fact to be better
// than a plain memory write at retrieval time. The cell measures whether
// the structured-fact lifecycle (file → retire → query → timeline) works
// end-to-end, not whether the product outperforms anything else.

// MARK: - Corpus model

/// One structured fact triple (subject / predicate / object) at a point in time.
///
/// Maps to a `moot_file_fact` call: subject, predicate, object, event_time,
/// and source_grounding are all passed as arguments. The harness uses `id` to
/// track which fact UUID was returned by the filing call.
struct FactRecord: Codable, Sendable, Equatable {
    /// Harness-assigned stable ID (used for ground-truth and retire calls).
    let id: String
    /// The subject of the fact ("Alice Nguyen 3").
    let subject: String
    /// The predicate ("employer").
    let predicate: String
    /// The object value at this point in the timeline ("Acme Robotics").
    let object: String
    /// Natural-language sentence filed as body content alongside the structured fields.
    let content: String
    /// ISO8601 timestamp of when this fact was asserted. Passed as `event_time`.
    let eventTime: String
    /// Source grounding sentence — the evidence backing this assertion.
    let sourceGrounding: String
    /// 0-based version index within this subject+predicate chain.
    let versionIndex: Int
    /// True for the most-recent (current) version of the chain.
    let isCurrent: Bool
}

/// One scored query over the fact corpus.
struct FactQuery: Codable, Sendable, Equatable {
    let id: String
    /// Natural-language question answered by the current fact.
    let question: String
    /// Subject the question is about.
    let subject: String
    /// Predicate the question targets.
    let predicate: String
    /// Current (correct) fact ID — must appear in search results.
    let currentFactID: String
    /// Retired fact IDs — must NOT outrank currentFactID.
    let retiredFactIDs: [String]
}

/// The complete fact-layer corpus. A pure function of `seed`.
struct FactLayerCorpus: Codable, Sendable, Equatable {
    let seed: UInt64
    let facts: [FactRecord]
    let queries: [FactQuery]
}

// MARK: - Deterministic generation

/// Builds a `FactLayerCorpus` that is a pure function of `seed`.
///
/// Same seed → same bytes on every call, both Swift and Rust ports.
/// The conformance vector file `conformance/fact_layer_vectors.json` pins
/// the output for seed=20260725 so both legs can be regression-tested.
///
/// Parameters intentionally small so the conformance vector is human-readable
/// and the unit test runs in milliseconds.
func generateFactLayerCorpus(
    seed: UInt64,
    factCount: Int = 10,
    versionsPerFact: Int = 2
) -> FactLayerCorpus {
    var rng = SplitMix64(seed: seed)

    // Vocabulary: plain, unambiguous terms so the harness does not measure
    // whether the product handles complex phrasing — only the lifecycle.
    let firstNames = ["Alice", "Bruno", "Chiara", "Dmitri", "Elena",
                      "Farid", "Grace", "Hamid", "Ingrid", "Jonas"]
    let lastNames  = ["Nguyen", "Osei", "Patel", "Romero", "Schmidt",
                      "Tanaka", "Utomo", "Vargas", "Wang", "Zielinski"]

    // (predicate, values, question template).
    // One value per version index — picked from the pool without replacement
    // so each version is a genuine change.
    typealias Triplet = (String, [String], String)
    let predicates: [Triplet] = [
        ("employer",
         ["Acme Robotics", "Northwind Analytics", "Beta Corp",
          "Vireo Systems", "Halcyon Labs", "Crest Technology"],
         "Where does %@ work?"),
        ("city",
         ["Lisbon", "Toronto", "Osaka", "Nairobi", "Reykjavik", "Montevideo"],
         "In what city does %@ live?"),
        ("role",
         ["staff engineer", "engineering manager", "principal architect",
          "director of platform", "technical lead", "VP of Engineering"],
         "What is %@'s current role?"),
        ("primary_language",
         ["Swift", "Rust", "Elixir", "OCaml", "Zig", "Haskell"],
         "What programming language does %@ primarily use?"),
    ]

    var facts:   [FactRecord] = []
    var queries: [FactQuery]  = []

    // Timeline epoch: fixed, never Date(), so the corpus is wall-clock-stable.
    // 2020-01-26T00:53:20Z — same epoch as SupersessionCorpus for consistency.
    let epoch = 1_580_000_000.0
    let iso = ISO8601DateFormatter()
    iso.timeZone = TimeZone(secondsFromGMT: 0)

    for fi in 0..<factCount {
        let fn = firstNames[Int(rng.next() % UInt64(firstNames.count))]
        let ln = lastNames[Int(rng.next() % UInt64(lastNames.count))]
        // Index suffix guarantees entity uniqueness across the corpus.
        let subject = "\(fn) \(ln) \(fi)"
        let (predicate, valuePool, questionTemplate) = predicates[fi % predicates.count]

        // Pick distinct values for each version (no repeats within a chain).
        var pool = valuePool
        var chainValues: [String] = []
        for _ in 0..<min(versionsPerFact, pool.count) {
            let idx = Int(rng.next() % UInt64(pool.count))
            chainValues.append(pool.remove(at: idx))
        }

        var chainIDs: [String] = []
        for (vi, value) in chainValues.enumerated() {
            let factID = "fact-\(fi)-v\(vi)"
            chainIDs.append(factID)
            // Versions land 120–240 days apart, strictly increasing.
            let dayOffset = Double(vi) * (120.0 + Double(rng.next() % 120))
            let when = epoch + dayOffset * 86_400.0
            let isCurrent = (vi == chainValues.count - 1)
            // Content phrasing avoids "was" / "changed from" so the harness
            // does not accidentally test language-model coreference — only
            // the structured timeline makes the current version identifiable.
            let content = vi == 0
                ? "\(subject)'s \(predicate) is \(value)."
                : "\(subject)'s \(predicate) is now \(value)."
            let grounding = "Source: internal profile record, effective \(iso.string(from: Date(timeIntervalSince1970: when)))."
            facts.append(FactRecord(
                id: factID,
                subject: subject,
                predicate: predicate,
                object: value,
                content: content,
                eventTime: iso.string(from: Date(timeIntervalSince1970: when)),
                sourceGrounding: grounding,
                versionIndex: vi,
                isCurrent: isCurrent
            ))
        }

        queries.append(FactQuery(
            id: "fq-\(fi)",
            question: String(format: questionTemplate, subject),
            subject: subject,
            predicate: predicate,
            currentFactID: chainIDs[chainIDs.count - 1],
            retiredFactIDs: Array(chainIDs.dropLast())
        ))
    }

    return FactLayerCorpus(seed: seed, facts: facts, queries: queries)
}
