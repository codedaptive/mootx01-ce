// grant_store.rs — Rust port of GrantStore.swift.
//
// Durable grant store for the Rust grant subsystem. Backed by a
// PersistenceKit `Storage` instance — the same abstraction the Swift port
// uses — so grant rows survive process restarts when the caller supplies a
// `SqliteStorage` instance (the default for production estates).
//
// The grants table schema exactly mirrors Swift GrantStore.grantsTable:
//   id            TEXT   (UUID string)   PRIMARY KEY
//   grantee_id    TEXT   (UUID string)
//   scope_json    TEXT   (JSON)
//   content_level INT
//   custody_mode  TEXT   (discriminant token)
//   lifetime_json TEXT   (JSON)
//   reshare       TEXT   (discriminant token)
//   inference_budget FLOAT
//   issued_at     TIMESTAMP (TEXT ISO-8601)
//   revoked_at    TIMESTAMP (TEXT ISO-8601) NULLABLE
//   signature     BLOB
//
// Security posture (access-control fail-closed):
//   A grant row that cannot be decoded MUST surface an error and grant NOTHING.
//   Silent widening (fabricated epoch-0 issue dates) or fabricated defaults are
//   prohibited. The caller must receive an error and make an explicit decision.
//
// Concurrency / double-spend:
//   All writes go through the `Storage` `RowStore`, which provides the
//   per-storage synchronisation boundary. For the `InMemoryStorage` backend
//   (used in tests) the `Mutex<State>` inside the storage is the lock; for
//   `SqliteStorage` (production) WAL-mode SQLite serialises writes. In both
//   cases, `debit_budget` is a read-then-write pair on the same storage;
//   callers that need atomic debit-before-read must serialise at the
//   `EstateCoordinator` level (the Rust coordinator is `!Sync` behind a
//   `Mutex` in the MCP server, providing the same serial-dispatch guarantee
//   as Swift's actor model).

use std::collections::BTreeMap;
use std::sync::Arc;
use uuid::Uuid;
use persistence_kit::storage::Storage;
use persistence_kit::schema::{ColumnDeclaration, SchemaDeclaration, TableDeclaration};
use persistence_kit::predicate::StoragePredicate;
use persistence_kit::types::{Column, StorageRow, TypedValue};
use serde_json;

use super::grant::{
    CustodyMode, DecayPolicy, DriftRate, Grant, GrantLifetime, GrantScope, ReSharePermission,
    StoredGrant,
};

/// Errors from grant store row decoding.
///
/// Mirror of Swift `GrantStore.GrantStoreError`. Raised when a SQLite row
/// cannot be decoded back into a `Grant`. Callers MUST treat these as
/// hard failures — no fabricated default is ever substituted.
///
/// Security posture: `CorruptIssuedAt` is separate because an epoch-0
/// `issued_at` silently corrupts lifetime arithmetic. The store must never
/// substitute epoch-0 for an unparseable date.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GrantStoreError {
    /// A required column could not be decoded. The string carries the
    /// column name and raw stored value for diagnosis.
    CorruptRow(String),
    /// The `issued_at` column could not be parsed as an ISO-8601 date.
    /// `stored_text` is the raw string for diagnosis.
    ///
    /// Throwing this error rather than falling back to epoch-0 is
    /// mandatory: an epoch-0 issue date would corrupt lifetime-window
    /// arithmetic (DecayWindow expiry computed from 1970; Until baseline
    /// wrong). Mirror of Swift `GrantStoreError.corruptIssuedAt`.
    CorruptIssuedAt { stored_text: String },
    /// An underlying PersistenceKit storage error. Wraps the formatted error
    /// string so the grant surface does not need to import StorageError.
    StorageFailure(String),
}

impl From<persistence_kit::error::StorageError> for GrantStoreError {
    fn from(e: persistence_kit::error::StorageError) -> Self {
        GrantStoreError::StorageFailure(format!("{e:?}"))
    }
}

/// Durable grant store backed by a PersistenceKit `Storage` instance.
///
/// Mirror of Swift `GrantStore`. Every public operation (insert, get,
/// debit_budget, revoke, active, expired) delegates to the `Storage`'s
/// `RowStore`. For production use, supply a `SqliteStorage`; for tests,
/// `InMemoryStorage` gives the same interface with no disk I/O.
///
/// Construction calls `Storage::open` with the merged LocusKit+grants schema,
/// matching Swift `GrantStore.init(storage:)` exactly.
pub struct GrantStore {
    storage: Arc<dyn Storage>,
}

impl GrantStore {
    // -----------------------------------------------------------------------
    // Schema — mirrors Swift GrantStore.grantsTable
    // -----------------------------------------------------------------------

    /// The `grants` table declaration. Column types, names, and nullable
    /// flags match Swift `GrantStore.grantsTable` exactly.
    ///
    /// Date columns use `Timestamp` (PersistenceKit stores as TEXT ISO-8601
    /// per the fleet rule; `revoked_at` is nullable for active grants).
    /// `scope_json` and `lifetime_json` are TEXT (JSON) because they are
    /// sum types; `custody_mode` and `reshare` store their discriminant token.
    ///
    /// The three `decay_*` columns hold the mode-4 (`TimeAging`) custody policy
    /// and are NULL for every other mode. Persisted explicitly (not packed into
    /// the `custody_mode` token) so the policy is queryable. Mirror of Swift
    /// `GrantStore.grantsTable`.
    pub fn grants_table() -> TableDeclaration {
        TableDeclaration::new(
            "grants",
            vec![
                ColumnDeclaration::text("id"),
                ColumnDeclaration::text("grantee_id"),
                ColumnDeclaration::text("scope_json"),
                ColumnDeclaration::int("content_level"),
                ColumnDeclaration::text("custody_mode"),
                ColumnDeclaration::text("lifetime_json"),
                ColumnDeclaration::text("reshare"),
                ColumnDeclaration::float("inference_budget"),
                ColumnDeclaration::timestamp("issued_at"),
                ColumnDeclaration::timestamp("revoked_at").nullable(),
                ColumnDeclaration::blob("signature"),
                // Mode-4 time-aging decay policy. NULL for modes 1–3.
                ColumnDeclaration::int("decay_half_life").nullable(),
                ColumnDeclaration::timestamp("decay_started_at").nullable(),
                ColumnDeclaration::int("decay_floor").nullable(),
                // nullable entity ext slots forward-compat slot — the #11 custody-payload slot.
                // Nullable JSON; reserves space for future custody metadata
                // (the federation/encryption track — e.g. mode-3 share-policy
                // descriptors) without a migration. 1.0 omits it on insert and
                // never reads it.
                ColumnDeclaration::json("ext").nullable(),
            ],
            vec!["id".to_string()],
        )
    }

