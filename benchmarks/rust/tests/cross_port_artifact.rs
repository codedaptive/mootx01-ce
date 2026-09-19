//! CROSS-PORT GATE — Rust decodes a Swift-written artifact.json.
//!
//! The fixture `fixtures/artifact_swift_written.json` was PRODUCED BY THE
//! SWIFT PORT's `writeArtifactProvenance` (JSONEncoder, .sortedKeys +
//! .prettyPrinted) from fixed literal inputs. This test proves the Rust
//! decoder reads the Swift writer's bytes field-for-field, and that a
//! decoded artifact validates cleanly against an identically-configured
//! Rust expectation — the property cross-port cache sharing rests on. The
//! Swift twin (ArtifactManifestTests.swift `decodesRustWrittenArtifact`)
//! decodes the Rust-written fixture.

use mcp_benchmarker_rs::artifact_manifest::{load_artifact_provenance, ArtifactProvenance};

#[test]
fn decodes_swift_written_artifact() {
    // load_artifact_provenance expects the entry DIRECTORY containing
    // artifact.json; stage the fixture into one so the production loader
    // (not a bare serde call) is what this gate exercises.
    let fixture = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/artifact_swift_written.json");
    let entry = std::env::temp_dir().join(format!("cross-port-artifact-{}", std::process::id()));
    std::fs::create_dir_all(&entry).unwrap();
    std::fs::copy(&fixture, entry.join("artifact.json")).unwrap();

    let p = load_artifact_provenance(&entry)
        .expect("Rust must decode a Swift-written artifact.json");
    let _ = std::fs::remove_dir_all(&entry);

    assert_eq!(p.format_version, 3);
    assert_eq!(p.benchmark, "crossport");
    assert_eq!(p.variant, "s");
    assert_eq!(p.seed, 424242);
    assert_eq!(p.encode_barrier, "drain");
    assert_eq!(p.estate_posture, "plaintext-optout");
    assert_eq!(p.seed_path, "batch");
    assert_eq!(p.corpus_digest, "cafef00d");
    assert_eq!(p.embedding_models, vec!["binary-default".to_string()]);
    assert_eq!(p.mootx01_version, "unknown");
    assert_eq!(p.protocol_version, "test-protocol");
    assert!(p.markers_present);
    assert_eq!(p.estate_schema_version, "1.1");

    // A run expecting exactly this configuration must accept the artifact.
    let expected = ArtifactProvenance {
        format_version: 3,
        benchmark: "crossport".to_string(),
        variant: "s".to_string(),
        seed: 424242,
        encode_barrier: "drain".to_string(),
        estate_posture: "plaintext-optout".to_string(),
        seed_path: "batch".to_string(),
        corpus_digest: "cafef00d".to_string(),
        embedding_models: vec!["binary-default".to_string()],
        mootx01_version: "unknown".to_string(),
        protocol_version: "test-protocol".to_string(),
        markers_present: true,
        estate_schema_version: "1.1".to_string(),
    };
    assert!(
        p.mismatches(&expected).is_empty(),
        "a Swift-written artifact must validate cleanly against the same run configuration"
    );
}
