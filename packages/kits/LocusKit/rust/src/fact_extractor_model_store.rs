use crate::drawer_operational::DrawerFeatureFlags;
use crate::error::LocusKitError;
use persistence_kit::predicate::{OrderClause, OrderDirection, StoragePredicate};
use persistence_kit::types::{Column, TypedValue};
use persistence_kit::{Storage, StorageRow};
use std::collections::BTreeMap;
use std::sync::Arc;

const T_MODELS: &str = "fact_extractor_models";
const T_DRAWERS: &str = "drawers";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FactExtractorModelRow {
    pub recipe_id: String,
    pub provider_id: String,
    pub model_id: String,
    pub model_version: String,
    pub schema_version: String,
    pub extractor_kind: String,
    pub maximum_input_characters: i64,
    pub maximum_facts_per_source: i64,
    pub is_active: bool,
}

pub struct FactExtractorModelStore {
    storage: Arc<dyn Storage>,
}

impl FactExtractorModelStore {
    pub fn new(storage: Arc<dyn Storage>) -> Self {
        Self { storage }
    }

    pub fn active(&self) -> Result<Option<FactExtractorModelRow>, LocusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                T_MODELS,
                Some(&StoragePredicate::Eq(
                    Column::new(T_MODELS, "is_active"),
                    TypedValue::Int(1),
                )),
                &[OrderClause::new(
                    Column::new(T_MODELS, "recipe_id"),
                    OrderDirection::Ascending,
                )],
                Some(1),
                None,
            )
            .map_err(map_err)?;
        rows.first().map(row_from).transpose()
    }

    pub fn all(&self) -> Result<Vec<FactExtractorModelRow>, LocusKitError> {
        self.storage
            .row_store()
            .query(
                T_MODELS,
                None,
                &[OrderClause::new(
                    Column::new(T_MODELS, "recipe_id"),
                    OrderDirection::Ascending,
                )],
                None,
                None,
            )
            .map_err(map_err)?
            .iter()
            .map(row_from)
            .collect()
    }

    pub fn upsert(&self, row: &FactExtractorModelRow) -> Result<(), LocusKitError> {
        validate(row)?;
        let mut values = BTreeMap::new();
        values.insert("recipe_id".into(), TypedValue::Text(row.recipe_id.clone()));
        values.insert(
            "provider_id".into(),
            TypedValue::Text(row.provider_id.clone()),
        );
        values.insert("model_id".into(), TypedValue::Text(row.model_id.clone()));
        values.insert(
            "model_version".into(),
            TypedValue::Text(row.model_version.clone()),
        );
        values.insert(
            "schema_version".into(),
            TypedValue::Text(row.schema_version.clone()),
        );
        values.insert(
            "extractor_kind".into(),
            TypedValue::Text(row.extractor_kind.clone()),
        );
        values.insert(
            "maximum_input_characters".into(),
            TypedValue::Int(row.maximum_input_characters),
        );
        values.insert(
            "maximum_facts_per_source".into(),
            TypedValue::Int(row.maximum_facts_per_source),
        );
        values.insert(
            "is_active".into(),
            TypedValue::Int(if row.is_active { 1 } else { 0 }),
        );
        values.insert("ext".into(), TypedValue::Null);
        self.storage
            .row_store()
            .upsert(T_MODELS, values, &["recipe_id".into()])
            .map_err(map_err)?;
        Ok(())
    }

    pub fn activate(&self, recipe_id: &str) -> Result<usize, LocusKitError> {
        let store = self.storage.row_store();
        let target_pred = StoragePredicate::Eq(
            Column::new(T_MODELS, "recipe_id"),
            TypedValue::Text(recipe_id.to_string()),
        );
        if store
            .query_projected(
                T_MODELS,
                &["recipe_id"],
                Some(&target_pred),
                &[],
                Some(1),
                None,
            )
            .map_err(map_err)?
            .is_empty()
        {
            return Err(LocusKitError::InvalidContent(format!(
                "fact_extractor_models has no row for recipe_id {recipe_id}"
            )));
        }
        store.begin_transaction().map_err(map_err)?;
        let result = (|| {
            let mut off = BTreeMap::new();
            off.insert("is_active".into(), TypedValue::Int(0));
            store
                .update(
                    T_MODELS,
                    off,
                    &StoragePredicate::Eq(Column::new(T_MODELS, "is_active"), TypedValue::Int(1)),
                )
                .map_err(map_err)?;
            let mut on = BTreeMap::new();
            on.insert("is_active".into(), TypedValue::Int(1));
            store.update(T_MODELS, on, &target_pred).map_err(map_err)?;

            let carriers = store
                .query_projected(
                    T_DRAWERS,
                    &["id", "operationalBitmap"],
                    Some(&StoragePredicate::BitmaskAll {
                        column: Column::new(T_DRAWERS, "operationalBitmap"),
                        mask: DrawerFeatureFlags::FACTS_EXTRACTED,
                    }),
                    &[],
                    None,
                    None,
                )
                .map_err(map_err)?;
            let mut cleared = 0;
            for carrier in carriers {
                let Some(TypedValue::Text(id)) = carrier.get("id") else {
                    continue;
                };
                let current = match carrier.get("operationalBitmap") {
                    Some(TypedValue::Bitmap(value)) | Some(TypedValue::Int(value)) => *value,
                    _ => 0,
                };
                let mut values = BTreeMap::new();
                values.insert(
                    "operationalBitmap".into(),
                    TypedValue::Bitmap(current & !DrawerFeatureFlags::FACTS_EXTRACTED),
                );
                cleared += store
                    .update(
                        T_DRAWERS,
                        values,
                        &StoragePredicate::Eq(
                            Column::new(T_DRAWERS, "id"),
                            TypedValue::Text(id.clone()),
                        ),
                    )
                    .map_err(map_err)?;
            }
            Ok(cleared)
        })();
        match result {
            Ok(count) => {
                store.commit_transaction().map_err(map_err)?;
                Ok(count)
            }
            Err(error) => {
                let _ = store.rollback_transaction();
                Err(error)
            }
        }
    }
}

