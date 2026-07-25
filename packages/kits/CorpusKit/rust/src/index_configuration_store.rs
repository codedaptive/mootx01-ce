//! Standalone-only authority for the passage-window policy bound to one
//! CorpusKit database. This module is absent unless the `standalone-passages`
//! feature is enabled; GLK/MOOTx01 does not enable it.

use crate::error::CorpusKitError;
use crate::schema_profile::CorpusIndexUnitPolicy;
use persistence_kit::{
    Column, ColumnDeclaration, SchemaDeclaration, Storage, StoragePredicate, TableDeclaration,
    TypedValue,
};
use std::collections::BTreeMap;
use std::sync::Arc;

pub const PASSAGE_TOKENIZER_ID: &str = "corpus-alphanumeric-v1";
pub const PASSAGE_POLICY_VERSION: i64 = 1;

pub fn policy_fingerprint(policy: CorpusIndexUnitPolicy) -> String {
    match policy {
        CorpusIndexUnitPolicy::WholeContent => "whole-content-v1".to_string(),
        CorpusIndexUnitPolicy::TokenWindows {
            window_tokens,
            overlap_tokens,
        } => format!("token-windows-v1:{PASSAGE_TOKENIZER_ID}:{window_tokens}:{overlap_tokens}"),
    }
}

pub struct CorpusIndexConfigurationStore {
    storage: Arc<dyn Storage>,
}

impl CorpusIndexConfigurationStore {
    pub fn schema_declaration() -> SchemaDeclaration {
        SchemaDeclaration::new(
            "CorpusKitIndexConfiguration",
            1,
            vec![TableDeclaration::new(
                "corpus_index_configuration",
                vec![
                    ColumnDeclaration::int("singleton_id"),
                    ColumnDeclaration::int("policy_version"),
                    ColumnDeclaration::text("policy_fingerprint"),
                    ColumnDeclaration::text("tokenizer_id"),
                    ColumnDeclaration::int("window_tokens").nullable(),
                    ColumnDeclaration::int("overlap_tokens").nullable(),
                ],
                vec!["singleton_id".to_string()],
            )],
        )
    }

    pub fn new(storage: Arc<dyn Storage>) -> Self {
        Self { storage }
    }

    pub fn fingerprint(&self) -> Result<Option<String>, CorpusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                "corpus_index_configuration",
                Some(&StoragePredicate::Eq(
                    Column::new("corpus_index_configuration", "singleton_id"),
                    TypedValue::Int(1),
                )),
                &[],
                Some(1),
                None,
            )
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        Ok(rows
            .first()
            .and_then(|row| match row.get("policy_fingerprint") {
                Some(TypedValue::Text(value)) => Some(value.clone()),
                _ => None,
            }))
    }

    pub fn bind(&self, policy: CorpusIndexUnitPolicy) -> Result<(), CorpusKitError> {
        let requested = policy_fingerprint(policy);
        if let Some(existing) = self.fingerprint()? {
            if existing != requested {
                return Err(CorpusKitError::InvalidConfiguration(format!(
                    "standalone database is indexed with policy {existing}, but the caller \
                     requested {requested}; explicitly rebuild the derived generation before \
                     changing passage windows"
                )));
            }
            return Ok(());
        }

        if matches!(policy, CorpusIndexUnitPolicy::TokenWindows { .. }) {
            let checkpoints = self
                .storage
                .row_store()
                .count("corpus_index_state", None)
                .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
            let indexed_units = self
                .storage
                .row_store()
                .count("iix_doclens", None)
                .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
            if checkpoints != 0 || indexed_units != 0 {
                return Err(CorpusKitError::InvalidConfiguration(
                    "existing standalone derived state has no bound passage policy; open it as \
                     whole-content or explicitly rebuild before enabling passage windows"
                        .into(),
                ));
            }
        }

        let mut values = BTreeMap::new();
        values.insert("singleton_id".into(), TypedValue::Int(1));
        values.insert(
            "policy_version".into(),
            TypedValue::Int(PASSAGE_POLICY_VERSION),
        );
        values.insert(
            "policy_fingerprint".into(),
            TypedValue::Text(requested.clone()),
        );
        values.insert(
            "tokenizer_id".into(),
            TypedValue::Text(PASSAGE_TOKENIZER_ID.to_string()),
        );
        if let CorpusIndexUnitPolicy::TokenWindows {
            window_tokens,
            overlap_tokens,
        } = policy
        {
            values.insert(
                "window_tokens".into(),
                TypedValue::Int(window_tokens as i64),
            );
            values.insert(
                "overlap_tokens".into(),
                TypedValue::Int(overlap_tokens as i64),
            );
        }
        if let Err(insert_error) = self
            .storage
            .row_store()
            .insert("corpus_index_configuration", values)
        {
            // Another opener may have won the singleton insert. Accept only
            // an identical binding; a different winner is a hard mismatch.
            if let Some(winner) = self.fingerprint()? {
                if winner == requested {
                    return Ok(());
                }
                return Err(CorpusKitError::InvalidConfiguration(format!(
                    "standalone database was concurrently bound to policy {winner}, but the \
                     caller requested {requested}"
                )));
            }
            return Err(CorpusKitError::StoreUnavailable(insert_error.to_string()));
        }
        Ok(())
    }
}
