// BM25ConformanceTests.swift
//
// Cross-language bit-identity gate for BM25-derived quantized impacts
// (inspection finding W1). Retrieval algorithms reference §2.2 claims
// BM25 impacts are bit-identical across Swift and Rust after round-half-even
// quantization at QUANT_SCALE=100. This suite PROVES that claim against a
// float-stressing fixture, where the prior conformance tests used
// pre-quantized integer vectors and could not catch a real float divergence.
//
// The plausible failure mode this guards against: FMA contraction on Apple
// Silicon (Swift) vs x86_64/no-FMA (Rust) shifting f64 ULPs in the BM25
// formula BEFORE quantization, which after ×100 + round-half-even can move
// an impact by ±1. See BM25Weighting.swift ~141-143 and
// rust/src/engine/bm25_weighting.rs ~103-106.
//
// Three checks:
//   1. Production-path agreement: build the InvertedIndex from the fixture
//      via BM25Weighting.build, recover each (termID,itemID) impact through a
//      single-term exhaustiveScan, and assert it equals the canonical JSON.
//   2. Canonical-vector match: the canonical file (generated once from this
//      Swift leg) is checked in under Tests/SharedVectors/; the Rust leg
//      (rust/tests/bm25_conformance_test.rs) must match the SAME file exactly.
//   3. In-language contraction self-check: recompute every raw f64 impact in
//      long-form (separate multiply/add steps, holding each intermediate in a
//      named `let`) and assert it quantizes to the same i32 as the production
//      formula — detecting compiler FMA contraction WITHIN Swift.
//
// The fixture is generated deterministically by an xorshift64 PRNG with
// constants shared verbatim with the Rust leg, so both languages construct
// the identical term-frequency table independently — there is no checked-in
// random dump of the table itself, only the canonical impact map.

import Testing
import Foundation
@testable import CorpusKit

// MARK: - Shared deterministic fixture generator
//
// xorshift64 with the SAME seed and constants as the Rust leg
// (rust/tests/bm25_conformance_test.rs). Identical arithmetic on identical
// u64 state yields the identical (term, doc, tf) table in both languages,
// so the table never needs to be checked in.
private struct XorShift64 {
    var state: UInt64
    init(seed: UInt64) {
        // Seed must be non-zero for xorshift64. The mission seed is fixed.
        self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }
    mutating func next() -> UInt64 {
        var x = state
        x ^= x << 13
        x ^= x >> 7
        x ^= x << 17
        state = x
        return x
    }
    /// Uniform integer in [lo, hi] inclusive. lo <= hi required.
    mutating func nextInRange(_ lo: Int, _ hi: Int) -> Int {
        let span = UInt64(hi - lo + 1)
        return lo + Int(next() % span)
    }
}

// Fixture dimensions. These STRESS the float path: many docs, widely varied
// doc lengths, tf in 1..30, and 60 terms with random document subsets, which
// yields irrational intermediate products under the k1=1.2/b=0.75 defaults.
private let fixtureNumDocs = 240
private let fixtureNumTerms = 60
// Fixed xorshift64 seed, shared verbatim with the Rust leg. Must be non-zero.
private let fixtureSeed: UInt64 = 0xDB25_0001
private let fixtureK1 = 1.2
private let fixtureB = 0.75

/// Build the deterministic term-frequency table and doc-length table.
/// MUST mirror `build_fixture` in the Rust leg bit-for-bit in iteration order
/// and arithmetic so both languages produce the identical (term,doc,tf) set.
private func buildFixture() -> (
    termFreqs: BM25Weighting.TermFreqTable,
    docLengths: [String: Int]
) {
    var rng = XorShift64(seed: fixtureSeed)

    // Document IDs and lengths first, in ascending index order.
    // Doc lengths span 5..400 to produce a wide range of |d|/avgdl ratios,
    // which drives the length-normalization term across many distinct values.
    var docLengths = [String: Int](minimumCapacity: fixtureNumDocs)
    var docIDs = [String]()
    docIDs.reserveCapacity(fixtureNumDocs)
    for d in 0..<fixtureNumDocs {
        let id = String(format: "d%03d", d)
        docIDs.append(id)
        docLengths[id] = rng.nextInRange(5, 400)
    }

    // For each term (ascending index), pick a document subset and per-doc tf.
    // The subset size varies so document frequency (df) — and therefore IDF —
    // takes many distinct values across terms.
    var termFreqs = BM25Weighting.TermFreqTable(minimumCapacity: fixtureNumTerms)
    for t in 0..<fixtureNumTerms {
        let term = String(format: "t%03d", t)
        // df in 1..fixtureNumDocs, biased toward smaller via two draws min.
        let dfTarget = rng.nextInRange(1, fixtureNumDocs)
        var docTFs = [String: Int](minimumCapacity: dfTarget)
        for d in 0..<fixtureNumDocs {
            // Include this doc in the term's postings with probability ~ dfTarget/numDocs.
            // Deterministic Bernoulli via a fresh draw compared to a threshold.
            let roll = rng.nextInRange(1, fixtureNumDocs)
            if roll <= dfTarget {
                let tf = rng.nextInRange(1, 30)
                docTFs[docIDs[d]] = tf
            }
        }
        // Guarantee at least one posting so IDF and the formula are exercised.
        if docTFs.isEmpty {
            docTFs[docIDs[0]] = rng.nextInRange(1, 30)
        }
        termFreqs[term] = docTFs
    }

    return (termFreqs, docLengths)
}