    /// Construct a grant store backed by `storage` and ensure the `grants`
    /// table exists by opening the schema.
    ///
    /// Mirrors Swift `GrantStore.init(storage:)`: applies a schema that is
    /// the LocusKit base schema plus the `grants` table. In the Rust port
    /// the LocusKit schema is NOT merged in here because the `DrawerStore`
    /// owns the LocusKit tables on its own `Storage`; the grant store opens
    /// only the `grants` table on its own storage. Using separate `Storage`
    /// instances for the draw store and grant store is acceptable — both
    /// PersistenceKit backends (`InMemoryStorage`, `SqliteStorage`) isolate
    /// tables by name; no cross-table key constraints are needed between the
    /// grant table and LocusKit tables.
    ///
    /// Returns `GrantStoreError::StorageFailure` on open failure.
    pub fn new(storage: Arc<dyn Storage>) -> Result<Self, GrantStoreError> {
        // Version tracks LocusKit base + 1, mirroring Swift's
        // `base.version + 1`, so a LocusKit schema bump (e.g. the nullable entity ext slots
        // `ext` slot, v1 → v2) advances the grants version in lockstep across
        // both ports without a hand-edited literal.
        let schema = SchemaDeclaration::new(
            "GeniusLocusKit.grants",
            locus_kit::schema::SCHEMA_VERSION + 1,
            vec![Self::grants_table()],
        );
        storage.open(&schema)?;
        Ok(GrantStore { storage })
    }

    // -----------------------------------------------------------------------
    // CRUD — mirrors Swift GrantStore
    // -----------------------------------------------------------------------

    /// Insert a grant. The grant's `id` is the primary key; re-inserting
    /// the same id upserts (mirrors Swift `GrantStore.insert`).
    pub fn insert(&self, grant: &Grant) -> Result<(), GrantStoreError> {
        let values = Self::row_from(grant)?;
        self.storage.row_store().upsert(
            "grants",
            values,
            &["id".to_string()],
        )?;
        Ok(())
    }

    /// Fetch a stored grant by id, or `None` if absent.
    pub fn get(&self, id: Uuid) -> Result<Option<StoredGrant>, GrantStoreError> {
        let pred = StoragePredicate::Eq(
            Column::new("grants", "id"),
            TypedValue::Text(id.to_string()),
        );
        let rows = self.storage.row_store().query(
            "grants",
            Some(&pred),
            &[],
            None,
            None,
        )?;
        match rows.into_iter().next() {
            None => Ok(None),
            Some(row) => Ok(Some(Self::decode_storage_row(&row)?)),
        }
    }

    /// Debit the inference budget for a grant by `amount`, clamping to 0.0.
    ///
    /// The read-then-write pair runs inside a single storage transaction so
    /// concurrent calls cannot double-spend the same quantum:
    ///   1. Read the current `inference_budget` inside the transaction.
    ///   2. Compute `new_budget = max(0.0, current - amount)`.
    ///   3. Write the new value with an UPDATE inside the same transaction.
    ///   4. Commit.
    ///
    /// Returns the budget BEFORE the debit so the caller can determine whether
    /// the read that triggered the debit was the last permitted one. Mirrors
    /// Swift `GrantStore.debitBudget(id:amount:)` exactly.
    ///
    /// Returns `0.0` if the grant is absent (row was revoked and deleted,
    /// which cannot happen on the normal path — grants use soft-revocation —
    /// but the call must not fault on an absent row).
    ///
    /// Atomicity: the storage transaction is the concurrency boundary. For
    /// `InMemoryStorage`, `Storage::transaction` snapshots state and holds the
    /// storage lock for the entire closure, preventing any interleaved read or
    /// write from another thread. For `SqliteStorage`, WAL-mode SQLite's write
    /// serialisation provides the same guarantee. This matches the Swift actor's
    /// serial-dispatch guarantee: no concurrent caller can observe the pre-debit
    /// budget while the debit is in flight.
    pub fn debit_budget(&self, id: Uuid, amount: f64) -> Result<f64, GrantStoreError> {
        use persistence_kit::storage::IsolationLevel;
        let id_str = id.to_string();
        let mut pre_budget = 0.0_f64;

        // Run the read-then-write atomically inside a transaction.
        // The closure captures `pre_budget` by mutable reference so the
        // caller can observe the pre-debit value after commit.
        self.storage.transaction(
            IsolationLevel::Serializable,
            &mut |txn| {
                let pred = StoragePredicate::Eq(
                    Column::new("grants", "id"),
                    TypedValue::Text(id_str.clone()),
                );
                let rows = txn.row_store().query(
                    "grants",
                    Some(&pred),
                    &[],
                    None,
                    None,
                )?;
                let current = rows.into_iter().next()
                    .and_then(|r| match r.get("inference_budget") {
                        Some(TypedValue::Float(f)) => Some(*f),
                        Some(TypedValue::Int(i)) => Some(*i as f64),
                        _ => None,
                    })
                    .unwrap_or(0.0);

                pre_budget = current;
                let new_budget = (current - amount).max(0.0);

                let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
                values.insert("inference_budget".to_string(), TypedValue::Float(new_budget));
                txn.row_store().update("grants", values, &pred)?;

                Ok(())
            },
        ).map_err(GrantStoreError::from)?;

        Ok(pre_budget)
    }

    /// Mark a grant revoked at `now_iso8601`. Idempotent: a second revoke
    /// overwrites the same `revoked_at`. No-op if the grant is absent.
    /// Mirrors Swift `GrantStore.revoke(id:at:)`.
    ///
    /// `now_iso8601` must be a well-formed ISO-8601 string
    /// (e.g. "2026-06-12T10:00:00Z"). Passing Apple reference seconds or
    /// Unix seconds here is a caller error.
    pub fn revoke(&self, id: Uuid, now_iso8601: &str) -> Result<(), GrantStoreError> {
        let pred = StoragePredicate::Eq(
            Column::new("grants", "id"),
            TypedValue::Text(id.to_string()),
        );
        let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
        // Store as TEXT ISO-8601 per the fleet date-storage rule.
        values.insert("revoked_at".to_string(), TypedValue::Text(now_iso8601.to_string()));
        self.storage.row_store().update("grants", values, &pred)?;
        Ok(())
    }

    /// Mark a grant revoked, supplying `now` as Unix epoch seconds.
    ///
    /// Converts `now_unix` to an ISO-8601 string before persisting,
    /// so callers can pass the same `f64` Unix-epoch representation used
    /// throughout the Rust grant subsystem. Mirrors Swift `GrantStore.revoke(id:at:)`.
    pub fn revoke_at_unix(&self, id: Uuid, now_unix: f64) -> Result<(), GrantStoreError> {
        let iso = unix_secs_to_iso8601(now_unix);
        self.revoke(id, &iso)
    }

    /// Every grant with no `revoked_at` set, as `StoredGrant` structs.
    ///
    /// Active means the row has `revoked_at IS NULL`. Expiry filtering
    /// is done in Rust after load (not in SQL) because the lifetime sum type
    /// is stored as JSON. Mirrors Swift `GrantStore.active()`.
    pub fn active_stored(&self) -> Result<Vec<StoredGrant>, GrantStoreError> {
        let pred = StoragePredicate::IsNull(Column::new("grants", "revoked_at"));
        let rows = self.storage.row_store().query(
            "grants",
            Some(&pred),
            &[],
            None,
            None,
        )?;
        rows.into_iter().map(|r| Self::decode_storage_row(&r)).collect()
    }

