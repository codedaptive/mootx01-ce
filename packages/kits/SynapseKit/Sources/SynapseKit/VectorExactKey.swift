// VectorExactKey.swift
//
// Exact logical row address for scoped vector mutation
// (GLK shared-content 1.1, P0).
//
// A VectorExactKey names one logical row position in the `vectors` table —
// the (item_id, vector_index, model_id) triple the schema's UNIQUE
// constraint keys. It deliberately EXCLUDES modelVersion: a version bump
// replaces the row at the same logical position, so scoped deletion must
// clear every version stored there or a stale-version row would survive.
//
// This is the address unit for `VectorStore.deleteVectors(keys:)` and
// `VectorStore.reconcileModelVectors(modelID:expected:)` — the exact-key
// batch APIs the shared-content migration uses so CorpusKit never runs an
// unscoped model-wide teardown against shared GLK storage.

import Foundation

/// One logical vector row address: (itemID, vectorIndex, modelID).
public struct VectorExactKey: Sendable, Hashable, Comparable {
    /// The owning item identifier (a Drawer ID in the GLK context; a legacy
    /// chunk UUID string in pre-1.1 Corpus estates).
    public let itemID: String
    /// Position of the vector within the item's vector sequence
    /// (0 = binary engram lane, 1 = dense float lane by CorpusKit convention).
    public let vectorIndex: Int
    /// Stable identifier of the embedding model that produced the vector.
    public let modelID: String

    public init(itemID: String, vectorIndex: Int, modelID: String) {
        self.itemID = itemID
        self.vectorIndex = vectorIndex
        self.modelID = modelID
    }

    /// Deterministic total order — (modelID, itemID, vectorIndex) — for
    /// stable iteration in migration inventories and tests.
    public static func < (lhs: VectorExactKey, rhs: VectorExactKey) -> Bool {
        if lhs.modelID != rhs.modelID { return lhs.modelID < rhs.modelID }
        if lhs.itemID != rhs.itemID { return lhs.itemID < rhs.itemID }
        return lhs.vectorIndex < rhs.vectorIndex
    }
}
