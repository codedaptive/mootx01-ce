//! RecallRating — one drawer's Bradley-Terry rating from the end-of-day
//! tournament. Ports `RecallRating.swift`.
//!
//! Persisted in the `recall_ratings` table (`drawer_id TEXT PRIMARY KEY,
//! rating REAL, contests INTEGER, updated_at TEXT`). `rating` is the
//! estimator's strength for the drawer; `contests` is the running count of
//! preference observations the drawer has taken part in across every
//! tournament pass; `updated_at` is the tournament clock at the last write,
//! stored as ISO8601 TEXT per the fleet date-storage rule.

use persistence_kit::{ColumnDeclaration, SchemaDeclaration, TableDeclaration};

/// Name of the rating ledger table.
pub const RECALL_RATINGS_TABLE: &str = "recall_ratings";

/// One drawer's Bradley-Terry rating from the end-of-day tournament.
#[derive(Debug, Clone, PartialEq)]
pub struct RecallRating {
    /// The rated drawer's identifier (`recall_ratings.drawer_id`).
    pub drawer_id: String,

    /// Bradley-Terry strength for the drawer.
    pub rating: f64,

    /// Number of preference observations the drawer has appeared in.
    pub contests: i64,

    /// Clock of the tournament pass that last wrote this row, as an
    /// ISO8601 string (TEXT in SQLite).
    pub updated_at: String,
}

impl RecallRating {
    /// Create a rating row. `updated_at` is an ISO8601 string.
    pub fn new(
        drawer_id: impl Into<String>,
        rating: f64,
        contests: i64,
        updated_at: impl Into<String>,
    ) -> Self {
        Self {
            drawer_id: drawer_id.into(),
            rating,
            contests,
            updated_at: updated_at.into(),
        }
    }
}

/// The rating ledger's schema, declared through PersistenceKit's schema
/// ladder so the DDL is identical on every backend. The name, version and
/// column set match the declaration the 1.8 → 1.9 estate-format capsule
/// applies on populated estates, so `migrate` is a no-op once either has
/// created the table.
pub fn recall_ratings_schema() -> SchemaDeclaration {
    SchemaDeclaration::new(
        "GLKRecallRatings",
        1,
        vec![TableDeclaration::new(
            RECALL_RATINGS_TABLE,
            vec![
                ColumnDeclaration::text("drawer_id"),
                ColumnDeclaration::float("rating"),
                ColumnDeclaration::int("contests"),
                ColumnDeclaration::timestamp("updated_at"),
            ],
            vec!["drawer_id".to_string()],
        )],
    )
}
