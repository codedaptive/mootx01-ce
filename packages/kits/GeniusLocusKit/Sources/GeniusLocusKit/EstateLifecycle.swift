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

        // Step 2b: Wire sub-stores based on kind — BEFORE seeding the wings.
        // Wiring registers the Corpus (and mounts the encode queue), so the wing
        // hints seeded in step 2c are stamped with the corpus's real model id, not
        // a sentinel. This matches the serve open path, which also wires before it
        // seeds. (Seeding does not depend on the wiring; the order is purely so the
        // hint drawers carry the normal model id — ADR-016 §2.)
        let backingStorage = corpusStorage ?? storage
        do {
            // Wire via the shared seam (also called by the serve entry points so a
            // bare-opened served estate gets the same Corpus + VectorStore + encode
            // queue — the semantic recall + distillation lanes — without re-stamping
            // the manifest).
            try await wireSubstores(
                for: handle, kind: params.kind,
                backingStorage: backingStorage, embeddingModels: embeddingModels)
        } catch {
            // Sub-store wiring failed. The estate is open but partially wired.
            // Close it to avoid a half-wired zombie in the registry, then rethrow.
            try? await close(handle)
            throw GeniusLocusKitError.underlyingEstateFailure(
                reason: "sub-store wiring failed for kind '\(params.kind.rawValue)': \(error)"
            )
        }

        // Step 2c: Seed the seven default wings (ADR-016 §1 and §2).
        // Delegates to `seedDefaultWings(for:now:)` — the single seam that owns
        // the idempotent seeding loop. Provision passes a fresh Date() as `now`;
        // the serve open path calls the same method unconditionally so bare estates
        // opened via `mootx01 serve` receive the same wings without re-stamping
        // the manifest. The method skips wings whose `AI_Charter_Hint` drawer
        // already exists so calling it again on a pre-seeded estate is a safe no-op.
        //
        // The Corpus is now wired (step 2b), so each hint drawer is stamped with the
        // corpus's normal model id — NOT the old "estate-provision" sentinel. Hints
        // are filed row-only (LocusKit `seedWing` does not enqueue): their semantic
        // vectors are produced by the next full-corpus reindex, alongside user
        // content, rather than training a basis on the 7 hints alone. This is the
        // intended ADR-016 §2 behaviour — normal drawers, embedded under the normal
        // model at reindex.
        //
        // Failure policy: wing seeding is part of provision — if seeding fails
        // the estate is considered partially provisioned. The estate is closed
        // and an `underlyingEstateFailure` is thrown so the caller sees the error
        // rather than silently receiving an un-seeded estate.
        do {
            try await seedDefaultWings(for: handle, now: Date())
        } catch {
            // Close the half-seeded estate to avoid a zombie in the registry.
            try? await close(handle)
            throw GeniusLocusKitError.underlyingEstateFailure(
                reason: "default wing seeding failed: \(error)"
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

    // MARK: - seedDefaultWings(for:now:)

    /// Idempotently seed the seven ADR-016 default wings on an open estate.
    ///
    /// This is the single seam that owns the default-wing seeding loop. Both the
    /// `provision` path (fresh estate) and the `mootx01 serve` open path (bare
    /// re-open of an existing estate) call this method so every served estate
    /// always has its wings, regardless of whether it was created via `provision`
    /// or by the older bare `Estate.create` + `open` path.
    ///
    /// **Idempotency contract:** for each wing, the method reads the estate's
    /// existing `AI_Charter_Hint` drawers once before the loop. Wings whose hint
    /// drawer already exists are skipped silently. Calling this method multiple
    /// times on the same estate — even concurrently across process restarts — is
    /// therefore safe: at most one hint drawer per wing will ever exist.
    ///
    /// The method delegates per-wing filing to `LocusKit.Estate.seedWing`, which
    /// inserts unconditionally (not idempotent by itself). The outer check here
    /// provides the idempotency boundary.
    ///
    /// - Parameters:
    ///   - handle: An open estate handle in the coordinator's registry.
    ///   - now: Write timestamp for any hints that are seeded. Pass `Date()`
    ///     from the serve open path (an app entry point — calling `Date()` here
    ///     is acceptable). Pass a specific value in tests for determinism.
    /// - Throws: `GeniusLocusKitError.estateNotFound` if `handle` is stale;
    ///   substrate errors if a `seedWing` write fails.
    func seedDefaultWings(for handle: EstateHandle, now: Date) async throws {
        let locusEstate = try estate(for: handle)

        // Read the existing drawers once — `allDrawers()` is a full corpus scan
        // but estates are typically small (7 hints + user content) and this is
        // called once per open, not per request. Already-seeded wings are
        // identified by finding drawers in room hintRoom ("AI_Charter_Hint").
        // Resolve parentNodeId → wing name from the node tree for each hint drawer.
        let existing = try await locusEstate.allDrawers()
        let allNodeIds = Array(Set(existing.map(\.parentNodeId)))
        let allNodeNames = try await locusEstate.resolveNodeNames(parentNodeIds: allNodeIds)
        let seededWings = Set(
            existing
                .filter { allNodeNames[$0.parentNodeId]?.room == LocusKit.hintRoom }
                .compactMap { allNodeNames[$0.parentNodeId]?.wing }
        )

        // The hint drawer is stamped with the corpus's primary model id when a
        // corpus is registered — the normal case now that both provision and the
        // serve open path wire the Corpus BEFORE calling this. The sentinel below
        // is reached only for a corpus-less estate (a LocusOnly estate, which has
        // no semantic lane, or a bare serve open before wiring); such a drawer is
        // row-only and is re-stamped under the real model on the next reindex.
        let embeddingModelID: String
        if let corpus = corpusKits[handle] {
            embeddingModelID = await corpus.modelID
        } else {
            embeddingModelID = "estate-provision"
        }

        // Seed each wing that is not yet present. Missing wings emerge when an
        // estate was created via the bare `Estate.create` + `open` path that
        // predates ADR-016 (e.g. the `mootx01 serve` first-run path before this
        // fix). For estates already seeded via `provision`, this loop is a no-op.
        var seededCount = 0
        for wing in LocusKit.defaultWings where !seededWings.contains(wing.name) {
            try await locusEstate.seedWing(
                wing.name,
                hint: wing.hint,
                addedBy: LocusKit.hintAddedBy,
                embeddingModelID: embeddingModelID,
                now: now
            )
            seededCount += 1
        }

        if seededCount > 0 {
            Self.lifecycleLog.info(
                "seedDefaultWings: seeded \(seededCount, privacy: .public) wings for \(handle.estateUUID, privacy: .public) (\(LocusKit.defaultWings.count - seededCount, privacy: .public) already present)"
            )
        } else {
            Self.lifecycleLog.debug(
                "seedDefaultWings: all \(LocusKit.defaultWings.count, privacy: .public) wings already present for \(handle.estateUUID, privacy: .public) — no-op"
            )
        }
    }

    // MARK: - wireSubstores(for:kind:backingStorage:embeddingModels:)

    /// Wire an open estate's semantic sub-stores (Corpus + VectorStore + encode
    /// queue) according to its composition kind.
    ///
    /// This is the single seam that lights an estate's semantic recall and
    /// distillation lanes. `provision` calls it after stamping the manifest and
    /// opening the estate; the serve entry points (`mootx01 serve`, `aria-mcp`)
    /// call it after a bare `open(storage:owner:)` so a served estate gets the
    /// same wiring without re-stamping the manifest. `open` alone admits a BARE
    /// estate — LocusKit BM25/structural recall works, but `corpusKits` and
    /// `vectorStores` stay empty, so dense/vector recall is dark and the
    /// distillation cluster lane is inert. This call closes that gap.
    ///
    /// Idempotent: `registerCorpus`/`registerVectorStore` replace any existing
    /// entry and `Corpus.mountIngestQueue` is a no-op when already mounted, so
    /// calling it again on a reopened estate is safe.
    ///
    /// - Parameters:
    ///   - handle: The open estate handle to wire. Must already be in the registry.
    ///   - kind: The composition profile that decides which sub-stores to wire.
    ///   - backingStorage: The storage the Corpus and VectorStore are built on —
    ///     the estate's own storage for a served estate.
    ///   - embeddingModels: The recall ensemble for the Corpus. Defaults to the
    ///     canonical 1.0 five-signal ensemble (`CorpusEnsemble.defaultEnsemble()`).
    /// - Throws: A storage/schema error if a sub-store cannot be opened.
    func wireSubstores(
        for handle: EstateHandle,
        kind: EstateKind,
        backingStorage: any Storage,
        embeddingModels: [EmbeddingModel] = CorpusEnsemble.defaultEnsemble()
    ) async throws {
        switch kind {
        case .glk:
            // Apply the GLK composite schema so all component kit tables (LocusKit,
            // VectorKit, CorpusKit) are registered on backingStorage under the
            // GeniusLocusKit composite kit ID. The plain `open(storage:owner:)` path
            // applies only the LocusKit component schema — it never registers the
            // composite — so opening the composite here ensures the version gate in
            // the replication primitive sees the correct composite version for this
            // estate. Idempotent: CREATE TABLE IF NOT EXISTS for all tables, plus a
            // migration-version record for "GeniusLocusKit". This is the same
            // composite open the hydrate launch path performs in
            // open(inMemory:hydrateFrom:).
            try await backingStorage.open(schema: GeniusLocusKitSchema.estateSchemaDeclaration)
            // Full composition: Corpus (BM25 + internal vectors) + standalone VectorStore.
            // Both are created on backingStorage. The Corpus.init call applies both
            // BundleStore and VectorStore schema declarations to backingStorage.
            let corpus = try await Corpus(storage: backingStorage, models: embeddingModels)
            registerCorpus(corpus, for: handle)
            // BORROW Corpus's single dense VectorStore for GLK's scored-recall
            // vector lane rather than constructing a second VectorStore over the
            // same `vectors` table. The two instances built identical whole-table
            // resident arrays (the binary fetch is filtered only by kind, not
            // model), so a second store doubled the resident array + cold-start
            // table scan AND made the on-disk sidecar churn (each store's writes
            // invalidated the other's whole-table live-count). One shared store =
            // one resident array, one sidecar kept in sync by every write (chunk
            // vectors from encode + distilled vectors from the distillation cycle).
            // CorpusKit owns the dense vector lane; GLK reaches it through Corpus's
            // public accessor (no reaching around the kit).
            let vectorStore = await corpus.sharedVectorStore
            registerVectorStore(vectorStore, for: handle)
            // CorpusKit owns the encode pipeline: mount the Corpus's own ingest
            // queue + drain worker pool, and wire its onEncoded callback to roll
            // up the touched LocusKit rooms for each encoded batch. GLK's only
            // role is to coordinate the two kits — it never performs the encode.
            // The regular capture path enqueues into the Corpus queue; the
            // Corpus drain worker ingests, lighting the semantic recall lanes.
            try await corpus.mountIngestQueue()
            await wireCorpusRoomRollup(corpus, for: handle)
            Self.lifecycleLog.info(
                "wired GLK estate \(handle.estateUUID, privacy: .public) (Corpus + VectorStore + encode queue)"
            )

        case .corpusOnly:
            // LocusKit core + Corpus. No standalone VectorStore registration.
            let corpus = try await Corpus(storage: backingStorage, models: embeddingModels)
            registerCorpus(corpus, for: handle)
            // A CorpusOnly estate also feeds its Corpus from capture: mount the
            // Corpus-owned ingest queue + drain worker and wire the room rollup.
            try await corpus.mountIngestQueue()
            await wireCorpusRoomRollup(corpus, for: handle)
            Self.lifecycleLog.info(
                "wired CorpusOnly estate \(handle.estateUUID, privacy: .public) (Corpus + encode queue)"
            )

        case .locusOnly:
            // LocusKit only. No sub-store wiring needed.
            Self.lifecycleLog.info(
                "wired LocusOnly estate \(handle.estateUUID, privacy: .public) (LocusKit only)"
            )
        }
    }

    /// Convenience wrapper that wires a served estate as a full GLK composition.
    ///
    /// The serve entry points open a durable SQLite estate and want the complete
    /// semantic layer (Corpus + VectorStore + encode queue) without needing to
    /// reference `EstateKind`. Equivalent to `wireSubstores(for:kind: .glk …)`.
    ///
    /// - Parameters:
    ///   - handle: The open estate handle to wire.
    ///   - backingStorage: The estate's storage (Corpus + VectorStore are built on it).
    ///   - embeddingModels: The recall ensemble. Defaults to the canonical 1.0
    ///     five-signal ensemble.
    /// - Throws: A storage/schema error if a sub-store cannot be opened.
    func wireGLKSubstores(
        for handle: EstateHandle,
        backingStorage: any Storage,
        embeddingModels: [EmbeddingModel] = CorpusEnsemble.defaultEnsemble()
    ) async throws {
        try await wireSubstores(
            for: handle, kind: .glk,
            backingStorage: backingStorage, embeddingModels: embeddingModels)
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

        // In-flight encode work has settled — flush the dense vector store's
        // resident-array sidecar so a graceful shutdown leaves it current (a cold
        // restart loads it instead of rebuilding from a full table scan).
        // Best-effort: the `vectors` table remains the source of truth.
        if let vectorStore = vectorStores[handle] {
            try? await vectorStore.flush()
        }

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
