// fed_sig01_grant_signature_tests.rs
//
// FED-SIG-01 — Grant signature verification at the federated_recall boundary.
//
// D9 hardening (DECISION_FEDERATION_SHARING_MODEL_2026-05-21 Delta 6):
// federated_recall verifies each candidate grant's Ed25519 signature against
// the GRANTER's registered identity public key before any recall is performed.
// Trust derives from the estate registry (the manifest-persisted public key),
// not from any field in the grant blob — the same registered-key trust anchor
// as the F-3 pull() hardening in ConvergenceKit FederationSyncEngine.
//
// Three coverage points (mirrors Swift FED_SIG01_GrantSignatureTests):
//
//   (a) fed_sig01a — a grant carrying a forged (non-empty, invalid) signature
//       is rejected with CrossEstateReadRefused { reason: InvalidGrantSignature }.
//
//   (b) fed_sig01b — a grant signed with the granter's actual identity key
//       (the key pre-seeded in the estate manifest) recalls successfully.
//
//   (c) fed_sig01c — a grant carrying an empty signature (legacy pre-signing
//       behaviour) is allowed on the local in-process path (I-13 invariant)
//       with a logged warning. D9 migration posture.

use base64::Engine as _;
use genius_locus_kit::{
    CustodyMode, EstateCoordinator, FederatedReadRefusalReason, GeniusLocusKitError,
    Grant, GrantLifetime, GrantScope, ReSharePermission,
};
use std::sync::Arc;
use uuid::Uuid;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::estate_types::OwnerCredentials;
use locus_kit::filter::{Filter, RecallFrame};

const NOW: i64 = 1_700_000_000;
const NOW_F64: f64 = 1_700_000_000.0;

// ---------------------------------------------------------------------------
// Shared harness
// ---------------------------------------------------------------------------

/// Open a two-estate coordinator where the SOURCE estate has its
/// ed25519_public_key seeded from a KNOWN keypair (controlled by the test).
///
/// Returns (coord, src, req, local_identity) where `local_identity` is the
/// convergence_kit::LocalIdentity whose signing key corresponds to the public
/// key registered in the source estate's manifest. Use it to produce valid
/// grant signatures for test (b).
fn open_two_estate_coord_with_known_identity() -> (
    EstateCoordinator,
    genius_locus_kit::EstateHandle,
    genius_locus_kit::EstateHandle,
    convergence_kit::LocalIdentity,
) {
    // Use a fixed 32-byte seed so the test is deterministic.
    const IDENTITY_SEED: [u8; 32] = [0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04,
                                     0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C,
                                     0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13, 0x14,
                                     0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C];

    let local_identity = convergence_kit::LocalIdentity::from_secret(IDENTITY_SEED);
    let pub_key_bytes = local_identity.public_key_bytes();
    let b64 = base64::engine::general_purpose::STANDARD;
    let pub_key_b64 = b64.encode(&pub_key_bytes);

    // Source estate: pre-seed the manifest's ed25519_public_key so the
    // estate's registered identity key matches our known keypair.
    // estate::from_manifest skips key generation when ed25519_public_key
    // is already present, so the estate uses our pre-seeded key.
    let src_store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    src_store
        .set_meta("ed25519_public_key", &pub_key_b64)
        .expect("pre-seed source estate public key");

    // Requester estate: ordinary fresh estate (no identity control needed).
    let req_store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());

    let mut coord = EstateCoordinator::new();
    let src = coord
        .open(src_store, OwnerCredentials::new("source"), 0, 100)
        .expect("open source");
    let req = coord
        .open(req_store, OwnerCredentials::new("requester"), 0, 100)
        .expect("open requester");

    (coord, src, req, local_identity)
}

/// Build a grant with the given signature bytes for direct insertion into
/// the grant store, bypassing the issue_grant signing path. Uses HandedOver
/// custody mode (mode 2) so federated_recall does not need a scope-key vault
/// entry — the custody gate passes through immediately, isolating the
/// signature check as the only gate under test.
fn make_grant(grantee_uuid: Uuid, signature: Vec<u8>) -> Grant {
    Grant {
        id: Uuid::new_v4(),
        grantee_estate_id: grantee_uuid,
        scope: GrantScope::WholeEstate,
        content_level: 0,
        lifetime: GrantLifetime::Permanent,
        custody_mode: CustodyMode::HandedOver,
        re_share_permission: ReSharePermission::None,
        inference_remaining_budget: 1.0,
        issued_at: NOW_F64,
        signature,
    }
}

// ---------------------------------------------------------------------------
// (a) Forged signature → InvalidGrantSignature
// ---------------------------------------------------------------------------

