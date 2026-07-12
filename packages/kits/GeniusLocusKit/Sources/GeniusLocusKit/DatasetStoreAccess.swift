// DatasetStoreAccess.swift
// GeniusLocusKit
//
// Public DatasetStore accessor for callers outside the GeniusLocusKit module
// (specifically AriaMcpKit/DatasetTools — MX-TAB-7).
//
// Why a separate file (not added to an existing source):
//   The concurrent-agent constraint on MX-TAB-4/5 bars modification of
//   existing GeniusLocusKit sources while that agent's work is in flight.
//   This extension adds exactly one new public method and touches no
//   existing code path; a new file avoids any diff collision.
//
// Design note — why DatasetStore is not on Estate:
//   LocusKit.Estate is the actor owning the drawer/tunnel/KG layer.
//   Dataset tables are raw backend tables managed by DatasetStore directly
//   BELOW the belief layer — they are not drawers, tunnels, or KG facts.
//   Surfacing DatasetStore through the Estate would blur the layer boundary.
//   Instead, the GeniusLocusKit coordinator (which already holds the storage
//   registry) is the correct seam: it knows which Storage backs each handle
//   and can vend the DatasetStore from there.

import Foundation
import PersistenceKit

public extension GeniusLocusKit {

    /// Return the DatasetStore backing the given estate.
    ///
    /// The caller uses the returned store to create, populate, query, and
    /// drop dataset tables. Handle lifecycle (belief state, bitmaps, content
    /// JSON) is managed through `estate(for:)` and LocusKit verbs — the
    /// DatasetStore operates at the raw-table layer below belief.
    ///
    /// - Throws:
    ///   - `GeniusLocusKitError.estateNotOpen` when `handle` is not in
    ///     the coordinator registry.
    ///   - `StorageError.featureGated("datasetStore")` when the estate's
    ///     Storage backend does not implement the DatasetStore surface
    ///     (e.g. a deferred Postgres backend or an unconforming third-party
    ///     Storage). The caller is responsible for propagating this as a
    ///     clear tool error, not an internal crash.
    func datasetStore(for handle: EstateHandle) throws -> any DatasetStore {
        guard let storage = storages[handle] else {
            throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
        }
        // `storage.datasetStore` is throwing at the protocol level because the
        // default protocol-extension implementation throws `featureGated`.
        // Concrete backends (SQLiteStorage, InMemoryStorage) expose it as a
        // stored non-throwing property, but the protocol erased `any Storage`
        // requires `try`.
        return try storage.datasetStore
    }
}
