//! Test-support: a forwarding `Storage` decorator that injects query faults
//! on demand.
//!
//! # Purpose
//!
//! Several GLK verbs perform a "fail-closed pre-read" before their main
//! operation: they query a specific table (e.g. `"drawers"` in `expunge`,
//! `"kg_facts"` in `withdraw_kg_fact`) and surface any error as a
//! `VerbError::UnderlyingEstateFailure`. Nothing currently tests the
//! thrown-error branch because the in-memory backend never throws.
//!
//! `FaultCell`, `FaultingRowStore`, and `FaultingStorage` together provide a
//! minimal seam: arm the cell for a target table, call the verb, and the
//! `query` for that table returns the injected `StorageError`. Disarm to
//! restore normal behaviour and verify the row survived.
//!
//! # Usage
//!
//! ```ignore
//! let storage = Arc::new(InMemoryStorage::with_estate(uuid::Uuid::new_v4()));
//! let cell = FaultCell::for_table("drawers");
//! let faulting = Arc::new(FaultingStorage::new(
//!     storage.clone() as Arc<dyn Storage>,
//!     cell.clone(),
//! ));
//! // Open the estate through the faulting wrapper.
//! let store = InMemoryDrawerStore::with_dyn_storage(
//!     faulting as Arc<dyn Storage>, NOW, None,
//! ).unwrap();
//! let mut coord = EstateCoordinator::new();
//! let handle = coord.open(Arc::new(store), owner, 0, 100).unwrap();
//! // Seed a row, arm the fault, call the verb, assert the error, disarm.
//! cell.arm(StorageError::BackendUnavailable { reason: "INJECTED".into() });
//! let err = coord.expunge(&handle, &row_id, "op", true, NOW).unwrap_err();
//! cell.disarm();
//! ```
//!
//! # Transaction limit
//!
//! `transaction` forwards to the inner storage unchanged: the closure receives
//! the inner transaction's row store, so queries inside a transaction are
//! unfaulted. The current tests are unaffected because both pre-reads run
//! before the transaction opens.

use crate::error::{StorageError, StorageResult};
use crate::observer::StorageObserver;
use crate::predicate::{OrderClause, StoragePredicate};
use crate::row_store::RowStore;
use crate::schema::SchemaDeclaration;
use crate::storage::{
    IsolationLevel, SchemaKitRenameOutcome, Storage, StorageTransaction,
};
use crate::types::{RowHandle, StorageRow, TypedValue};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

// ── FaultCell ─────────────────────────────────────────────────────────────

/// Shared state controlling a single table-level query fault.
///
/// `FaultCell` is `Clone`able; every clone shares the same `Arc<Mutex<...>>`
/// so the test and the `FaultingStorage` both observe the arm/disarm calls.
#[derive(Clone)]
pub struct FaultCell {
    inner: Arc<Mutex<FaultState>>,
}

struct FaultState {
    target: String,
    error: Option<StorageError>,
}

impl FaultCell {
    /// Create a disarmed cell targeting `table`.
    ///
    /// Pass a clone of this cell to `FaultingStorage::new` and hold the
    /// original in the test to arm/disarm.
    pub fn for_table(table: impl Into<String>) -> Self {
        FaultCell {
            inner: Arc::new(Mutex::new(FaultState {
                target: table.into(),
                error: None,
            })),
        }
    }

    /// Arm the cell: subsequent `query` calls for the target table return
    /// `Err(error)` instead of querying the backend.
    pub fn arm(&self, error: StorageError) {
        self.inner.lock().unwrap().error = Some(error);
    }

    /// Disarm the cell: subsequent `query` calls forward normally.
    pub fn disarm(&self) {
        self.inner.lock().unwrap().error = None;
    }

    /// If the cell is armed and `table` matches the target, returns a clone
    /// of the stored error. Returns `None` to signal "forward normally".
    pub fn try_fire(&self, table: &str) -> Option<StorageError> {
        let state = self.inner.lock().unwrap();
        if table != state.target {
            return None;
        }
        state.error.clone()
    }
}

// ── FaultingRowStore ──────────────────────────────────────────────────────

/// A forwarding `RowStore` that injects a fault into `query` for the target
/// table while armed.
///
/// All write operations and count are forwarded unchanged.
pub struct FaultingRowStore {
    inner: Arc<dyn RowStore>,
    cell: FaultCell,
}