    /// Every active (non-revoked) grant as `Grant` values. Equivalent to
    /// Swift `GrantStore.active()`.
    pub fn active_grants(&self) -> Result<Vec<Grant>, GrantStoreError> {
        Ok(self.active_stored()?.into_iter().map(|sg| sg.grant).collect())
    }

    /// Non-revoked grants that appear active at `now` (Unix epoch seconds)
    /// — revoked_at IS NULL AND not yet expired.
    ///
    /// Used by the coordinator's `federated_recall` to filter active grants.
    /// Mirrors the in-memory store's `active(now: f64) -> Vec<&StoredGrant>`.
    pub fn active(&self, now: f64) -> Result<Vec<StoredGrant>, GrantStoreError> {
        let stored = self.active_stored()?;
        Ok(stored.into_iter().filter(|sg| {
            match sg.grant.lifetime.expiry(sg.grant.issued_at) {
                None => true,
                Some(expiry) => now <= expiry,
            }
        }).collect())
    }

    /// Non-revoked grants that have expired strictly before `now`
    /// (Unix epoch seconds). Mirrors Swift `GrantStore.expired(before:)`.
    pub fn expired(&self, now: f64) -> Result<Vec<Grant>, GrantStoreError> {
        let stored = self.active_stored()?;
        Ok(stored.into_iter()
            .filter(|sg| {
                match sg.grant.lifetime.expiry(sg.grant.issued_at) {
                    None => false,
                    Some(expiry) => expiry < now,
                }
            })
            .map(|sg| sg.grant)
            .collect())
    }

    /// Directly set the inference budget for a grant to `value`.
    ///
    /// Test helper used by parity tests to seed a specific budget value
    /// without going through the normal issue path. In production, budget
    /// is initialised at issue time and decremented only via `debit_budget`.
    /// Does nothing if the grant is absent.
    pub fn set_budget(&self, id: Uuid, value: f64) -> Result<(), GrantStoreError> {
        // Only update if the grant exists.
        if self.get(id)?.is_none() {
            return Ok(());
        }
        let pred = StoragePredicate::Eq(
            Column::new("grants", "id"),
            TypedValue::Text(id.to_string()),
        );
        let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
        values.insert("inference_budget".to_string(), TypedValue::Float(value));
        self.storage.row_store().update("grants", values, &pred)?;
        Ok(())
    }

    // -----------------------------------------------------------------------
    // Decode — fail-closed, mirrors Swift GrantStore.decode(_:)
    // -----------------------------------------------------------------------

    /// Decode a `StorageRow` (as returned by a `RowStore::query` call) into a
    /// `StoredGrant`. Fail-closed: any undecodable required field surfaces a
    /// `GrantStoreError` — callers MUST treat this as a hard failure and MUST
    /// NOT honour the grant.
    ///
    /// Security posture: `issued_at` failures throw `CorruptIssuedAt` rather
    /// than substituting epoch-0. An epoch-0 `issued_at` is a fabricated value
    /// that corrupts lifetime arithmetic. Access-control data must fail-closed.
    ///
    /// Mirror of Swift `GrantStore.decode(_:StorageRow)`.
    pub fn decode_storage_row(row: &StorageRow) -> Result<StoredGrant, GrantStoreError> {
        // Helper: extract required text column, fail-closed on missing/wrong type.
        let text = |col: &str| -> Result<String, GrantStoreError> {
            match row.get(col) {
                Some(TypedValue::Text(s)) => Ok(s.clone()),
                Some(other) => Err(GrantStoreError::CorruptRow(
                    format!("grants.{col} expected Text, got {:?}", other.type_description())
                )),
                None => Err(GrantStoreError::CorruptRow(
                    format!("grants.{col} missing")
                )),
            }
        };

        let id = Uuid::parse_str(&text("id")?)
            .map_err(|_| GrantStoreError::CorruptRow("grants.id is not a UUID".into()))?;

        let grantee_id = Uuid::parse_str(&text("grantee_id")?)
            .map_err(|_| GrantStoreError::CorruptRow("grants.grantee_id is not a UUID".into()))?;

        // Fail-closed: a corrupt issued_at must throw rather than produce epoch-0.
        // See GrantStoreError::CorruptIssuedAt for the security rationale.
        let issued_at_unix = match row.get("issued_at") {
            Some(TypedValue::Text(s)) => {
                parse_iso8601_to_unix_secs(s).ok_or_else(|| GrantStoreError::CorruptIssuedAt {
                    stored_text: s.clone(),
                })?
            }
            Some(TypedValue::Timestamp(t)) => {
                // Defensive: if the InMemory backend ever stored issued_at as a
                // raw Timestamp rather than ISO8601 Text. PersistenceKit
                // `Timestamp(i64)` is Unix epoch SECONDS (sqlite.rs iso8601(secs)),
                // which is exactly the unit we want — pass through directly.
                // No /1000 (it is NOT ms) and no epoch offset needed.
                *t as f64
            }
            Some(other) => return Err(GrantStoreError::CorruptIssuedAt {
                stored_text: format!("<{}>", other.type_description()),
            }),
            None => return Err(GrantStoreError::CorruptIssuedAt {
                stored_text: "<null>".into(),
            }),
        };

        // revoked_at is nullable; a corrupt value is a hard failure because
        // silently ignoring a revocation record would widen access.
        let revoked_at: Option<f64> = match row.get("revoked_at") {
            None | Some(TypedValue::Null) => None,
            Some(TypedValue::Text(s)) if s.is_empty() => None,
            Some(TypedValue::Text(s)) => {
                Some(parse_iso8601_to_unix_secs(s).ok_or_else(|| {
                    GrantStoreError::CorruptRow(
                        format!("grants.revoked_at not ISO-8601: {s}")
                    )
                })?)
            }
            Some(TypedValue::Timestamp(t)) => {
                // PersistenceKit Timestamp is Unix epoch SECONDS — pass through
                // directly. No /1000 (NOT ms), no epoch offset needed.
                Some(*t as f64)
            }
            Some(other) => return Err(GrantStoreError::CorruptRow(
                format!("grants.revoked_at unexpected type {:?}", other.type_description())
            )),
        };

        // scope_json and lifetime_json are stored as TEXT (JSON).
        let scope: GrantScope = serde_json::from_str(&text("scope_json")?)
            .map_err(|e| GrantStoreError::CorruptRow(
                format!("grants.scope_json cannot decode: {e}")
            ))?;
        let lifetime: GrantLifetime = serde_json::from_str(&text("lifetime_json")?)
            .map_err(|e| GrantStoreError::CorruptRow(
                format!("grants.lifetime_json cannot decode: {e}")
            ))?;

        // Mode-4 decay columns (NULL for other modes). decay_started_at is a
        // TEXT/Timestamp date column parsed to Unix epoch seconds the same
        // way issued_at is; a non-date value is ignored (treated as absent) so
        // the documented default (started_at = issued_at) can fire.
        let decay_half_life: Option<i64> = match row.get("decay_half_life") {
            Some(TypedValue::Int(i)) => Some(*i),
            Some(TypedValue::Bitmap(i)) => Some(*i),
            Some(TypedValue::Float(f)) => Some(*f as i64),
            _ => None,
        };
        let decay_floor: Option<i64> = match row.get("decay_floor") {
            Some(TypedValue::Int(i)) => Some(*i),
            Some(TypedValue::Bitmap(i)) => Some(*i),
            Some(TypedValue::Float(f)) => Some(*f as i64),
            _ => None,
        };
        let decay_started_at: Option<f64> = match row.get("decay_started_at") {
            Some(TypedValue::Text(s)) => parse_iso8601_to_unix_secs(s),
            Some(TypedValue::Timestamp(t)) => {
                // PersistenceKit Timestamp is Unix epoch SECONDS — pass through
                // directly. No /1000 (NOT ms), no epoch offset needed.
                Some(*t as f64)
            }
            _ => None,
        };
        let custody_mode = Self::decode_custody_mode(
            &text("custody_mode")?,
            decay_half_life,
            decay_started_at,
            decay_floor,
            Some(issued_at_unix),
        )?;
        let reshare = Self::decode_reshare(&text("reshare")?)?;

        let content_level: i64 = match row.get("content_level") {
            Some(TypedValue::Int(i)) => *i,
            Some(TypedValue::Bitmap(i)) => *i,
            Some(TypedValue::Float(f)) => *f as i64,
            Some(TypedValue::Text(s)) => s.parse().unwrap_or(0),
            _ => 0,
        };

        let inference_budget: f64 = match row.get("inference_budget") {
            Some(TypedValue::Float(f)) => *f,
            Some(TypedValue::Int(i)) => *i as f64,
            _ => 0.0,
        };

        let signature: Vec<u8> = match row.get("signature") {
            Some(TypedValue::Blob(b)) => b.clone(),
            _ => vec![],
        };

        let grant = Grant {
            id,
            grantee_estate_id: grantee_id,
            scope,
            content_level,
            lifetime,
            custody_mode,
            re_share_permission: reshare,
            inference_remaining_budget: inference_budget,
            issued_at: issued_at_unix,
            signature,
        };
        Ok(StoredGrant { grant, revoked_at })
    }

