//! The bundled FDCSignatures.json artifact contract — Rust leg of the
//! invariants `FDCSignaturesArtifactTests.swift` pins
//! (FDC_ENCODER_CANONICAL § 2/§ 7-build, cookbook § 7): membership-only
//! term lists, the provenance source_weights header (never read at
//! runtime), all 1071 signature-bearing codes, sorted and non-empty.
//! Reads the SAME file the Swift bundle carries, via the repo path.

use std::path::PathBuf;

use serde_json::Value;

fn artifact() -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../Sources/LatticeLib/Resources/FDCSignatures.json");
    let bytes = std::fs::read(path).expect("bundled FDCSignatures.json");
    serde_json::from_slice(&bytes).expect("artifact parses")
}

#[test]
fn artifact_is_membership_only_with_provenance_header() {
    let a = artifact();
    assert!(!a["version"].as_str().unwrap_or("").is_empty());
    let w = &a["source_weights"];
    assert_eq!(w["label"], 3);
    assert_eq!(w["title"], 2);
    assert_eq!(w["article"], 1);
}

#[test]
fn all_codes_ship_sorted_and_non_empty() {
    let a = artifact();
    let codes = a["codes"].as_array().expect("codes array");
    assert_eq!(codes.len(), 1071);

    let mut prev: Option<&str> = None;
    for entry in codes {
        let code = entry["code"].as_str().expect("code string");
        if let Some(p) = prev {
            assert!(p < code, "codes sorted and unique: {p} < {code}");
        }
        prev = Some(code);

        let terms = entry["terms"].as_array().expect("terms array");
        assert!(!terms.is_empty(), "code {code} has a non-empty signature");
        let mut prev_term: Option<&str> = None;
        for t in terms {
            let t = t.as_str().expect("term string");
            if let Some(pt) = prev_term {
                assert!(pt < t, "code {code} terms sorted: {pt} < {t}");
            }
            prev_term = Some(t);
        }
    }
}
