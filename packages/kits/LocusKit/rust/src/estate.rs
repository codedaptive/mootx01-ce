//! Estate handle. Ports `Estate.swift` (the lifecycle surface).
//!
//! Top-level handle to a single GeniusLocus estate. An `Estate` is the
//! application's only connection point to a GeniusLocus. It owns a
//! `DrawerStore` (trait object today, concrete impls land with the
//! sub-missions named in MISSION_LP_1B_SCHEMA_ESTATE.md), validates
//! the manifest on open, and provides typed access to the manifest
//! and estate UUID.
//!
//! The nine verb methods (`capture`, `recall`, `mutate`, `withdraw`,
//! `expunge`, `reanchor`, `learn`, `propose`, `associate`) live in
//! `estate_verbs.rs` as inherent methods on `Estate` once the verb
//! frames exist. The audit / history methods (`audit_trail`,
//! `bitmap_state`) live in `estate_audit.rs`. Splitting the spine
//! from the verbs mirrors the Swift split into `Estate.swift` /
//! `EstateAudit.swift` / `EstateVerbs.swift` and keeps each
//! sub-mission's blast radius tractable.
//!
//! Per `GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md` §7.8.1.

use crate::drawer_store::DrawerStore;
use crate::estate_types::{EstateError, OwnerCredentials};
use crate::manifest::{ManifestKey, ManifestValues};
use crate::node_store::NodeStore;
use ed25519_dalek::SigningKey;
use rand_core::OsRng;
use std::sync::Arc;
use uuid::Uuid;

// MARK: - Bitmap layout compatibility

/// The bitmap layout version this kit speaks. `Estate::open` refuses
/// to open a backing store whose manifest carries a different value,
/// returning `EstateError::ManifestMismatch { key:
/// "bitmap_layout_version", ... }`. Bumped lock-step with any
/// breaking change to a bitmap layout, see spec §13.2.
pub const EXPECTED_BITMAP_LAYOUT_VERSION: &str = "v1.0";

// MARK: - Estate

/// Top-level handle to a single estate.
///
/// Cloneable because the contained store is an `Arc`; clones share the
/// same underlying backend. The estate is `Send + Sync` so it crosses
/// thread boundaries without further wrapping. The Swift port models
/// the same value as an `actor` to serialise mutation; the Rust port
/// leaves serialisation to the concrete `DrawerStore` impl (the future
/// SQLite-backed store will hold an internal mutex, the in-memory
/// future test store likewise — same shape, different mechanism).
#[derive(Clone)]
pub struct Estate {
    // (manual Debug impl below; we cannot derive because
    // `Arc<dyn DrawerStore>` carries no Debug bound by design — adding
    // one to the trait would force every concrete store to print its
    // internals through any indirect log surface.)
    /// The underlying store. Held as `Arc<dyn DrawerStore>` so the
    /// estate is cheap to clone and the concrete impl is decided by
    /// the sub-mission that constructs the store. The Swift comment
    /// "Declared internal so EstateVerbs.swift can reach it" maps to
    /// the `pub(crate)` visibility here — `estate_verbs.rs` and
    /// `estate_audit.rs` reach the store, external callers do not.
    pub(crate) store: Arc<dyn DrawerStore>,

    /// The estate's containment tree store. Wings and rooms
    /// are nodes; the capture verb resolves wing/room display names to
    /// node IDs through this store's create-on-demand resolution (§7).
    /// Wrapped in Arc so Estate remains Clone.
    pub(crate) node_store: Option<Arc<NodeStore>>,

    /// Parsed UUID form of the manifest's `estate_uuid` row. Cached at
    /// init time because the value never changes for the lifetime of
    /// the backing store (the manifest's `estate_uuid` is set once at
    /// create time and treated as immutable per spec §7.7).
    estate_uuid: Uuid,

    /// TEST-ONLY single-use fault seam for `recall` internal reads.
    /// Encoded as an `AtomicU8` (a `RecallInternalRead` discriminant, or
    /// `0` for "no fault") so `recall(&self, ...)` can consume it through
    /// a shared reference and clear it for the next call without needing
    /// `&mut self`. `AtomicU8` keeps `Estate: Send + Sync`. Compiled out
    /// entirely unless the `test-seams` feature (or a test build) is
    /// active — zero production footprint. Mirrors the Swift
    /// `Estate._testForceInternalReadError` seam. Spec § 7.8.1 fault path.
    #[cfg(any(test, feature = "test-seams"))]
    pub(crate) test_force_internal_read_error: std::sync::Arc<std::sync::atomic::AtomicU8>,

    /// TEST-ONLY single-use fault seam for `seal_expunge_orphan_audit`.
    /// When `true`, the next call to `seal_expunge_orphan_audit` returns
    /// `LocusKitError::InvalidContent("forced orphan-seal failure")` and
    /// clears the flag. This drives the double-failure path in GLK's
    /// `expunge` coordinator: step-2 vector delete fails AND the orphan
    /// audit cannot be recorded. Used to verify the coordinator folds
    /// both failure reasons into the returned error without swallowing
    /// the seal error. Wrapped in `Arc<AtomicBool>` so `Estate: Clone`
    /// is preserved — clones share the same seam instance. Compiled out
    /// in production builds.
    #[cfg(any(test, feature = "test-seams"))]
    pub(crate) test_force_orphan_seal_error: std::sync::Arc<std::sync::atomic::AtomicBool>,
}

