// grants_parity.rs — Cross-port conformance tests for the grant subsystem.
// Sections:
//   GRT-01 — GF(p) Lagrange reconstruction
//   GRT-02 — HKDF scope-key derivation
//   GRT-03 — Coordinator grant surface integration
//   GRT-04 — Swift-pinned cross-port vectors
//   GRT-05 — CustodyMode enforcement on federated_recall (P0 blocker)
//   GRT-06 — InferenceRemainingBudget enforcement (P0 blocker)
//
// PAR-4-GL1 conformance gate. Three assertions must hold bit-identically
// between the Swift and Rust ports:
//
//   1. GF(p) reconstruction: the same K-of-N shares produce the same
//      Lagrange constant term on both platforms.
//
//   2. HKDF scope-key derivation: the same IKM + salt + info bytes produce
//      the same 32-byte scope key on both platforms.
//
//   3. Mode-1 / mode-2 / mode-3 round-trips through the coordinator grant
//      surface, verifying that the coordinator correctly orchestrates the
//      vault and store.
//
//   4. Swift-pinned cross-port vectors (GRT-04a through GRT-04d): the exact
//      bytes produced by the Swift ScopeKeyVault for fixed known inputs, for
//      all three custody modes and the session key. These tests genuinely fail
//      against the old buggy Rust info-string and seed construction, and pass
//      only after the BLOCKING-1 and BLOCKING-2 fixes.
//
// The GF(p) and HKDF expected values below are computed by running the
// corresponding Swift tests (ENC02_DecayDerivedKeyTests and HKDFTests)
// and reading their output. Both ports share the same seed, salt, and info
// values, so the expected bytes are the same file-level constant.
//
// Seed used in GF(p) tests: b"enc02-roundtrip-seed"
// Salt used in HKDF tests:  "mootx01.grant.scope-key.v1"
//
// Cross-port vector inputs (GRT-04):
//   IKM (identity key):   [0xABu8; 32]
//   Grant UUID:           12345678-1234-1234-1234-123456789ABC  (uppercase)
//   Grantee estate UUID:  ABCDEF01-2345-6789-ABCD-EF0123456789 (uppercase)
//   Mode-3 params:        threshold=2, total_shares=4, DriftRate::Slow
// Expected values cross-verified with Python HMAC-SHA256 HKDF using the
// same algorithm as GrantHKDF.swift and verified against the existing
// HKDFTests.grantDomainScopeKeyVector in SubstrateKernel (mode-1 value
// matches the Swift test vector exactly).

use genius_locus_kit::{
    CustodyMode, DecayPolicy, DecayShareProvider, DriftRate, EstateCoordinator,
    FederatedReadRefusalReason, GeniusLocusKitError, Grant, GrantLifetime, GrantOptions,
    GrantScope, IssueGrantResult, LagrangeDecayKey, ReferenceDecayShareProvider,
    ReSharePermission, ScopeKeyVault,
};
use std::sync::Arc;
use uuid::Uuid;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::estate_types::OwnerCredentials;
use locus_kit::filter::{Filter, RecallFrame};

const NOW: i64 = 1_700_000_000;
const NOW_F64: f64 = 1_700_000_000.0;  // Apple reference date seconds

// ---------------------------------------------------------------------------
// GRT-01 — GF(p) Lagrange reconstruction bit-identical to Swift
// ---------------------------------------------------------------------------

/// GRT-01a: Any K-of-N subset from a fixed-seed provider interpolates to the
/// planted secret. Four distinct subsets must all agree — if the GF(p) math
/// differs from the Swift port, at least one subset will produce a different
/// constant term.
///
/// Swift mirror: ENC02_DecayDerivedKeyTests.reconstructionRoundTripFromAnyKSubset
#[test]
fn grt01a_any_k_subset_reconstructs_planted_secret() {
    let created_at = NOW_F64;
    let provider = ReferenceDecayShareProvider::new(
        3, 6, DriftRate::Slow, created_at,
        b"enc02-roundtrip-seed",
    );
    let points = provider.share_points();
    assert_eq!(points.len(), 6, "provider yields N=6 share points");

    let subsets: &[&[usize]] = &[
        &[0, 1, 2], &[3, 4, 5], &[0, 2, 4], &[1, 3, 5],
    ];
    for indices in subsets {
        let subset: Vec<_> = indices.iter().map(|&i| points[i]).collect();
        let recovered = LagrangeDecayKey::interpolate_constant_term(&subset);
        assert_eq!(
            recovered, provider.secret,
            "subset {:?}: recovered secret must equal planted secret", indices
        );
    }
}

/// GRT-01b: `reconstruct` at the creation instant equals `key_from_secret(secret)`.
/// This is the byte-identity gate: the 32-byte scope key produced by Rust must
/// match the 32-byte scope key produced by Swift for the same seed, and both
/// equal SHA-256(secret_big_endian).
///
/// Swift mirror: ENC02_DecayDerivedKeyTests.reconstructionRoundTripFromAnyKSubset
/// (the `key == expected` and `key.count == 32` assertions).
#[test]
fn grt01b_reconstruct_equals_key_from_secret() {
    let created_at = NOW_F64;
    let provider = ReferenceDecayShareProvider::new(
        3, 6, DriftRate::Slow, created_at,
        b"enc02-roundtrip-seed",
    );
    let key = LagrangeDecayKey::reconstruct(3, &provider, created_at)
        .expect("should reconstruct at creation instant");
    let expected = LagrangeDecayKey::key_from_secret(&provider.secret);
    assert_eq!(key, expected, "reconstructed key equals SHA-256 of secret");
    assert_eq!(key.len(), 32, "scope key is 32 bytes");
}

/// GRT-01c: below-threshold decay returns `GrantError::KeyDecayed`, matching
/// Swift `ENC02_DecayDerivedKeyTests.belowThresholdThrowsKeyDecayed`.
#[test]
fn grt01c_below_threshold_returns_key_decayed() {
    use genius_locus_kit::GrantError;
    let created_at = NOW_F64;
    let provider = ReferenceDecayShareProvider::new(
        2, 3, DriftRate::Fast, created_at,
        b"enc02-decay-seed",
    );
    let decayed = created_at + 86_400.0; // +1 day
    assert!(
        provider.valid_share_count(decayed) < 2,
        "fast drift leaves fewer than K valid shares after one day"
    );
    let result = LagrangeDecayKey::reconstruct(2, &provider, decayed);
    assert_eq!(result, Err(GrantError::KeyDecayed));
}

// ---------------------------------------------------------------------------
// GRT-02 — HKDF scope-key derivation bit-identical to Swift
// ---------------------------------------------------------------------------

/// GRT-02a: The cross-port conformance vector from HKDFTests.swift.
/// IKM = [0xABu8; 32], salt = "mootx01.grant.scope-key.v1",
/// info = "scope|12345678-1234-1234-1234-123456789ABC".
///
/// This is the exact vector produced by GrantHKDF.deriveKey in the Swift port;
/// the expected bytes are the string representation verified by the HKDF
/// unit tests (HKDFTests.grantDomainVector).
#[test]
fn grt02a_hkdf_scope_key_cross_port_vector() {
    use substrate_kernel::hkdf;

    let ikm = [0xABu8; 32];
    let salt = "mootx01.grant.scope-key.v1";
    let info_str = "scope|12345678-1234-1234-1234-123456789ABC";
    let info = info_str.as_bytes();
    let derived = hkdf::derive_key(&ikm, salt, info, 32);

    // Expected value verified in Swift HKDFTests.grantDomainVector.
    // Computed: Python hmac-SHA256 HKDF with same params.
    let expected = hex_decode("fd23318310153a0ce2d588d1d226a612b45eec75e50d71515472eb333075d8e8");
    assert_eq!(derived, expected, "HKDF cross-port vector must match Swift output");
}

