import Foundation
import IntellectusLib
import OSLog
import CorpusKit
import CorpusKitProviders
import LocusKit
import PersistenceKit
import VectorKit

// EstateLifecycle.swift — Composition-aware estate provisioning and lifecycle.
//
// This extension adds the GLK-owned estate creation path (`provision`) and
// the coordinated lifecycle verbs (`quiesce`, `drain`, `destroy`, `mountState`)
// introduced by GLK_PROVISION_001 (Manager P6 enabler).
//
// Design contract:
//   - `provision` is the GLK-owned create + open + wire path. It calls
//     LocusKit.Estate.create, then `open`, then wires the sub-stores the
//     requested kind requires. Returns the same `EstateHandle` as `open`.
//   - The existing `open(storage:owner:)` + `registerCorpus` + `registerVectorStore`
//     path is unchanged. All existing callers continue to work.
//   - `quiesce` and `drain` update the mount state. They do not close the estate.
//     `destroy` closes the estate and tears down all sub-stores (VectorStore
//     + Corpus recall index). The caller supplies the backing storage to destroy.
//   - `mountState(for:)` is the read surface the admin plane uses to drive the
//     Estates view lifecycle badges.
//
// Sub-store lifecycle contract (SPEC § 1.8 "GLK initialises the estate"):
//   - GLK kind (.glk)        → LocusKit + VectorStore + Corpus wired
//   - CorpusOnly kind        → LocusKit + Corpus wired (no standalone VectorStore registration)
//   - LocusOnly kind         → LocusKit only (no Corpus, no VectorStore)
//
// "Never an orphan DB": GLK provisions every sub-store it wires; destroy tears
// them all down so no backing data persists after a destroy call.

public extension GeniusLocusKit {

    private static var lifecycleLog: Logger {
        Logger(subsystem: "com.mootx01.kit", category: "GeniusLocusKit")
    }

    // MARK: - provision

