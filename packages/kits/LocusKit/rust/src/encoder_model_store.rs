//! The span-encoder registry (ENCODER_RERANK_CONTRACT §2, LocusKit schema
//! v19): one `encoder_models` row per shipped model per device, exactly one
//! row `is_active = 1` at a time. The active row is what the recall stage
//! and the span-encode duty read; this store is the only writer.
//!
//! Activation is the one operation with estate-wide reach: switching the
//! active model clears bit 27 (`SPAN_INDEXED`) on every drawer so the duty
//! re-encodes the whole estate under the new model. The rows of the old
//! model stay in `vectors` until `mootx01 upgrade`'s reclaim removes them;
//! they are never read because the recall stage queries by the ACTIVE
//! model id.
//!
//! Bit 27 is cleared row by row inside one transaction: persistence-kit's
//! RowStore has no bitwise UPDATE expression (an UPDATE takes literal
//! values), and the runtime path never issues backend SQL. Only rows that
//! carry the bit are touched, so a fresh estate pays one projected SELECT.
//!
//! Swift twin: Sources/LocusKit/EncoderModelStore.swift.

use crate::drawer_operational::DrawerFeatureFlags;
use crate::error::LocusKitError;
use persistence_kit::predicate::{OrderClause, OrderDirection, StoragePredicate};
use persistence_kit::types::{Column, TypedValue};
use persistence_kit::{Storage, StorageRow};
use std::collections::BTreeMap;
use std::sync::Arc;

const T_ENCODER_MODELS: &str = "encoder_models";
const T_DRAWERS: &str = "drawers";

/// Pooling strategy an encoder applies over its token states. Mirrors
/// Swift `Pooling`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Pooling {
    /// Mean over the token states (all-MiniLM-L6-v2, bge-small).
    Mean,
    /// The [CLS] token state.
    Cls,
}

impl Pooling {
    /// The stored text form ("mean" | "cls").
    pub fn as_str(self) -> &'static str {
        match self {
            Pooling::Mean => "mean",
            Pooling::Cls => "cls",
        }
    }

    /// Parse the stored text form; `None` for anything else.
    pub fn parse(text: &str) -> Option<Self> {
        match text {
            "mean" => Some(Pooling::Mean),
            "cls" => Some(Pooling::Cls),
            _ => None,
        }
    }
}

/// One `encoder_models` row (ENCODER_RERANK_CONTRACT §2, §7). The registry
/// row IS the encoder contract: everything the factory needs to load the
/// model and everything the spanner needs to cut spans lives here, so the
/// recall stage, the duty and the upgrade read one row and agree.
/// `model_id` is `<model>-w<window_words>`; the span window is part of the
/// identity because a different window is a different index. Mirrors Swift
/// `EncoderModelRow`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EncoderModelRow {
    /// `<model>-w<window_words>`, e.g. `minilm-l6-v2-w60`. Primary key.
    pub model_id: String,
    /// The weights revision; a weights change is a new version and a re-index.
    pub model_version: String,
    /// Embedding dimension (384 for all-MiniLM-L6-v2).
    pub dim: i64,
    /// Prefix applied to queries before encoding; "" when the card has none.
    pub query_prefix: String,
    /// Prefix applied to documents (spans) before encoding; "" when none.
    pub doc_prefix: String,
    /// Pooling over token states.
    pub pooling: Pooling,
    /// sha256 hex of the vendored vocab file; the factory refuses a model
    /// whose vocab does not hash to this.
    pub tokenizer_hash: String,
    /// Span window in words.
    pub window_words: i64,
    /// Overlap divisor: 2 = half overlap (step = window / 2).
    pub overlap_divisor: i64,
    /// Cap on spans per drawer (32); the spanner widens the step to fit.
    pub max_spans: i64,
    /// The model's maximum sequence length in tokens.
    pub max_sequence: i64,
    /// Whether this row is the configured model on this device. Decoded
    /// from the INTEGER `is_active` column (no bool field on the row; this
    /// is the value type the row decodes into).
    pub is_active: bool,
}

/// Read/write surface over `encoder_models`. Mirrors Swift `EncoderModelStore`.
pub struct EncoderModelStore {
    storage: Arc<dyn Storage>,
}

impl EncoderModelStore {
    /// Wrap an already-opened Storage (the LocusKit schema is opened by the
    /// drawer store; this type issues RowStore operations only).
    pub fn new(storage: Arc<dyn Storage>) -> Self {
        EncoderModelStore { storage }
    }