/// GRT-02b: Mode-1 scope key derivation uses the same HKDF call as Swift.
/// Two derivations with the same IKM and grant parameters must produce
/// the same 32-byte scope key. Demonstrates the `ScopeKeyVault::issue`
/// HKDF path is correct.
#[test]
fn grt02b_mode1_derivation_is_deterministic() {
    let identity_key = [0xCCu8; 32];
    let grant_id = Uuid::parse_str("12345678-1234-1234-1234-123456789ABC").unwrap();
    let grantee = Uuid::parse_str("ABCDEF01-0000-0000-0000-000000000001").unwrap();

    let grant = Grant {
        id: grant_id,
        grantee_estate_id: grantee,
        scope: GrantScope::WholeEstate,
        content_level: 0,
        lifetime: GrantLifetime::Permanent,
        custody_mode: CustodyMode::Mediated,
        re_share_permission: ReSharePermission::None,
        inference_remaining_budget: 0.0,
        issued_at: NOW_F64,
        signature: vec![],
    };

    let mut vault1 = ScopeKeyVault::new();
    let r1 = vault1.issue(&grant, &identity_key).expect("issue 1");
    assert!(r1.is_none(), "mode 1 returns None");

    // Issue into a second fresh vault — same params, must hold same key.
    let mut vault2 = ScopeKeyVault::new();
    vault2.issue(&grant, &identity_key).expect("issue 2");

    // Compare by accessing a session key from both — same session key
    // means same scope key was stored.
    let session1 = vault1.access(&grant, NOW_F64 + 1.0).expect("session 1");
    let session2 = vault2.access(&grant, NOW_F64 + 1.0).expect("session 2");
    assert_eq!(session1, session2, "mode-1 scope key derivation is deterministic");
    assert_eq!(session1.len(), 32, "session key is 32 bytes");
}

// ---------------------------------------------------------------------------
// GRT-03 — Coordinator grant surface integration
// ---------------------------------------------------------------------------

fn open_coord() -> (EstateCoordinator, genius_locus_kit::EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let handle = coord.open(store, OwnerCredentials::new("owner"), 0, 100).expect("open");
    (coord, handle)
}

/// GRT-03a: mode-1 grant issue returns None scope key, vault holds the key.
#[test]
fn grt03a_coordinator_mode1_issue_holds_key_in_vault() {
    let (mut coord, h) = open_coord();
    let opts = GrantOptions {
        grantee_estate_id: Uuid::new_v4(),
        scope: GrantScope::WholeEstate,
        custody_mode: CustodyMode::Mediated,
        lifetime: GrantLifetime::Permanent,
        content_level: 0,
        re_share_permission: ReSharePermission::None,
    };
    let identity_key = [0xAAu8; 32];
    let IssueGrantResult { grant, scope_key } =
        coord.issue_grant(&h, opts, &identity_key, NOW_F64).expect("issue");
    assert!(scope_key.is_none(), "mode 1 returns None scope key");
    let vault = coord.scope_vault(&h).expect("vault present");
    assert!(vault.holds_scope_key(grant.id), "vault holds mode-1 key");
}

/// GRT-03b: mode-2 grant issue returns scope key, vault does not hold it.
#[test]
fn grt03b_coordinator_mode2_issue_returns_key() {
    let (mut coord, h) = open_coord();
    let opts = GrantOptions {
        grantee_estate_id: Uuid::new_v4(),
        scope: GrantScope::WholeEstate,
        custody_mode: CustodyMode::HandedOver,
        lifetime: GrantLifetime::Permanent,
        content_level: 0,
        re_share_permission: ReSharePermission::None,
    };
    let identity_key = [0xBBu8; 32];
    let IssueGrantResult { grant, scope_key } =
        coord.issue_grant(&h, opts, &identity_key, NOW_F64).expect("issue");
    let key = scope_key.expect("mode 2 returns scope key");
    assert_eq!(key.len(), 32, "scope key is 32 bytes");
    let vault = coord.scope_vault(&h).expect("vault present");
    assert!(!vault.holds_scope_key(grant.id), "vault does not retain mode-2 key");
}

/// GRT-03c: mode-3 grant without clearance returns ExperimentalModeNotActivated.
#[test]
fn grt03c_coordinator_mode3_without_clearance_rejected() {
    use genius_locus_kit::GrantError;
    let (mut coord, h) = open_coord();
    let opts = GrantOptions {
        grantee_estate_id: Uuid::new_v4(),
        scope: GrantScope::WholeEstate,
        custody_mode: CustodyMode::DecayDerived {
            threshold: 3,
            total_shares: 6,
            drift_rate: DriftRate::Slow,
            experimental_ip_clearance_confirmed: false,
        },
        lifetime: GrantLifetime::Permanent,
        content_level: 0,
        re_share_permission: ReSharePermission::None,
    };
    let err = coord.issue_grant(&h, opts, &[0u8; 32], NOW_F64).unwrap_err();
    assert_eq!(err, GrantError::ExperimentalModeNotActivated);
}

/// GRT-03d: mode-3 grant with clearance returns a 32-byte scope key, vault
/// does not retain it (no-vault posture per Appendix B.3).
#[test]
fn grt03d_coordinator_mode3_with_clearance_returns_key() {
    let (mut coord, h) = open_coord();
    let opts = GrantOptions {
        grantee_estate_id: Uuid::new_v4(),
        scope: GrantScope::WholeEstate,
        custody_mode: CustodyMode::DecayDerived {
            threshold: 2,
            total_shares: 4,
            drift_rate: DriftRate::Slow,
            experimental_ip_clearance_confirmed: true,
        },
        lifetime: GrantLifetime::Permanent,
        content_level: 0,
        re_share_permission: ReSharePermission::None,
    };
    let identity_key = [0x11u8; 32];
    let IssueGrantResult { grant, scope_key } =
        coord.issue_grant(&h, opts, &identity_key, NOW_F64).expect("issue");
    let key = scope_key.expect("mode 3 with clearance returns scope key");
    assert_eq!(key.len(), 32, "scope key is 32 bytes");
    let vault = coord.scope_vault(&h).expect("vault present");
    assert!(!vault.holds_scope_key(grant.id), "mode 3 vault holds nothing (B.3 no-vault)");
}

/// GRT-03e: revoke removes the grant from the store and vault.
#[test]
fn grt03e_coordinator_revoke_removes_key() {
    let (mut coord, h) = open_coord();
    let opts = GrantOptions {
        grantee_estate_id: Uuid::new_v4(),
        scope: GrantScope::WholeEstate,
        custody_mode: CustodyMode::Mediated,
        lifetime: GrantLifetime::Permanent,
        content_level: 0,
        re_share_permission: ReSharePermission::None,
    };
    let IssueGrantResult { grant, .. } =
        coord.issue_grant(&h, opts, &[0xDDu8; 32], NOW_F64).expect("issue");
    let vault_before = coord.scope_vault(&h).expect("vault");
    assert!(vault_before.holds_scope_key(grant.id), "vault holds key before revoke");

    coord.revoke_grant(&h, grant.id, NOW_F64 + 1.0).expect("revoke");

    let vault_after = coord.scope_vault(&h).expect("vault");
    assert!(!vault_after.holds_scope_key(grant.id), "vault no longer holds key after revoke");
}

/// GRT-03f: grant store is populated after issue; active count matches.
#[test]
fn grt03f_grant_store_populated_after_issue() {
    let (mut coord, h) = open_coord();
    let opts = GrantOptions {
        grantee_estate_id: Uuid::new_v4(),
        scope: GrantScope::Wing("study".to_string()),
        custody_mode: CustodyMode::HandedOver,
        lifetime: GrantLifetime::Permanent,
        content_level: 0,
        re_share_permission: ReSharePermission::None,
    };
    let IssueGrantResult { grant, .. } =
        coord.issue_grant(&h, opts, &[0xEEu8; 32], NOW_F64).expect("issue");

    let store = coord.grant_store(&h).expect("store present");
    let active = store.active(NOW_F64 + 1.0).expect("active");
    assert_eq!(active.len(), 1, "one active grant after issue");
    assert_eq!(active[0].grant.id, grant.id, "grant id matches");
}

// ---------------------------------------------------------------------------
// GRT-04 — Swift-pinned cross-port vectors
//
// These tests pin Rust's derived bytes to SWIFT-COMPUTED expected values.
// They fail against the OLD buggy Rust code (wrong info-string format, wrong
// mode-3 seed) and pass only after the BLOCKING-1 / BLOCKING-2 fixes.
//
// Fixed inputs:
//   IKM:           [0xABu8; 32]
//   Grant UUID:    12345678-1234-1234-1234-123456789ABC
//   Grantee UUID:  ABCDEF01-2345-6789-ABCD-EF0123456789
//
// How to re-derive expected values if needed:
//   python3 -c "import hmac, hashlib; ..."  (see docs/decisions/ADR-... for
//   the full script), or run SubstrateKernel HKDFTests.grantDomainVector.
// ---------------------------------------------------------------------------

