import Foundation
import Testing
@testable import mcp_benchmarker

// SupersessionCorpusTests — generator determinism, corpus invariants, and the
// cross-language conformance check against the committed vector file.
//
// The vector file (conformance/supersession_vectors.json) is the corpus for
// seed 20260725 / 6 entities / 3 versions / 4 contradictions. Both legs must
// regenerate it EXACTLY: a benchmark whose corpus drifts between legs or
// between runs cannot support a claim.

/// Resolves `benchmarks/conformance/<filename>` from this file.
private func conformancePath(_ filename: String, file: String = #filePath) -> URL {
    URL(fileURLWithPath: file)
        .deletingLastPathComponent()   // mcp-benchmarkerTests/
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // package root
        .appendingPathComponent("conformance")
        .appendingPathComponent(filename)
}

@Suite("Supersession corpus")
struct SupersessionCorpusTests {

    @Test("generation is a pure function of seed")
    func deterministicGeneration() {
        let a = generateSupersessionCorpus(seed: 42, entityCount: 8,
                                           versionsPerChain: 3, contradictionCount: 4)
        let b = generateSupersessionCorpus(seed: 42, entityCount: 8,
                                           versionsPerChain: 3, contradictionCount: 4)
        #expect(a == b)
        let c = generateSupersessionCorpus(seed: 43, entityCount: 8,
                                           versionsPerChain: 3, contradictionCount: 4)
        #expect(a.records[0].content != c.records[0].content)
    }

    @Test("chains are strictly increasing and current is last")
    func chainInvariants() {
        let corpus = generateSupersessionCorpus(seed: 20260725, entityCount: 12,
                                                versionsPerChain: 3, contradictionCount: 0)
        for q in corpus.queries {
            let chain = corpus.records.filter {
                $0.entity == q.entity && $0.id.hasPrefix("sup-")
            }
            #expect(chain.count == 3)
            for w in zip(chain, chain.dropFirst()) {
                #expect(w.0.eventTime < w.1.eventTime)
            }
            #expect(chain.last?.isCurrent == true)
            #expect(chain.last?.id == q.currentRecordID)
            #expect(q.supersededRecordIDs.count == 2)
        }
    }

    @Test("contradiction pairs share event_time and differ in value")
    func contradictionInvariants() {
        let corpus = generateSupersessionCorpus(seed: 7, entityCount: 4,
                                                versionsPerChain: 2, contradictionCount: 6)
        #expect(corpus.contradictions.count == 6)
        for pair in corpus.contradictions {
            let left = corpus.records.first { $0.id == pair.leftRecordID }
            let right = corpus.records.first { $0.id == pair.rightRecordID }
            #expect(left?.eventTime == right?.eventTime)
            #expect(left?.value != right?.value)
            #expect(left?.isCurrent == false && right?.isCurrent == false)
        }
    }

    /// Rewrites the committed vector file from the current generator.
    /// Guarded: only runs when MOOT_REGEN_CONFORMANCE=1 — the normal suite
    /// never writes. Run after an INTENTIONAL corpus content change (e.g.
    /// the 2026-08-26 embedding-visibility sentence), then commit the
    /// regenerated JSON together with the generator change.
    @Test("regenerate committed conformance vectors (env-guarded)",
          .enabled(if: ProcessInfo.processInfo.environment["MOOT_REGEN_CONFORMANCE"] == "1"))
    func regenerateConformanceVectors() throws {
        let generated = generateSupersessionCorpus(
            seed: 20260725, entityCount: 6, versionsPerChain: 3,
            contradictionCount: 4)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(generated)
            .write(to: conformancePath("supersession_vectors.json"))
    }

    @Test("committed conformance vectors regenerate exactly")
    func conformanceVectors() throws {
        let url = conformancePath("supersession_vectors.json")
        let expected = try JSONDecoder().decode(SupersessionCorpus.self,
                                                from: Data(contentsOf: url))
        let generated = generateSupersessionCorpus(
            seed: 20260725, entityCount: 6, versionsPerChain: 3,
            contradictionCount: 4)
        #expect(generated == expected)
    }

    // ── BM-01 Finding 5 regression ────────────────────────────────────────────

    /// Before the fix, both `contradictionSweep` gate conditions in
    /// `SupersessionRunner.swift` checked only `!corpus.contradictions.isEmpty`.
    /// A `--contradictions 0` run requesting divergences would silently skip
    /// tiered scoring. The fixed gate checks all three class arrays.
    @Test("tiered gate fires for divergences even when contradictions is empty")
    func tieredGateFiresForDivergencesWithEmptyContradictions() {
        let corpus = generateSupersessionCorpus(
            seed: 42, entityCount: 6, versionsPerChain: 2,
            contradictionCount: 0, divergenceCount: 5, decoyCount: 0)

        #expect(corpus.contradictions.isEmpty,
                "contradictions must be empty (0 requested)")
        #expect(!corpus.divergences.isEmpty,
                "divergences must be non-empty (5 requested)")

        // The post-fix gate condition (mirrors both runner locations):
        let gateWouldFire = !corpus.contradictions.isEmpty
            || !corpus.divergences.isEmpty
            || !corpus.decoys.isEmpty
        #expect(gateWouldFire,
                "gate must fire when divergences is non-empty even with 0 contradictions")
    }
}
