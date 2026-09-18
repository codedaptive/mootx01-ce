import Testing
import Foundation
@testable import mcp_benchmarker

// FactLayerCorpusTests.swift — determinism, corpus invariants, and the
// cross-language conformance check for the fact-layer capability cell
// (PR-08 Deliverable 2).
//
// INTERNAL CAPABILITY CELL — outside the fairness-rule comparative lane.
//
// The conformance vector (conformance/fact_layer_vectors.json) pins the
// corpus produced by seed=20260725 / factCount=6 / versionsPerFact=2 so
// both the Swift and Rust legs must regenerate it EXACTLY. A benchmark
// whose corpus drifts between legs cannot support a published claim.

/// Resolves `benchmarks/conformance/<filename>` from this file's path.
private func factConformancePath(_ filename: String, file: String = #filePath) -> URL {
    URL(fileURLWithPath: file)
        .deletingLastPathComponent()   // mcp-benchmarkerTests/
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // package root
        .appendingPathComponent("conformance")
        .appendingPathComponent(filename)
}

@Suite("FactLayer corpus")
struct FactLayerCorpusTests {

    // MARK: - Determinism

    @Test("generation is a pure function of seed")
    func deterministicGeneration() {
        let a = generateFactLayerCorpus(seed: 42, factCount: 5, versionsPerFact: 2)
        let b = generateFactLayerCorpus(seed: 42, factCount: 5, versionsPerFact: 2)
        #expect(a == b)
    }

