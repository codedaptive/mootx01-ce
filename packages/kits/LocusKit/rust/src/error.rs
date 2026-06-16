//! LocusKit error type. Ports `LocusKitError.swift`.
//!
//! Every failure mode LocusKit surfaces is enumerated here so callers can
//! recover specifically — for example, treating a missing drawer as a
//! routine query miss while still propagating SQLite failures.

/// Errors returned by LocusKit operations.
///
/// Maps exactly to the Swift `LocusKitError` enum. All nine cases are
/// present; associated-value types match the Swift definitions.
///
/// `DisciplineViolation` carries `from` and `to` as `i64` (matching the
/// Swift `Int` raw values) rather than as typed `State` cases so the
/// error does not create a dependency on the adjectives module within
/// the error type itself. Callers that need the typed cases convert via
/// `State::try_from(from)`. This mirrors the Swift comment: "from and
/// to are the State raw values (Int) rather than the enum cases so the
/// error is Equatable without requiring State to be in LocusKitError's
/// dependency set."
#[derive(Debug, PartialEq, Eq)]
pub enum LocusKitError {
    /// SQLite could not open or create the database. The associated
    /// message is produced by `sqlite3_errmsg`, surfaced verbatim so
    /// logs preserve the underlying diagnostic.
    DatabaseUnavailable(String),

    /// No drawer exists for the supplied identifier.
    DrawerNotFound { id: String },

    /// No tunnel exists for the supplied identifier.
    TunnelNotFound { id: String },

    /// No diary entry exists for the supplied identifier.
    DiaryEntryNotFound { id: String },

    /// No recall trace item exists for the supplied identifier.
    /// Thrown by `DrawerStore::mark_recall_trace_used` when the target row
    /// is absent — callers can treat this as a stale reward signal.
    RecallTraceItemNotFound { id: String },

    /// A SQLite call returned a non-OK result code. The associated
    /// string is the message produced by `sqlite3_errmsg`.
    SqliteError(String),

    /// Schema version on disk is newer than this build expects.
    /// Reserved for the migration workflow; no current mission throws
    /// this case, but it is part of the conformance surface.
    /// Swift declares these as `Int`, which is i64-width on Apple
    /// Silicon, so the wire semantics match across the two legs.
    SchemaTooNew { found: i64, expected: i64 },

    /// Drawer, tunnel, or diary content failed validation. The
    /// associated message names the rule that was violated (for
    /// example, "wing must not be empty"). The message is the
    /// contract — tests assert on it.
    InvalidContent(String),

    /// A verb call or mutation would violate a substrate invariant —
    /// an illegal state transition (§ 6.2), a forbidden combination
    /// (I-3), or an expunge without confirmation.
    ///
    /// `from` and `to` are `State` raw values as `i64`. Callers that
    /// need the typed cases convert via `State::try_from(value)`.
    DisciplineViolation { from: i64, to: i64, reason: String },

    /// A stored TEXT value in a required column could not be parsed
    /// to its declared type (UUID or ISO 8601 timestamp). Parity with
    /// `StorageError::CorruptStoredValue` in PersistenceKit (commit
    /// 0ff08d93) and Swift `LocusKitError.corruptStoredValue`.
    /// Returned instead of silently substituting a default
    /// (new random UUID, epoch-0 date) so callers know their stored
    /// data is corrupt and cannot be trusted.
    ///
    /// `table`: LocusKit table name (e.g. "drawers").
    /// `column`: the column whose stored text was unparseable.
    /// `stored_text`: the raw string that failed to parse, reproduced
    /// verbatim for log diagnosis.
    CorruptStoredValue {
        table: String,
        column: String,
        stored_text: String,
    },

    /// A verb call targets a feature that is not yet implemented in
    /// this version of LocusKit. The associated message names the
    /// feature so callers can distinguish clearly between "not found"
    /// (data missing) and "not supported" (code missing). Returned
    /// instead of silently producing a sentinel or stub result per
    /// the P1 mandate: fail-loud unsupported is required when the
    /// producing data does not exist. Mirrors Swift
    /// `LocusKitError.notSupported`.
    NotSupported(String),
}

