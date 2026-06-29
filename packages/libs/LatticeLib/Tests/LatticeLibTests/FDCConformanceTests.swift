// FDCConformanceTests.swift
//
// Swift half of the FDC Swift↔Rust cross-language conformance gate.
//
// Reads the shared fixture at rust/tests/fixtures/fdc_conformance.json
// using a compile-time path anchor so no resource bundling is required.
// The Rust half lives in rust/tests/fdc_conformance_test.rs and reads
// the same file via include_bytes!.
//
// Conformance structure:
//
//   * Every vector is an HMM baseline vector. The Swift leg exercises
//     the deterministic HMM path on every platform, including Apple.
//     This matches the production `FDC.encode` / `FDC.encodeAnchor` path,
//     which uses HMM everywhere (HMM is the default; NLTagger is opt-in only).
//
//   * Apple NLTagger is the opt-in path activated only when an estate is
//     configured with `NovelTokenTaggerChoice.nlTagger`. It is outside this
//     conformance gate and is NOT exercised or treated as a baseline here.
//
// Seed: N/A (determinism comes from the pinned artifacts and algorithm,
// not from a hash-family seed).

import Testing
import Foundation
@testable import LatticeLib

// MARK: - Vector schema (mirrors the Rust ConformanceVector struct)

private struct ConformanceVector: Decodable {
    /// The input text.
    let input: String
    /// The expected FDC code, or nil for UNRESOLVED (no-code cases omit
    /// the `code` key in the JSON — the schema uses presence/absence,
    /// not explicit null).
    let code: String?
}

// MARK: - HMM-only test harness

/// Test-only HMM encoder for the shared FDC vectors.
///
/// Production `FDC.encode` intentionally has no public tagger-choice parameter.
/// This conformance test is narrower: prove Swift's deterministic HMM path
/// still produces the Rust-HMM fixture values on every platform. It therefore
/// builds the concept bag through `BagBuilder.bag(..., taggerChoice: .hmm)` and
/// applies the same pinned-resource matching rules the runtime uses.
private struct HMMFDCConformanceHarness {
    private struct SignaturesFile: Decodable {
        struct Entry: Decodable { let code: String; let terms: [String] }
        let codes: [Entry]
    }

    private let lexicon: CanonicalizationLexicon
    private let frame: FDCFrame
    private let sigTerms: [String: Set<String>]
    private let index: [String: [String]]
    private let idf: [String: Double]

    static func load(sourceFile: String = #filePath) throws -> HMMFDCConformanceHarness {
        let thisFile = URL(fileURLWithPath: sourceFile)
        let packageRoot = thisFile
            .deletingLastPathComponent()  // LatticeLibTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // package root (LatticeLib/)
        let resourceRoot = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("LatticeLib")
            .appendingPathComponent("Resources")

        func loadResource<T: Decodable>(_ name: String) throws -> T {
            let url = resourceRoot.appendingPathComponent(name).appendingPathExtension("json")
            let data = try #require(
                try? Data(contentsOf: url),
                "\(name).json must be readable at \(url.path)"
            )
            return try JSONDecoder().decode(T.self, from: data)
        }

