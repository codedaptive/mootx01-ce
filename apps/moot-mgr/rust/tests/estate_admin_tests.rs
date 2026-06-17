// estate_admin_tests.rs — Rust twin of the Swift EstateAdminCacheTests.swift +
// EstateAdminTests.swift, plus the LOAD-BEARING DEBT-1+2 proof.
//
// THE PROOF (the load-bearing deliverable): construct an estate via the ported
// admin path and show
//   (a) the backing store is a CachingRowStore (cache-on default — DEBT-1), and
//   (b) a captured drawer becomes semantically (BM25) searchable — i.e. the
//       corpus is registered via provision, not open (DEBT-2).
//
// All tests run against SCRATCH estates (in-memory / a temp directory). The real
// estate and ~/.mempalace are never touched.

use genius_locus_kit::recall::{GLKRecallMode, GLKRecallRequest, RecallEvidencePath};
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::estate_types::LatticeAnchor;
use locus_kit::filter::{Filter, RecallFrame};
use locus_kit::frames::CaptureFrame;
use moot_mgr::admin_payloads::EstateAdminRequest;
use moot_mgr::estate_admin::{AdminError, EstateAdmin};
use moot_mgr::admin_payloads::EstateLifecycleRequest;
use persistence_kit::cache_config::EstateCacheConfig;

/// A fresh, unique scratch directory path for SQLite-backed admin estates.
fn scratch_estates_dir() -> String {
    let dir = std::env::temp_dir().join(format!("moot-mgr-rs-{}", uuid::Uuid::new_v4()));
    dir.to_string_lossy().into_owned()
}

/// A baseline provision request (GLK / InMemory) the tests vary from.
fn req(name: &str, kind: &str, backend: &str, owner: &str) -> EstateAdminRequest {
    EstateAdminRequest {
        estate_name: name.to_string(),
        kind: kind.to_string(),
        backend: backend.to_string(),
        zoom_window_low: 1,
        zoom_window_high: 10,
        framework_profile: "KnowledgeWork".to_string(),
        sync_mode: "None".to_string(),
        owner: owner.to_string(),
    }
}

const NOW: i64 = 1_700_000_000;

// ───────────────────────────── DEBT-1: cache-on ─────────────────────────────

#[test]
fn in_memory_live_estate_is_caching() {
    // Explicit cache-ON config (the live default), independent of the ambient
    // process environment so the test is deterministic. Mirrors the Swift
    // `inMemoryLiveEstateIsCaching` test.
    let mut admin = EstateAdmin::with_cache_config(
        scratch_estates_dir(),
        EstateCacheConfig::new(true, 8 * 1024 * 1024, 2),
    );
    let result = admin
        .provision(&req("CacheScratch", "GLK", "InMemory", "cache-tests"), NOW)
        .expect("provision must succeed");
    let uuid = result.estate_uuid.expect("provision returns a uuid");
    // The CachingRowStore hot tier is wired for the InMemory estate: its backing
    // storage was constructed with the cache-on config that makes row_store() a
    // CachingRowStore.
    assert_eq!(admin.backing_storage_is_caching(&uuid), Some(true));
}

#[test]
fn sqlite_live_estate_is_caching() {
    // Behavior-parity test for the SQLite backend — mirrors `in_memory_live_estate_is_caching`.
    // SqliteDrawerStore::from_path_with_config threads the cache-on EstateConfiguration
    // into SqliteStorage, so SqliteStorage::row_store() wraps the backing SqliteRowStore
    // in a CachingRowStore LRU hot tier — identical to the InMemory path. This test
    // asserts that the SQLite estate's backing storage is caching when the host's
    // resolved cache config has enabled=true.
    let mut admin = EstateAdmin::with_cache_config(
        scratch_estates_dir(),
        EstateCacheConfig::new(true, 8 * 1024 * 1024, 2),
    );
    let result = admin
        .provision(&req("SQLiteCacheScratch", "GLK", "SQLite", "cache-tests"), NOW)
        .expect("provision must succeed");
    let uuid = result.estate_uuid.expect("provision returns a uuid");
    // The CachingRowStore hot tier is now wired for the SQLite estate as well:
    // its backing storage was constructed via from_path_with_config with the
    // cache-on config, closing the InMemory/SQLite caching parity gap.
    assert_eq!(admin.backing_storage_is_caching(&uuid), Some(true));
}

#[test]
fn sqlite_cache_disabled_reverts_to_bare_store() {
    // Complement of sqlite_live_estate_is_caching: when cache is disabled the
    // SQLite estate's backing storage must NOT wrap in CachingRowStore.
    let mut admin =
        EstateAdmin::with_cache_config(scratch_estates_dir(), EstateCacheConfig::disabled());
    let result = admin
        .provision(&req("SQLiteBareScratch", "GLK", "SQLite", "cache-tests"), NOW)
        .expect("provision must succeed");
    let uuid = result.estate_uuid.expect("provision returns a uuid");
    assert_eq!(admin.backing_storage_is_caching(&uuid), Some(false));
}

