import Foundation
import LocusKit
import SubstrateTypes

/// Handle-scoped estate reads for access surfaces.
///
/// ARIA and the other consumers above GeniusLocusKit address an estate by
/// `EstateHandle` and never hold the `LocusKit.Estate` behind it: GLK resolves
/// the handle, delegates to the one `Estate` method the read needs, and returns
/// the result (the B-1 pattern `recallTunnels` and the dreaming reads follow).
/// Each method here mirrors an `Estate` method by name and argument labels,
/// with the handle as the leading `in:` argument, so a consumer that used to
/// call `estate.getDrawers(ids:hydrationLevel:)` calls
/// `kit.getDrawers(in: handle, ids:hydrationLevel:)` and nothing else changes.
///
/// Every method throws `GeniusLocusKitError.estateNotOpen` for a stale handle.
public extension GeniusLocusKit {

    /// Summarize rooms in the optional wing, retaining the ordering and counts
    /// from `Estate.listRooms(in:)`. Applies no caller sensitivity filter.
    func listRooms(in handle: EstateHandle, wing: String? = nil) async throws -> [RoomSummary] {
        let estate = try estate(for: handle)
        return try await estate.listRooms(in: wing)
    }

    /// The row's sealed audit events in HLC order, or an empty array when no
    /// events exist. Delegates to `Estate.auditTrail(rowID:)` without applying
    /// caller sensitivity filtering.
    func auditTrail(in handle: EstateHandle, rowID: RowID) async throws -> [AuditEvent] {
        let estate = try estate(for: handle)
        return try await estate.auditTrail(rowID: rowID)
    }

    /// Every drawer in the addressed estate at the given hydration level, up
    /// to `limit` rows; `nil` reads the whole estate. Delegates to
    /// `Estate.allDrawers(hydrationLevel:limit:)`.
    func allDrawers(
        in handle: EstateHandle,
        hydrationLevel: HydrationLevel,
        limit: Int?
    ) async throws -> [Drawer] {
        let estate = try estate(for: handle)
        return try await estate.allDrawers(hydrationLevel: hydrationLevel, limit: limit)
    }

    /// The single drawer with this storage row id, or nil when the estate has
    /// no such row. Tombstoned rows are returned like any other; a caller that
    /// wants believed rows only filters on the result. Delegates to
    /// `Estate.drawerById(rowID:)`.
    func drawerById(in handle: EstateHandle, rowID: String) async throws -> Drawer? {
        let estate = try estate(for: handle)
        return try await estate.drawerById(rowID: rowID)
    }

    /// The drawers whose storage ids are in `ids`, at the given hydration
    /// level, with no frame applied. Callers that need the sensitivity gate
    /// use `getDrawers(in:ids:matchingFrame:hydrationLevel:)` instead.
    /// Delegates to `Estate.getDrawers(ids:hydrationLevel:)`.
    func getDrawers(
        in handle: EstateHandle,
        ids: [String],
        hydrationLevel: HydrationLevel
    ) async throws -> [Drawer] {
        let estate = try estate(for: handle)
        return try await estate.getDrawers(ids: ids, hydrationLevel: hydrationLevel)
    }

    /// The drawers whose storage ids are in `ids`, split into the rows the
    /// frame admits and the rows it withholds. Delegates to
    /// `Estate.getDrawers(ids:matchingFrame:hydrationLevel:preservePhysicalUUIDSpellings:)`.
    func getDrawers(
        in handle: EstateHandle,
        ids: [String],
        matchingFrame frame: RecallFrame,
        hydrationLevel: HydrationLevel,
        preservePhysicalUUIDSpellings: Bool = false
    ) async throws -> FrameFilteredDrawers {
        let estate = try estate(for: handle)
        return try await estate.getDrawers(
            ids: ids,
            matchingFrame: frame,
            hydrationLevel: hydrationLevel,
            preservePhysicalUUIDSpellings: preservePhysicalUUIDSpellings)
    }

    /// The non-tombstoned tunnel with storage id `id`, or `nil`. Delegates to
    /// `Estate.getTunnel(id:)`.
    func getTunnel(in handle: EstateHandle, id: String) async throws -> Tunnel? {
        let estate = try estate(for: handle)
        return try await estate.getTunnel(id: id)
    }

    /// Confirmed-active, non-tombstoned tunnels whose source drawer is
    /// `drawerId`. The lifecycle filter runs at the SQL layer. Delegates to
    /// `Estate.activeTunnelsFrom(drawerId:)`.
    func activeTunnels(in handle: EstateHandle, from drawerId: String) async throws -> [Tunnel] {
        let estate = try estate(for: handle)
        return try await estate.activeTunnelsFrom(drawerId: drawerId)
    }

    /// Confirmed-active, non-tombstoned tunnels whose target drawer is
    /// `drawerId`. Delegates to `Estate.activeTunnelsTo(drawerId:)`.
    func activeTunnels(in handle: EstateHandle, to drawerId: String) async throws -> [Tunnel] {
        let estate = try estate(for: handle)
        return try await estate.activeTunnelsTo(drawerId: drawerId)
    }

    /// KG facts filtered by exact subject and/or exact source drawer id at the
    /// SQL layer; both `nil` reads every fact. Unlike `recallKGFacts(_:)` this
    /// applies no sensitivity ceiling, so callers gate the result themselves.
    /// Delegates to `Estate.kgFacts(subjectEq:sourceDrawerIDEq:)`.
    func kgFacts(
        in handle: EstateHandle,
        subjectEq: String? = nil,
        sourceDrawerIDEq: String? = nil
    ) async throws -> [KGFact] {
        let estate = try estate(for: handle)
        return try await estate.kgFacts(subjectEq: subjectEq, sourceDrawerIDEq: sourceDrawerIDEq)
    }

    /// The estate-level meta value stored under `key`, or `nil`. Delegates to
    /// `Estate.meta(key:)`.
    func meta(in handle: EstateHandle, key: String) async throws -> String? {
        let estate = try estate(for: handle)
        return try await estate.meta(key: key)
    }

    /// The active dataset-handle drawer for `datasetId`. Delegates to
    /// `Estate.resolveActiveDatasetHandle(datasetId:)`, which throws when no
    /// active handle exists.
    func resolveActiveDatasetHandle(in handle: EstateHandle, datasetId: UUID) async throws -> Drawer {
        let estate = try estate(for: handle)
        return try await estate.resolveActiveDatasetHandle(datasetId: datasetId)
    }

    /// Drawers still owed a subject by the active subject producer. Delegates
    /// to `Estate.countSubjectDebt()`.
    func countSubjectDebt(in handle: EstateHandle) async throws -> Int {
        let estate = try estate(for: handle)
        return try await estate.countSubjectDebt()
    }
}
