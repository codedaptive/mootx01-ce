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