fn validate(row: &FactExtractorModelRow) -> Result<(), LocusKitError> {
    if row.recipe_id.is_empty()
        || row.provider_id.is_empty()
        || row.model_id.is_empty()
        || row.model_version.is_empty()
        || row.schema_version.is_empty()
        || row.extractor_kind.is_empty()
        || row.maximum_input_characters <= 0
        || row.maximum_facts_per_source <= 0
    {
        Err(LocusKitError::InvalidContent(
            "invalid FactExtractorModelRow".into(),
        ))
    } else {
        Ok(())
    }
}

fn row_from(row: &StorageRow) -> Result<FactExtractorModelRow, LocusKitError> {
    let text = |key: &str| match row.get(key) {
        Some(TypedValue::Text(value)) => Ok(value.clone()),
        _ => Err(LocusKitError::CorruptStoredValue {
            table: T_MODELS.into(),
            column: key.into(),
            stored_text: "(null)".into(),
        }),
    };
    let int = |key: &str| match row.get(key) {
        Some(TypedValue::Int(value)) => Ok(*value),
        _ => Err(LocusKitError::CorruptStoredValue {
            table: T_MODELS.into(),
            column: key.into(),
            stored_text: "(null)".into(),
        }),
    };
    Ok(FactExtractorModelRow {
        recipe_id: text("recipe_id")?,
        provider_id: text("provider_id")?,
        model_id: text("model_id")?,
        model_version: text("model_version")?,
        schema_version: text("schema_version")?,
        extractor_kind: text("extractor_kind")?,
        maximum_input_characters: int("maximum_input_characters")?,
        maximum_facts_per_source: int("maximum_facts_per_source")?,
        is_active: int("is_active")? != 0,
    })
}

fn map_err(error: persistence_kit::StorageError) -> LocusKitError {
    LocusKitError::DatabaseUnavailable(error.to_string())
}
