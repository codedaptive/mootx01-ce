import EngramLib
import Foundation

/// One row of the `vectors` table — the canonical record returned by
/// `VectorStore.vectors(forItemID:)`.
///
/// Lane F rename: `drawerID` → `itemID` (mirrors the `drawer_id` →
/// `item_id` column rename in the vectors table schema, arch spec §4.1).
/// Callers that previously read `drawerID` must use `itemID` going
/// forward. The two names referred to the same concept; the rename
/// removes the naming ambiguity so the field name agrees with the
/// column name.
///
/// Multi-vector: `vectorIndex` (0 for single-vector items; 0..N-1 for
/// ColBERT token vectors). The UNIQUE constraint on the table is now
/// (item_id, vector_index, model_id).
///
/// Per spec I-4, every stored vector is tagged with the model ID and
/// version that produced it.
public struct StoredVector: Sendable, Equatable {
    /// Stable primary key (UUID string assigned by the store on
    /// insert). Survives upserts on the same
    /// `(itemID, vectorIndex, modelID)` triple.
    public let id: String

    /// The owning item this vector indexes (drawer UUID or chunk UUID).
    ///
    /// This field was previously named `drawerID`; renamed to `itemID`
    /// to match the `item_id` column in the vectors table. CorpusKit's
    /// join is also updated: chunk.id.uuidString == vectorStore.itemID.
    public let itemID: String

    /// Position of this vector within the item's vector sequence.
    /// 0 for all single-vector items (the common case). 0..N-1 for
    /// ColBERT multi-token items where each token gets its own row.
    public let vectorIndex: UInt32

    /// The embedding model that produced this engram. Vectors with
    /// different `modelID` values are NOT comparable per spec I-4.
    public let modelID: String

    /// Weights version of `modelID`. A weights update bumps this
    /// string; cross-version comparisons are forbidden.
    public let modelVersion: String

    /// 256-bit engram returned by the embedding model. Non-nil only
    /// for binary-kind payloads (VectorKind.binary). Float and int8
    /// payloads are accessible via VectorStore.getPayload.
    public let engram: Engram

    /// When this row was filed, in storage-fidelity terms — round-
    /// tripped through SQLite's TEXT ISO8601 column. Sub-millisecond
    /// precision is lost in the round trip.
    public let filedAt: Date

    public init(id: String,
                itemID: String,
                vectorIndex: UInt32 = 0,
                modelID: String,
                modelVersion: String,
                engram: Engram,
                filedAt: Date) {
        self.id = id
        self.itemID = itemID
        self.vectorIndex = vectorIndex
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.engram = engram
        self.filedAt = filedAt
    }
}
