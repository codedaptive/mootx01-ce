// FDCMatcherInternedGoldenTests.swift
//
// Golden-anchor conformance test for FDCMatcher runtime anchors. These anchors
// pin the current hierarchy-first classifier behavior so Swift and Rust keep the
// same code/QID output across matcher refactors.
//
// Purpose: assert that (code: String?, conceptQID: String?) from
// FDCMatcher.encodeAnchor stays stable for the current classifier contract. The
// QID is the strongest Q-ID term that supports the winning code, so divergence
// means either scoring, bag-building, or winner-supported provenance changed.
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

/// 23 golden anchors for the current hierarchy-first FDC classifier.
private let goldenAnchors: [GoldenAnchor] = [
    // From fdc_conformance.json and focused historical failure vectors.
    GoldenAnchor(
        input: "machine learning neural networks artificial intelligence",
        code: "004", qid: "Q11019"),
    GoldenAnchor(
        input: "computer graphics rendering visualization",
        code: "006.6", qid: "Q274988"),
    GoldenAnchor(
        input: "software engineering algorithms data structures",
        code: "004", qid: "Q2466334"),
    GoldenAnchor(
        input: "web development HTML programming",
        code: "005", qid: "Q2740926"),
    GoldenAnchor(
        input: "distributed systems cloud computing",
        code: "004", qid: "Q1"),
    GoldenAnchor(
        input: "geology rocks minerals earth science",
        code: "552", qid: "Q1069"),
    GoldenAnchor(
        input: "economics markets trade finance",
        code: "330", qid: "Q132510"),
    GoldenAnchor(
        input: "literature poetry novels writing",
        code: "800", qid: "Q37260"),
    GoldenAnchor(
        input: "medicine surgery treatment disease",
        code: "610", qid: "Q11190"),
    GoldenAnchor(
        input: "pharmacology drugs clinical trials",
        code: "615", qid: "Q128406"),
    GoldenAnchor(
        input: "nursing patient care hospital",
        code: "610", qid: "Q12456707"),
    GoldenAnchor(
        input: "religion theology Christianity Islam",
        code: "200", qid: "Q34178"),
    GoldenAnchor(
        input: "animal behavior mammals dogs cats",
        code: "590", qid: "Q168338"),
    GoldenAnchor(
        input: "agriculture farming crops soil",
        code: "631", qid: "Q131596"),
    GoldenAnchor(
        input: "environment climate change pollution",
        code: "363.73", qid: "Q43619"),
    GoldenAnchor(
        input: "robotics automation mechanical engineering",
        code: "621", qid: "Q184199"),
    GoldenAnchor(
        input: "materials science metals polymers",
        code: "668", qid: "Q336"),
    // Additional diverse inputs (biology, math, astronomy, etc.)
    GoldenAnchor(
        input: "Biology is the scientific study of life and living organisms including their physical structure chemical processes molecular interactions physiological mechanisms and evolution",
        code: "570", qid: "Q1053535"),
    GoldenAnchor(
        input: "mathematics algebra calculus geometry topology number theory",
        code: "510", qid: "Q1093379"),
    GoldenAnchor(
        input: "astronomy stars planets galaxies universe cosmology",
        code: "520", qid: "Q1059081"),
    GoldenAnchor(
        input: "music theory harmony rhythm melody composition orchestra",
        code: "780", qid: "Q170406"),
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

    /// All 23 golden anchors must match the pinned classifier contract.
    ///
    /// If any anchor fails, matcher scoring, descent, label-proof gating, or
    /// winner-supported QID provenance has drifted. Code and QID must both
    /// match: code is the primary output, and QID proves the concept provenance
    /// still belongs to the winning code.
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