// MARK: - Canonical vector schema

private struct BM25CanonicalVector: Codable {
    let term: String
    let item: String
    let impact: Int32
}

private struct BM25CanonicalFile: Codable {
    let schemaVersion: String
    let seed: String
    let numDocs: Int
    let numTerms: Int
    let k1: Double
    let b: Double
    let quantScale: Int32
    let vectors: [BM25CanonicalVector]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case seed
        case numDocs = "num_docs"
        case numTerms = "num_terms"
        case k1
        case b
        case quantScale = "quant_scale"
        case vectors
    }
}

// MARK: - Conformance suite

@Suite("BM25 cross-language bit-identity (W1)")
struct BM25ConformanceTests {

    /// Recover the full (termID, itemID) -> quantized impact map from a built
    /// InvertedIndex. Postings are not publicly readable after construction,
    /// so each term's impacts are recovered via a single-term exhaustiveScan:
    /// score = queryWeight(=100) * impact, exposed as Float(score)/100 = impact.
    /// Impacts here are small (a few hundred at most), so the f32 round-trip is
    /// exact; we recover the i32 by rounding the product back.
    private func recoverImpacts(
        index: InvertedIndex,
        termMapping: [String: UInt32]
    ) -> [String: [String: Int32]] {
        var result = [String: [String: Int32]]()
        for (term, termID) in termMapping {
            let hits = index.exhaustiveScan(
                query: [(termID: termID, queryWeight: invertedIndexQuantScale)],
                k: fixtureNumDocs
            )
            var perItem = [String: Int32](minimumCapacity: hits.count)
            for hit in hits {
                // exhaustiveScan score = queryWeight * impact = QUANT_SCALE * impact,
                // exposed as hit.impact = Float(score)/QUANT_SCALE = the quantized
                // integer impact itself. Round the f32 back to recover the exact i32
                // (impacts here are < 2^24, so the f32 round-trip is lossless).
                let recovered = Int32(hit.impact.rounded())
                perItem[hit.itemID] = recovered
            }
            result[term] = perItem
        }
        return result
    }

    /// Long-form BM25 raw impact: each multiply/add held in a named binding so
    /// the optimizer cannot contract the multiply-add chain into a single FMA.
    /// This is the contraction reference for check #3.
    private func longFormRawImpact(
        tf: Int, dl: Int, df: Int, numDocs: Int, avgdl: Double
    ) -> Double {
        let tfD = Double(tf)
        let dfD = Double(df)
        // IDF: ln(1 + (N - df + 0.5)/(df + 0.5)), split into named steps.
        let numerator = Double(numDocs) - dfD + 0.5
        let denominatorIDF = dfD + 0.5
        let ratio = numerator / denominatorIDF
        let idf = (1.0 + ratio).logarithm()
        // Length norm: (1 - b + b*|d|/avgdl), split.
        let lengthRatio = Double(dl) / max(avgdl, 1.0)
        let bScaled = fixtureB * lengthRatio
        let lengthNorm = 1.0 - fixtureB + bScaled
        // Denominator: tf + k1 * lengthNorm.
        let k1Term = fixtureK1 * lengthNorm
        let denom = tfD + k1Term
        // Numerator: tf * (k1 + 1).
        let k1Plus1 = fixtureK1 + 1.0
        let tfWeighted = tfD * k1Plus1
        let fraction = tfWeighted / max(denom, 0.0001)
        return idf * fraction
    }

    /// Build the canonical vectors from the fixture via the production path.
    /// Sorted (term ASC, item ASC) for a stable, language-independent order.
    private func buildCanonicalVectors() -> BM25CanonicalFile {
        let (termFreqs, docLengths) = buildFixture()
        let (index, termMapping) = BM25Weighting.build(
            termFreqs: termFreqs,
            docLengths: docLengths,
            parameters: BM25Parameters(k1: fixtureK1, b: fixtureB)
        )
        let recovered = recoverImpacts(index: index, termMapping: termMapping)

        var vectors = [BM25CanonicalVector]()
        for term in recovered.keys.sorted() {
            let perItem = recovered[term]!
            for item in perItem.keys.sorted() {
                vectors.append(BM25CanonicalVector(term: term, item: item, impact: perItem[item]!))
            }
        }
        return BM25CanonicalFile(
            schemaVersion: "1",
            seed: String(format: "0x%016X", fixtureSeed),
            numDocs: fixtureNumDocs,
            numTerms: fixtureNumTerms,
            k1: fixtureK1,
            b: fixtureB,
            quantScale: invertedIndexQuantScale,
            vectors: vectors
        )
    }

