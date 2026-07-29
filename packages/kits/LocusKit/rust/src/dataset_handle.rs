//! Dataset handle as first-class drawer (MX-TAB-4).
//!
//! The handle is an ordinary drawer with `content_kind() == ContentKind::Dataset`.
//! Its content field stores `DatasetHandleContent` JSON.
//!
//! The creation seam (`capture_dataset_handle`) is the ONLY authorised path —
//! the FDC classifier (`run_n_fdc`) is barred from emitting `ContentKind::Dataset`
//! and skips dataset-kind drawers during reclassification.
//!
//! ## Sensitivity floor invariant (v1)
//!
//! Rows appended to the backing dataset table are expected to carry sensitivity
//! at or below the handle drawer's sensitivity tier. This is an operator
//! convention in v1 — no per-row enforcement exists yet. MX-TAB-5 will add
//! column-level row sensitivity gating.
//!
//! ## JSON key convention
//!
//! `DatasetHandleContent` and `DatasetColumnSummary` use
//! `#[serde(rename_all = "camelCase")]` to match the Swift Codable defaults
//! so both legs produce byte-identical JSON keys. All six fields are present
//! in the schema now; the reserved MX-TAB-5 fields (`tableSignature`,
//! `columnSignatures`) are always `None` in v1.

use crate::drawer::Drawer;
use crate::error::LocusKitError;
use crate::estate::Estate;
use persistence_kit::predicate::StoragePredicate;
use persistence_kit::types::{Column, TypedValue};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use uuid::Uuid;

// MARK: - DatasetColumnSummary

/// Schema summary for one column in a dataset handle.
///
/// Stored inside `DatasetHandleContent.columns`. The `dataType` string
/// matches the backend DDL type supplied at `DatasetStore::create_dataset`
/// time (e.g. "TEXT", "INTEGER", "REAL"). Case and whitespace are
/// preserved verbatim; no normalisation is applied by the handle layer.
///
/// Mirrors Swift `DatasetColumnSummary` in `DatasetHandle.swift`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DatasetColumnSummary {
    /// Column name. Validated via `validate_dataset_column_identifier` at
    /// dataset creation time; this value is already clean when stored here.
    pub name: String,

    /// Backend DDL type string (e.g. "TEXT", "INTEGER", "REAL"). Case and
    /// whitespace are preserved verbatim from the schema declaration.
    pub data_type: String,
}

// MARK: - DatasetHandleContent

/// JSON payload stored in `Drawer.content` for drawers with
/// `content_kind() == ContentKind::Dataset`.
///
/// `rename_all = "camelCase"` matches the Swift Codable defaults so both
/// legs produce byte-identical JSON field names.
///
/// Reserved fields (MX-TAB-5): `table_signature` and `column_signatures`
/// are present in the schema now so MX-TAB-5 can populate them without a
/// content-field migration. In v1 (MX-TAB-4) they are always `None`.
///
/// Mirrors Swift `DatasetHandleContent` in `DatasetHandle.swift`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DatasetHandleContent {
    /// UUID of the backing dataset table in the `DatasetStore`.
    /// Used by the erase cascade in `coordinator::expunge` to call
    /// `DatasetStore::drop_dataset(id)` when the handle is erased.
    pub dataset_id: Uuid,

    /// Column schema summary at handle-creation time. Informational —
    /// the authoritative schema lives in the `DatasetStore` itself.
    pub columns: Vec<DatasetColumnSummary>,

    /// Row count at handle-creation time. Informational; may drift as
    /// rows are appended via `DatasetStore::append_rows`.
    pub row_count: i64,

    /// Human-readable description of the dataset's origin (e.g. CSV
    /// filename, API endpoint, tool invocation summary).
    pub source_description: String,

    // --- MX-TAB-5 reserved signature fields ---

    /// Reserved for MX-TAB-5: dataset-level Merkle signature string.
    /// Always `None` in v1 (MX-TAB-4).
    pub table_signature: Option<String>,

    /// Reserved for MX-TAB-5: per-column content signatures.
    /// Keyed by column name. Always `None` in v1 (MX-TAB-4).
    pub column_signatures: Option<std::collections::HashMap<String, String>>,
}

impl DatasetHandleContent {
    /// Encode to a JSON string for storage in `Drawer.content`.
    ///
    /// Returns an error string (not a typed error) so callers can wrap it
    /// as `LocusKitError::InvalidContent` if needed.
    pub fn encode(&self) -> Result<String, String> {
        serde_json::to_string(self)
            .map_err(|e| format!("DatasetHandleContent: JSON encode failed: {}", e))
    }