impl std::fmt::Display for LocusKitError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LocusKitError::DatabaseUnavailable(msg) => {
                write!(f, "DatabaseUnavailable: {}", msg)
            }
            LocusKitError::DrawerNotFound { id } => {
                write!(f, "DrawerNotFound: id='{}'", id)
            }
            LocusKitError::TunnelNotFound { id } => {
                write!(f, "TunnelNotFound: id='{}'", id)
            }
            LocusKitError::DiaryEntryNotFound { id } => {
                write!(f, "DiaryEntryNotFound: id='{}'", id)
            }
            LocusKitError::RecallTraceItemNotFound { id } => {
                write!(f, "RecallTraceItemNotFound: id='{}'", id)
            }
            LocusKitError::SqliteError(msg) => {
                write!(f, "SqliteError: {}", msg)
            }
            LocusKitError::SchemaTooNew { found, expected } => {
                write!(f, "SchemaTooNew: found={} expected={}", found, expected)
            }
            LocusKitError::InvalidContent(msg) => {
                write!(f, "InvalidContent: {}", msg)
            }
            LocusKitError::DisciplineViolation { from, to, reason } => {
                write!(
                    f,
                    "DisciplineViolation: from={} to={} reason='{}'",
                    from, to, reason
                )
            }
            LocusKitError::CorruptStoredValue {
                table,
                column,
                stored_text,
            } => write!(
                f,
                "CorruptStoredValue: table='{}' column='{}' stored_text='{}'",
                table, column, stored_text
            ),
            LocusKitError::NotSupported(msg) => {
                write!(f, "NotSupported: {}", msg)
            }
        }
    }
}

impl std::error::Error for LocusKitError {}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn database_unavailable_equality() {
        let a = LocusKitError::DatabaseUnavailable("disk full".to_string());
        let b = LocusKitError::DatabaseUnavailable("disk full".to_string());
        assert_eq!(a, b);
    }

    #[test]
    fn drawer_not_found() {
        let err = LocusKitError::DrawerNotFound {
            id: "d-001".to_string(),
        };
        assert_eq!(
            err,
            LocusKitError::DrawerNotFound {
                id: "d-001".to_string()
            }
        );
    }

    #[test]
    fn tunnel_not_found() {
        let err = LocusKitError::TunnelNotFound {
            id: "t-001".to_string(),
        };
        assert_eq!(
            err,
            LocusKitError::TunnelNotFound {
                id: "t-001".to_string()
            }
        );
    }

    #[test]
    fn diary_entry_not_found() {
        let err = LocusKitError::DiaryEntryNotFound {
            id: "de-001".to_string(),
        };
        assert_eq!(
            err,
            LocusKitError::DiaryEntryNotFound {
                id: "de-001".to_string()
            }
        );
    }

    #[test]
    fn schema_too_new() {
        let err = LocusKitError::SchemaTooNew {
            found: 5,
            expected: 3,
        };
        match &err {
            LocusKitError::SchemaTooNew { found, expected } => {
                assert_eq!(*found, 5);
                assert_eq!(*expected, 3);
            }
            _ => panic!("wrong variant"),
        }
    }

    #[test]
    fn invalid_content() {
        let err = LocusKitError::InvalidContent("wing must not be empty".to_string());
        assert_eq!(
            err,
            LocusKitError::InvalidContent("wing must not be empty".to_string())
        );
    }

    #[test]
    fn discipline_violation_carries_raw_values() {
        // from/to are i64 raw values of the State enum, not typed State cases.
        // This matches the Swift comment: error is Equatable without requiring
        // State in LocusKitError's dependency set.
        let err = LocusKitError::DisciplineViolation {
            from: 9, // tombstoned raw value
            to: 0,   // active raw value
            reason: "terminal rows cannot transition".to_string(),
        };
        match &err {
            LocusKitError::DisciplineViolation { from, to, reason } => {
                assert_eq!(*from, 9);
                assert_eq!(*to, 0);
                assert_eq!(reason, "terminal rows cannot transition");
            }
            _ => panic!("wrong variant"),
        }
    }

    #[test]
    fn all_eleven_cases_are_distinct() {
        // Confirm no two different cases compare equal — basic sanity check.
        let variants: Vec<LocusKitError> = vec![
            LocusKitError::DatabaseUnavailable("x".to_string()),
            LocusKitError::DrawerNotFound {
                id: "x".to_string(),
            },
            LocusKitError::TunnelNotFound {
                id: "x".to_string(),
            },
            LocusKitError::DiaryEntryNotFound {
                id: "x".to_string(),
            },
            LocusKitError::RecallTraceItemNotFound {
                id: "x".to_string(),
            },
            LocusKitError::SqliteError("x".to_string()),
            LocusKitError::SchemaTooNew {
                found: 1,
                expected: 0,
            },
            LocusKitError::InvalidContent("x".to_string()),
            LocusKitError::DisciplineViolation {
                from: 0,
                to: 1,
                reason: "x".to_string(),
            },
            LocusKitError::CorruptStoredValue {
                table: "drawers".to_string(),
                column: "lineageID".to_string(),
                stored_text: "NOT-A-UUID".to_string(),
            },
            LocusKitError::NotSupported("feature not yet implemented".to_string()),
        ];
        assert_eq!(variants.len(), 11);
        for (i, a) in variants.iter().enumerate() {
            for (j, b) in variants.iter().enumerate() {
                if i == j {
                    assert_eq!(a, b, "variant {i} should equal itself");
                } else {
                    assert_ne!(a, b, "variant {i} should not equal variant {j}");
                }
            }
        }
    }
}