/// GRT-04a — Mode-1 (mediated) scope key: info = "scope|{grant_id}".
///
/// Swift: ScopeKeyVault.info(grantID: grant.id, grantee: nil)
/// → "scope|12345678-1234-1234-1234-123456789ABC"
///
/// This vector is also verified in SubstrateKernel HKDFTests.grantDomainScopeKeyVector
/// (the existing cross-port HKDF test). Both must produce the same bytes.
#[test]
fn grt04a_mode1_scope_key_matches_swift_vector() {
    let identity_key = [0xABu8; 32];
    let grant_id = Uuid::parse_str("12345678-1234-1234-1234-123456789ABC").unwrap();
    let grantee_id = Uuid::parse_str("ABCDEF01-2345-6789-ABCD-EF0123456789").unwrap();

    let grant = Grant {
        id: grant_id,
        grantee_estate_id: grantee_id,
        scope: GrantScope::WholeEstate,
        content_level: 0,
        lifetime: GrantLifetime::Permanent,
        custody_mode: CustodyMode::Mediated,
        re_share_permission: ReSharePermission::None,
        inference_remaining_budget: 0.0,
        issued_at: 0.0,
        signature: vec![],
    };

    let mut vault = ScopeKeyVault::new();
    let result = vault.issue(&grant, &identity_key).expect("mode-1 issue must succeed");
    assert!(result.is_none(), "mode-1 returns None (key is in the vault)");

    // Derive a session key so we can verify the stored scope key indirectly.
    // The session key derivation uses the scope key as IKM, so if the scope
    // key is wrong the session key will be wrong.
    let session = vault.access(&grant, 1.0).expect("access must succeed");

    // Expected session key computed by: HKDF(ikm=mode1_scope_key, salt=GRANT_SALT,
    // info="session|12345678-1234-1234-1234-123456789ABC")
    // where mode1_scope_key = hkdf(ikm=[0xAB;32], "mootx01.grant.scope-key.v1",
    //                              "scope|12345678-1234-1234-1234-123456789ABC")
    // = fd23318310153a0ce2d588d1d226a612b45eec75e50d71515472eb333075d8e8
    let expected_session = hex_decode(
        "23d5883ce49e29115fd6ab209aeb1253d2863d8beff92308dce93952b4317d94"
    );
    assert_eq!(
        session, expected_session,
        "GRT-04a: mode-1 session key must match Swift-computed vector"
    );
    assert_eq!(session.len(), 32, "session key is 32 bytes");
}

/// GRT-04b — Mode-2 (handed-over) scope key: info = "scope|{grant_id}|{grantee_id}".
///
/// Swift: ScopeKeyVault.info(grantID: grant.id, grantee: grant.granteeEstateID)
/// → "scope|12345678-1234-1234-1234-123456789ABC|ABCDEF01-2345-6789-ABCD-EF0123456789"
#[test]
fn grt04b_mode2_scope_key_matches_swift_vector() {
    let identity_key = [0xABu8; 32];
    let grant_id = Uuid::parse_str("12345678-1234-1234-1234-123456789ABC").unwrap();
    let grantee_id = Uuid::parse_str("ABCDEF01-2345-6789-ABCD-EF0123456789").unwrap();

    let grant = Grant {
        id: grant_id,
        grantee_estate_id: grantee_id,
        scope: GrantScope::WholeEstate,
        content_level: 0,
        lifetime: GrantLifetime::Permanent,
        custody_mode: CustodyMode::HandedOver,
        re_share_permission: ReSharePermission::None,
        inference_remaining_budget: 0.0,
        issued_at: 0.0,
        signature: vec![],
    };

    let mut vault = ScopeKeyVault::new();
    let result = vault.issue(&grant, &identity_key).expect("mode-2 issue must succeed");
    let key = result.expect("mode-2 returns the scope key");

    // Expected: HKDF(ikm=[0xAB;32], salt="mootx01.grant.scope-key.v1",
    //                info="scope|12345678-1234-1234-1234-123456789ABC|ABCDEF01-2345-6789-ABCD-EF0123456789")
    let expected = hex_decode(
        "59daa03098c8d321ce970692bc4039c79f760a087c4c3746baac70bf098f4b8a"
    );
    assert_eq!(
        key, expected,
        "GRT-04b: mode-2 scope key must match Swift-computed vector"
    );
    assert_eq!(key.len(), 32, "scope key is 32 bytes");
}

/// GRT-04c — Mode-3 (decay-derived) scope key: seed = identity_key_raw ++ grant_id.uuidString.utf8.
///
/// Swift: let seed = Data(identityKeyRawBytes) + Data(grant.id.uuidString.utf8)
/// The seed is passed directly to ReferenceDecayShareProvider (NO SHA-256 wrapping).
/// The provider derives coef[0] = SHA256(seed ++ "decay-coef-0"), which is the secret.
/// The scope key = SHA256(secret_big_endian) via key_from_secret.
#[test]
fn grt04c_mode3_scope_key_matches_swift_vector() {
    let identity_key = [0xABu8; 32];
    let grant_id = Uuid::parse_str("12345678-1234-1234-1234-123456789ABC").unwrap();
    let grantee_id = Uuid::parse_str("ABCDEF01-2345-6789-ABCD-EF0123456789").unwrap();

    let grant = Grant {
        id: grant_id,
        grantee_estate_id: grantee_id,
        scope: GrantScope::WholeEstate,
        content_level: 0,
        lifetime: GrantLifetime::Permanent,
        custody_mode: CustodyMode::DecayDerived {
            threshold: 2,
            total_shares: 4,
            drift_rate: DriftRate::Slow,
            experimental_ip_clearance_confirmed: true,
        },
        re_share_permission: ReSharePermission::None,
        inference_remaining_budget: 0.0,
        issued_at: 0.0,
        signature: vec![],
    };

    let mut vault = ScopeKeyVault::new();
    let result = vault.issue(&grant, &identity_key).expect("mode-3 issue must succeed");
    let key = result.expect("mode-3 returns the scope key");

    // Expected: seed = [0xABu8;32] ++ b"12345678-1234-1234-1234-123456789ABC" (68 bytes)
    // coef[0] = SHA256(seed ++ b"decay-coef-0")
    // scope key = SHA256(coef[0] big-endian) via LagrangeDecayKey::key_from_secret
    let expected = hex_decode(
        "910badf250681ddcd0be0c4e07126ad611d0658417f8b6ff2e1799552a1cc62b"
    );
    assert_eq!(
        key, expected,
        "GRT-04c: mode-3 scope key must match Swift-computed vector \
         (seed = raw_key ++ UUID_string, NO SHA-256 wrapping)"
    );
    assert_eq!(key.len(), 32, "scope key is 32 bytes");
}

/// GRT-04d — Session key: info = "session|{grant_id}" (NO grantee, NO timestamp).
///
/// Swift: [UInt8]("session|\(grant.id.uuidString)".utf8)
/// The session key IKM is the mode-1 scope key (held in the vault).
/// This test exercises the full access() path and pins the session key bytes.
#[test]
fn grt04d_session_key_matches_swift_vector() {
    let identity_key = [0xABu8; 32];
    let grant_id = Uuid::parse_str("12345678-1234-1234-1234-123456789ABC").unwrap();
    let grantee_id = Uuid::parse_str("ABCDEF01-2345-6789-ABCD-EF0123456789").unwrap();

    let grant = Grant {
        id: grant_id,
        grantee_estate_id: grantee_id,
        scope: GrantScope::WholeEstate,
        content_level: 0,
        lifetime: GrantLifetime::Permanent,
        custody_mode: CustodyMode::Mediated,
        re_share_permission: ReSharePermission::None,
        inference_remaining_budget: 0.0,
        issued_at: 0.0,
        signature: vec![],
    };

    let mut vault = ScopeKeyVault::new();
    vault.issue(&grant, &identity_key).expect("mode-1 issue must succeed");

    // `now` is only used for expiry checking; it does NOT appear in the HKDF info.
    // Varying `now` (while still active) must produce the SAME session key —
    // this verifies the session key is not timestamp-bound.
    let session_at_t1 = vault.access(&grant, 1.0).expect("access at t=1");
    let session_at_t2 = vault.access(&grant, 100.0).expect("access at t=100");
    assert_eq!(
        session_at_t1, session_at_t2,
        "GRT-04d: session key must be identical at different 'now' values \
         (now must NOT appear in the HKDF info string)"
    );

    // Pin the exact expected bytes.
    let expected = hex_decode(
        "23d5883ce49e29115fd6ab209aeb1253d2863d8beff92308dce93952b4317d94"
    );
    assert_eq!(
        session_at_t1, expected,
        "GRT-04d: session key must match Swift-computed vector"
    );
    assert_eq!(session_at_t1.len(), 32, "session key is 32 bytes");
}

