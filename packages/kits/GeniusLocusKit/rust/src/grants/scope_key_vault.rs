// scope_key_vault.rs — Rust port of ScopeKeyVault.swift.
//
// Mirrors Sources/GeniusLocusKit/Grants/ScopeKeyVault.swift.
//
// Key derivation chain:
//   Mode 1 (Mediated): HKDF(ikm=identity_key_raw, salt="mootx01.grant.scope-key.v1",
//                           info="scope|{grant_id_uppercase_uuid}") → 32-byte scope key.
//   Mode 2 (HandedOver): HKDF with info="scope|{grant_id}|{grantee_id}", both uppercase
//                        hyphenated UUID strings. Scope key returned to caller, not held.
//   Mode 3 (DecayDerived): seed = identity_key_raw ++ grant_id.uuidString.utf8 (NO SHA-256
//                          wrapping). Passed directly to ReferenceDecayShareProvider.
//                          Lagrange reconstruct → key_from_secret → 32 bytes returned.
//
// Session key derivation (access):
//   HKDF(ikm=mediated_scope_key, salt="mootx01.grant.scope-key.v1",
//        info="session|{grant_id_uppercase_uuid}") → 32-byte session key.
//   Note: NO grantee UUID, NO timestamp in the session info. Mirror of Swift
//   ScopeKeyVault.access(grant:now:) which uses "session|{grant.id.uuidString}".
//
// All HKDF calls go through substrate_kernel::hkdf::derive_key (RFC 5869,
// in-repo, no external crates). Mirror of the Swift port, which uses
// SubstrateKernel.GrantHKDF.

use std::collections::{HashMap, HashSet};
use uuid::Uuid;
use zeroize::Zeroizing;

use substrate_kernel::hkdf;
use super::grant::{CustodyMode, Grant, GrantError};
use super::lagrange::{LagrangeDecayKey, ReferenceDecayShareProvider};

/// The fixed salt used for all grant scope-key derivations.
/// Mirror of Swift `GrantHKDF.grantSalt`.
const GRANT_SALT: &str = "mootx01.grant.scope-key.v1";

/// Holds the in-custody scope keys for mode-1 (mediated) grants.
/// Mode-2 and mode-3 scope keys are computed on demand and returned
/// to the caller — they are never retained here.
///
/// Mirror of Swift `ScopeKeyVault`. In the Rust port there is no `actor`
/// keyword; callers must serialise access externally if needed (single-
/// threaded coordinator context).
pub struct ScopeKeyVault {
    /// Grant-id → 32-byte scope key, held for mode-1 grants only.
    /// Wrapped in `Zeroizing` so the key bytes are zeroed on drop and on
    /// remove (revoke). The Zeroizing wrapper guarantees the memory is
    /// overwritten when the entry is removed from the HashMap, preventing
    /// scope key material from persisting in heap memory after revocation.
    mediated_keys: HashMap<Uuid, Zeroizing<[u8; 32]>>,
    revoked: HashSet<Uuid>,
}

impl ScopeKeyVault {
    pub fn new() -> Self {
        ScopeKeyVault {
            mediated_keys: HashMap::new(),
            revoked: HashSet::new(),
        }
    }

