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

    // MARK: - Private init

    /// Construct an Estate around an already-opened store and a
    /// manifest that has already been validated against the kit's
    /// expected `bitmap_layout_version`. Parses `manifest.estateUUID`
    /// into a Foundation UUID, throwing `manifestMismatch` if the
    /// stored value is not a valid UUID string.
    private init(store: DrawerStore,
                 containerFP: ContainerFingerprintStore,
                 manifest: ManifestValues) throws {
        guard let uuid = UUID(uuidString: manifest.estateUUID) else {
            throw EstateError.manifestMismatch(
                key: ManifestKey.estateUUID.rawValue,
                found: manifest.estateUUID,
                expected: "<valid UUID string>"
            )
        }
        self.store = store
        self.containerFP = containerFP
        self._estateUUID = uuid
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
    /// - Parameters:
    ///   - storage: an already-constructed storage backend (SQLite or
    ///     in-memory). The caller owns its lifecycle.
    ///   - owner: credentials identifying the opening party. The
    ///     substrate only validates that `ownerIdentifier` is non-empty.
    /// - Throws:
    ///   - `EstateError.emptyOwnerIdentifier` if the owner identifier
    ///     is empty (raised before any storage call).
    ///   - `EstateError.substrateUnavailable(_:)` if the schema cannot
    ///     be opened.
    ///   - `EstateError.manifestMismatch(key:found:expected:)` if the
    ///     bitmap layout version is incompatible.
    public static func open(
        storage: any Storage,
        owner: OwnerCredentials
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
        // Establish the estate's Ed25519 federation identity on first
        // open. The keypair is the signing identity for federation
        // grants (DECISION_SYNCKIT_DESIGN_2026-05-19 §8); minting it once
        // and persisting both halves to the manifest makes the public key
        // stable across every subsequent open of the same storage. Key
        // generation is intrinsically random — like the estate UUID
        // minted at create — so it is exempt from the deterministic-engine
        // rule. See ManifestKey.ed25519PrivateKeyWrapped for the at-rest
        // wrapping note. Stored as base64 of the raw 32-byte forms.
        if manifest.ed25519PublicKey == nil {
            let privateKey = Curve25519.Signing.PrivateKey()
            try await store.setMeta(
                key: ManifestKey.ed25519PublicKey.rawValue,
                value: privateKey.publicKey.rawRepresentation.base64EncodedString()
            )
            try await store.setMeta(
                key: ManifestKey.ed25519PrivateKeyWrapped.rawValue,
                value: privateKey.rawRepresentation.base64EncodedString()
            )
        }
        let containerFP: ContainerFingerprintStore
        do {
            containerFP = try await ContainerFingerprintStore(storage: storage)
        } catch {
            throw EstateError.substrateUnavailable("\(error)")
        }
        // Backfill so the aggregate covers every active row and is
        // therefore sound to prune against. One full scan at open.
        let active = (try await store.allDrawers()).filter { $0.tombstonedAt == nil }
        try await containerFP.rebuildAll(activeDrawers: active)
        return try Estate(store: store, containerFP: containerFP, manifest: manifest)
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
        let manifest = try await store.readManifest()
        return try Estate(store: store, containerFP: containerFP, manifest: manifest)
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
        // Run the exact recall filter pipeline over the loaded rows. asOf-based
        // historical reconstruction is honored too (BitmapEvaluator reads the
        // audit log via `store`), so a frame's `asOf` projects the same state
        // it would on the full recall path.
        let admissible = try await BitmapEvaluator.evaluate(
            frame: frame, drawers: loaded, store: store)
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
    public func tunnelsFromWing(_ wing: String) async throws -> [Tunnel] {
        try await store.tunnelsFrom(wing: wing)
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

    // MARK: - Verb methods (added by LOCI_V035_14)
    //
    // The nine verbs (capture, recall, mutate, withdraw, expunge,
    // reanchor, learn, propose, associate) are declared as
    // `extension Estate` in EstateVerbs.swift once the frame types
    // exist. Splitting the verbs into mission 14 keeps each mission's
    // blast radius tractable; mission 13 ships a usable Estate handle.
}