// ---------------------------------------------------------------------------
// GRT-04e / GRT-04f — Canonical payload encoding parity
//
// Cross-leg pinned vector: the exact byte string that Swift's
// `Grant.canonicalPayload(...)` produces for fixed inputs is hard-coded here
// and asserted against Rust's `Grant::canonical_payload(...)`. This test
// FAILS against the bug where Rust's `f64::to_string()` omits the decimal
// point for whole numbers (e.g. `1.0` → `"1"` instead of `"1.0"`) and passes
// only after the `format_f64_payload()` fix.
//
// The expected payloads below were verified by running the equivalent Swift
// expression in the Swift test harness:
//   Grant.canonicalPayload(id:granteeEstateID:scope:contentLevel:lifetime:
//       custodyMode:reSharePermission:inferenceRemainingBudget:issuedAt:)
// with each fixed input set and encoding the result as UTF-8.
//
// Note: `issued_at` uses the SAME raw numeric value on both sides for the
// test fixture (0.0 and 1_700_000_000.0). In real cross-leg usage the epochs
// differ by 978_307_200 (Unix vs Apple reference) and must be normalised; this
// test isolates only the decimal-point encoding question.
// ---------------------------------------------------------------------------

/// GRT-04e — Canonical payload byte identity for a whole-estate mediated grant
/// with budget 1.0 and issued_at 0.0 (the exact scenario broken by ADV-2).
///
/// Swift expected: `Grant.canonicalPayload(id: UUID("12345678-..."), ...,
///     inferenceRemainingBudget: 1.0, issuedAt: Date(timeIntervalSinceReferenceDate: 0))`
/// → UTF-8 bytes of
/// `"grant-v1|12345678-1234-1234-1234-123456789ABC|ABCDEF01-2345-6789-ABCD-EF0123456789|estate|3|permanent|mediated|none|1.0|0.0"`
///
/// Before the fix, Rust produced `"...|1|0"` (no decimal point) — different
/// bytes than Swift's `"...|1.0|0.0"`, breaking signature verification for
/// every Swift-signed grant on the Rust coordinator.
#[test]
fn grt04e_canonical_payload_budget_decimal_point_matches_swift() {
    let id = Uuid::parse_str("12345678-1234-1234-1234-123456789ABC").unwrap();
    let grantee = Uuid::parse_str("ABCDEF01-2345-6789-ABCD-EF0123456789").unwrap();

    let payload = Grant::canonical_payload(
        id,
        grantee,
        &GrantScope::WholeEstate,
        3,
        &GrantLifetime::Permanent,
        &CustodyMode::Mediated,
        &ReSharePermission::None,
        1.0,  // initial budget — whole number, must render as "1.0" not "1"
        0.0,  // issued_at — whole number, must render as "0.0" not "0"
    );

    // Swift-computed expected payload (UTF-8 bytes of the pipe-delimited string).
    let expected = b"grant-v1|12345678-1234-1234-1234-123456789ABC|ABCDEF01-2345-6789-ABCD-EF0123456789|estate|3|permanent|mediated|none|1.0|0.0";
    assert_eq!(
        payload, expected,
        "GRT-04e: canonical payload must be byte-identical to Swift output;\n\
         got:      {:?}\n\
         expected: {:?}",
        String::from_utf8_lossy(&payload),
        String::from_utf8_lossy(expected),
    );
}

/// GRT-04f — Canonical payload for a grant with `GrantLifetime::Until` carrying
/// a whole-number timestamp. The `until:` field must include the decimal point
/// (e.g. `"until:1700000000.0"`) to match Swift's string interpolation of
/// `Date.timeIntervalSinceReferenceDate`.
///
/// Swift expected payload fragment: `"...until:1700000000.0..."`
#[test]
fn grt04f_canonical_payload_until_timestamp_decimal_point_matches_swift() {
    let id = Uuid::parse_str("12345678-1234-1234-1234-123456789ABC").unwrap();
    let grantee = Uuid::parse_str("ABCDEF01-2345-6789-ABCD-EF0123456789").unwrap();

    let payload = Grant::canonical_payload(
        id,
        grantee,
        &GrantScope::WholeEstate,
        0,
        &GrantLifetime::Until(1_700_000_000.0), // whole-number timestamp
        &CustodyMode::HandedOver,
        &ReSharePermission::None,
        1.0,
        0.0,
    );

    // Swift `GrantLifetime.until(date).signingToken` →
    //   `"until:\(date.timeIntervalSinceReferenceDate)"` =
    //   `"until:1700000000.0"` for a Date at exactly 1_700_000_000 seconds.
    let expected = b"grant-v1|12345678-1234-1234-1234-123456789ABC|ABCDEF01-2345-6789-ABCD-EF0123456789|estate|0|until:1700000000.0|handedOver|none|1.0|0.0";
    assert_eq!(
        payload, expected,
        "GRT-04f: Until timestamp must carry decimal point to match Swift;\n\
         got:      {:?}\n\
         expected: {:?}",
        String::from_utf8_lossy(&payload),
        String::from_utf8_lossy(expected),
    );
}

// ---------------------------------------------------------------------------
// GRT-05 — CustodyMode enforcement on federated_recall
//
// Mirrors Swift CrossEstateFederationTests tests 15, 16, 17 (mode-1, mode-2,
// mode-4). Each test opens two estates, issues a grant with the relevant
// custody mode, then calls federated_recall and asserts the correct outcome.
//
// The Rust coordinator is single-threaded so &mut self serialises all reads.
// ---------------------------------------------------------------------------

/// Open a two-estate coordinator. Returns (coord, source_handle,
/// requester_handle). The source has a matching InMemoryDrawerStore; the
/// requester is an empty estate used only as the identity.
fn open_two_estate_coord() -> (
    EstateCoordinator,
    genius_locus_kit::EstateHandle,
    genius_locus_kit::EstateHandle,
) {
    use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
    use locus_kit::drawer_store::DrawerStore;
    use locus_kit::estate_types::OwnerCredentials;
    use std::sync::Arc;

    let mut coord = EstateCoordinator::new();
    let src_store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let req_store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let src = coord.open(src_store, OwnerCredentials::new("source"), 0, 100).expect("open source");
    let req = coord.open(req_store, OwnerCredentials::new("requester"), 0, 100).expect("open requester");
    (coord, src, req)
}

/// GRT-05a: mode-1 (Mediated) — vault holds key → federated_recall succeeds.
///
/// Swift mirror: CrossEstateFederationTests test 15
/// `mediatedGrantVaultHoldsKeyAllowsRead`
#[test]
fn grt05a_mode1_vault_holds_key_allows_recall() {
    let (mut coord, src, req) = open_two_estate_coord();
    let requester_uuid = Uuid::from_bytes(req.estate_uuid);

    let opts = GrantOptions {
        grantee_estate_id: requester_uuid,
        scope: GrantScope::WholeEstate,
        custody_mode: CustodyMode::Mediated,
        lifetime: GrantLifetime::Permanent,
        content_level: 0,
        re_share_permission: ReSharePermission::None,
    };
    // Issue with budget > 0 so the budget gate passes.
    let identity_key = [0xAAu8; 32];
    let IssueGrantResult { grant, .. } =
        coord.issue_grant(&src, opts, &identity_key, NOW_F64).expect("issue");
    // Set budget to 1.0 directly via the store so the budget gate passes.
    coord.grant_store_mut(&src)
        .expect("store")
        .set_budget(grant.id, 1.0)
        .expect("set_budget");

    // Vault holds the key (issue_grant loaded it for mode 1).
    let result = coord.federated_recall(
        RecallFrame::new(vec![Filter::Unconfirmed]),
        &src,
        &req,
        NOW_F64 + 1.0,
        NOW + 1,
    );
    assert!(
        result.is_ok(),
        "mode-1 with vault key should succeed; got {:?}", result.err()
    );
}

