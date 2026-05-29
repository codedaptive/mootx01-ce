// sqlite_tail.rs
//
// SQLite durability tail per cookbook § 4.3. Mirror of
// glref-swift-SQLiteDurabilityTail.swift.
//
// Reference implementation: trait + in-memory backing for the
// conformance gate. Production code wires this to libsqlite3 via
// rusqlite or sqlx.

use std::sync::Mutex;
use crate::hlc::HLC;
use crate::fingerprint256::Fingerprint256;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuditEvent {
    pub hlc: HLC,
    pub estate_uuid: [u8; 16],
    pub row_id: u128,
    pub actor: String,
    pub mutation: String,
    pub before_state: Option<Vec<u8>>,
    pub after_state: Vec<u8>,
    pub fingerprint: Fingerprint256,
    pub lattice: String,
}

pub trait AuditEventStore {
    fn append(&self, event: AuditEvent) -> Result<(), String>;
    fn events_for_row(&self, row_id: u128, up_to: Option<HLC>) -> Result<Vec<AuditEvent>, String>;
    fn events_in_range(&self, start: HLC, end: HLC) -> Result<Vec<AuditEvent>, String>;
    fn events_for_estate(&self, estate: [u8; 16], start: HLC, end: HLC) -> Result<Vec<AuditEvent>, String>;
    fn event_count(&self) -> Result<usize, String>;
    fn truncate(&self) -> Result<(), String>;
}

#[derive(Default)]
pub struct InMemoryAuditStore {
    inner: Mutex<Vec<AuditEvent>>,
}

impl InMemoryAuditStore {
    pub fn new() -> Self { Self::default() }
}

impl AuditEventStore for InMemoryAuditStore {
    fn append(&self, event: AuditEvent) -> Result<(), String> {
        self.inner.lock().map_err(|e| e.to_string())?.push(event);
        Ok(())
    }

    fn events_for_row(&self, row_id: u128, up_to: Option<HLC>) -> Result<Vec<AuditEvent>, String> {
        let guard = self.inner.lock().map_err(|e| e.to_string())?;
        let mut out: Vec<AuditEvent> = guard.iter()
            .filter(|e| e.row_id == row_id && up_to.map(|u| e.hlc <= u).unwrap_or(true))
            .cloned()
            .collect();
        out.sort_by(|a, b| a.hlc.cmp(&b.hlc));
        Ok(out)
    }

    fn events_in_range(&self, start: HLC, end: HLC) -> Result<Vec<AuditEvent>, String> {
        let guard = self.inner.lock().map_err(|e| e.to_string())?;
        let mut out: Vec<AuditEvent> = guard.iter()
            .filter(|e| e.hlc >= start && e.hlc <= end)
            .cloned()
            .collect();
        out.sort_by(|a, b| a.hlc.cmp(&b.hlc));
        Ok(out)
    }

    fn events_for_estate(&self, estate: [u8; 16], start: HLC, end: HLC) -> Result<Vec<AuditEvent>, String> {
        let guard = self.inner.lock().map_err(|e| e.to_string())?;
        let mut out: Vec<AuditEvent> = guard.iter()
            .filter(|e| e.estate_uuid == estate && e.hlc >= start && e.hlc <= end)
            .cloned()
            .collect();
        out.sort_by(|a, b| a.hlc.cmp(&b.hlc));
        Ok(out)
    }

    fn event_count(&self) -> Result<usize, String> {
        Ok(self.inner.lock().map_err(|e| e.to_string())?.len())
    }

    fn truncate(&self) -> Result<(), String> {
        self.inner.lock().map_err(|e| e.to_string())?.clear();
        Ok(())
    }
}

/// Canonical SQL DDL for production schema setup.
pub struct SQLiteTailSchema;

impl SQLiteTailSchema {
    pub const CREATE_TABLE: &'static str = "
        CREATE TABLE IF NOT EXISTS audit_events (
            hlc_packed    INTEGER NOT NULL,
            estate_uuid   BLOB    NOT NULL,
            row_id        BLOB    NOT NULL,
            actor         TEXT    NOT NULL,
            mutation      TEXT    NOT NULL,
            before_state  BLOB,
            after_state   BLOB    NOT NULL,
            fingerprint   BLOB    NOT NULL,
            lattice       TEXT    NOT NULL,
            PRIMARY KEY (estate_uuid, hlc_packed, row_id)
        );";

    pub const CREATE_INDEX_BY_ROW: &'static str =
        "CREATE INDEX IF NOT EXISTS audit_by_row ON audit_events (row_id, hlc_packed);";

    pub const CREATE_INDEX_BY_HLC: &'static str =
        "CREATE INDEX IF NOT EXISTS audit_by_hlc ON audit_events (hlc_packed);";

    pub const PRAGMAS: &'static [&'static str] = &[
        "PRAGMA journal_mode = WAL;",
        "PRAGMA synchronous = NORMAL;",
        "PRAGMA wal_autocheckpoint = 1000;",
    ];

    pub const INSERT_EVENT: &'static str = "
        INSERT INTO audit_events
            (hlc_packed, estate_uuid, row_id, actor, mutation,
             before_state, after_state, fingerprint, lattice)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);";

    pub const SELECT_BY_ROW: &'static str = "
        SELECT hlc_packed, estate_uuid, row_id, actor, mutation,
               before_state, after_state, fingerprint, lattice
        FROM audit_events
        WHERE row_id = ? AND hlc_packed <= ?
        ORDER BY hlc_packed ASC;";

    pub const SELECT_BY_HLC_RANGE: &'static str = "
        SELECT hlc_packed, estate_uuid, row_id, actor, mutation,
               before_state, after_state, fingerprint, lattice
        FROM audit_events
        WHERE hlc_packed BETWEEN ? AND ?
        ORDER BY hlc_packed ASC;";
}