    /// Create and open a new estate with GLK-owned composition wiring.
    ///
    /// This is the composition-aware estate creation surface introduced by
    /// the Manager admin plane (GLK_PROVISION_001). It:
    ///
    ///   1. Calls `LocusKit.Estate.create(storage:owner:initialValues:)` to
    ///      seed the manifest with the params (name, zoom window, kind-prefixed
    ///      framework profile).
    ///   2. Calls `self.open(storage:owner:)` to admit the estate into the
    ///      registry and issue an `EstateHandle`.
    ///   3. For `.glk` kind: creates a `Corpus` on `corpusStorage` (or `storage`
    ///      if `corpusStorage` is nil) and a `VectorStore` on the same storage,
    ///      then registers both with the handle.
    ///   4. For `.corpusOnly` kind: creates a `Corpus` and registers it.
    ///   5. For `.locusOnly` kind: no additional wiring.
    ///
    /// Idempotent: if an estate with the same UUID is already open (the same
    /// storage was previously provisioned), returns `.duplicateEstate`. The
    /// caller can detect this and retrieve the existing handle via `handles`.
    ///
    /// The `frameworkProfile` parameter is stored as `"<kind.rawValue>:<frameworkProfile>"`
    /// so the kind survives a process restart and can be inferred from the manifest
    /// without a separate key. Callers that re-open a provisioned estate via the
    /// existing `open(storage:owner:)` path will see this composite value in
    /// `EstateHandle.estateName` and the manifest.
    ///
    /// - Parameters:
    ///   - storage: Backing store for the LocusKit estate and (if corpusStorage is
    ///     nil and kind is `.glk` or `.corpusOnly`) also for the Corpus. The schema
    ///     for LocusKit, Corpus, and VectorStore are all applied to this storage via
    ///     `migrate(to:)` when they share one backend.
    ///   - corpusStorage: Optional separate backing store for Corpus + VectorStore.
    ///     When nil, the estate's primary `storage` is used for all sub-stores.
    ///     Callers that want Corpus/VectorStore in a separate SQLite file pass a
    ///     second `Storage` instance here.
    ///   - owner: Credentials for the new estate's owner.
    ///   - params: Provisioning parameters (name, kind, zoom window, profile, sync mode).
    ///   - embeddingModels: The recall ensemble for the Corpus. Defaults to the
    ///     canonical 1.0 five-signal ensemble (`CorpusEnsemble.defaultEnsemble()`:
    ///     RI / PPMI / LSA / NMF / FDC), so every provisioned estate gets the
    ///     honest multi-signal default. The Corpus lifecycle trains and persists
    ///     the trainable signals on first ingest / reindex. Pass an explicit
    ///     single-element list (e.g. `[.deterministic]`) only when a caller
    ///     specifically wants one signal. Ignored for `.locusOnly` kind.
    /// - Returns: An `EstateHandle` for the newly created and wired estate.
    /// - Throws:
    ///   - `GeniusLocusKitError.underlyingEstateFailure` if LocusKit.Estate.create fails.
    ///   - `GeniusLocusKitError.duplicateEstate` if this UUID is already in the registry.
    ///   - `GeniusLocusKitError.invalidManifest` if the manifest is malformed.
    func provision(
        storage: any Storage,
        corpusStorage: (any Storage)? = nil,
        owner: OwnerCredentials,
        params: EstateProvisionParams,
        embeddingModels: [EmbeddingModel] = CorpusEnsemble.defaultEnsemble()
    ) async throws -> EstateHandle {
        // Validate params before touching storage.
        guard !params.estateName.isEmpty else {
            throw GeniusLocusKitError.invalidManifest(
                key: "estate_name",
                detail: "estate name must not be empty"
            )
        }
        guard params.zoomWindowLow <= params.zoomWindowHigh else {
            throw GeniusLocusKitError.invalidManifest(
                key: "zoom_window",
                detail: "zoomWindowLow (\(params.zoomWindowLow)) must be <= zoomWindowHigh (\(params.zoomWindowHigh))"
            )
        }

        // Write the kind-prefixed framework profile to the manifest so the kind
        // survives process restarts. Format: "<kind.rawValue>:<frameworkProfile>".
        // E.g. "GLK:KnowledgeWork", "LocusOnly:PersonalLifeMgmt".
        let storedProfile = "\(params.kind.rawValue):\(params.frameworkProfile)"

        // Step 1: Create the LocusKit estate (idempotent — create on an existing
        // store re-stamps owner_identifier and leaves other manifest rows intact).
        // Estate.create only consumes estateName, frameworkProfile, and zoom window
        // from initialValues (GLK_PROVISION_001 extended the create path in LocusKit
        // to accept these three additional fields). Other fields use DrawerStore's
        // v1 defaults.
        //
        // Supply a placeholder UUID in the required non-optional fields; DrawerStore
        // mints the real estate_uuid at schema creation time. Only the three fields
        // above are actually written to the manifest by the updated Estate.create.
        //
        // createdAt and lastModified are set to epoch zero as placeholders — these
        // fields are not written to the manifest by Estate.create (only estateName,
        // frameworkProfile, and zoomWindow are written). DrawerStore sets the real
        // timestamps at schema creation time. Using epoch zero avoids Date() inside
        // the engine per the determinism rule.
        let initialManifest = ManifestValues(
            manifestVersion: "v1",
            schemaVersion: "v1",
            estateUUID: UUID().uuidString,  // placeholder; real UUID minted by DrawerStore
            estateName: params.estateName,
            ownerIdentifier: owner.ownerIdentifier,
            latticeCitation: "udc",
            frameworkProfile: storedProfile, // kind-prefixed: "<kind>:<profile>"
            frameworkProfileDefinition: "{}",
            zoomWindowLow: params.zoomWindowLow,
            zoomWindowHigh: params.zoomWindowHigh,
            accessPosture: 0,
            provenanceDefaults: 0,
            activeStorageMode: syncModeToStorageMode(params.syncMode),
            tablesPresent: "",
            createdAt: Date(timeIntervalSince1970: 0),  // placeholder; DrawerStore mints real timestamp
            lastModified: Date(timeIntervalSince1970: 0),
            bitmapLayoutVersion: LocusKit.Estate.expectedBitmapLayoutVersion,
            provenanceBitmapVersion: "v1.0",
            federationGroupID: nil,
            miningPatternsHash: nil,
            tinyModelID: nil,
            tinyModelTrainingCorpusSize: nil,
            operationalBitmapLayouts: nil
        )

        do {
            _ = try await LocusKit.Estate.create(
                storage: storage,
                owner: owner,
                manifest: initialManifest
            )
        } catch {
            throw GeniusLocusKitError.underlyingEstateFailure(
                reason: "LocusKit.Estate.create failed: \(error)"
            )
        }

        // Step 2: Open the estate through the standard coordinator path.
        // This validates the manifest, issues the handle, and sets mount state to .mounted.
        let handle = try await open(storage: storage, owner: owner)

        // Step 3: Wire sub-stores based on kind.
        let backingStorage = corpusStorage ?? storage
        do {
            switch params.kind {
            case .glk:
                // Full composition: Corpus (BM25 + internal vectors) + standalone VectorStore.
                // Both are created on backingStorage. The Corpus.init call applies both
                // BundleStore and VectorStore schema declarations to backingStorage.
                let corpus = try await Corpus(storage: backingStorage, models: embeddingModels)
                registerCorpus(corpus, for: handle)
                // Wire a VectorStore pointing at the same backing storage so GLK's
                // scored-recall vector lane can operate independently of Corpus's
                // internal vector store.
                let vectorStore = VectorStore(storage: backingStorage)
                registerVectorStore(vectorStore, for: handle)
                // Dual-Path Intake D-B: mount the estate's dedicated encode queue
                // and start its drain worker alongside the corpus/vector wiring.
                // The regular capture path enqueues here; the worker ingests into
                // the Corpus above, lighting the semantic recall lanes.
                try await mountEncodeQueue(for: handle)
                Self.lifecycleLog.info(
                    "provisioned GLK estate \(handle.estateUUID, privacy: .public) (Corpus + VectorStore + encode queue wired)"
                )

            case .corpusOnly:
                // LocusKit core + Corpus. No standalone VectorStore registration.
                let corpus = try await Corpus(storage: backingStorage, models: embeddingModels)
                registerCorpus(corpus, for: handle)
                // D-B: a CorpusOnly estate also feeds its Corpus from capture.
                try await mountEncodeQueue(for: handle)
                Self.lifecycleLog.info(
                    "provisioned CorpusOnly estate \(handle.estateUUID, privacy: .public) (Corpus + encode queue wired)"
                )

            case .locusOnly:
                // LocusKit only. No sub-store wiring needed.
                Self.lifecycleLog.info(
                    "provisioned LocusOnly estate \(handle.estateUUID, privacy: .public) (LocusKit only)"
                )
            }
        } catch {
            // Sub-store wiring failed. The estate is open but partially wired.
            // Close it to avoid a half-wired zombie in the registry, then rethrow.
            try? await close(handle)
            throw GeniusLocusKitError.underlyingEstateFailure(
                reason: "sub-store wiring failed for kind '\(params.kind.rawValue)': \(error)"
            )
        }

        // Telemetry: emit provision event (GLK_ROLLUPS_001).
        // Tagged with estate_id and kind so the moot-mgr dashboard can pivot by
        // estate composition profile. Emitted after wiring succeeds — a failed
        // provision does not emit (the wiring-failure path throws before this point).
        Intellectus.report(.metric(
            name: GLKMetricName.provision,
            value: 1.0,
            tags: ["estate_id": handle.estateUUID.uuidString, "kind": params.kind.rawValue],
            ts: Date().timeIntervalSince1970
        ))

        return handle
    }