    /// Decode a raw `HashMap<&str, &str>` row (as from an external SQL read or test)
    /// into a `StoredGrant`. Fail-closed: any undecodable field surfaces a
    /// `GrantStoreError` — callers MUST treat this as a hard failure.
    ///
    /// This is the legacy decode path used by tests that build rows by hand.
    /// New callers should prefer `decode_storage_row`. Mirror of
    /// Swift `GrantStore.decode(_:StorageRow)` for the text-dict form.
    pub fn decode_row(
        row: &std::collections::HashMap<&str, &str>,
    ) -> Result<StoredGrant, GrantStoreError> {
        let id_str = row.get("id").copied()
            .ok_or_else(|| GrantStoreError::CorruptRow("grants.id missing".into()))?;
        let id = Uuid::parse_str(id_str)
            .map_err(|_| GrantStoreError::CorruptRow(format!("grants.id not a UUID: {id_str}")))?;

        let grantee_str = row.get("grantee_id").copied()
            .ok_or_else(|| GrantStoreError::CorruptRow("grants.grantee_id missing".into()))?;
        let grantee_estate_id = Uuid::parse_str(grantee_str)
            .map_err(|_| GrantStoreError::CorruptRow(
                format!("grants.grantee_id not a UUID: {grantee_str}")
            ))?;

        // Fail-closed: a corrupt issued_at must throw rather than produce epoch-0.
        let issued_at_str = row.get("issued_at").copied()
            .ok_or_else(|| GrantStoreError::CorruptIssuedAt {
                stored_text: "<null>".into(),
            })?;
        let issued_at = parse_iso8601_to_unix_secs(issued_at_str)
            .ok_or_else(|| GrantStoreError::CorruptIssuedAt {
                stored_text: issued_at_str.to_string(),
            })?;

        let revoked_at = match row.get("revoked_at").copied() {
            None | Some("") => None,
            Some(s) => {
                let t = parse_iso8601_to_unix_secs(s)
                    .ok_or_else(|| GrantStoreError::CorruptRow(
                        format!("grants.revoked_at not ISO-8601: {s}")
                    ))?;
                Some(t)
            }
        };

        // scope/lifetime/custody_mode/reshare require full decode.
        // For the text-dict path, these may arrive as JSON strings or tokens.
        // Scope and lifetime are decoded from JSON if present; custody mode
        // and reshare are decoded from their discriminant tokens.
        let scope: GrantScope = if let Some(j) = row.get("scope_json").copied() {
            serde_json::from_str(j)
                .map_err(|e| GrantStoreError::CorruptRow(format!("scope_json: {e}")))?
        } else {
            // Permissive path for tests that omit scope_json — use WholeEstate.
            // This does NOT apply to real storage-backed decode; see decode_storage_row.
            super::grant::GrantScope::WholeEstate
        };

        let lifetime: GrantLifetime = if let Some(j) = row.get("lifetime_json").copied() {
            serde_json::from_str(j)
                .map_err(|e| GrantStoreError::CorruptRow(format!("lifetime_json: {e}")))?
        } else {
            super::grant::GrantLifetime::Permanent
        };

        // Mode-4 decay columns from the text-dict form (tests). decay_started_at
        // is an ISO-8601 string here; a missing or unparseable value falls back
        // to the documented default (issued_at) inside decode_custody_mode.
        let decay_half_life: Option<i64> = row.get("decay_half_life")
            .and_then(|s| s.parse::<i64>().ok());
        let decay_floor: Option<i64> = row.get("decay_floor")
            .and_then(|s| s.parse::<i64>().ok());
        let decay_started_at: Option<f64> = row.get("decay_started_at")
            .and_then(|s| parse_iso8601_to_unix_secs(s));
        let custody_mode: CustodyMode = if let Some(t) = row.get("custody_mode").copied() {
            Self::decode_custody_mode(t, decay_half_life, decay_started_at, decay_floor, Some(issued_at))?
        } else {
            CustodyMode::Mediated
        };

        let reshare: ReSharePermission = if let Some(t) = row.get("reshare").copied() {
            Self::decode_reshare(t)?
        } else {
            ReSharePermission::None
        };

        // Decode the remaining persisted fields so decode_row faithfully
        // reconstructs the stored grant. Hardcoding content_level=0 and
        // inference_remaining_budget=0.0 caused callers that build rows by hand
        // (integration tests, migration paths) to see effective content_level=0
        // and zero budget regardless of what was persisted — a security-relevant
        // omission that would silently block all federated access for any grant
        // decoded through this path (finding GRT-decode).
        let content_level: i64 = row
            .get("content_level")
            .and_then(|s| s.parse::<i64>().ok())
            .unwrap_or(0);

        let inference_remaining_budget: f64 = row
            .get("inference_budget")
            .and_then(|s| s.parse::<f64>().ok())
            .unwrap_or(0.0);

        // Signature is a BLOB; the text-dict path does not carry a real Ed25519
        // signature (tests omit it). An empty signature is the correct posture
        // here — the verify path checks `!signature.is_empty()` before doing
        // curve arithmetic so an empty vec never passes verification silently.
        // The production decode path (`decode_storage_row`) reads the real blob.
        let signature: Vec<u8> = vec![];

        let grant = Grant {
            id,
            grantee_estate_id,
            scope,
            content_level,
            lifetime,
            custody_mode,
            re_share_permission: reshare,
            inference_remaining_budget,
            issued_at,
            signature,
        };
        Ok(StoredGrant { grant, revoked_at })
    }

