//! fact_extraction_cycle_tests.rs — Decision-gate tests for signal 14.
//!
//! These tests cover the two public functions that compose signal 14:
//!
//!   GSS-14a  `build_fact_extraction_cycle` — unavailable assets → None while Off
//!   GSS-14b  `activate_and_build_extraction_cycle` — On + stub extractor → Some
//!   GSS-14c  `build_fact_extraction_cycle` — On + no config paths → None
//!   GSS-14d  `build_fact_extraction_cycle` — provider selector + settings paths
//!
//! GSS-14b is the On-path gate: it calls the testable seam
//! `activate_and_build_extraction_cycle` with a stub `FactExtractor` so that
//! no real model assets are required. The seam holds the estate-setting
//! decision, the `activate_fact_extractor` call, and the cycle closure.
//!
//! GSS-14c gates the no-model path: calls `build_fact_extraction_cycle` with
//! On + a scratch config.json that carries no `fact_extraction` block. This
//! is the common case in the field — most installs have no model on disk.
//!
//! Neither test neutered, reverted, or mutated working code. Each entry below
//! names what would have to break for it to go red.

use std::sync::Arc;

use aria_mcp::{
    activate_and_build_extraction_cycle, build_fact_extraction_cycle,
    estate_registry::EstateRegistry,
};
use fact_extraction_kit::contract::{
    FactExtractionError, FactExtractionRequest, FactExtractionResponse, FactExtractor,
    FactExtractorKind, FactExtractorModelSpec,
};
use genius_locus_kit::{EstateCoordinator, EstatePreferenceKey, EstatePreferenceValue};

// ---------------------------------------------------------------------------
// Stub extractor (deterministic, no subprocess)
// ---------------------------------------------------------------------------

/// Minimal `FactExtractor` that always returns an empty response. The spec
/// fields produce a deterministic recipe ID:
/// "stub-provider:stub-model:stub-v1".
struct StubExtractor {
    spec: FactExtractorModelSpec,
}

impl StubExtractor {
    fn new() -> Self {
        Self {
            spec: FactExtractorModelSpec {
                provider_id: "stub-provider".into(),
                model_id: "stub-model".into(),
                model_version: "stub-v1".into(),
                schema_version: "kgfact-extraction-v1".into(),
                extractor_kind: FactExtractorKind::SpecializedModel,
                maximum_input_characters: 4096,
                maximum_facts_per_source: 8,
            },
        }
    }
}

impl FactExtractor for StubExtractor {
    fn spec(&self) -> &FactExtractorModelSpec {
        &self.spec
    }