        let lexicon: CanonicalizationLexicon = try loadResource("Lexicon")
        let frame: FDCFrame = try loadResource("FDCFrame")
        let signatures: SignaturesFile = try loadResource("FDCSignatures")
        return HMMFDCConformanceHarness(
            lexicon: lexicon,
            frame: frame,
            entries: signatures.codes
        )
    }

    private init(
        lexicon: CanonicalizationLexicon,
        frame: FDCFrame,
        entries: [SignaturesFile.Entry]
    ) {
        self.lexicon = lexicon
        self.frame = frame

        var termsByCode: [String: Set<String>] = [:]
        var idx: [String: [String]] = [:]
        for entry in entries {
            let terms = Set(entry.terms)
            termsByCode[entry.code] = terms
            for term in terms {
                idx[term, default: []].append(entry.code)
            }
        }
        for key in idx.keys {
            idx[key]!.sort()
        }
        self.sigTerms = termsByCode
        self.index = idx

        var df: [String: Int] = [:]
        for terms in termsByCode.values {
            for term in terms {
                df[term, default: 0] += 1
            }
        }
        let n = Double(termsByCode.count)
        var idfMap: [String: Double] = [:]
        for (term, count) in df {
            idfMap[term] = count > 0 ? Foundation.log(n / Double(count)) : 0
        }
        self.idf = idfMap
    }

    func encode(_ text: String) -> String? {
        let bag = BagBuilder.bag(text, lexicon: lexicon, taggerChoice: .hmm)
        guard !bag.isEmpty else { return nil }

        var candidateSet: Set<String> = []
        for (term, _) in bag {
            guard let codes = index[term] else { continue }
            for code in codes {
                candidateSet.insert(code)
            }
        }
        guard !candidateSet.isEmpty else { return nil }

        let candidates = candidateSet.sorted()

        var node = ""
        var nodeScore = -Double.greatestFiniteMagnitude
        for code in candidates {
            let s = score(code: code, bag: bag)
            if s > nodeScore || (s == nodeScore && code < node) {
                node = code
                nodeScore = s
            }
        }

        // Mirror FDCMatcher.maximumTiedWinnersForClassification: when many codes
        // share the argmax score the bag is dominated by common cross-domain Q-IDs
        // with near-zero IDF. The tie-break then selects an arbitrary code rather
        // than a semantically grounded one. Return UNRESOLVED.
        let tiedCount = candidates.filter { score(code: $0, bag: bag) == nodeScore }.count
        guard tiedCount <= FDCMatcher.maximumTiedWinnersForClassification else { return nil }

        while true {
            var best: String?
            var bestScore = 0.0
            for child in frame.children(of: node) {
                guard sigTerms[child.code] != nil else { continue }
                guard rawOverlap(code: child.code, bag: bag) >= FDC.stopThreshold else { continue }
                let s = score(code: child.code, bag: bag)
                if best == nil || s > bestScore || (s == bestScore && child.code < best!) {
                    best = child.code
                    bestScore = s
                }
            }
            guard let next = best else { break }
            node = next
        }

        return node
    }

    private func score(code: String, bag: ConceptBag) -> Double {
        guard let terms = sigTerms[code] else { return 0 }
        var score = 0.0
        for term in terms.filter({ bag[$0] != nil }).sorted() {
            score += Double(bag[term]!) * (idf[term] ?? 0)
        }
        return score
    }

    private func rawOverlap(code: String, bag: ConceptBag) -> Int {
        guard let terms = sigTerms[code] else { return 0 }
        var overlap = 0
        for (term, count) in bag where terms.contains(term) {
            overlap += count
        }
        return overlap
    }
}

// MARK: - Conformance test

@Suite("FDC Swift/Rust conformance vectors")
struct FDCConformanceTests {

