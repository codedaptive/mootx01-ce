//! fact_extraction_live_proof.rs — Live end-to-end proof for signal 14.
//!
//! Creates a SQLite estate, files one drawer with a cued factual sentence,
//! then obtains the dreaming cycle from `build_fact_extraction_cycle` (the
//! same function `runtime.rs:326` calls). Invokes the returned closure once
//! and asserts that at least one KG fact was filed.
//!
//! This test exercises the full wiring this unit built:
//!   `build_fact_extraction_cycle` → `activate_and_build_extraction_cycle`
//!   → `activate_fact_extractor` → cycle closure → `run_fact_extraction_batch`
//!
//! The live proof is gated on the actual model assets being present at their
//! known machine paths. It is tagged `#[ignore]` so the standard suite does
//! not run it on machines without the assets; invoke it explicitly with
//! `--include-ignored`.
//!
//! Command to run (from the worktree root):
//!   make test-one DIR=packages/kits/AriaMcpKit/rust \
//!        CARGO_TEST_ARGS="--test fact_extraction_live_proof -- --include-ignored"
//!
//! Assets required:
//!   /Volumes/llm_models/gguf/q8-nuextract-local/model.gguf
//!   /Volumes/llm_models/gguf/q8-nuextract-local/tokenizer.json
//!   cargo-target/debug/moot-nuextract-worker
//!     (build with: make build-one DIR=packages/kits/FactExtractionKit/rust-providers)
//!
//! Model-behaviour note:
//!   NuExtract-tiny (Qwen2 0.5B) requires epistemological cue words in the
//!   source text. Without "Evidence: <sentence>" the model leaves
//!   `evidenceQuote` as the template default, which `FactGroundingValidator`
//!   rejects at `fact_extraction_kit/src/validator.rs` (unsupported values).
//!   Without "Asserted:" the model leaves `assertionKind` as "" (template
//!   default), which `into_candidate()` rejects at
//!   `fact_extraction_kit/src/candidate.rs` (empty assertion kind).
//!   The cued content in step 5 is what this model needs; it is NOT a pattern
//!   a typical user would write. Whether the product ships a model that
//!   requires cue words is a ruling, not a coding change.

use std::sync::Arc;
use std::path::Path;

use aria_mcp::{build_fact_extraction_cycle, estate_registry::EstateRegistry};
use genius_locus_kit::{EstatePreferenceKey, EstatePreferenceValue};
use locus_kit::frames::CaptureFrame;
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::estate_types::LatticeAnchor;