/// Which internal read inside `recall`/`live_rows` a forced fault targets.
/// Each variant maps 1:1 to a degraded-stage string so a force-test can
/// drive each internal-read failure path independently. The `u8`
/// discriminants are the values stored in the `AtomicU8` seam (0 is
/// reserved for "no fault").
#[cfg(any(test, feature = "test-seams"))]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum RecallInternalRead {
    /// The bounded corpus scan (`all_drawers_bounded*`) — non-pruning path.
    LiveRows = 1,
    /// The room-fingerprint enumeration (`room_level_fingerprints`) —
    /// fingerprint-pruning path.
    RoomFingerprints = 2,
    /// A surviving room's drawer read (`drawers_in_wing_room`) —
    /// fingerprint-pruning path.
    RoomDrawerRead = 3,
    /// `BitmapEvaluator::evaluate`.
    BitmapEval = 4,
    /// The opt-in recall-trace WRITE (`store.insert_recall_traces`). Unlike the
    /// read variants, this fault fires AFTER reads + eval succeed, so a forced
    /// `TraceWrite` yields a populated result WITH the `recall.trace_write_failed`
    /// stage — proving recall stays non-throwing while a lost trace is observable.
    TraceWrite = 5,
}

impl std::fmt::Debug for Estate {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Estate")
            .field("estate_uuid", &self.estate_uuid)
            .finish_non_exhaustive()
    }
}

impl Estate {
    // -----------------------------------------------------------------
    // open
    // -----------------------------------------------------------------

    /// Open an existing estate backed by `store`.
    ///
    /// Validates that the manifest's `bitmap_layout_version` matches
    /// the kit's `EXPECTED_BITMAP_LAYOUT_VERSION`. Returns
    /// `EstateError::ManifestMismatch` if the stored layout version is
    /// unrecognised — the kit refuses to read a database written by a
    /// future schema whose bitmap bit positions may have shifted.
    ///
    /// # Parameters
    /// - `store`: an already-constructed `DrawerStore` impl. The
    ///   caller owns its lifecycle.
    /// - `owner`: credentials identifying the opening party. The
    ///   substrate only validates that `owner_identifier` is
    ///   non-empty.
    ///
    /// # Errors
    /// - `EstateError::EmptyOwnerIdentifier` if the owner identifier
    ///   is empty (raised before any store call).
    /// - `EstateError::SubstrateUnavailable(_)` if the manifest cannot
    ///   be read.
    /// - `EstateError::ManifestMismatch` if the bitmap layout version
    ///   is incompatible, or `estate_uuid` does not parse as a UUID.
    pub fn open(
        store: Arc<dyn DrawerStore>,
        owner: OwnerCredentials,
    ) -> Result<Estate, EstateError> {
        if owner.owner_identifier.is_empty() {
            return Err(EstateError::EmptyOwnerIdentifier);
        }
        let manifest = store
            .read_manifest()
            .map_err(|e| EstateError::SubstrateUnavailable(e.to_string()))?;

        // Validate bitmap layout version compatibility per spec §13.2:
        // bitmap bit positions are part of the on-disk contract, so a
        // mismatched version requires an explicit migration mission
        // before this kit can read the data.
        if manifest.bitmap_layout_version != EXPECTED_BITMAP_LAYOUT_VERSION {
            return Err(EstateError::ManifestMismatch {
                key: ManifestKey::BitmapLayoutVersion.as_str().to_string(),
                found: manifest.bitmap_layout_version,
                expected: EXPECTED_BITMAP_LAYOUT_VERSION.to_string(),
            });
        }
        Estate::from_manifest(store, manifest)
    }

    // -----------------------------------------------------------------
    // create
    // -----------------------------------------------------------------

    /// Create a new estate backed by `store`, seeding it with the
    /// supplied manifest values. Callers can use `create` on a fresh
    /// store; the concrete impl is expected to open the schema
    /// idempotently and write the v1 manifest defaults so that
    /// `read_manifest` returns a populated value immediately after the
    /// constructor.
    ///
    /// `owner_identifier` is always written from `owner`.
    /// `estate_name` is written from `initial_values.estate_name`
    /// when supplied and non-empty; other manifest fields keep their
    /// v1 defaults.
    ///
    /// # Errors
    /// - `EstateError::EmptyOwnerIdentifier` if the owner identifier
    ///   is empty.
    /// - `EstateError::SubstrateUnavailable(_)` if a store write or
    ///   the post-create manifest read fails.
    /// - `EstateError::ManifestMismatch` if the freshly-read manifest
    ///   carries an unparseable `estate_uuid`.
    pub fn create(
        store: Arc<dyn DrawerStore>,
        owner: OwnerCredentials,
        initial_values: Option<&ManifestValues>,
    ) -> Result<Estate, EstateError> {
        if owner.owner_identifier.is_empty() {
            return Err(EstateError::EmptyOwnerIdentifier);
        }
        // Always stamp the owner identifier; the concrete store writes
        // a default sentinel at first open which this overrides.
        store
            .set_meta(
                ManifestKey::OwnerIdentifier.as_str(),
                &owner.owner_identifier,
            )
            .map_err(|e| EstateError::SubstrateUnavailable(e.to_string()))?;
        if let Some(values) = initial_values {
            if !values.estate_name.is_empty() {
                store
                    .set_meta(ManifestKey::EstateName.as_str(), &values.estate_name)
                    .map_err(|e| EstateError::SubstrateUnavailable(e.to_string()))?;
            }
        }
        let manifest = store
            .read_manifest()
            .map_err(|e| EstateError::SubstrateUnavailable(e.to_string()))?;
        Estate::from_manifest(store, manifest)
    }

    // -----------------------------------------------------------------
    // close
    // -----------------------------------------------------------------

    /// Close the estate, flushing any pending writes. After calling
    /// `close`, the estate must not be used.
    ///
    /// The injected store owns the underlying connection; closing it
    /// is the caller's responsibility once the estate is released.
    /// `close` exists today as a semantic signal for callers and as
    /// the API hook for an explicit teardown that a later mission will
    /// add. Implementing it now keeps the public surface stable across
    /// that future change.
    pub fn close(&self) -> Result<(), EstateError> {
        // Intentional no-op for the present substrate; the caller's
        // store reference owns teardown. Same shape as Swift's
        // `Estate.close()`.
        Ok(())
    }

