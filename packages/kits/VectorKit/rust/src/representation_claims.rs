//! Executable representation-ownership manifest
//! (GLK shared-content 1.1, P0 — vector representation ownership gate).
//! Rust twin of Swift `VectorRepresentationClaims.swift`.
//!
//! The `vectors` table has no lane-owner field, and GLK and CorpusKit
//! already use overlapping model IDs — so "same model ID" is NOT proof of
//! ownership, and a Drawer-keyed vector may be a shared representation
//! consumed by several lanes. This ledger records, per REPRESENTATION KEY
//! (model_id, model_version, vector_index), which consumers produced or
//! consume that representation:
//!
//!   - one claimant → EXCLUSIVE: the consumer may delete its rows by
//!     exact key;
//!   - several claimants → SHARED: deleting one consumer's index releases
//!     that consumer's claim only, and a vector row may be deleted only
//!     when no retained lane still claims the representation.
//!
//! Deliberately a CONSUMER LEDGER — not a payload copy, not a
//! lane-specific ID scheme, not a model-ID naming convention.

use crate::error::VectorKitError;
use persistence_kit::{
    Column, ColumnDeclaration, IndexDeclaration, SchemaDeclaration, StoragePredicate, Storage,
    TableDeclaration, TypedValue,
};
use std::collections::BTreeMap;
use std::sync::Arc;

/// One representation key: the identity of a stored vector representation,
/// independent of which items carry it.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct VectorRepresentationKey {
    pub model_id: String,
    pub model_version: String,
    /// Lane position (0 = binary engram, 1 = dense float by CorpusKit
    /// convention).
    pub vector_index: u32,
}

impl VectorRepresentationKey {
    pub fn new(
        model_id: impl Into<String>,
        model_version: impl Into<String>,
        vector_index: u32,
    ) -> Self {
        VectorRepresentationKey {
            model_id: model_id.into(),
            model_version: model_version.into(),
            vector_index,
        }
    }
}

/// Durable consumer-claims ledger over vector representations.
pub struct VectorRepresentationClaims {
    storage: Arc<dyn Storage>,
}

impl VectorRepresentationClaims {
    /// Additive ledger schema. Applied via `storage.migrate(..)` like the
    /// other sidecar declarations; not part of any composite schema until
    /// the attached-profile composition (P3) adopts it.
    pub fn schema_declaration() -> SchemaDeclaration {
        SchemaDeclaration::new(
            "VectorKitClaims",
            1,
            vec![TableDeclaration::new(
                "vector_rep_claims",
                vec![
                    ColumnDeclaration::text("model_id"),
                    ColumnDeclaration::text("model_version"),
                    ColumnDeclaration::int("vector_index"),
                    // The claiming lane, e.g. "corpus" or "glk-encode".
                    ColumnDeclaration::text("consumer"),
                    ColumnDeclaration::timestamp("claimed_at"),
                ],
                vec![
                    "model_id".to_string(),
                    "model_version".to_string(),
                    "vector_index".to_string(),
                    "consumer".to_string(),
                ],
            )],
        )
        .with_indices(vec![IndexDeclaration::new(
            "idx_vector_rep_claims_consumer",
            "vector_rep_claims",
            vec!["consumer".to_string()],
        )])
    }

    pub fn new(storage: Arc<dyn Storage>) -> Self {
        VectorRepresentationClaims { storage }
    }

    fn key_predicate(key: &VectorRepresentationKey) -> StoragePredicate {
        StoragePredicate::all(vec![
            StoragePredicate::Eq(
                Column::new("vector_rep_claims", "model_id"),
                TypedValue::Text(key.model_id.clone()),
            ),
            StoragePredicate::Eq(
                Column::new("vector_rep_claims", "model_version"),
                TypedValue::Text(key.model_version.clone()),
            ),
            StoragePredicate::Eq(
                Column::new("vector_rep_claims", "vector_index"),
                TypedValue::Int(key.vector_index as i64),
            ),
        ])
    }

