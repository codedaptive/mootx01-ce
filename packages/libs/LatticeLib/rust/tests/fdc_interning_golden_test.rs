// fdc_interning_golden_test.rs
//
// Golden-anchor conformance test for FdcMatcher runtime anchors. These anchors
// pin the current hierarchy-first classifier behavior so Swift and Rust keep the
// same code/QID output across matcher refactors.
//
// Purpose: assert that (code: Option<String>, conceptQID: Option<String>) from
// Fdc::encode_anchor stays stable for the current classifier contract. Any code
// divergence means scoring, descent, or source-evidence drift; any QID divergence
// means winner-supported concept provenance changed.
//
// Matches Swift FDCMatcherInternedGoldenTests.swift. Both use the same 23
// inputs and the same expected (code, qid) pairs.

use lattice_lib::Fdc;

struct GoldenAnchor {
    input: &'static str,
    code: Option<&'static str>,
    qid: Option<&'static str>,
}

/// 23 golden anchors for the current hierarchy-first FDC classifier.
/// Expected values are identical to those in Swift
/// FDCMatcherInternedGoldenTests.
static GOLDEN_ANCHORS: &[GoldenAnchor] = &[
    // From fdc_conformance.json and focused historical failure vectors.
    GoldenAnchor { input: "machine learning neural networks artificial intelligence",
                   code: Some("004"), qid: Some("Q11019") },
    GoldenAnchor { input: "computer graphics rendering visualization",
                   code: Some("006.6"), qid: Some("Q274988") },
    GoldenAnchor { input: "software engineering algorithms data structures",
                   code: Some("004"), qid: Some("Q2466334") },
    GoldenAnchor { input: "web development HTML programming",
                   code: Some("005"), qid: Some("Q2740926") },
    GoldenAnchor { input: "distributed systems cloud computing",
                   code: Some("004"), qid: Some("Q1") },
    GoldenAnchor { input: "geology rocks minerals earth science",
                   code: Some("552"), qid: Some("Q1069") },
    GoldenAnchor { input: "economics markets trade finance",
                   code: Some("330"), qid: Some("Q132510") },
    GoldenAnchor { input: "literature poetry novels writing",
                   code: Some("800"), qid: Some("Q37260") },
    GoldenAnchor { input: "medicine surgery treatment disease",
                   code: Some("610"), qid: Some("Q11190") },
    GoldenAnchor { input: "pharmacology drugs clinical trials",
                   code: Some("615"), qid: Some("Q128406") },
    GoldenAnchor { input: "nursing patient care hospital",
                   code: Some("610"), qid: Some("Q12456707") },
    GoldenAnchor { input: "religion theology Christianity Islam",
                   code: Some("200"), qid: Some("Q34178") },
    GoldenAnchor { input: "animal behavior mammals dogs cats",
                   code: Some("590"), qid: Some("Q168338") },
    GoldenAnchor { input: "agriculture farming crops soil",
                   code: Some("631"), qid: Some("Q131596") },
    GoldenAnchor { input: "environment climate change pollution",
                   code: Some("363.73"), qid: Some("Q43619") },
    GoldenAnchor { input: "robotics automation mechanical engineering",
                   code: Some("621"), qid: Some("Q184199") },
    GoldenAnchor { input: "materials science metals polymers",
                   code: Some("668"), qid: Some("Q336") },
    // Additional diverse inputs
    GoldenAnchor {
        input: "Biology is the scientific study of life and living organisms including their physical structure chemical processes molecular interactions physiological mechanisms and evolution",
        code: Some("570"), qid: Some("Q1053535"),
    },
    GoldenAnchor { input: "mathematics algebra calculus geometry topology number theory",
                   code: Some("510"), qid: Some("Q1093379") },
    GoldenAnchor { input: "astronomy stars planets galaxies universe cosmology",
                   code: Some("520"), qid: Some("Q1059081") },
    GoldenAnchor { input: "music theory harmony rhythm melody composition orchestra",
                   code: Some("780"), qid: Some("Q170406") },
    GoldenAnchor { input: "cooking cuisine recipes ingredients gastronomy",
                   code: Some("641"), qid: Some("Q10675206") },
    GoldenAnchor { input: "photography film camera exposure lens aperture",
                   code: Some("778"), qid: Some("Q11633") },
];

/// All 23 golden anchors must match the pinned classifier contract.
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
            recording.0,
            non_recording.0,
            "encode_anchor_no_record code diverged from encode_anchor on {:?}",
            &anchor.input[..anchor.input.len().min(40)]
        );
        assert_eq!(
            recording.1,
            non_recording.1,
            "encode_anchor_no_record QID diverged from encode_anchor on {:?}",
            &anchor.input[..anchor.input.len().min(40)]
        );
    }
}