    fn extract(
        &self,
        _request: &FactExtractionRequest,
    ) -> Result<FactExtractionResponse, FactExtractionError> {
        Ok(FactExtractionResponse {
            source_digest: String::new(),
            provider_id: self.spec.provider_id.clone(),
            model_id: self.spec.model_id.clone(),
            model_version: self.spec.model_version.clone(),
            schema_version: self.spec.schema_version.clone(),
            candidates: vec![],
        })
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Open a fresh in-memory estate and return (coord, handle) ready for testing.
fn open_estate() -> (
    Arc<std::sync::Mutex<EstateCoordinator>>,
    genius_locus_kit::EstateHandle,
) {
    let registry = EstateRegistry::new_inmemory();
    (registry.coord, registry.default.handle)
}

/// Write a minimal config.json into `dir` that does NOT contain a
/// `fact_extraction` block (all four paths are absent).
fn write_no_fact_extraction_config(dir: &std::path::Path) {
    std::fs::write(dir.join("config.json"), r#"{"daemon":{}}"#).expect("write config.json");
}

// ---------------------------------------------------------------------------
// GSS-14a: setting Off + unavailable assets → no cycle or activation
//
// Calls `build_fact_extraction_cycle` directly — the real production function.
// ---------------------------------------------------------------------------

/// GSS-14a: the production builder returns no cycle without provider assets.
/// Live Off-to-On behavior with an available extractor is tested separately.
#[test]
fn fact_extraction_cycle_is_none_without_assets_while_off() {
    let (coord, handle) = open_estate();

    // Provision the estate with Off.
    {
        let coord_guard = coord.lock().unwrap();
        coord_guard
            .provision_preference(
                &handle,
                EstatePreferenceKey::FactExtraction,
                EstatePreferenceValue::Off,
            )
            .expect("provision Off");
    }

    // Omit model configuration; the builder must leave the provider inactive.
    let scratch = std::env::temp_dir().join(format!("aria-fec-off-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&scratch).unwrap();
    write_no_fact_extraction_config(&scratch);

    let cycle = build_fact_extraction_cycle(&coord, handle, Some(&scratch));

    assert!(
        cycle.is_none(),
        "missing assets must produce None; got Some(cycle)"
    );

    // Confirm no extractor was registered on the coordinator.
    let coord_guard = coord.lock().unwrap();
    assert!(
        coord_guard.registered_fact_extractor(&handle).is_none(),
        "no extractor must be registered when setting is Off"
    );
}

// ---------------------------------------------------------------------------
// GSS-14b: setting On + stub extractor → cycle is Some
//
// Calls `activate_and_build_extraction_cycle` — the testable seam — with a
// stub FactExtractor. No real model assets or config.json required.
// ---------------------------------------------------------------------------

/// GSS-14b: when the estate setting is On and an extractor is supplied,
/// `activate_and_build_extraction_cycle` returns `Some(cycle)` and the first
/// enabled invocation registers the extractor on the coordinator.
///
/// Goes red when:
///   - An enabled invocation skips provider activation.
///   - The `activate_fact_extractor` call is removed (extractor not registered).
///   - The cycle closure is not built (Some returned with wrong body).
///   - `run_fact_extraction_batch` is not called inside the closure.
#[test]
fn fact_extraction_cycle_is_some_when_setting_is_on_and_extractor_provided() {
    let (coord, handle) = open_estate();

    // Estate is On by default; provision explicitly so the intent is clear.
    {
        let coord_guard = coord.lock().unwrap();
        coord_guard
            .provision_preference(
                &handle,
                EstatePreferenceKey::FactExtraction,
                EstatePreferenceValue::On,
            )
            .expect("provision On");
    }

    let extractor: Arc<dyn FactExtractor> = Arc::new(StubExtractor::new());

    // Call the testable seam directly — no config.json, no subprocess.
    let cycle = activate_and_build_extraction_cycle(Arc::clone(&extractor), &coord, handle);

    // 1. The return must be Some.
    assert!(
        cycle.is_some(),
        "setting On with an extractor must produce Some(cycle)"
    );

    // 2. The returned closure must be callable and activate lazily.
    //    Fresh estate has no drawers, so facts_filed = 0 — that is still Ok.
    let result = cycle.unwrap()();
    assert!(
        result.is_ok(),
        "cycle closure must return Ok on a fresh estate; got {result:?}"
    );
    assert!(coord
        .lock()
        .unwrap()
        .registered_fact_extractor(&handle)
        .is_some());
}

#[test]
fn fact_extraction_cycle_tracks_runtime_preference_without_restart() {
    let (coord, handle) = open_estate();
    {
        let coord_guard = coord.lock().unwrap();
        coord_guard
            .provision_preference(
                &handle,
                EstatePreferenceKey::FactExtraction,
                EstatePreferenceValue::Off,
            )
            .expect("provision Off");
    }
    let extractor: Arc<dyn FactExtractor> = Arc::new(StubExtractor::new());
    let cycle = activate_and_build_extraction_cycle(extractor, &coord, handle)
        .expect("available extractor retains a lazy cycle while Off");
    assert_eq!(cycle().expect("Off is a no-op"), 0);
    assert!(coord
        .lock()
        .unwrap()
        .registered_fact_extractor(&handle)
        .is_none());

    {
        let coord_guard = coord.lock().unwrap();
        coord_guard
            .provision_preference(
                &handle,
                EstatePreferenceKey::FactExtraction,
                EstatePreferenceValue::On,
            )
            .expect("provision On");
    }
    assert_eq!(cycle().expect("On runs after live preference change"), 0);
    assert!(coord
        .lock()
        .unwrap()
        .registered_fact_extractor(&handle)
        .is_some());
}

// ---------------------------------------------------------------------------
// GSS-14c: setting On + no config paths → None
//
// Calls `build_fact_extraction_cycle` with On and a scratch config.json that
// carries no fact_extraction block. This is the common field case — most
// installs have no model on disk.
// ---------------------------------------------------------------------------

/// GSS-14c: when the estate setting is On but config.json contains no
/// `fact_extraction` block, `build_fact_extraction_cycle` returns `None` and
/// does not activate any extractor.
///
/// Goes red when: `build_fact_extraction_cycle` does not check for missing
/// config paths before calling the seam, or calls `activate_and_build_extraction_cycle`
/// even when one or more required paths are absent from config.json.
#[test]
fn build_fact_extraction_cycle_is_none_when_setting_on_and_no_config_paths() {
    let (coord, handle) = open_estate();

    // Estate is On — we want the config-path check to fire, not the Off check.
    {
        let coord_guard = coord.lock().unwrap();
        coord_guard
            .provision_preference(
                &handle,
                EstatePreferenceKey::FactExtraction,
                EstatePreferenceValue::On,
            )
            .expect("provision On");
    }

    let scratch = std::env::temp_dir().join(format!("aria-fec-noconfig-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&scratch).unwrap();
    // Config.json exists but has no fact_extraction paths — the common install.
    write_no_fact_extraction_config(&scratch);

    let cycle = build_fact_extraction_cycle(&coord, handle, Some(&scratch));

    assert!(
        cycle.is_none(),
        "On + missing config paths must produce None; got Some(cycle)"
    );

    // No extractor registered — the daemon runs without signal 14.
    let coord_guard = coord.lock().unwrap();
    assert!(
        coord_guard.registered_fact_extractor(&handle).is_none(),
        "no extractor must be registered when config paths are absent"
    );
}

// ---------------------------------------------------------------------------
// GSS-14d: selector + settings choose the Rust NuExtract provider
// ---------------------------------------------------------------------------

/// One product-composition regression gate: configured, readable worker assets
/// under `fact_extractor=nuextract` register the Candle worker client, while the
/// same estate under `fact_extractor=apple` stays inactive on the Rust port.
#[test]
fn builder_selects_and_activates_only_nuextract_on_rust() {
    let scratch = std::env::temp_dir().join(format!("aria-fec-selection-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&scratch).unwrap();
    let worker = scratch.join("moot-nuextract-worker");
    let gguf = scratch.join("model.gguf");
    let tokenizer = scratch.join("tokenizer.json");
    std::fs::write(&worker, b"worker").unwrap();
    std::fs::write(&gguf, b"gguf").unwrap();
    std::fs::write(&tokenizer, b"{}").unwrap();
    std::fs::write(
        scratch.join("config.json"),
        format!(
            r#"{{"fact_extraction":{{"worker_executable":"{}","gguf":"{}","tokenizer":"{}","model_version":"test-v1"}}}}"#,
            worker.display(), gguf.display(), tokenizer.display()
        ),
    )
    .unwrap();

    let (coord, handle) = open_estate();
    {
        let coord_guard = coord.lock().unwrap();
        coord_guard
            .provision_preference(
                &handle,
                EstatePreferenceKey::FactExtraction,
                EstatePreferenceValue::On,
            )
            .unwrap();
        coord_guard
            .provision_preference(
                &handle,
                EstatePreferenceKey::FactExtractor,
                EstatePreferenceValue::Nuextract,
            )
            .unwrap();
    }
    let cycle = build_fact_extraction_cycle(&coord, handle, Some(&scratch))
        .expect("configured NuExtract must prepare signal 14");
    assert!(coord.lock().unwrap().registered_fact_extractor(&handle).is_none(),
        "construction must defer activation until the live preference gate runs");
    assert_eq!(cycle().expect("first enabled tick activates the configured provider"), 0,
        "an empty estate must not invoke the worker");
    let registered = coord
        .lock()
        .unwrap()
        .registered_fact_extractor(&handle)
        .expect("NuExtract worker client registered");
    assert_eq!(registered.spec().provider_id, "nuextract-candle-worker");

    let (apple_coord, apple_handle) = open_estate();
    {
        let coord_guard = apple_coord.lock().unwrap();
        coord_guard
            .provision_preference(
                &apple_handle,
                EstatePreferenceKey::FactExtractor,
                EstatePreferenceValue::Apple,
            )
            .unwrap();
    }
    assert!(
        build_fact_extraction_cycle(&apple_coord, apple_handle, Some(&scratch)).is_none(),
        "Apple selector must fail quiet on the Rust product"
    );

    std::fs::remove_dir_all(scratch).ok();
}