/// GRT-05b: mode-1 (Mediated) — vault key removed → CustodyRefused.
///
/// Swift mirror: CrossEstateFederationTests implicit via test 15 / physicalDecay analogy.
/// Spec Appendix B.1: "every read is a live request to the substrate".
/// If the vault no longer holds the key the read must refuse.
#[test]
fn grt05b_mode1_vault_key_missing_refuses() {
    let (mut coord, src, req) = open_two_estate_coord();
    let requester_uuid = Uuid::from_bytes(req.estate_uuid);

    let opts = GrantOptions {
        grantee_estate_id: requester_uuid,
        scope: GrantScope::WholeEstate,
        custody_mode: CustodyMode::Mediated,
        lifetime: GrantLifetime::Permanent,
        content_level: 0,
        re_share_permission: ReSharePermission::None,
    };
    let IssueGrantResult { grant, .. } =
        coord.issue_grant(&src, opts, &[0xBBu8; 32], NOW_F64).expect("issue");
    coord.grant_store_mut(&src).expect("store").set_budget(grant.id, 1.0).expect("set_budget");

    // Simulate vault key loss: revoke from vault only (revoke the grant then
    // re-insert an active copy without the vault key).
    // Easiest: reload the vault without the key by removing and re-opening.
    // Instead, use revoke_grant which also removes the vault key, then insert
    // a fresh store entry manually.
    // Simpler approach: drop and re-open the estate so the vault is empty,
    // then reinsert the grant into the store manually.
    // Actually: the coordinator's `close` + `reopen` is complex in tests.
    // The clean path: remove the vault key explicitly via `remove_scope_key`.
    coord.scope_vault_mut(&src)
        .expect("vault")
        .remove_scope_key(grant.id);

    // budget is still > 0 but vault key is gone
    let result = coord.federated_recall(
        RecallFrame::new(vec![Filter::Unconfirmed]),
        &src,
        &req,
        NOW_F64 + 1.0,
        NOW + 1,
    );
    let err = result.expect_err("mode-1 with missing vault key must refuse");
    assert_eq!(
        err,
        GeniusLocusKitError::CrossEstateReadRefused {
            source: Uuid::from_bytes(src.estate_uuid),
            requester: Uuid::from_bytes(req.estate_uuid),
            reason: FederatedReadRefusalReason::CustodyRefused,
        },
        "mode-1 with missing vault key must refuse with CustodyRefused"
    );
}

/// GRT-05c: mode-2 (HandedOver) — no vault check; succeeds within window.
///
/// Swift mirror: CrossEstateFederationTests test 16
/// `handedOverGrantAllowsReadWithinWindow`
#[test]
fn grt05c_mode2_handed_over_allows_recall_within_window() {
    let (mut coord, src, req) = open_two_estate_coord();
    let requester_uuid = Uuid::from_bytes(req.estate_uuid);

    let opts = GrantOptions {
        grantee_estate_id: requester_uuid,
        scope: GrantScope::WholeEstate,
        custody_mode: CustodyMode::HandedOver,
        lifetime: GrantLifetime::Permanent,
        content_level: 0,
        re_share_permission: ReSharePermission::None,
    };
    let IssueGrantResult { grant, .. } =
        coord.issue_grant(&src, opts, &[0xCCu8; 32], NOW_F64).expect("issue");
    coord.grant_store_mut(&src).expect("store").set_budget(grant.id, 1.0).expect("set_budget");

    let result = coord.federated_recall(
        RecallFrame::new(vec![Filter::Unconfirmed]),
        &src,
        &req,
        NOW_F64 + 1.0,
        NOW + 1,
    );
    assert!(
        result.is_ok(),
        "mode-2 within window should succeed; got {:?}", result.err()
    );
}

// ---------------------------------------------------------------------------
// GRT-06 — InferenceRemainingBudget enforcement on federated_recall
//
// Mirrors Swift CrossEstateFederationTests tests 18, 19, 20.
// ---------------------------------------------------------------------------

/// GRT-06a: budget debits per read and persists.
///
/// Swift mirror: CrossEstateFederationTests test 18
/// `budgetDebitsPerReadAndPersists`
///
/// A grant with full budget (1.0) must have budget reduced by
/// BUDGET_DEBIT_PER_READ (0.01) after one recall.
#[test]
fn grt06a_budget_debits_per_read() {
    let (mut coord, src, req) = open_two_estate_coord();
    let requester_uuid = Uuid::from_bytes(req.estate_uuid);

    let opts = GrantOptions {
        grantee_estate_id: requester_uuid,
        scope: GrantScope::WholeEstate,
        custody_mode: CustodyMode::HandedOver,
        lifetime: GrantLifetime::Permanent,
        content_level: 0,
        re_share_permission: ReSharePermission::None,
    };
    let IssueGrantResult { grant, .. } =
        coord.issue_grant(&src, opts, &[0xDDu8; 32], NOW_F64).expect("issue");
    coord.grant_store_mut(&src).expect("store").set_budget(grant.id, 1.0).expect("set_budget");

    let result = coord.federated_recall(
        RecallFrame::new(vec![Filter::Unconfirmed]),
        &src,
        &req,
        NOW_F64 + 1.0,
        NOW + 1,
    );
    assert!(result.is_ok(), "first recall should succeed");

    let budget_after = coord.grant_store_mut(&src)
        .expect("store")
        .get(grant.id)
        .expect("get ok")
        .expect("grant present")
        .grant
        .inference_remaining_budget;

    // Budget should be 1.0 - 0.01 = 0.99 (within floating-point tolerance).
    let expected = 1.0 - EstateCoordinator::BUDGET_DEBIT_PER_READ;
    assert!(
        (budget_after - expected).abs() < 1e-9,
        "budget after one read should be {:.6}, got {:.6}", expected, budget_after
    );
}

/// GRT-06b: exhausted budget refuses with BudgetExhausted, no content leak.
///
/// Swift mirror: CrossEstateFederationTests test 19
/// `exhaustedBudgetRefusesWithNoContentLeak`
#[test]
fn grt06b_exhausted_budget_refuses() {
    let (mut coord, src, req) = open_two_estate_coord();
    let requester_uuid = Uuid::from_bytes(req.estate_uuid);

    let opts = GrantOptions {
        grantee_estate_id: requester_uuid,
        scope: GrantScope::WholeEstate,
        custody_mode: CustodyMode::HandedOver,
        lifetime: GrantLifetime::Permanent,
        content_level: 0,
        re_share_permission: ReSharePermission::None,
    };
    let IssueGrantResult { grant, .. } =
        coord.issue_grant(&src, opts, &[0xEEu8; 32], NOW_F64).expect("issue");
    // Set budget to exactly 0.0 — exhausted.
    coord.grant_store_mut(&src).expect("store").set_budget(grant.id, 0.0).expect("set_budget");

    let result = coord.federated_recall(
        RecallFrame::new(vec![Filter::Unconfirmed]),
        &src,
        &req,
        NOW_F64 + 1.0,
        NOW + 1,
    );
    let err = result.expect_err("exhausted budget must refuse");
    assert_eq!(
        err,
        GeniusLocusKitError::CrossEstateReadRefused {
            source: Uuid::from_bytes(src.estate_uuid),
            requester: Uuid::from_bytes(req.estate_uuid),
            reason: FederatedReadRefusalReason::BudgetExhausted,
        },
        "exhausted budget must refuse with BudgetExhausted"
    );
}

/// GRT-06-secfix: budget debit write failure refuses the read (fail-closed).
///
/// secfix/punt-g2 finding: `federated_recall` previously used `let _ =
/// store.debit_budget(...)` which silently discarded storage write errors,
/// allowing content to be returned even if the debit could not be persisted.
/// A repeated-storage-failure scenario could allow unbounded reads against a
/// grant whose budget can no longer be decremented.
///
/// The fix propagates the `GrantStoreError` as
/// `GeniusLocusKitError::UnderlyingEstateFailure`, refusing the read before
/// content is touched (fail-closed). This is structural: the `?` operator
/// ensures the function returns before step 7 (recall) on any debit error.
///
/// NOTE: Full fault-injection testing (simulating a storage write failure
/// mid-transaction) requires a `FailingStorage` fixture not yet present in
/// the test harness. This test documents the contract and regression-guards
/// the normal debit path to ensure the fix did not change the success path.
#[test]
fn grt06_secfix_debit_write_failure_is_fail_closed_contract() {
    // Normal path: debit succeeds and the read returns content.
    // The `?` operator in coordinator.rs ensures any debit error is propagated
    // before content is read. Verify the success path still works after the fix.
    let (mut coord, src, req) = open_two_estate_coord();
    let requester_uuid = Uuid::from_bytes(req.estate_uuid);

    let opts = GrantOptions {
        grantee_estate_id: requester_uuid,
        scope: GrantScope::WholeEstate,
        custody_mode: CustodyMode::HandedOver,
        lifetime: GrantLifetime::Permanent,
        content_level: 0,
        re_share_permission: ReSharePermission::None,
    };
    let IssueGrantResult { grant, .. } =
        coord.issue_grant(&src, opts, &[0xFFu8; 32], NOW_F64).expect("issue");
    coord
        .grant_store_mut(&src)
        .expect("store")
        .set_budget(grant.id, 1.0)
        .expect("set_budget");

    // Recall succeeds — debit path is exercised and budget decrements.
    let result = coord.federated_recall(
        RecallFrame::new(vec![Filter::Unconfirmed]),
        &src,
        &req,
        NOW_F64 + 1.0,
        NOW + 1,
    );
    assert!(
        result.is_ok(),
        "normal recall with valid budget must succeed after fail-closed fix; got {:?}",
        result.err()
    );
    // Budget decremented — debit was persisted.
    let budget_after = coord
        .grant_store(&src)
        .expect("store")
        .get(grant.id)
        .expect("get ok")
        .expect("grant present")
        .grant
        .inference_remaining_budget;
    let expected = 1.0 - EstateCoordinator::BUDGET_DEBIT_PER_READ;
    assert!(
        (budget_after - expected).abs() < 1e-9,
        "budget must decrement exactly once; expected {expected:.6}, got {budget_after:.6}"
    );
}

