//! The bundled FDCSignatures.json artifact contract — Rust leg of the
//! invariants `FDCSignaturesArtifactTests.swift` pins
//! (FDC_ENCODER_CANONICAL § 2/§ 7-build, cookbook § 7): source-owned
//! term lists, provenance weights, and all unique frame codes.
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
fn artifact_carries_source_ownership_with_provenance_header() {
    let a = artifact();
    assert!(!a["version"].as_str().unwrap_or("").is_empty());
    let w = &a["source_weights"];
    assert_eq!(w["label"], 3);
    assert_eq!(w["title"], 2);
    assert_eq!(w["article"], 1);
    assert_eq!(w["alias"], 4);
}

#[test]
fn all_codes_ship_sorted_and_non_empty() {
    let a = artifact();
    let codes = a["codes"].as_array().expect("codes array");
    assert_eq!(codes.len(), 1075);

    let mut prev: Option<&str> = None;
    for entry in codes {
        let code = entry["code"].as_str().expect("code string");
        if let Some(p) = prev {
            assert!(p < code, "codes sorted and unique: {p} < {code}");
        }
        prev = Some(code);

        let fields = [
            "label_terms",
            "alias_terms",
            "title_terms",
            "article_terms",
            "ancestor_terms",
        ];
        let mut own_count = 0usize;
        for field in fields {
            let terms = entry[field].as_array().expect("source term array");
            if field != "ancestor_terms" {
                own_count += terms.len();
            }
            let mut prev_term: Option<&str> = None;
            for term in terms {
                let term = term.as_str().expect("term string");
                if let Some(previous) = prev_term {
                    assert!(
                        previous < term,
                        "code {code} {field} sorted: {previous} < {term}"
                    );
                }
                prev_term = Some(term);
            }
        }
        assert!(own_count > 0, "code {code} has non-empty owned evidence");
    }
}