    /// The active registry row, or `None` when no model is registered or
    /// none is active (lexical-only recall).
    pub fn active(&self) -> Result<Option<EncoderModelRow>, LocusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                T_ENCODER_MODELS,
                Some(&StoragePredicate::Eq(
                    Column::new(T_ENCODER_MODELS, "is_active"),
                    TypedValue::Int(1),
                )),
                &[OrderClause::new(
                    Column::new(T_ENCODER_MODELS, "model_id"),
                    OrderDirection::Ascending,
                )],
                Some(1),
                None,
            )
            .map_err(map_err)?;
        rows.first().map(spec_from_row).transpose()
    }

    /// Every registry row, ordered by model id.
    pub fn all(&self) -> Result<Vec<EncoderModelRow>, LocusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                T_ENCODER_MODELS,
                None,
                &[OrderClause::new(
                    Column::new(T_ENCODER_MODELS, "model_id"),
                    OrderDirection::Ascending,
                )],
                None,
                None,
            )
            .map_err(map_err)?;
        rows.iter().map(spec_from_row).collect()
    }

    /// Insert or replace one registry row keyed by `model_id`. `is_active`
    /// on the spec is written as given; use `activate` to switch the
    /// configured model, which is the path that also invalidates the span
    /// index. Validation: non-empty ids, positive dimensions and windows,
    /// `overlap_divisor >= 1`, `max_spans >= 1`.
    pub fn upsert(&self, spec: &EncoderModelRow) -> Result<(), LocusKitError> {
        validate(spec)?;
        let mut values = BTreeMap::new();
        values.insert("model_id".to_string(), TypedValue::Text(spec.model_id.clone()));
        values.insert("model_version".to_string(), TypedValue::Text(spec.model_version.clone()));
        values.insert("dim".to_string(), TypedValue::Int(spec.dim));
        values.insert("query_prefix".to_string(), TypedValue::Text(spec.query_prefix.clone()));
        values.insert("doc_prefix".to_string(), TypedValue::Text(spec.doc_prefix.clone()));
        values.insert("pooling".to_string(), TypedValue::Text(spec.pooling.as_str().to_string()));
        values.insert("tokenizer_hash".to_string(), TypedValue::Text(spec.tokenizer_hash.clone()));
        values.insert("window_words".to_string(), TypedValue::Int(spec.window_words));
        values.insert("overlap_divisor".to_string(), TypedValue::Int(spec.overlap_divisor));
        values.insert("max_spans".to_string(), TypedValue::Int(spec.max_spans));
        values.insert("max_sequence".to_string(), TypedValue::Int(spec.max_sequence));
        values.insert("is_active".to_string(), TypedValue::Int(if spec.is_active { 1 } else { 0 }));
        values.insert("ext".to_string(), TypedValue::Null);
        self.storage
            .row_store()
            .upsert(T_ENCODER_MODELS, values, &["model_id".to_string()])
            .map_err(map_err)?;
        Ok(())
    }

    /// Make `model_id` the one active row and clear bit 27 (`SPAN_INDEXED`)
    /// on every drawer that carries it, all in one transaction, so the
    /// span-encode duty re-encodes the estate under the new model.
    /// Idempotent: activating the already-active model still clears the bit
    /// (a forced re-encode), which is the safe direction. Returns the number
    /// of drawers whose bit 27 was cleared; `InvalidContent` when no row has
    /// `model_id`.
    pub fn activate(&self, model_id: &str) -> Result<usize, LocusKitError> {
        let row_store = self.storage.row_store();
        let target_pred = StoragePredicate::Eq(
            Column::new(T_ENCODER_MODELS, "model_id"),
            TypedValue::Text(model_id.to_string()),
        );
        let target = row_store
            .query_projected(T_ENCODER_MODELS, &["model_id"], Some(&target_pred), &[], Some(1), None)
            .map_err(map_err)?;
        if target.is_empty() {
            return Err(LocusKitError::InvalidContent(format!(
                "encoder_models has no row for model_id {model_id}"
            )));
        }
        row_store.begin_transaction().map_err(map_err)?;
        let result = (|| -> Result<usize, LocusKitError> {
            let mut off = BTreeMap::new();
            off.insert("is_active".to_string(), TypedValue::Int(0));
            row_store
                .update(
                    T_ENCODER_MODELS,
                    off,
                    &StoragePredicate::Eq(Column::new(T_ENCODER_MODELS, "is_active"), TypedValue::Int(1)),
                )
                .map_err(map_err)?;
            let mut on = BTreeMap::new();
            on.insert("is_active".to_string(), TypedValue::Int(1));
            row_store.update(T_ENCODER_MODELS, on, &target_pred).map_err(map_err)?;
            // Estate-wide bit 27 clear: projected read of the rows that carry
            // the bit, then one UPDATE per row with the literal cleared value
            // (RowStore has no bitwise UPDATE expression).
            let carriers = row_store
                .query_projected(
                    T_DRAWERS,
                    &["id", "operationalBitmap"],
                    Some(&StoragePredicate::BitmaskAll {
                        column: Column::new(T_DRAWERS, "operationalBitmap"),
                        mask: DrawerFeatureFlags::SPAN_INDEXED,
                    }),
                    &[],
                    None,
                    None,
                )
                .map_err(map_err)?;
            let mut cleared = 0usize;
            for row in &carriers {
                let id = match row.get("id") {
                    Some(TypedValue::Text(s)) => s.clone(),
                    _ => continue,
                };
                let current = match row.get("operationalBitmap") {
                    Some(TypedValue::Bitmap(b)) => *b,
                    Some(TypedValue::Int(i)) => *i,
                    _ => 0,
                };
                let mut values = BTreeMap::new();
                values.insert(
                    "operationalBitmap".to_string(),
                    TypedValue::Bitmap(current & !DrawerFeatureFlags::SPAN_INDEXED),
                );
                cleared += row_store
                    .update(
                        T_DRAWERS,
                        values,
                        &StoragePredicate::Eq(Column::new(T_DRAWERS, "id"), TypedValue::Text(id)),
                    )
                    .map_err(map_err)?;
            }
            Ok(cleared)
        })();
        match result {
            Ok(n) => {
                row_store.commit_transaction().map_err(map_err)?;
                Ok(n)
            }
            Err(e) => {
                let _ = row_store.rollback_transaction();
                Err(e)
            }
        }
    }
}