/// Live end-to-end proof: the cycle obtained from `build_fact_extraction_cycle`
/// files at least one KG fact when invoked against a drawer with cued content.
///
/// This is the wiring proof for signal 14 — it runs through
/// `build_fact_extraction_cycle` → activation → cycle closure →
/// `run_fact_extraction_batch`, proving that all layers are wired, not just
/// the extraction duty in isolation.
///
/// Goes red when: `build_fact_extraction_cycle` returns None for a valid
/// config, the cycle closure is not wired to `run_fact_extraction_batch`, or
/// the batch returns 0 facts for a drawer with correctly cued content.
///
/// Ignored by default; run explicitly with --include-ignored.
#[test]
#[ignore = "requires model assets on /Volumes/llm_models and the built worker binary"]
fn live_proof_cycle_from_build_fact_extraction_cycle_files_at_least_one_fact() {
    // ----------------------------------------------------------------
    // 1. Locate assets.
    // ----------------------------------------------------------------
    let worktree = std::env::var("CARGO_MANIFEST_DIR")
        .map(|m| {
            // CARGO_MANIFEST_DIR = packages/kits/AriaMcpKit/rust → ../../../../
            std::path::PathBuf::from(&m)
                .ancestors()
                .nth(4)
                .unwrap()
                .to_path_buf()
        })
        .unwrap_or_else(|_| std::path::PathBuf::from("."));

    let worker_exe = worktree.join("cargo-target/debug/moot-nuextract-worker");
    // q8 is the fastest model on this machine and sufficient for the live proof.
    let gguf = Path::new("/Volumes/llm_models/gguf/q8-nuextract-local/model.gguf");
    let tokenizer = Path::new("/Volumes/llm_models/gguf/q8-nuextract-local/tokenizer.json");

    for (label, path) in [
        ("worker", worker_exe.as_path()),
        ("gguf", gguf),
        ("tokenizer", tokenizer),
    ] {
        assert!(
            path.exists(),
            "live proof requires {label} at {}; build with candle feature or provision the model",
            path.display()
        );
    }

    // ----------------------------------------------------------------
    // 2. Build a scratch config.json pointing at the real model assets.
    //    `build_fact_extraction_cycle` reads these four paths to construct
    //    the NuExtractWorkerClient. This is the same mechanism the daemon
    //    uses in production; `config_dir` is injected so no real
    //    ~/Library/Application Support is read.
    // ----------------------------------------------------------------
    let scratch_root = std::env::temp_dir().join("mootx01-fact-extraction-live-proof");
    let scratch_dir = scratch_root.as_path();
    std::fs::create_dir_all(scratch_dir).expect("create scratch dir");

    // Write config.json with all four fact_extraction paths.
    let config_json = format!(
        r#"{{"fact_extraction":{{"worker_executable":"{worker}","gguf":"{gguf}","tokenizer":"{tok}","model_version":"q8-2026-09-14"}}}}"#,
        worker = worker_exe.display(),
        gguf = gguf.display(),
        tok = tokenizer.display(),
    );
    let config_path = scratch_dir.join("config.json");
    std::fs::write(&config_path, &config_json).expect("write scratch config.json");

    // ----------------------------------------------------------------
    // 3. Create a SQLite estate at the scratch path.
    // ----------------------------------------------------------------
    let estate_dir = scratch_dir.join("estate");
    std::fs::create_dir_all(&estate_dir).expect("create estate dir");
    let db_path = estate_dir.join("live-proof.sqlite");
    // Remove any stale estate from a prior run so we start clean.
    let _ = std::fs::remove_file(&db_path);

    let registry = EstateRegistry::new_sqlite(
        db_path.to_str().expect("UTF-8 path"),
        "live-proof-owner",
    )
    .expect("open SQLite estate");

    let coord = Arc::clone(&registry.coord);
    let handle = registry.default.handle;

    // ----------------------------------------------------------------
    // 4. Provision fact extraction as On (the default, but explicit).
    // ----------------------------------------------------------------
    {
        let coord_guard = coord.lock().unwrap();
        coord_guard
            .provision_preference(&handle, EstatePreferenceKey::FactExtraction, EstatePreferenceValue::On)
            .expect("provision fact extraction On");
    }

    // ----------------------------------------------------------------
    // 5. Obtain the dreaming cycle from `build_fact_extraction_cycle`.
    //    This exercises the full wiring: config load → client build →
    //    activation → cycle closure. The same path `runtime.rs:326` takes.
    // ----------------------------------------------------------------
    let cycle = build_fact_extraction_cycle(&coord, handle, Some(scratch_dir))
        .expect("build_fact_extraction_cycle must return Some with valid config and On setting");

    // ----------------------------------------------------------------
    // 6. File one drawer with cued content.
    //
    //    Content format is calibrated for the NuExtract-tiny model (Qwen2 0.5B).
    //    The model reads the source text to fill the extraction schema:
    //
    //      - "Evidence: <sentence>" → model cites that sentence as
    //        evidenceQuote, which is then exact-matched against the source by
    //        FactGroundingValidator.
    //      - "Asserted:" → model maps the cue word to assertionKind="asserted".
    //
    //    Without these cues the model leaves assertionKind="" (template default,
    //    rejected by into_candidate at fact_extraction_kit/src/candidate.rs) and
    //    cites unrelated sentences as evidence (rejected by FactGroundingValidator
    //    at fact_extraction_kit/src/validator.rs because evidenceQuote must
    //    contain all grounding tokens from subject and object).
    //
    //    This is standard NuExtract usage (cue words guide schema filling).
    //    Both sentences are plainly factual about the Eiffel Tower.
    // ----------------------------------------------------------------
    let content = "Evidence: The Eiffel Tower stands in Paris, France. \
                   Asserted: The Eiffel Tower location is Paris, France.";

    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;

    // File via the coordinator's capture path so the audit trail and bits
    // are set exactly as in production.
    let drawer = {
        let coord_guard = coord.lock().unwrap();
        let frame = CaptureFrame::new(
            content,
            CaptureChannel::Typed,
            "live-proof/eiffel",
            LatticeAnchor::udc("0"),
            "live-proof",
            "test-v1",
        );
        coord_guard
            .capture(&handle, frame, now)
            .expect("capture must succeed")
    };
    eprintln!("live proof: filed drawer uuid={}", drawer.id);

    // ----------------------------------------------------------------
    // 7. Invoke the cycle closure once and assert ≥1 fact filed.
    //    `cycle()` calls `run_fact_extraction_batch` via the closure
    //    that `build_fact_extraction_cycle` returned in step 5.
    // ----------------------------------------------------------------
    let facts_filed = cycle().expect("cycle closure must return Ok");

    eprintln!("live proof: cycle returned facts_filed={facts_filed} for drawer {}", drawer.id);

    assert!(
        facts_filed >= 1,
        "at least one KG fact must be filed for the Eiffel Tower drawer; \
         got facts_filed={facts_filed}"
    );

    eprintln!(
        "live proof PASS: {} KG fact(s) filed via build_fact_extraction_cycle for drawer {}",
        facts_filed,
        drawer.id,
    );
}