    /// Issue a scope key for `grant` using the estate identity key's raw bytes.
    ///
    /// Returns the derived scope key for modes 2 and 3 (returned to the
    /// grantee), or `None` for mode 1 (held inside the vault, not returned).
    ///
    /// Mirror of Swift `ScopeKeyVault.issue(grant:identityKeyRawBytes:)`.
    pub fn issue(
        &mut self,
        grant: &Grant,
        identity_key_raw: &[u8],
    ) -> Result<Option<Vec<u8>>, GrantError> {
        match &grant.custody_mode {
            CustodyMode::Mediated => {
                // Mode 1: info = "scope|{grant_id}" — no grantee. Mirror of Swift
                // `Self.info(grantID: grant.id, grantee: nil)`.
                let info_bytes = Self::info_bytes(grant.id, None);
                let key_bytes = hkdf::derive_key(identity_key_raw, GRANT_SALT, &info_bytes, 32);
                let mut stored = Zeroizing::new([0u8; 32]);
                stored.copy_from_slice(&key_bytes);
                self.mediated_keys.insert(grant.id, stored);
                Ok(None)
            }

            CustodyMode::HandedOver => {
                // Mode 2: info = "scope|{grant_id}|{grantee_id}" — includes grantee so the
                // handed-over key is bound to its recipient. Mirror of Swift
                // `Self.info(grantID: grant.id, grantee: grant.granteeEstateID)`.
                let info_bytes = Self::info_bytes(grant.id, Some(grant.grantee_estate_id));
                let key_bytes = hkdf::derive_key(identity_key_raw, GRANT_SALT, &info_bytes, 32);
                Ok(Some(key_bytes))
            }

            CustodyMode::DecayDerived {
                threshold,
                total_shares,
                drift_rate,
                experimental_ip_clearance_confirmed,
            } => {
                if !experimental_ip_clearance_confirmed {
                    return Err(GrantError::ExperimentalModeNotActivated);
                }
                // Seed = identity_key_raw ++ grant.id.uuidString.utf8 (NO SHA-256 wrapping).
                // Mirror of Swift: Data(identityKeyRawBytes) + Data(grant.id.uuidString.utf8)
                // The UUID string is uppercase hyphenated (e.g. "12345678-1234-1234-1234-123456789ABC"),
                // matching Swift's UUID.uuidString which is always uppercase.
                // The seed is passed DIRECTLY to ReferenceDecayShareProvider — it is NOT
                // hashed here. The provider's coefficient derivation hashes it internally
                // (SHA256(seed ++ "decay-coef-{i}")) to produce the sharing polynomial.
                let grant_id_str = grant.id.to_string().to_uppercase();
                let mut seed = identity_key_raw.to_vec();
                seed.extend_from_slice(grant_id_str.as_bytes());

                let provider = ReferenceDecayShareProvider::new(
                    *threshold,
                    *total_shares,
                    drift_rate.clone(),
                    grant.issued_at,
                    &seed,
                );
                let key = LagrangeDecayKey::reconstruct(*threshold, &provider, grant.issued_at)?;
                Ok(Some(key.to_vec()))
            }

            CustodyMode::TimeAging(_) => {
                // Mode 4: the scope key is derived once and handed to the
                // recipient exactly as mode 2 — the time-aging policy
                // attenuates the *content level* on the recall path, not the
                // key. Binding to the grantee (mode-2 derivation) keeps a
                // mode-4 key from being usable by any other estate. The vault
                // retains nothing. Mirror of Swift ScopeKeyVault.issue `.timeAging`.
                let info_bytes = Self::info_bytes(grant.id, Some(grant.grantee_estate_id));
                let key_bytes = hkdf::derive_key(identity_key_raw, GRANT_SALT, &info_bytes, 32);
                Ok(Some(key_bytes))
            }
        }
    }

    /// Derive a session key for an active mediated grant.
    ///
    /// Session key = HKDF(ikm=scope_key, salt=GRANT_SALT,
    ///                    info="session|{grant_id_uppercase_uuid}")
    ///
    /// The `now` parameter is used for expiry checking only — it does NOT appear
    /// in the HKDF info string. Mirror of Swift `ScopeKeyVault.access(grant:now:)`.
    pub fn access(&self, grant: &Grant, now: f64) -> Result<Vec<u8>, GrantError> {
        if self.revoked.contains(&grant.id) {
            return Err(GrantError::GrantRevoked(grant.id));
        }
        // Check expiry (mode-2/3 grants check locally; mode-1 checked here).
        if let Some(expiry) = grant.lifetime.expiry(grant.issued_at) {
            if now > expiry {
                return Err(GrantError::GrantExpired(grant.id));
            }
        }
        let Some(scope_key) = self.mediated_keys.get(&grant.id) else {
            return Err(GrantError::ScopeKeyUnavailable(grant.id));
        };
        // Session info = "session|{grant_id}" — no grantee, no timestamp.
        // Mirror of Swift: [UInt8]("session|\(grant.id.uuidString)".utf8).
        let session_info = Self::session_info_bytes(grant.id);
        // Deref Zeroizing<[u8; 32]> to &[u8; 32], then to &[u8] for the HKDF call.
        let session_key = hkdf::derive_key(scope_key.as_ref(), GRANT_SALT, &session_info, 32);
        Ok(session_key)
    }