    /// Record that `consumer` produces or consumes `key`. Idempotent
    /// (upsert on the full primary key); re-claiming refreshes `claimed_at`.
    /// `now_millis` is the caller's clock (epoch milliseconds; determinism
    /// discipline — never read the system clock inside the engine).
    pub fn register_claim(
        &self,
        consumer: &str,
        key: &VectorRepresentationKey,
        now_millis: i64,
    ) -> Result<(), VectorKitError> {
        let mut values = BTreeMap::new();
        values.insert("model_id".to_string(), TypedValue::Text(key.model_id.clone()));
        values.insert(
            "model_version".to_string(),
            TypedValue::Text(key.model_version.clone()),
        );
        values.insert(
            "vector_index".to_string(),
            TypedValue::Int(key.vector_index as i64),
        );
        values.insert("consumer".to_string(), TypedValue::Text(consumer.to_string()));
        values.insert("claimed_at".to_string(), TypedValue::Timestamp(now_millis));
        self.storage
            .row_store()
            .upsert(
                "vector_rep_claims",
                values,
                &[
                    "model_id".to_string(),
                    "model_version".to_string(),
                    "vector_index".to_string(),
                    "consumer".to_string(),
                ],
            )
            .map_err(|e| VectorKitError::StoreUnavailable(e.to_string()))?;
        Ok(())
    }

    /// Release `consumer`'s claim on `key`. No-op when not claimed.
    pub fn release_claim(
        &self,
        consumer: &str,
        key: &VectorRepresentationKey,
    ) -> Result<(), VectorKitError> {
        let predicate = StoragePredicate::all(vec![
            Self::key_predicate(key),
            StoragePredicate::Eq(
                Column::new("vector_rep_claims", "consumer"),
                TypedValue::Text(consumer.to_string()),
            ),
        ]);
        self.storage
            .row_store()
            .delete("vector_rep_claims", &predicate)
            .map_err(|e| VectorKitError::StoreUnavailable(e.to_string()))?;
        Ok(())
    }

    /// Release every claim held by `consumer` (index teardown).
    pub fn release_all_claims(&self, consumer: &str) -> Result<(), VectorKitError> {
        self.storage
            .row_store()
            .delete(
                "vector_rep_claims",
                &StoragePredicate::Eq(
                    Column::new("vector_rep_claims", "consumer"),
                    TypedValue::Text(consumer.to_string()),
                ),
            )
            .map_err(|e| VectorKitError::StoreUnavailable(e.to_string()))?;
        Ok(())
    }