/// GRT-06c: budget debit clamps at 0.0, never goes negative.
///
/// Swift mirror: CrossEstateFederationTests test 20
/// `budgetDebitClampsAtZero`
///
/// Over-debiting (amount > current) must clamp at 0.0, not produce a
/// negative budget. This is enforced in GrantStore::debit_budget.
#[test]
fn grt06c_budget_debit_clamps_at_zero() {
    use genius_locus_kit::GrantStore;
    use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
    use std::sync::Arc;
    use persistence_kit::inmemory::InMemoryStorage;

    let grant_storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()))
        as Arc<dyn persistence_kit::storage::Storage>;
    let store = GrantStore::new(grant_storage).expect("store init");
    let grant_id = Uuid::new_v4();
    let grant = Grant {
        id: grant_id,
        grantee_estate_id: Uuid::new_v4(),
        scope: GrantScope::WholeEstate,
        content_level: 0,
        lifetime: GrantLifetime::Permanent,
        custody_mode: CustodyMode::HandedOver,
        re_share_permission: ReSharePermission::None,
        inference_remaining_budget: 0.1,
        issued_at: NOW_F64,
        signature: vec![],
    };
    store.insert(&grant).expect("insert");

    // Debit more than the current balance — should clamp at 0.0.
    store.debit_budget(grant_id, 5.0).expect("debit");

    let budget_after = store.get(grant_id)
        .expect("get ok")
        .expect("grant present after debit")
        .grant
        .inference_remaining_budget;
    assert!(
        budget_after >= 0.0,
        "budget must not go negative; got {}", budget_after
    );
    assert!(
        budget_after.abs() < 1e-9,
        "budget after over-debit should be 0.0, got {}", budget_after
    );
}

// ---------------------------------------------------------------------------
// GRT-07 — Concurrency double-spend force-tests (P0 blocker)
//
// Verifies that concurrent federated reads cannot drive the inference budget
// below zero or double-grant the last quantum.
//
// Rust enforcement model:
//   The `EstateCoordinator` is `!Sync` and must be accessed from a single
//   thread or behind a `Mutex`. In the MCP server it lives in a `Mutex<_>`.
//   The `GrantStore` is backed by `InMemoryStorage`, whose `Mutex<State>`
//   serialises all row operations. These two locks together prevent
//   double-spending in the same way the Swift actor's single-threaded serial
//   queue does.
//
//   The force-test simulates the failure mode by spawning N threads, each
//   of which holds a clone of the `Arc<dyn Storage>` (not the
//   `EstateCoordinator`) and calls `debit_budget` concurrently. Because the
//   storage backend's internal mutex serialises all writes, only one thread
//   can win the race to debit the last quantum and the budget must never go
//   negative.
//
// Mirror of Swift CrossEstateFederationTests (concurrent budget tests).
// ---------------------------------------------------------------------------

/// GRT-07a: Sequential debits against the GrantStore never drive the budget
/// below zero.
///
/// This test verifies the clamp-at-zero invariant through the storage layer:
/// after N debits each larger than the remaining budget, the final persisted
/// budget must be exactly 0.0 — never negative.
///
/// Rust enforcement model:
///   The `EstateCoordinator` is `!Sync` and serialises all access behind a
///   `Mutex<EstateCoordinator>` in the MCP server. The coordinator's
///   `federated_recall` takes `&mut self` which prevents reentrancy from the
///   same thread. The test validates the storage-layer clamp; the
///   coordinator-level serial guarantee is tested in GRT-07b.
///
/// Swift mirror: CrossEstateFederationTests concurrent budget gate tests.
/// The Swift actor enforces the same invariant via its serial executor.
#[test]
fn grt07a_sequential_debits_never_go_negative() {
    use genius_locus_kit::GrantStore;
    use persistence_kit::inmemory::InMemoryStorage;
    use persistence_kit::storage::Storage;

    let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()))
        as Arc<dyn Storage>;
    let store = GrantStore::new(Arc::clone(&storage)).expect("store init");

    // Seed a grant with exactly one quantum of budget.
    let grant_id = Uuid::new_v4();
    let grant = Grant {
        id: grant_id,
        grantee_estate_id: Uuid::new_v4(),
        scope: GrantScope::WholeEstate,
        content_level: 0,
        lifetime: GrantLifetime::Permanent,
        custody_mode: CustodyMode::HandedOver,
        re_share_permission: ReSharePermission::None,
        inference_remaining_budget: EstateCoordinator::BUDGET_DEBIT_PER_READ,
        issued_at: NOW_F64,
        signature: vec![],
    };
    store.insert(&grant).expect("insert");

    // Apply 8 sequential debits. Each sees the current budget and clamps.
    // Only the first debit reduces a positive budget; the rest hit 0.0.
    let n_debits = 8;
    let mut positive_count = 0usize;
    for _ in 0..n_debits {
        let pre = store.debit_budget(grant_id, EstateCoordinator::BUDGET_DEBIT_PER_READ)
            .expect("debit");
        if pre > 0.0 { positive_count += 1; }
    }

    // Post-condition: final budget must be >= 0.0 (clamped, not negative).
    let final_budget = store.get(grant_id)
        .expect("get ok")
        .expect("grant present")
        .grant
        .inference_remaining_budget;
    assert!(
        final_budget >= 0.0,
        "GRT-07a: debits must not produce negative budget; got {final_budget}"
    );
    assert!(
        final_budget.abs() < 1e-9,
        "GRT-07a: final budget must be 0.0, got {final_budget}"
    );

    // Post-condition: exactly one debit observed positive pre-budget.
    assert_eq!(
        positive_count, 1,
        "GRT-07a: exactly one debit should observe a positive pre-budget"
    );
}

