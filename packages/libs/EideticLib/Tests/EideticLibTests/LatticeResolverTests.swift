// LatticeResolverTests.swift
//
// Per-type coverage for LatticeResolver
// (Sources/EideticLib/LatticeResolver.swift): the grounding step of
// EideticLib.lookup that resolves normalized/stemmed input tokens to
// an MDCC canon entry under the deterministic ranking vector
// (exactLabel, matchedInputCount, -extraLabelTokens, -codeOrder).
//
// Documented Swift/Rust asymmetry (Known Ambiguity 1): the Rust leg's
// `lookup` returns a not_implemented sentinel and has no
// lattice_resolver.rs tests, so this resolver behavior is asserted on
// the Swift side only — no parity claim is made against Rust here.

import Testing
@testable import EideticLib
import LatticeKit

@Suite("Lattice resolver ranking")
struct LatticeResolverTests {

    /// Builds the normalized + stemmed token pair the way the lookup
    /// pipeline does: normalize each input token, then stem it.
    private func tokens(_ words: [String]) -> (normalized: [String], stemmed: [String]) {
        let normalized = words.map(Normalizer.normalize)
        return (normalized, normalized.map(Stemmer.stem))
    }

    private func entry(_ code: String, _ qid: String, _ label: String) -> LatticeEntry {
        LatticeEntry(code: code, sourceIdentity: qid, label: label, classBase: 1)
    }

    private var sampleCanon: LatticeCanon {
        LatticeCanon(canonVersion: "test", entries: [
            entry("100", "Q5891", "philosophy"),
            entry("170", "Q9415", "moral philosophy"),
            entry("540", "Q2329", "chemistry"),
        ])
    }

    @Test("empty input returns nil")
    func emptyInputReturnsNil() {
        let result = LatticeResolver.resolve(
            normalized: [], stemmed: [], canon: sampleCanon
        )
        #expect(result == nil)
    }

    @Test("no token match returns nil")
    func noTokenMatchReturnsNil() {
        let t = tokens(["zxcvqwertyasdfgh"])
        let result = LatticeResolver.resolve(
            normalized: t.normalized, stemmed: t.stemmed, canon: sampleCanon
        )
        #expect(result == nil)
    }

    @Test("exact label match resolves with high confidence")
    func exactLabelMatchResolvesWithHighConfidence() throws {
        let t = tokens(["philosophy"])
        let result = try #require(LatticeResolver.resolve(
            normalized: t.normalized, stemmed: t.stemmed, canon: sampleCanon
        ))
        #expect(result.code == "100")
        #expect(result.sourceIdentity == "Q5891")
        #expect(result.confidence == 48, "exact label name is high confidence")
    }

    @Test("concise exact label beats longer containing label")
    func conciseExactLabelBeatsLongerLabel() throws {
        // Both "philosophy" (code 100) and "moral philosophy" (170)
        // match the input; the exact, more precise label wins.
        let t = tokens(["philosophy"])
        let result = try #require(LatticeResolver.resolve(
            normalized: t.normalized, stemmed: t.stemmed, canon: sampleCanon
        ))
        #expect(result.code == "100")
    }

    @Test("full coverage by longer label is medium confidence")
    func fullCoverageByLongerLabelIsMedium() throws {
        // Only the longer label is present, so the single input token
        // is fully covered but the match is not exact.
        let canon = LatticeCanon(canonVersion: "test", entries: [
            entry("170", "Q9415", "moral philosophy"),
        ])
        let t = tokens(["philosophy"])
        let result = try #require(LatticeResolver.resolve(
            normalized: t.normalized, stemmed: t.stemmed, canon: canon
        ))
        #expect(result.code == "170")
        #expect(result.confidence == 32, "input fully covered but inexact is medium")
    }

    @Test("partial hit is low confidence")
    func partialHitIsLowConfidence() throws {
        // Two input tokens, only one matches the label — a partial hit.
        let t = tokens(["philosophy", "zzznomatch"])
        let result = try #require(LatticeResolver.resolve(
            normalized: t.normalized, stemmed: t.stemmed, canon: sampleCanon
        ))
        #expect(result.code == "100")
        #expect(result.confidence == 16, "partial hit is low confidence")
    }

    @Test("duplicate labels resolve to lowest code")
    func duplicateLabelsResolveToLowestCode() throws {
        // Identical labels rank equally on every prior key; the lowest
        // (most canonical) code is the deterministic final tiebreak.
        let canon = LatticeCanon(canonVersion: "test", entries: [
            entry("701", "Q1", "art"),
            entry("700", "Q2", "art"),
        ])
        let t = tokens(["art"])
        let result = try #require(LatticeResolver.resolve(
            normalized: t.normalized, stemmed: t.stemmed, canon: canon
        ))
        #expect(result.code == "700")
    }

    @Test("resolution is deterministic")
    func resolutionIsDeterministic() {
        let t = tokens(["philosophy"])
        let a = LatticeResolver.resolve(
            normalized: t.normalized, stemmed: t.stemmed, canon: sampleCanon
        )
        let b = LatticeResolver.resolve(
            normalized: t.normalized, stemmed: t.stemmed, canon: sampleCanon
        )
        #expect(a == b)
    }
}