    /// Revoke a grant: remove its scope key from the vault and record the id.
    ///
    /// Mirror of Swift `ScopeKeyVault.revoke(grantID:)`.
    pub fn revoke(&mut self, grant_id: Uuid) {
        self.mediated_keys.remove(&grant_id);
        self.revoked.insert(grant_id);
    }

    /// Whether the vault currently holds a scope key for `id`.
    ///
    /// Mirror of Swift `ScopeKeyVault.holdsScopeKey(for:)`.
    pub fn holds_scope_key(&self, id: Uuid) -> bool {
        self.mediated_keys.contains_key(&id)
    }

    /// Remove a scope key from the vault without recording a revocation.
    ///
    /// Test helper for simulating vault-key loss (e.g. estate restart without
    /// key reload) so that mode-1 custody gate tests can verify CustodyRefused.
    /// Unlike `revoke`, this does NOT add the grant id to the revoked set —
    /// the grant remains active in the GrantStore; only the in-memory key is gone.
    pub fn remove_scope_key(&mut self, id: Uuid) {
        self.mediated_keys.remove(&id);
    }

    // MARK: - Private helpers

    /// The HKDF `info` bytes for scope-key derivation.
    ///
    /// Mode 1 (no grantee): `"scope|{grantID.uuidString}"` — grant ID only.
    /// Mode 2 (with grantee): `"scope|{grantID.uuidString}|{granteeEstateID.uuidString}"`.
    ///
    /// Both UUID strings are uppercase hyphenated (e.g. "12345678-ABCD-..."), matching
    /// Swift's UUID.uuidString which is always uppercase.
    ///
    /// Byte-identical to Swift `ScopeKeyVault.info(grantID:grantee:)`.
    fn info_bytes(grant_id: Uuid, grantee: Option<Uuid>) -> Vec<u8> {
        let grant_id_str = grant_id.to_string().to_uppercase();
        match grantee {
            Some(g) => {
                let grantee_str = g.to_string().to_uppercase();
                format!("scope|{grant_id_str}|{grantee_str}").into_bytes()
            }
            None => format!("scope|{grant_id_str}").into_bytes(),
        }
    }

    /// The HKDF `info` bytes for session-key derivation.
    ///
    /// Format: `"session|{grant_id.uuidString}"` as UTF-8 bytes.
    /// NO grantee UUID. NO timestamp. Mirror of Swift
    /// `ScopeKeyVault.access(grant:now:)` which uses:
    ///   `[UInt8]("session|\(grant.id.uuidString)".utf8)`
    fn session_info_bytes(grant_id: Uuid) -> Vec<u8> {
        let grant_id_str = grant_id.to_string().to_uppercase();
        format!("session|{grant_id_str}").into_bytes()
    }
}

impl Default for ScopeKeyVault {
    fn default() -> Self { Self::new() }
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::grants::grant::{DriftRate, GrantLifetime, GrantScope};

    /// Construct a minimal mode-1 grant for test fixtures.
    fn make_grant(mode: CustodyMode) -> Grant {
        Grant {
            id: Uuid::new_v4(),
            grantee_estate_id: Uuid::new_v4(),
            scope: GrantScope::WholeEstate,
            content_level: 0,
            lifetime: GrantLifetime::Permanent,
            custody_mode: mode,
            re_share_permission: super::super::grant::ReSharePermission::None,
            inference_remaining_budget: 1000.0,
            issued_at: 1_700_000_000.0,
            signature: vec![],
        }
    }