/// GRT-07b: Concurrent federated reads through a `Mutex<EstateCoordinator>`
/// cannot double-grant the last budget quantum.
///
/// N threads each hold a `Arc<Mutex<EstateCoordinator>>` and call
/// `federated_recall` concurrently. Because every call acquires the mutex
/// before proceeding, the calls are serialised — only one can run at a time.
/// The budget gate inside `federated_recall` checks the budget, refuses if
/// exhausted, and debits atomically (read-then-write inside a storage
/// transaction). The Mutex ensures no two calls interleave.
///
/// Expected result: exactly one call succeeds (the one that sees budget > 0),
/// and all subsequent calls fail with `BudgetExhausted`.
///
/// Rust enforcement model:
///   `EstateCoordinator` is `!Sync`. The `Mutex<EstateCoordinator>` in
///   the MCP server is the equivalent of the Swift actor's serial queue.
///   This test mirrors that pattern directly.
///
/// Swift mirror: CrossEstateFederationTests concurrent budget gate tests.
#[test]
fn grt07b_concurrent_coordinator_recalls_do_not_double_grant_last_quantum() {
    use std::sync::{Arc, Mutex};

    // Build a two-estate coordinator behind a Mutex.
    let mut inner_coord = EstateCoordinator::new();
    let src_store: Arc<dyn locus_kit::drawer_store::DrawerStore> =
        Arc::new(locus_kit::drawer_store_inmemory::InMemoryDrawerStore::new(NOW, None).unwrap());
    let req_store: Arc<dyn locus_kit::drawer_store::DrawerStore> =
        Arc::new(locus_kit::drawer_store_inmemory::InMemoryDrawerStore::new(NOW, None).unwrap());
    let src = inner_coord.open(src_store, locus_kit::estate_types::OwnerCredentials::new("source"), 0, 100).expect("open source");
    let req = inner_coord.open(req_store, locus_kit::estate_types::OwnerCredentials::new("requester"), 0, 100).expect("open req");
    let requester_uuid = Uuid::from_bytes(req.estate_uuid);

    // Issue a grant with exactly one quantum of budget.
    let opts = GrantOptions {
        grantee_estate_id: requester_uuid,
        scope: GrantScope::WholeEstate,
        custody_mode: CustodyMode::HandedOver,
        lifetime: GrantLifetime::Permanent,
        content_level: 0,
        re_share_permission: ReSharePermission::None,
    };
    let IssueGrantResult { grant, .. } =
        inner_coord.issue_grant(&src, opts, &[0xFFu8; 32], NOW_F64).expect("issue");
    // Set budget to exactly one quantum.
    inner_coord.grant_store_mut(&src).expect("store")
        .set_budget(grant.id, EstateCoordinator::BUDGET_DEBIT_PER_READ)
        .expect("set_budget");

    let coord = Arc::new(Mutex::new(inner_coord));

    // Spawn N threads, each competing for the single federated recall quota.
    let n_threads = 8;
    let results: Arc<Mutex<Vec<Result<(), ()>>>> = Arc::new(Mutex::new(Vec::new()));
    let mut handles = Vec::new();
    for _ in 0..n_threads {
        let coord_clone = Arc::clone(&coord);
        let results_clone = Arc::clone(&results);
        let src_c = src;
        let req_c = req;
        handles.push(std::thread::spawn(move || {
            let mut guard = coord_clone.lock().unwrap();
            let outcome = guard.federated_recall(
                RecallFrame::new(vec![]),
                &src_c,
                &req_c,
                NOW_F64 + 1.0,
                NOW + 1,
            );
            let r = if outcome.is_ok() { Ok(()) } else { Err(()) };
            results_clone.lock().unwrap().push(r);
        }));
    }
    for h in handles { h.join().expect("thread panicked"); }

    // Post-condition: exactly one call succeeded (budget was available).
    let results = results.lock().unwrap();
    let success_count = results.iter().filter(|r| r.is_ok()).count();
    assert_eq!(
        success_count, 1,
        "GRT-07b: exactly one recall should succeed when budget = one quantum; got {success_count}"
    );

    // Post-condition: the final stored budget is 0.0.
    let final_budget = coord.lock().unwrap()
        .grant_store_mut(&src)
        .expect("store")
        .get(grant.id)
        .expect("get ok")
        .expect("grant present")
        .grant
        .inference_remaining_budget;
    assert!(
        final_budget.abs() < 1e-9,
        "GRT-07b: final budget must be 0.0 after one successful recall; got {final_budget}"
    );
}

// ---------------------------------------------------------------------------
// GRT-07 — mode-4 time-aging custody (restored mode-4 slot)
//
// Mode 4 (`CustodyMode::TimeAging`) restores the Appendix B mode-4 slot as a
// deterministic software decay policy. The effective content level halves every
// half-life of elapsed time since started_at, floored at floor, computed against
// an injected `now`. These tests pin the SAME attenuation values the Swift
// `GRT04_TimeAgingCustodyTests` assert, so the discrete decay schedule is
// bit-comparable across ports.
// ---------------------------------------------------------------------------

/// GRT-07a: `DecayPolicy::effective_level` halves each half-life and floors.
///
/// Swift mirror: GRT04_TimeAgingCustodyTests.effectiveLevelHalvesEachHalfLifeAndFloors
/// — identical fixture (base 48, half-life 100s, floor 4) and identical
/// expected values 48/24/12/6/4, proving the two ports agree on the discrete
/// attenuation schedule.
#[test]
fn grt07a_effective_level_matches_swift_decay_schedule() {
    let t0 = 1_000_000.0_f64; // Apple reference seconds, decay-clock origin
    let policy = DecayPolicy { half_life_seconds: 100, started_at: t0, floor: 4 };
    assert_eq!(policy.effective_level(48, t0), 48, "t0: undecayed");
    assert_eq!(policy.effective_level(48, t0 + 100.0), 24, "one half-life: 24");
    assert_eq!(policy.effective_level(48, t0 + 200.0), 12, "two half-lives: 12");
    assert_eq!(policy.effective_level(48, t0 + 300.0), 6, "three half-lives: 6");
    assert_eq!(policy.effective_level(48, t0 + 400.0), 4, "floor clamps the residual");
    assert_eq!(policy.effective_level(48, t0 - 50.0), 48, "pre-start is undecayed");
}

/// GRT-07b: issuance + persisted read-back round-trips the decay policy.
///
/// Swift mirror: GRT04_TimeAgingCustodyTests.issueWithExplicitDecayFieldsPersistsPolicy.
/// A mode-4 grant issued with explicit decay fields decodes back from the store
/// carrying the same half-life, started_at, and floor in the dedicated columns.
#[test]
fn grt07b_issue_and_readback_round_trips_policy() {
    let (mut coord, h) = open_coord();
    let t0 = 1_000_000.0_f64;
    let opts = GrantOptions {
        grantee_estate_id: Uuid::new_v4(),
        scope: GrantScope::WholeEstate,
        custody_mode: CustodyMode::TimeAging(DecayPolicy {
            half_life_seconds: 3600, started_at: t0, floor: 1,
        }),
        lifetime: GrantLifetime::Permanent,
        content_level: 48,
        re_share_permission: ReSharePermission::None,
    };
    let IssueGrantResult { grant, scope_key } =
        coord.issue_grant(&h, opts, &[0x4Du8; 32], t0).expect("issue");
    // Mode 4 hands the scope key to the recipient (mode-2 derivation).
    assert!(scope_key.is_some(), "mode 4 returns the handed-over scope key");

    let store = coord.grant_store(&h).expect("store present");
    let stored = store.get(grant.id).expect("get").expect("row present");
    match &stored.grant.custody_mode {
        CustodyMode::TimeAging(p) => {
            assert_eq!(p.half_life_seconds, 3600);
            assert_eq!(p.floor, 1);
            assert_eq!(p.started_at, t0, "decay clock round-trips through the column");
        }
        other => panic!("decoded custody mode is not TimeAging: {other:?}"),
    }
}

/// GRT-07c: legacy `physicalDecay` token decodes (migrates) into TimeAging.
///
/// Swift mirror: GRT04_TimeAgingCustodyTests.legacyPhysicalDecayTokenDecodesIntoTimeAgingWithDefaults.
/// A row carrying the legacy mode-4 token with NO decay columns must decode with
/// documented defaults (30-day half-life, decay clock = issued_at, floor 0) —
/// never a CorruptRow.
#[test]
fn grt07c_legacy_physical_decay_token_decodes_with_defaults() {
    use std::collections::HashMap;
    // Build a text-dict row with the legacy physicalDecay token and no
    // decay_* columns. The issued_at ISO string is "2001-01-12T13:46:40Z"
    // which is Unix epoch second 979_307_200 (= Apple-ref 1_000_000 + offset
    // 978_307_200). The Rust port parses ISO-8601 to Unix epoch seconds.
    let issued_iso = "2001-01-12T13:46:40Z"; // Unix epoch: 979_307_200
    let mut row: HashMap<&str, &str> = HashMap::new();
    row.insert("id", "12345678-1234-1234-1234-123456789ABC");
    row.insert("grantee_id", "ABCDEF01-2345-6789-ABCD-EF0123456789");
    row.insert("custody_mode", "physicalDecay");
    row.insert("reshare", "none");
    row.insert("issued_at", issued_iso);

    let stored = genius_locus_kit::GrantStore::decode_row(&row)
        .expect("legacy physicalDecay row must decode, never CorruptRow");
    match &stored.grant.custody_mode {
        CustodyMode::TimeAging(p) => {
            assert_eq!(p.half_life_seconds, DecayPolicy::DEFAULT_HALF_LIFE_SECONDS);
            assert_eq!(p.floor, 0);
            // started_at defaults to issued_at (Unix epoch 979_307_200, within rounding).
            assert!((p.started_at - 979_307_200.0).abs() < 1.0,
                "legacy row defaults the decay clock to issued_at; got {}", p.started_at);
        }
        other => panic!("legacy physicalDecay did not decode into TimeAging: {other:?}"),
    }
}

