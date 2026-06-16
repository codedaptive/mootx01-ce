// VectorRecordKey.swift
//
// The multi-vector key: uniquely identifies one stored vector within
// the `vectors` table.
//
// Lane F foundation type. The key generalizes the previous one-vector-
// per-(drawer, model) constraint to N vectors per item, enabling
// ColBERT token vectors where each token is a separate row. Single-
// vector items use vector_index=0; ColBERT items use 0..N-1.
//
// The key maps exactly to the new UNIQUE(item_id, vector_index, model_id)
// constraint on the `vectors` table (schema migration §4.1). The
// physical column may still be named `drawer_id` on a v1 store; callers
// read it as item_id in code. The rename migration (v1→v2) brings the
// column name into alignment with this field name.
//
// Additive-only rule: if a downstream lane needs a new field on this
// type, it files an FT-1 update to Lane F. No lane adds fields locally.

import Foundation

/// Uniquely identifies one stored vector record in the engine.
///
/// Replaces the old (drawerID, modelID) two-tuple with a three-tuple
/// that supports multi-vector items (ColBERT token vectors). The
/// model_version is carried alongside model_id per spec I-4: vectors
/// produced by different weight versions are not comparable.
///
/// Ordering: lexicographic on (item_id, vector_index, model_id,
/// model_version). This total order is used by the ResidentVectorArray
/// partition index and by the tie-break rules in all search results
/// (§0.3 of the retrieval algorithms reference: smaller id wins —
/// VectorRecordKey.item_id plays the role of "id" at the engine seam).
///
/// Thread-safety: value type, fully Sendable.
public struct VectorRecordKey: Sendable, Equatable, Hashable, Comparable {

    // MARK: - Stored fields

    /// The owning item identifier.
    ///
    /// For LocusKit drawers this is the drawer UUID string. For
    /// CorpusKit chunks this is the chunk UUID string. Callers that
    /// read `drawer_id` from the v1 schema should treat it as item_id
    /// in code; the schema migration renames the column to item_id.
    public let itemID: String

    /// Position of this vector within the item's vector sequence.
    ///
    /// - 0: single-vector items (the common case; all existing rows
    ///      migrate to vector_index=0).
    /// - 0…N-1: ColBERT token vectors. Each token gets its own row
    ///   with the same item_id but a unique vector_index.
    public let vectorIndex: UInt32

    /// Stable identifier of the embedding model that produced this
    /// vector (spec I-4: one model per vector).
    public let modelID: String

    /// Weights version of modelID. Cross-version comparisons are
    /// forbidden; vectors are indexed and retrieved within a fixed
    /// (modelID, modelVersion) pair.
    public let modelVersion: String

    // MARK: - Initialisers

    /// Designated initialiser.
    public init(itemID: String,
                vectorIndex: UInt32,
                modelID: String,
                modelVersion: String) {
        self.itemID = itemID
        self.vectorIndex = vectorIndex
        self.modelID = modelID
        self.modelVersion = modelVersion
    }

    /// Convenience: single-vector item (vectorIndex=0).
    public init(itemID: String, modelID: String, modelVersion: String) {
        self.init(itemID: itemID, vectorIndex: 0,
                  modelID: modelID, modelVersion: modelVersion)
    }

    // MARK: - Comparable

    /// Lexicographic order: (itemID, vectorIndex, modelID, modelVersion).
    ///
    /// This order drives the partition index in ResidentVectorArray and
    /// produces the canonical enumeration order for conformance tests.
    public static func < (lhs: VectorRecordKey, rhs: VectorRecordKey) -> Bool {
        if lhs.itemID != rhs.itemID { return lhs.itemID < rhs.itemID }
        if lhs.vectorIndex != rhs.vectorIndex { return lhs.vectorIndex < rhs.vectorIndex }
        if lhs.modelID != rhs.modelID { return lhs.modelID < rhs.modelID }
        return lhs.modelVersion < rhs.modelVersion
    }
}