#[test]
fn cache_disabled_reverts_to_bare_store() {
    let mut admin =
        EstateAdmin::with_cache_config(scratch_estates_dir(), EstateCacheConfig::disabled());
    let result = admin
        .provision(&req("BareScratch", "GLK", "InMemory", "cache-tests"), NOW)
        .expect("provision must succeed");
    let uuid = result.estate_uuid.expect("provision returns a uuid");
    assert_eq!(admin.backing_storage_is_caching(&uuid), Some(false));
}

#[test]
fn resolve_cache_config_default_is_enabled() {
    // In a normal test process MOOTX01_ESTATE_CACHE is unset → cache ON. (If a CI
    // runner sets it to 0 the assertion below would flip; the resident host ships
    // with it unset, which is the contract we encode.) Mirrors the Swift
    // `resolverDefaultIsEnabled` test.
    if std::env::var("MOOTX01_ESTATE_CACHE").is_err() {
        let cfg = EstateAdmin::resolve_cache_config();
        assert!(cfg.enabled);
        assert!(cfg.ceiling_bytes > 0);
        // Secret-exclusion clamp holds: threshold never exceeds 2.
        assert!(cfg.sensitivity_threshold <= 2);
    }
}

// ──────────────────── DEBT-2: provision-with-corpus + BM25 ───────────────────

#[test]
fn provisioned_estate_registers_corpus() {
    // DEBT-2 structural proof: the admin path provisions WITH a corpus (the
    // coordinator registers it), unlike the ARIA_MCP `open` path which leaves
    // the semantic lanes dark.
    let mut admin = EstateAdmin::new(scratch_estates_dir());
    let result = admin
        .provision(&req("CorpusScratch", "GLK", "InMemory", "corpus-tests"), NOW)
        .expect("provision must succeed");
    let uuid = result.estate_uuid.expect("provision returns a uuid");
    assert_eq!(admin.backing_estate_has_corpus(&uuid), Some(true));
}

#[test]
fn captured_drawer_becomes_bm25_searchable() {
    // THE LOAD-BEARING PROOF (DEBT-1 + DEBT-2 together): construct an estate via
    // the ported admin path, capture a drawer, and show it becomes BM25-searchable
    // — only possible because the corpus is registered via provision, not open.
    let mut admin = EstateAdmin::new(scratch_estates_dir());
    let result = admin
        .provision(&req("SearchScratch", "GLK", "InMemory", "search-tests"), NOW)
        .expect("provision must succeed");
    let uuid = result.estate_uuid.clone().expect("provision returns a uuid");

    // (a) cache-on (DEBT-1) — the default resolver enables the cache.
    // (Skip the assertion when a CI runner has forced the cache off via env.)
    if std::env::var("MOOTX01_ESTATE_CACHE").is_err() {
        assert_eq!(admin.backing_storage_is_caching(&uuid), Some(true));
    }

    let handle = admin.handle_for(&uuid).expect("estate is hosted");

    // Capture a drawer with distinctive content. Impatient mode ingests it into
    // the registered Corpus inline before returning, so it is immediately
    // BM25-searchable — exercising the provision-registered corpus directly.
    let frame = CaptureFrame::new(
        "the peregrine falcon stoops at terminal velocity over the estuary",
        CaptureChannel::Typed,
        "field-notes",
        LatticeAnchor::udc("598.9"),
        "search-tests",
        "deterministic-v1",
    );
    let drawer = {
        use genius_locus_kit::intake::WriteMode;
        admin
            .coordinator_mut()
            .capture_with_mode(&handle, frame, NOW, WriteMode::Impatient)
            .expect("capture must succeed")
    };

    // (b) BM25-searchable (DEBT-2): a CorpusOnly scored recall keyed on a word
    // from the captured content returns the captured drawer via the BM25 lane.
    // A `coord.open`-constructed estate (no corpus) would return zero BM25 hits.
    let mut request = GLKRecallRequest::new(RecallFrame::new(vec![Filter::CurrentlyBelieve]))
        .with_mode(GLKRecallMode::CorpusOnly);
    request.query_text = Some("peregrine falcon estuary".to_string());
    request.limit = 10;

    let recall = admin
        .coordinator()
        .recall_scored(&handle, request, NOW)
        .expect("recall_scored must succeed");

    // The captured drawer is present in the hits...
    let hit = recall
        .hits
        .iter()
        .find(|h| h.id == drawer.id)
        .expect("captured drawer must surface in scored recall — corpus is registered (DEBT-2)");
    // ...and the BM25 lane is the path that produced it (not a locus fallback):
    // proving the semantic lane is LIT through the provision-registered corpus.
    assert!(
        hit.sources.contains(&RecallEvidencePath::CorpusBm25),
        "the hit must come through the CorpusBm25 evidence lane — \
         a provision-registered corpus is what lights it (DEBT-2)"
    );
}

