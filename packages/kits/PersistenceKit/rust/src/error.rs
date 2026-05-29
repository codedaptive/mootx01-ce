//! Errors. Mirror of Swift's StorageError.

use crate::types::ColumnType;

#[derive(Debug, Clone, PartialEq)]
pub enum StorageError {
    BackendUnavailable { reason: String },
    SchemaMismatch { expected: i32, actual: i32 },
    MigrationFailed { version: i32, reason: String },
    ConstraintViolation { detail: String },
    PoolExhausted { timeout_secs: f64 },
    TransactionConflict { detail: String },
    TypeMismatch { column: String, expected: ColumnType, actual: String },
    RowNotFound { table: String, key: String },
    DuplicateKey { table: String, key: String },
    InvalidQuery { detail: String },
    AppendOnlyViolation { table: String },
    BackendError { underlying: String },
}

impl std::fmt::Display for StorageError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            StorageError::BackendUnavailable { reason } => write!(f, "backend unavailable: {}", reason),
            StorageError::SchemaMismatch { expected, actual } => write!(f, "schema mismatch: expected v{}, got v{}", expected, actual),
            StorageError::MigrationFailed { version, reason } => write!(f, "migration to v{} failed: {}", version, reason),
            StorageError::ConstraintViolation { detail } => write!(f, "constraint violation: {}", detail),
            StorageError::PoolExhausted { timeout_secs } => write!(f, "connection pool exhausted after {}s", timeout_secs),
            StorageError::TransactionConflict { detail } => write!(f, "transaction conflict: {}", detail),
            StorageError::TypeMismatch { column, expected, actual } => write!(f, "type mismatch on column {}: expected {:?}, got {}", column, expected, actual),
            StorageError::RowNotFound { table, key } => write!(f, "row not found: {}.{}", table, key),
            StorageError::DuplicateKey { table, key } => write!(f, "duplicate key in {}: {}", table, key),
            StorageError::InvalidQuery { detail } => write!(f, "invalid query: {}", detail),
            StorageError::AppendOnlyViolation { table } => write!(f, "table {} is append-only", table),
            StorageError::BackendError { underlying } => write!(f, "backend error: {}", underlying),
        }
    }
}

impl std::error::Error for StorageError {}

pub type StorageResult<T> = Result<T, StorageError>;
