import Foundation
import IntellectusLib
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
    /// Composes `LocusKit.Estate.open(storage:owner:identityKeyStore:)` against
    /// the supplied `Storage`, captures the manifest snapshot the coordinator
    /// needs (UUID, zoom window, name), and issues an `EstateHandle` keyed on
    /// the estate's manifest UUID.
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
    ///   - identityKeyStore: the key store used to persist and retrieve the
    ///     estate's Ed25519 private signing key (secfix/ed25519-keychain,
    ///     data-movement privacy tiers). When nil (the default) `LocusKit.Estate.open` resolves
    ///     it from the storage backend — Keychain for durable backends,
    ///     in-memory for `.inMemory` storage — so ephemeral estates never
    ///     persist identity keys to the login keychain. Pass
    ///     `KeychainEstateIdentityKeyStore()` explicitly when serving a
    ///     DURABLE estate from hydrated in-memory storage (the hydrate
    ///     launch path does); tests may inject
    ///     `InMemoryEstateIdentityKeyStore` explicitly for temp-dir SQLite
    ///     estates.
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
        owner: OwnerCredentials,
        identityKeyStore: (any EstateIdentityKeyStore)? = nil
    ) async throws -> EstateHandle {
        let estate: LocusKit.Estate
        do {
            estate = try await LocusKit.Estate.open(
                storage: storage,
                owner: owner,
                identityKeyStore: identityKeyStore
            )
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
        // Mark the estate mounted (GLK_PROVISION_001) so the admin plane
        // can observe mount state without polling the registry directly.
        mountStates[handle] = .mounted
        // Auto-register substrate-native topology provider (node-tree integrity,
        // NT-G1). Shares the estate's NodeStore so .nodeTreeNative recall
        // works without a host-supplied provider (NT-Q1).
        let topologyAdapter = SubstrateNodeTopologyProvider(nodeStore: await estate.nodeStore)
        registerNodeTopology(topologyAdapter, for: handle)
        Self.log.info("opened estate \(handle.estateUUID, privacy: .public)")

        // Telemetry: emit mount-state transition (GLK_ROLLUPS_001).
        // The autoclosure is only evaluated when monitoring is enabled;
        // the disabled-path cost is one Atomic<Bool> load (~1 ns).
        let estateIDStr = handle.estateUUID.uuidString
        Intellectus.report(.metric(
            name: GLKMetricName.mountStateTransition,
            value: 1.0,
            tags: ["estate_id": estateIDStr, "state": "mounted"],
            ts: Date().timeIntervalSince1970
        ))

        // Telemetry: emit noun count snapshot at admission time (GLK_ROLLUPS_001).
        // Non-zero for re-opened existing estates; zero for freshly created ones.
        // Drawer count is read lazily inside the autoclosure — only when monitoring
        // is enabled — so there is zero overhead on the disabled path.
        if Intellectus.isEnabled,
           let liveEstate = registry[handle] {
            let count = (try? await liveEstate.allDrawers().filter { $0.tombstonedAt == nil }.count) ?? 0
            Intellectus.report(.metric(
                name: GLKMetricName.nounCount,
                value: Double(count),
                tags: ["estate_id": estateIDStr],
                ts: Date().timeIntervalSince1970
            ))
        }

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
    /// to flush any pending state, then calls `storage.close()` on the
    /// backing SQLite connection to release the file lock, and drops all
    /// registry entries for the handle.
    ///
    /// "All" is literal and load-bearing: EVERY per-estate registry is
    /// cleared, on both the error path and the success path, because handles
    /// are equal across reopens and anything left behind resolves on the next
    /// open of the same estate as state the caller never registered.
    /// `EstateCloseCompletenessTests` enforces this as registries are added.
    /// Values that own a worker, a lease, or a connection are torn down BEFORE
    /// their entry is dropped — see `corpusKits` and `schedulers` below.
    ///
    /// Storage close contract: GLK retains the caller's `Storage` in
    /// `storages[handle]` so grant stores and sub-stores share the same
    /// SQLite file. On close, GLK calls `storage.close()` to release
    /// the connection. Callers must not use the `Storage` instance after
    /// passing it to `open`/`provision` and then calling `close`.
    ///
    /// The handle becomes stale after this call; subsequent
    /// `estate(for:)` lookups throw `.estateNotOpen`.
    ///
    /// Double-close safe: a stale handle raises `.estateNotOpen`,
    /// which the caller can ignore.
    ///
    /// - Throws: `.estateNotOpen` if the handle is not in the registry.
    func close(_ handle: EstateHandle) async throws {
        guard let estate = registry[handle] else {
            throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
        }
        // Capture the storage before clearing the map entries so we can close it
        // after all registry cleanup. Closing AFTER cleanup ensures no concurrent
        // actor-isolated path can read through the storage once close() is in flight.
        let storage = storages[handle]
        do {
            try await estate.close()
        } catch {
            // The registry entry must still be dropped; an Estate that
            // refused to flush is still inaccessible going forward, and
            // leaving it in the registry would leak a dead handle. The
            // audit log is dropped with it — a closed handle must not
            // resolve to a live log (GLK-03).
            registry[handle] = nil
            diaryStores[handle] = nil
            kgStores[handle] = nil
            fingerprintStores[handle] = nil
            matrixTiers[handle] = nil
            calibrationRegistries[handle] = nil
            matrixPersistenceBackends[handle] = nil
            nodeTopologyProviders[handle] = nil
            // Drop the recall accelerators. Both are caller-registered pure
            // score lookups with no lazy re-mint, so a reopened estate scores
            // their columns at 0.0 until the caller registers again.
            graphCaches[handle] = nil
            preferenceStores[handle] = nil
            // Drop the subject-backfill rider. Handles are equal across
            // reopens, so leaving this entry lets a reopened estate resolve to
            // a producer that was never re-registered — drainStatuses renders
            // the subject_backfill lane as live and subjectBackfillSweep, which
            // authorises on map presence alone, hands drawer content to it.
            subjectProducers[handle] = nil
            // Release the standing-signal scheduler's signals drain lease
            // BEFORE dropping the registry entry, the same ordering discipline
            // the corpusKits drop below follows. `DrainLease.release()` is
            // ownership-guarded — it removes the lease file only when this
            // process holds it — so it can never clobber another drainer's
            // record. The scheduler owns no background task or timer of its
            // own (`tick(now:)` is caller-driven), so once the lease is
            // released the reference itself is safe to drop; that also
            // releases the scheduler's queue.sqlite connection.
            schedulers[handle]?.drainLease?.release()
            schedulers[handle] = nil
            // Drop dreaming queue + HLC. No drain worker to
            // cancel — T6 is enqueue-only; the lease is a T9 drainer concern.
            dreamingQueues[handle] = nil
            dreamingHLCs[handle] = nil
            // Cancel the Corpus's ingest drain worker and drop its queue
            // (CorpusKit owns the encode pipeline) BEFORE releasing the corpus
            // registration, so no orphan worker outlives the estate.
            await corpusKits[handle]?.dropIngestQueue()
            corpusKits[handle] = nil
            vectorStores[handle] = nil
            distillFunctions[handle] = nil
            mountStates[handle] = nil
            // Drop the sync engine so no engine reference outlives the estate.
            syncEngines[handle] = nil
            dropGrantSurface(for: handle)
            // Release the storage connection even on estate flush failure so
            // the SQLite file lock is freed and the file can be reopened.
            storages[handle] = nil
            await storage?.close()
            throw GeniusLocusKitError.underlyingEstateFailure(reason: "\(error)")
        }
        registry[handle] = nil
        diaryStores[handle] = nil
        kgStores[handle] = nil
        fingerprintStores[handle] = nil
        matrixTiers[handle] = nil
        calibrationRegistries[handle] = nil
        matrixPersistenceBackends[handle] = nil
        nodeTopologyProviders[handle] = nil
        // Drop the recall accelerators. Both are caller-registered pure
        // score lookups with no lazy re-mint, so a reopened estate scores
        // their columns at 0.0 until the caller registers again.
        graphCaches[handle] = nil
        preferenceStores[handle] = nil
        // Drop the subject-backfill rider. Handles are equal across reopens,
        // so leaving this entry lets a reopened estate resolve to a producer
        // that was never re-registered — drainStatuses renders the
        // subject_backfill lane as live and subjectBackfillSweep, which
        // authorises on map presence alone, hands drawer content to it.
        subjectProducers[handle] = nil
        // Release the standing-signal scheduler's signals drain lease BEFORE
        // dropping the registry entry, the same ordering discipline the
        // corpusKits drop below follows. `DrainLease.release()` is
        // ownership-guarded — it removes the lease file only when this process
        // holds it — so it can never clobber another drainer's record. The
        // scheduler owns no background task or timer of its own (`tick(now:)`
        // is caller-driven), so once the lease is released the reference itself
        // is safe to drop; that also releases the scheduler's queue.sqlite
        // connection.
        schedulers[handle]?.drainLease?.release()
        schedulers[handle] = nil
        // Drop dreaming queue + HLC. No drain worker to
        // cancel — T6 is enqueue-only; the lease is a T9 drainer concern.
        dreamingQueues[handle] = nil
        dreamingHLCs[handle] = nil
        // Drop corpus and vector store registrations (GLK_PROVISION_001):
        // these are set by provision() and must be released with the estate.
        // Register-only path (existing callers) also sets these via
        // registerCorpus/registerVectorStore — both paths benefit from cleanup.
        // Cancel the Corpus's ingest drain worker and drop its queue (CorpusKit
        // owns the encode pipeline) BEFORE releasing the corpus registration, so
        // no orphan worker outlives the estate.
        await corpusKits[handle]?.dropIngestQueue()
        corpusKits[handle] = nil
        vectorStores[handle] = nil
        distillFunctions[handle] = nil
        mountStates[handle] = nil
        // Drop the sync engine so no engine reference outlives the estate.
        syncEngines[handle] = nil
        dropGrantSurface(for: handle)
        // Release the backing Storage connection so the SQLite file lock is freed.
        // This is the fix for the connection leak: storages[handle] was captured
        // before cleanup; nil it and close the connection now that all per-estate
        // map entries are cleared and no actor-isolated path can reach the storage.
        storages[handle] = nil
        await storage?.close()
        Self.log.info("closed estate \(handle.estateUUID, privacy: .public)")

        // Telemetry: emit mount-state transition to unmounted (GLK_ROLLUPS_001).
        // Emitted after all registry cleanup so the closed state is authoritative.
        Intellectus.report(.metric(
            name: GLKMetricName.mountStateTransition,
            value: 1.0,
            tags: ["estate_id": handle.estateUUID.uuidString, "state": "unmounted"],
            ts: Date().timeIntervalSince1970
        ))
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

// MARK: - Close-path completeness audit

/// Reporting seam for the close-path completeness audit: any dictionary keyed
/// by `EstateHandle` can say whether it still holds an entry for a handle,
/// whatever its value type is.
///
/// The conditional conformance below is what makes `residentRegistries(for:)`
/// STRUCTURAL rather than a hand-maintained list. Every per-estate registry on
/// the actor is a `[EstateHandle: …]`, so each one conforms automatically and
/// is enumerated by reflection — a registry added in a later mission is
/// audited with no edit to this file and no edit to the test.
internal protocol EstateKeyedRegistry {
    /// Whether this registry still holds an entry for `handle`.
    func holdsEntry(for handle: EstateHandle) -> Bool
}

extension Dictionary: EstateKeyedRegistry where Key == EstateHandle {
    internal func holdsEntry(for handle: EstateHandle) -> Bool {
        self[handle] != nil
    }
}

internal extension GeniusLocusKit {

    /// The names of every per-estate registry that still holds an entry for
    /// `handle`, sorted for a stable diff.
    ///
    /// `close` must leave this empty. Handles are equal across reopens
    /// (`EstateHandle.estateUUID` comes from the manifest, so it is a property
    /// of the substrate rather than of the open), which means any registry
    /// entry left behind is resolvable by the NEXT open of the same estate as
    /// state the caller never registered. That is the whole shape of Codex
    /// finding `6ed2ab30948481919f147fae496f55b1`.
    ///
    /// Implemented by reflecting over the actor's stored properties and
    /// selecting those that are `EstateHandle`-keyed dictionaries, so the audit
    /// covers registries that did not exist when it was written. Reflection is
    /// acceptable here because this is a diagnostic read on a cold path — the
    /// close-completeness test — never a hot recall path.
    func residentRegistries(for handle: EstateHandle) -> [String] {
        Mirror(reflecting: self).children.compactMap { child in
            guard let label = child.label,
                  let registry = child.value as? any EstateKeyedRegistry,
                  registry.holdsEntry(for: handle)
            else { return nil }
            return label
        }
        .sorted()
    }

    /// The names of every per-estate registry declared on the actor, sorted.
    ///
    /// The completeness test asserts this is non-empty and that the registries
    /// it managed to populate are a meaningful share of it, so the test cannot
    /// quietly degrade into asserting emptiness over an empty set.
    func declaredRegistryNames() -> [String] {
        Mirror(reflecting: self).children.compactMap { child in
            guard let label = child.label,
                  child.value is any EstateKeyedRegistry
            else { return nil }
            return label
        }
        .sorted()
    }
}