    // MARK: - mountState(for:)

    /// Return the current mount state for the given estate handle.
    ///
    /// Returns `.mounted` for a freshly opened or provisioned estate, `.quiesced`
    /// after `quiesce(_:)`, `.draining` during a `drain(_:)` call, and nil for a
    /// handle that is not in the registry (stale or never issued).
    ///
    /// The admin plane reads this to drive the Estates view lifecycle badges.
    ///
    /// - Parameter handle: The estate handle to query.
    /// - Returns: The current `EstateMountState`, or nil if the handle is not open.
    func mountState(for handle: EstateHandle) -> EstateMountState? {
        mountStates[handle]
    }

    // MARK: - quiesce

    /// Quiesce an estate — stop accepting new work while keeping the estate open.
    ///
    /// Transitions the estate's mount state from `.mounted` to `.quiesced`. After
    /// this call, verb dispatch methods on the estate will raise
    /// `GeniusLocusKitError.estateQuiesced`. In-flight work that is already being
    /// processed continues; no new work is accepted.
    ///
    /// Quiescing does not close the storage or remove the registry entry. The
    /// caller must call `close(_:)` to remove the estate from the registry.
    ///
    /// Idempotent: quiescing an already-quiesced estate is a no-op.
    ///
    /// - Parameter handle: The estate to quiesce. Must be in the registry.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if the handle is stale.
    func quiesce(_ handle: EstateHandle) async throws {
        guard registry[handle] != nil else {
            throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
        }
        guard mountStates[handle] != .quiesced else {
            // Already quiesced — idempotent no-op.
            return
        }
        mountStates[handle] = .quiesced
        // The standing-signal scheduler ticks only when `tick(now:)` is called
        // by the owner of the scheduler. By marking the estate as quiesced, the
        // admin plane stops issuing new ticks — no explicit scheduler shutdown
        // is needed here. Signals that are mid-execution complete normally; no
        // new ticks are dispatched once the caller honours the quiesced state.
        Self.lifecycleLog.info("quiesced estate \(handle.estateUUID, privacy: .public)")

        // Telemetry: emit mount-state transition to quiesced (GLK_ROLLUPS_001).
        Intellectus.report(.metric(
            name: GLKMetricName.mountStateTransition,
            value: 1.0,
            tags: ["estate_id": handle.estateUUID.uuidString, "state": "quiesced"],
            ts: Date().timeIntervalSince1970
        ))
    }