/// GRT-07d: federation — a grant decayed to 0 (floor 0) refuses CustodyRefused.
///
/// Swift mirror: GRT04_TimeAgingCustodyTests.decayedToZeroFloorZeroRefusesCustody.
#[test]
fn grt07d_decayed_to_zero_floor_zero_refuses() {
    let (mut coord, src, req) = open_two_estate_coord();
    let requester_uuid = Uuid::from_bytes(req.estate_uuid);
    let t0 = NOW_F64;

    let opts = GrantOptions {
        grantee_estate_id: requester_uuid,
        scope: GrantScope::WholeEstate,
        custody_mode: CustodyMode::TimeAging(DecayPolicy {
            half_life_seconds: 100, started_at: t0, floor: 0,
        }),
        lifetime: GrantLifetime::Permanent,
        content_level: 32,
        re_share_permission: ReSharePermission::None,
    };
    let IssueGrantResult { grant, .. } =
        coord.issue_grant(&src, opts, &[0x4Eu8; 32], t0).expect("issue");
    coord.grant_store_mut(&src).expect("store").set_budget(grant.id, 1.0).expect("set_budget");

    // t0 + 1000 (ten half-lives): effective level is 0 → refuse.
    let result = coord.federated_recall(
        RecallFrame::new(vec![Filter::Unconfirmed]),
        &src,
        &req,
        t0 + 1000.0,
        NOW + 1000,
    );
    match result {
        Err(GeniusLocusKitError::CrossEstateReadRefused { reason, .. }) => {
            assert_eq!(reason, FederatedReadRefusalReason::CustodyRefused,
                "decayed-to-zero grant refuses with CustodyRefused");
        }
        other => panic!("expected CustodyRefused, got {other:?}"),
    }
}

/// GRT-07e: federation — a mid-decay grant (positive floor) proceeds and the
/// budget debits, proving decay and budget compose.
///
/// Swift mirror: GRT04_TimeAgingCustodyTests.budgetDebitsWhileDecayAttenuates.
#[test]
fn grt07e_mid_decay_grant_proceeds_and_budget_debits() {
    let (mut coord, src, req) = open_two_estate_coord();
    let requester_uuid = Uuid::from_bytes(req.estate_uuid);
    let t0 = NOW_F64;

    let opts = GrantOptions {
        grantee_estate_id: requester_uuid,
        scope: GrantScope::WholeEstate,
        custody_mode: CustodyMode::TimeAging(DecayPolicy {
            half_life_seconds: 100, started_at: t0, floor: 1,
        }),
        lifetime: GrantLifetime::Permanent,
        content_level: 48,
        re_share_permission: ReSharePermission::None,
    };
    let IssueGrantResult { grant, .. } =
        coord.issue_grant(&src, opts, &[0x4Fu8; 32], t0).expect("issue");
    coord.grant_store_mut(&src).expect("store").set_budget(grant.id, 1.0).expect("set_budget");

    // Mid-decay read (one half-life) succeeds (floor 1 keeps the grant usable).
    let result = coord.federated_recall(
        RecallFrame::new(vec![Filter::Unconfirmed]),
        &src,
        &req,
        t0 + 100.0,
        NOW + 100,
    );
    assert!(result.is_ok(), "mid-decay grant should proceed; got {:?}", result.err());

    let budget_after = coord.grant_store(&src).expect("store")
        .get(grant.id).expect("get").expect("row")
        .grant.inference_remaining_budget;
    assert!((budget_after - 0.99).abs() < 1e-9,
        "one read debits 0.01 regardless of decay state; got {budget_after}");
}

// ---------------------------------------------------------------------------
// B1 Finding #2 regression — degenerate mode-3 custody parameters guard
//
// Mirrors Swift GRT01_GrantTests tests decayDerivedRejectsZeroThreshold,
// decayDerivedRejectsTotalSharesBelowThreshold, decayDerivedRejectsTotalSharesAboveCap,
// and decayDerivedAcceptsValidParameters.
//
// A mode-3 (DecayDerived) grant with threshold=0 causes Lagrange
// reconstruction to interpolate an empty point set → DecayFieldElement::zero,
// a constant anyone can precompute, breaking the custody model. The guard
// also rejects totalShares < threshold and totalShares > 255.
// ---------------------------------------------------------------------------

/// Mode-3 with `threshold = 0` and clearance confirmed must be rejected with
/// `GrantError::InvalidCustodyParameters`.
///
/// Swift mirror: GRT01_GrantTests.decayDerivedRejectsZeroThreshold
#[test]
fn grt08a_mode3_threshold_zero_rejected() {
    use genius_locus_kit::GrantError;
    let (mut coord, h) = open_coord();
    let opts = GrantOptions {
        grantee_estate_id: Uuid::new_v4(),
        scope: GrantScope::WholeEstate,
        custody_mode: CustodyMode::DecayDerived {
            // threshold=0 causes Lagrange interpolation over an empty share set
            // → DecayFieldElement::zero — a precomputable constant (B1 finding #2).
            threshold: 0,
            total_shares: 3,
            drift_rate: DriftRate::Slow,
            experimental_ip_clearance_confirmed: true,
        },
        lifetime: GrantLifetime::Permanent,
        content_level: 0,
        re_share_permission: ReSharePermission::None,
    };
    let err = coord.issue_grant(&h, opts, &[0u8; 32], NOW_F64).unwrap_err();
    assert_eq!(
        err, GrantError::InvalidCustodyParameters,
        "GRT-08a: threshold=0 must produce InvalidCustodyParameters"
    );
}

/// Mode-3 with `total_shares < threshold` and clearance confirmed must be
/// rejected — reconstruction is impossible when the share count is below the
/// threshold.
///
/// Swift mirror: GRT01_GrantTests.decayDerivedRejectsTotalSharesBelowThreshold
#[test]
fn grt08b_mode3_total_shares_below_threshold_rejected() {
    use genius_locus_kit::GrantError;
    let (mut coord, h) = open_coord();
    let opts = GrantOptions {
        grantee_estate_id: Uuid::new_v4(),
        scope: GrantScope::WholeEstate,
        custody_mode: CustodyMode::DecayDerived {
            threshold: 5,
            // total_shares < threshold: cannot reconstruct the secret.
            total_shares: 3,
            drift_rate: DriftRate::Slow,
            experimental_ip_clearance_confirmed: true,
        },
        lifetime: GrantLifetime::Permanent,
        content_level: 0,
        re_share_permission: ReSharePermission::None,
    };
    let err = coord.issue_grant(&h, opts, &[0u8; 32], NOW_F64).unwrap_err();
    assert_eq!(
        err, GrantError::InvalidCustodyParameters,
        "GRT-08b: total_shares < threshold must produce InvalidCustodyParameters"
    );
}

/// Mode-3 with `total_shares > 255` and clearance confirmed must be rejected —
/// the implementation cap guards against pathological share counts.
///
/// Swift mirror: GRT01_GrantTests.decayDerivedRejectsTotalSharesAboveCap
#[test]
fn grt08c_mode3_total_shares_above_cap_rejected() {
    use genius_locus_kit::GrantError;
    let (mut coord, h) = open_coord();
    let opts = GrantOptions {
        grantee_estate_id: Uuid::new_v4(),
        scope: GrantScope::WholeEstate,
        custody_mode: CustodyMode::DecayDerived {
            threshold: 2,
            // total_shares = 256 exceeds the MAX_DECAY_SHARES cap of 255.
            total_shares: 256,
            drift_rate: DriftRate::Slow,
            experimental_ip_clearance_confirmed: true,
        },
        lifetime: GrantLifetime::Permanent,
        content_level: 0,
        re_share_permission: ReSharePermission::None,
    };
    let err = coord.issue_grant(&h, opts, &[0u8; 32], NOW_F64).unwrap_err();
    assert_eq!(
        err, GrantError::InvalidCustodyParameters,
        "GRT-08c: total_shares > 255 must produce InvalidCustodyParameters"
    );
}

/// Valid mode-3 parameters (threshold > 0, total_shares ≥ threshold, ≤ 255,
/// clearance confirmed) must succeed — the guard must not be a spurious barrier.
///
/// Swift mirror: GRT01_GrantTests.decayDerivedAcceptsValidParameters
#[test]
fn grt08d_mode3_valid_parameters_accepted() {
    let (mut coord, h) = open_coord();
    let opts = GrantOptions {
        grantee_estate_id: Uuid::new_v4(),
        scope: GrantScope::WholeEstate,
        custody_mode: CustodyMode::DecayDerived {
            threshold: 2,
            total_shares: 3,
            drift_rate: DriftRate::Slow,
            experimental_ip_clearance_confirmed: true,
        },
        lifetime: GrantLifetime::Permanent,
        content_level: 0,
        re_share_permission: ReSharePermission::None,
    };
    // Must not error — valid parameters with clearance confirmed.
    coord.issue_grant(&h, opts, &[0x11u8; 32], NOW_F64)
        .expect("GRT-08d: valid mode-3 parameters must succeed");
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn hex_decode(hex: &str) -> Vec<u8> {
    assert!(hex.len() % 2 == 0, "hex string must have even length");
    (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).expect("valid hex"))
        .collect()
}
