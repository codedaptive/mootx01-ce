//! The ONE canonical indexing and recall engine
//! (GLK shared-content 1.1, P2). Rust twin of Swift
//! `CorpusContentEngine.swift`.
//!
//! Every derived row — BM25 postings, vector items, checkpoints — is
//! keyed by the canonical content ID (the Drawer ID in attached mode).
//! No chunk identity lane, no translation map, no copied text. Text is
//! resolved BY ID at work time; `ContentIndexJob` payloads carry
//! id/revision/digest/cursor only; a stale job is rejected with
//! `StaleRevision` without advancing the checkpoint. Vector writes are
//! exact-key scoped and every representation is claimed under the
//! "corpus" consumer in the `VectorRepresentationClaims` ledger.
//!
//! Reuses the SAME provider-slot machinery as `Corpus` (`build_slot`) —
//! one engine, not a fork.

use crate::basis_store::{BasisStore, PersistedBasis};
use crate::content::{
    CorpusContentChange, CorpusContentId, CorpusContentRecord, CorpusContentSource,
};
use crate::corpus::{Corpus, EmbeddingModelConfig, EncodeSpeed, FloatLaneOutcome, ProviderSlot};
use crate::corpus_provider_counts_store::{
    CorpusProviderCountsStore, PersistedCounts, PersistedCountsReference,
};
use crate::document_store::CorpusDocumentStore;
use crate::engine::inverted_index_store::InvertedIndexStore;
use crate::error::{CorpusKitError, CorpusKitResult};
use crate::index_state_store::{CorpusIndexState, CorpusIndexStateStore};
use crate::schema_profile::{
    attached_declaration, standalone_declaration, CorpusContentConfiguration,
    CorpusIndexUnitPolicy, CorpusOperatingMode,
};
use crate::tokenizer::default_keyword_tokens;
use crate::trainable_embedding_basis::TrainableEmbeddingBasis;
use intellectus_lib::{report, StatSample};
use persistence_kit::{Column, Storage, StoragePredicate, TypedValue};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

/// GLK's room-rollup coordination callback (fired with Drawer IDs).
pub type ContentOnEncoded = Box<dyn Fn(&[String]) + Send + Sync>;
/// Test-only drain failure-injection hook (transient failure when Err).
pub type ContentIngestFailureHook = Box<dyn Fn(&str) -> Result<(), ()> + Send + Sync>;
use vectorkit::{
    EmbeddingProvider, VectorExactKey, VectorPayload, VectorPayloadInput,
    VectorRepresentationClaims, VectorRepresentationKey, VectorStore,
};

/// Range evidence for a standalone passage hit. Never changes result
/// identity.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CorpusEvidence {
    pub passage_id: String,
    pub utf8_start: usize,
    pub utf8_length: usize,
}

/// One recall result: a canonical content ID plus fused score.
#[derive(Debug, Clone, PartialEq)]
pub struct CorpusContentHit {
    pub id: CorpusContentId,
    pub score: f32,
    pub keyword_score: Option<f32>,
    pub vector_score: Option<f32>,
    pub evidence: Option<CorpusEvidence>,
}

/// The async index-work payload: identity/revision/digest/cursor — NEVER
/// text. Serde keys are the cross-port wire contract (Swift
/// `ContentIndexJob` Codable keys).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ContentIndexJob {
    pub kind: ContentIndexJobKind,
    #[serde(rename = "contentID")]
    pub content_id: CorpusContentId,
    pub revision: i64,
    pub digest: Option<String>,
    pub cursor: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ContentIndexJobKind {
    Upsert,
    Remove,
}

impl ContentIndexJob {
    pub fn from_change(change: &CorpusContentChange, cursor: Option<String>) -> Self {
        match change {
            CorpusContentChange::Upsert {
                id,
                revision,
                digest,
            } => ContentIndexJob {
                kind: ContentIndexJobKind::Upsert,
                content_id: id.clone(),
                revision: *revision,
                digest: Some(digest.clone()),
                cursor,
            },
            CorpusContentChange::Remove { id, revision } => ContentIndexJob {
                kind: ContentIndexJobKind::Remove,
                content_id: id.clone(),
                revision: *revision,
                digest: None,
                cursor,
            },
        }
    }
}

// ── Passage production ───────────────────────────────────────────────────

/// Field separator inside passage keys — cannot appear in validated
/// content IDs. Mirrors Swift `PassageProduction.keySeparator`.
const INDEX_UNIT_KEY_SEPARATOR: char = '\u{1F}';
#[cfg(feature = "standalone-passages")]
pub const PASSAGE_KEY_SEPARATOR: char = INDEX_UNIT_KEY_SEPARATOR;

/// Deterministic token-budgeted passage ranges over UTF-8 text. Token
/// boundaries follow the SAME alphanumeric-run rule as
/// `default_keyword_tokens`, computed WITHOUT lowercasing so byte offsets
/// refer to the original text. Mirrors Swift
/// `PassageProduction.passageRanges`.
#[cfg(feature = "standalone-passages")]
pub fn passage_ranges(
    text: &str,
    window_tokens: usize,
    overlap_tokens: usize,
) -> Vec<(usize, usize)> {
    assert!(window_tokens > 0);
    assert!(overlap_tokens < window_tokens);
    let mut token_ranges: Vec<(usize, usize)> = Vec::new();
    let mut run_start: Option<usize> = None;
    let mut offset = 0usize;
    for ch in text.chars() {
        let width = ch.len_utf8();
        let is_token = ch.is_alphabetic() || ch.is_ascii_digit();
        if is_token {
            if run_start.is_none() {
                run_start = Some(offset);
            }
        } else if let Some(start) = run_start.take() {
            token_ranges.push((start, offset));
        }
        offset += width;
    }
    if let Some(start) = run_start {
        token_ranges.push((start, offset));
    }

    let mut out = Vec::new();
    let mut index = 0;
    while index < token_ranges.len() {
        let window_end = (index + window_tokens).min(token_ranges.len());
        let first = token_ranges[index];
        let last = token_ranges[window_end - 1];
        out.push((first.0, last.1 - first.0));
        if window_end == token_ranges.len() {
            break;
        }
        index += window_tokens - overlap_tokens;
    }
    out
}

#[cfg(feature = "standalone-passages")]
fn passage_key(content_id: &str, revision: i64, utf8_start: usize, utf8_length: usize) -> String {
    format!(
        "{content_id}{sep}{revision}{sep}{utf8_start}{sep}{utf8_length}",
        sep = PASSAGE_KEY_SEPARATOR
    )
}

/// Parse a derived-row item key back to its canonical content ID. A
/// whole-content key contains no separator and returns itself.
pub fn content_id_from_item_key(key: &str) -> &str {
    #[cfg(feature = "standalone-passages")]
    {
        match key.find(PASSAGE_KEY_SEPARATOR) {
            Some(pos) => &key[..pos],
            None => key,
        }
    }
    #[cfg(not(feature = "standalone-passages"))]
    {
        key
    }
}

fn evidence_from_item_key(key: &str) -> Option<CorpusEvidence> {
    #[cfg(feature = "standalone-passages")]
    {
        let parts: Vec<&str> = key.split(PASSAGE_KEY_SEPARATOR).collect();
        if parts.len() != 4 {
            return None;
        }
        Some(CorpusEvidence {
            passage_id: key.to_string(),
            utf8_start: parts[2].parse().ok()?,
            utf8_length: parts[3].parse().ok()?,
        })
    }
    #[cfg(not(feature = "standalone-passages"))]
    {
        let _ = key;
        None
    }
}

/// Emit one CorpusKit-tagged counter (the same shape corpus.rs uses).
fn emit_engine_metric(name: &str, value: f64) {
    report!(StatSample::metric(
        name.to_string(),
        value,
        [("kit".to_string(), "CorpusKit".to_string())]
            .into_iter()
            .collect(),
        {
            use std::time::{SystemTime, UNIX_EPOCH};
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_secs_f64())
                .unwrap_or(0.0)
        },
    ));
}

// ── Engine ───────────────────────────────────────────────────────────────

/// The engine/index layout version stamped into `corpus_index_state`.
/// v2 (corrective pass): per-provider coverage rows; attached-mode binary
/// rows written for the DEFAULT slot only.
pub const CONTENT_ENGINE_INDEX_VERSION: i64 = 2;

/// Which slots an indexing pass embeds. `All` is the ordinary path;
/// `StatelessOnly` is the migration's structural rebuild (BM25 +
/// checkpoints + stateless-slot vectors; trainable slots deferred to the
/// train + backfill phases).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SlotScope {
    All,
    StatelessOnly,
}

/// Backfill crash-boundary test hook: (phase, batch_index) where phase is
/// "afterVectors" or "afterCoverage"; an Err aborts the backfill there.
pub type ContentBackfillFaultHook = Box<dyn Fn(&str, usize) -> Result<(), String> + Send + Sync>;

/// The consumer name this engine claims representations under.
pub const CLAIMS_CONSUMER: &str = "corpus";

/// Reserved checkpoint row recording the last APPLIED feed cursor.
const FEED_CURSOR_ROW_ID: &str = "\u{1F}feed";