fn map_err(e: persistence_kit::StorageError) -> LocusKitError {
    LocusKitError::DatabaseUnavailable(e.to_string())
}

fn validate(spec: &EncoderModelRow) -> Result<(), LocusKitError> {
    let require = |ok: bool, what: &str| -> Result<(), LocusKitError> {
        if ok {
            Ok(())
        } else {
            Err(LocusKitError::InvalidContent(format!("EncoderModelRow: {what}")))
        }
    };
    require(!spec.model_id.is_empty(), "model_id must not be empty")?;
    require(!spec.model_version.is_empty(), "model_version must not be empty")?;
    require(spec.dim > 0, "dim must be positive")?;
    require(spec.window_words > 0, "window_words must be positive")?;
    require(spec.overlap_divisor >= 1, "overlap_divisor must be >= 1")?;
    require(spec.max_spans >= 1, "max_spans must be >= 1")?;
    require(spec.max_sequence > 0, "max_sequence must be positive")
}

fn spec_from_row(row: &StorageRow) -> Result<EncoderModelRow, LocusKitError> {
    let text = |key: &str| -> Result<String, LocusKitError> {
        match row.get(key) {
            Some(TypedValue::Text(s)) => Ok(s.clone()),
            _ => Err(LocusKitError::CorruptStoredValue {
                table: T_ENCODER_MODELS.to_string(),
                column: key.to_string(),
                stored_text: "(null)".to_string(),
            }),
        }
    };
    let int = |key: &str| -> Result<i64, LocusKitError> {
        match row.get(key) {
            Some(TypedValue::Int(v)) => Ok(*v),
            _ => Err(LocusKitError::CorruptStoredValue {
                table: T_ENCODER_MODELS.to_string(),
                column: key.to_string(),
                stored_text: "(null)".to_string(),
            }),
        }
    };
    let pooling_text = text("pooling")?;
    let pooling = Pooling::parse(&pooling_text).ok_or_else(|| LocusKitError::CorruptStoredValue {
        table: T_ENCODER_MODELS.to_string(),
        column: "pooling".to_string(),
        stored_text: pooling_text.clone(),
    })?;
    Ok(EncoderModelRow {
        model_id: text("model_id")?,
        model_version: text("model_version")?,
        dim: int("dim")?,
        query_prefix: text("query_prefix")?,
        doc_prefix: text("doc_prefix")?,
        pooling,
        tokenizer_hash: text("tokenizer_hash")?,
        window_words: int("window_words")?,
        overlap_divisor: int("overlap_divisor")?,
        max_spans: int("max_spans")?,
        max_sequence: int("max_sequence")?,
        is_active: int("is_active")? != 0,
    })
}