    /// Decode from the JSON string stored in `Drawer.content`.
    ///
    /// Returns an error string so callers can wrap it as
    /// `LocusKitError::InvalidContent` if needed.
    pub fn decode(json: &str) -> Result<DatasetHandleContent, String> {
        serde_json::from_str(json)
            .map_err(|e| format!("DatasetHandleContent: JSON decode failed: {}", e))
    }
}

// MARK: - Embedding model sentinel

/// Sentinel `embedding_model_id` for dataset handle drawers.
///
/// Dataset handles carry no vector embedding — there is no content blob to
/// embed. The sentinel satisfies `DrawerStore::add_drawer`'s non-empty
/// validation while making the intent explicit. The VectorKit encode pipeline
/// skips drawers whose model ID does not match a registered model.
///
/// Mirrors Swift `datasetHandleEmbeddingModelID` in `DatasetHandle.swift`.
pub const DATASET_HANDLE_EMBEDDING_MODEL_ID: &str = "dataset-handle";

// ---------------------------------------------------------------------------
// Estate extension — dataset handle signature patch (MX-TAB-5)
// ---------------------------------------------------------------------------

/// Drawers table name, local to this module (matches DrawerStoreCore constant).
const T_DRAWERS: &str = "drawers";

impl Estate {
    /// Overwrite the `content` column of a dataset handle drawer with a new
    /// JSON string.
    ///
    /// Used by `patch_dataset_handle_signatures` to persist MX-TAB-5 table and
    /// column signatures into the stored `DatasetHandleContent` JSON without
    /// re-running `capture_dataset_handle`.
    ///
    /// No audit event is appended; no supersession cascade fires. Signature
    /// computation is a deterministic annotation — writing the same content
    /// twice produces the same JSON, so the operation is idempotent.
    ///
    /// Mirrors Swift `DrawerStore.updateDatasetContent(drawerId:content:)` in
    /// `LocusKit/Sources/LocusKit/DrawerStore.swift`.
    ///
    /// - Returns `()` on success.
    /// - Errors:
    ///   - `LocusKitError::DatabaseUnavailable` when `storage()` returns `None`.
    ///   - `LocusKitError::DrawerNotFound` when `drawer_id` does not exist
    ///     (update affected zero rows).
    ///   - `LocusKitError::DatabaseUnavailable` wrapping a `StorageResult` error
    ///     from the row_store `update` call.
    pub fn patch_dataset_handle_content(
        &self,
        drawer_id: &str,
        content: &str,
    ) -> Result<(), LocusKitError> {
        let storage = self.store.storage().ok_or_else(|| {
            LocusKitError::DatabaseUnavailable(
                "patch_dataset_handle_content: storage not available".into(),
            )
        })?;
        let row_store = storage.row_store();
        let pred = StoragePredicate::Eq(
            Column::new(T_DRAWERS, "id"),
            TypedValue::Text(drawer_id.to_string()),
        );
        let mut values = BTreeMap::new();
        values.insert("content".to_string(), TypedValue::Text(content.to_string()));
        // Content changed in place → the distilled representation (a view of
        // the OLD content) is stale. NULL-on-edit in the same statement is
        // the SPEC §7.3 regeneration trigger. Mirrors Swift
        // updateDatasetContent.
        crate::drawer_store_inmemory::insert_cleared_representation(&mut values);
        let count = row_store
            .update(T_DRAWERS, values, &pred)
            .map_err(|e| LocusKitError::DatabaseUnavailable(e.to_string()))?;
        if count == 0 {
            return Err(LocusKitError::DrawerNotFound {
                id: drawer_id.to_string(),
            });
        }
        Ok(())
    }