    // -----------------------------------------------------------------
    // Manifest and identity
    // -----------------------------------------------------------------

    /// Typed snapshot of the estate manifest.
    ///
    /// Re-reads from the backing store on each access so callers see
    /// any changes made via the future verb surface. Callers that need
    /// a stable snapshot should bind the value.
    pub fn manifest(&self) -> Result<ManifestValues, EstateError> {
        self.store
            .read_manifest()
            .map_err(|e| EstateError::SubstrateUnavailable(e.to_string()))
    }

    /// Read a per-estate metadata value by key, or `None` on miss.
    ///
    /// The public, lowest-level key-value surface over the estate manifest
    /// table (spec §5.9) — the "future verb surface" the manifest accessor
    /// anticipated. The substrate OWNS this durable storage; upper layers
    /// (e.g. NeuronKit's dreaming/maintenance daemons) persist their own
    /// state here THROUGH the estate's public interface rather than reaching
    /// around the substrate to a host-owned store (Interface Rules: features
    /// owned at the lowest level; data flows through public interfaces).
    ///
    /// Consumers MUST namespace their keys (e.g. `"neuronkit.dreaming.policy"`)
    /// to avoid collision with the typed v1 manifest keys in `ManifestKey`.
    /// The value round-trips verbatim and survives restarts (the manifest
    /// table is durable). Mirrors Swift `Estate.meta(key:)`.
    pub fn meta(&self, key: &str) -> Result<Option<String>, EstateError> {
        self.store
            .get_meta(key)
            .map_err(|e| EstateError::SubstrateUnavailable(e.to_string()))
    }

    /// Write a per-estate metadata value (upsert on `key`).
    ///
    /// See `meta` for the ownership rationale and the key-namespacing
    /// requirement. The write is durable and visible to a subsequent `meta`
    /// read (including across a restart). Mirrors Swift `Estate.setMeta(key:value:)`.
    pub fn set_meta(&self, key: &str, value: &str) -> Result<(), EstateError> {
        self.store
            .set_meta(key, value)
            .map_err(|e| EstateError::SubstrateUnavailable(e.to_string()))
    }

    /// The estate's stable UUID, parsed from the manifest at open time.
    /// Identical across all opens of the same backing store, because
    /// estate identity is a property of the substrate, not the handle.
    pub fn estate_uuid(&self) -> Uuid {
        self.estate_uuid
    }

    /// Public accessor for the estate's node store.
    /// Consumers outside LocusKit (e.g. GeniusLocusKit, VaultKit) need
    /// to resolve drawer `parent_node_id` values to display names via
    /// `NodeStore::get_node`. Returns `None` for legacy estates opened
    /// without a node tree.
    pub fn node_store(&self) -> Option<&Arc<NodeStore>> {
        self.node_store.as_ref()
    }

    // -----------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------

    /// Construct an `Estate` around an already-validated manifest.
    /// Parses `manifest.estate_uuid` into a `Uuid`, returning
    /// `ManifestMismatch` if the stored value is not a valid UUID
    /// string. Internal so callers always go through `open` / `create`.
    fn from_manifest(
        store: Arc<dyn DrawerStore>,
        manifest: ManifestValues,
    ) -> Result<Estate, EstateError> {
        let uuid =
            Uuid::parse_str(&manifest.estate_uuid).map_err(|_| EstateError::ManifestMismatch {
                key: ManifestKey::EstateUUID.as_str().to_string(),
                found: manifest.estate_uuid.clone(),
                expected: "<valid UUID string>".to_string(),
            })?;
        // Establish the estate's Ed25519 federation identity on first
        // open. The keypair is the signing identity for federation grants
        //; minting it once and
        // persisting the public half to the manifest makes the public key
        // stable across every subsequent open. Key generation is
        // intrinsically random — like the estate UUID minted at create —
        // so it is exempt from the deterministic-engine rule. The private
        // signing key is intentionally not persisted here: the manifest is
        // a normal key/value table and row encryption does not protect
        // manifest.value, so storing raw key bytes here would expose the
        // estate identity to database/backup readers. Mirrors Swift Estate.open.
        if manifest.ed25519_public_key.is_none() {
            use base64::Engine;
            let b64 = base64::engine::general_purpose::STANDARD;
            let signing_key = SigningKey::generate(&mut OsRng);
            let pub_b64 = b64.encode(signing_key.verifying_key().as_bytes());
            store
                .set_meta(ManifestKey::Ed25519PublicKey.as_str(), &pub_b64)
                .map_err(|e| EstateError::SubstrateUnavailable(e.to_string()))?;
        }
        // Backfill the per-container OR aggregate from the active drawer set
        // so it covers every active row and is therefore sound to prune
        // against (spec § 11.5). One full scan at open. Mirrors Swift
        // `Estate.open`/`create`'s `containerFP.rebuildAll(activeDrawers:)`.
        // On a fresh estate (create) this is a cheap no-op — no drawers yet.
        // `now` is sourced from the manifest's `last_modified` row rather than
        // a system clock, honouring the deterministic-engine rule: the
        // aggregate's `updatedAt` stamp is reproducible from on-disk state.
        store
            .rebuild_container_fingerprints(manifest.last_modified)
            .map_err(|e| EstateError::SubstrateUnavailable(e.to_string()))?;
        // node-tree integrity NT-L2: construct NodeStore from the same storage that
        // backs the DrawerStore. The `storage()` trait method returns the
        // underlying Storage so NodeStore shares the same connection.
        let node_store = store.storage().map(|s| Arc::new(NodeStore::new(s, None)));
        // seed root node. create_root is idempotent — returns
        // existing root if already seeded.
        if let Some(ref ns) = node_store {
            ns.create_root("Estate", manifest.last_modified)
                .map_err(|e| EstateError::SubstrateUnavailable(e.to_string()))?;
        }
        Ok(Estate {
            store,
            node_store,
            estate_uuid: uuid,
            #[cfg(any(test, feature = "test-seams"))]
            test_force_internal_read_error: std::sync::Arc::new(
                std::sync::atomic::AtomicU8::new(0),
            ),
            #[cfg(any(test, feature = "test-seams"))]
            test_force_orphan_seal_error: std::sync::Arc::new(
                std::sync::atomic::AtomicBool::new(false),
            ),
        })
    }

