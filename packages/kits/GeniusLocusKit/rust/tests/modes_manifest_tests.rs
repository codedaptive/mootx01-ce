// modes_manifest_tests.rs
//
// Rust conformance tests for the user-owned "modes_config" manifest key
// and ModesManifest type. Mirrors Swift ModesManifestTests.
//
// Coverage:
//   (a) Spec defaults — Default::default() has sticky_enabled=true, coaching_calls=25.
//   (b) Codable round-trip — serialize + deserialize produces the same value.
//   (c) Snake_case wire keys are present in serialized JSON.
//   (d) Partial JSON — a JSON with only "sticky_enabled" fills coaching_calls with 25.
//   (e) Malformed JSON — fails to deserialize (caller uses .unwrap_or_default()).
//   (f) sticky_enabled=false decodes and differs from Default.
//   (g) coaching_calls=0 decodes correctly (0=off).
//   (h) Estate verb round-trip via provision_modes_config / provisioned_modes_config.
//   (i) Absent key returns spec-default config.
//   (j) Golden pin: sticky_enabled=false, coaching_calls=2 round-trips exactly.

use std::sync::Arc;

use genius_locus_kit::{coordinator::ModesManifest, EstateCoordinator};
use locus_kit::{
    drawer_store::DrawerStore,
    drawer_store_inmemory::InMemoryDrawerStore,
    estate_types::OwnerCredentials,
};

const NOW: i64 = 1_700_000_000;

fn open_one() -> (EstateCoordinator, genius_locus_kit::EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> = Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let handle = coord
        .open(store, OwnerCredentials::new("modes-manifest-test"), 0, i64::MAX)
        .expect("open must succeed");
    (coord, handle)
}

// MARK: (a) Spec defaults

#[test]
fn default_sticky_enabled_is_true() {
    assert!(ModesManifest::default().sticky_enabled);
}

#[test]
fn default_coaching_calls_is_25() {
    assert_eq!(ModesManifest::default().coaching_calls, 25);
}

#[test]
fn two_defaults_are_equal() {
    assert_eq!(ModesManifest::default(), ModesManifest::default());
}

// MARK: (b) Codable round-trip

#[test]
fn serialize_deserialize_roundtrip() {
    let original = ModesManifest { sticky_enabled: false, coaching_calls: 10 };
    let json = serde_json::to_string(&original).expect("serialize must succeed");
    let decoded: ModesManifest = serde_json::from_str(&json).expect("deserialize must succeed");
    assert_eq!(decoded, original);
}

// MARK: (c) Snake_case wire keys

#[test]
fn wire_keys_are_snake_case() {
    let m = ModesManifest { sticky_enabled: false, coaching_calls: 10 };
    let json = serde_json::to_string(&m).expect("serialize must succeed");
    assert!(json.contains("\"sticky_enabled\""), "expected 'sticky_enabled' key in {json}");
    assert!(json.contains("\"coaching_calls\""), "expected 'coaching_calls' key in {json}");
    assert!(json.contains("false"), "expected false value in {json}");
    assert!(json.contains("10"), "expected 10 value in {json}");
}

// MARK: (d) Partial JSON — absent coaching_calls fills with spec default

#[test]
fn partial_json_fills_coaching_calls_default() {
    // Only sticky_enabled present; coaching_calls should default to 25.
    let json = r#"{"sticky_enabled":false}"#;
    let decoded: ModesManifest = serde_json::from_str(json).expect("partial JSON must decode");
    assert!(!decoded.sticky_enabled);
    assert_eq!(decoded.coaching_calls, 25);
}

#[test]
fn empty_json_object_fills_spec_defaults() {
    let decoded: ModesManifest = serde_json::from_str("{}").expect("empty JSON must decode");
    assert_eq!(decoded, ModesManifest::default());
}

// MARK: (e) Malformed JSON — fails to deserialize

#[test]
fn malformed_json_fails_to_deserialize() {
    let result: Result<ModesManifest, _> = serde_json::from_str("not-json");
    assert!(result.is_err(), "malformed JSON must fail; caller uses .unwrap_or_default()");
}

// MARK: (f) sticky_enabled=false decodes and differs from Default

#[test]
fn sticky_enabled_false_decodes_and_differs_from_default() {
    // Failure mode: if sticky_enabled=false is silently coerced to true,
    // decoded == default and the assert fires.
    let json = r#"{"sticky_enabled":false,"coaching_calls":25}"#;
    let decoded: ModesManifest = serde_json::from_str(json).expect("must decode");
    assert!(!decoded.sticky_enabled, "sticky_enabled=false must decode as false");
    assert_ne!(decoded, ModesManifest::default(),
               "sticky_enabled=false must produce a config distinct from the default (true)");
}

// MARK: (g) coaching_calls=0 decodes correctly

#[test]
fn coaching_calls_zero_decodes() {
    // Failure mode: if coaching_calls=0 is ignored and falls back to 25,
    // should_coach() would fire at call 25 and tests expecting zero coaching fail.
    let json = r#"{"sticky_enabled":true,"coaching_calls":0}"#;
    let decoded: ModesManifest = serde_json::from_str(json).expect("must decode");
    assert_eq!(decoded.coaching_calls, 0, "coaching_calls=0 must decode as 0");
    assert_ne!(decoded, ModesManifest::default(),
               "coaching_calls=0 must produce a config distinct from the default (25)");
}

// MARK: (h) Estate verb round-trip

#[test]
fn provision_and_read_back() {
    let (coord, handle) = open_one();
    let written = ModesManifest { sticky_enabled: false, coaching_calls: 10 };
    coord.provision_modes_config(&handle, &written).expect("provision must succeed");
    let read = coord.provisioned_modes_config(&handle).expect("read-back must succeed");
    assert_eq!(read, written);
    assert!(!read.sticky_enabled);
    assert_eq!(read.coaching_calls, 10);
}

#[test]
fn provision_overwrite_reflects_on_next_read() {
    let (coord, handle) = open_one();
    let first = ModesManifest { sticky_enabled: false, coaching_calls: 0 };
    coord.provision_modes_config(&handle, &first).expect("first provision must succeed");
    let second = ModesManifest { sticky_enabled: true, coaching_calls: 50 };
    coord.provision_modes_config(&handle, &second).expect("second provision must succeed");
    let read = coord.provisioned_modes_config(&handle).expect("read-back must succeed");
    assert_eq!(read, second);
    assert_ne!(read, first);
}

// MARK: (i) Absent key returns spec-default

#[test]
fn absent_key_returns_default() {
    let (coord, handle) = open_one();
    let config = coord.provisioned_modes_config(&handle).expect("read must succeed");
    assert_eq!(config, ModesManifest::default());
    assert!(config.sticky_enabled);
    assert_eq!(config.coaching_calls, 25);
}

// MARK: (j) Golden pin

#[test]
fn golden_pin_sticky_false_coaching_2() {
    // Discriminating pin: both fields non-default. Fails if either field is
    // ignored, coerced, or silently replaced with the spec constant.
    let (coord, handle) = open_one();
    let pin = ModesManifest { sticky_enabled: false, coaching_calls: 2 };
    coord.provision_modes_config(&handle, &pin).expect("provision must succeed");
    let read = coord.provisioned_modes_config(&handle).expect("read-back must succeed");
    assert!(!read.sticky_enabled);
    assert_eq!(read.coaching_calls, 2);
    assert_eq!(read, pin);
    assert_ne!(read, ModesManifest::default());
}