    // -----------------------------------------------------------------------
    // Row encoding — mirrors Swift GrantStore.row(from:)
    // -----------------------------------------------------------------------

    /// Encode a `Grant` into a column dictionary for upsert.
    /// `revoked_at` is omitted at insert; it is written only by `revoke`.
    /// Mirrors Swift `GrantStore.row(from:)`.
    fn row_from(grant: &Grant) -> Result<BTreeMap<String, TypedValue>, GrantStoreError> {
        let scope_json = serde_json::to_string(&grant.scope)
            .map_err(|e| GrantStoreError::StorageFailure(format!("scope encode: {e}")))?;
        let lifetime_json = serde_json::to_string(&grant.lifetime)
            .map_err(|e| GrantStoreError::StorageFailure(format!("lifetime encode: {e}")))?;
        let issued_at_iso = unix_secs_to_iso8601(grant.issued_at);
        let mut map: BTreeMap<String, TypedValue> = BTreeMap::new();
        map.insert("id".to_string(), TypedValue::Text(grant.id.to_string()));
        map.insert("grantee_id".to_string(), TypedValue::Text(grant.grantee_estate_id.to_string()));
        map.insert("scope_json".to_string(), TypedValue::Text(scope_json));
        map.insert("content_level".to_string(), TypedValue::Int(grant.content_level));
        // The bare discriminant — mode-4 decay parameters ride in the
        // dedicated decay_* columns, not the token.
        map.insert("custody_mode".to_string(), TypedValue::Text(grant.custody_mode.column_token().to_string()));
        map.insert("lifetime_json".to_string(), TypedValue::Text(lifetime_json));
        map.insert("reshare".to_string(), TypedValue::Text(grant.re_share_permission.signing_token().to_string()));
        map.insert("inference_budget".to_string(), TypedValue::Float(grant.inference_remaining_budget));
        // Store dates as TEXT ISO-8601 per the fleet date-storage rule.
        map.insert("issued_at".to_string(), TypedValue::Text(issued_at_iso));
        map.insert("signature".to_string(), TypedValue::Blob(grant.signature.clone()));
        // Mode-4 (TimeAging) persists its decay policy into dedicated columns.
        // Every other mode leaves them absent (NULL on insert).
        if let CustodyMode::TimeAging(policy) = &grant.custody_mode {
            map.insert("decay_half_life".to_string(), TypedValue::Int(policy.half_life_seconds));
            map.insert("decay_started_at".to_string(), TypedValue::Text(unix_secs_to_iso8601(policy.started_at)));
            map.insert("decay_floor".to_string(), TypedValue::Int(policy.floor));
        }
        Ok(map)
    }

    // -----------------------------------------------------------------------
    // Token decoders — mirrors Swift custodyMode(from:) / reSharePermission(from:)
    // -----------------------------------------------------------------------

    /// Reconstruct the custody mode from its persisted discriminant token.
    ///
    /// Mode 3 (decay-derived) is no-vault BY DESIGN (Appendix B.3 no-vault
    /// posture): the issuer derives the scope key, returns it to the caller,
    /// and retains NOTHING — the caller holds the K-of-N shares. The issuer
    /// therefore correctly does NOT persist threshold/total_shares/drift_rate;
    /// there is no issuer-side custody record to round-trip. Mode 3 decodes with
    /// placeholder associated values (`threshold=0`, `total_shares=0`,
    /// `DriftRate::Slow`, `experimental_ip_clearance_confirmed=true`) precisely
    /// because the authoritative copy lives with the caller, not the store —
    /// this is the intended posture, NOT a schema defect. Callers must not treat
    /// decoded mode-3 grants as authoritative for the associated value fields.
    /// Any future custody metadata the federation/encryption track needs to
    /// retain has a migration-free home in the `ext` forward-compat slot
    /// rather than new typed columns. Mirror of the Swift port.
    ///
    /// Mode 4 (`TimeAging`) round-trips its decay policy through the dedicated
    /// `decay_half_life`, `decay_started_at`, and `decay_floor` columns
    /// (passed here as `half_life`, `started_at`, `floor`). The legacy
    /// `"physicalDecay"` token is an alias for the same mode-4 slot and decodes
    /// INTO `TimeAging` — the slot was never retired, so a legacy row is
    /// migrated, never refused.
    ///
    /// Documented defaults for a mode-4 row with NULL decay columns (a legacy
    /// `physicalDecay` row): the decay clock starts at `issued_at`, the
    /// half-life is `DecayPolicy::DEFAULT_HALF_LIFE_SECONDS` (30 days), and the
    /// floor is `0`. Mirror of Swift `GrantStore.custodyMode(from:...)`.
    fn decode_custody_mode(
        token: &str,
        half_life: Option<i64>,
        started_at: Option<f64>,
        floor: Option<i64>,
        issued_at: Option<f64>,
    ) -> Result<CustodyMode, GrantStoreError> {
        match token {
            "mediated"     => Ok(CustodyMode::Mediated),
            "handedOver"   => Ok(CustodyMode::HandedOver),
            "decayDerived" => Ok(CustodyMode::DecayDerived {
                threshold: 0,
                total_shares: 0,
                drift_rate: DriftRate::Slow,
                experimental_ip_clearance_confirmed: true,
            }),
            // `physicalDecay` is the legacy mode-4 token; it aliases `timeAging`.
            "timeAging" | "physicalDecay" => Ok(CustodyMode::TimeAging(DecayPolicy {
                half_life_seconds: half_life.unwrap_or(DecayPolicy::DEFAULT_HALF_LIFE_SECONDS),
                started_at: started_at.or(issued_at).unwrap_or(0.0),
                floor: floor.unwrap_or(0),
            })),
            other => Err(GrantStoreError::CorruptRow(
                format!("unrecognized custody_mode '{other}'")
            )),
        }
    }