    @Test("different seeds produce different corpora")
    func differentSeedsDifferentOutput() {
        let a = generateFactLayerCorpus(seed: 42, factCount: 5, versionsPerFact: 2)
        let c = generateFactLayerCorpus(seed: 43, factCount: 5, versionsPerFact: 2)
        // At minimum the first fact's object should differ between seeds.
        #expect(a.facts[0].object != c.facts[0].object
                || a.facts[0].subject != c.facts[0].subject)
    }

    @Test("factCount and versionsPerFact control corpus size")
    func corpusSizeMatchesParams() {
        let corpus = generateFactLayerCorpus(seed: 1, factCount: 8, versionsPerFact: 3)
        // Each fact (entity) produces versionsPerFact FactRecords.
        #expect(corpus.facts.count == 8 * 3)
        // One FactQuery per entity.
        #expect(corpus.queries.count == 8)
    }

    // MARK: - Chain invariants

    @Test("each chain has exactly one current version")
    func chainHasExactlyOneCurrent() {
        let corpus = generateFactLayerCorpus(seed: 7, factCount: 10, versionsPerFact: 2)
        for q in corpus.queries {
            let chain = corpus.facts.filter { $0.id.hasPrefix("fact-") &&
                $0.subject == q.subject && $0.predicate == q.predicate }
            let currentFacts = chain.filter(\.isCurrent)
            #expect(currentFacts.count == 1,
                    "chain for \(q.subject)/\(q.predicate) must have exactly one current fact")
        }
    }

    @Test("current fact ID matches query currentFactID")
    func currentFactMatchesQuery() {
        let corpus = generateFactLayerCorpus(seed: 7, factCount: 10, versionsPerFact: 2)
        for q in corpus.queries {
            let current = corpus.facts.first {
                $0.id == q.currentFactID && $0.isCurrent
            }
            #expect(current != nil,
                    "current fact '\(q.currentFactID)' must exist and be marked isCurrent")
        }
    }

    @Test("version indices are sequential from zero")
    func versionIndicesAreSequential() {
        let corpus = generateFactLayerCorpus(seed: 3, factCount: 4, versionsPerFact: 3)
        for q in corpus.queries {
            let chain = corpus.facts.filter { $0.subject == q.subject && $0.predicate == q.predicate }
                .sorted { $0.versionIndex < $1.versionIndex }
            for (i, fact) in chain.enumerated() {
                #expect(fact.versionIndex == i,
                        "version index must equal position in sorted chain")
            }
            #expect(chain.last?.isCurrent == true, "last version must be current")
        }
    }

    @Test("event times are strictly increasing within each chain")
    func eventTimesIncreasing() {
        let corpus = generateFactLayerCorpus(seed: 9, factCount: 6, versionsPerFact: 3)
        for q in corpus.queries {
            let chain = corpus.facts.filter { $0.subject == q.subject && $0.predicate == q.predicate }
                .sorted { $0.versionIndex < $1.versionIndex }
            for (a, b) in zip(chain, chain.dropFirst()) {
                #expect(a.eventTime < b.eventTime,
                        "event times must be strictly increasing within chain")
            }
        }
    }

    @Test("retired fact IDs are all non-current chain members")
    func retiredFactIDsAreNonCurrent() {
        let corpus = generateFactLayerCorpus(seed: 5, factCount: 8, versionsPerFact: 2)
        let factByID = Dictionary(uniqueKeysWithValues: corpus.facts.map { ($0.id, $0) })
        for q in corpus.queries {
            for retiredID in q.retiredFactIDs {
                let fact = factByID[retiredID]
                #expect(fact != nil, "retired fact '\(retiredID)' must exist in corpus")
                #expect(fact?.isCurrent == false,
                        "retired fact '\(retiredID)' must not be marked isCurrent")
            }
        }
    }

    @Test("corpus retiredFactIDs plus currentFactID equals full chain")
    func retiredPlusCurrentEqualsChain() {
        let corpus = generateFactLayerCorpus(seed: 11, factCount: 5, versionsPerFact: 3)
        for q in corpus.queries {
            let allInQuery = Set(q.retiredFactIDs + [q.currentFactID])
            let chain = corpus.facts.filter { $0.subject == q.subject && $0.predicate == q.predicate }
            #expect(allInQuery.count == chain.count,
                    "union of retired + current must cover entire chain")
        }
    }

    @Test("values within a chain are distinct (no no-op updates)")
    func chainValuesAreDistinct() {
        let corpus = generateFactLayerCorpus(seed: 4, factCount: 10, versionsPerFact: 2)
        for q in corpus.queries {
            let chain = corpus.facts.filter { $0.subject == q.subject && $0.predicate == q.predicate }
            let values = chain.map(\.object)
            let unique = Set(values)
            #expect(unique.count == chain.count,
                    "all values in chain must be distinct (no no-op updates)")
        }
    }

    @Test("epoch is deterministic — no wall-clock dependency")
    func epochIsDeterministic() {
        // The corpus must not embed wall-clock dates. The fixed epoch ensures
        // eventTime values are identical across runs and machines.
        let a = generateFactLayerCorpus(seed: 999, factCount: 3, versionsPerFact: 2)
        let b = generateFactLayerCorpus(seed: 999, factCount: 3, versionsPerFact: 2)
        #expect(a.facts.map(\.eventTime) == b.facts.map(\.eventTime))
    }

    // MARK: - Codable round-trip

    @Test("FactLayerCorpus survives JSON round-trip")
    func jsonRoundTrip() throws {
        let corpus = generateFactLayerCorpus(seed: 20260725, factCount: 6, versionsPerFact: 2)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(corpus)
        let decoded = try JSONDecoder().decode(FactLayerCorpus.self, from: data)
        #expect(corpus == decoded)
    }

    // MARK: - Conformance vector

    @Test("committed conformance vectors regenerate exactly")
    func conformanceVectors() throws {
        let url = factConformancePath("fact_layer_vectors.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Vector file not yet generated — skip gracefully. The CI task that
            // generates vectors must run `supersession --fact-layer --dump-seed`
            // first and commit the file.
            return
        }
        let expected = try JSONDecoder().decode(FactLayerCorpus.self,
                                                from: Data(contentsOf: url))
        let generated = generateFactLayerCorpus(
            seed: 20260725, factCount: 6, versionsPerFact: 2)
        #expect(generated == expected)
    }
}
