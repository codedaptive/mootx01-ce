import EngramLib
import Foundation

/// One row of the `vectors` table — the canonical record returned by
/// `VectorStore.vectors(forDrawerID:)`.
///
/// Per spec I-4, every stored vector is tagged with the model ID and
/// version that produced it. The `id` field is the row's stable
/// primary key (one row per `(drawerID, modelID)` pair after upsert;
/// the kit assigns the `id` on insert).
public struct StoredVector: Sendable, Equatable {
    /// Stable primary key (UUID string assigned by the store on
    /// insert). Survives upserts on the same `(drawerID, modelID)`
    /// pair — the row is updated in place rather than replaced.
    public let id: String

    /// The drawer this vector indexes.
    public let drawerID: String

    /// The embedding model that produced this engram. Vectors with
    /// different `modelID` values are NOT comparable per spec I-4.
    public let modelID: String

    /// Weights version of `modelID`. A weights update bumps this
    /// string; cross-version comparisons are forbidden.
    public let modelVersion: String

    /// 256-bit engram returned by the embedding model.
    public let engram: Engram

    /// When this row was filed, in storage-fidelity terms — round-
    /// tripped through SQLite's TEXT ISO8601 column. Sub-millisecond
    /// precision is lost in the round trip.
    public let filedAt: Date

    public init(id: String,
                drawerID: String,
                modelID: String,
                modelVersion: String,
                engram: Engram,
                filedAt: Date) {
        self.id = id
        self.drawerID = drawerID
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.engram = engram
        self.filedAt = filedAt
    }
}