/// FED-SIG-01a: a grant with a non-empty forged signature is rejected at
/// the federated_recall boundary with InvalidGrantSignature.
///
/// The source estate has a real Ed25519 identity key in its manifest.
/// The grant is signed with 64 zero-bytes — a syntactically-valid length
/// but cryptographically invalid signature over any payload.
///
/// Mirrors Swift FED_SIG01_GrantSignatureTests.forgedSignatureIsRejectedAtFederatedRecallBoundary.
#[test]
fn fed_sig01a_forged_signature_rejected_at_federated_recall() {
    let (mut coord, src, req, _) = open_two_estate_coord_with_known_identity();
    let requester_uuid = Uuid::from_bytes(req.estate_uuid);
    let source_uuid = Uuid::from_bytes(src.estate_uuid);

    // 64 zero-bytes: syntactically valid Ed25519 signature length, but
    // cryptographically invalid over any payload.
    let forged_sig = vec![0x00u8; 64];
    let grant = make_grant(requester_uuid, forged_sig);

    coord
        .grant_store_mut(&src)
        .expect("grant store must be initialised for open estate")
        .insert(&grant)
        .expect("insert forged-signature grant");

    let result = coord.federated_recall(
        RecallFrame::new(vec![Filter::Unconfirmed]),
        &src,
        &req,
        NOW_F64,
        NOW,
    );

    match result {
        Err(GeniusLocusKitError::CrossEstateReadRefused { source, requester, reason }) => {
            assert_eq!(source, source_uuid, "refusal must name the source estate");
            assert_eq!(requester, requester_uuid, "refusal must name the requester");
            assert_eq!(
                reason,
                FederatedReadRefusalReason::InvalidGrantSignature,
                "a forged (non-empty, invalid) signature must refuse with InvalidGrantSignature"
            );
        }
        other => panic!(
            "expected CrossEstateReadRefused with InvalidGrantSignature, got {:?}", other
        ),
    }
}

// ---------------------------------------------------------------------------
// (b) Correctly-signed grant → success
// ---------------------------------------------------------------------------

/// FED-SIG-01b: a grant signed with the granter's actual identity key
/// (matched to the manifest's registered public key) recalls successfully.
///
/// The source estate was opened with a pre-seeded ed25519_public_key derived
/// from IDENTITY_SEED. The grant is signed with the matching private key via
/// convergence_kit::LocalIdentity.sign(). This is the positive D9 path.
///
/// Mirrors Swift FED_SIG01_GrantSignatureTests.correctlySignedGrantRecallsSuccessfully.
#[test]
fn fed_sig01b_correctly_signed_grant_recalls_successfully() {
    let (mut coord, src, req, identity) = open_two_estate_coord_with_known_identity();
    let requester_uuid = Uuid::from_bytes(req.estate_uuid);

    // Build a grant and sign its canonical payload with the matching private key.
    // The public key corresponding to `identity` is what we pre-seeded into the
    // source estate's manifest — so verification at step 4.5 will succeed.
    let grant = {
        let unsigned = make_grant(requester_uuid, vec![]);
        let payload = unsigned.signing_payload();
        let sig = identity.sign(&payload).to_vec();
        Grant { signature: sig, ..unsigned }
    };

    coord
        .grant_store_mut(&src)
        .expect("grant store must be initialised for open estate")
        .insert(&grant)
        .expect("insert signed grant");

    let result = coord.federated_recall(
        RecallFrame::new(vec![Filter::Unconfirmed]),
        &src,
        &req,
        NOW_F64,
        NOW,
    );

    assert!(
        result.is_ok(),
        "a grant signed with the estate's actual identity key must succeed at federated_recall; got {:?}",
        result.err()
    );
    let recall = result.unwrap();
    assert_eq!(
        Uuid::from_bytes(recall.source_handle.estate_uuid),
        Uuid::from_bytes(src.estate_uuid),
        "recall result must name the correct source estate"
    );
    assert!(
        !recall.grant.signature.is_empty(),
        "authorizing grant must carry a non-empty signature"
    );
}

// ---------------------------------------------------------------------------
// (c) Empty (legacy) signature → allowed on local I-13 path
// ---------------------------------------------------------------------------

/// FED-SIG-01c: a grant with an empty signature is allowed on the local
/// in-process path (I-13 invariant — no network crossing, both estates open
/// in the same coordinator) with a logged warning. D9 migration posture for
/// grants that predate the Ed25519 signing scheme.
///
/// Mirrors Swift FED_SIG01_GrantSignatureTests.emptySignatureAllowedOnLocalInProcessPath.
#[test]
fn fed_sig01c_empty_signature_allowed_on_local_i13_path() {
    let (mut coord, src, req, _) = open_two_estate_coord_with_known_identity();
    let requester_uuid = Uuid::from_bytes(req.estate_uuid);

    // Empty signature: `signature.is_empty()` is true. Step 4.5 logs a warning
    // and allows the read — D9 migration posture for legacy pre-signing grants.
    let unsigned_grant = make_grant(requester_uuid, vec![]);

    coord
        .grant_store_mut(&src)
        .expect("grant store must be initialised for open estate")
        .insert(&unsigned_grant)
        .expect("insert legacy unsigned grant");

    let result = coord.federated_recall(
        RecallFrame::new(vec![Filter::Unconfirmed]),
        &src,
        &req,
        NOW_F64,
        NOW,
    );

    assert!(
        result.is_ok(),
        "empty signature (legacy pre-signing grant) must be allowed on the local I-13 path; got {:?}",
        result.err()
    );
    let recall = result.unwrap();
    assert!(
        recall.grant.signature.is_empty(),
        "the authorizing legacy grant must carry an empty signature"
    );
    assert_eq!(
        Uuid::from_bytes(recall.source_handle.estate_uuid),
        Uuid::from_bytes(src.estate_uuid),
        "recall result names the correct source estate"
    );
}
