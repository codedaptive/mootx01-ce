import Foundation
import PersistenceKit

/// One drawer's Bradley-Terry rating from the end-of-day tournament.
///
/// Persisted in the `recall_ratings` table (`drawer_id TEXT PRIMARY KEY,
/// rating REAL, contests INTEGER, updated_at TEXT`). `rating` is the
/// estimator's log-strength for the drawer; `contests` is the running count
/// of preference observations the drawer has taken part in across every
/// tournament pass; `updatedAt` is the tournament clock at the last write,
/// stored as ISO8601 TEXT per the fleet date-storage rule.
public struct RecallRating: Sendable, Equatable {
    /// The rated drawer's identifier (`recall_ratings.drawer_id`).
    public let drawerID: String

    /// Bradley-Terry log-strength for the drawer.
    public var rating: Double

    /// Number of preference observations the drawer has appeared in.
    public var contests: Int

    /// Clock of the tournament pass that last wrote this row.
    public var updatedAt: Date

    /// Designated initializer.
    public init(drawerID: String, rating: Double, contests: Int, updatedAt: Date) {
        self.drawerID = drawerID
        self.rating = rating
        self.contests = contests
        self.updatedAt = updatedAt
    }
}

public extension RecallRating {
    /// The rating ledger's table name.
    static let tableName = "recall_ratings"

    /// The rating ledger's schema, declared through PersistenceKit's schema
    /// ladder so the DDL is identical on every backend. This is the ONE
    /// declaration of `recall_ratings` in the Swift port: `DrawerStore`
    /// applies it on first use (a fresh estate is stamped at the current
    /// format without running the migration capsules, so no capsule ever
    /// creates the table there) and the 1.8 → 1.9 estate-format capsule
    /// applies the same value on populated estates. Same kit id, version
    /// and column set on both paths, so `migrate(to:)` is a no-op once
    /// either has created the table. Mirrors Rust
    /// `recall_rating::recall_ratings_schema()`.
    static let schema = SchemaDeclaration(
        kitID: "GLKRecallRatings",
        version: 1,
        tables: [
            TableDeclaration(
                name: tableName,
                columns: [
                    .text("drawer_id", nullable: false),
                    .float("rating", nullable: false),
                    .int("contests", nullable: false),
                    .timestamp("updated_at", nullable: false),
                ],
                primaryKey: ["drawer_id"]
            )
        ]
    )
}
