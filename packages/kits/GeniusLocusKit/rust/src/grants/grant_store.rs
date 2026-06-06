// grant_store.rs — Rust port of GrantStore.swift.
//
// In-memory grant store for the Rust grant subsystem. The Swift side
// persists grants in SQLite through PersistenceKit; the Rust port does
// not have PersistenceKit yet, so this is a plain HashMap backing.
// Functionally identical for in-process use (coordinator, tests, MCP).
//
// Mirrors the observable behaviour of Sources/GeniusLocusKit/Grants/GrantStore.swift:
// - insert / get / revoke / active / expired / all
// All timestamps are f64 Apple reference seconds.

use std::collections::HashMap;
use uuid::Uuid;
use super::grant::{Grant, GrantError, StoredGrant};

/// In-memory store for `StoredGrant` rows.
///
/// Mirror of Swift `GrantStore`. The persistence layer is an in-memory
/// `HashMap` in the Rust port; the public interface is identical.
pub struct GrantStore {
    store: HashMap<Uuid, StoredGrant>,
}

impl GrantStore {
    pub fn new() -> Self {
        GrantStore { store: HashMap::new() }
    }

    /// Insert a new grant. Overwrites any existing row with the same id.
    pub fn insert(&mut self, grant: Grant) {
        self.store.insert(grant.id, StoredGrant { grant, revoked_at: None });
    }

    /// Fetch a stored grant by id, or `None` if unknown.
    pub fn get(&self, id: Uuid) -> Option<&StoredGrant> {
        self.store.get(&id)
    }

    /// Revoke a grant: record `revoked_at` and mark it inactive.
    ///
    /// Returns `Err(GrantError::GrantNotFound(_))` if the id is unknown.
    pub fn revoke(&mut self, id: Uuid, now: f64) -> Result<(), GrantError> {
        let entry = self.store.get_mut(&id).ok_or(GrantError::GrantNotFound(id))?;
        entry.revoked_at = Some(now);
        Ok(())
    }

    /// Grants that are currently active: not revoked and not expired at `now`.
    pub fn active(&self, now: f64) -> Vec<&StoredGrant> {
        self.store.values().filter(|sg| {
            if sg.revoked_at.is_some() { return false; }
            if let Some(expiry) = sg.grant.lifetime.expiry(sg.grant.issued_at) {
                if now > expiry { return false; }
            }
            true
        }).collect()
    }

    /// Grants that have expired (by deadline) but have NOT been revoked.
    pub fn expired(&self, now: f64) -> Vec<&StoredGrant> {
        self.store.values().filter(|sg| {
            if sg.revoked_at.is_some() { return false; }
            if let Some(expiry) = sg.grant.lifetime.expiry(sg.grant.issued_at) {
                return now > expiry;
            }
            false
        }).collect()
    }

    /// All stored grants, regardless of state.
    pub fn all(&self) -> Vec<&StoredGrant> {
        self.store.values().collect()
    }
}

impl Default for GrantStore {
    fn default() -> Self { Self::new() }
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::grants::grant::{CustodyMode, GrantLifetime, GrantScope, ReSharePermission};

    fn make_grant(lifetime: GrantLifetime) -> Grant {
        Grant {
            id: Uuid::new_v4(),
            grantee_estate_id: Uuid::new_v4(),
            scope: GrantScope::WholeEstate,
            content_level: 0,
            lifetime,
            custody_mode: CustodyMode::Mediated,
            re_share_permission: ReSharePermission::None,
            inference_remaining_budget: 1000.0,
            issued_at: 1_700_000_000.0,
            signature: vec![],
        }
    }

    #[test]
    fn insert_and_get_round_trip() {
        let mut store = GrantStore::new();
        let grant = make_grant(GrantLifetime::Permanent);
        let id = grant.id;
        store.insert(grant);
        assert!(store.get(id).is_some());
    }

    #[test]
    fn active_excludes_revoked() {
        let mut store = GrantStore::new();
        let grant = make_grant(GrantLifetime::Permanent);
        let id = grant.id;
        store.insert(grant);
        store.revoke(id, 1_700_000_100.0).unwrap();
        assert!(store.active(1_700_000_200.0).is_empty());
    }

    #[test]
    fn active_excludes_expired() {
        let mut store = GrantStore::new();
        let grant = make_grant(GrantLifetime::Until(1_700_000_100.0));
        store.insert(grant);
        assert!(store.active(1_700_000_200.0).is_empty());
        assert_eq!(store.active(1_700_000_050.0).len(), 1);
    }

    #[test]
    fn revoke_unknown_returns_not_found() {
        let mut store = GrantStore::new();
        let id = Uuid::new_v4();
        assert_eq!(store.revoke(id, 1.0), Err(GrantError::GrantNotFound(id)));
    }
}