#[cfg(target_os = "macos")]
fn physical_memory_bytes() -> Option<u64> {
    use std::ffi::{c_char, c_void};
    unsafe extern "C" {
        fn sysctlbyname(
            name: *const c_char,
            oldp: *mut c_void,
            oldlenp: *mut usize,
            newp: *mut c_void,
            newlen: usize,
        ) -> i32;
    }
    let name = b"hw.memsize\0";
    let mut value = 0u64;
    let mut size = std::mem::size_of::<u64>();
    let result = unsafe {
        sysctlbyname(
            name.as_ptr().cast(),
            (&mut value as *mut u64).cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    (result == 0 && size == std::mem::size_of::<u64>()).then_some(value)
}

#[cfg(target_os = "linux")]
fn physical_memory_bytes() -> Option<u64> {
    let meminfo = std::fs::read_to_string("/proc/meminfo").ok()?;
    let kib = meminfo.lines().find_map(|line| {
        let mut fields = line.split_whitespace();
        (fields.next()? == "MemTotal:")
            .then(|| fields.next()?.parse::<u64>().ok())
            .flatten()
    })?;
    kib.checked_mul(1_024)
}

#[cfg(target_os = "windows")]
fn physical_memory_bytes() -> Option<u64> {
    #[repr(C)]
    struct MemoryStatusEx {
        length: u32,
        memory_load: u32,
        total_physical: u64,
        available_physical: u64,
        total_page_file: u64,
        available_page_file: u64,
        total_virtual: u64,
        available_virtual: u64,
        available_extended_virtual: u64,
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GlobalMemoryStatusEx(status: *mut MemoryStatusEx) -> i32;
    }
    let mut status = MemoryStatusEx {
        length: std::mem::size_of::<MemoryStatusEx>() as u32,
        memory_load: 0,
        total_physical: 0,
        available_physical: 0,
        total_page_file: 0,
        available_page_file: 0,
        total_virtual: 0,
        available_virtual: 0,
        available_extended_virtual: 0,
    };
    (unsafe { GlobalMemoryStatusEx(&mut status) } != 0).then_some(status.total_physical)
}

#[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
fn physical_memory_bytes() -> Option<u64> {
    None
}

struct ProviderTrainingJob {
    slot_index: usize,
    model_id: String,
    model_version: String,
    fresh_basis_blob: Vec<u8>,
}

/// Fully computed provider state that has not yet touched durable storage.
/// Worker threads return these; the caller publishes them in slot order.
struct PreparedProviderTraining {
    job: ProviderTrainingJob,
    provider: Box<dyn TrainableEmbeddingBasis>,
    counts_accumulator: Box<dyn TrainableEmbeddingBasis>,
    basis_row: PersistedBasis,
    counts_row: PersistedCounts,
    basis_digest: String,
    subsumed_references: Vec<PersistedCountsReference>,
}

/// The canonical-ID indexing/recall engine. One engine serves BOTH
/// operating modes; only the content source and configuration differ.
pub struct CorpusContentEngine {
    storage: Arc<dyn Storage>,
    configuration: CorpusContentConfiguration,
    source: Arc<dyn CorpusContentSource>,
    inverted_index: InvertedIndexStore,
    vector_store: Arc<VectorStore>,
    basis_store: BasisStore,
    counts_store: CorpusProviderCountsStore,
    index_state: CorpusIndexStateStore,
    coverage_store: crate::provider_coverage_store::CorpusProviderCoverageStore,
    provider_configuration_store:
        crate::provider_configuration_store::CorpusProviderConfigurationStore,
    claims: VectorRepresentationClaims,
    slots: Vec<ProviderSlot>,
    /// Engine-owned content-reference queue state (P3). See
    /// content_engine_queue.rs.
    queue_state: Mutex<Option<crate::content_engine_queue::ContentQueueState>>,
    /// A failed counts/checkpoint transaction must rehydrate maintained counts
    /// before any durable queue reference is attempted again.
    counts_reload_required: AtomicBool,
    /// Serializes identity admission, durable reference/checkpoint commit, and
    /// the corresponding in-memory fold at the queue batch boundary.
    counts_commit_lock: Mutex<()>,
    /// GLK's room-rollup coordination hook (fired with Drawer IDs).
    on_encoded: Mutex<Option<ContentOnEncoded>>,
    /// Declared encode speed (serial drain today; retained surface).
    encode_speed: Mutex<EncodeSpeed>,
    /// Test-only drain failure-injection hook.
    ingest_failure_hook: Mutex<Option<ContentIngestFailureHook>>,
    /// Test-only single-use forced float store error (default slot).
    forced_float_error: Mutex<Option<String>>,
    /// Test-only single-use provider opt-out for the default float slot.
    #[cfg(feature = "canonical-test-seams")]
    forced_float_provider_opt_out: AtomicBool,
    /// Test-only training fault seams (crash-boundary suites).
    train_fault_after_model: Mutex<Option<String>>,
    train_fault_before_commit_model: Mutex<Option<String>>,
    /// Test-only backfill fault hook (crash-boundary suites).
    backfill_fault_hook: Mutex<Option<ContentBackfillFaultHook>>,
}

impl CorpusContentEngine {
    /// Construct the engine over a validated configuration and content
    /// source. In attached mode NO canonical content table is created.
    pub fn open(
        storage: Arc<dyn Storage>,
        configuration: CorpusContentConfiguration,
        source: Arc<dyn CorpusContentSource>,
        models: Vec<EmbeddingModelConfig>,
    ) -> CorpusKitResult<Self> {
        if models.is_empty() {
            return Err(CorpusKitError::InvalidConfiguration(
                "CorpusContentEngine requires at least one embedding model".into(),
            ));
        }
        let profile = match configuration.mode() {
            CorpusOperatingMode::Standalone => {
                #[cfg(feature = "standalone-passages")]
                {
                    let passages = matches!(
                        configuration.index_unit(),
                        CorpusIndexUnitPolicy::TokenWindows { .. }
                    );
                    standalone_declaration(passages)
                }
                #[cfg(not(feature = "standalone-passages"))]
                {
                    standalone_declaration(false)
                }
            }
            CorpusOperatingMode::Attached => attached_declaration(),
        };
        storage
            .migrate(&profile)
            .map_err(|e| CorpusKitError::StoreUnavailable(format!("{e:?}")))?;
        #[cfg(feature = "standalone-passages")]
        if configuration.mode() == CorpusOperatingMode::Standalone {
            crate::index_configuration_store::CorpusIndexConfigurationStore::new(Arc::clone(
                &storage,
            ))
            .bind(configuration.index_unit())?;
        }
        storage
            .migrate(&VectorStore::schema_declaration())
            .map_err(|e| CorpusKitError::StoreUnavailable(format!("{e:?}")))?;
        storage
            .migrate(&VectorRepresentationClaims::schema_declaration())
            .map_err(|e| CorpusKitError::StoreUnavailable(format!("{e:?}")))?;

        let inverted_index = InvertedIndexStore::open_for_storage(&storage)
            .map_err(|e| CorpusKitError::StoreUnavailable(format!("{e:?}")))?;
        let vector_store = Arc::new(VectorStore::new(
            Arc::clone(&storage),
            VectorStore::default_sidecar_path(&storage),
        ));
        let basis_store = BasisStore::new(Arc::clone(&storage));
        let counts_store = CorpusProviderCountsStore::new(Arc::clone(&storage));
        let index_state = CorpusIndexStateStore::new(Arc::clone(&storage));
        let coverage_store =
            crate::provider_coverage_store::CorpusProviderCoverageStore::new(Arc::clone(&storage));
        let provider_configuration_store =
            crate::provider_configuration_store::CorpusProviderConfigurationStore::new(Arc::clone(
                &storage,
            ));
        let claims = VectorRepresentationClaims::new(Arc::clone(&storage));

        let mut slots = Vec::with_capacity(models.len());
        for model in models {
            slots.push(Corpus::build_slot(model, &basis_store, &counts_store)?);
        }

        let engine = CorpusContentEngine {
            storage,
            configuration,
            source,
            inverted_index,
            vector_store,
            basis_store,
            counts_store,
            index_state,
            coverage_store,
            provider_configuration_store,
            claims,
            slots,
            queue_state: Mutex::new(None),
            counts_reload_required: AtomicBool::new(false),
            counts_commit_lock: Mutex::new(()),
            on_encoded: Mutex::new(None),
            encode_speed: Mutex::new(EncodeSpeed::Foreground),
            ingest_failure_hook: Mutex::new(None),
            forced_float_error: Mutex::new(None),
            #[cfg(feature = "canonical-test-seams")]
            forced_float_provider_opt_out: AtomicBool::new(false),
            train_fault_after_model: Mutex::new(None),
            train_fault_before_commit_model: Mutex::new(None),
            backfill_fault_hook: Mutex::new(None),
        };
        // Rehydrate the base snapshot plus crash-durable reference deltas.
        engine.reload_counts_from_storage()?;
        Ok(engine)
    }

    /// STANDALONE convenience: construct a whole-content standalone engine
    /// that OWNS its canonical documents (a `CorpusDocumentStore` over the
    /// same storage). Mirrors Swift `init(standaloneOn:models:)`.
    pub fn standalone_on(
        storage: Arc<dyn Storage>,
        models: Vec<EmbeddingModelConfig>,
    ) -> CorpusKitResult<Self> {
        storage
            .migrate(&CorpusDocumentStore::schema_declaration())
            .map_err(|e| CorpusKitError::StoreUnavailable(format!("{e:?}")))?;
        let store = Arc::new(CorpusDocumentStore::new(Arc::clone(&storage)));
        Self::open(
            storage,
            CorpusContentConfiguration::new(
                CorpusOperatingMode::Standalone,
                CorpusIndexUnitPolicy::WholeContent,
            )?,
            store as Arc<dyn CorpusContentSource>,
            models,
        )
    }

    /// Standalone SDK convenience with an explicit database-bound token-window
    /// policy. Absent from GLK/MOOTx01 builds.
    #[cfg(feature = "standalone-passages")]
    pub fn standalone_on_with_policy(
        storage: Arc<dyn Storage>,
        index_unit: CorpusIndexUnitPolicy,
        models: Vec<EmbeddingModelConfig>,
    ) -> CorpusKitResult<Self> {
        storage
            .migrate(&CorpusDocumentStore::schema_declaration())
            .map_err(|e| CorpusKitError::StoreUnavailable(format!("{e:?}")))?;
        let store = Arc::new(CorpusDocumentStore::new(Arc::clone(&storage)));
        Self::open(
            storage,
            CorpusContentConfiguration::new(CorpusOperatingMode::Standalone, index_unit)?,
            store as Arc<dyn CorpusContentSource>,
            models,
        )
    }

    /// STANDALONE convenience: put canonical text and index it in one call.
    /// Attached mode rejects content mutation through CorpusKit.
    pub fn ingest(&self, text: &str, content_id: &str, now_millis: i64) -> CorpusKitResult<()> {
        if !self.configuration.allows_content_mutation() {
            return Err(CorpusKitError::AttachedModeViolation(
                "content mutation through CorpusKit is standalone-only — attached \
                 content changes flow through the canonical store's own verbs"
                    .into(),
            ));
        }
        Self::validate(content_id)?;
        if text.is_empty() {
            return Ok(());
        }
        // The standalone source IS a CorpusDocumentStore; route the put
        // through a fresh handle over the same storage (same tables).
        let store = CorpusDocumentStore::new(Arc::clone(&self.storage));
        crate::content::CorpusContentStore::put(&store, text, content_id, now_millis)?;
        self.index_content(content_id, now_millis)?;
        Ok(())
    }

    // ── Queue plumbing accessors (content_engine_queue.rs) ───────────────

    pub(crate) fn queue_state(
        &self,
    ) -> &Mutex<Option<crate::content_engine_queue::ContentQueueState>> {
        &self.queue_state
    }

    pub(crate) fn storage_ref(&self) -> &Arc<dyn Storage> {
        &self.storage
    }

    /// Install (or clear) the `on_encoded` coordination callback.
    pub fn set_on_encoded<F>(&self, callback: F)
    where
        F: Fn(&[String]) + Send + Sync + 'static,
    {
        if let Ok(mut guard) = self.on_encoded.lock() {
            *guard = Some(Box::new(callback));
        }
    }

    pub(crate) fn fire_on_encoded(&self, ids: &[String]) {
        if let Ok(guard) = self.on_encoded.lock() {
            if let Some(cb) = guard.as_ref() {
                cb(ids);
            }
        }
    }

    /// Arm (or clear) the drain failure-injection hook (test seam).
    pub fn arm_ingest_failure_hook(&self, hook: Option<ContentIngestFailureHook>) {
        if let Ok(mut guard) = self.ingest_failure_hook.lock() {
            *guard = hook;
        }
    }

    pub(crate) fn fire_ingest_failure_hook(&self, id: &str) -> Result<(), ()> {
        if let Ok(guard) = self.ingest_failure_hook.lock() {
            if let Some(hook) = guard.as_ref() {
                return hook(id);
            }
        }
        Ok(())
    }

    /// Test seam: force the next per-signal float call to report a store
    /// error for the DEFAULT slot (single-use).
    pub fn test_force_float_store_error(&self, message: impl Into<String>) {
        if let Ok(mut guard) = self.forced_float_error.lock() {
            *guard = Some(message.into());
        }
    }

    /// Test seam: force the next default float call to report provider opt-out.
    #[cfg(feature = "canonical-test-seams")]
    pub fn test_force_float_provider_opt_out(&self) {
        self.forced_float_provider_opt_out
            .store(true, Ordering::Release);
    }

    /// The declared encode speed (serial drain today; surface retained).
    pub fn set_encode_speed(&self, speed: EncodeSpeed) {
        if let Ok(mut guard) = self.encode_speed.lock() {
            *guard = speed;
        }
    }

    fn embed_concurrency_cap(&self) -> usize {
        let cores = std::thread::available_parallelism()
            .map(|count| count.get())
            .unwrap_or(1);
        let speed = self
            .encode_speed
            .lock()
            .map(|guard| *guard)
            .unwrap_or(EncodeSpeed::Foreground);
        match speed {
            EncodeSpeed::Foreground => cores.max(1),
            EncodeSpeed::Background => (cores / 4).max(1),
        }
    }

    /// Batch-resolve current source records for the given IDs. Delegates to
    /// the source's `records_for` (one WHERE…IN query); exposes the source
    /// through a pub(crate) seam so the queue module does not need direct
    /// field access.
    pub(crate) fn source_records_for(
        &self,
        ids: &[&str],
    ) -> CorpusKitResult<HashMap<String, CorpusContentRecord>> {
        self.source.records_for(ids)
    }

    pub(crate) fn begin_deferred_vector_index(&self) -> CorpusKitResult<()> {
        self.vector_store
            .begin_deferred_index()
            .map_err(|e| CorpusKitError::StoreUnavailable(format!("{e:?}")))
    }

    pub(crate) fn publish_vector_index(&self) -> CorpusKitResult<()> {
        self.vector_store
            .publish_resident_index()
            .map_err(|e| CorpusKitError::StoreUnavailable(format!("{e:?}")))
    }

    // ── GLK orchestration surface (P3 cutover compatibility) ─────────────

    /// BM25-only top-k with the coordinator's historical tuple shape —
    /// identity is DIRECT (the ID is the Drawer ID).
    pub fn bm25_top_k_by_source(&self, query: &str, limit: usize) -> Vec<(String, f32)> {
        self.bm25_top_k(query, limit).unwrap_or_default()
    }

    /// Live indexed content IDs — the intake backfill's skip set.
    pub fn indexed_source_ids(&self) -> CorpusKitResult<std::collections::HashSet<String>> {
        Ok(self.indexed_content_ids()?.into_iter().collect())
    }

    /// Indexed content-row count (content-unit semantics).
    pub fn count(&self) -> CorpusKitResult<usize> {
        Ok(self.indexed_content_ids()?.len())
    }

    /// The estate's single dense vector store (borrowed by GLK's recall
    /// vector lane — one store, one resident array).
    pub fn shared_vector_store(&self) -> Arc<VectorStore> {
        Arc::clone(&self.vector_store)
    }

    /// Clear one content ID's derived state directly (expunge/withdraw path).
    pub fn remove_content(&self, id: &str) -> CorpusKitResult<()> {
        Self::validate(id)?;
        self.clear_derived_state(id)
    }

    /// Embed on the default signal (the recall probe surface).
    pub fn embed(&self, text: &str) -> CorpusKitResult<engram_lib::Engram> {
        let handle = self.slots[0].handle.lock().unwrap();
        handle
            .provider()
            .embed(text)
            .map_err(|e| CorpusKitError::EmbeddingFailed(format!("{e:?}")))
    }

    /// Per-content derived-index coverage attestations (the engine's ONLY
    /// integrity surface — no second content Merkle hierarchy).
    pub fn index_coverage_attestations(&self) -> CorpusKitResult<Vec<(String, i64, String)>> {
        Ok(self
            .index_state_all_states()?
            .into_iter()
            .map(|s| (s.content_id, s.revision, s.digest))
            .collect())
    }

    fn index_state_all_states(
        &self,
    ) -> CorpusKitResult<Vec<crate::index_state_store::CorpusIndexState>> {
        Ok(self
            .index_state
            .all_states()?
            .into_iter()
            .filter(|s| s.content_id != FEED_CURSOR_ROW_ID)
            .collect())
    }

    /// Destroy this engine's recall index — OWNERSHIP-SCOPED: exact-key
    /// vector deletes (checkpointed IDs × slots × lanes), wholesale clears
    /// only on corpus-exclusive tables, claim release for the "corpus"
    /// consumer.
    pub fn destroy_recall_index(&self) -> CorpusKitResult<()> {
        // Claim-aware: keys in representation families another retained
        // consumer also claims are NOT deleted — that claimant may own the
        // exact same rows. The engine releases its own claims below; the
        // surviving claimant's rows survive with it.
        let shared = self.shared_representation_families()?;
        let ids = self.indexed_content_ids()?;
        let mut keys: Vec<VectorExactKey> = Vec::new();
        for id in &ids {
            for key in self.unit_keys(id)? {
                for slot in &self.slots {
                    for lane in [0u32, 1u32] {
                        if shared.contains(&format!("{}|{lane}", slot.model_id)) {
                            continue;
                        }
                        keys.push(VectorExactKey::new(
                            key.clone(),
                            lane,
                            slot.model_id.clone(),
                        ));
                    }
                }
            }
        }
        self.vector_store
            .delete_vectors(&keys)
            .map_err(|e| CorpusKitError::StoreUnavailable(format!("{e:?}")))?;
        self.inverted_index
            .clear_all()
            .map_err(|e| CorpusKitError::StoreUnavailable(format!("{e:?}")))?;
        self.index_state.clear_all()?;
        self.coverage_store.clear_all()?;
        self.basis_store.delete_all()?;
        self.counts_store.delete_all()?;
        self.claims
            .release_all_claims(CLAIMS_CONSUMER)
            .map_err(|e| CorpusKitError::StoreUnavailable(format!("{e:?}")))?;
        Ok(())
    }

    /// Per-signal dense float NEAREST recall — content-ID keyed.
    pub fn float_nearest_per_signal(
        &self,
        query: &str,
        limit: usize,
    ) -> Vec<(String, FloatLaneOutcome)> {
        self.float_per_signal(query, limit, true)
    }

    /// Per-signal dense float FARTHEST (anti-similarity) recall.
    pub fn float_farthest_per_signal(
        &self,
        query: &str,
        limit: usize,
    ) -> Vec<(String, FloatLaneOutcome)> {
        self.float_per_signal(query, limit, false)
    }

    /// Single-signal convenience: the DEFAULT slot's nearest outcome.
    pub fn float_nearest(&self, query: &str, limit: usize) -> FloatLaneOutcome {
        self.float_nearest_per_signal(query, limit)
            .into_iter()
            .next()
            .map(|(_, o)| o)
            .unwrap_or(FloatLaneOutcome::EmptyQuery)
    }

    fn float_per_signal(
        &self,
        query: &str,
        limit: usize,
        nearest: bool,
    ) -> Vec<(String, FloatLaneOutcome)> {
        if limit == 0 || query.is_empty() {
            return self
                .slots
                .iter()
                .map(|s| (s.model_id.clone(), FloatLaneOutcome::EmptyQuery))
                .collect();
        }
        // Consume the forced-error seam for the DEFAULT slot (nearest only).
        let mut forced_default: Option<FloatLaneOutcome> = None;
        if nearest {
            #[cfg(feature = "canonical-test-seams")]
            let forced_provider_opt_out = self
                .forced_float_provider_opt_out
                .swap(false, Ordering::AcqRel);
            #[cfg(not(feature = "canonical-test-seams"))]
            let forced_provider_opt_out = false;
            if forced_provider_opt_out {
                emit_engine_metric("corpus.float_lane.dark_provider", 1.0);
                forced_default = Some(FloatLaneOutcome::UnavailableProviderOptOut);
            } else if let Ok(mut guard) = self.forced_float_error.lock() {
                if let Some(message) = guard.take() {
                    emit_engine_metric("corpus.float_lane.store_error", 1.0);
                    forced_default = Some(FloatLaneOutcome::StoreError(message));
                }
            }
        }
        let mut results = Vec::with_capacity(self.slots.len());
        for (slot_index, slot) in self.slots.iter().enumerate() {
            let model_id = slot.model_id.clone();
            if slot_index == 0 {
                if let Some(forced) = forced_default.take() {
                    results.push((model_id, forced));
                    continue;
                }
            }
            let probe = {
                let handle = slot.handle.lock().unwrap();
                match handle.provider().embed_float(query) {
                    Ok(v) if v.is_empty() => {
                        emit_engine_metric("corpus.float_lane.dark_provider", 1.0);
                        results.push((model_id, FloatLaneOutcome::UnavailableProviderOptOut));
                        continue;
                    }
                    Ok(v) => v,
                    Err(vectorkit::VectorKitError::EmbedFloatVocabMiss(_)) => {
                        emit_engine_metric("corpus.float_lane.dark_vocab_miss", 1.0);
                        results.push((model_id, FloatLaneOutcome::UnavailableNoVocabHit));
                        continue;
                    }
                    Err(_) => {
                        emit_engine_metric("corpus.float_lane.dark_provider", 1.0);
                        results.push((model_id, FloatLaneOutcome::UnavailableProviderOptOut));
                        continue;
                    }
                }
            };
            let matches = if nearest {
                self.vector_store
                    .find_nearest_float(&probe, &model_id, limit * 4)
            } else {
                self.vector_store
                    .find_farthest_float(&probe, &model_id, limit * 4)
            };
            let matches = match matches {
                Ok(m) => m,
                Err(e) => {
                    emit_engine_metric("corpus.float_lane.store_error", 1.0);
                    results.push((model_id, FloatLaneOutcome::StoreError(format!("{e:?}"))));
                    continue;
                }
            };
            if matches.is_empty() {
                emit_engine_metric("corpus.float_lane.dark_no_rows", 1.0);
                results.push((model_id, FloatLaneOutcome::UnavailableNoFloatRows));
                continue;
            }
            let mut by_content: BTreeMap<String, f32> = BTreeMap::new();
            for m in &matches {
                let id = content_id_from_item_key(&m.item_id).to_string();
                let similarity = 1.0 - (m.distance as f32) / 10_000.0;
                let entry =
                    by_content
                        .entry(id)
                        .or_insert(if nearest { f32::MIN } else { f32::MAX });
                if nearest {
                    if similarity > *entry {
                        *entry = similarity;
                    }
                } else if similarity < *entry {
                    *entry = similarity;
                }
            }
            if by_content.is_empty() {
                emit_engine_metric("corpus.float_lane.dark_no_rows", 1.0);
                results.push((model_id, FloatLaneOutcome::UnavailableNoFloatRows));
                continue;
            }
            let mut ranked: Vec<(String, f32)> = by_content.into_iter().collect();
            ranked.sort_by(|a, b| {
                let ord = if nearest {
                    b.1.partial_cmp(&a.1)
                } else {
                    a.1.partial_cmp(&b.1)
                };
                ord.unwrap_or(std::cmp::Ordering::Equal)
                    .then_with(|| a.0.cmp(&b.0))
            });
            ranked.truncate(limit);
            emit_engine_metric("corpus.float_lane.hit", ranked.len() as f64);
            results.push((model_id, FloatLaneOutcome::Hits(ranked)));
        }
        results
    }

    /// Register this engine's representation claims (idempotent).
    pub fn register_claims(&self, now_millis: i64) -> CorpusKitResult<()> {
        for (slot_index, slot) in self.slots.iter().enumerate() {
            let (model_id, model_version) = {
                let handle = slot.handle.lock().unwrap();
                let p = handle.provider();
                (p.model_id().to_string(), p.model_version().to_string())
            };
            for lane in [0u32, 1u32] {
                // Attached mode writes binary (lane 0) rows for the DEFAULT
                // slot only — GLK's Hamming readers all probe the default
                // model — so non-default binary claims are not registered
                // there either. Standalone keeps per-slot binary lanes.
                if lane == 0
                    && slot_index != 0
                    && self.configuration.mode() == CorpusOperatingMode::Attached
                {
                    continue;
                }
                self.claims
                    .register_claim(
                        CLAIMS_CONSUMER,
                        &VectorRepresentationKey::new(
                            model_id.clone(),
                            model_version.clone(),
                            lane,
                        ),
                        now_millis,
                    )
                    .map_err(|e| CorpusKitError::StoreUnavailable(format!("{e:?}")))?;
            }
        }
        Ok(())
    }

    /// Current-format provider reconciliation. Provider additions train and
    /// coverage-backfill through the ordinary engine; removals release the
    /// Corpus claim and delete only vectors with no retained claimant plus the
    /// retired provider's basis/count/coverage residue. This is runtime index
    /// maintenance, not a historical estate migration.
    pub fn reconcile_configured_providers(&self, now_millis: i64) -> CorpusKitResult<()> {
        let mut desired: BTreeSet<VectorRepresentationKey> = BTreeSet::new();
        for (slot_index, slot) in self.slots.iter().enumerate() {
            let handle = slot.handle.lock().unwrap();
            let provider = handle.provider();
            for lane in [0u32, 1u32] {
                if lane == 0
                    && slot_index != 0
                    && self.configuration.mode() == CorpusOperatingMode::Attached
                {
                    continue;
                }
                desired.insert(VectorRepresentationKey::new(
                    provider.model_id(),
                    provider.model_version(),
                    lane,
                ));
            }
        }
        let existing: BTreeSet<_> = self
            .claims
            .claims(CLAIMS_CONSUMER)
            .map_err(|error| CorpusKitError::StoreUnavailable(format!("{error:?}")))?
            .into_iter()
            .collect();
        if existing == desired
            && self.provider_configuration_store.generation_token()?
                == Some(self.provider_generation_token())
        {
            return Ok(());
        }
        self.register_claims(now_millis)?;
        let stale: Vec<_> = existing
            .into_iter()
            .filter(|key| !desired.contains(key))
            .collect();
        let mut retired: BTreeSet<(String, String)> = BTreeSet::new();
        for key in stale {
            let others: Vec<_> = self
                .claims
                .claimants(&key)
                .map_err(|error| CorpusKitError::StoreUnavailable(format!("{error:?}")))?
                .into_iter()
                .filter(|consumer| consumer != CLAIMS_CONSUMER)
                .collect();
            self.claims
                .release_claim(CLAIMS_CONSUMER, &key)
                .map_err(|error| CorpusKitError::StoreUnavailable(format!("{error:?}")))?;
            if others.is_empty() {
                let predicate = StoragePredicate::all(vec![
                    StoragePredicate::Eq(
                        Column::new("vectors", "model_id"),
                        TypedValue::Text(key.model_id.clone()),
                    ),
                    StoragePredicate::Eq(
                        Column::new("vectors", "vector_index"),
                        TypedValue::Int(key.vector_index as i64),
                    ),
                ]);
                let rows = self
                    .storage
                    .row_store()
                    .query("vectors", Some(&predicate), &[], None, None)
                    .map_err(|error| CorpusKitError::StoreUnavailable(format!("{error:?}")))?;
                let exact: Vec<_> = rows
                    .iter()
                    .filter_map(|row| match (row.get("model_version"), row.get("item_id")) {
                        (Some(TypedValue::Text(version)), Some(TypedValue::Text(item_id)))
                            if version == &key.model_version =>
                        {
                            Some(VectorExactKey::new(
                                item_id.clone(),
                                key.vector_index,
                                key.model_id.clone(),
                            ))
                        }
                        _ => None,
                    })
                    .collect();
                self.vector_store
                    .delete_vectors(&exact)
                    .map_err(|error| CorpusKitError::StoreUnavailable(format!("{error:?}")))?;
            }
            retired.insert((key.model_id, key.model_version));
        }

        let desired_model_ids: BTreeSet<String> =
            desired.iter().map(|key| key.model_id.clone()).collect();
        for (model_id, model_version) in retired {
            for table in [
                "corpus_provider_basis",
                "corpus_provider_counts",
                "corpus_provider_count_references",
            ] {
                self.storage
                    .row_store()
                    .delete(
                        table,
                        &StoragePredicate::all(vec![
                            StoragePredicate::Eq(
                                Column::new(table, "model_id"),
                                TypedValue::Text(model_id.clone()),
                            ),
                            StoragePredicate::Eq(
                                Column::new(table, "model_version"),
                                TypedValue::Text(model_version.clone()),
                            ),
                        ]),
                    )
                    .map_err(|error| CorpusKitError::StoreUnavailable(format!("{error:?}")))?;
            }
            if !desired_model_ids.contains(&model_id) {
                self.storage
                    .row_store()
                    .delete(
                        "corpus_provider_coverage",
                        &StoragePredicate::Eq(
                            Column::new("corpus_provider_coverage", "model_id"),
                            TypedValue::Text(model_id),
                        ),
                    )
                    .map_err(|error| CorpusKitError::StoreUnavailable(format!("{error:?}")))?;
            }
        }

        self.train_trainable_slots(now_millis, false)?;
        self.vector_store
            .begin_deferred_index()
            .map_err(|error| CorpusKitError::StoreUnavailable(format!("{error:?}")))?;
        self.backfill_provider_coverage(now_millis, 500)?;
        self.vector_store
            .publish_resident_index()
            .map_err(|error| CorpusKitError::StoreUnavailable(format!("{error:?}")))?;
        // LAST durable write: a crash before this point retries from
        // per-provider coverage; a matching open avoids an O(corpus) scan.
        self.provider_configuration_store
            .mark_current(&self.provider_generation_token(), now_millis)?;
        Ok(())
    }

    fn provider_generation_token(&self) -> String {
        let generations = self
            .slots
            .iter()
            .map(|slot| {
                let handle = slot.handle.lock().unwrap();
                let provider = handle.provider();
                format!(
                    "{}@{}={}",
                    provider.model_id(),
                    provider.model_version(),
                    slot.basis_digest.lock().unwrap().as_str()
                )
            })
            .collect::<Vec<_>>()
            .join("|");
        format!("{}|{}", self.configuration_fingerprint(), generations)
    }

    fn validate(id: &str) -> CorpusKitResult<()> {
        if id.is_empty() || id.contains(INDEX_UNIT_KEY_SEPARATOR) {
            return Err(CorpusKitError::InvalidConfiguration(
                "content IDs must be non-empty and must not contain the U+001F separator".into(),
            ));
        }
        Ok(())
    }

    /// Index (or re-index) the CURRENT record for `id`. Returns true when
    /// live content was indexed; false when the ID no longer resolves
    /// (derived state cleared).
    pub fn index_content(&self, id: &str, now_millis: i64) -> CorpusKitResult<bool> {
        Self::validate(id)?;
        match self.source.record(id)? {
            Some(record) => {
                self.index_record(&record, None, false, now_millis, SlotScope::All)?;
                Ok(true)
            }
            None => {
                self.clear_derived_state(id)?;
                Ok(false)
            }
        }
    }

    /// STRUCTURAL index for the migration's rebuild phase: BM25 postings,
    /// checkpoint, and STATELESS-slot vectors + coverage only. Trainable
    /// slots are deferred to `train_trainable_slots` + the coverage
    /// backfill so the rebuild never triggers training and never
    /// double-writes. Mirrors Swift `indexContentStructural`.
    pub fn index_content_structural(&self, id: &str, now_millis: i64) -> CorpusKitResult<bool> {
        Self::validate(id)?;
        match self.source.record(id)? {
            Some(record) => {
                self.index_record(&record, None, false, now_millis, SlotScope::StatelessOnly)?;
                Ok(true)
            }
            None => {
                self.clear_derived_state(id)?;
                Ok(false)
            }
        }
    }

    /// Migration rebuild kernel: resolve a bounded batch, run pure
    /// tokenization/stateless embedding on the proven bounded worker shape,
    /// then publish every durable row through one deterministic serial writer.
    /// Checkpoints advance only after the batch's BM25, vectors, and coverage
    /// are durable. Provider math is the same `embed_pair` call used by normal
    /// ingestion; only scheduling changes.
    pub fn index_content_structural_batch(
        &self,
        ids: &[String],
        now_millis: i64,
    ) -> CorpusKitResult<usize> {
        if ids.is_empty() {
            return Ok(0);
        }
        if self.configuration.mode() != CorpusOperatingMode::Attached
            || !matches!(
                self.configuration.index_unit(),
                CorpusIndexUnitPolicy::WholeContent
            )
        {
            return Err(CorpusKitError::InvalidConfiguration(
                "structural batch rebuild is available only to attached whole-content engines"
                    .into(),
            ));
        }
        self.index_whole_content_batch(ids, now_millis, SlotScope::StatelessOnly, false)
    }

    /// Shared whole-content compute-parallel/write-serial kernel. Migration
    /// selects stateless slots and honors existing checkpoints; full reindex
    /// selects every published slot and forces replacement after retraining.
    /// Passage-range replacement remains on `prepare_index_record` because it
    /// also mutates database-bound range rows.
    fn index_whole_content_batch(
        &self,
        ids: &[String],
        now_millis: i64,
        slot_scope: SlotScope,
        force: bool,
    ) -> CorpusKitResult<usize> {
        if ids.is_empty() {
            return Ok(0);
        }
        if !matches!(
            self.configuration.index_unit(),
            CorpusIndexUnitPolicy::WholeContent
        ) {
            return Err(CorpusKitError::InvalidConfiguration(
                "whole-content batch indexing requires the wholeContent index unit".into(),
            ));
        }
        self.register_claims(now_millis)?;

        let mut records = Vec::with_capacity(ids.len());
        for id in ids {
            Self::validate(id)?;
            let Some(record) = self.source.record(id)? else {
                self.clear_derived_state(id)?;
                continue;
            };
            if !force {
                if let Some(existing) = self.index_state.state(id)? {
                    if existing.revision == record.revision
                        && existing.digest == record.digest
                        && existing.index_version == CONTENT_ENGINE_INDEX_VERSION
                    {
                        continue;
                    }
                }
            }
            records.push(record);
        }
        if records.is_empty() {
            return Ok(0);
        }

        let selected: Vec<usize> = self
            .slots
            .iter()
            .enumerate()
            .filter_map(|(index, slot)| {
                if slot_scope == SlotScope::StatelessOnly && slot.fresh_basis_blob.is_some() {
                    return None;
                }
                if slot.fresh_basis_blob.is_some() && slot.basis_digest.lock().unwrap().is_empty() {
                    return None;
                }
                Some(index)
            })
            .collect();
        let guards: Vec<_> = selected
            .iter()
            .map(|index| {
                self.slots[*index]
                    .handle
                    .lock()
                    .map_err(|_| CorpusKitError::StoreUnavailable("provider lock poisoned".into()))
            })
            .collect::<Result<Vec<_>, _>>()?;
        let providers: Vec<&dyn vectorkit::EmbeddingProvider> =
            guards.iter().map(|guard| guard.provider()).collect();
        let metadata: Vec<(String, String, String, bool)> = selected
            .iter()
            .zip(providers.iter())
            .map(|(index, provider)| {
                (
                    provider.model_id().to_string(),
                    provider.model_version().to_string(),
                    self.slots[*index].basis_digest.lock().unwrap().clone(),
                    *index == 0 || self.configuration.mode() == CorpusOperatingMode::Standalone,
                )
            })
            .collect();
        let cap = self.embed_concurrency_cap();
        let slice_len = ((records.len() + cap - 1) / cap).max(1);
        let providers_ref = &providers;
        let metadata_ref = &metadata;
        let prepared: Vec<(
            CorpusContentRecord,
            Vec<String>,
            Vec<VectorPayloadInput>,
            Vec<(String, String, String)>,
        )> = std::thread::scope(|scope| -> CorpusKitResult<Vec<_>> {
            let handles: Vec<_> = records
                .chunks(slice_len)
                .map(|slice| {
                    scope.spawn(move || -> CorpusKitResult<Vec<_>> {
                        let mut output = Vec::with_capacity(slice.len());
                        for record in slice {
                            let mut rows = Vec::with_capacity(providers_ref.len() * 2);
                            let mut covered = Vec::with_capacity(providers_ref.len());
                            for (provider, meta) in providers_ref.iter().zip(metadata_ref.iter()) {
                                let (engram, floats) =
                                    provider.embed_pair(&record.text).map_err(|error| {
                                        CorpusKitError::EmbeddingFailed(format!("{error:?}"))
                                    })?;
                                if meta.3 {
                                    rows.push(VectorPayloadInput {
                                        item_id: record.id.clone(),
                                        vector_index: 0,
                                        payload: VectorPayload::from_engram(&engram),
                                        model_id: meta.0.clone(),
                                        model_version: meta.1.clone(),
                                        filed_at_unix_secs: now_millis,
                                    });
                                }
                                if !floats.is_empty() {
                                    rows.push(VectorPayloadInput {
                                        item_id: record.id.clone(),
                                        vector_index: 1,
                                        payload: VectorPayload::from_f32(&floats),
                                        model_id: meta.0.clone(),
                                        model_version: meta.1.clone(),
                                        filed_at_unix_secs: now_millis,
                                    });
                                }
                                covered.push((record.id.clone(), meta.0.clone(), meta.2.clone()));
                            }
                            output.push((
                                record.clone(),
                                default_keyword_tokens(&record.text),
                                rows,
                                covered,
                            ));
                        }
                        Ok(output)
                    })
                })
                .collect();
            let mut output = Vec::with_capacity(records.len());
            for handle in handles {
                output.extend(handle.join().expect("structural worker panicked")?);
            }
            Ok(output)
        })?;
        drop(guards);

        for (record, tokens, _, _) in &prepared {
            self.inverted_index
                .index(&record.id, tokens, "")
                .map_err(|error| CorpusKitError::StoreUnavailable(format!("{error:?}")))?;
        }
        let rows: Vec<_> = prepared
            .iter()
            .flat_map(|item| item.2.iter().cloned())
            .collect();
        if !rows.is_empty() {
            self.vector_store
                .add_payloads(&rows)
                .map_err(|error| CorpusKitError::StoreUnavailable(format!("{error:?}")))?;
        }
        let covered: Vec<_> = prepared
            .iter()
            .flat_map(|item| item.3.iter().cloned())
            .collect();
        self.coverage_store.mark_covered(&covered, now_millis)?;
        for (record, _, _, _) in &prepared {
            self.index_state.advance(&CorpusIndexState {
                content_id: record.id.clone(),
                revision: record.revision,
                digest: record.digest.clone(),
                index_version: CONTENT_ENGINE_INDEX_VERSION,
                applied_cursor: None,
                updated_at_millis: now_millis,
            })?;
        }
        Ok(prepared.len())
    }

    /// Apply one change. The stale gate: an upsert whose (revision,
    /// digest) mismatches the CURRENT record returns `StaleRevision` and
    /// advances NOTHING.
    pub fn apply_change(
        &self,
        change: &CorpusContentChange,
        cursor: Option<&str>,
        now_millis: i64,
    ) -> CorpusKitResult<()> {
        Self::validate(change.id())?;
        match change {
            CorpusContentChange::Upsert {
                id,
                revision,
                digest,
            } => {
                let Some(record) = self.source.record(id)? else {
                    return Err(CorpusKitError::StaleRevision(format!(
                        "upsert for {id} rev {revision}: the ID no longer resolves — \
                         the remove change will clear it"
                    )));
                };
                if record.revision != *revision || record.digest != *digest {
                    return Err(CorpusKitError::StaleRevision(format!(
                        "upsert for {id} rev {revision} does not match the current record \
                         rev {} — stale job rejected without checkpoint advance",
                        record.revision
                    )));
                }
                self.index_record(&record, cursor, false, now_millis, SlotScope::All)?;
            }
            CorpusContentChange::Remove { id, .. } => {
                self.clear_derived_state(id)?;
            }
        }
        if let Some(cursor) = cursor {
            self.advance_feed_cursor(cursor, now_millis)?;
        }
        Ok(())
    }

    /// Process one queue job payload — the drain-worker entry point.
    pub fn process_job(&self, job: &ContentIndexJob, now_millis: i64) -> CorpusKitResult<()> {
        match job.kind {
            ContentIndexJobKind::Upsert => {
                let Some(digest) = &job.digest else {
                    return Err(CorpusKitError::InvalidConfiguration(format!(
                        "upsert job for {} carries no digest",
                        job.content_id
                    )));
                };
                self.apply_change(
                    &CorpusContentChange::Upsert {
                        id: job.content_id.clone(),
                        revision: job.revision,
                        digest: digest.clone(),
                    },
                    job.cursor.as_deref(),
                    now_millis,
                )
            }
            ContentIndexJobKind::Remove => self.apply_change(
                &CorpusContentChange::Remove {
                    id: job.content_id.clone(),
                    revision: job.revision,
                },
                job.cursor.as_deref(),
                now_millis,
            ),
        }
    }

    /// Queue-only preparation seam. Derived vectors and coverage are written
    /// in their normal order, while the final content/cursor checkpoints are
    /// returned for an atomic batch commit with maintained provider counts.
    pub(crate) fn prepare_queue_job(
        &self,
        job: &ContentIndexJob,
        now_millis: i64,
        content_already_prepared: bool,
        prefetched_record: Option<CorpusContentRecord>,
    ) -> CorpusKitResult<(Vec<CorpusIndexState>, Option<(String, i64, String, String)>)> {
        if self.counts_reload_required.load(Ordering::Acquire) {
            self.reload_counts_from_storage()?;
            self.counts_reload_required.store(false, Ordering::Release);
        }
        Self::validate(&job.content_id)?;
        let mut checkpoints = Vec::with_capacity(2);
        let mut counts_update = None;
        match job.kind {
            ContentIndexJobKind::Upsert => {
                let Some(digest) = &job.digest else {
                    return Err(CorpusKitError::InvalidConfiguration(format!(
                        "upsert job for {} carries no digest",
                        job.content_id
                    )));
                };
                // Use the batch-prefetched record when provided; fall back to a
                // single source read only when called without pre-fetch context.
                let record_opt = match prefetched_record {
                    Some(r) => Some(r),
                    None => self.source.record(&job.content_id)?,
                };
                let Some(record) = record_opt else {
                    return Err(CorpusKitError::StaleRevision(format!(
                        "upsert for {} rev {}: the ID no longer resolves — the remove change will clear it",
                        job.content_id, job.revision
                    )));
                };
                if record.revision != job.revision || record.digest != *digest {
                    return Err(CorpusKitError::StaleRevision(format!(
                        "upsert for {} rev {} does not match the current record rev {} — stale job rejected without checkpoint advance",
                        job.content_id, job.revision, record.revision
                    )));
                }
                if !content_already_prepared {
                    if let Some(checkpoint) = self.prepare_index_record(
                        &record,
                        job.cursor.as_deref(),
                        false,
                        now_millis,
                        SlotScope::All,
                    )? {
                        // Every newly prepared revision reaches the durable-
                        // reference admission authority at batch close. It
                        // distinguishes a new identity, an idempotent replay,
                        // and a changed digest whose novel vocabulary advances
                        // the governor anchor without incrementing documents.
                        counts_update = Some((
                            record.id.clone(),
                            record.revision,
                            record.digest.clone(),
                            record.text.clone(),
                        ));
                        checkpoints.push(checkpoint);
                    }
                }
            }
            ContentIndexJobKind::Remove => self.clear_derived_state(&job.content_id)?,
        }
        if let Some(cursor) = &job.cursor {
            checkpoints.push(CorpusIndexState {
                content_id: FEED_CURSOR_ROW_ID.to_string(),
                revision: 0,
                digest: String::new(),
                index_version: CONTENT_ENGINE_INDEX_VERSION,
                applied_cursor: Some(cursor.clone()),
                updated_at_millis: now_millis,
            });
        }
        Ok((checkpoints, counts_update))
    }

    /// Last-write transaction for a durable queue batch. A crash can observe
    /// either the old counts/checkpoints (and replay the durable references) or
    /// the new pair, never a checkpoint that outruns its maintained counts.
    pub(crate) fn commit_queue_batch(
        &self,
        checkpoints: &[CorpusIndexState],
        counts_updates: &[(String, i64, String, String)],
        now_millis: i64,
    ) -> CorpusKitResult<()> {
        let _commit_guard = self
            .counts_commit_lock
            .lock()
            .map_err(|_| CorpusKitError::StoreUnavailable("counts commit lock poisoned".into()))?;
        // A prior failed commit whose reload ALSO failed leaves the in-memory
        // accumulator dirty; heal from storage before any new fold.
        if self.counts_reload_required.load(Ordering::Acquire) {
            self.reload_counts_from_storage()?;
            self.counts_reload_required.store(false, Ordering::Release);
        }
        // The published provider counts stay frozen. Each reference carries
        // only the hashes of genuinely novel terms accumulated for that
        // identity, making repeated revisions byte-identical across reopen.
        let mut references: Vec<(PersistedCountsReference, usize, BTreeSet<String>, bool)> =
            Vec::new();
        let mut consumed_subsumed_references: Vec<(String, String, String)> = Vec::new();
        if !counts_updates.is_empty() {
            // Deduplicate content IDs once before the slot loop so the batch
            // query (one per slot) fetches exactly the set needed.
            let mut seen_ids = HashSet::new();
            let unique_content_ids: Vec<&str> = counts_updates
                .iter()
                .filter_map(|(cid, _, _, _)| {
                    if seen_ids.insert(cid.as_str()) {
                        Some(cid.as_str())
                    } else {
                        None
                    }
                })
                .collect();
            for (slot_index, slot) in self.slots.iter().enumerate() {
                let (model_id, model_version) = {
                    let handle = slot.handle.lock().unwrap();
                    let provider = handle.provider();
                    (
                        provider.model_id().to_string(),
                        provider.model_version().to_string(),
                    )
                };
                if slot.counts.lock().unwrap().is_none() {
                    continue;
                }
                // Batch-fetch all references for this slot in one WHERE…IN query
                // instead of N individual reference_for calls. Semantics identical:
                // the HashMap returns None-for-absent, matching the old path.
                let existing_refs = self.counts_store.references_for(
                    &model_id,
                    &model_version,
                    &unique_content_ids,
                )?;
                let mut admitted_ids = HashSet::new();
                for (content_id, revision, digest, text) in counts_updates {
                    if !admitted_ids.insert(content_id.clone()) {
                        continue;
                    }
                    let mut term_digests = BTreeSet::new();
                    let counts_document = match existing_refs.get(content_id.as_str()) {
                        Some(existing) if existing.digest == *digest => {
                            if existing.is_subsumed {
                                consumed_subsumed_references.push((
                                    model_id.clone(),
                                    model_version.clone(),
                                    content_id.clone(),
                                ));
                            }
                            continue;
                        }
                        Some(existing) => {
                            term_digests.extend(existing.growth_term_digests.iter().cloned());
                            false
                        }
                        None => self.index_state.state(content_id)?.is_none(),
                    };
                    {
                        let counts = slot.counts.lock().unwrap();
                        if let Some(state) = counts.as_ref() {
                            for term in default_keyword_tokens(text) {
                                if !state.accumulator.counts_contains_term(&term) {
                                    term_digests.insert(crate::content::content_digest_bytes(
                                        term.as_bytes(),
                                    ));
                                }
                            }
                        }
                    }
                    references.push((
                        PersistedCountsReference {
                            model_id: model_id.clone(),
                            model_version: model_version.clone(),
                            content_id: content_id.clone(),
                            revision: *revision,
                            digest: digest.clone(),
                            updated_at_secs: now_millis / 1000,
                            is_subsumed: false,
                            growth_term_digests: term_digests.iter().cloned().collect(),
                        },
                        slot_index,
                        term_digests,
                        counts_document,
                    ));
                }
            }
        }
        // Advance compact growth contributions before the durable commit; the
        // same hashes are written with the anchors, so reload is exact.
        let mut touched_slots: BTreeSet<usize> = BTreeSet::new();
        for (_, slot_index, term_digests, counts_document) in &references {
            let mut counts = self.slots[*slot_index].counts.lock().unwrap();
            if let Some(state) = counts.as_mut() {
                state
                    .growth_term_digests
                    .extend(term_digests.iter().cloned());
                if *counts_document {
                    state.document_count += 1;
                }
                state.vocab_anchor = state.vocab_anchor.max(
                    state.accumulator.counts_vocabulary_size() + state.growth_term_digests.len(),
                );
                touched_slots.insert(*slot_index);
            }
        }
        let mut anchor_rows: Vec<(String, String, usize, usize)> = Vec::new();
        for slot_index in &touched_slots {
            let slot = &self.slots[*slot_index];
            let (model_id, model_version) = {
                let handle = slot.handle.lock().unwrap();
                let provider = handle.provider();
                (
                    provider.model_id().to_string(),
                    provider.model_version().to_string(),
                )
            };
            let counts = slot.counts.lock().unwrap();
            if let Some(state) = counts.as_ref() {
                anchor_rows.push((
                    model_id,
                    model_version,
                    state.document_count,
                    state.vocab_anchor,
                ));
            }
        }
        let counts_store = &self.counts_store;
        let index_state = &self.index_state;
        let result = self
            .storage
            .transaction(persistence_kit::IsolationLevel::Serializable, &mut |txn| {
                let rows = txn.row_store();
                for (model_id, model_version, content_id) in &consumed_subsumed_references {
                    counts_store
                        .delete_reference_into(model_id, model_version, content_id, &rows)
                        .map_err(|error| persistence_kit::StorageError::BackendError {
                            underlying: format!("queue subsumed reference: {error:?}"),
                        })?;
                }
                for (reference, _, _, _) in &references {
                    counts_store
                        .upsert_reference_into(reference, &rows)
                        .map_err(|error| persistence_kit::StorageError::BackendError {
                            underlying: format!("queue counts reference: {error:?}"),
                        })?;
                }
                for (model_id, model_version, document_count, vocab_anchor) in &anchor_rows {
                    counts_store
                        .update_anchors_into(
                            model_id,
                            model_version,
                            *document_count,
                            *vocab_anchor,
                            &rows,
                        )
                        .map_err(|error| persistence_kit::StorageError::BackendError {
                            underlying: format!("queue counts anchors: {error:?}"),
                        })?;
                }
                for checkpoint in checkpoints {
                    index_state
                        .advance_into(checkpoint, &rows)
                        .map_err(|error| persistence_kit::StorageError::BackendError {
                            underlying: format!("queue checkpoint: {error:?}"),
                        })?;
                }
                Ok(())
            })
            .map_err(|error| CorpusKitError::StoreUnavailable(format!("{error:?}")));
        if let Err(transaction_error) = result {
            // The storage transaction is the authority even if a backend
            // reports an ambiguous commit error. Reload only on this rare
            // path; retaining rollback copies during every successful burst
            // would duplicate the estate-scale counts blobs in memory.
            self.counts_reload_required.store(true, Ordering::Release);
            if let Err(reload_error) = self.reload_counts_from_storage() {
                return Err(CorpusKitError::StoreUnavailable(format!(
                    "{transaction_error:?}; reload durable counts: {reload_error:?}"
                )));
            }
            self.counts_reload_required.store(false, Ordering::Release);
            return Err(transaction_error);
        }
        Ok(())
    }

    fn reload_counts_from_storage(&self) -> CorpusKitResult<()> {
        for slot in &self.slots {
            let Some(fresh_blob) = slot.fresh_basis_blob.as_ref() else {
                continue;
            };
            let (model_id, model_version) = {
                let handle = slot.handle.lock().unwrap();
                let provider = handle.provider();
                (
                    provider.model_id().to_string(),
                    provider.model_version().to_string(),
                )
            };
            let persisted = self.counts_store.load(&model_id, &model_version)?;
            let mut counts = slot.counts.lock().unwrap();
            let state = counts.as_ref().ok_or_else(|| {
                CorpusKitError::NotTrainable(format!(
                    "provider {model_id} has no retained counts accumulator"
                ))
            })?;
            let mut accumulator = state.accumulator.reconstruct_trainable_basis(fresh_blob)?;
            let document_count = if let Some(row) = persisted {
                accumulator.restore_counts(&row.counts)?;
                row.document_count
            } else {
                0
            };
            let mut growth_term_digests = BTreeSet::new();
            for reference in self.counts_store.references(&model_id, &model_version)? {
                // Already represented by the published base; retained only
                // until the delayed admission commits its checkpoint.
                if reference.is_subsumed {
                    continue;
                }
                growth_term_digests.extend(reference.growth_term_digests);
            }
            // The STORED anchors are the authority: they were committed in
            // the same transaction as each reference mutation, so a restarted
            // process holds exactly the anchors the live process held. The
            // rebuilt accumulator may legitimately differ in per-term folds
            // for revised identities (it resolves current canonical text);
            // its only behavioral consumer is the next training rebuild,
            // which re-reads the full corpus anyway.
            let (stored_docs, stored_vocab) = self
                .counts_store
                .load(&model_id, &model_version)?
                .map(|row| (row.document_count, row.vocab_size))
                .unwrap_or((
                    document_count,
                    accumulator.counts_vocabulary_size() + growth_term_digests.len(),
                ));
            *counts = Some(crate::corpus::CountsState {
                accumulator,
                document_count: stored_docs,
                vocab_anchor: stored_vocab,
                growth_term_digests,
            });
        }
        Ok(())
    }

    fn index_record(
        &self,
        record: &CorpusContentRecord,
        applied_cursor: Option<&str>,
        force: bool,
        now_millis: i64,
        slot_scope: SlotScope,
    ) -> CorpusKitResult<()> {
        if let Some(checkpoint) =
            self.prepare_index_record(record, applied_cursor, force, now_millis, slot_scope)?
        {
            self.commit_direct_index(record, &checkpoint, now_millis)?;
        }
        Ok(())
    }

    /// Produce every derived row and the final checkpoint, but leave the
    /// checkpoint uncommitted. The durable queue uses this seam to atomically
    /// publish batch-maintained counts with all corresponding checkpoints.
    fn prepare_index_record(
        &self,
        record: &CorpusContentRecord,
        applied_cursor: Option<&str>,
        force: bool,
        now_millis: i64,
        slot_scope: SlotScope,
    ) -> CorpusKitResult<Option<CorpusIndexState>> {
        // Idempotence anchor: a checkpoint covering this exact (revision,
        // digest, index_version) means the derived rows are complete —
        // replay writes NOTHING. `force` (reindex) bypasses deliberately.
        if !force {
            if let Some(existing) = self.index_state.state(&record.id)? {
                if existing.revision == record.revision
                    && existing.digest == record.digest
                    && existing.index_version == CONTENT_ENGINE_INDEX_VERSION
                {
                    return Ok(None);
                }
            }
        }
        self.register_claims(now_millis)?;
        if slot_scope == SlotScope::All {
            self.first_ingest_train_if_needed(now_millis)?;
        }

        let units = self.replace_units(record)?;

        for (key, text) in &units {
            self.inverted_index
                .index(key, &default_keyword_tokens(text), "")
                .map_err(|e| CorpusKitError::StoreUnavailable(format!("{e:?}")))?;
        }

        // Attached mode writes the binary (Hamming) row for the DEFAULT
        // slot only: every GLK binary reader probes the default model;
        // non-default binary rows would be unreachable weight. Standalone
        // keeps per-slot binary lanes.
        let mut rows: Vec<VectorPayloadInput> =
            Vec::with_capacity(units.len() * self.slots.len() * 2);
        let mut covered: Vec<(String, String, String)> = Vec::new();
        for (slot_index, slot) in self.slots.iter().enumerate() {
            if slot_scope == SlotScope::StatelessOnly && slot.fresh_basis_blob.is_some() {
                continue;
            }
            let digest = slot.basis_digest.lock().unwrap().clone();
            // A trainable slot with no trained basis cannot embed; the
            // train + backfill phases cover it.
            if slot.fresh_basis_blob.is_some() && digest.is_empty() {
                continue;
            }
            let write_binary =
                slot_index == 0 || self.configuration.mode() == CorpusOperatingMode::Standalone;
            let handle = slot.handle.lock().unwrap();
            let provider = handle.provider();
            for (key, text) in &units {
                let (engram, floats) = provider
                    .embed_pair(text)
                    .map_err(|e| CorpusKitError::EmbeddingFailed(format!("{e:?}")))?;
                if write_binary {
                    rows.push(VectorPayloadInput {
                        item_id: key.clone(),
                        vector_index: 0,
                        payload: VectorPayload::from_engram(&engram),
                        model_id: provider.model_id().to_string(),
                        model_version: provider.model_version().to_string(),
                        filed_at_unix_secs: now_millis,
                    });
                }
                if !floats.is_empty() {
                    rows.push(VectorPayloadInput {
                        item_id: key.clone(),
                        vector_index: 1,
                        payload: VectorPayload::from_f32(&floats),
                        model_id: provider.model_id().to_string(),
                        model_version: provider.model_version().to_string(),
                        filed_at_unix_secs: now_millis,
                    });
                }
            }
            covered.push((record.id.clone(), provider.model_id().to_string(), digest));
        }
        if !rows.is_empty() {
            self.vector_store
                .add_payloads(&rows)
                .map_err(|e| CorpusKitError::StoreUnavailable(format!("{e:?}")))?;
        }
        // Coverage rows AFTER the vector rows are durable — coverage never
        // overstates the vectors table (and the checkpoint below never
        // overstates coverage).
        self.coverage_store.mark_covered(&covered, now_millis)?;

        // The caller publishes this checkpoint LAST.
        Ok(Some(CorpusIndexState {
            content_id: record.id.clone(),
            revision: record.revision,
            digest: record.digest.clone(),
            index_version: CONTENT_ENGINE_INDEX_VERSION,
            applied_cursor: applied_cursor.map(str::to_string),
            updated_at_millis: now_millis,
        }))
    }

    /// Compute the record's index units under the configured policy,
    /// replacing durable passage rows and deleting STALE derived keys by
    /// exact key. Returns (key, text) pairs.
    fn replace_units(
        &self,
        record: &CorpusContentRecord,
    ) -> CorpusKitResult<Vec<(String, String)>> {
        let mut stale_keys = self.unit_keys(&record.id)?;

        let units: Vec<(String, String)> = match self.configuration.index_unit() {
            CorpusIndexUnitPolicy::WholeContent => {
                vec![(record.id.clone(), record.text.clone())]
            }
            #[cfg(feature = "standalone-passages")]
            CorpusIndexUnitPolicy::TokenWindows {
                window_tokens,
                overlap_tokens,
            } => {
                let ranges = passage_ranges(&record.text, window_tokens, overlap_tokens);
                let bytes = record.text.as_bytes();
                let units: Vec<(String, String)> = ranges
                    .iter()
                    .map(|(start, length)| {
                        let key = passage_key(&record.id, record.revision, *start, *length);
                        let text =
                            String::from_utf8_lossy(&bytes[*start..*start + *length]).into_owned();
                        (key, text)
                    })
                    .collect();
                // Replace the durable passage-range rows for this content.
                self.storage
                    .row_store()
                    .delete(
                        "corpus_passages",
                        &StoragePredicate::Eq(
                            Column::new("corpus_passages", "content_id"),
                            TypedValue::Text(record.id.clone()),
                        ),
                    )
                    .map_err(|e| CorpusKitError::StoreUnavailable(format!("{e:?}")))?;
                for ((key, _), (start, length)) in units.iter().zip(ranges.iter()) {
                    let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
                    values.insert("passage_id".into(), TypedValue::Text(key.clone()));
                    values.insert("content_id".into(), TypedValue::Text(record.id.clone()));
                    values.insert("revision".into(), TypedValue::Int(record.revision));
                    values.insert("digest".into(), TypedValue::Text(record.digest.clone()));
                    values.insert("utf8_start".into(), TypedValue::Int(*start as i64));
                    values.insert("utf8_length".into(), TypedValue::Int(*length as i64));
                    values.insert(
                        "policy_fingerprint".into(),
                        TypedValue::Text(crate::index_configuration_store::policy_fingerprint(
                            self.configuration.index_unit(),
                        )),
                    );
                    self.storage
                        .row_store()
                        .insert("corpus_passages", values)
                        .map_err(|e| CorpusKitError::StoreUnavailable(format!("{e:?}")))?;
                }
                units
            }
        };

        let fresh: BTreeSet<&String> = units.iter().map(|(k, _)| k).collect();
        stale_keys.retain(|k| !fresh.contains(k));
        if !stale_keys.is_empty() {
            self.delete_derived_rows(&stale_keys)?;
        }
        Ok(units)
    }

    /// Every derived-row key currently attributable to `id`.
    fn unit_keys(&self, id: &str) -> CorpusKitResult<BTreeSet<String>> {
        let mut keys: BTreeSet<String> = BTreeSet::new();
        keys.insert(id.to_string());
        #[cfg(feature = "standalone-passages")]
        if matches!(
            self.configuration.index_unit(),
            CorpusIndexUnitPolicy::TokenWindows { .. }
        ) {
            let rows = self
                .storage
                .row_store()
                .query(
                    "corpus_passages",
                    Some(&StoragePredicate::Eq(
                        Column::new("corpus_passages", "content_id"),
                        TypedValue::Text(id.to_string()),
                    )),
                    &[],
                    None,
                    None,
                )
                .map_err(|e| CorpusKitError::StoreUnavailable(format!("{e:?}")))?;
            for row in &rows {
                if let Some(TypedValue::Text(passage_id)) = row.get("passage_id") {
                    keys.insert(passage_id.clone());
                }
            }
        }
        Ok(keys)
    }

    /// Delete BM25 postings and vector rows for the given unit keys —
    /// exact-key scoped, never model-wide.
    /// CLAIM-AWARE derived-row delete: a key whose (model, lane)
    /// representation family is also claimed by another retained consumer
    /// is NOT deleted — the row may serve that claimant's exact
    /// representation. The engine only removes what it exclusively owns.
    fn delete_derived_rows(&self, unit_keys: &BTreeSet<String>) -> CorpusKitResult<()> {
        let shared = self.shared_representation_families()?;
        let model_ids: Vec<String> = self.slots.iter().map(|s| s.model_id.clone()).collect();
        let mut vector_keys: Vec<VectorExactKey> = Vec::new();
        for key in unit_keys {
            self.inverted_index
                .remove(key)
                .map_err(|e| CorpusKitError::StoreUnavailable(format!("{e:?}")))?;
            for model_id in &model_ids {
                for lane in [0u32, 1u32] {
                    if shared.contains(&format!("{model_id}|{lane}")) {
                        continue;
                    }
                    vector_keys.push(VectorExactKey::new(key.clone(), lane, model_id.clone()));
                }
            }
        }
        self.vector_store
            .delete_vectors(&vector_keys)
            .map_err(|e| CorpusKitError::StoreUnavailable(format!("{e:?}")))?;
        Ok(())
    }

    /// Representation families (model_id|lane) this engine's slots write
    /// that at least one OTHER consumer also claims. Rows in these
    /// families are never deleted by the engine's remove/destroy paths.
    fn shared_representation_families(&self) -> CorpusKitResult<std::collections::HashSet<String>> {
        let mut out = std::collections::HashSet::new();
        for slot in &self.slots {
            let (model_id, model_version) = {
                let handle = slot.handle.lock().unwrap();
                let p = handle.provider();
                (p.model_id().to_string(), p.model_version().to_string())
            };
            for lane in [0u32, 1u32] {
                let claimants = self
                    .claims
                    .claimants(&VectorRepresentationKey::new(
                        model_id.clone(),
                        model_version.clone(),
                        lane,
                    ))
                    .map_err(|e| CorpusKitError::StoreUnavailable(format!("{e:?}")))?;
                if claimants.iter().any(|c| c != CLAIMS_CONSUMER) {
                    out.insert(format!("{model_id}|{lane}"));
                }
            }
        }
        Ok(out)
    }

    /// Clear EVERYTHING derived for `id` (the remove path).
    fn clear_derived_state(&self, id: &str) -> CorpusKitResult<()> {
        let keys = self.unit_keys(id)?;
        self.delete_derived_rows(&keys)?;
        self.coverage_store.clear(id)?;
        #[cfg(feature = "standalone-passages")]
        if matches!(
            self.configuration.index_unit(),
            CorpusIndexUnitPolicy::TokenWindows { .. }
        ) {
            self.storage
                .row_store()
                .delete(
                    "corpus_passages",
                    &StoragePredicate::Eq(
                        Column::new("corpus_passages", "content_id"),
                        TypedValue::Text(id.to_string()),
                    ),
                )
                .map_err(|e| CorpusKitError::StoreUnavailable(format!("{e:?}")))?;
        }
        self.index_state.clear(id)?;
        Ok(())
    }

    fn advance_feed_cursor(&self, cursor: &str, now_millis: i64) -> CorpusKitResult<()> {
        self.index_state.advance(&CorpusIndexState {
            content_id: FEED_CURSOR_ROW_ID.to_string(),
            revision: 0,
            digest: String::new(),
            index_version: CONTENT_ENGINE_INDEX_VERSION,
            applied_cursor: Some(cursor.to_string()),
            updated_at_millis: now_millis,
        })
    }

    /// The last applied feed cursor.
    pub fn applied_feed_cursor(&self) -> CorpusKitResult<Option<String>> {
        Ok(self
            .index_state
            .state(FEED_CURSOR_ROW_ID)?
            .and_then(|s| s.applied_cursor))
    }

    /// Content IDs with a live checkpoint.
    pub fn indexed_content_ids(&self) -> CorpusKitResult<Vec<CorpusContentId>> {
        Ok(self
            .index_state
            .all_states()?
            .into_iter()
            .map(|s| s.content_id)
            .filter(|id| id != FEED_CURSOR_ROW_ID)
            .collect())
    }

    // ── Training ─────────────────────────────────────────────────────────

    /// First-ingest auto-train (standalone UX): a trainable slot with no
    /// persisted basis trains ONCE — via the BOUNDED streaming trainer,
    /// never by materializing the corpus.
    fn first_ingest_train_if_needed(&self, now_millis: i64) -> CorpusKitResult<()> {
        let any_untrained = self.slots.iter().any(|slot| {
            slot.fresh_basis_blob.is_some() && slot.basis_digest.lock().unwrap().is_empty()
        });
        if any_untrained {
            self.train_trainable_slots(now_millis, false)?;
        }
        Ok(())
    }

    /// Minimum content-count threshold for a "stable" auto-trained basis.
    ///
    /// Below this count a 2× corpus growth triggers a growth retrain; above
    /// it only an explicit `reindex` retrains (the "stable" contract). Mirrors
    /// `Corpus::PER_DOC_AUTO_RETRAIN_STABLE_CHUNK_THRESHOLD` (fix-basis
    /// d7011ae2) and Swift `CorpusContentEngine.perDocAutoRetrainStableChunkThreshold`.
    pub const PER_DOC_AUTO_RETRAIN_STABLE_CHUNK_THRESHOLD: usize = 50;

    /// Three-state auto-train for the batch drain path (Kinsta-fix): prevents
    /// a degenerate rank-1 basis from freezing during early corpus growth.
    ///
    /// Called from `drain_content_with_queue` ONCE per batch, before per-document
    /// work. NEVER called from per-document paths (`prepare_index_record`); doing
    /// so would fire spurious growth retrains that break counts idempotence.
    ///
    /// States:
    ///   (1) First-ingest: no persisted basis → train from scratch.
    ///   (2) Growth retrain: young basis (trained_chunk_count <
    ///       `PER_DOC_AUTO_RETRAIN_STABLE_CHUNK_THRESHOLD`) AND the INDEXED corpus
    ///       has grown to ≥ 2× trained_chunk_count → retrain from scratch. Stops
    ///       exponentially; at most ⌊log₂(50)⌋ ≈ 5 implicit retrains before stable.
    ///   (3) Fold-in: stable basis or indexed corpus hasn't grown 2× → no retrain.
    ///
    /// IMPORTANT — indexed count, not source count: the growth ratio compares the
    /// basis (trained on `trained_chunk_count` INDEXED docs) against the ALREADY
    /// CHECKPOINTED doc count from `index_state`. Using `source.active_content_ids()`
    /// would include docs queued but not yet indexed in the current batch. Those
    /// docs are about to be indexed by the drain loop below. If they triggered a
    /// growth retrain, `train_trainable_slots` would include them in the training
    /// corpus and create subsumed references for them, which `commit_queue_batch`
    /// would then delete instead of creating the normal non-subsumed delta references.
    /// Using the indexed count prevents this double-counting. The same doc count
    /// is fetched lazily and shared across all trainable slots (one DB read per
    /// batch even with N trainable models).
    ///
    /// `train_trainable_slots` is called with `force: true` for cases (1) and (2)
    /// — the non-forced path skips providers whose basis digest is already set.
    pub(crate) fn batch_train_if_needed(&self, now_millis: i64) -> CorpusKitResult<()> {
        let stable_threshold = Self::PER_DOC_AUTO_RETRAIN_STABLE_CHUNK_THRESHOLD;
        let mut should_retrain = false;
        // Indexed-doc count: CHECKPOINTED documents only. Source docs not yet
        // indexed (queued but not checkpointed) are excluded on purpose — see
        // the function doc-comment above.
        let mut cached_indexed_count: Option<usize> = None;

        for slot in &self.slots {
            if slot.fresh_basis_blob.is_none() {
                continue;
            }
            let digest = slot
                .basis_digest
                .lock()
                .map_err(|_| {
                    CorpusKitError::StoreUnavailable("basis digest mutex poisoned".into())
                })?
                .clone();
            // Case (1): no persisted basis — first ingest.
            if digest.is_empty() {
                should_retrain = true;
                break;
            }
            // Persisted basis exists — check if it is young enough to retrain.
            let model_id = slot.model_id.clone();
            let model_version = slot
                .handle
                .lock()
                .map_err(|_| {
                    CorpusKitError::StoreUnavailable("provider handle mutex poisoned".into())
                })?
                .provider()
                .model_version()
                .to_string();
            let Some(basis) = self.basis_store.load(&model_id, &model_version)? else {
                continue;
            };
            if basis.trained_chunk_count >= stable_threshold {
                continue; // Case (3): stable basis — fold-in only.
            }
            // Case (2): young basis — check 2× growth against INDEXED count.
            let indexed_count = if let Some(count) = cached_indexed_count {
                count
            } else {
                let count = self
                    .index_state
                    .all_states()?
                    .into_iter()
                    .filter(|s| s.content_id != FEED_CURSOR_ROW_ID)
                    .count();
                cached_indexed_count = Some(count);
                count
            };
            if indexed_count >= basis.trained_chunk_count * 2 {
                should_retrain = true;
                break;
            }
            // Indexed corpus hasn't grown 2× yet — fold-in only.
        }

        if should_retrain {
            // force: true required for cases (1) and (2) — for case (2) the
            // basis digest is non-empty; the non-forced path would skip it.
            self.train_trainable_slots(now_millis, true)?;
        }
        Ok(())
    }

    /// Training page size — bounds transient text memory to one page; the
    /// accumulator state is vocabulary-scale regardless, and the trained
    /// basis is byte-identical for every page size.
    pub const TRAINING_PAGE_SIZE: usize = 2_000;

    /// Test seam: throw AFTER the named provider's atomic commit.
    pub fn arm_train_fault_after(&self, model_id: Option<&str>) {
        *self.train_fault_after_model.lock().unwrap() = model_id.map(str::to_string);
    }
    /// Test seam: throw BEFORE the named provider's commit.
    pub fn arm_train_fault_before_commit(&self, model_id: Option<&str>) {
        *self.train_fault_before_commit_model.lock().unwrap() = model_id.map(str::to_string);
    }
    /// Test seam: backfill fault hook.
    pub fn arm_backfill_fault_hook(&self, hook: Option<ContentBackfillFaultHook>) {
        *self.backfill_fault_hook.lock().unwrap() = hook;
    }

    /// Conservative provider-level training admission. The per-worker memory
    /// envelope mirrors the migration capacity gate (2 GiB fixed + 320 KiB per
    /// active content row). At least one worker is always retained, preserving
    /// the former serial operability when memory is constrained.
    fn provider_training_parallelism(content_count: usize, provider_count: usize) -> usize {
        if provider_count == 0 {
            return 1;
        }
        let explicit = std::env::var("MOOT_PROVIDER_TRAINING_MEMORY_BUDGET_BYTES")
            .ok()
            .and_then(|raw| raw.parse::<u64>().ok())
            .filter(|value| *value > 0)
            .or_else(|| {
                std::env::var("MOOT_MIGRATION_MEMORY_BUDGET_BYTES")
                    .ok()
                    .and_then(|raw| raw.parse::<u64>().ok())
                    .filter(|value| *value > 0)
            });
        let budget = explicit
            .or_else(physical_memory_bytes)
            .unwrap_or(0)
            .saturating_mul(if explicit.is_some() { 1 } else { 4 })
            / if explicit.is_some() { 1 } else { 5 };
        let cpu_workers = std::thread::available_parallelism()
            .map(|count| count.get())
            .unwrap_or(1);
        Self::provider_training_parallelism_with_budget(
            content_count,
            provider_count,
            budget,
            cpu_workers,
        )
    }

    fn provider_training_parallelism_with_budget(
        content_count: usize,
        provider_count: usize,
        budget: u64,
        cpu_workers: usize,
    ) -> usize {
        if provider_count == 0 {
            return 1;
        }
        let per_worker = 2u64
            .saturating_mul(1_024 * 1_024 * 1_024)
            .saturating_add((content_count as u64).saturating_mul(320 * 1_024));
        let memory_workers = ((budget / per_worker.max(1)) as usize).max(1);
        provider_count.min(cpu_workers).min(memory_workers).max(1)
    }

    fn prepare_provider_training(
        &self,
        job: ProviderTrainingJob,
        all_ids: &[CorpusContentId],
        indexed_states: &BTreeMap<String, CorpusIndexState>,
        now_millis: i64,
    ) -> CorpusKitResult<PreparedProviderTraining> {
        let slot = &self.slots[job.slot_index];
        let (mut fresh, mut counts_accumulator) = {
            let counts = slot.counts.lock().map_err(|_| {
                CorpusKitError::StoreUnavailable("provider counts mutex poisoned".into())
            })?;
            let state = counts.as_ref().ok_or_else(|| {
                CorpusKitError::NotTrainable(format!(
                    "provider {} has no retained counts accumulator",
                    job.model_id
                ))
            })?;
            (
                state
                    .accumulator
                    .reconstruct_trainable_basis(&job.fresh_basis_blob)?,
                state
                    .accumulator
                    .reconstruct_trainable_basis(&job.fresh_basis_blob)?,
            )
        };

        let mut subsumed_references = Vec::new();
        let mut document_count = 0usize;
        let mut cursor = 0usize;
        while cursor < all_ids.len() {
            let end = (cursor + Self::TRAINING_PAGE_SIZE).min(all_ids.len());
            let mut texts = Vec::with_capacity(end - cursor);
            for id in &all_ids[cursor..end] {
                if let Some(record) = self.source.record(id)? {
                    let indexed = indexed_states.get(&record.id);
                    if indexed.map_or(true, |state| {
                        state.revision != record.revision
                            || state.digest != record.digest
                            || state.index_version != CONTENT_ENGINE_INDEX_VERSION
                    }) {
                        subsumed_references.push(PersistedCountsReference {
                            model_id: job.model_id.clone(),
                            model_version: job.model_version.clone(),
                            content_id: record.id.clone(),
                            revision: record.revision,
                            digest: record.digest.clone(),
                            updated_at_secs: now_millis / 1000,
                            is_subsumed: true,
                            growth_term_digests: Vec::new(),
                        });
                    }
                    texts.push(record.text);
                }
            }
            let refs: Vec<&str> = texts.iter().map(String::as_str).collect();
            fresh.accumulate_training(&refs);
            for text in &texts {
                counts_accumulator.add_to_counts(text);
            }
            document_count += texts.len();
            cursor = end;
        }
        fresh.finalize_training();

        let basis_blob = fresh.serialize_basis();
        let basis_digest = crate::content::content_digest_bytes(&basis_blob);
        Ok(PreparedProviderTraining {
            basis_row: PersistedBasis {
                model_id: job.model_id.clone(),
                model_version: job.model_version.clone(),
                basis: basis_blob,
                trained_at_secs: now_millis / 1000,
                trained_chunk_count: document_count,
            },
            counts_row: PersistedCounts {
                model_id: job.model_id.clone(),
                model_version: job.model_version.clone(),
                counts: counts_accumulator.serialize_counts(),
                document_count,
                vocab_size: counts_accumulator.counts_vocabulary_size(),
                updated_at_secs: now_millis / 1000,
            },
            job,
            provider: fresh,
            counts_accumulator,
            basis_digest,
            subsumed_references,
        })
    }

    /// Stream-train every trainable slot that lacks a CURRENT basis (or
    /// every trainable slot when `force`) with bounded provider-level parallel
    /// compute and deterministic configured-slot publication.
    ///
    /// Crash safety per provider: accumulation/finalization are in-memory
    /// only — a crash loses nothing durable; the resumed run retrains that
    /// provider from zero. The commit is ONE atomic transaction writing
    /// the basis AND its training-corpus counts (the metadata pair that
    /// must agree). Already-trained providers are skipped on resume.
    ///
    /// Bounded: texts stream in pages of `TRAINING_PAGE_SIZE`;
    /// per-provider accumulator state is vocabulary-scale.
    ///
    /// Returns model_id → basis digest for every trainable slot.
    pub fn train_trainable_slots(
        &self,
        now_millis: i64,
        force: bool,
    ) -> CorpusKitResult<std::collections::BTreeMap<String, String>> {
        // Publication replaces the base snapshot and deletes only reference
        // deltas represented by that snapshot. Exclude admission while the
        // snapshot is accumulated and published so a post-snapshot reference
        // cannot be deleted as though it had been subsumed.
        let _commit_guard = self
            .counts_commit_lock
            .lock()
            .map_err(|_| CorpusKitError::StoreUnavailable("counts commit lock poisoned".into()))?;
        let indexed_states: BTreeMap<String, CorpusIndexState> = self
            .index_state
            .all_states()?
            .into_iter()
            .filter(|state| state.content_id != FEED_CURSOR_ROW_ID)
            .map(|state| (state.content_id.clone(), state))
            .collect();
        let mut digests = BTreeMap::new();
        let mut jobs = Vec::new();
        for (slot_index, slot) in self.slots.iter().enumerate() {
            let Some(blob) = &slot.fresh_basis_blob else {
                continue;
            };
            let model_id = slot.model_id.clone();
            let digest = slot
                .basis_digest
                .lock()
                .map_err(|_| {
                    CorpusKitError::StoreUnavailable("basis digest mutex poisoned".into())
                })?
                .clone();
            if !force && !digest.is_empty() {
                digests.insert(model_id, digest);
                continue;
            }
            let model_version = slot
                .handle
                .lock()
                .map_err(|_| {
                    CorpusKitError::StoreUnavailable("provider handle mutex poisoned".into())
                })?
                .provider()
                .model_version()
                .to_string();
            jobs.push(ProviderTrainingJob {
                slot_index,
                model_id,
                model_version,
                fresh_basis_blob: blob.clone(),
            });
        }

        let all_ids = self.source.active_content_ids()?;
        if all_ids.is_empty() {
            return Ok(digests);
        }
        let cap = Self::provider_training_parallelism(all_ids.len(), jobs.len());
        for job_batch in jobs.chunks(cap) {
            let prepared: Vec<PreparedProviderTraining> = std::thread::scope(|scope| {
                let handles: Vec<_> = job_batch
                    .iter()
                    .map(|job| {
                        let owned_job = ProviderTrainingJob {
                            slot_index: job.slot_index,
                            model_id: job.model_id.clone(),
                            model_version: job.model_version.clone(),
                            fresh_basis_blob: job.fresh_basis_blob.clone(),
                        };
                        scope.spawn(|| {
                            self.prepare_provider_training(
                                owned_job,
                                &all_ids,
                                &indexed_states,
                                now_millis,
                            )
                        })
                    })
                    .collect();
                handles
                    .into_iter()
                    .map(|handle| {
                        handle.join().map_err(|_| {
                            CorpusKitError::StoreUnavailable(
                                "provider training worker panicked".into(),
                            )
                        })?
                    })
                    .collect::<CorpusKitResult<Vec<_>>>()
            })?;

            for result in prepared {
                let model_id = result.job.model_id.clone();
                {
                    let mut seam = self.train_fault_before_commit_model.lock().unwrap();
                    if seam.as_deref() == Some(model_id.as_str()) {
                        *seam = None;
                        return Err(CorpusKitError::InvalidConfiguration(format!(
                            "injected training fault before commit: {model_id}"
                        )));
                    }
                }

                let basis_store = &self.basis_store;
                let counts_store = &self.counts_store;
                self.storage
                    .transaction(persistence_kit::IsolationLevel::Serializable, &mut |txn| {
                        let rows = txn.row_store();
                        basis_store
                            .upsert_into(&result.basis_row, &rows)
                            .map_err(|e| persistence_kit::StorageError::BackendError {
                                underlying: format!("{e:?}"),
                            })?;
                        counts_store
                            .upsert_into(&result.counts_row, &rows)
                            .map_err(|e| persistence_kit::StorageError::BackendError {
                                underlying: format!("{e:?}"),
                            })?;
                        counts_store
                            .delete_references_into(
                                &result.job.model_id,
                                &result.job.model_version,
                                &rows,
                            )
                            .map_err(|e| persistence_kit::StorageError::BackendError {
                                underlying: format!("{e:?}"),
                            })?;
                        for reference in &result.subsumed_references {
                            counts_store
                                .upsert_reference_into(reference, &rows)
                                .map_err(|e| persistence_kit::StorageError::BackendError {
                                    underlying: format!("{e:?}"),
                                })?;
                        }
                        Ok(())
                    })
                    .map_err(|e| CorpusKitError::StoreUnavailable(format!("{e:?}")))?;

                let slot = &self.slots[result.job.slot_index];
                {
                    let mut handle = slot.handle.lock().unwrap();
                    *handle = crate::corpus::ProviderHandle::Trainable(result.provider);
                }
                *slot.basis_digest.lock().unwrap() = result.basis_digest.clone();
                {
                    let mut counts = slot.counts.lock().unwrap();
                    *counts = Some(crate::corpus::CountsState {
                        accumulator: result.counts_accumulator,
                        document_count: result.counts_row.document_count,
                        vocab_anchor: result.counts_row.vocab_size,
                        growth_term_digests: BTreeSet::new(),
                    });
                }
                digests.insert(model_id.clone(), result.basis_digest);

                {
                    let mut seam = self.train_fault_after_model.lock().unwrap();
                    if seam.as_deref() == Some(model_id.as_str()) {
                        *seam = None;
                        return Err(CorpusKitError::InvalidConfiguration(format!(
                            "injected training fault after commit: {model_id}"
                        )));
                    }
                }
            }
        }
        Ok(digests)
    }

    /// Backfill MISSING provider representations (trainable AND stateless
    /// slots alike — an upgrade can add either), driven by the coverage
    /// table — writes ONLY what is absent under each slot's CURRENT basis
    /// digest. Never touches BM25, never folds counts, never rewrites
    /// covered providers' rows. Per batch: vector rows first, coverage
    /// rows second — a crash leaves coverage LAGGING the durable vectors,
    /// never ahead. Mirrors Swift `backfillProviderCoverage`.
    pub fn backfill_provider_coverage(
        &self,
        now_millis: i64,
        batch_size: usize,
    ) -> CorpusKitResult<usize> {
        let targets: Vec<(usize, String, String)> = self
            .slots
            .iter()
            .enumerate()
            .filter_map(|(index, slot)| {
                let digest = slot.basis_digest.lock().unwrap().clone();
                if digest.is_empty() {
                    return None;
                }
                Some((index, slot.model_id.clone(), digest))
            })
            .collect();
        if targets.is_empty() {
            return Ok(0);
        }
        if !matches!(
            self.configuration.index_unit(),
            CorpusIndexUnitPolicy::WholeContent
        ) {
            return Err(CorpusKitError::InvalidConfiguration(
                "backfill_provider_coverage supports the wholeContent index unit                  (the mandatory attached policy); passage engines reindex instead"
                    .into(),
            ));
        }
        self.register_claims(now_millis)?;

        let indexed: std::collections::HashSet<String> =
            self.indexed_content_ids()?.into_iter().collect();
        let mut missing_by_slot: std::collections::HashMap<
            usize,
            std::collections::HashSet<String>,
        > = std::collections::HashMap::new();
        for (index, model_id, digest) in &targets {
            let covered = self.coverage_store.covered_content_ids(model_id, digest)?;
            missing_by_slot.insert(*index, indexed.difference(&covered).cloned().collect());
        }
        let mut affected: Vec<String> = missing_by_slot
            .values()
            .flat_map(|set| set.iter().cloned())
            .collect::<std::collections::HashSet<_>>()
            .into_iter()
            .collect();
        affected.sort();

        let guards: Vec<_> = targets
            .iter()
            .map(|(index, _, _)| {
                self.slots[*index]
                    .handle
                    .lock()
                    .map_err(|_| CorpusKitError::StoreUnavailable("provider lock poisoned".into()))
            })
            .collect::<Result<Vec<_>, _>>()?;
        let providers: Vec<&dyn EmbeddingProvider> =
            guards.iter().map(|guard| guard.provider()).collect();
        let metadata: Vec<(usize, String, String, String, bool)> = targets
            .iter()
            .zip(providers.iter())
            .map(|((index, model_id, digest), provider)| {
                (
                    *index,
                    model_id.clone(),
                    provider.model_version().to_string(),
                    digest.clone(),
                    *index == 0 || self.configuration.mode() == CorpusOperatingMode::Standalone,
                )
            })
            .collect();
        let cap = self.embed_concurrency_cap();
        let mut written = 0usize;
        for (batch_index, chunk) in affected.chunks(batch_size.max(1)).enumerate() {
            let mut records = Vec::with_capacity(chunk.len());
            for id in chunk {
                if let Some(record) = self.source.record(id)? {
                    records.push(record);
                }
            }
            let slice_len = ((records.len() + cap - 1) / cap).max(1);
            let providers_ref = &providers;
            let metadata_ref = &metadata;
            let missing_ref = &missing_by_slot;
            let prepared: Vec<(Vec<VectorPayloadInput>, Vec<(String, String, String)>)> =
                std::thread::scope(|scope| -> CorpusKitResult<Vec<_>> {
                    let handles: Vec<_> = records
                        .chunks(slice_len)
                        .map(|slice| {
                            scope.spawn(move || -> CorpusKitResult<Vec<_>> {
                                let mut output = Vec::with_capacity(slice.len());
                                for record in slice {
                                    let mut rows = Vec::new();
                                    let mut covered = Vec::new();
                                    for (provider, meta) in
                                        providers_ref.iter().zip(metadata_ref.iter())
                                    {
                                        if !missing_ref
                                            .get(&meta.0)
                                            .map(|set| set.contains(&record.id))
                                            .unwrap_or(false)
                                        {
                                            continue;
                                        }
                                        let (engram, floats) =
                                            provider.embed_pair(&record.text).map_err(|error| {
                                                CorpusKitError::EmbeddingFailed(format!(
                                                    "{error:?}"
                                                ))
                                            })?;
                                        if meta.4 {
                                            rows.push(VectorPayloadInput {
                                                item_id: record.id.clone(),
                                                vector_index: 0,
                                                payload: VectorPayload::from_engram(&engram),
                                                model_id: meta.1.clone(),
                                                model_version: meta.2.clone(),
                                                filed_at_unix_secs: now_millis,
                                            });
                                        }
                                        if !floats.is_empty() {
                                            rows.push(VectorPayloadInput {
                                                item_id: record.id.clone(),
                                                vector_index: 1,
                                                payload: VectorPayload::from_f32(&floats),
                                                model_id: meta.1.clone(),
                                                model_version: meta.2.clone(),
                                                filed_at_unix_secs: now_millis,
                                            });
                                        }
                                        covered.push((
                                            record.id.clone(),
                                            meta.1.clone(),
                                            meta.3.clone(),
                                        ));
                                    }
                                    output.push((rows, covered));
                                }
                                Ok(output)
                            })
                        })
                        .collect();
                    let mut output = Vec::with_capacity(records.len());
                    for handle in handles {
                        output.extend(handle.join().expect("coverage worker panicked")?);
                    }
                    Ok(output)
                })?;
            let rows: Vec<_> = prepared
                .iter()
                .flat_map(|item| item.0.iter().cloned())
                .collect();
            let covered: Vec<_> = prepared
                .iter()
                .flat_map(|item| item.1.iter().cloned())
                .collect();
            if !rows.is_empty() {
                self.vector_store
                    .add_payloads(&rows)
                    .map_err(|e| CorpusKitError::StoreUnavailable(format!("{e:?}")))?;
            }
            if let Some(hook) = self.backfill_fault_hook.lock().unwrap().as_ref() {
                hook("afterVectors", batch_index).map_err(CorpusKitError::InvalidConfiguration)?;
            }
            self.coverage_store.mark_covered(&covered, now_millis)?;
            if let Some(hook) = self.backfill_fault_hook.lock().unwrap().as_ref() {
                hook("afterCoverage", batch_index).map_err(CorpusKitError::InvalidConfiguration)?;
            }
            written += covered.len();
        }
        drop(guards);
        Ok(written)
    }

    /// Coverage count for one held slot's model under its CURRENT basis
    /// digest — the verification-gate read.
    pub fn covered_count(&self, model_id: &str) -> CorpusKitResult<Option<usize>> {
        let Some(slot) = self.slots.iter().find(|s| s.model_id == model_id) else {
            return Ok(None);
        };
        let digest = slot.basis_digest.lock().unwrap().clone();
        Ok(Some(self.coverage_store.covered_count(model_id, &digest)?))
    }

    /// Every held slot's (model_id, basis_digest) in slot order.
    pub fn provider_generations(&self) -> Vec<(String, String)> {
        self.slots
            .iter()
            .map(|slot| {
                (
                    slot.model_id.clone(),
                    slot.basis_digest.lock().unwrap().clone(),
                )
            })
            .collect()
    }

    /// The configuration fingerprint for a WIRING (mode + model configs)
    /// WITHOUT constructing an engine — the gate/upgrade comparison input.
    /// MUST byte-match `configuration_fingerprint()` for the same wiring
    /// and the Swift twin's static `configurationFingerprint(mode:models:)`.
    pub fn configuration_fingerprint_for(
        mode: CorpusOperatingMode,
        models: &[EmbeddingModelConfig],
    ) -> String {
        let parts: Vec<String> = models
            .iter()
            .map(|config| {
                let (model_id, model_version, trainable): (String, String, bool) = match config {
                    EmbeddingModelConfig::Deterministic => {
                        let p = crate::corpus::make_deterministic_provider();
                        let pref = &p as &dyn vectorkit::EmbeddingProvider;
                        (
                            pref.model_id().to_string(),
                            pref.model_version().to_string(),
                            false,
                        )
                    }
                    EmbeddingModelConfig::RandomIndexing { provider } => (
                        provider.model_id().to_string(),
                        provider.model_version().to_string(),
                        true,
                    ),
                    EmbeddingModelConfig::Ppmi { provider } => (
                        provider.model_id().to_string(),
                        provider.model_version().to_string(),
                        true,
                    ),
                    EmbeddingModelConfig::Lsa { provider } => (
                        provider.model_id().to_string(),
                        provider.model_version().to_string(),
                        true,
                    ),
                    EmbeddingModelConfig::Nmf { provider } => (
                        provider.model_id().to_string(),
                        provider.model_version().to_string(),
                        true,
                    ),
                    EmbeddingModelConfig::Fdc { provider } => (
                        provider.model_id().to_string(),
                        provider.model_version().to_string(),
                        false,
                    ),
                    // The named text models are constructed with these fixed
                    // identities in `Corpus::build_slot`; mirrored here so the
                    // fingerprint never needs the inference seam.
                    EmbeddingModelConfig::MiniLM { .. } => {
                        ("minilm-v6".to_string(), "1.0.0".to_string(), false)
                    }
                    EmbeddingModelConfig::MPNet { .. } => {
                        ("mpnet-base-v2".to_string(), "1.0.0".to_string(), false)
                    }
                    EmbeddingModelConfig::EmbeddingGemma { .. } => (
                        "embedding-gemma-300m".to_string(),
                        "1.0.0".to_string(),
                        false,
                    ),
                };
                format!(
                    "{model_id}@{model_version}{}",
                    if trainable { ":T" } else { "" }
                )
            })
            .collect();
        format!(
            "iv{}|{}|{}",
            CONTENT_ENGINE_INDEX_VERSION,
            if mode == CorpusOperatingMode::Attached {
                "attached"
            } else {
                "standalone"
            },
            parts.join("|")
        )
    }

    /// This engine's configuration fingerprint: mode, index version, and
    /// every slot's identity+trainability in slot order. Excludes basis
    /// digests (retraining the same configuration is not a configuration
    /// change). MUST byte-match the Swift twin for the same wiring.
    pub fn configuration_fingerprint(&self) -> String {
        let parts: Vec<String> = self
            .slots
            .iter()
            .map(|slot| {
                let handle = slot.handle.lock().unwrap();
                let p = handle.provider();
                format!(
                    "{}@{}{}",
                    p.model_id(),
                    p.model_version(),
                    if slot.fresh_basis_blob.is_some() {
                        ":T"
                    } else {
                        ""
                    }
                )
            })
            .collect();
        format!(
            "iv{}|{}|{}",
            CONTENT_ENGINE_INDEX_VERSION,
            if self.configuration.mode() == CorpusOperatingMode::Attached {
                "attached"
            } else {
                "standalone"
            },
            parts.join("|")
        )
    }

    /// Retrain every trainable slot from scratch and re-index every active
    /// content row (forced — a retrain changes the basis). Training is
    /// streamed (bounded); each provider's basis+counts commit is atomic.
    pub fn reindex(&self, now_millis: i64) -> CorpusKitResult<()> {
        self.train_trainable_slots(now_millis, true)?;
        // Bulk-write bracket (same idiom as reconcile_configured_providers
        // and the drain worker): defer the resident dense index for the
        // whole O(corpus) rewrite and publish ONCE. Without it every
        // per-record vector write rebuilt the resident MIH index — an
        // estate-scale retrain span measured in hours instead of minutes.
        self.vector_store
            .begin_deferred_index()
            .map_err(|error| CorpusKitError::StoreUnavailable(format!("{error:?}")))?;
        let ids = self.source.active_content_ids()?;
        if matches!(
            self.configuration.index_unit(),
            CorpusIndexUnitPolicy::WholeContent
        ) {
            // Bound both worker admission and prepared-result memory. Worker
            // joins preserve slice/input order; all durable writes remain on
            // this caller thread in BM25 -> vectors -> coverage -> checkpoint
            // order.
            for batch in ids.chunks(500) {
                self.index_whole_content_batch(batch, now_millis, SlotScope::All, true)?;
            }
        } else {
            // Standalone passage policies also replace durable range rows;
            // keep that mutation path serialized and policy-bound.
            for id in ids {
                match self.source.record(&id)? {
                    Some(record) => {
                        if let Some(checkpoint) = self.prepare_index_record(
                            &record,
                            None,
                            true,
                            now_millis,
                            SlotScope::All,
                        )? {
                            self.index_state.advance(&checkpoint)?;
                        }
                    }
                    None => self.clear_derived_state(&id)?,
                }
            }
        }
        self.vector_store
            .publish_resident_index()
            .map_err(|error| CorpusKitError::StoreUnavailable(format!("{error:?}")))?;
        self.provider_configuration_store
            .mark_current(&self.provider_generation_token(), now_millis)?;
        Ok(())
    }

    /// Persist the maintained counts snapshot — the BATCH-boundary write.
    /// Called by the drain worker at burst close; never once per record.
    pub fn persist_counts_snapshot(&self, now_millis: i64) -> CorpusKitResult<()> {
        let _commit_guard = self
            .counts_commit_lock
            .lock()
            .map_err(|_| CorpusKitError::StoreUnavailable("counts commit lock poisoned".into()))?;
        self.persist_counts(now_millis)
    }

    // ── Maintained counts ────────────────────────────────────────────────

    /// Direct-path last-write publication under the same durable-reference
    /// authority as the queue batch. Reference mutation, nondecreasing anchors,
    /// and the corresponding content checkpoint commit together.
    fn commit_direct_index(
        &self,
        record: &CorpusContentRecord,
        checkpoint: &CorpusIndexState,
        now_millis: i64,
    ) -> CorpusKitResult<()> {
        let _commit_guard = self
            .counts_commit_lock
            .lock()
            .map_err(|_| CorpusKitError::StoreUnavailable("counts commit lock poisoned".into()))?;
        // A prior failed commit whose reload ALSO failed leaves the in-memory
        // accumulator dirty; heal from storage before any new fold.
        if self.counts_reload_required.load(Ordering::Acquire) {
            self.reload_counts_from_storage()?;
            self.counts_reload_required.store(false, Ordering::Release);
        }
        let mut references: Vec<(PersistedCountsReference, usize, bool, BTreeSet<String>)> =
            Vec::new();
        let mut consumed_subsumed_references: Vec<(String, String, String)> = Vec::new();
        for (slot_index, slot) in self.slots.iter().enumerate() {
            if slot.counts.lock().unwrap().is_none() {
                continue;
            }
            let (model_id, model_version) = {
                let handle = slot.handle.lock().unwrap();
                let p = handle.provider();
                (p.model_id().to_string(), p.model_version().to_string())
            };
            let mut term_digests = BTreeSet::new();
            let counts_document = match self
                .counts_store
                .reference_for(&model_id, &model_version, &record.id)?
            {
                Some(existing) if existing.digest == record.digest => {
                    if existing.is_subsumed {
                        consumed_subsumed_references.push((
                            model_id.clone(),
                            model_version.clone(),
                            record.id.clone(),
                        ));
                    }
                    continue;
                }
                Some(existing) => {
                    term_digests.extend(existing.growth_term_digests);
                    false
                }
                None => self.index_state.state(&record.id)?.is_none(),
            };
            {
                let counts = slot.counts.lock().unwrap();
                if let Some(state) = counts.as_ref() {
                    for term in default_keyword_tokens(&record.text) {
                        if !state.accumulator.counts_contains_term(&term) {
                            term_digests
                                .insert(crate::content::content_digest_bytes(term.as_bytes()));
                        }
                    }
                }
            }
            references.push((
                PersistedCountsReference {
                    model_id,
                    model_version,
                    content_id: record.id.clone(),
                    revision: record.revision,
                    digest: record.digest.clone(),
                    updated_at_secs: now_millis / 1000,
                    is_subsumed: false,
                    growth_term_digests: term_digests.iter().cloned().collect(),
                },
                slot_index,
                counts_document,
                term_digests,
            ));
        }
        // Update the exact identity-scoped growth set first; the transaction
        // persists those same hashes with the resulting anchors.
        let mut anchor_rows: Vec<(String, String, usize, usize)> = Vec::new();
        for (reference, slot_index, counts_document, term_digests) in &references {
            let mut counts = self.slots[*slot_index].counts.lock().unwrap();
            if let Some(state) = counts.as_mut() {
                state
                    .growth_term_digests
                    .extend(term_digests.iter().cloned());
                if *counts_document {
                    state.document_count += 1;
                }
                state.vocab_anchor = state.vocab_anchor.max(
                    state.accumulator.counts_vocabulary_size() + state.growth_term_digests.len(),
                );
                anchor_rows.push((
                    reference.model_id.clone(),
                    reference.model_version.clone(),
                    state.document_count,
                    state.vocab_anchor,
                ));
            }
        }
        let counts_store = &self.counts_store;
        let index_state = &self.index_state;
        let result = self
            .storage
            .transaction(persistence_kit::IsolationLevel::Serializable, &mut |txn| {
                let rows = txn.row_store();
                for (model_id, model_version, content_id) in &consumed_subsumed_references {
                    counts_store
                        .delete_reference_into(model_id, model_version, content_id, &rows)
                        .map_err(|error| persistence_kit::StorageError::BackendError {
                            underlying: format!("direct subsumed reference: {error:?}"),
                        })?;
                }
                for (reference, _, _, _) in &references {
                    counts_store
                        .upsert_reference_into(reference, &rows)
                        .map_err(|error| persistence_kit::StorageError::BackendError {
                            underlying: format!("direct counts reference: {error:?}"),
                        })?;
                }
                for (model_id, model_version, document_count, vocab_anchor) in &anchor_rows {
                    counts_store
                        .update_anchors_into(
                            model_id,
                            model_version,
                            *document_count,
                            *vocab_anchor,
                            &rows,
                        )
                        .map_err(|error| persistence_kit::StorageError::BackendError {
                            underlying: format!("direct counts anchors: {error:?}"),
                        })?;
                }
                index_state.advance_into(checkpoint, &rows).map_err(|error| {
                    persistence_kit::StorageError::BackendError {
                        underlying: format!("direct checkpoint: {error:?}"),
                    }
                })?;
                Ok(())
            })
            .map_err(|error| CorpusKitError::StoreUnavailable(format!("{error:?}")));
        if let Err(transaction_error) = result {
            self.counts_reload_required.store(true, Ordering::Release);
            if let Err(reload_error) = self.reload_counts_from_storage() {
                return Err(CorpusKitError::StoreUnavailable(format!(
                    "{transaction_error:?}; reload durable counts: {reload_error:?}"
                )));
            }
            self.counts_reload_required.store(false, Ordering::Release);
            return Err(transaction_error);
        }
        Ok(())
    }

    fn persist_counts(&self, now_millis: i64) -> CorpusKitResult<()> {
        for slot in &self.slots {
            let (model_id, model_version) = {
                let handle = slot.handle.lock().unwrap();
                let p = handle.provider();
                (p.model_id().to_string(), p.model_version().to_string())
            };
            let counts = slot.counts.lock().unwrap();
            let Some(state) = counts.as_ref() else {
                continue;
            };
            let row = PersistedCounts {
                model_id,
                model_version,
                counts: state.accumulator.serialize_counts(),
                document_count: state.document_count,
                vocab_size: state.vocab_anchor,
                // Unix seconds per the store's field contract.
                updated_at_secs: now_millis / 1000,
            };
            // This blob is the immutable publication snapshot. Reference
            // contributions remain authoritative until provider publication.
            self.counts_store.upsert(&row)?;
        }
        Ok(())
    }

    /// The vocab-growth anchor (content-unit semantics).
    pub fn maintained_vocab_anchor(&self) -> usize {
        self.slots
            .iter()
            .filter_map(|slot| slot.counts.lock().unwrap().as_ref().map(|s| s.vocab_anchor))
            .max()
            .unwrap_or(0)
    }

    /// Canonical records represented by the base snapshot plus durable deltas.
    pub fn maintained_document_count(&self) -> usize {
        self.slots
            .iter()
            .filter_map(|slot| {
                slot.counts
                    .lock()
                    .unwrap()
                    .as_ref()
                    .map(|state| state.document_count)
            })
            .max()
            .unwrap_or(0)
    }

    // ── Recall ───────────────────────────────────────────────────────────

    /// Hybrid recall aggregated to canonical content IDs.
    pub fn recall(&self, query: &str, limit: usize) -> CorpusKitResult<Vec<CorpusContentHit>> {
        if limit == 0 || query.is_empty() {
            return Ok(Vec::new());
        }
        let candidate_k = (limit * 4).max(32);
        let (probe, model_id) = {
            let handle = self.slots[0].handle.lock().unwrap();
            let provider = handle.provider();
            (
                provider
                    .embed(query)
                    .map_err(|e| CorpusKitError::EmbeddingFailed(format!("{e:?}")))?,
                provider.model_id().to_string(),
            )
        };
        let vector_matches = self
            .vector_store
            .find_nearest(&probe, &model_id, candidate_k)
            .map_err(|e| CorpusKitError::StoreUnavailable(format!("{e:?}")))?;
        let tokens = default_keyword_tokens(query);
        let keyword_hits = self.inverted_index.top_k(
            &tokens,
            candidate_k,
            Default::default(),
            crate::engine::Algorithm::BlockMaxWand,
        );

        let mut vector_best: BTreeMap<String, (f32, String)> = BTreeMap::new();
        for m in &vector_matches {
            let id = content_id_from_item_key(&m.item_id).to_string();
            let score = (256 - m.distance) as f32;
            match vector_best.get(&id) {
                Some((existing, _)) if *existing >= score => {}
                _ => {
                    vector_best.insert(id, (score, m.item_id.clone()));
                }
            }
        }
        let mut keyword_best: BTreeMap<String, (f32, String)> = BTreeMap::new();
        for hit in &keyword_hits {
            let id = content_id_from_item_key(&hit.item_id).to_string();
            match keyword_best.get(&id) {
                Some((existing, _)) if *existing >= hit.impact => {}
                _ => {
                    keyword_best.insert(id, (hit.impact, hit.item_id.clone()));
                }
            }
        }

        let rrf_k = 60.0f64;
        let ranked_lane = |best: &BTreeMap<String, (f32, String)>| -> Vec<String> {
            let mut entries: Vec<(&String, &(f32, String))> = best.iter().collect();
            entries.sort_by(|a, b| {
                b.1 .0
                    .partial_cmp(&a.1 .0)
                    .unwrap_or(std::cmp::Ordering::Equal)
                    .then_with(|| a.0.cmp(b.0))
            });
            entries.into_iter().map(|(id, _)| id.clone()).collect()
        };
        let vector_ranked = ranked_lane(&vector_best);
        let keyword_ranked = ranked_lane(&keyword_best);
        let mut fused: BTreeMap<String, f64> = BTreeMap::new();
        for (rank, id) in vector_ranked.iter().enumerate() {
            *fused.entry(id.clone()).or_insert(0.0) += 1.0 / (rrf_k + (rank + 1) as f64);
        }
        for (rank, id) in keyword_ranked.iter().enumerate() {
            *fused.entry(id.clone()).or_insert(0.0) += 1.0 / (rrf_k + (rank + 1) as f64);
        }
        let mut ranked: Vec<(String, f64)> = fused.into_iter().collect();
        ranked.sort_by(|a, b| {
            b.1.partial_cmp(&a.1)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| a.0.cmp(&b.0))
        });
        ranked.truncate(limit);

        Ok(ranked
            .into_iter()
            .map(|(id, score)| {
                let best_key = keyword_best
                    .get(&id)
                    .map(|(_, k)| k.clone())
                    .or_else(|| vector_best.get(&id).map(|(_, k)| k.clone()));
                let evidence = best_key.as_deref().and_then(evidence_from_item_key);
                CorpusContentHit {
                    id: id.clone(),
                    score: score as f32,
                    keyword_score: keyword_best.get(&id).map(|(s, _)| *s),
                    vector_score: vector_best.get(&id).map(|(s, _)| *s),
                    evidence,
                }
            })
            .collect())
    }

    /// BM25-only top-k at content granularity — content IDs DIRECTLY.
    pub fn bm25_top_k(&self, query: &str, limit: usize) -> CorpusKitResult<Vec<(String, f32)>> {
        if limit == 0 || query.is_empty() {
            return Ok(Vec::new());
        }
        let tokens = default_keyword_tokens(query);
        if tokens.is_empty() {
            return Ok(Vec::new());
        }
        let hits = self.inverted_index.top_k(
            &tokens,
            limit * 4,
            Default::default(),
            crate::engine::Algorithm::BlockMaxWand,
        );
        let mut best: BTreeMap<String, f32> = BTreeMap::new();
        for hit in &hits {
            let id = content_id_from_item_key(&hit.item_id).to_string();
            let entry = best.entry(id).or_insert(0.0);
            if hit.impact > *entry {
                *entry = hit.impact;
            }
        }
        let mut ranked: Vec<(String, f32)> = best.into_iter().collect();
        ranked.sort_by(|a, b| {
            b.1.partial_cmp(&a.1)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| a.0.cmp(&b.0))
        });
        ranked.truncate(limit);
        Ok(ranked)
    }

    /// The default signal's model ID.
    pub fn model_id(&self) -> String {
        self.slots[0].model_id.clone()
    }
}

#[cfg(test)]
mod training_admission_tests {
    use super::CorpusContentEngine;

    #[test]
    fn provider_training_parallelism_uses_cpu_when_memory_allows() {
        let workers = CorpusContentEngine::provider_training_parallelism_with_budget(
            2_000,
            4,
            128u64 * 1_024 * 1_024 * 1_024,
            18,
        );
        assert_eq!(workers, 4);

        let constrained = CorpusContentEngine::provider_training_parallelism_with_budget(
            98_118,
            4,
            16u64 * 1_024 * 1_024 * 1_024,
            18,
        );
        assert_eq!(constrained, 1);
    }
}