    /// Write computed table and column signatures into an existing dataset
    /// handle drawer without re-running `capture_dataset_handle`.
    ///
    /// Decodes the current `DatasetHandleContent` from `drawer_id`, replaces
    /// `table_signature` and `column_signatures` with the supplied values,
    /// re-encodes to JSON, and writes via `patch_dataset_handle_content`.
    ///
    /// Mirrors Swift `Estate.patchDatasetHandleSignatures(rowID:tableSignature:
    /// columnSignatures:now:)` in `LocusKit/Sources/LocusKit/DatasetHandle.swift`.
    ///
    /// - Returns the refreshed `Drawer` read back after the write.
    /// - Errors:
    ///   - `LocusKitError::DrawerNotFound` when `drawer_id` does not exist.
    ///   - `LocusKitError::InvalidContent` when the stored JSON fails to decode
    ///     as `DatasetHandleContent`.
    ///   - `LocusKitError::DatabaseUnavailable` on storage failures.
    pub fn patch_dataset_handle_signatures(
        &self,
        drawer_id: &str,
        table_signature: &str,
        column_signatures: std::collections::HashMap<String, String>,
    ) -> Result<Drawer, LocusKitError> {
        // Read the current drawer to confirm existence and preserve other fields.
        let existing = self
            .store
            .get_drawer(drawer_id)?
            .ok_or_else(|| LocusKitError::DrawerNotFound {
                id: drawer_id.to_string(),
            })?;
        let mut current = DatasetHandleContent::decode(&existing.content)
            .map_err(LocusKitError::InvalidContent)?;

        // Replace the signature fields; all other fields (dataset_id, columns,
        // row_count, source_description) are preserved verbatim.
        current.table_signature = Some(table_signature.to_string());
        current.column_signatures = Some(column_signatures);

        let new_json = current
            .encode()
            .map_err(LocusKitError::InvalidContent)?;
        self.patch_dataset_handle_content(drawer_id, &new_json)?;

        // Read back the drawer so the caller has the current storage state.
        self.store
            .get_drawer(drawer_id)?
            .ok_or_else(|| LocusKitError::DrawerNotFound {
                id: drawer_id.to_string(),
            })
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dataset_column_summary_roundtrip() {
        let col = DatasetColumnSummary {
            name: "user_id".to_string(),
            data_type: "INTEGER".to_string(),
        };
        let json = serde_json::to_string(&col).unwrap();
        // Confirm camelCase keys are used in JSON output.
        assert!(json.contains("\"name\""), "expected 'name' key: {}", json);
        assert!(json.contains("\"dataType\""), "expected 'dataType' key: {}", json);
        let decoded: DatasetColumnSummary = serde_json::from_str(&json).unwrap();
        assert_eq!(col, decoded);
    }

    #[test]
    fn dataset_handle_content_encode_decode_roundtrip() {
        let id = Uuid::new_v4();
        let content = DatasetHandleContent {
            dataset_id: id,
            columns: vec![
                DatasetColumnSummary {
                    name: "col_a".to_string(),
                    data_type: "TEXT".to_string(),
                },
                DatasetColumnSummary {
                    name: "col_b".to_string(),
                    data_type: "REAL".to_string(),
                },
            ],
            row_count: 42,
            source_description: "test fixture".to_string(),
            table_signature: None,
            column_signatures: None,
        };
        let json = content.encode().unwrap();
        // Confirm camelCase keys in the top-level struct.
        assert!(json.contains("\"datasetId\""), "expected 'datasetId' key");
        assert!(json.contains("\"rowCount\""), "expected 'rowCount' key");
        assert!(json.contains("\"sourceDescription\""), "expected 'sourceDescription' key");
        let decoded = DatasetHandleContent::decode(&json).unwrap();
        assert_eq!(content, decoded);
    }

    #[test]
    fn dataset_handle_content_json_keys_match_swift() {
        // Verify exact key names so Swift/Rust JSON is byte-compatible on the
        // wire. Swift Codable produces "datasetId", "columns", "rowCount",
        // "sourceDescription", "tableSignature", "columnSignatures".
        let id = Uuid::parse_str("550e8400-e29b-41d4-a716-446655440000").unwrap();
        let content = DatasetHandleContent {
            dataset_id: id,
            columns: vec![],
            row_count: 0,
            source_description: "".to_string(),
            table_signature: None,
            column_signatures: None,
        };
        let json = content.encode().unwrap();
        let expected_keys = [
            "\"datasetId\"",
            "\"columns\"",
            "\"rowCount\"",
            "\"sourceDescription\"",
        ];
        for key in &expected_keys {
            assert!(json.contains(key), "missing key {} in: {}", key, json);
        }
    }

    #[test]
    fn sentinel_embedding_model_id_is_nonempty() {
        // DrawerStore validates non-empty; confirm the sentinel passes.
        assert!(!DATASET_HANDLE_EMBEDDING_MODEL_ID.is_empty());
        assert_eq!(DATASET_HANDLE_EMBEDDING_MODEL_ID, "dataset-handle");
    }
}