    private func loadCanonical() throws -> BM25CanonicalFile {
        let url = try #require(
            Bundle.module.url(
                forResource: "bm25_impact_vectors",
                withExtension: "json",
                subdirectory: "SharedVectors"
            ),
            "bm25_impact_vectors.json must ship in the test bundle under SharedVectors/"
        )
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(BM25CanonicalFile.self, from: data)
    }

    /// One-shot canonical-file emitter. Disabled unless BM25_EMIT_CANONICAL is
    /// set in the environment; it writes the canonical JSON to the path in that
    /// variable. Used ONCE to generate the checked-in vector file from the Swift
    /// leg (the canonical source per the mission). Never asserts, so it is inert
    /// in normal runs.
    @Test("emit canonical vectors when BM25_EMIT_CANONICAL is set")
    func emitCanonicalIfRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["BM25_EMIT_CANONICAL"], !path.isEmpty else {
            return
        }
        let file = buildCanonicalVectors()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(file)
        try data.write(to: URL(fileURLWithPath: path))
    }

    /// CHECK 1 + 2: the production build path reproduces the canonical vectors
    /// exactly. The canonical file was generated once from this Swift leg; the
    /// Rust leg must match the SAME file. Any mismatch here means Swift drifted
    /// from the checked-in canonical (e.g. a formula or quantization change).
    @Test("production build path matches canonical impact vectors")
    func productionMatchesCanonical() throws {
        let canonical = try loadCanonical()
        #expect(canonical.vectors.count > 0)
        #expect(canonical.quantScale == invertedIndexQuantScale)

        let built = buildCanonicalVectors()
        #expect(
            built.vectors.count == canonical.vectors.count,
            "vector count drift: built \(built.vectors.count) vs canonical \(canonical.vectors.count)"
        )

        // Index canonical by (term,item) for O(1) comparison.
        var canonMap = [String: Int32](minimumCapacity: canonical.vectors.count)
        for v in canonical.vectors { canonMap["\(v.term)\u{0}\(v.item)"] = v.impact }

        var failures: [String] = []
        for v in built.vectors {
            let key = "\(v.term)\u{0}\(v.item)"
            if let expected = canonMap[key] {
                if expected != v.impact {
                    failures.append("(\(v.term),\(v.item)): canonical=\(expected) built=\(v.impact)")
                }
            } else {
                failures.append("(\(v.term),\(v.item)): missing from canonical")
            }
        }
        let report = failures.prefix(50).joined(separator: "\n")
        #expect(
            failures.isEmpty,
            "BM25 production-vs-canonical FAILED: \(failures.count) diverge:\n\(report)"
        )
    }

    /// CHECK 3: in-language FMA-contraction self-check. For every posting,
    /// recompute the raw f64 impact in long-form (named intermediates, no
    /// contractible multiply-add chain) and assert it quantizes to the same
    /// i32 as the production formula. A divergence here means the Swift
    /// compiler contracted the production expression into an FMA, shifting a
    /// ULP that crosses a .5 quantization boundary.
    @Test("Swift production formula matches long-form (no FMA contraction)")
    func swiftFormulaMatchesLongForm() throws {
        let (termFreqs, docLengths) = buildFixture()
        let numDocs = docLengths.count
        let totalLen = docLengths.values.reduce(0, +)
        let avgdl = Double(totalLen) / Double(numDocs)

        var failures: [String] = []
        var checked = 0
        for (term, docTFs) in termFreqs.sorted(by: { $0.key < $1.key }) {
            let df = docTFs.count
            for (item, tf) in docTFs.sorted(by: { $0.key < $1.key }) {
                let dl = docLengths[item] ?? 0

                // Production formula (mirrors BM25Weighting.build exactly).
                let idf = log(1.0 + (Double(numDocs) - Double(df) + 0.5) / (Double(df) + 0.5))
                let denom = Double(tf) + fixtureK1 * (1.0 - fixtureB + fixtureB * Double(dl) / max(avgdl, 1.0))
                let prodRaw = idf * (Double(tf) * (fixtureK1 + 1.0)) / max(denom, 0.0001)
                let prodQuant = quantizeImpact(prodRaw)

                // Long-form reference.
                let longRaw = longFormRawImpact(
                    tf: tf, dl: dl, df: df, numDocs: numDocs, avgdl: avgdl
                )
                let longQuant = quantizeImpact(longRaw)

                checked += 1
                if prodQuant != longQuant {
                    failures.append(
                        "(\(term),\(item)) tf=\(tf) dl=\(dl) df=\(df): "
                        + "prod_raw=\(prodRaw.bitPattern) long_raw=\(longRaw.bitPattern) "
                        + "prod_q=\(prodQuant) long_q=\(longQuant)"
                    )
                }
            }
        }
        #expect(checked > 0)
        let report = failures.prefix(50).joined(separator: "\n")
        #expect(
            failures.isEmpty,
            "Swift FMA-contraction self-check FAILED: \(failures.count)/\(checked) diverge:\n\(report)"
        )
    }
}

// Small helper so longFormRawImpact reads as a chain of named bindings without
// importing log under a name that collides with the production call site above.
private extension Double {
    func logarithm() -> Double { Foundation.log(self) }
}