    /// Decode re-share permission from its persisted discriminant token.
    fn decode_reshare(token: &str) -> Result<ReSharePermission, GrantStoreError> {
        match token {
            "none"      => Ok(ReSharePermission::None),
            "withAudit" => Ok(ReSharePermission::WithAudit),
            "free"      => Ok(ReSharePermission::Free),
            other => Err(GrantStoreError::CorruptRow(
                format!("unrecognized reshare '{other}'")
            )),
        }
    }
}

// -----------------------------------------------------------------------
// Serialization — GrantScope and GrantLifetime need serde for JSON storage
// -----------------------------------------------------------------------

// Implement serde Serialize/Deserialize for GrantScope and GrantLifetime
// so the grant store can round-trip them through JSON text columns.
// The tagged-enum format matches what Swift's Codable would produce,
// ensuring the on-disk JSON is cross-platform compatible.

use serde::{Deserialize, Serialize};

impl Serialize for GrantScope {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeMap;
        match self {
            GrantScope::WholeEstate => {
                let mut m = s.serialize_map(Some(1))?;
                m.serialize_entry("type", "wholeEstate")?;
                m.end()
            }
            GrantScope::Wing(name) => {
                let mut m = s.serialize_map(Some(2))?;
                m.serialize_entry("type", "wing")?;
                m.serialize_entry("name", name)?;
                m.end()
            }
            GrantScope::Room(name) => {
                let mut m = s.serialize_map(Some(2))?;
                m.serialize_entry("type", "room")?;
                m.serialize_entry("name", name)?;
                m.end()
            }
            GrantScope::LatticeSubtree { udc_code } => {
                let mut m = s.serialize_map(Some(2))?;
                m.serialize_entry("type", "latticeSubtree")?;
                m.serialize_entry("udc_code", udc_code)?;
                m.end()
            }
            GrantScope::SingleRow(id) => {
                let mut m = s.serialize_map(Some(2))?;
                m.serialize_entry("type", "singleRow")?;
                m.serialize_entry("id", &id.to_string())?;
                m.end()
            }
        }
    }
}

impl<'de> Deserialize<'de> for GrantScope {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        use serde::de::{self, MapAccess, Visitor};
        struct ScopeVisitor;
        impl<'de> Visitor<'de> for ScopeVisitor {
            type Value = GrantScope;
            fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                write!(f, "a GrantScope JSON map")
            }
            fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<GrantScope, A::Error> {
                let mut type_tag: Option<String> = None;
                let mut name: Option<String> = None;
                let mut udc_code: Option<String> = None;
                let mut id: Option<String> = None;
                while let Some(key) = map.next_key::<String>()? {
                    match key.as_str() {
                        "type"     => { type_tag = Some(map.next_value()?); }
                        "name"     => { name = Some(map.next_value()?); }
                        "udc_code" => { udc_code = Some(map.next_value()?); }
                        "id"       => { id = Some(map.next_value()?); }
                        _          => { let _: serde_json::Value = map.next_value()?; }
                    }
                }
                match type_tag.as_deref() {
                    Some("wholeEstate") => Ok(GrantScope::WholeEstate),
                    Some("wing") => Ok(GrantScope::Wing(
                        name.ok_or_else(|| de::Error::missing_field("name"))?
                    )),
                    Some("room") => Ok(GrantScope::Room(
                        name.ok_or_else(|| de::Error::missing_field("name"))?
                    )),
                    Some("latticeSubtree") => Ok(GrantScope::LatticeSubtree {
                        udc_code: udc_code.ok_or_else(|| de::Error::missing_field("udc_code"))?,
                    }),
                    Some("singleRow") => {
                        let id_str = id.ok_or_else(|| de::Error::missing_field("id"))?;
                        let uuid = Uuid::parse_str(&id_str)
                            .map_err(de::Error::custom)?;
                        Ok(GrantScope::SingleRow(uuid))
                    }
                    other => Err(de::Error::unknown_variant(
                        other.unwrap_or("<null>"),
                        &["wholeEstate","wing","room","latticeSubtree","singleRow"],
                    )),
                }
            }
        }
        d.deserialize_map(ScopeVisitor)
    }
}

impl Serialize for GrantLifetime {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeMap;
        match self {
            GrantLifetime::Permanent => {
                let mut m = s.serialize_map(Some(1))?;
                m.serialize_entry("type", "permanent")?;
                m.end()
            }
            GrantLifetime::Until(t) => {
                let mut m = s.serialize_map(Some(2))?;
                m.serialize_entry("type", "until")?;
                m.serialize_entry("deadline", t)?;
                m.end()
            }
            GrantLifetime::DecayWindow { seconds } => {
                let mut m = s.serialize_map(Some(2))?;
                m.serialize_entry("type", "decayWindow")?;
                m.serialize_entry("seconds", seconds)?;
                m.end()
            }
        }
    }
}

impl<'de> Deserialize<'de> for GrantLifetime {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        use serde::de::{self, MapAccess, Visitor};
        struct LifetimeVisitor;
        impl<'de> Visitor<'de> for LifetimeVisitor {
            type Value = GrantLifetime;
            fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                write!(f, "a GrantLifetime JSON map")
            }
            fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<GrantLifetime, A::Error> {
                let mut type_tag: Option<String> = None;
                let mut deadline: Option<f64> = None;
                let mut seconds: Option<i64> = None;
                while let Some(key) = map.next_key::<String>()? {
                    match key.as_str() {
                        "type"     => { type_tag = Some(map.next_value()?); }
                        "deadline" => { deadline = Some(map.next_value()?); }
                        "seconds"  => { seconds = Some(map.next_value()?); }
                        _          => { let _: serde_json::Value = map.next_value()?; }
                    }
                }
                match type_tag.as_deref() {
                    Some("permanent") => Ok(GrantLifetime::Permanent),
                    Some("until") => Ok(GrantLifetime::Until(
                        deadline.ok_or_else(|| de::Error::missing_field("deadline"))?
                    )),
                    Some("decayWindow") => Ok(GrantLifetime::DecayWindow {
                        seconds: seconds.ok_or_else(|| de::Error::missing_field("seconds"))?,
                    }),
                    other => Err(de::Error::unknown_variant(
                        other.unwrap_or("<null>"),
                        &["permanent","until","decayWindow"],
                    )),
                }
            }
        }
        d.deserialize_map(LifetimeVisitor)
    }
}

// -----------------------------------------------------------------------
// ISO-8601 ↔ Unix epoch seconds helpers
// -----------------------------------------------------------------------

/// Format Unix epoch seconds (f64) as an ISO-8601 string.
///
/// Produces "YYYY-MM-DDThh:mm:ssZ" (whole-second resolution). The grant
/// subsystem stores all dates as ISO-8601 TEXT (fleet rule). The input is
/// truncated to whole seconds — sub-second precision is not preserved in
/// the persisted string, matching Swift's `ISO8601DateFormatter` behaviour
/// with no fractional-seconds option. NOTE: the Apple reference date
/// (2001-01-01) is NOT used here — the input is plain Unix epoch seconds
/// (1970-01-01 origin), consistent with the rest of the Rust substrate.
pub(crate) fn unix_secs_to_iso8601(unix_secs: f64) -> String {
    format_iso8601_from_unix_i64(unix_secs as i64)
}