    /// TEST-ONLY: arm the single-use `recall` internal-read fault seam so the
    /// next `recall` forces `read` to fail, surfacing its named degraded
    /// stage without a genuinely-broken store. `recall` consumes and clears
    /// the seam, so a subsequent recall behaves normally. Mirrors Swift
    /// `Estate._setTestForceInternalReadError`. Never call in production code.
    #[cfg(any(test, feature = "test-seams"))]
    pub fn set_test_force_internal_read_error(&self, read: Option<RecallInternalRead>) {
        let v = read.map(|r| r as u8).unwrap_or(0);
        self.test_force_internal_read_error
            .store(v, std::sync::atomic::Ordering::SeqCst);
    }

    /// TEST-ONLY: arm the single-use `seal_expunge_orphan_audit` fault seam.
    ///
    /// When armed, the next call to `seal_expunge_orphan_audit` on this estate
    /// returns `LocusKitError::InvalidContent("forced orphan-seal failure")` and
    /// clears the flag. This drives the double-failure path in GLK's `expunge`
    /// coordinator: a step-2 vector delete failure followed by an orphan-seal
    /// failure. Never call in production code.
    #[cfg(any(test, feature = "test-seams"))]
    pub fn set_test_force_orphan_seal_error(&self, should_fail: bool) {
        self.test_force_orphan_seal_error
            .store(should_fail, std::sync::atomic::Ordering::SeqCst);
    }

    /// TEST-ONLY: consume the orphan-seal fault seam — returns `true` if a
    /// fault was armed (and clears it), `false` otherwise. Called once at the
    /// start of `seal_expunge_orphan_audit` in `estate_verbs.rs`.
    #[cfg(any(test, feature = "test-seams"))]
    pub(crate) fn take_test_force_orphan_seal_error(&self) -> bool {
        self.test_force_orphan_seal_error
            .swap(false, std::sync::atomic::Ordering::SeqCst)
    }

