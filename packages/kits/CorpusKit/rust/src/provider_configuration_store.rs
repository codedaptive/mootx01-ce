//! Last-written attestation for current-runtime provider reconciliation.
//! This is ordinary derived-index state, not historical estate migration state.

use crate::error::CorpusKitError;
use persistence_kit::{
    Column, ColumnDeclaration, SchemaDeclaration, Storage, StoragePredicate, TableDeclaration,
    TypedValue,
};
use std::collections::BTreeMap;
use std::sync::Arc;

pub struct CorpusProviderConfigurationStore {
    storage: Arc<dyn Storage>,
}

impl CorpusProviderConfigurationStore {
    pub fn schema_declaration() -> SchemaDeclaration {
        SchemaDeclaration::new(
            "CorpusKitProviderConfiguration",
            1,
            vec![TableDeclaration::new(
                "corpus_provider_configuration",
                vec![
                    ColumnDeclaration::int("singleton_id"),
                    ColumnDeclaration::text("generation_token"),
                    ColumnDeclaration::timestamp("updated_at"),
                ],
                vec!["singleton_id".to_string()],
            )],
        )
    }

    pub fn new(storage: Arc<dyn Storage>) -> Self {
        Self { storage }
    }

    pub fn generation_token(&self) -> Result<Option<String>, CorpusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                "corpus_provider_configuration",
                Some(&StoragePredicate::Eq(
                    Column::new("corpus_provider_configuration", "singleton_id"),
                    TypedValue::Int(1),
                )),
                &[],
                Some(1),
                None,
            )
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        Ok(rows
            .first()
            .and_then(|row| match row.get("generation_token") {
                Some(TypedValue::Text(token)) => Some(token.clone()),
                _ => None,
            }))
    }

    pub fn mark_current(&self, token: &str, now_millis: i64) -> Result<(), CorpusKitError> {
        let mut values = BTreeMap::new();
        values.insert("singleton_id".into(), TypedValue::Int(1));
        values.insert(
            "generation_token".into(),
            TypedValue::Text(token.to_string()),
        );
        values.insert("updated_at".into(), TypedValue::Timestamp(now_millis));
        self.storage
            .row_store()
            .upsert(
                "corpus_provider_configuration",
                values,
                &["singleton_id".to_string()],
            )
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        Ok(())
    }

    pub fn invalidate(&self) -> Result<(), CorpusKitError> {
        self.storage
            .row_store()
            .delete("corpus_provider_configuration", &StoragePredicate::IsTrue)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        Ok(())
    }
}