    /// The consumers currently claiming `key`, sorted.
    pub fn claimants(&self, key: &VectorRepresentationKey) -> Result<Vec<String>, VectorKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                "vector_rep_claims",
                Some(&Self::key_predicate(key)),
                &[],
                None,
                None,
            )
            .map_err(|e| VectorKitError::StoreUnavailable(e.to_string()))?;
        let mut out: Vec<String> = rows
            .iter()
            .filter_map(|row| match row.get("consumer") {
                Some(TypedValue::Text(t)) => Some(t.clone()),
                _ => None,
            })
            .collect();
        out.sort();
        Ok(out)
    }

    /// Every representation key `consumer` currently claims, sorted.
    pub fn claims(&self, consumer: &str) -> Result<Vec<VectorRepresentationKey>, VectorKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                "vector_rep_claims",
                Some(&StoragePredicate::Eq(
                    Column::new("vector_rep_claims", "consumer"),
                    TypedValue::Text(consumer.to_string()),
                )),
                &[],
                None,
                None,
            )
            .map_err(|e| VectorKitError::StoreUnavailable(e.to_string()))?;
        let mut out: Vec<VectorRepresentationKey> = rows
            .iter()
            .filter_map(|row| {
                let model_id = match row.get("model_id") {
                    Some(TypedValue::Text(t)) => t.clone(),
                    _ => return None,
                };
                let model_version = match row.get("model_version") {
                    Some(TypedValue::Text(t)) => t.clone(),
                    _ => return None,
                };
                let vector_index = match row.get("vector_index") {
                    Some(TypedValue::Int(i)) => *i as u32,
                    _ => return None,
                };
                Some(VectorRepresentationKey {
                    model_id,
                    model_version,
                    vector_index,
                })
            })
            .collect();
        out.sort();
        Ok(out)
    }

    /// True when `consumer` is the SOLE claimant of `key` — the precondition
    /// for deleting the representation's rows rather than merely releasing
    /// the claim. False when unclaimed.
    pub fn is_exclusive(
        &self,
        consumer: &str,
        key: &VectorRepresentationKey,
    ) -> Result<bool, VectorKitError> {
        Ok(self.claimants(key)? == vec![consumer.to_string()])
    }

    /// True when no consumer claims `key` — the release-side precondition
    /// for physically deleting a shared representation's remaining rows.
    pub fn is_unclaimed(&self, key: &VectorRepresentationKey) -> Result<bool, VectorKitError> {
        Ok(self.claimants(key)?.is_empty())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use persistence_kit::inmemory::InMemoryStorage;
    use persistence_kit::{BackendConfiguration, EstateConfiguration};

    fn make_claims() -> VectorRepresentationClaims {
        let config =
            EstateConfiguration::new(uuid::Uuid::new_v4(), BackendConfiguration::InMemory);
        let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(config));
        storage
            .migrate(&VectorRepresentationClaims::schema_declaration())
            .expect("migrate claims schema");
        VectorRepresentationClaims::new(storage)
    }

    const NOW: i64 = 1_700_000_000_000;

    #[test]
    fn ledger_tracks_shared_and_exclusive_ownership() {
        let claims = make_claims();
        let key = VectorRepresentationKey::new("minilm-v6", "1.0.0", 1);

        // Unclaimed at first — never treated as exclusive.
        assert!(claims.is_unclaimed(&key).unwrap());
        assert!(!claims.is_exclusive("corpus", &key).unwrap());

        // One claimant → exclusive.
        claims.register_claim("corpus", &key, NOW).unwrap();
        assert!(claims.is_exclusive("corpus", &key).unwrap());
        assert_eq!(claims.claimants(&key).unwrap(), vec!["corpus"]);

        // Two claimants → shared: NEITHER is exclusive.
        claims.register_claim("glk-encode", &key, NOW).unwrap();
        assert!(!claims.is_exclusive("corpus", &key).unwrap());
        assert!(!claims.is_exclusive("glk-encode", &key).unwrap());
        assert_eq!(
            claims.claimants(&key).unwrap(),
            vec!["corpus", "glk-encode"]
        );

        // Releasing one claim restores the other's exclusivity.
        claims.release_claim("corpus", &key).unwrap();
        assert!(claims.is_exclusive("glk-encode", &key).unwrap());

        // Releasing the last claim leaves the key unclaimed.
        claims.release_claim("glk-encode", &key).unwrap();
        assert!(claims.is_unclaimed(&key).unwrap());
    }

    #[test]
    fn ledger_enumerates_and_bulk_releases_per_consumer() {
        let claims = make_claims();
        let binary = VectorRepresentationKey::new("corpus-deterministic-v1", "1.0.0", 0);
        let float = VectorRepresentationKey::new("corpus-deterministic-v1", "1.0.0", 1);
        let shared = VectorRepresentationKey::new("minilm-v6", "1.0.0", 1);

        claims.register_claim("corpus", &binary, NOW).unwrap();
        claims.register_claim("corpus", &float, NOW).unwrap();
        claims.register_claim("corpus", &shared, NOW).unwrap();
        claims.register_claim("glk-encode", &shared, NOW).unwrap();

        let mut expected = vec![binary.clone(), float.clone(), shared.clone()];
        expected.sort();
        assert_eq!(claims.claims("corpus").unwrap(), expected);

        // Index teardown: the corpus releases everything it claims; the
        // shared key stays claimed by the retained lane.
        claims.release_all_claims("corpus").unwrap();
        assert!(claims.claims("corpus").unwrap().is_empty());
        assert_eq!(claims.claimants(&shared).unwrap(), vec!["glk-encode"]);
        assert!(claims.is_unclaimed(&binary).unwrap());
    }

    #[test]
    fn register_claim_is_idempotent() {
        let claims = make_claims();
        let key = VectorRepresentationKey::new("model", "1.0.0", 0);
        claims.register_claim("corpus", &key, NOW).unwrap();
        claims.register_claim("corpus", &key, NOW + 1).unwrap();
        assert_eq!(claims.claimants(&key).unwrap(), vec!["corpus"]);
    }
}