impl FaultingRowStore {
    fn new(inner: Arc<dyn RowStore>, cell: FaultCell) -> Self {
        FaultingRowStore { inner, cell }
    }
}

impl RowStore for FaultingRowStore {
    fn insert(
        &self,
        table: &str,
        values: BTreeMap<String, TypedValue>,
    ) -> StorageResult<RowHandle> {
        self.inner.insert(table, values)
    }

    fn upsert(
        &self,
        table: &str,
        values: BTreeMap<String, TypedValue>,
        conflict_columns: &[String],
    ) -> StorageResult<RowHandle> {
        self.inner.upsert(table, values, conflict_columns)
    }

    fn update(
        &self,
        table: &str,
        values: BTreeMap<String, TypedValue>,
        predicate: &StoragePredicate,
    ) -> StorageResult<usize> {
        self.inner.update(table, values, predicate)
    }

    fn delete(&self, table: &str, predicate: &StoragePredicate) -> StorageResult<usize> {
        self.inner.delete(table, predicate)
    }

    fn query(
        &self,
        table: &str,
        predicate: Option<&StoragePredicate>,
        order_by: &[OrderClause],
        limit: Option<usize>,
        offset: Option<usize>,
    ) -> StorageResult<Vec<StorageRow>> {
        // Intercept for the armed table; forward every other table.
        if let Some(err) = self.cell.try_fire(table) {
            return Err(err);
        }
        self.inner.query(table, predicate, order_by, limit, offset)
    }

    fn count(&self, table: &str, predicate: Option<&StoragePredicate>) -> StorageResult<usize> {
        self.inner.count(table, predicate)
    }
}

// ── FaultingStorage ───────────────────────────────────────────────────────

/// A forwarding `Storage` decorator that injects a query fault on demand.
///
/// Every method is forwarded to the wrapped backend. The sole exception is
/// `row_store()`, which returns a `FaultingRowStore` that intercepts `query`
/// calls for the armed table.
pub struct FaultingStorage {
    inner: Arc<dyn Storage>,
    cell: FaultCell,
}

impl FaultingStorage {
    /// Wrap `inner` with a fault cell targeting a single table.
    ///
    /// - `inner`: The real storage backend (e.g. `Arc<InMemoryStorage>`).
    /// - `cell`: A `FaultCell` the caller uses to arm/disarm the fault.
    ///   `FaultingStorage` clones the cell; arm/disarm through the same
    ///   `FaultCell` instance the test holds.
    pub fn new(inner: Arc<dyn Storage>, cell: FaultCell) -> Self {
        FaultingStorage { inner, cell }
    }
}

impl Storage for FaultingStorage {
    fn configuration(&self) -> &crate::storage::EstateConfiguration {
        self.inner.configuration()
    }

    /// Returns a `FaultingRowStore` that intercepts `query` for the armed
    /// table. Writes and queries for other tables pass through unchanged.
    fn row_store(&self) -> Arc<dyn RowStore> {
        Arc::new(FaultingRowStore::new(self.inner.row_store(), self.cell.clone()))
    }

    fn blob_store(&self) -> Arc<dyn crate::blob_store::BlobStore> {
        self.inner.blob_store()
    }

    fn audit_log(&self) -> Arc<dyn crate::audit_log::AuditLog> {
        self.inner.audit_log()
    }

    fn observer(&self) -> Arc<dyn StorageObserver> {
        self.inner.observer()
    }

    fn open(&self, schema: &SchemaDeclaration) -> StorageResult<()> {
        self.inner.open(schema)
    }

    fn close(&self) -> StorageResult<()> {
        self.inner.close()
    }

    fn current_schema_version(&self) -> StorageResult<i32> {
        self.inner.current_schema_version()
    }

    fn current_schema_version_for(&self, kit_id: &str) -> StorageResult<i32> {
        self.inner.current_schema_version_for(kit_id)
    }

    fn rename_schema_kit(
        &self,
        old_kit_id: &str,
        new_kit_id: &str,
    ) -> StorageResult<SchemaKitRenameOutcome> {
        self.inner.rename_schema_kit(old_kit_id, new_kit_id)
    }

    fn migrate(&self, schema: &SchemaDeclaration) -> StorageResult<()> {
        self.inner.migrate(schema)
    }

    fn transaction(
        &self,
        isolation: IsolationLevel,
        block: &mut dyn FnMut(&dyn StorageTransaction) -> StorageResult<()>,
    ) -> StorageResult<()> {
        self.inner.transaction(isolation, block)
    }
}
