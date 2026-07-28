import Foundation
import CryptoKit
import PersistenceKit

/// Top-level handle to a single GeniusLocus estate.
///
/// An `Estate` is the application's only connection point to a
/// GeniusLocus. It owns a `DrawerStore`, loads and validates the
/// manifest on open, and provides typed access to the manifest and
/// estate UUID.
///
/// The nine verb methods (`capture`, `recall`, `mutate`, `withdraw`,
/// `expunge`, `reanchor`, `learn`, `propose`, `associate`) are added
/// by LOCI_V035_14 as extension methods once the frame types
/// (`CaptureFrame`, `RecallFrame`, etc.) exist. This mission delivers
/// the lifecycle and manifest-introspection surface only; that is
/// intentional, because a conforming `Estate` is useful on its own for
/// manifest inspection and bitmap-layout-version validation, and the
/// split keeps each mission's blast radius small.
///
/// Storage is injected. `Estate.open` and `Estate.create` take an
/// `any Storage` rather than a file path, matching the fleet
/// convention that a kit's source depends only on the PersistenceKit
/// protocol and never constructs a concrete backend itself. The
/// caller (an application, the MCP server, or a test) builds a
/// SQLiteStorage or an in-memory storage and hands it in.
///
/// Per GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md section 7.8.1.
public actor Estate {

    // MARK: - Bitmap layout compatibility

    /// The bitmap layout version this kit speaks. `Estate.open`
    /// refuses to open a database whose manifest carries a different
    /// value, throwing `EstateError.manifestMismatch(key:
    /// "bitmap_layout_version", ...)`. Bumped lock-step with any
    /// breaking change to a bitmap layout, see spec section 13.2.
    public static let expectedBitmapLayoutVersion: String = "v1.0"

    // MARK: - Private state

    /// The underlying store. Declared `internal` (not `private`) so
    /// that `extension Estate` in EstateVerbs.swift, which lives in a
    /// separate file in the same module, can reach the verb call
    /// sites (`store.addDrawer`, `store.mutateAdjective`, etc.) per
    /// spec section 7.8.1. No caller outside `LocusKit` can reach it.
    internal let store: DrawerStore

    /// Per-container OR-reduction aggregates (spec section 11.5),
    /// maintained for recall pruning (section 7.9.4 step 1). Built
    /// alongside the store over the same storage; backfilled on open.
    internal let containerFP: ContainerFingerprintStore

    /// The estate's containment tree store. Wings and rooms
    /// are nodes; the capture verb resolves wing/room display names to
    /// node IDs through this store's create-on-demand resolution (§7).
    /// Public so GeniusLocusKit's SubstrateNodeTopologyProvider can
    /// share this store instead of constructing a redundant one (NT-Q1).
    public let nodeStore: NodeStore

    /// Parsed UUID form of the manifest's `estate_uuid` row. Cached
    /// at init time because the value never changes for the lifetime
    /// of the file (the manifest's `estate_uuid` is set once at create
    /// time and treated as immutable per spec section 7.7).
    private let _estateUUID: UUID

    // MARK: - Test seam (fault injection)

    /// Identifies which internal read in `recall`/`liveRows` a forced
    /// fault should target. Each case maps 1:1 to a degraded-stage string
    /// so a force-test can drive each internal-read failure path
    /// independently and assert the precise stage the stream surfaces.
    public enum RecallInternalRead: Sendable, Equatable {
        /// The bounded corpus scan (`store.allDrawers`) — non-pruning path.
        case liveRows
        /// The room-fingerprint enumeration (`containerFP.roomLevelEntries`)
        /// — fingerprint-pruning path.
        case roomFingerprints
        /// A surviving room's drawer read (`store.drawersIn(wing:room:)`)
        /// — fingerprint-pruning path.
        case roomDrawerRead
        /// `BitmapEvaluator.evaluate`.
        case bitmapEval
        /// The opt-in recall-trace WRITE (`store.insertRecallTraces`). Unlike
        /// the read variants, this fault fires AFTER reads + eval succeed, so a
        /// forced `.traceWrite` yields a populated result WITH the
        /// `recall.trace_write_failed` stage — proving recall stays non-throwing
        /// while a lost trace is observable.
        case traceWrite
    }

    /// TEST-ONLY fault seam: when non-nil, the next `recall` forces the
    /// named internal read to fail, exercising the degraded-stage path
    /// without needing a genuinely-broken store. SINGLE-USE — `recall`
    /// reads and clears it so a subsequent recall behaves normally. Never
    /// set in production code; it has no production caller. Mirrors the
    /// GLK `_testForce*` seam pattern. The Rust port gates the equivalent
    /// seam behind the `test-seams` Cargo feature; Swift kits gate by the
    /// `_test`-prefix convention and this documented contract.
    var _testForceInternalReadError: RecallInternalRead?

    /// Arm the `_testForceInternalReadError` seam. TEST-ONLY.
    func _setTestForceInternalReadError(_ read: RecallInternalRead?) {
        _testForceInternalReadError = read
    }

    /// The identity key store used to persist and retrieve the estate's Ed25519
    /// private signing key. `KeychainEstateIdentityKeyStore` in production;
    /// callers inject `InMemoryEstateIdentityKeyStore` for tests.
    private let identityKeyStore: any EstateIdentityKeyStore

    /// In-memory cache of the estate's Ed25519 private signing key raw bytes,
    /// loaded from `identityKeyStore` at open time. Nil when the key is absent
    /// from the store (e.g. Keychain was wiped after the first open, or the
    /// estate was opened before the identity keypair existed). Grant signing
    /// throws at the call site when this is nil; the estate remains usable for
    /// all other operations.
    private let _privateSigningKeyData: Data?

    // MARK: - Private init

    /// Construct an Estate around an already-opened store and a
    /// manifest that has already been validated against the kit's
    /// expected `bitmap_layout_version`. Parses `manifest.estateUUID`
    /// into a Foundation UUID, throwing `manifestMismatch` if the
    /// stored value is not a valid UUID string.
    private init(store: DrawerStore,
                 containerFP: ContainerFingerprintStore,
                 nodeStore: NodeStore,
                 manifest: ManifestValues,
                 identityKeyStore: any EstateIdentityKeyStore,
                 privateSigningKeyData: Data?) throws {
        guard let uuid = UUID(uuidString: manifest.estateUUID) else {
            throw EstateError.manifestMismatch(
                key: ManifestKey.estateUUID.rawValue,
                found: manifest.estateUUID,
                expected: "<valid UUID string>"
            )
        }
        self.store = store
        self.containerFP = containerFP
        self.nodeStore = nodeStore
        self._estateUUID = uuid
        self.identityKeyStore = identityKeyStore
        self._privateSigningKeyData = privateSigningKeyData
    }

    // MARK: - Open

    /// Open an existing estate backed by `storage`.
    ///
    /// Validates that the manifest's `bitmap_layout_version` matches
    /// the kit's `expectedBitmapLayoutVersion`. Throws
    /// `EstateError.manifestMismatch` if the stored layout version is
    /// unrecognised, because the kit refuses to read a database
    /// written by a future schema whose bitmap bit positions may have
    /// shifted.
    ///
    /// On first open (when `ed25519_public_key` is absent from the manifest)
    /// a fresh Curve25519 Ed25519 keypair is minted. The public key is
    /// written to the manifest; the private key is stored in `identityKeyStore`
    /// (Keychain in production) and cached in memory for the lifetime of this
    /// `Estate` instance. The private key is never written to `estate_meta`:
    /// `manifest.value` is ordinary, unencrypted metadata readable by anyone
    /// with database or backup access. Mirrors Rust `Estate::open` post PR #8.
    ///
    /// On subsequent opens the private key is loaded from `identityKeyStore`
    /// and cached in memory. If the key is absent from the store (e.g. the
    /// Keychain was wiped), the estate opens successfully but grant signing
    /// will throw at the call site.
    ///
    /// - Parameters:
    ///   - storage: an already-constructed storage backend (SQLite or
    ///     in-memory). The caller owns its lifecycle.
    ///   - owner: credentials identifying the opening party. The
    ///     substrate only validates that `ownerIdentifier` is non-empty.
    ///   - identityKeyStore: the store used to persist and retrieve the
    ///     estate's Ed25519 private signing key. When nil (the default) it is
    ///     resolved from the storage backend: durable backends (SQLite,
    ///     PostgreSQL) use `KeychainEstateIdentityKeyStore`; an `.inMemory`
    ///     backend uses `InMemoryEstateIdentityKeyStore`, so an ephemeral
    ///     estate never persists an identity key to the login keychain
    ///     (branch estates, in-memory serving modes, and test estates were
    ///     each leaving one permanent keychain item per throwaway estate).
    ///     Callers serving a DURABLE estate from hydrated in-memory storage
    ///     must pass `KeychainEstateIdentityKeyStore()` explicitly so the
    ///     estate's real signing key is found — see GLK
    ///     `open(inMemory:owner:hydrateFrom:)`. Tests may still inject
    ///     `InMemoryEstateIdentityKeyStore` explicitly (required when the
    ///     test estate lives on temp-dir SQLite storage).
    /// - Throws:
    ///   - `EstateError.emptyOwnerIdentifier` if the owner identifier
    ///     is empty (raised before any storage call).
    ///   - `EstateError.substrateUnavailable(_:)` if the schema cannot
    ///     be opened.
    ///   - `EstateError.manifestMismatch(key:found:expected:)` if the
    ///     bitmap layout version is incompatible.
    ///   - `EstateError.keychainError(status:)` if the identity key store
    ///     fails to persist the newly-minted private key on first open.
    public static func open(
        storage: any Storage,
        owner: OwnerCredentials,
        identityKeyStore: (any EstateIdentityKeyStore)? = nil
    ) async throws -> Estate {
        guard !owner.ownerIdentifier.isEmpty else {
            throw EstateError.emptyOwnerIdentifier
        }
        let identityKeyStore = identityKeyStore ?? Self.defaultIdentityKeyStore(for: storage)
        let store: DrawerStore
        do {
            store = try await DrawerStore(storage: storage)
        } catch {
            throw EstateError.substrateUnavailable("\(error)")
        }
        let manifest = try await store.readManifest()
        // Validate bitmap layout version compatibility per spec
        // section 13.2: bitmap bit positions are part of the on-disk
        // contract, so a mismatched version requires an explicit
        // migration mission before this kit can read the data.
        if manifest.bitmapLayoutVersion != Self.expectedBitmapLayoutVersion {
            throw EstateError.manifestMismatch(
                key: ManifestKey.bitmapLayoutVersion.rawValue,
                found: manifest.bitmapLayoutVersion,
                expected: Self.expectedBitmapLayoutVersion
            )
        }
        // Parse the estate UUID early: it is used as the Keychain account key
        // (kSecAttrAccount = estate UUID string) to isolate each estate's
        // signing key. A malformed UUID surfaces as manifestMismatch here before
        // any key-store access, matching the same error the private init would
        // produce and avoiding a stale Keychain lookup against an invalid account.
        guard let estateID = UUID(uuidString: manifest.estateUUID) else {
            throw EstateError.manifestMismatch(
                key: ManifestKey.estateUUID.rawValue,
                found: manifest.estateUUID,
                expected: "<valid UUID string>"
            )
        }
        // Establish the estate's Ed25519 federation identity on first open.
        // The keypair is the signing credential for federation grants
        //; minting it once and
        // persisting the public half to the manifest makes the public key
        // stable across every subsequent open of the same storage. Key
        // generation is intrinsically random — like the estate UUID minted
        // at create — so it is exempt from the deterministic-engine rule.
        //
        // Security posture (data-movement privacy tiers, mirrors Rust Estate::open post PR #8):
        //   - The private key lives in the identity key store (Keychain in prod).
        //   - The private key is NEVER written to manifest.value: that table is
        //     ordinary metadata, unencrypted, visible to database and backup readers.
        //   - Only the public key is written to the manifest; it is safe to store
        //     there — a public key has no confidentiality requirement.
        var privateSigningKeyData: Data?
        if manifest.ed25519PublicKey == nil {
            // First open: mint a fresh Curve25519 keypair for this estate.
            let privateKey = Curve25519.Signing.PrivateKey()
            // Store the private key in the identity key store (Keychain) first.
            // If this throws, the public key has not yet been written, so the
            // estate remains in the pre-identity state on rollback — consistent.
            try identityKeyStore.storePrivateKey(
                privateKey.rawRepresentation,
                forEstateID: estateID
            )
            // Write only the public key to the manifest.
            try await store.setMeta(
                key: ManifestKey.ed25519PublicKey.rawValue,
                value: privateKey.publicKey.rawRepresentation.base64EncodedString()
            )
            // Cache the private key bytes in memory for this Estate instance.
            // Avoids a Keychain round-trip on the first issueGrant call.
            privateSigningKeyData = privateKey.rawRepresentation
        } else {
            // Subsequent open: load the private key from the identity key store.
            // Returns nil if the key is absent (e.g. the Keychain was wiped, or
            // this estate was opened with a different key store instance). The
            // estate remains fully openable; only grant signing will throw.
            privateSigningKeyData = try identityKeyStore.loadPrivateKey(forEstateID: estateID)
        }
        let containerFP: ContainerFingerprintStore
        do {
            containerFP = try await ContainerFingerprintStore(storage: storage)
        } catch {
            throw EstateError.substrateUnavailable("\(error)")
        }
        // NodeStore shares the same storage — schema already opened.
        let nodeStore = NodeStore(storage: storage)
        // ensure root node exists. createRoot is idempotent —
        // returns existing root if already seeded.
        _ = try await nodeStore.createRoot(displayName: "Estate", now: Date())
        // Backfill so the aggregate covers every active row and is
        // therefore sound to prune against. One full scan at open.
        let active = (try await store.allDrawers()).filter { $0.tombstonedAt == nil }
        let nodeNames = try await store.resolveNodeNames(
            parentNodeIds: active.map(\.parentNodeId))
        try await containerFP.rebuildAll(activeDrawers: active, nodeNames: nodeNames)
        return try Estate(
            store: store,
            containerFP: containerFP,
            nodeStore: nodeStore,
            manifest: manifest,
            identityKeyStore: identityKeyStore,
            privateSigningKeyData: privateSigningKeyData
        )
    }

    // MARK: - Create

    /// Create a new estate backed by `storage`, seeding it with the
    /// supplied manifest values. `DrawerStore(storage:)` opens the
    /// schema idempotently and writes the v1 manifest defaults, so
    /// callers can use `create` on a fresh storage without
    /// pre-checking existence.
    ///
    /// `owner_identifier` is always written from the `owner` argument.
    /// `estate_name` is written from `initialValues.estateName` when
    /// supplied and non-empty; other manifest fields keep their v1
    /// defaults.
    ///
    /// - Parameters:
    ///   - storage: an already-constructed storage backend.
    ///   - owner: credentials for the new estate's owner.
    ///   - initialValues: optional initial manifest values. Only
    ///     `estateName` is consumed here; other fields are written by
    ///     the substrate's first-open path.
    /// - Throws:
    ///   - `EstateError.emptyOwnerIdentifier` if the owner identifier
    ///     is empty.
    ///   - `EstateError.substrateUnavailable(_:)` if the schema cannot
    ///     be opened.
    public static func create(
        storage: any Storage,
        owner: OwnerCredentials,
        manifest initialValues: ManifestValues? = nil
    ) async throws -> Estate {
        guard !owner.ownerIdentifier.isEmpty else {
            throw EstateError.emptyOwnerIdentifier
        }
        let store: DrawerStore
        do {
            store = try await DrawerStore(storage: storage)
        } catch {
            throw EstateError.substrateUnavailable("\(error)")
        }
        // Always stamp the owner identifier; DrawerStore writes a
        // default sentinel at first open which this overrides.
        try await store.setMeta(
            key: ManifestKey.ownerIdentifier.rawValue,
            value: owner.ownerIdentifier
        )
        if let name = initialValues?.estateName, !name.isEmpty {
            try await store.setMeta(
                key: ManifestKey.estateName.rawValue,
                value: name
            )
        }
        // Write optional manifest fields from initialValues when supplied.
        // These are consumed by the GLK provision path (GLK_PROVISION_001) to
        // seed the kind-prefixed framework profile and zoom window from the
        // EstateProvisionParams at creation time so they survive restarts.
        if let iv = initialValues {
            if !iv.frameworkProfile.isEmpty {
                try await store.setMeta(
                    key: ManifestKey.frameworkProfile.rawValue,
                    value: iv.frameworkProfile
                )
            }
            // Zoom window bounds: write only when the provisioning params supply
            // non-default values (non-zero range). A zoomWindowLow of 0 with
            // zoomWindowHigh of 0 means "not specified" — the default manifest
            // row values are left intact for the existing Estate.create callers
            // that do not pass a zoom window.
            if iv.zoomWindowLow != 0 || iv.zoomWindowHigh != 0 {
                try await store.setMeta(
                    key: ManifestKey.zoomWindowLow.rawValue,
                    value: String(iv.zoomWindowLow)
                )
                try await store.setMeta(
                    key: ManifestKey.zoomWindowHigh.rawValue,
                    value: String(iv.zoomWindowHigh)
                )
            }
        }
        let containerFP: ContainerFingerprintStore
        do {
            containerFP = try await ContainerFingerprintStore(storage: storage)
        } catch {
            throw EstateError.substrateUnavailable("\(error)")
        }
        let nodeStore = NodeStore(storage: storage)
        // seed root node on create. createRoot is idempotent.
        _ = try await nodeStore.createRoot(displayName: "Estate", now: Date())
        let manifest = try await store.readManifest()
        // Estate.create does not mint the Ed25519 keypair — that happens in
        // Estate.open (the first open after create). The created estate carries
        // no identity key store and no cached private key; callers that need
        // grant signing must open the estate after creating it. The key store
        // is resolved by backend durability, matching open(), so a created
        // in-memory estate never references the Keychain.
        return try Estate(
            store: store,
            containerFP: containerFP,
            nodeStore: nodeStore,
            manifest: manifest,
            identityKeyStore: Self.defaultIdentityKeyStore(for: storage),
            privateSigningKeyData: nil
        )
    }

    /// The identity key store implied by the storage backend when the caller
    /// does not inject one. Identity persistence follows storage durability:
    /// an estate on an `.inMemory` backend is ephemeral, so persisting its
    /// freshly-minted signing key to the login keychain would orphan one
    /// permanent keychain item per throwaway estate (branch estates, in-memory
    /// serving modes, tests — observed as hundreds of
    /// "com.mootx01.estate.identity" entries in Keychain Access). Durable
    /// backends keep the Keychain default so a real estate's identity
    /// survives restarts.
    static func defaultIdentityKeyStore(for storage: any Storage) -> any EstateIdentityKeyStore {
        if case .inMemory = storage.configuration.backend {
            return InMemoryEstateIdentityKeyStore()
        }
        return KeychainEstateIdentityKeyStore()
    }

    // MARK: - Close

    /// Close the estate, flushing any pending writes. After calling
    /// `close()`, the estate must not be used.
    ///
    /// The injected storage owns the underlying connection; closing it
    /// is the caller's responsibility once the estate is released.
    /// `close()` exists today as a semantic signal for callers and as
    /// the API hook for an explicit teardown that a later mission will
    /// add. Implementing it now keeps the public surface stable across
    /// that future change.
    public func close() async throws {
        // Intentional no-op for the present substrate; the caller's
        // storage reference owns teardown.
    }

    // MARK: - Distilled representation (SPEC_DISTILLATION_STORAGE §4)

    /// Write the distilled representation of one drawer — all four
    /// representation columns in one atomic UPDATE. Delegates to
    /// `DrawerStore.setDistilledRepresentation`; see that method for the
    /// full contract (direct column write, no audit event, no index-feed
    /// involvement). This is the seam GLK's distillation paths (drain-stage
    /// and `moot_distill` sweep) write through.
    ///
    /// - Returns: Count of rows updated (0 = drawer not found).
    @discardableResult
    public func setDistilledRepresentation(
        drawerId: String,
        distilled: String,
        pipelineVersion: String,
        tokenCount: Int64,
        at generatedAt: Date
    ) async throws -> Int {
        try await store.setDistilledRepresentation(
            drawerId: drawerId,
            distilled: distilled,
            pipelineVersion: pipelineVersion,
            tokenCount: tokenCount,
            at: generatedAt)
    }

    // MARK: - Drawer enumeration

    /// Enumerate every drawer in the estate. Used by cross-row
    /// consumers (e.g. GLK's `feedAuditLog`) that need to walk the
    /// substrate's contents without a query frame. Delegates to the
    /// underlying store's `allDrawers()`.
    public func allDrawers() async throws -> [Drawer] {
        try await store.allDrawers()
    }

    /// Up to `limit` drawers in the estate (including tombstoned rows), in
    /// `filedAt`-ascending order, fully hydrated. Delegates to the store's
    /// bounded scan `allDrawers(hydrationLevel: .full, limit:)`, which applies
    /// the `LIMIT` at the storage tier so the I/O is O(min(N_estate, limit)),
    /// not O(N_estate)-then-truncate.
    ///
    /// `.full` hydration is deliberate: the maintenance reader inspects each
    /// drawer's state and tombstone fields, so the content blob is read too —
    /// no projection that could drop a field the scan needs. Passing `nil`
    /// reads the full corpus, identical to `allDrawers()`.
    ///
    /// Used by GLK to give the maintenance reader a bounded scan without
    /// NeuronKit reaching the store directly (B-1).
    public func allDrawers(limit: Int?) async throws -> [Drawer] {
        try await store.allDrawers(hydrationLevel: .full, limit: limit)
    }

    /// All drawers in the estate at the requested hydration level, ordered by
    /// `filedAt` ascending.
    ///
    /// This overload exposes `DrawerStore.allDrawers(hydrationLevel:limit:)` through
    /// the `Estate` boundary so callers outside LocusKit (e.g. GeniusLocusKit) can
    /// request a no-blob projection without reaching around the estate actor. At
    /// `.structured` or `.bitmapOnly`, the `content` column is NOT fetched from
    /// storage — all other columns (including `id`, `eventTime`, `filedAt`,
    /// `adjectiveBitmap`, `operationalBitmap`) are returned intact.
    ///
    /// Use `.structured` when you need drawer metadata (e.g. `id`, `eventTime`)
    /// without content blobs. Use `.full` only when content is required.
    ///
    /// Passing `nil` for `limit` scans the whole corpus. Passing a value applies
    /// `LIMIT` at the storage tier (O(min(N_estate, limit))).
    public func allDrawers(
        hydrationLevel: HydrationLevel,
        limit: Int?
    ) async throws -> [Drawer] {
        try await store.allDrawers(hydrationLevel: hydrationLevel, limit: limit)
    }

    /// Bounded page of active (non-tombstoned) drawers ordered by `id`
    /// ascending, optionally starting strictly after `afterID`. Exposes
    /// `DrawerStore.activeDrawersAfter(id:limit:)` through the `Estate`
    /// boundary so GeniusLocusKit's `reindexMissing` backfill can walk the
    /// drawers table in bounded, cursor-advancing pages instead of
    /// reloading the full table on every pass (MEDIUM perf fix — see
    /// `EncodeIntake.swift`).
    ///
    /// - Parameters:
    ///   - afterID: exclusive lower bound on `id`; `nil` starts from the
    ///     beginning of the table.
    ///   - limit: maximum rows to return; `LIMIT` is applied at the
    ///     storage tier.
    public func activeDrawersAfter(id afterID: String?, limit: Int) async throws -> [Drawer] {
        try await store.activeDrawersAfter(id: afterID, limit: limit)
    }

    /// The set of lineage IDs whose rows have been permanently erased (cluster C:
    /// `tombstonedAt IS NOT NULL`). Delegates to `DrawerStore.tombstonedLineageIDs()`,
    /// which reads the `lineageID` column directly via a storage-tier `.isNotNull`
    /// predicate without a full row decode — avoiding any timestamp-format sensitivity.
    ///
    /// Used by GLK's `tombstonedLineageIDs` passthrough so VaultKit can detect
    /// erased lineages without importing LocusKit directly (B-1).
    public func tombstonedLineageIDs() async throws -> Set<UUID> {
        try await store.tombstonedLineageIDs()
    }

    /// Every room-level container fingerprint (room non-empty) with its
    /// bitwise-OR aggregate over the container's active drawers. Delegates to
    /// the estate's `ContainerFingerprintStore.roomLevelEntries()`.
    ///
    /// The maintenance daemon's fingerprint-drift signal reads these through
    /// GLK as the live per-scope fingerprint (B-1 — NeuronKit never touches
    /// the store). No drawer scan happens: the OR aggregates are read straight
    /// from the `container_fingerprints` table the recall pruner maintains.
    public func roomLevelFingerprints() async throws
        -> [(wing: String, room: String, fingerprint: ContainerFingerprint)] {
        try await containerFP.roomLevelEntries()
    }

    /// Batch by-id drawer load. Returns the drawers matching `ids` in
    /// unspecified order, omitting ids with no row, via a single indexed
    /// `IN` query per chunk rather than a full-estate scan. The O(candidates)
    /// hydration path for recall's BM25/vector frontier. Tombstoned rows are
    /// returned unfiltered; callers apply their own liveness guard. Delegates
    /// to the underlying store's `getDrawers(ids:)`.
    public func getDrawers(ids: [String]) async throws -> [Drawer] {
        try await store.getDrawers(ids: ids)
    }

    /// Batch by-id drawer load at a chosen hydration level — the dense-first
    /// candidate-pool path. At `.structured`/`.bitmapOnly` the content blob is
    /// projected away and never read from storage (the returned drawers carry
    /// `content == ""`); at `.full` it reads every column. Delegates to the
    /// store's `getDrawers(ids:hydrationLevel:)`.
    public func getDrawers(ids: [String], hydrationLevel: HydrationLevel) async throws -> [Drawer] {
        try await store.getDrawers(ids: ids, hydrationLevel: hydrationLevel)
    }

    /// FRAME-AWARE by-id load. Loads `ids` by row, then applies the frame's
    /// bitmap/structured/content filter chain (via `BitmapEvaluator`, the exact
    /// pipeline `recall(_:)` runs) so the returned `admissible` set is precisely
    /// the frame-filtered subset of `ids` — identical semantics to running a
    /// `recall(frame)` scan and intersecting with `ids`, but as an O(candidates)
    /// by-id load rather than an O(estate) scan.
    ///
    /// This is the capability GLK's RecallDirector needs to build its
    /// `drawerIndex` honoring the actual recall frame, so that the BM25/vector
    /// corpus lanes drop exactly the candidates the frame state filter excludes
    /// (e.g. `.withdrawn` under the default `.currentlyBelieve`) — and STILL
    /// surface them when the frame overrides to `.usedToBelieve`. It is the
    /// frame-faithful parity of the Rust recall path, whose `drawer_index` is
    /// derived from `estate.recall(frame)` (frame-filtered) for any frame.
    ///
    /// The returned `loadedIDs` set reports every id whose row was physically
    /// returned by storage, REGARDLESS of whether it passed the frame filter.
    /// Callers use the distinction to gate a drop: an id that loaded but is
    /// absent from `admissible` failed the frame filter (drop it); an id absent
    /// from BOTH `admissible` and `loadedIDs` did not load (e.g. a transient
    /// partial read) and must be DEGRADED gracefully, never dropped. Tombstone
    /// exclusion is always enforced by `BitmapEvaluator` independent of the
    /// chain, so a tombstoned row never appears in `admissible`.
    ///
    /// `hydrationLevel` controls the body read. When the frame's chain carries a
    /// `.contentMatches` predicate the load is forced to `.full` so the substring
    /// match has the body; otherwise the caller's level is honored (`.structured`
    /// keeps the body-free fast path). Peer of the Rust
    /// `Estate::get_drawers_matching_frame`.
    public func getDrawers(
        ids: [String],
        matchingFrame frame: RecallFrame,
        hydrationLevel: HydrationLevel
    ) async throws -> FrameFilteredDrawers {
        // Content-tier predicates need the body for the substring match; force
        // .full in that case so the frame is evaluated faithfully. Otherwise the
        // caller's chosen level stands (the dense-first lanes load .structured).
        let needsContent = BitmapEvaluator.chainHasContentPredicate(frame.filterChain)
        let loadLevel: HydrationLevel = needsContent ? .full : hydrationLevel
        let loaded = try await store.getDrawers(ids: ids, hydrationLevel: loadLevel)
        let loadedIDs = Set(loaded.map(\.id))
        // Resolve wing/room names when the frame contains structured name
        // filters (.inWing, .inRoom). Without this, the evaluator's
        // structured tier sees empty names and excludes all drawers.
        let nodeNames: [String: (wing: String, room: String)]
        if BitmapEvaluator.chainHasStructuredNameFilter(frame.filterChain) {
            let parentIds = Set(loaded.map(\.parentNodeId))
            nodeNames = try await store.resolveNodeNames(parentNodeIds: Array(parentIds))
        } else {
            nodeNames = [:]
        }
        // Run the exact recall filter pipeline over the loaded rows. asOf-based
        // historical reconstruction is honored too (BitmapEvaluator reads the
        // audit log via `store`), so a frame's `asOf` projects the same state
        // it would on the full recall path.
        let admissible = try await BitmapEvaluator.evaluate(
            frame: frame, drawers: loaded, store: store, nodeNames: nodeNames)
        return FrameFilteredDrawers(admissible: admissible, loadedIDs: loadedIDs)
    }

    /// LATE BODY HYDRATION — read the full content blob for a specific id set.
    /// This is the dense-first hydration capability: the candidate pool is
    /// loaded body-free (`.structured`), selection runs on the dense signal,
    /// and only the survivor/returned ids are passed here to materialize their
    /// bodies. A thin alias of the `.full` by-id load, named for intent so
    /// callers (RecallDirector, and via a GLK-owned closure the higher lanes)
    /// read as "hydrate these bodies now." Tombstoned rows are returned
    /// unfiltered; callers apply their own liveness guard.
    public func hydrateBodies(ids: [String]) async throws -> [Drawer] {
        try await store.getDrawers(ids: ids, hydrationLevel: .full)
    }

    // MARK: - Association graph

    /// Every non-tombstoned tunnel whose source is `wing`, in stable
    /// filed-at order. The estate-level public read over the association
    /// graph (`DrawerStore.tunnelsFrom(wing:)`) — the edge set the
    /// structural reasoning lenses build their drawer graph from. A wing
    /// with no outgoing tunnels reads empty rather than throwing.
    /// Peer of the Rust `Estate::tunnels_from_wing`.
    ///
    /// Sensitivity gate: the store query filters only by source wing +
    /// tombstone, so it would return restricted/secret tunnel edges
    /// (endpoint ids, free-form labels, adjective bitmaps) that the drawer
    /// recall pipeline excludes by default. Apply the same no-claims
    /// sensitivity ceiling BitmapEvaluator inserts for drawers — Normal
    /// tier (normal + elevated) visible, restricted/secret excluded — so a
    /// reasoning lens reading the graph never sees an edge above the
    /// default recall ceiling. Synthetic containment edges carry
    /// adjectiveBitmap 0 (Normal) and always pass. Mirrors the Rust
    /// `Estate::tunnels_from_wing` gate; enforced at the source so every
    /// caller is covered.
    ///
    /// `includingRestricted` is the ONE sanctioned widening: the vault
    /// export's `.believedIncludingPrivate` scope — the owner's explicit
    /// opt-in for Private-tier bulk export — must carry
    /// provenance tunnels to restricted drawers, mirroring the drawer-side
    /// tier rule (`VaultExportScope.includesPrivateTier`). Secret-tier edges
    /// are excluded UNCONDITIONALLY — no parameter widens past restricted,
    /// matching the drawer side where secret never bulk-exports.
    public func tunnelsFromWing(
        _ wing: String,
        includingRestricted: Bool = false
    ) async throws -> [Tunnel] {
        try await store.tunnelsFrom(wing: wing)
            .filter {
                switch $0.adjectiveSensitivity {
                case .normal, .elevated: return true
                case .restricted: return includingRestricted
                case .secret: return false
                }
            }
    }

    // MARK: - Dreaming substrate reads

    /// Recall-trace rows whose `recalledAt` falls in `[since, now]`. The
    /// two-sided window the dreaming daemon uses when it mines the reward
    /// signal for a cycle. Delegates to `DrawerStore.recentRecallTraces`.
    public func recentRecallTraces(since: Date, now: Date) async throws -> [RecallTraceItem] {
        try await store.recentRecallTraces(since: since, now: now)
    }

    /// All non-tombstoned tunnels across all wings, in filed-at order.
    /// Used by the dreaming daemon to suppress candidate proposals that
    /// already have a Tunnel. Delegates to `DrawerStore.allTunnels`.
    public func allTunnels() async throws -> [Tunnel] {
        try await store.allTunnels()
    }

    /// All confirmed-active, non-retired tunnels across all wings.
    ///
    /// Active-edge view: only tunnels with `lifecycle == .active` (bits 3–5 = 0)
    /// and `isRetired == false` (bit 13 clear) are returned. Proposed, withdrawn,
    /// and superseded tunnels are excluded; full history is reachable via
    /// `allTunnels()`. Delegates to `DrawerStore.allActiveTunnels`.
    public func allActiveTunnels() async throws -> [Tunnel] {
        try await store.allActiveTunnels()
    }

    /// Insert a tunnel directly into the estate store.
    ///
    /// Delegates to `DrawerStore.addTunnel`. Conflicting IDs surface as
    /// `duplicateKey`. Declared `internal` so it is NOT part of the public
    /// API surface — test files reach it via `@testable import LocusKit`.
    /// This prevents MCP-layer callers from inserting tunnels that bypass the
    /// proposed → active review cycle that `moot_link_memories` enforces.
    internal func addTunnel(_ t: Tunnel) async throws {
        try await store.addTunnel(t)
    }

    /// Flip bit 13 of `operationalBitmap` to retire a tunnel.
    ///
    /// Throws `LocusKitError.tunnelNotFound` if no non-tombstoned tunnel exists for
    /// `tunnelId`. Delegates to `DrawerStore.retireTunnel(id:changedBy:now:)`.
    public func retireTunnel(id tunnelId: String, changedBy: String, now: Date) async throws {
        try await store.retireTunnel(id: tunnelId, changedBy: changedBy, now: now)
    }

    /// Clear bit 13 of `operationalBitmap` to un-retire a tunnel.
    ///
    /// Reverses a prior `retireTunnel`. Throws `LocusKitError.tunnelNotFound` if no
    /// non-tombstoned tunnel exists for `tunnelId`. Delegates to
    /// `DrawerStore.unretireTunnel(id:changedBy:now:)`.
    public func unretireTunnel(id tunnelId: String, changedBy: String, now: Date) async throws {
        try await store.unretireTunnel(id: tunnelId, changedBy: changedBy, now: now)
    }

    /// Delete recall-trace rows whose `recalledAt` is strictly before
    /// `cutoff`. Returns the number of rows deleted.
    ///
    /// Called by the dreaming daemon after each reward sweep to keep the
    /// recall_trace table bounded. The cutoff must be derived from the
    /// caller's deterministic `now` — never from `Date()` inside an engine.
    ///
    /// - Parameter cutoff: rows with `recalledAt < cutoff` are deleted.
    /// - Returns: the number of rows deleted.
    @discardableResult
    public func pruneRecallTraces(olderThan cutoff: Date) async throws -> Int {
        try await store.pruneRecallTraces(olderThan: cutoff)
    }

    /// Bulk-mark trace rows for a drawer target within a time window.
    ///
    /// Delegates to `DrawerStore.markRecallTracesUsed(target:since:now:)`.
    /// Called by the GLK `markRecallUsed` verb on behalf of ARIA — ARIA
    /// decides "drawer D was used", GLK routes it here. Returns the number
    /// of rows whose `used` bit was flipped.
    ///
    /// - Parameters:
    ///   - target: drawer id whose live trace rows to mark.
    ///   - since:  lower bound (inclusive) of the time window.
    ///   - now:    upper bound (inclusive) of the time window.
    @discardableResult
    public func markRecallTracesUsed(target: String, since: Date, now: Date) async throws -> Int {
        try await store.markRecallTracesUsed(target: target, since: since, now: now)
    }

    /// Count all rows in the recall_trace table. Delegates to
    /// `DrawerStore.countRecallTraces`. Used by estate-status reporting.
    public func countRecallTraces() async throws -> Int {
        try await store.countRecallTraces()
    }

    /// Count all rows in the `drawers` table via a SQL `COUNT(*)` — bypasses
    /// row-decode entirely, so corrupt rows are counted. Used by the vault-export
    /// fail-loud path to distinguish "estate is genuinely empty" from "all rows
    /// are corrupt". Delegates to `DrawerStore.countDrawerRows`. Mirrors Rust
    /// `Estate::count_drawer_rows`.
    public func countDrawerRows() async throws -> Int {
        try await store.countDrawerRows()
    }

    /// Count all rows in the `tunnels` table via a SQL `COUNT(*)` — O(1), bypasses
    /// row-decode. Delegates to `DrawerStore.countTunnelRows`. Mirrors Rust
    /// `Estate::count_tunnel_rows`.
    public func countTunnelRows() async throws -> Int {
        try await store.countTunnelRows()
    }

    /// Count all rows in the `kg_facts` table via a SQL `COUNT(*)` — O(1), bypasses
    /// row-decode. Delegates to `DrawerStore.countKGFactRows`. Mirrors Rust
    /// `Estate::count_kg_fact_rows`.
    public func countKGFactRows() async throws -> Int {
        try await store.countKGFactRows()
    }

    // MARK: - Unfiltered full-corpus reads (recall surface)

    /// All proposals estate-wide, ordered by `filedAt` ascending.
    /// Estate-level pass-through over `DrawerStore.allProposals`.
    /// Peer of the Rust `Estate::all_proposals`.
    public func allProposals() async throws -> [Proposal] {
        try await store.allProposals()
    }

    /// All non-tombstoned associations estate-wide, ordered by `filedAt`
    /// ascending. Estate-level pass-through over `DrawerStore.allAssociations`.
    /// Peer of the Rust `Estate::all_associations`.
    public func allAssociations() async throws -> [Association] {
        try await store.allAssociations()
    }

    /// All non-tombstoned learned references estate-wide, ordered by
    /// `filedAt` ascending. Estate-level pass-through over
    /// `DrawerStore.allLearnedReferences`.
    /// Peer of the Rust `Estate::all_learned_references`.
    public func allLearnedReferences() async throws -> [LearnedReference] {
        try await store.allLearnedReferences()
    }

    /// All kg-facts estate-wide in the RowState Cluster-A (active) set —
    /// `g_state_cluster < RowState.activeClusterUpperBoundRaw` (16) —
    /// ordered by `filedAt` ascending. Estate-level pass-through over
    /// `DrawerStore.allKGFacts`.
    /// Peer of the Rust `Estate::all_kg_facts`.
    public func allKGFacts() async throws -> [KGFact] {
        try await store.allKGFacts()
    }

    /// All kg-facts estate-wide regardless of lifecycle state — active AND
    /// retired — ordered by `filedAt` ascending. Estate-level pass-through
    /// over `DrawerStore.allKGFactsIncludingRetired`.
    /// Peer of the Rust `Estate::all_kg_facts_including_retired`.
    public func allKGFactsIncludingRetired() async throws -> [KGFact] {
        try await store.allKGFactsIncludingRetired()
    }

    /// All non-tombstoned diary entries estate-wide, ordered by `filedAt`
    /// ascending. Estate-level pass-through over `DrawerStore.allDiaryEntries`.
    /// Peer of the Rust `Estate::all_diary_entries`.
    public func allDiaryEntries() async throws -> [DiaryEntry] {
        try await store.allDiaryEntries()
    }

    // MARK: - Node-tree name resolution

    /// Resolve parentNodeId UUIDs to display-name pairs (wing, room).
    /// Higher kits call this to obtain display names after node-tree integrity
    /// removed them from the Drawer struct.
    public func resolveNodeNames(
        parentNodeIds: [String]
    ) async throws -> [String: (wing: String, room: String)] {
        try await store.resolveNodeNames(parentNodeIds: parentNodeIds)
    }

    // MARK: - Manifest and identity

    /// Typed snapshot of the estate manifest.
    ///
    /// Re-reads from the backing store on each access so callers see
    /// any changes made via `setMeta` (today: `estate_name` updates
    /// after create; later: any verb that mutates a manifest row).
    /// Callers that need a stable snapshot should bind the value:
    /// `let m = try await estate.manifest`.
    public var manifest: ManifestValues {
        get async throws { try await store.readManifest() }
    }

    /// The estate's stable UUID, parsed from the manifest at open
    /// time. Identical across all opens of the same database file,
    /// because estate identity is a property of the substrate, not the
    /// handle.
    public var estateUUID: UUID { _estateUUID }

    /// The raw 32-byte Curve25519 Ed25519 private signing key, loaded from the
    /// identity key store at open time and cached in memory for this Estate's
    /// lifetime.
    ///
    /// Returns `nil` when the key is absent from the store — e.g. after a
    /// Keychain wipe, or when the estate was opened with an `InMemoryEstateIdentityKeyStore`
    /// that did not contain the key. In that case
    /// `GeniusLocusKit.VerbSurface.issueGrant` throws
    /// `GeniusLocusKitError.invalidManifest` at the signing step.
    ///
    /// Callers outside GeniusLocusKit should not need this; grant issuance
    /// is the only use of the private key in the substrate layer.
    public func retrievePrivateSigningKeyData() -> Data? {
        _privateSigningKeyData
    }

    // MARK: - Estate metadata (consumer key-value surface)

    /// Read a per-estate metadata value by key, or `nil` on miss.
    ///
    /// This is the public, lowest-level key-value surface over the estate
    /// manifest table (spec §5.9) — the "future verb surface" the manifest
    /// accessor anticipated. The substrate OWNS this durable storage; upper
    /// layers (e.g. NeuronKit's dreaming/maintenance daemons) persist their
    /// own state here THROUGH the estate's public interface rather than
    /// reaching around the substrate to a host-owned store (Interface Rules:
    /// features are owned at the lowest level; data flows through public
    /// interfaces).
    ///
    /// Consumers MUST namespace their keys (e.g. `"neuronkit.dreaming.policy"`)
    /// to avoid collision with the typed v1 manifest keys in `ManifestKey`.
    /// The value round-trips verbatim and survives restarts (the manifest
    /// table is durable).
    public func meta(key: String) async throws -> String? {
        try await store.getMeta(key: key)
    }

    /// Write a per-estate metadata value (upsert on `key`).
    ///
    /// See `meta(key:)` for the ownership rationale and the key-namespacing
    /// requirement. The write is durable and visible to a subsequent
    /// `meta(key:)` read (including across a restart).
    public func setMeta(key: String, value: String) async throws {
        try await store.setMeta(key: key, value: value)
    }

    // MARK: - Verb methods (added by LOCI_V035_14)
    //
    // The nine verbs (capture, recall, mutate, withdraw, expunge,
    // reanchor, learn, propose, associate) are declared as
    // `extension Estate` in EstateVerbs.swift once the frame types
    // exist. Splitting the verbs into mission 14 keeps each mission's
    // blast radius tractable; mission 13 ships a usable Estate handle.
}