    /// Loads the shared conformance fixture using a compile-time path anchor.
    ///
    /// `#filePath` resolves to this source file's absolute path at compile
    /// time. The fixture lives at rust/tests/fixtures/fdc_conformance.json
    /// relative to the LatticeLib package root. We walk up three directories
    /// from this test file (LatticeLibTests/ → Tests/ → package root)
    /// then down to rust/tests/fixtures/.
    ///
    /// This avoids resource bundling (which would create a separate test
    /// bundle and break the existing FDCSignaturesArtifactTests that rely on
    /// Bundle.module resolving to the main LatticeLib target's bundle).
    private func loadVectors(sourceFile: String = #filePath) throws -> [ConformanceVector] {
        // __file is in Tests/LatticeLibTests/FDCConformanceTests.swift.
        // Walk: ← FDCConformanceTests.swift (filename)
        //       ← LatticeLibTests/      (1 up)
        //       ← Tests/               (2 up)
        //       → rust/tests/fixtures/fdc_conformance.json (package root + path)
        let thisFile = URL(fileURLWithPath: sourceFile)
        let packageRoot = thisFile
            .deletingLastPathComponent()  // LatticeLibTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // package root (LatticeLib/)
        let fixtureURL = packageRoot
            .appendingPathComponent("rust")
            .appendingPathComponent("tests")
            .appendingPathComponent("fixtures")
            .appendingPathComponent("fdc_conformance.json")

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let data = try #require(
            try? Data(contentsOf: fixtureURL),
            "fdc_conformance.json must be readable at \(fixtureURL.path)"
        )
        return try decoder.decode([ConformanceVector].self, from: data)
    }

    /// Every vector in the shared fixture must produce the expected Rust-HMM
    /// code (or nil for UNRESOLVED) from Swift's explicit HMM path. This test
    /// never calls NLTagger and never skips Apple-only divergences.
    @Test("all HMM conformance vectors match")
    func allConformanceVectorsMatch() throws {
        let vectors = try loadVectors()
        #expect(!vectors.isEmpty, "fixture must contain at least one vector")
        #expect(FDC.isAvailable, "bundled FDC artifacts must load")
        let harness = try HMMFDCConformanceHarness.load()

        var failures: [String] = []
        for v in vectors {
            let got = harness.encode(v.input)
            if got != v.code {
                failures.append(
                    "MISMATCH input=\(v.input.debugDescription) expected=\(v.code.map { "\"\($0)\"" } ?? "nil") got=\(got.map { "\"\($0)\"" } ?? "nil")"
                )
            }
        }

        let report = failures.joined(separator: "\n")
        #expect(
            failures.isEmpty,
            "FDC HMM conformance FAILED: \(failures.count)/\(vectors.count) vectors diverge:\n\(report)"
        )
    }

    /// Regenerate the shared conformance fixture with the current HMM encoder
    /// output. Only runs when the REGEN_FDC_FIXTURE env var is set to "1".
    ///
    /// Usage: REGEN_FDC_FIXTURE=1 swift test --filter regenerateConformanceFixture
    ///
    /// After running, verify the fixture looks sane (many nil codes is expected
    /// now that the tie-count guard filters degenerate bags), then commit it.
    @Test("regenerate conformance fixture (REGEN_FDC_FIXTURE=1 only)")
    func regenerateConformanceFixture() throws {
        guard ProcessInfo.processInfo.environment["REGEN_FDC_FIXTURE"] == "1" else {
            // Skip silently — this is an operator-triggered action, not a
            // routine assertion.
            return
        }

        let vectors = try loadVectors()
        let harness = try HMMFDCConformanceHarness.load()

        // Produce updated vectors: keep the same input strings but replace
        // the expected codes with what the new encoder actually produces.
        struct OutputVector: Encodable {
            let input: String
            let code: String?
        }
        let updated = vectors.map { v in
            OutputVector(input: v.input, code: harness.encode(v.input))
        }

        // Locate the fixture file the same way loadVectors() does.
        let sourceFile = #filePath
        let thisFile = URL(fileURLWithPath: sourceFile)
        let packageRoot = thisFile
            .deletingLastPathComponent()  // LatticeLibTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // package root (LatticeLib/)
        let fixtureURL = packageRoot
            .appendingPathComponent("rust")
            .appendingPathComponent("tests")
            .appendingPathComponent("fixtures")
            .appendingPathComponent("fdc_conformance.json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(updated)
        try data.write(to: fixtureURL, options: .atomic)

        // Report what changed.
        let nilCount = updated.filter { $0.code == nil }.count
        print("Regenerated \(fixtureURL.path)")
        print("  total vectors: \(updated.count)")
        print("  UNRESOLVED (nil): \(nilCount)")
        print("  resolved: \(updated.count - nilCount)")
    }
}