    /// TEST-ONLY: consume the seam — return the armed fault (if any) and clear
    /// it. Called once at the top of `recall`.
    #[cfg(any(test, feature = "test-seams"))]
    pub(crate) fn take_test_force_internal_read_error(&self) -> Option<RecallInternalRead> {
        let v = self
            .test_force_internal_read_error
            .swap(0, std::sync::atomic::Ordering::SeqCst);
        match v {
            1 => Some(RecallInternalRead::LiveRows),
            2 => Some(RecallInternalRead::RoomFingerprints),
            3 => Some(RecallInternalRead::RoomDrawerRead),
            4 => Some(RecallInternalRead::BitmapEval),
            5 => Some(RecallInternalRead::TraceWrite),
            _ => None,
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::container_fingerprint_store::RoomLevelEntry;
    use crate::drawer::Drawer;
    use crate::error::LocusKitError;
    use crate::estate_types::RowID;
    use std::sync::Mutex;

    /// Test fake: an in-memory `DrawerStore` that holds a fixed
    /// manifest and a mutable set_meta override map. Exists only inside
    /// this test module; the production in-memory impl lands with the
    /// sub-mission that brings the concrete store.
    struct FakeStore {
        base_manifest: ManifestValues,
        overrides: Mutex<std::collections::BTreeMap<String, String>>,
        fail_read: bool,
    }

    impl FakeStore {
        fn new(layout: &str, uuid_str: &str) -> Self {
            Self {
                base_manifest: ManifestValues {
                    manifest_version: "1".to_string(),
                    schema_version: "1".to_string(),
                    estate_uuid: uuid_str.to_string(),
                    estate_name: "test-estate".to_string(),
                    owner_identifier: "".to_string(),
                    lattice_citation: "UDC-2.0-2020".to_string(),
                    framework_profile: "default".to_string(),
                    framework_profile_definition: "{}".to_string(),
                    zoom_window_low: -3,
                    zoom_window_high: 3,
                    access_posture: 0,
                    provenance_defaults: 0,
                    active_storage_mode: 1,
                    tables_present: "drawers".to_string(),
                    created_at: 1_700_000_000,
                    last_modified: 1_700_000_000,
                    bitmap_layout_version: layout.to_string(),
                    provenance_bitmap_version: "v1".to_string(),
                    federation_group_id: None,
                    mining_patterns_hash: None,
                    tiny_model_id: None,
                    tiny_model_training_corpus_size: None,
                    operational_bitmap_layouts: None,
                    ed25519_public_key: None,
                    ed25519_private_key_wrapped: None,
                },
                overrides: Mutex::new(Default::default()),
                fail_read: false,
            }
        }
    }

    impl DrawerStore for FakeStore {
        fn read_manifest(&self) -> Result<ManifestValues, LocusKitError> {
            if self.fail_read {
                return Err(LocusKitError::DatabaseUnavailable("disk full".to_string()));
            }
            let mut m = self.base_manifest.clone();
            let lock = self.overrides.lock().unwrap();
            if let Some(v) = lock.get(ManifestKey::OwnerIdentifier.as_str()) {
                m.owner_identifier = v.clone();
            }
            if let Some(v) = lock.get(ManifestKey::EstateName.as_str()) {
                m.estate_name = v.clone();
            }
            if let Some(v) = lock.get(ManifestKey::Ed25519PublicKey.as_str()) {
                m.ed25519_public_key = Some(v.clone());
            }
            if let Some(v) = lock.get(ManifestKey::Ed25519PrivateKeyWrapped.as_str()) {
                m.ed25519_private_key_wrapped = Some(v.clone());
            }
            Ok(m)
        }

        fn set_meta(&self, key: &str, value: &str) -> Result<(), LocusKitError> {
            self.overrides
                .lock()
                .unwrap()
                .insert(key.to_string(), value.to_string());
            Ok(())
        }

        fn drawer_ids(&self) -> Result<Vec<RowID>, LocusKitError> {
            Ok(Vec::new())
        }

        // `all_drawers` and `room_level_fingerprints` carry NO trait default
        // (compile-enforced per Bob's SDK ruling), so every store — including
        // this minimal manifest-only fake — must implement them. The fake holds
        // no drawers and no container aggregate, so both return empty.
        fn all_drawers(&self) -> Result<Vec<Drawer>, LocusKitError> {
            Ok(Vec::new())
        }

        fn room_level_fingerprints(&self) -> Result<Vec<RoomLevelEntry>, LocusKitError> {
            Ok(Vec::new())
        }
    }

    /// Force-test: a minimal store that does NOT override
    /// `all_kg_facts_including_retired` must receive a `DatabaseUnavailable`
    /// error rather than a silent empty-vec. This guards the math-provenance
    /// gate (FINDING-3): a missing impl must fail loud, not hide silently.
    ///
    /// `FakeStore` overrides `read_manifest`, `set_meta`, `drawer_ids`, and the
    /// two compile-required reads (`all_drawers`, `room_level_fingerprints`) —
    /// it intentionally does NOT override `all_kg_facts_including_retired`, so it
    /// exercises that method's trait default.
    #[test]
    fn all_kg_facts_including_retired_default_fails_loud_on_non_overriding_store() {
        let store = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        let err = store
            .all_kg_facts_including_retired()
            .expect_err("expected DatabaseUnavailable, got Ok");
        match err {
            LocusKitError::DatabaseUnavailable(msg) => {
                assert!(
                    msg.contains("all_kg_facts_including_retired"),
                    "error message should name the method; got: {msg}"
                );
            }
            other => panic!("expected DatabaseUnavailable, got {:?}", other),
        }
    }

    // -----------------------------------------------------------------
    // Force-tests: every newly-gated read method must return
    // DatabaseUnavailable on a non-overriding store.
    //
    // FakeStore overrides `read_manifest`, `set_meta`, `drawer_ids`, and the
    // two compile-required reads (`all_drawers`, `room_level_fingerprints`);
    // it intentionally does NOT override any of the methods below so each test
    // exercises the trait default in isolation.
    // Concrete stores (InMemory/SQLite/Postgres) all override every method
    // and are covered by their own integration tests.
    // -----------------------------------------------------------------

    /// Helper: assert a result is DatabaseUnavailable and that the message
    /// names the expected method. Parameterized over any T.
    fn assert_fail_loud<T: std::fmt::Debug>(
        result: Result<T, LocusKitError>,
        method: &str,
    ) {
        let err = result.unwrap_err_or_else_panic(
            &format!("expected DatabaseUnavailable for {method}, got Ok"),
        );
        match &err {
            LocusKitError::DatabaseUnavailable(msg) => {
                assert!(
                    msg.contains(method),
                    "error for {method} should name the method; got: {msg}"
                );
            }
            other => panic!("expected DatabaseUnavailable for {method}, got {:?}", other),
        }
    }

    // Extend Result<T,E> with an inline unwrap-or-panic to avoid
    // unwrap_err() being the only option (it panics but we want a
    // custom message).
    trait UnwrapErrOrPanic<T, E> {
        fn unwrap_err_or_else_panic(self, msg: &str) -> E;
    }
    impl<T: std::fmt::Debug, E> UnwrapErrOrPanic<T, E> for Result<T, E> {
        fn unwrap_err_or_else_panic(self, msg: &str) -> E {
            match self {
                Err(e) => e,
                Ok(v) => panic!("{msg}: got Ok({v:?})"),
            }
        }
    }

    #[test]
    fn get_meta_default_fails_loud() {
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(s.get_meta("any-key"), "get_meta");
    }

    #[test]
    fn get_drawer_default_fails_loud() {
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(s.get_drawer("any-id"), "get_drawer");
    }

    #[test]
    fn living_successor_in_lineage_default_fails_loud() {
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(
            s.living_successor_in_lineage("lineage-id", "excluding-id"),
            "living_successor_in_lineage",
        );
    }

    #[test]
    fn drawers_in_wing_default_fails_loud() {
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(s.drawers_in_wing("wing-a"), "drawers_in_wing");
    }

    #[test]
    fn drawers_in_wing_room_default_fails_loud() {
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(
            s.drawers_in_wing_room("wing-a", "room-b"),
            "drawers_in_wing_room",
        );
    }

    #[test]
    fn drawers_by_source_default_fails_loud() {
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(s.drawers_by_source("file.txt"), "drawers_by_source");
    }

    // `all_drawers` is now a REQUIRED trait method with no default (Bob's SDK
    // ruling: a backend that forgets it fails to COMPILE). There is no default
    // to exercise, so the former `all_drawers_default_fails_loud` test was
    // removed — the compiler now enforces the invariant it used to assert.

    #[test]
    fn get_tunnel_default_fails_loud() {
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(s.get_tunnel("t-id"), "get_tunnel");
    }

    #[test]
    fn tunnels_from_wing_default_fails_loud() {
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(s.tunnels_from_wing("wing-a"), "tunnels_from_wing");
    }

    #[test]
    fn tunnels_from_wing_room_default_fails_loud() {
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(
            s.tunnels_from_wing_room("wing-a", "room-b"),
            "tunnels_from_wing_room",
        );
    }

    #[test]
    fn tunnels_to_wing_default_fails_loud() {
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(s.tunnels_to_wing("wing-a"), "tunnels_to_wing");
    }

    #[test]
    fn all_tunnels_default_fails_loud() {
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(s.all_tunnels(), "all_tunnels");
    }

    #[test]
    fn get_kg_fact_default_fails_loud() {
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(s.get_kg_fact("kg-id"), "get_kg_fact");
    }

    #[test]
    fn kg_facts_for_drawer_default_fails_loud() {
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(s.kg_facts_for_drawer("d-id"), "kg_facts_for_drawer");
    }

    #[test]
    fn get_proposal_default_fails_loud() {
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(s.get_proposal("p-id"), "get_proposal");
    }

    #[test]
    fn proposals_for_target_default_fails_loud() {
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(s.proposals_for_target("row-id"), "proposals_for_target");
    }

    #[test]
    fn get_association_default_fails_loud() {
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(s.get_association("a-id"), "get_association");
    }

    #[test]
    fn associations_from_default_fails_loud() {
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(s.associations_from("wing-a", "room-b"), "associations_from");
    }

    #[test]
    fn associations_to_default_fails_loud() {
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(s.associations_to("wing-a", "room-b"), "associations_to");
    }

    #[test]
    fn get_learned_reference_default_fails_loud() {
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(s.get_learned_reference("lr-id"), "get_learned_reference");
    }

    #[test]
    fn learned_references_from_source_default_fails_loud() {
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(
            s.learned_references_from_source("cat-id"),
            "learned_references_from_source",
        );
    }

    #[test]
    fn get_source_catalog_entry_default_fails_loud() {
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(
            s.get_source_catalog_entry("sce-id"),
            "get_source_catalog_entry",
        );
    }

    #[test]
    fn source_catalog_entry_for_handle_default_fails_loud() {
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(
            s.source_catalog_entry_for_handle("handle"),
            "source_catalog_entry_for_handle",
        );
    }

    #[test]
    fn get_diary_entry_default_fails_loud() {
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(s.get_diary_entry("de-id"), "get_diary_entry");
    }

    #[test]
    fn read_diary_default_fails_loud() {
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(s.read_diary("agent", 10), "read_diary");
    }

    #[test]
    fn read_diary_in_wing_default_fails_loud() {
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(
            s.read_diary_in_wing("agent", "wing-a", 10),
            "read_diary_in_wing",
        );
    }

    #[test]
    fn get_recall_trace_default_fails_loud() {
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(s.get_recall_trace("rt-id"), "get_recall_trace");
    }

    #[test]
    fn recall_trace_since_default_fails_loud() {
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(
            s.recall_trace_since("2024-01-01T00:00:00.000Z"),
            "recall_trace_since",
        );
    }

    #[test]
    fn recent_recall_traces_default_fails_loud() {
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(
            s.recent_recall_traces("2024-01-01T00:00:00.000Z", "2024-12-31T00:00:00.000Z"),
            "recent_recall_traces",
        );
    }

    #[test]
    fn count_recall_traces_default_fails_loud() {
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(s.count_recall_traces(), "count_recall_traces");
    }

    #[test]
    fn count_drawer_rows_default_fails_loud() {
        // The DrawerStore trait's default impl for count_drawer_rows must return
        // DatabaseUnavailable rather than silently returning 0 — a silent zero
        // would mask a bricked corpus as an empty one, defeating the vault-export
        // fail-loud check. Mirrors the `count_recall_traces_default_fails_loud` pattern.
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(s.count_drawer_rows(), "count_drawer_rows");
    }

    #[test]
    fn audit_events_for_row_default_fails_loud() {
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(s.audit_events_for_row("row-id"), "audit_events_for_row");
    }

    #[test]
    fn list_wings_default_fails_loud() {
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(s.list_wings(), "list_wings");
    }

    #[test]
    fn list_rooms_default_fails_loud() {
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(s.list_rooms(None), "list_rooms");
    }

    #[test]
    fn all_proposals_default_fails_loud() {
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(s.all_proposals(), "all_proposals");
    }

    #[test]
    fn all_associations_default_fails_loud() {
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(s.all_associations(), "all_associations");
    }

    #[test]
    fn all_learned_references_default_fails_loud() {
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(s.all_learned_references(), "all_learned_references");
    }

    #[test]
    fn all_kg_facts_default_fails_loud() {
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(s.all_kg_facts(), "all_kg_facts");
    }

    #[test]
    fn all_diary_entries_default_fails_loud() {
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(s.all_diary_entries(), "all_diary_entries");
    }

    #[test]
    fn fingerprints_captured_in_default_fails_loud() {
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(
            s.fingerprints_captured_in(0, 9_999_999_999),
            "fingerprints_captured_in",
        );
    }

    #[test]
    fn fingerprint_bit_series_default_fails_loud() {
        let s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        assert_fail_loud(
            s.fingerprint_bit_series(0, 86400, 7, 9_999_999_999),
            "fingerprint_bit_series",
        );
    }

    // `room_level_fingerprints` is now a REQUIRED trait method with no default
    // (Bob's SDK ruling: a backend that forgets it fails to COMPILE). There is
    // no default to exercise, so the former
    // `room_level_fingerprints_default_fails_loud` test was removed — the
    // compiler now enforces the invariant it used to assert.

    // -----------------------------------------------------------------
    // Regression guard: concrete InMemoryDrawerStore (wrapping DrawerStoreCore)
    // still returns correct results on an empty estate — empty is a valid
    // result from a real store, distinct from "not implemented".
    // Uses epoch 1_700_000_000 as the deterministic now parameter.
    // -----------------------------------------------------------------

    #[test]
    fn concrete_inmemory_store_all_drawers_returns_empty_on_empty_estate() {
        use crate::drawer_store_inmemory::InMemoryDrawerStore;
        let store = InMemoryDrawerStore::new(1_700_000_000, None).unwrap();
        let result = store.all_drawers().expect("all_drawers on empty InMemory store");
        assert!(result.is_empty(), "empty estate has no drawers");
    }

    #[test]
    fn concrete_inmemory_store_all_tunnels_returns_empty_on_empty_estate() {
        use crate::drawer_store_inmemory::InMemoryDrawerStore;
        let store = InMemoryDrawerStore::new(1_700_000_000, None).unwrap();
        let result = store.all_tunnels().expect("all_tunnels on empty InMemory store");
        assert!(result.is_empty(), "empty estate has no tunnels");
    }

    #[test]
    fn concrete_inmemory_store_all_kg_facts_returns_empty_on_empty_estate() {
        use crate::drawer_store_inmemory::InMemoryDrawerStore;
        let store = InMemoryDrawerStore::new(1_700_000_000, None).unwrap();
        let result = store.all_kg_facts().expect("all_kg_facts on empty InMemory store");
        assert!(result.is_empty(), "empty estate has no KG facts");
    }

    #[test]
    fn concrete_inmemory_store_count_recall_traces_returns_zero_on_empty_estate() {
        use crate::drawer_store_inmemory::InMemoryDrawerStore;
        let store = InMemoryDrawerStore::new(1_700_000_000, None).unwrap();
        let count = store
            .count_recall_traces()
            .expect("count_recall_traces on empty InMemory store");
        assert_eq!(count, 0, "empty estate has zero trace rows");
    }

    #[test]
    fn concrete_inmemory_store_count_drawer_rows_returns_zero_on_empty_estate() {
        // An empty InMemory estate has no drawer rows: COUNT(*) must return 0.
        // Mirrors Swift `DrawerStore.countDrawerRows()` contract check.
        use crate::drawer_store_inmemory::InMemoryDrawerStore;
        let store = InMemoryDrawerStore::new(1_700_000_000, None).unwrap();
        let count = store
            .count_drawer_rows()
            .expect("count_drawer_rows on empty InMemory store");
        assert_eq!(count, 0, "empty estate has zero drawer rows");
    }

    #[test]
    fn concrete_inmemory_store_list_wings_returns_empty_on_empty_estate() {
        use crate::drawer_store_inmemory::InMemoryDrawerStore;
        let store = InMemoryDrawerStore::new(1_700_000_000, None).unwrap();
        let result = store.list_wings().expect("list_wings on empty InMemory store");
        assert!(result.is_empty(), "empty estate has no wings");
    }

    // -----------------------------------------------------------------
    // End force-tests
    // -----------------------------------------------------------------

    /// The expected bitmap layout version is the value the spec fixes;
    /// changing it is a coordinated cross-leg event.
    #[test]
    fn expected_bitmap_layout_version_matches_spec() {
        assert_eq!(EXPECTED_BITMAP_LAYOUT_VERSION, "v1.0");
    }

    /// Open succeeds when the manifest's bitmap layout version matches
    /// the kit's expected value and the estate_uuid parses.
    #[test]
    fn open_succeeds_on_matching_layout() {
        let store = Arc::new(FakeStore::new(
            "v1.0",
            "11111111-1111-1111-1111-111111111111",
        ));
        let estate = Estate::open(store, OwnerCredentials::new("alice@icloud.com")).unwrap();
        assert_eq!(
            estate.estate_uuid().to_string(),
            "11111111-1111-1111-1111-111111111111"
        );
    }

    /// Open refuses an empty owner identifier before touching the store.
    #[test]
    fn open_rejects_empty_owner_identifier() {
        let store = Arc::new(FakeStore::new(
            "v1.0",
            "11111111-1111-1111-1111-111111111111",
        ));
        let err = Estate::open(store, OwnerCredentials::new("")).unwrap_err();
        assert_eq!(err, EstateError::EmptyOwnerIdentifier);
    }

    /// A mismatched bitmap layout version surfaces as
    /// `ManifestMismatch` so callers can route to a migration path.
    #[test]
    fn open_rejects_mismatched_bitmap_layout_version() {
        let store = Arc::new(FakeStore::new(
            "v0.99",
            "11111111-1111-1111-1111-111111111111",
        ));
        let err = Estate::open(store, OwnerCredentials::new("alice")).unwrap_err();
        match err {
            EstateError::ManifestMismatch {
                key,
                found,
                expected,
            } => {
                assert_eq!(key, "bitmap_layout_version");
                assert_eq!(found, "v0.99");
                assert_eq!(expected, "v1.0");
            }
            other => panic!("expected ManifestMismatch, got {:?}", other),
        }
    }

    /// An unparseable `estate_uuid` surfaces as `ManifestMismatch` with
    /// the key `estate_uuid` so the caller can re-key the row.
    #[test]
    fn open_rejects_invalid_estate_uuid() {
        let store = Arc::new(FakeStore::new("v1.0", "not-a-uuid"));
        let err = Estate::open(store, OwnerCredentials::new("alice")).unwrap_err();
        match err {
            EstateError::ManifestMismatch { key, found, .. } => {
                assert_eq!(key, "estate_uuid");
                assert_eq!(found, "not-a-uuid");
            }
            other => panic!("expected ManifestMismatch on estate_uuid, got {:?}", other),
        }
    }

    /// Substrate read failure surfaces as `SubstrateUnavailable`.
    #[test]
    fn open_surfaces_substrate_failure() {
        let mut s = FakeStore::new("v1.0", "11111111-1111-1111-1111-111111111111");
        s.fail_read = true;
        let store: Arc<dyn DrawerStore> = Arc::new(s);
        let err = Estate::open(store, OwnerCredentials::new("alice")).unwrap_err();
        match err {
            EstateError::SubstrateUnavailable(msg) => {
                assert!(msg.contains("disk full"));
            }
            other => panic!("expected SubstrateUnavailable, got {:?}", other),
        }
    }

    /// Create stamps the owner identifier into the manifest.
    #[test]
    fn create_stamps_owner_identifier() {
        let store = Arc::new(FakeStore::new(
            "v1.0",
            "22222222-2222-2222-2222-222222222222",
        ));
        let _ = Estate::create(
            store.clone(),
            OwnerCredentials::new("alice@icloud.com"),
            None,
        )
        .unwrap();
        let manifest = store.read_manifest().unwrap();
        assert_eq!(manifest.owner_identifier, "alice@icloud.com");
    }

    /// Create with a non-empty `estate_name` in initial values stamps
    /// the name; empty names leave the default in place.
    #[test]
    fn create_stamps_estate_name_when_supplied() {
        let store = Arc::new(FakeStore::new(
            "v1.0",
            "22222222-2222-2222-2222-222222222222",
        ));
        let initial = ManifestValues {
            estate_name: "alice-research".to_string(),
            ..manifest_template()
        };
        let _ = Estate::create(
            store.clone(),
            OwnerCredentials::new("alice@icloud.com"),
            Some(&initial),
        )
        .unwrap();
        let manifest = store.read_manifest().unwrap();
        assert_eq!(manifest.estate_name, "alice-research");
    }

    /// Create rejects an empty owner identifier before touching the store.
    #[test]
    fn create_rejects_empty_owner_identifier() {
        let store = Arc::new(FakeStore::new(
            "v1.0",
            "22222222-2222-2222-2222-222222222222",
        ));
        let err = Estate::create(store, OwnerCredentials::new(""), None).unwrap_err();
        assert_eq!(err, EstateError::EmptyOwnerIdentifier);
    }

    /// Close is a no-op semantic hook today; verify it returns Ok.
    #[test]
    fn close_is_no_op() {
        let store = Arc::new(FakeStore::new(
            "v1.0",
            "33333333-3333-3333-3333-333333333333",
        ));
        let estate = Estate::open(store, OwnerCredentials::new("alice")).unwrap();
        assert!(estate.close().is_ok());
    }

    /// First open mints an Ed25519 identity and persists only the public
    /// half to the manifest. The private signing key must not be written
    /// to manifest.value because that table is not secret storage.
    #[test]
    fn open_mints_ed25519_public_key_on_first_open_without_persisting_private_key() {
        let store = Arc::new(FakeStore::new(
            "v1.0",
            "55555555-5555-5555-5555-555555555555",
        ));
        let estate = Estate::open(store.clone(), OwnerCredentials::new("alice")).unwrap();
        let m = estate.manifest().unwrap();
        assert!(m.ed25519_public_key.is_some(), "public key should be minted");
        assert!(
            m.ed25519_private_key_wrapped.is_none(),
            "private key must not be persisted in the manifest"
        );
        // The public key is base64 of a 32-byte Ed25519 verifying key.
        use base64::Engine;
        let b64 = base64::engine::general_purpose::STANDARD;
        let pub_bytes = b64
            .decode(m.ed25519_public_key.as_ref().unwrap())
            .expect("public key should be valid base64");
        assert_eq!(pub_bytes.len(), 32, "Ed25519 public key is 32 bytes");
    }

    /// Re-opening an estate that already has a public identity does NOT regenerate it.
    #[test]
    fn open_preserves_existing_ed25519_public_key() {
        let store = Arc::new(FakeStore::new(
            "v1.0",
            "66666666-6666-6666-6666-666666666666",
        ));
        let estate1 = Estate::open(store.clone(), OwnerCredentials::new("alice")).unwrap();
        let m1 = estate1.manifest().unwrap();
        let pub1 = m1.ed25519_public_key.clone().unwrap();

        // Second open: public key should be identical.
        let estate2 = Estate::open(store.clone(), OwnerCredentials::new("alice")).unwrap();
        let m2 = estate2.manifest().unwrap();
        assert_eq!(
            m2.ed25519_public_key.as_ref().unwrap(),
            &pub1,
            "public key stable across re-opens"
        );
        assert!(
            m2.ed25519_private_key_wrapped.is_none(),
            "private key remains absent across re-opens"
        );
    }

    /// Manifest accessor re-reads through the store each call so
    /// post-create overrides surface.
    #[test]
    fn manifest_accessor_rereads() {
        let store = Arc::new(FakeStore::new(
            "v1.0",
            "44444444-4444-4444-4444-444444444444",
        ));
        let estate = Estate::create(
            store.clone(),
            OwnerCredentials::new("alice@icloud.com"),
            None,
        )
        .unwrap();
        // Stamp a new estate_name through the store and observe via Estate.
        store
            .set_meta(ManifestKey::EstateName.as_str(), "renamed")
            .unwrap();
        let m = estate.manifest().unwrap();
        assert_eq!(m.estate_name, "renamed");
    }

    fn manifest_template() -> ManifestValues {
        ManifestValues {
            manifest_version: "1".to_string(),
            schema_version: "1".to_string(),
            estate_uuid: "22222222-2222-2222-2222-222222222222".to_string(),
            estate_name: "".to_string(),
            owner_identifier: "".to_string(),
            lattice_citation: "UDC-2.0-2020".to_string(),
            framework_profile: "default".to_string(),
            framework_profile_definition: "{}".to_string(),
            zoom_window_low: -3,
            zoom_window_high: 3,
            access_posture: 0,
            provenance_defaults: 0,
            active_storage_mode: 1,
            tables_present: "drawers".to_string(),
            created_at: 1_700_000_000,
            last_modified: 1_700_000_000,
            bitmap_layout_version: "v1.0".to_string(),
            provenance_bitmap_version: "v1".to_string(),
            federation_group_id: None,
            mining_patterns_hash: None,
            tiny_model_id: None,
            tiny_model_training_corpus_size: None,
            operational_bitmap_layouts: None,
            ed25519_public_key: None,
            ed25519_private_key_wrapped: None,
        }
    }
}