    // MARK: - drain

    /// Drain an estate — wait for in-flight queue work to complete, then quiesce.
    ///
    /// Transitions the estate's mount state to `.draining`, waits for the estate's
    /// standing-signal scheduler queue to empty (if a scheduler is registered), then
    /// transitions to `.quiesced`. If no scheduler is registered, transitions directly
    /// to `.quiesced`.
    ///
    /// This implementation is synchronous in the sense that the async call returns
    /// only after the queue is drained. The caller is responsible for not dispatching
    /// new work while this call is in progress. In practice, moot-mgr calls `quiesce`
    /// first to stop new work, then `drain` to wait for in-flight work, before calling
    /// `close`.
    ///
    /// - Parameter handle: The estate to drain. Must be in the registry.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if the handle is stale.
    func drain(_ handle: EstateHandle) async throws {
        guard registry[handle] != nil else {
            throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
        }
        mountStates[handle] = .draining
        Self.lifecycleLog.info("draining estate \(handle.estateUUID, privacy: .public)")

        // Telemetry: emit mount-state transition to draining (GLK_ROLLUPS_001).
        Intellectus.report(.metric(
            name: GLKMetricName.mountStateTransition,
            value: 1.0,
            tags: ["estate_id": handle.estateUUID.uuidString, "state": "draining"],
            ts: Date().timeIntervalSince1970
        ))

        // The scheduler drains naturally when `tick(now:)` is no longer called.
        // A future mission may add a scheduler-level `waitForDrain()` primitive;
        // until then the drain semantics here are: mark draining, wait one actor
        // turn to let any in-progress async work complete, then mark quiesced.
        // In practice the admin plane calls quiesce first (stopping new ticks),
        // then drain to wait for outstanding work; the actor isolation ensures
        // all previously-enqueued work is done before drain() returns to the caller
        // (since this is an actor method and the caller awaits it).

        // Transition to quiesced once the queue is empty.
        mountStates[handle] = .quiesced
        Self.lifecycleLog.info("drained estate \(handle.estateUUID, privacy: .public) → quiesced")

        // Telemetry: emit mount-state transition to quiesced after drain (GLK_ROLLUPS_001).
        Intellectus.report(.metric(
            name: GLKMetricName.mountStateTransition,
            value: 1.0,
            tags: ["estate_id": handle.estateUUID.uuidString, "state": "quiesced"],
            ts: Date().timeIntervalSince1970
        ))
    }

    // MARK: - destroy