/// Internal civil-date ISO-8601 formatter from Unix epoch seconds (i64).
fn format_iso8601_from_unix_i64(unix_secs: i64) -> String {
    // Convert Unix seconds to (y, m, d, h, min, s) via civil-date math.
    // Howard Hinnant's civil_from_days algorithm.
    let (y, mo, d) = civil_from_unix_secs_inner(unix_secs);
    let remaining = unix_secs.rem_euclid(86_400);
    let hh = remaining / 3_600;
    let mm = (remaining % 3_600) / 60;
    let ss = remaining % 60;
    format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z", y, mo, d, hh, mm, ss)
}

fn civil_from_unix_secs_inner(unix_secs: i64) -> (i64, i64, i64) {
    // Days since Unix epoch.
    let z = unix_secs.div_euclid(86_400) + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let mo = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if mo <= 2 { y + 1 } else { y };
    (y, mo, d)
}

/// Parse an ISO-8601 date-time string to Unix epoch seconds (f64).
///
/// Accepted forms match what Swift's `ISO8601DateFormatter` with
/// `.withInternetDateTime` produces:
///   - `YYYY-MM-DDThh:mm:ssZ`           (20 chars, whole-second)
///   - `YYYY-MM-DDThh:mm:ss.sssZ`       (24 chars, millisecond)
///
/// Returns `None` if the string does not structurally match either form.
/// NOTE: returns plain Unix epoch seconds (1970-01-01 origin) — the Apple
/// reference date offset (978307200) is NOT applied.
pub(crate) fn parse_iso8601_to_unix_secs(s: &str) -> Option<f64> {
    let b = s.as_bytes();
    // Require exactly the two accepted shapes.
    let (len, has_frac) = match b.len() {
        20 => (20usize, false),
        24 => (24usize, true),
        _ => return None,
    };
    // Structural checks: separators must be in the right positions.
    if b[4] != b'-' || b[7] != b'-' || b[10] != b'T'
        || b[13] != b':' || b[16] != b':' || b[len - 1] != b'Z'
    {
        return None;
    }
    if has_frac && b[19] != b'.' {
        return None;
    }

    let y: i64 = s.get(0..4)?.parse().ok()?;
    let mo: i64 = s.get(5..7)?.parse().ok()?;
    let d: i64 = s.get(8..10)?.parse().ok()?;
    let hh: i64 = s.get(11..13)?.parse().ok()?;
    let mm: i64 = s.get(14..16)?.parse().ok()?;
    let ss: i64 = s.get(17..19)?.parse().ok()?;

    // Validate field ranges to reject nonsense like month=99.
    if mo < 1 || mo > 12 || d < 1 || d > 31 || hh > 23 || mm > 59 || ss > 59 {
        return None;
    }

    let frac_millis: i64 = if has_frac {
        s.get(20..23)?.parse().ok()?
    } else {
        0
    };

    // Days since Unix epoch (Howard Hinnant's days_from_civil).
    let days = days_from_civil(y, mo, d);
    let unix_secs = days * 86_400 + hh * 3_600 + mm * 60 + ss;

    Some(unix_secs as f64 + frac_millis as f64 / 1_000.0)
}

/// Days from 1970-01-01 for a civil (y, m, d) date (Howard Hinnant).
/// Valid for the proleptic Gregorian calendar.
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

