// fdc_interning_golden_test.rs
//
// Golden-anchor conformance test for the FdcMatcher String→Int term-interning
// change (#31 Phase 2). These anchors were captured from the pre-interning
// Swift implementation on 2026-07-01 and verified against the Rust port via
// the existing fdc_conformance_test.rs cross-language gate.
//
// Purpose: assert that (code: Option<String>, conceptQID: Option<String>) from
// Fdc::encode_anchor is byte-identical before and after the interning refactor.
// Any code divergence → scoring-order or tie-break regression.
// Any QID divergence → dominant_qid regression (independent of interning).
//
// Matches Swift FDCMatcherInternedGoldenTests.swift. Both use the same 23
// inputs and the same expected (code, qid) pairs.

use lattice_lib::Fdc;

struct GoldenAnchor {
    input: &'static str,
    code: Option<&'static str>,
    qid: Option<&'static str>,
}

/// 23 golden anchors — captured from the pre-interning FDCMatcher on 2026-07-01.
/// Expected values are identical to those in Swift FDCMatcherInternedGoldenTests.
static GOLDEN_ANCHORS: &[GoldenAnchor] = &[
    // From fdc_conformance.json — all 17 resolved vectors
    GoldenAnchor { input: "machine learning neural networks artificial intelligence",
                   code: Some("615.892"), qid: Some("Q11019") },
    GoldenAnchor { input: "computer graphics rendering visualization",
                   code: Some("006.6"), qid: Some("Q274988") },
    GoldenAnchor { input: "software engineering algorithms data structures",
                   code: Some("004"), qid: Some("Q2466334") },
    GoldenAnchor { input: "web development HTML programming",
                   code: Some("942"), qid: Some("Q2740926") },
    GoldenAnchor { input: "distributed systems cloud computing",
                   code: Some("959"), qid: Some("Q1") },
    GoldenAnchor { input: "geology rocks minerals earth science",
                   code: Some("549"), qid: Some("Q1069") },
    GoldenAnchor { input: "economics markets trade finance",
                   code: Some("336"), qid: Some("Q132510") },
    GoldenAnchor { input: "literature poetry novels writing",
                   code: Some("823"), qid: Some("Q37260") },
    GoldenAnchor { input: "medicine surgery treatment disease",
                   code: Some("617"), qid: Some("Q11190") },
    GoldenAnchor { input: "pharmacology drugs clinical trials",
                   code: Some("615.85"), qid: Some("Q128406") },
    GoldenAnchor { input: "nursing patient care hospital",
                   code: Some("131"), qid: Some("Q12456707") },
    GoldenAnchor { input: "religion theology Christianity Islam",
                   code: Some("297"), qid: Some("Q189746") },
    GoldenAnchor { input: "animal behavior mammals dogs cats",
                   code: Some("636"), qid: Some("Q144") },
    GoldenAnchor { input: "agriculture farming crops soil",
                   code: Some("631"), qid: Some("Q131596") },
    GoldenAnchor { input: "environment climate change pollution",
                   code: Some("385"), qid: Some("Q43619") },
    GoldenAnchor { input: "robotics automation mechanical engineering",
                   code: Some("533"), qid: Some("Q170978") },
    GoldenAnchor { input: "materials science metals polymers",
                   code: Some("667"), qid: Some("Q11426") },
    // Additional diverse inputs
    GoldenAnchor {
        input: "Biology is the scientific study of life and living organisms including their physical structure chemical processes molecular interactions physiological mechanisms and evolution",
        code: Some("612.6"), qid: Some("Q9256"),
    },
    GoldenAnchor { input: "mathematics algebra calculus geometry topology number theory",
                   code: Some("513"), qid: Some("Q1093379") },
    GoldenAnchor { input: "astronomy stars planets galaxies universe cosmology",
                   code: Some("521"), qid: Some("Q1059081") },
    GoldenAnchor { input: "music theory harmony rhythm melody composition orchestra",
                   code: Some("782"), qid: Some("Q170406") },
    GoldenAnchor { input: "cooking cuisine recipes ingredients gastronomy",
                   code: Some("641"), qid: Some("Q10675206") },
    GoldenAnchor { input: "photography film camera exposure lens aperture",
                   code: Some("778"), qid: Some("Q11633") },
];

/// All 23 golden anchors must survive the String→Int term-interning refactor.
///
/// Exact port of Swift `FDCMatcherInternedGoldenTests.allGoldenAnchorsMatch`.
/// Both ports must produce the same (code, qid) pairs for every input.
#[test]
fn fdc_interning_all_golden_anchors_match() {
    assert!(
        Fdc::is_available(),
        "bundled FDC artifacts must be available for golden-anchor test"
    );

    let mut failures: Vec<String> = Vec::new();

    for anchor in GOLDEN_ANCHORS {
        let (got_code, got_qid) = Fdc::encode_anchor(anchor.input);
        let expected_code: Option<String> = anchor.code.map(|s| s.to_owned());
        let expected_qid: Option<String> = anchor.qid.map(|s| s.to_owned());

        if got_code != expected_code {
            failures.push(format!(
                "CODE MISMATCH input={:?} expected={:?} got={:?}",
                &anchor.input[..anchor.input.len().min(40)],
                anchor.code,
                got_code
            ));
        }
        if got_qid != expected_qid {
            failures.push(format!(
                "QID  MISMATCH input={:?} expected={:?} got={:?}",
                &anchor.input[..anchor.input.len().min(40)],
                anchor.qid,
                got_qid
            ));
        }
    }

    if !failures.is_empty() {
        let report = failures.join("\n");
        panic!(
            "FdcMatcher interning golden-anchor conformance FAILED ({} mismatches):\n{}",
            failures.len(),
            report
        );
    }

    println!(
        "FdcMatcher interning: all {} golden anchors match",
        GOLDEN_ANCHORS.len()
    );
}

/// Non-recording path must produce the same anchor as the recording path.
/// encode_anchor_no_record must be byte-identical to encode_anchor after
/// the interning refactor — interning must not introduce a divergence between
/// the two code paths.
///
/// Mirrors Swift `FDCMatcherInternedGoldenTests.recordNovelPathsAgree`.
#[test]
fn fdc_interning_record_novel_paths_agree() {
    assert!(Fdc::is_available(), "bundled FDC artifacts required");

    for anchor in GOLDEN_ANCHORS.iter().filter(|a| a.code.is_some()) {
        let recording = Fdc::encode_anchor(anchor.input);
        let non_recording = Fdc::encode_anchor_no_record(anchor.input);

        assert_eq!(
            recording.0, non_recording.0,
            "encode_anchor_no_record code diverged from encode_anchor on {:?}",
            &anchor.input[..anchor.input.len().min(40)]
        );
        assert_eq!(
            recording.1, non_recording.1,
            "encode_anchor_no_record QID diverged from encode_anchor on {:?}",
            &anchor.input[..anchor.input.len().min(40)]
        );
    }
}