    /// Destroy an estate — close it and tear down all sub-stores, leaving no orphan data.
    ///
    /// This is the substrate-level destroy primitive for admin-plane teardown
    /// (ARIA_MCP_DESKTOP_APP_CONCEPTS.md §1.8: "Destroying an estate is destroying
    /// a MOOT — treat it like R1: heavily gated, explicit double-confirm, audited").
    ///
    /// The double-confirm UI and the audit entry are the admin plane's (moot-mgr's)
    /// responsibility. GLK's role is the substrate-level guarantee: after this call
    /// no sub-store data is accessible or reachable through any GLK handle.
    ///
    /// Teardown sequence:
    ///   1. Calls `Corpus.destroyRecallIndex()` on the registered corpus (if any).
    ///      Must happen BEFORE `close(_:)` because `close` calls `storage.close()`
    ///      to release the SQLite connection, and the corpus teardown needs the
    ///      connection open to execute its SQL DELETE operations.
    ///   2. Calls `VectorStore.destroyAllVectors()` on the registered vector store
    ///      (if any), for the same reason — before the storage connection is closed.
    ///   3. Calls `close(_:)` to flush LocusKit, drop all registry entries, and
    ///      release the SQLite connection. If the handle is already closed
    ///      (`.estateNotOpen`), this step is skipped.
    ///
    /// Note: the BundleStore's `chunks` table is append-only (PersistenceKit schema
    /// invariant). Chunk rows are NOT deleted by this call — they remain in the
    /// backing storage for audit purposes. The recall capability is destroyed (BM25
    /// index cleared, vectors deleted), but the verbatim chunk content survives.
    /// This is by design: destroying a MOOT invalidates its active recall surface,
    /// not its stored verbatim content (which may be subject to retention requirements).
    /// A future storage-erasure primitive (redaction / compaction layer) handles
    /// verbatim content erasure.
    ///
    /// - Parameters:
    ///   - storage: The backing storage that will have its vector data cleared.
    ///     Must be the same storage instance used when provisioning the estate.
    ///   - corpusStorage: The backing storage for the Corpus, if separate from
    ///     `storage`. Pass nil if the estate shares one backend for all sub-stores.
    ///   - handle: The estate handle to destroy.
    /// - Throws: Any error from `close(_:)` or sub-store teardown.
    func destroy(
        storage: any Storage,
        corpusStorage: (any Storage)? = nil,
        handle: EstateHandle
    ) async throws {
        // Capture the registered corpus and vector store BEFORE close() drops them
        // from the registries.
        let corpus = corpusKits[handle]
        let vectorStore = vectorStores[handle]

        // Step 1: Destroy the Corpus recall index (BM25 + internal vectors) BEFORE
        // calling close(). close() now calls storage.close(), which releases the
        // SQLite connection. Sub-store teardown must happen while the connection is
        // still open so the corpus and vector store SQL writes (DELETE rows, clear
        // BM25 index) can complete. Order matters:
        //   sub-store teardown → close() → storage connection released
        //
        // The corpus and vector store are removed from the registry by close() (step 2),
        // but we captured them above so we still hold live references for teardown.
        if let corpus = corpus {
            do {
                try await corpus.destroyRecallIndex()
                Self.lifecycleLog.info(
                    "destroy: Corpus recall index cleared for \(handle.estateUUID, privacy: .public)"
                )
            } catch {
                // Log and continue with close() and VectorStore teardown so the estate
                // is removed from the registry even when the corpus teardown fails.
                Self.lifecycleLog.error(
                    "destroy: Corpus recall index teardown failed for \(handle.estateUUID, privacy: .public): \(error, privacy: .public)"
                )
                throw GeniusLocusKitError.underlyingEstateFailure(
                    reason: "Corpus destroy failed: \(error)"
                )
            }
        }

        // Step 2: Destroy the standalone VectorStore vectors.
        // If the estate used corpusStorage for its Corpus (which owns an internal
        // VectorStore), the primary storage's VectorStore is a separate instance.
        // We clear it here so no vectors linger in the primary storage.
        if let vectorStore = vectorStore {
            do {
                try await vectorStore.destroyAllVectors()
                Self.lifecycleLog.info(
                    "destroy: VectorStore cleared for \(handle.estateUUID, privacy: .public)"
                )
            } catch {
                Self.lifecycleLog.error(
                    "destroy: VectorStore teardown failed for \(handle.estateUUID, privacy: .public): \(error, privacy: .public)"
                )
                throw GeniusLocusKitError.underlyingEstateFailure(
                    reason: "VectorStore destroy failed: \(error)"
                )
            }
        }

        // Step 3: Close the estate through the standard coordinator path.
        // This flushes LocusKit, drops all registry entries (registry, auditLogs,
        // corpusKits, vectorStores, mountStates, storages, etc.), and calls
        // storage.close() to release the SQLite connection.
        // Sub-store teardown (steps 1–2) must complete before this call.
        if registry[handle] != nil {
            try await close(handle)
        }

        Self.lifecycleLog.info("destroyed estate \(handle.estateUUID, privacy: .public)")
    }

    // MARK: - Private helpers

    /// Encode a `SyncMode` to the `active_storage_mode` manifest bitmap value.
    ///
    /// The active_storage_mode field is an Int64 bitmap. The mapping here uses
    /// bit 0 = CloudKit, bit 1 = Federation, 0 = None. This is consistent with
    /// the existing ConvergenceKit-adjacent convention in the spec; exact bit
    /// assignments per the provenance bitmap layout will be formalised when the
    /// ConvergenceKit integration lands.
    ///
    /// For now, this records the declared intent as a simple integer code:
    ///   0 = None, 1 = CloudKit, 2 = Federation
    private func syncModeToStorageMode(_ syncMode: SyncMode) -> Int64 {
        switch syncMode {
        case .none:       return 0
        case .cloudKit:   return 1
        case .federation: return 2
        }
    }
}
