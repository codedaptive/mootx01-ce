// Swift bit-identity conformance for FloatSimHash.
//
// The expected Fingerprint256 values below are checked-in canonical
// constants derived from the Swift implementation. Any divergence in
// the Rust port produces different output and fails the test; the
// algorithm must be bit-identical to Swift's for cross-platform
// engram storage to round-trip correctly.

use substrate_types::fingerprint256::Fingerprint256;
use substrate_ml::float_simhash;

fn ramp384() -> Vec<f32> {
    (0..384).map(|i| (i as f32) / 384.0 - 0.5).collect()
}

fn rust_base() -> Vec<f32> {
    (0..384)
        .map(|i| ((((i * 17) + 3) % 200) as f32) / 100.0 - 1.0)
        .collect()
}

fn rust_v1() -> Vec<f32> {
    (0..384)
        .map(|i| ((((i * 13) + 7) % 200) as f32) / 100.0 - 1.0)
        .collect()
}

fn rust_v2() -> Vec<f32> {
    (0..384)
        .map(|i| ((((i * 29) + 11) % 200) as f32) / 100.0 - 1.0)
        .collect()
}

#[test]
fn ramp384_seed_dead_beef_matches_swift() {
    let fp = float_simhash::project(&ramp384(), 0xDEAD_BEEF);
    let expected = Fingerprint256::new(
        0xE618023A0AD89639,
        0xFB6A420A485FA888,
        0x5E9CAAB433E3E8C1,
        0x3B6AA105B8D70BCE,
    );
    assert_eq!(fp, expected, "FloatSimHash drift from Swift");
}

#[test]
fn rust_base_seed_cafe_matches_swift() {
    let fp = float_simhash::project(&rust_base(), 0xCAFE);
    let expected = Fingerprint256::new(
        0xCCC6CBB381E59970,
        0x8B27ED81D11789F5,
        0xD8B172D24A03B10D,
        0x821428D6B9BBE096,
    );
    assert_eq!(fp, expected);
}

#[test]
fn rust_v1_seed_abcd_matches_swift() {
    let fp = float_simhash::project(&rust_v1(), 0xABCD);
    let expected = Fingerprint256::new(
        0xA164012F14A11D0B,
        0xF0C1D142311B04A7,
        0x72AB0CAB07C788A0,
        0x2D2EEC444CD69A02,
    );
    assert_eq!(fp, expected);
}

#[test]
fn rust_v2_seed_abcd_matches_swift() {
    let fp = float_simhash::project(&rust_v2(), 0xABCD);
    let expected = Fingerprint256::new(
        0x4EA4A643533357B5,
        0x77943D3FD6BCAA94,
        0x7EC8FE8E46E29ECA,
        0x5D698EF1C4255172,
    );
    assert_eq!(fp, expected);
}

#[test]
fn empty_seed_42_matches_swift() {
    let fp = float_simhash::project(&[], 0x42);
    assert_eq!(fp, Fingerprint256::ZERO);
}
