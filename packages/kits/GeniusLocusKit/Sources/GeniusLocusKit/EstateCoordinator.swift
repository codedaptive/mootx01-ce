import Foundation
import OSLog
import LocusKit
import PersistenceKit

/// The multi-estate coordinator surface on `GeniusLocusKit`.
///
/// Open admits an estate into the kit's registry by composing
/// `LocusKit.Estate.open` over a caller-supplied storage backend, then
/// issuing an `EstateHandle` that the caller uses to address that
/// estate from then on. Close removes the entry; list reports what is
/// currently open; `estate(for:)` reaches the live `LocusKit.Estate`
/// actor for a handle so callers can issue verbs through the existing
/// LocusKit surface until the unified verb surface lands in GLK-02.
///
/// Estates are isolated by design. A write into estate A through its
/// handle is invisible to estate B because each estate has its own
/// `Storage` instance with its own SQLite file; the coordinator never
/// shares storage across estates and the registry is keyed by handle
/// so cross-estate lookups are impossible by construction.
///
/// Declared as an `extension` on `GeniusLocusKit` (the actor lives in
/// `GeniusLocusKit.swift`) so this file owns the coordinator surface
/// while the actor type and registry stay in their own file. The
/// extension reaches the actor's internal `registry` property.
public extension GeniusLocusKit {

    /// Logger reused across coordinator operations. Read through the
    /// kit's static logger so the subsystem and category stay
    /// fleet-standard ("com.mootx01.kit" / "GeniusLocusKit").
    private static var log: Logger {
        Logger(subsystem: "com.mootx01.kit", category: "GeniusLocusKit")
    }

    // MARK: - open

    /// Open an estate and admit it into the kit's registry.
    ///
    /// Composes `LocusKit.Estate.open(storage:owner:)` against the
    /// supplied `Storage`, captures the manifest snapshot the
    /// coordinator needs (UUID, zoom window, name), and issues an
    /// `EstateHandle` keyed on the estate's manifest UUID.
    ///
    /// Refuses to admit an estate whose UUID is already in the
    /// registry: per spec § 7.7 estate UUIDs are immutable, so a
    /// duplicate is almost always the same database file being opened
    /// twice. The second open is rejected explicitly rather than
    /// silently shadowing the live entry.
    ///
    /// - Parameters:
    ///   - storage: an already-constructed storage backend (typically
    ///     a `PersistenceKitSQLite.SQLiteStorage` or an
    ///     `PersistenceKitInMemory.InMemoryStorage`). The caller owns its
    ///     lifecycle; closing the handle does not close the storage.
    ///   - owner: credentials for the estate's owner. Forwarded to
    ///     `LocusKit.Estate.open` unchanged.
    /// - Returns: a fresh `EstateHandle` the caller uses to address
    ///   this estate.
    /// - Throws:
    ///   - `.underlyingEstateFailure` if `LocusKit.Estate.open` fails.
    ///   - `.invalidManifest` if the manifest the kit reads back from
    ///     the opened estate is malformed (invalid UUID, inverted zoom
    ///     window).
    ///   - `.duplicateEstate` if an estate with this UUID is already
    ///     in the registry.
    func open(
        storage: any Storage,
        owner: OwnerCredentials
    ) async throws -> EstateHandle {
        let estate: LocusKit.Estate
        do {
            estate = try await LocusKit.Estate.open(storage: storage, owner: owner)
        } catch {
            throw GeniusLocusKitError.underlyingEstateFailure(reason: "\(error)")
        }
        let manifest = try await readManifest(estate: estate)
        let handle = try EstateHandle(manifest: manifest)
        if registry[handle] != nil {
            throw GeniusLocusKitError.duplicateEstate(estateUUID: handle.estateUUID)
        }
        registry[handle] = estate
        // Retain the caller's storage so the grant surface (GRT-01) can
        // back a GrantStore with the estate's own database. The grant
        // store and scope vault are built lazily on first use.
        storages[handle] = storage
        // Mint an empty unified audit log for the estate (GLK-03). The
        // log is fed lazily via feedAuditLog(for:); it starts empty so a
        // verify pass before any feed reports a clean, zero-entry chain.
        auditLogs[handle] = UnifiedAuditLog()
        Self.log.info("opened estate \(handle.estateUUID, privacy: .public)")
        return handle
    }

    /// Read the manifest from an opened LocusKit estate, translating
    /// any thrown error to `.underlyingEstateFailure`. Kept private
    /// because manifest reading is an internal detail of `open`; the
    /// public surface returns the cached fields on `EstateHandle`.
    private func readManifest(estate: LocusKit.Estate) async throws -> ManifestValues {
        do {
            return try await estate.manifest
        } catch {
            throw GeniusLocusKitError.underlyingEstateFailure(reason: "\(error)")
        }
    }

    // MARK: - close

    /// Close an estate and remove it from the registry.
    ///
    /// Calls `LocusKit.Estate.close()` on the live actor to allow it
    /// to flush any pending state, then drops the registry entry. The
    /// handle becomes stale after this call; subsequent
    /// `estate(for:)` lookups throw `.estateNotOpen`.
    ///
    /// Idempotent only in the sense that a stale handle is reported
    /// explicitly: closing an already-closed handle raises
    /// `.estateNotOpen`, which the caller can ignore.
    ///
    /// - Throws: `.estateNotOpen` if the handle is not in the registry.
    func close(_ handle: EstateHandle) async throws {
        guard let estate = registry[handle] else {
            throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
        }
        do {
            try await estate.close()
        } catch {
            // The registry entry must still be dropped; an Estate that
            // refused to flush is still inaccessible going forward, and
            // leaving it in the registry would leak a dead handle. The
            // audit log is dropped with it — a closed handle must not
            // resolve to a live log (GLK-03).
            registry[handle] = nil
            auditLogs[handle] = nil
            diaryStores[handle] = nil
            kgStores[handle] = nil
            matrixTiers[handle] = nil
            nodeTopologyProviders[handle] = nil
            dropGrantSurface(for: handle)
            throw GeniusLocusKitError.underlyingEstateFailure(reason: "\(error)")
        }
        registry[handle] = nil
        auditLogs[handle] = nil
        diaryStores[handle] = nil
        kgStores[handle] = nil
        matrixTiers[handle] = nil
        nodeTopologyProviders[handle] = nil
        dropGrantSurface(for: handle)
        Self.log.info("closed estate \(handle.estateUUID, privacy: .public)")
    }

    // MARK: - estate(for:)

    /// Reach the live `LocusKit.Estate` actor for a handle.
    ///
    /// This is the per-handle access point. Callers use the returned
    /// estate to invoke LocusKit verbs (`capture`, `recall`, etc.)
    /// directly against the addressed estate. The coordinator does
    /// not mediate verb calls; it only routes by handle.
    ///
    /// - Throws: `.estateNotOpen` if the handle is not in the registry.
    func estate(for handle: EstateHandle) throws -> LocusKit.Estate {
        guard let estate = registry[handle] else {
            throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
        }
        return estate
    }
}
