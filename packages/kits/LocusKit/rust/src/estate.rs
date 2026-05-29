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
use std::sync::Arc;
use uuid::Uuid;

// MARK: - Bitmap layout compatibility

/// The bitmap layout version this kit speaks. `Estate::open` refuses
/// to open a backing store whose manifest carries a different value,
/// returning `EstateError::ManifestMismatch { key:
/// "bitmap_layout_version", ... }`. Bumped lock-step with any
/// breaking change to a bitmap layout, see spec §13.2.
pub const EXPECTED_BITMAP_LAYOUT_VERSION: &str = "v0.35";

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

    /// Parsed UUID form of the manifest's `estate_uuid` row. Cached at
    /// init time because the value never changes for the lifetime of
    /// the backing store (the manifest's `estate_uuid` is set once at
    /// create time and treated as immutable per spec §7.7).
    estate_uuid: Uuid,
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

    /// The estate's stable UUID, parsed from the manifest at open time.
    /// Identical across all opens of the same backing store, because
    /// estate identity is a property of the substrate, not the handle.
    pub fn estate_uuid(&self) -> Uuid {
        self.estate_uuid
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
        let uuid = Uuid::parse_str(&manifest.estate_uuid).map_err(|_| {
            EstateError::ManifestMismatch {
                key: ManifestKey::EstateUUID.as_str().to_string(),
                found: manifest.estate_uuid.clone(),
                expected: "<valid UUID string>".to_string(),
            }
        })?;
        Ok(Estate {
            store,
            estate_uuid: uuid,
        })
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
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
    }

    /// The expected bitmap layout version is the value the spec fixes;
    /// changing it is a coordinated cross-port event.
    #[test]
    fn expected_bitmap_layout_version_matches_spec() {
        assert_eq!(EXPECTED_BITMAP_LAYOUT_VERSION, "v0.35");
    }

    /// Open succeeds when the manifest's bitmap layout version matches
    /// the kit's expected value and the estate_uuid parses.
    #[test]
    fn open_succeeds_on_matching_layout() {
        let store = Arc::new(FakeStore::new(
            "v0.35",
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
            "v0.35",
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
            EstateError::ManifestMismatch { key, found, expected } => {
                assert_eq!(key, "bitmap_layout_version");
                assert_eq!(found, "v0.99");
                assert_eq!(expected, "v0.35");
            }
            other => panic!("expected ManifestMismatch, got {:?}", other),
        }
    }

    /// An unparseable `estate_uuid` surfaces as `ManifestMismatch` with
    /// the key `estate_uuid` so the caller can re-key the row.
    #[test]
    fn open_rejects_invalid_estate_uuid() {
        let store = Arc::new(FakeStore::new("v0.35", "not-a-uuid"));
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
        let mut s = FakeStore::new("v0.35", "11111111-1111-1111-1111-111111111111");
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
            "v0.35",
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
            "v0.35",
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
            "v0.35",
            "22222222-2222-2222-2222-222222222222",
        ));
        let err = Estate::create(store, OwnerCredentials::new(""), None).unwrap_err();
        assert_eq!(err, EstateError::EmptyOwnerIdentifier);
    }

    /// Close is a no-op semantic hook today; verify it returns Ok.
    #[test]
    fn close_is_no_op() {
        let store = Arc::new(FakeStore::new(
            "v0.35",
            "33333333-3333-3333-3333-333333333333",
        ));
        let estate = Estate::open(store, OwnerCredentials::new("alice")).unwrap();
        assert!(estate.close().is_ok());
    }

    /// Manifest accessor re-reads through the store each call so
    /// post-create overrides surface.
    #[test]
    fn manifest_accessor_rereads() {
        let store = Arc::new(FakeStore::new(
            "v0.35",
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
            bitmap_layout_version: "v0.35".to_string(),
            provenance_bitmap_version: "v1".to_string(),
            federation_group_id: None,
            mining_patterns_hash: None,
            tiny_model_id: None,
            tiny_model_training_corpus_size: None,
            operational_bitmap_layouts: None,
        }
    }
}
