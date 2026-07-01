// FDCMatcherInternedGoldenTests.swift
//
// Golden-anchor conformance test for the FDCMatcher String→Int term-interning
// change (#31 Phase 2). These anchors were captured from the pre-interning
// implementation on 2026-07-01 and hardcoded here to serve as a regression gate.
//
// Purpose: assert that inlining (code: String?, conceptQID: String?) from
// FDCMatcher.encodeAnchor is byte-identical before and after the interning
// refactor. Because dominantQID uses the original String bag (independent of
// the interning structures), any QID divergence would indicate a bag-building
// regression. Any code divergence would indicate a scoring-order or tie-break
// regression.
//
// Both Swift and Rust run the same inputs; Swift↔Rust parity is enforced by
// the existing FDCConformanceTests.swift (which checks code only). This file
// adds a QID-inclusive layer on top.

import Testing
import Foundation
@testable import LatticeLib

// MARK: - Golden pair table

/// A captured (input, expected code, expected QID) triple.
private struct GoldenAnchor {
    let input: String
    let code: String?     // nil = UNRESOLVED
    let qid:  String?     // nil = no Wikidata Q-ID in bag
}

/// 23 golden anchors captured from the pre-interning FDCMatcher on 2026-07-01.
/// The expected values are the exact return values of FDC.encodeAnchor(input)
/// at that commit. Any change in output after the interning refactor is a
/// conformance failure.
private let goldenAnchors: [GoldenAnchor] = [
    // From fdc_conformance.json — all 17 resolved vectors
    GoldenAnchor(
        input: "machine learning neural networks artificial intelligence",
        code: "615.892", qid: "Q11019"),
    GoldenAnchor(
        input: "computer graphics rendering visualization",
        code: "006.6", qid: "Q274988"),
    GoldenAnchor(
        input: "software engineering algorithms data structures",
        code: "004", qid: "Q2466334"),
    GoldenAnchor(
        input: "web development HTML programming",
        code: "942", qid: "Q2740926"),
    GoldenAnchor(
        input: "distributed systems cloud computing",
        code: "959", qid: "Q1"),
    GoldenAnchor(
        input: "geology rocks minerals earth science",
        code: "549", qid: "Q1069"),
    GoldenAnchor(
        input: "economics markets trade finance",
        code: "336", qid: "Q132510"),
    GoldenAnchor(
        input: "literature poetry novels writing",
        code: "823", qid: "Q37260"),
    GoldenAnchor(
        input: "medicine surgery treatment disease",
        code: "617", qid: "Q11190"),
    GoldenAnchor(
        input: "pharmacology drugs clinical trials",
        code: "615.85", qid: "Q128406"),
    GoldenAnchor(
        input: "nursing patient care hospital",
        code: "131", qid: "Q12456707"),
    GoldenAnchor(
        input: "religion theology Christianity Islam",
        code: "297", qid: "Q189746"),
    GoldenAnchor(
        input: "animal behavior mammals dogs cats",
        code: "636", qid: "Q144"),
    GoldenAnchor(
        input: "agriculture farming crops soil",
        code: "631", qid: "Q131596"),
    GoldenAnchor(
        input: "environment climate change pollution",
        code: "385", qid: "Q43619"),
    GoldenAnchor(
        input: "robotics automation mechanical engineering",
        code: "533", qid: "Q170978"),
    GoldenAnchor(
        input: "materials science metals polymers",
        code: "667", qid: "Q11426"),
    // Additional diverse inputs (biology, math, astronomy, etc.)
    GoldenAnchor(
        input: "Biology is the scientific study of life and living organisms including their physical structure chemical processes molecular interactions physiological mechanisms and evolution",
        code: "612.6", qid: "Q9256"),
    GoldenAnchor(
        input: "mathematics algebra calculus geometry topology number theory",
        code: "513", qid: "Q1093379"),
    GoldenAnchor(
        input: "astronomy stars planets galaxies universe cosmology",
        code: "521", qid: "Q1059081"),
    GoldenAnchor(
        input: "music theory harmony rhythm melody composition orchestra",
        code: "782", qid: "Q170406"),
    GoldenAnchor(
        input: "cooking cuisine recipes ingredients gastronomy",
        code: "641", qid: "Q10675206"),
    GoldenAnchor(
        input: "photography film camera exposure lens aperture",
        code: "778", qid: "Q11633"),
]

// MARK: - Test suite

@Suite("FDCMatcher interning golden anchors (#31 Phase 2)")
struct FDCMatcherInternedGoldenTests {

    /// All 23 golden anchors must survive the String→Int term-interning refactor.
    ///
    /// If any anchor fails, it means the interning changed tie-breaking order
    /// (ID assignment not in ascending String order), dropped a term that should
    /// score, or introduced a computation path divergence. Code and QID must
    /// both match — code because it's the primary output and QID because it
    /// verifies the independent dominantQID scan is untouched.
    @Test("all 23 golden anchors are byte-identical after interning")
    func allGoldenAnchorsMatch() throws {
        #expect(FDC.isAvailable, "bundled FDC artifacts must be available for this test")
        guard FDC.isAvailable else { return }

        var failures: [String] = []
        for anchor in goldenAnchors {
            let (gotCode, gotQID) = FDC.encodeAnchor(anchor.input)
            if gotCode != anchor.code {
                failures.append(
                    "CODE MISMATCH input=\(anchor.input.prefix(40).debugDescription) " +
                    "expected=\(anchor.code.map { "\"\($0)\"" } ?? "nil") " +
                    "got=\(gotCode.map { "\"\($0)\"" } ?? "nil")"
                )
            }
            if gotQID != anchor.qid {
                failures.append(
                    "QID  MISMATCH input=\(anchor.input.prefix(40).debugDescription) " +
                    "expected=\(anchor.qid.map { "\"\($0)\"" } ?? "nil") " +
                    "got=\(gotQID.map { "\"\($0)\"" } ?? "nil")"
                )
            }
        }
        let report = failures.joined(separator: "\n")
        #expect(
            failures.isEmpty,
            "Interning golden-anchor conformance FAILED (\(failures.count) mismatches):\n\(report)"
        )
    }

    /// Non-recording path must produce the same anchor as the recording path —
    /// interning must not introduce a divergence between the two code paths.
    @Test("recordNovel:false produces same anchor as recordNovel:true after interning")
    func recordNovelPathsAgree() throws {
        #expect(FDC.isAvailable)
        guard FDC.isAvailable else { return }
        for anchor in goldenAnchors where anchor.code != nil {
            let recording    = FDC.encodeAnchor(anchor.input, recordNovel: true)
            let nonRecording = FDC.encodeAnchor(anchor.input, recordNovel: false)
            let prefix = anchor.input.prefix(40)
            #expect(
                recording.code == nonRecording.code,
                "recordNovel code paths diverged on \(prefix.debugDescription)"
            )
            #expect(
                recording.conceptQID == nonRecording.conceptQID,
                "recordNovel QID paths diverged on \(prefix.debugDescription)"
            )
        }
    }
}
