//! Errors. Mirror of Swift's StorageError.

use crate::types::ColumnType;

#[derive(Debug, Clone, PartialEq)]
pub enum StorageError {
    BackendUnavailable {
        reason: String,
    },
    SchemaMismatch {
        expected: i32,
        actual: i32,
    },
    MigrationFailed {
        version: i32,
        reason: String,
    },
    ConstraintViolation {
        detail: String,
    },
    PoolExhausted {
        timeout_secs: f64,
    },
    TransactionConflict {
        detail: String,
    },
    TypeMismatch {
        column: String,
        expected: ColumnType,
        actual: String,
    },
    RowNotFound {
        table: String,
        key: String,
    },
    DuplicateKey {
        table: String,
        key: String,
    },
    InvalidQuery {
        detail: String,
    },
    AppendOnlyViolation {
        table: String,
    },
    BackendError {
        underlying: String,
    },
    /// A stored value could not be parsed back to its declared type. The
    /// `stored_text` field carries the raw string from SQLite for diagnosis.
    /// Thrown instead of silently substituting a default (e.g. Uuid::nil()
    /// or timestamp 0) so callers know their data is corrupt.
    CorruptStoredValue {
        table: String,
        column: String,
        stored_text: String,
    },
    /// The supplied `EstateConfiguration` contains a value that is invalid for
    /// the current platform or runtime. For example, selecting `NlTagger` on
    /// a non-Apple platform (where `NaturalLanguage` is unavailable) produces
    /// this error at configuration validation time. Fail-closed: an invalid
    /// configuration is rejected before any storage is opened. Mirrors
    /// Swift's `StorageError.invalidConfiguration(reason:)`.
    InvalidConfiguration {
        reason: String,
    },
    /// A storage surface exists but is gated off until prerequisite missions
    /// land. The `feature` string names the gate so the caller knows which
    /// capability is unavailable and why.
    ///
    /// The as-of query gate (ADR-017 §17) stays closed until NT-L4
    /// (lineage-wide expunge) and NT-P3 (erasure overlay) merge, preventing
    /// the governance defect where an as-of read resurfaces un-erased payload
    /// from a superseded lineage version. Mirrors
    /// Swift's `StorageError.featureGated(feature:)`.
    FeatureGated {
        feature: String,
    },
    /// A caller-supplied SQL identifier (column name, table name) contains
    /// characters outside the safe set `[A-Za-z_][A-Za-z0-9_]*`. Allowing
    /// arbitrary identifiers into a dynamically-constructed SELECT list is a
    /// SQL-injection vector even when the name is double-quoted, because a
    /// name containing `"` can break out of the quoting and alter the query.
    /// Planned hardening landed 2026-06-28 (SECFIX-WS2-PK).
    InvalidIdentifier {
        name: String,
    },
}

impl std::fmt::Display for StorageError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            StorageError::BackendUnavailable { reason } => {
                write!(f, "backend unavailable: {}", reason)
            }
            StorageError::SchemaMismatch { expected, actual } => write!(
                f,
                "schema mismatch: expected v{}, got v{}",
                expected, actual
            ),
            StorageError::MigrationFailed { version, reason } => {
                write!(f, "migration to v{} failed: {}", version, reason)
            }
            StorageError::ConstraintViolation { detail } => {
                write!(f, "constraint violation: {}", detail)
            }
            StorageError::PoolExhausted { timeout_secs } => {
                write!(f, "connection pool exhausted after {}s", timeout_secs)
            }
            StorageError::TransactionConflict { detail } => {
                write!(f, "transaction conflict: {}", detail)
            }
            StorageError::TypeMismatch {
                column,
                expected,
                actual,
            } => write!(
                f,
                "type mismatch on column {}: expected {:?}, got {}",
                column, expected, actual
            ),
            StorageError::RowNotFound { table, key } => {
                write!(f, "row not found: {}.{}", table, key)
            }
            StorageError::DuplicateKey { table, key } => {
                write!(f, "duplicate key in {}: {}", table, key)
            }
            StorageError::InvalidQuery { detail } => write!(f, "invalid query: {}", detail),
            StorageError::AppendOnlyViolation { table } => {
                write!(f, "table {} is append-only", table)
            }
            StorageError::BackendError { underlying } => write!(f, "backend error: {}", underlying),
            StorageError::CorruptStoredValue { table, column, stored_text } => write!(
                f,
                "corrupt stored value in {}.{}: cannot parse {:?}",
                table, column, stored_text
            ),
            StorageError::InvalidConfiguration { reason } => {
                write!(f, "invalid estate configuration: {}", reason)
            }
            StorageError::FeatureGated { feature } => {
                write!(f, "feature gated: {} is not yet enabled", feature)
            }
            StorageError::InvalidIdentifier { name } => {
                write!(f, "invalid SQL identifier: {:?} — only [A-Za-z_][A-Za-z0-9_]* is allowed", name)
            }
        }
    }
}

impl std::error::Error for StorageError {}

pub type StorageResult<T> = Result<T, StorageError>;

/// Validate a caller-supplied SQL identifier (column or table name).
///
/// Accepts only names matching `[A-Za-z_][A-Za-z0-9_]*`. Double-quoting is
/// insufficient protection when the name contains `"` — the quote character
/// escapes the double-quote delimiter and can alter a dynamically-constructed
/// SQL string. Reject before embedding any name in a SELECT list or FROM clause.
///
/// Called by `SqliteRowStore::query_projected` and `PostgresRowStore::query_projected`
/// to guard caller-supplied column names (SECFIX-WS2-PK F1).
pub fn validate_sql_identifier(name: &str) -> StorageResult<()> {
    let mut chars = name.chars();
    match chars.next() {
        None => return Err(StorageError::InvalidIdentifier { name: name.to_string() }),
        Some(c) if !c.is_ascii_alphabetic() && c != '_' => {
            return Err(StorageError::InvalidIdentifier { name: name.to_string() });
        }
        _ => {}
    }
    for c in chars {
        if !c.is_ascii_alphanumeric() && c != '_' {
            return Err(StorageError::InvalidIdentifier { name: name.to_string() });
        }
    }
    Ok(())
}