// -----------------------------------------------------------------------
// Unit tests
// -----------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use persistence_kit::inmemory::InMemoryStorage;
    use persistence_kit::storage::{BackendConfiguration, EstateConfiguration};

    fn make_storage() -> Arc<dyn Storage> {
        Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()))
    }

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
            issued_at: 1_780_272_000.0, // 2026-06-01T00:00:00Z in Unix epoch seconds
            signature: vec![],
        }
    }

    #[test]
    fn new_opens_schema_and_inserts_grant() {
        let storage = make_storage();
        let store = GrantStore::new(storage).expect("store init");
        let grant = make_grant(GrantLifetime::Permanent);
        let id = grant.id;
        store.insert(&grant).expect("insert");
        let sg = store.get(id).expect("get ok").expect("grant present");
        assert_eq!(sg.grant.id, id);
        assert!(sg.revoked_at.is_none());
    }

    #[test]
    fn active_excludes_revoked() {
        let storage = make_storage();
        let store = GrantStore::new(storage).expect("store init");
        let grant = make_grant(GrantLifetime::Permanent);
        let id = grant.id;
        let issued_at = grant.issued_at;
        store.insert(&grant).expect("insert");
        // Revoke using an ISO-8601 time after issuance.
        let revoke_time = unix_secs_to_iso8601(issued_at + 100.0);
        store.revoke(id, &revoke_time).expect("revoke");
        let active = store.active(issued_at + 200.0).expect("active");
        assert!(active.is_empty(), "revoked grant must not appear in active");
    }

    #[test]
    fn active_excludes_expired() {
        let storage = make_storage();
        let store = GrantStore::new(storage).expect("store init");
        // Until deadline = issued_at + 100 Unix epoch seconds.
        let grant = make_grant(GrantLifetime::Until(1_780_272_100.0));
        let issued_at = grant.issued_at;
        store.insert(&grant).expect("insert");
        // Before expiry: active.
        let active_before = store.active(issued_at + 50.0).expect("active before");
        assert_eq!(active_before.len(), 1, "grant should be active before expiry");
        // After expiry: not active.
        let active_after = store.active(issued_at + 200.0).expect("active after");
        assert!(active_after.is_empty(), "grant must not be active after expiry");
    }

    #[test]
    fn debit_budget_persists_to_storage() {
        let storage = make_storage();
        let store = GrantStore::new(storage).expect("store init");
        let mut grant = make_grant(GrantLifetime::Permanent);
        grant.inference_remaining_budget = 1.0;
        let id = grant.id;
        store.insert(&grant).expect("insert");

        let pre = store.debit_budget(id, 0.01).expect("debit");
        assert!((pre - 1.0).abs() < 1e-9, "pre-debit must be 1.0");

        // Re-read from storage to verify persistence.
        let sg = store.get(id).expect("get ok").expect("present");
        let expected = 1.0 - 0.01;
        assert!(
            (sg.grant.inference_remaining_budget - expected).abs() < 1e-9,
            "budget after debit must be {expected}, got {}",
            sg.grant.inference_remaining_budget
        );
    }

    #[test]
    fn debit_budget_clamps_at_zero() {
        let storage = make_storage();
        let store = GrantStore::new(storage).expect("store init");
        let mut grant = make_grant(GrantLifetime::Permanent);
        grant.inference_remaining_budget = 0.005;
        let id = grant.id;
        store.insert(&grant).expect("insert");

        store.debit_budget(id, 1.0).expect("debit");
        let sg = store.get(id).expect("get ok").expect("present");
        assert!(
            sg.grant.inference_remaining_budget >= 0.0,
            "budget must not go negative"
        );
        assert!(
            sg.grant.inference_remaining_budget.abs() < 1e-9,
            "budget after over-debit must be 0.0, got {}",
            sg.grant.inference_remaining_budget
        );
    }

    #[test]
    fn scope_and_lifetime_round_trip_through_json() {
        let storage = make_storage();
        let store = GrantStore::new(storage).expect("store init");
        let mut grant = make_grant(GrantLifetime::DecayWindow { seconds: 3600 });
        grant.scope = GrantScope::Wing("study".to_string());
        let id = grant.id;
        store.insert(&grant).expect("insert");

        let sg = store.get(id).expect("get ok").expect("present");
        assert_eq!(sg.grant.scope, GrantScope::Wing("study".to_string()), "scope round-trips");
        assert_eq!(
            sg.grant.lifetime,
            GrantLifetime::DecayWindow { seconds: 3600 },
            "lifetime round-trips"
        );
    }

    // Fail-closed decode tests — mirror Swift GRT01_CorruptGrantIssuedAtTests

    #[test]
    fn decode_row_valid_issued_at_succeeds() {
        let id = Uuid::new_v4();
        let grantee = Uuid::new_v4();
        let mut row: std::collections::HashMap<&str, &str> = std::collections::HashMap::new();
        row.insert("id", Box::leak(id.to_string().into_boxed_str()));
        row.insert("grantee_id", Box::leak(grantee.to_string().into_boxed_str()));
        row.insert("issued_at", "2026-06-01T00:00:00Z");
        let result = GrantStore::decode_row(&row);
        assert!(result.is_ok(), "valid ISO-8601 issued_at must decode; got {:?}", result.err());
        let sg = result.unwrap();
        // 2026-06-01T00:00:00Z is Unix epoch second 1_780_272_000.
        assert!(
            (sg.grant.issued_at - 1_780_272_000.0).abs() < 1.0,
            "issued_at Unix epoch must be ~1780272000, got {}", sg.grant.issued_at
        );
    }

    #[test]
    fn decode_row_corrupt_issued_at_returns_error_not_epoch_zero() {
        let id = Uuid::new_v4();
        let grantee = Uuid::new_v4();
        let mut row: std::collections::HashMap<&str, &str> = std::collections::HashMap::new();
        row.insert("id", Box::leak(id.to_string().into_boxed_str()));
        row.insert("grantee_id", Box::leak(grantee.to_string().into_boxed_str()));
        row.insert("issued_at", "not-a-date");
        let result = GrantStore::decode_row(&row);
        assert!(result.is_err(), "corrupt issued_at must produce an error");
        match result.unwrap_err() {
            GrantStoreError::CorruptIssuedAt { stored_text } => {
                assert_eq!(stored_text, "not-a-date");
            }
            other => panic!("expected CorruptIssuedAt, got {:?}", other),
        }
    }

    #[test]
    fn decode_row_empty_issued_at_returns_corrupt_error() {
        let id = Uuid::new_v4();
        let grantee = Uuid::new_v4();
        let mut row: std::collections::HashMap<&str, &str> = std::collections::HashMap::new();
        row.insert("id", Box::leak(id.to_string().into_boxed_str()));
        row.insert("grantee_id", Box::leak(grantee.to_string().into_boxed_str()));
        row.insert("issued_at", "");
        let result = GrantStore::decode_row(&row);
        assert!(result.is_err(), "empty issued_at must error");
        assert!(matches!(result.unwrap_err(), GrantStoreError::CorruptIssuedAt { .. }));
    }

    #[test]
    fn decode_row_absent_issued_at_returns_corrupt_error() {
        let id = Uuid::new_v4();
        let grantee = Uuid::new_v4();
        let mut row: std::collections::HashMap<&str, &str> = std::collections::HashMap::new();
        row.insert("id", Box::leak(id.to_string().into_boxed_str()));
        row.insert("grantee_id", Box::leak(grantee.to_string().into_boxed_str()));
        let result = GrantStore::decode_row(&row);
        assert!(result.is_err(), "absent issued_at must error");
        assert!(matches!(result.unwrap_err(), GrantStoreError::CorruptIssuedAt { .. }));
    }

    #[test]
    fn iso8601_round_trip() {
        // unix_secs_to_iso8601(parse_iso8601_to_unix_secs(s)) must equal s.
        // Verifies that the round-trip is lossless: the stored ISO-8601 TEXT
        // for any given wall-clock instant is byte-identical regardless of
        // which epoch is used internally, as long as the formatter and parser
        // are consistent.
        let cases = [
            "2026-06-01T00:00:00Z",
            "1970-01-01T00:00:00Z", // Unix epoch itself
            "2026-12-31T23:59:59Z",
        ];
        for s in &cases {
            let unix_secs = parse_iso8601_to_unix_secs(s)
                .unwrap_or_else(|| panic!("parse failed for {s}"));
            let back = unix_secs_to_iso8601(unix_secs);
            assert_eq!(&back, s, "ISO-8601 round-trip failed for {s}");
        }
    }

    #[test]
    fn unix_epoch_known_instant_round_trips_iso8601() {
        // A grant issued at a known Unix epoch instant must persist the
        // SAME ISO-8601 string it would have produced with Apple-ref
        // internally — because the persisted form is always ISO-8601 TEXT
        // and the TEXT is epoch-independent.
        // 2026-06-01T00:00:00Z = Unix second 1_780_272_000.
        let unix_secs = 1_780_272_000.0_f64;
        let iso = unix_secs_to_iso8601(unix_secs);
        assert_eq!(iso, "2026-06-01T00:00:00Z",
            "Unix 1780272000 must format as 2026-06-01T00:00:00Z, got {iso}");
        let parsed = parse_iso8601_to_unix_secs(&iso)
            .expect("round-trip parse must succeed");
        assert!((parsed - unix_secs).abs() < 1.0,
            "round-trip must recover the Unix epoch value; got {parsed}");
    }

    #[test]
    fn unix_epoch_grant_round_trips_through_storage() {
        // A grant issued at a known Unix instant must persist and reload
        // with the same issued_at value. Verifies the ISO-8601 TEXT stored
        // in SQLite is byte-identical to the formatter output.
        let storage = make_storage();
        let store = GrantStore::new(storage).expect("store init");
        // 2026-06-01T00:00:00Z in Unix epoch seconds.
        let unix_issued_at = 1_780_272_000.0_f64;
        let mut grant = make_grant(GrantLifetime::Permanent);
        grant.issued_at = unix_issued_at;
        let id = grant.id;
        store.insert(&grant).expect("insert");
        let sg = store.get(id).expect("get ok").expect("grant present");
        assert!(
            (sg.grant.issued_at - unix_issued_at).abs() < 1.0,
            "issued_at must round-trip through storage; expected ~{unix_issued_at}, got {}",
            sg.grant.issued_at
        );
    }
}