// ───────────────────────── admin lifecycle + validation ─────────────────────

#[test]
fn provision_rejects_empty_name() {
    let mut admin = EstateAdmin::new(scratch_estates_dir());
    let err = admin
        .provision(&req("", "GLK", "InMemory", "x"), NOW)
        .unwrap_err();
    assert!(matches!(err, AdminError::InvalidRequest { .. }));
}

#[test]
fn provision_rejects_unknown_kind_and_backend() {
    let mut admin = EstateAdmin::new(scratch_estates_dir());
    assert!(matches!(
        admin
            .provision(&req("n", "Nope", "InMemory", "x"), NOW)
            .unwrap_err(),
        AdminError::InvalidRequest { .. }
    ));
    assert!(matches!(
        admin
            .provision(&req("n", "GLK", "Nope", "x"), NOW)
            .unwrap_err(),
        AdminError::InvalidRequest { .. }
    ));
}

#[test]
fn provision_rejects_inverted_zoom_window() {
    let mut admin = EstateAdmin::new(scratch_estates_dir());
    let mut r = req("n", "GLK", "InMemory", "x");
    r.zoom_window_low = 50;
    r.zoom_window_high = 10;
    assert!(matches!(
        admin.provision(&r, NOW).unwrap_err(),
        AdminError::InvalidRequest { .. }
    ));
}

#[test]
fn quiesce_then_drain_transitions_mount_state() {
    let mut admin = EstateAdmin::new(scratch_estates_dir());
    let uuid = admin
        .provision(&req("LifeScratch", "GLK", "InMemory", "life"), NOW)
        .unwrap()
        .estate_uuid
        .unwrap();
    let life = |u: &str| EstateLifecycleRequest {
        estate_uuid: u.to_string(),
        confirm_name: None,
    };
    let q = admin.quiesce(&life(&uuid)).unwrap();
    assert_eq!(q.mount_state.as_deref(), Some("quiesced"));
    let d = admin.drain(&life(&uuid)).unwrap();
    assert_eq!(d.mount_state.as_deref(), Some("quiesced"));
}

#[test]
fn destroy_requires_matching_confirm_name() {
    let mut admin = EstateAdmin::new(scratch_estates_dir());
    let uuid = admin
        .provision(&req("Fragile", "GLK", "InMemory", "owner"), NOW)
        .unwrap()
        .estate_uuid
        .unwrap();
    // Wrong confirm name → refused, estate untouched.
    let wrong = EstateLifecycleRequest {
        estate_uuid: uuid.clone(),
        confirm_name: Some("NotTheName".to_string()),
    };
    assert!(matches!(
        admin.destroy(&wrong).unwrap_err(),
        AdminError::DestroyConfirmMismatch
    ));
    assert_eq!(admin.payload().hosted.len(), 1);

    // Correct confirm name → destroyed, dropped from the provenance map.
    let right = EstateLifecycleRequest {
        estate_uuid: uuid.clone(),
        confirm_name: Some("Fragile".to_string()),
    };
    let res = admin.destroy(&right).unwrap();
    assert!(res.ok);
    assert!(admin.payload().hosted.is_empty());
}

#[test]
fn unknown_estate_lifecycle_errors() {
    let mut admin = EstateAdmin::new(scratch_estates_dir());
    let life = EstateLifecycleRequest {
        estate_uuid: uuid::Uuid::new_v4().to_string(),
        confirm_name: None,
    };
    assert!(matches!(
        admin.quiesce(&life).unwrap_err(),
        AdminError::UnknownEstate { .. }
    ));
}

#[test]
fn payload_reflects_hosted_estate_sorted() {
    let mut admin = EstateAdmin::new(scratch_estates_dir());
    admin
        .provision(&req("E1", "GLK", "InMemory", "o"), NOW)
        .unwrap();
    admin
        .provision(&req("E2", "CorpusOnly", "InMemory", "o"), NOW)
        .unwrap();
    let payload = admin.payload();
    assert_eq!(payload.hosted.len(), 2);
    // Sorted by UUID for byte-stable output.
    assert!(payload.hosted[0].estate_uuid <= payload.hosted[1].estate_uuid);
    // Mount-state badge is "mounted" for a freshly provisioned estate.
    assert!(payload.hosted.iter().all(|e| e.mount_state == "mounted"));
}