    #[test]
    fn mode1_issue_holds_key_in_vault() {
        let identity_key = [0xABu8; 32];
        let grant = make_grant(CustodyMode::Mediated);
        let mut vault = ScopeKeyVault::new();
        let result = vault.issue(&grant, &identity_key).unwrap();
        assert!(result.is_none(), "mode 1 returns None — key is in the vault");
        assert!(vault.holds_scope_key(grant.id), "vault holds the mode-1 key");
    }

    #[test]
    fn mode2_issue_returns_key_not_held() {
        let identity_key = [0xCDu8; 32];
        let grant = make_grant(CustodyMode::HandedOver);
        let mut vault = ScopeKeyVault::new();
        let result = vault.issue(&grant, &identity_key).unwrap();
        assert!(result.is_some(), "mode 2 returns the scope key");
        assert_eq!(result.unwrap().len(), 32, "returned key is 32 bytes");
        assert!(!vault.holds_scope_key(grant.id), "vault does not retain mode-2 key");
    }

    #[test]
    fn mode3_without_clearance_returns_not_activated() {
        let identity_key = [0xEFu8; 32];
        let grant = make_grant(CustodyMode::DecayDerived {
            threshold: 3,
            total_shares: 6,
            drift_rate: DriftRate::Slow,
            experimental_ip_clearance_confirmed: false,
        });
        let mut vault = ScopeKeyVault::new();
        let result = vault.issue(&grant, &identity_key);
        assert_eq!(result, Err(GrantError::ExperimentalModeNotActivated));
    }

    #[test]
    fn mode3_with_clearance_returns_32_byte_key() {
        let identity_key = [0x11u8; 32];
        let grant = make_grant(CustodyMode::DecayDerived {
            threshold: 2,
            total_shares: 4,
            drift_rate: DriftRate::Slow,
            experimental_ip_clearance_confirmed: true,
        });
        let mut vault = ScopeKeyVault::new();
        let result = vault.issue(&grant, &identity_key).unwrap();
        let key = result.expect("mode 3 with clearance returns a scope key");
        assert_eq!(key.len(), 32, "scope key is 32 bytes");
        assert!(!vault.holds_scope_key(grant.id), "vault does not retain mode-3 key");
    }

    #[test]
    fn revoke_removes_key_and_blocks_access() {
        let identity_key = [0x22u8; 32];
        let grant = make_grant(CustodyMode::Mediated);
        let mut vault = ScopeKeyVault::new();
        vault.issue(&grant, &identity_key).unwrap();
        assert!(vault.holds_scope_key(grant.id));
        vault.revoke(grant.id);
        assert!(!vault.holds_scope_key(grant.id));
        let access_result = vault.access(&grant, grant.issued_at + 1.0);
        assert_eq!(access_result, Err(GrantError::GrantRevoked(grant.id)));
    }

    #[test]
    fn access_mode1_derives_session_key() {
        let identity_key = [0x33u8; 32];
        let grant = make_grant(CustodyMode::Mediated);
        let mut vault = ScopeKeyVault::new();
        vault.issue(&grant, &identity_key).unwrap();
        let session = vault.access(&grant, grant.issued_at + 1.0).unwrap();
        assert_eq!(session.len(), 32, "session key is 32 bytes");
    }

    #[test]
    fn access_expired_grant_returns_expired_error() {
        let identity_key = [0x44u8; 32];
        let grant = Grant {
            lifetime: GrantLifetime::Until(1_700_000_100.0),
            ..make_grant(CustodyMode::Mediated)
        };
        let mut vault = ScopeKeyVault::new();
        vault.issue(&grant, &identity_key).unwrap();
        // Access at t = issued_at + 200 (past the Until deadline).
        let result = vault.access(&grant, grant.issued_at + 200.0);
        assert_eq!(result, Err(GrantError::GrantExpired(grant.id)));
    }
}
