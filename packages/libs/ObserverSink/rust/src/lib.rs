//! observer-sink
//!
//! Reusable PersistenceKit-backed `StatsSink` + stats-store schema + retention
//! for the MOOTx01 manager pipeline (Manager 1.0, Phase 0.5).
//!
//! ## Architecture (MANAGER_1.0_PLAN.md §1, §4)
//!
//! Consumers install a `PersistenceStatsSink` in the `Intellectus` global holder.
//! Each `receive` call checks the store-level monitoring flag row; if the flag
//! is `"1"`, the sample is serialised into the appropriate table in the `StatsStore`.
//!
//! ## Schema (mirrors Swift port exactly)
//!
//! Four tables (v2):
//! - `metric_samples`:       metric observations (name, value, tags-JSON, ts TEXT, dropbox_id)
//! - `event_samples`:        topology events (kind, noun_type, estate_row_id, estate, ts TEXT, dropbox_id)
//! - `control`:              global monitoring flag + retention metadata (key-value TEXT pairs)
//! - `topology_snapshots`:   one row per estate, latest-wins upsert (estate PK, generated_at TEXT, payload TEXT)
//!
//! All timestamps are TEXT (ISO-8601 UTC). The `ts: f64` (epoch seconds) from
//! `StatSample` is converted at the store boundary. No REAL timestamp columns exist.
//!
//! ## Parity with Swift port
//!
//! - Same table names, column names, and column types.
//! - Same monitoring flag semantics: `"monitoring"` row, value `"1"` = on, `"0"` = off.
//! - Same retention semantics: `delete_metrics_before` / `delete_events_before` take
//!   the cutoff as a parameter — no `std::time::SystemTime::now()` inside any engine.
//! - `PersistenceStatsSink::receive` is synchronous (Rust trait is synchronous) and
//!   checks the flag before each insert.

mod store;
mod sink;

pub use store::{StatsStore, StatsStoreSchema, MetricRow, EventRow, DropboxMetricAggregate};
pub use sink::PersistenceStatsSink;
// Re-export StorageStats so callers of storage_stats() can name the return type
// without a direct persistence_kit dependency in their own crate.
pub use persistence_kit::StorageStats;
