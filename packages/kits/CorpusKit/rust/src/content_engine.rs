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
use intellectus_lib::{report, StatSample};
use persistence_kit::{Column, Storage, StoragePredicate, TypedValue};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
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
pub const PASSAGE_KEY_SEPARATOR: char = '\u{1F}';

/// Deterministic token-budgeted passage ranges over UTF-8 text. Token
/// boundaries follow the SAME alphanumeric-run rule as
/// `default_keyword_tokens`, computed WITHOUT lowercasing so byte offsets
/// refer to the original text. Mirrors Swift
/// `PassageProduction.passageRanges`.
pub fn passage_ranges(text: &str, token_budget: usize) -> Vec<(usize, usize)> {
    assert!(token_budget > 0);
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
        let window_end = (index + token_budget).min(token_ranges.len());
        let first = token_ranges[index];
        let last = token_ranges[window_end - 1];
        out.push((first.0, last.1 - first.0));
        index = window_end;
    }
    out
}

fn passage_key(content_id: &str, revision: i64, utf8_start: usize, utf8_length: usize) -> String {
    format!(
        "{content_id}{sep}{revision}{sep}{utf8_start}{sep}{utf8_length}",
        sep = PASSAGE_KEY_SEPARATOR
    )
}

/// Parse a derived-row item key back to its canonical content ID. A
/// whole-content key contains no separator and returns itself.
pub fn content_id_from_item_key(key: &str) -> &str {
    match key.find(PASSAGE_KEY_SEPARATOR) {
        Some(pos) => &key[..pos],
        None => key,
    }
}

fn evidence_from_item_key(key: &str) -> Option<CorpusEvidence> {
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
    /// GLK's room-rollup coordination hook (fired with Drawer IDs).
    on_encoded: Mutex<Option<ContentOnEncoded>>,
    /// Declared encode speed (serial drain today; retained surface).
    encode_speed: Mutex<EncodeSpeed>,
    /// Test-only drain failure-injection hook.
    ingest_failure_hook: Mutex<Option<ContentIngestFailureHook>>,
    /// Test-only single-use forced float store error (default slot).
    forced_float_error: Mutex<Option<String>>,
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
                let passages = matches!(
                    configuration.index_unit(),
                    CorpusIndexUnitPolicy::TokenBudgetedPassages { .. }
                );
                standalone_declaration(passages)
            }
            CorpusOperatingMode::Attached => attached_declaration(),
        };
        storage
            .migrate(&profile)
            .map_err(|e| CorpusKitError::StoreUnavailable(format!("{e:?}")))?;
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
            on_encoded: Mutex::new(None),
            encode_speed: Mutex::new(EncodeSpeed::Foreground),
            ingest_failure_hook: Mutex::new(None),
            forced_float_error: Mutex::new(None),
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
            if let Ok(mut guard) = self.forced_float_error.lock() {
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
        if id.is_empty() || id.contains(PASSAGE_KEY_SEPARATOR) {
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
        self.register_claims(now_millis)?;

        let mut records = Vec::with_capacity(ids.len());
        for id in ids {
            Self::validate(id)?;
            let Some(record) = self.source.record(id)? else {
                self.clear_derived_state(id)?;
                continue;
            };
            if let Some(existing) = self.index_state.state(id)? {
                if existing.revision == record.revision
                    && existing.digest == record.digest
                    && existing.index_version == CONTENT_ENGINE_INDEX_VERSION
                {
                    continue;
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
            .filter_map(|(index, slot)| slot.fresh_basis_blob.is_none().then_some(index))
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
                let Some(record) = self.source.record(&job.content_id)? else {
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
                let previously_indexed = self.index_state.state(&record.id)?.is_some();
                if !content_already_prepared {
                    if let Some(checkpoint) = self.prepare_index_record(
                        &record,
                        job.cursor.as_deref(),
                        false,
                        now_millis,
                        SlotScope::All,
                        false,
                    )? {
                        // Counts are a monotonic vocabulary-growth anchor, not
                        // a revision inventory. Fold one content identity once.
                        if !previously_indexed {
                            counts_update = Some((
                                record.id.clone(),
                                record.revision,
                                record.digest.clone(),
                                record.text.clone(),
                            ));
                        }
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
        let mut references = Vec::new();
        if !counts_updates.is_empty() {
            for slot in &self.slots {
                let (model_id, model_version) = {
                    let handle = slot.handle.lock().unwrap();
                    let provider = handle.provider();
                    (
                        provider.model_id().to_string(),
                        provider.model_version().to_string(),
                    )
                };
                let mut counts = slot.counts.lock().unwrap();
                let Some(state) = counts.as_mut() else {
                    continue;
                };
                for (content_id, revision, digest, text) in counts_updates {
                    state.accumulator.add_to_counts(text);
                    state.document_count += 1;
                    references.push(PersistedCountsReference {
                        model_id: model_id.clone(),
                        model_version: model_version.clone(),
                        content_id: content_id.clone(),
                        revision: *revision,
                        digest: digest.clone(),
                        updated_at_secs: now_millis / 1000,
                    });
                }
            }
        }
        let counts_store = &self.counts_store;
        let index_state = &self.index_state;
        let result = self
            .storage
            .transaction(persistence_kit::IsolationLevel::Serializable, &mut |txn| {
                let rows = txn.row_store();
                for reference in &references {
                    counts_store
                        .upsert_reference_into(reference, &rows)
                        .map_err(|error| persistence_kit::StorageError::BackendError {
                            underlying: format!("queue counts reference: {error:?}"),
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
            let mut document_count = if let Some(row) = persisted {
                accumulator.restore_counts(&row.counts)?;
                row.document_count
            } else {
                0
            };
            for reference in self.counts_store.references(&model_id, &model_version)? {
                // Resolve by identity at reopen. A later revision contributes
                // its current canonical text once; a removed identity no
                // longer contributes to the post-base delta.
                let Some(record) = self.source.record(&reference.content_id)? else {
                    continue;
                };
                accumulator.add_to_counts(&record.text);
                document_count += 1;
            }
            *counts = Some(crate::corpus::CountsState {
                accumulator,
                document_count,
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
            self.prepare_index_record(record, applied_cursor, force, now_millis, slot_scope, true)?
        {
            self.index_state.advance(&checkpoint)?;
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
        maintain_counts: bool,
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

        // Maintained counts: fold in memory. Persistence happens at BATCH
        // boundaries (drain-burst close) and at training commits — never
        // once per record.
        if maintain_counts {
            self.fold_into_counts(&record.text);
        }

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
            CorpusIndexUnitPolicy::TokenBudgetedPassages { token_budget } => {
                let ranges = passage_ranges(&record.text, token_budget);
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
        if matches!(
            self.configuration.index_unit(),
            CorpusIndexUnitPolicy::TokenBudgetedPassages { .. }
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
        if matches!(
            self.configuration.index_unit(),
            CorpusIndexUnitPolicy::TokenBudgetedPassages { .. }
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

    /// Stream-train every trainable slot that lacks a CURRENT basis (or
    /// every trainable slot when `force`), one provider at a time.
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
        let mut digests = std::collections::BTreeMap::new();
        for slot in &self.slots {
            let Some(blob) = &slot.fresh_basis_blob else {
                continue;
            };
            let model_id = slot.model_id.clone();
            {
                let digest = slot.basis_digest.lock().unwrap().clone();
                if !force && !digest.is_empty() {
                    digests.insert(model_id, digest);
                    continue;
                }
            }
            let all_ids = self.source.active_content_ids()?;
            if all_ids.is_empty() {
                continue;
            }
            // Fresh accumulation state from the pristine blob — a retrain
            // never compounds on a prior generation. A SEPARATE fresh
            // counts accumulator folds the SAME pages, so the persisted
            // counts are exactly the training corpus's statistics.
            let model_version = {
                let handle = slot.handle.lock().unwrap();
                handle.provider().model_version().to_string()
            };
            // Reconstruct through the maintained-counts accumulator, not the
            // serving handle. A reopened persisted basis is intentionally held
            // as `Plain` because Rust cannot cross-cast that trait object back
            // to trainable; the separately retained accumulator remains the
            // stable trainable witness across reopen (the standalone Corpus
            // uses the same pattern in `train_and_persist_basis`).
            let (mut fresh, mut counts_accumulator) = {
                let counts = slot.counts.lock().unwrap();
                let state = counts.as_ref().ok_or_else(|| {
                    CorpusKitError::NotTrainable(format!(
                        "provider {model_id} has no retained counts accumulator"
                    ))
                })?;
                (
                    state.accumulator.reconstruct_trainable_basis(blob)?,
                    state.accumulator.reconstruct_trainable_basis(blob)?,
                )
            };
            let mut document_count = 0usize;
            let mut cursor = 0usize;
            while cursor < all_ids.len() {
                let end = (cursor + Self::TRAINING_PAGE_SIZE).min(all_ids.len());
                let mut texts: Vec<String> = Vec::with_capacity(end - cursor);
                for id in &all_ids[cursor..end] {
                    if let Some(record) = self.source.record(id)? {
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

            {
                let mut seam = self.train_fault_before_commit_model.lock().unwrap();
                if seam.as_deref() == Some(model_id.as_str()) {
                    *seam = None;
                    return Err(CorpusKitError::InvalidConfiguration(format!(
                        "injected training fault before commit: {model_id}"
                    )));
                }
            }

            // ATOMIC commit: basis + training-corpus counts in ONE
            // transaction — the pair can never disagree durably.
            let basis_blob = fresh.serialize_basis();
            let digest = crate::content::content_digest_bytes(&basis_blob);
            let basis_row = PersistedBasis {
                model_id: model_id.clone(),
                model_version: model_version.clone(),
                basis: basis_blob,
                trained_at_secs: now_millis / 1000,
                trained_chunk_count: document_count,
            };
            let counts_row = PersistedCounts {
                model_id: model_id.clone(),
                model_version: model_version.clone(),
                counts: counts_accumulator.serialize_counts(),
                document_count,
                vocab_size: counts_accumulator.counts_vocabulary_size(),
                updated_at_secs: now_millis / 1000,
            };
            let basis_store = &self.basis_store;
            let counts_store = &self.counts_store;
            self.storage
                .transaction(persistence_kit::IsolationLevel::Serializable, &mut |txn| {
                    let rows = txn.row_store();
                    basis_store.upsert_into(&basis_row, &rows).map_err(|e| {
                        persistence_kit::StorageError::BackendError {
                            underlying: format!("{e:?}"),
                        }
                    })?;
                    counts_store.upsert_into(&counts_row, &rows).map_err(|e| {
                        persistence_kit::StorageError::BackendError {
                            underlying: format!("{e:?}"),
                        }
                    })?;
                    counts_store
                        .delete_references_into(&model_id, &model_version, &rows)
                        .map_err(|e| persistence_kit::StorageError::BackendError {
                            underlying: format!("{e:?}"),
                        })?;
                    Ok(())
                })
                .map_err(|e| CorpusKitError::StoreUnavailable(format!("{e:?}")))?;

            // Serve the new generation.
            {
                let mut handle = slot.handle.lock().unwrap();
                *handle = crate::corpus::ProviderHandle::Trainable(fresh);
            }
            *slot.basis_digest.lock().unwrap() = digest.clone();
            {
                let mut counts = slot.counts.lock().unwrap();
                *counts = Some(crate::corpus::CountsState {
                    accumulator: counts_accumulator,
                    document_count,
                });
            }
            digests.insert(model_id.clone(), digest);

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
        for id in self.source.active_content_ids()? {
            match self.source.record(&id)? {
                Some(record) => {
                    // Training just rebuilt the maintained counts from this
                    // same full-corpus snapshot. Re-embedding the generation
                    // must not fold every record into those counts again.
                    if let Some(checkpoint) = self.prepare_index_record(
                        &record,
                        None,
                        true,
                        now_millis,
                        SlotScope::All,
                        false,
                    )? {
                        self.index_state.advance(&checkpoint)?;
                    }
                }
                None => self.clear_derived_state(&id)?,
            }
        }
        self.provider_configuration_store
            .mark_current(&self.provider_generation_token(), now_millis)?;
        Ok(())
    }

    /// Persist the maintained counts snapshot — the BATCH-boundary write.
    /// Called by the drain worker at burst close; never once per record.
    pub fn persist_counts_snapshot(&self, now_millis: i64) -> CorpusKitResult<()> {
        self.persist_counts(now_millis)
    }

    // ── Maintained counts ────────────────────────────────────────────────

    fn fold_into_counts(&self, text: &str) {
        for slot in &self.slots {
            let mut counts = slot.counts.lock().unwrap();
            if let Some(state) = counts.as_mut() {
                state.accumulator.add_to_counts(text);
                state.document_count += 1;
            }
        }
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
                vocab_size: state.accumulator.counts_vocabulary_size(),
                // Unix seconds per the store's field contract.
                updated_at_secs: now_millis / 1000,
            };
            let counts_store = &self.counts_store;
            self.storage
                .transaction(persistence_kit::IsolationLevel::Serializable, &mut |txn| {
                    let rows = txn.row_store();
                    counts_store.upsert_into(&row, &rows).map_err(|e| {
                        persistence_kit::StorageError::BackendError {
                            underlying: format!("{e:?}"),
                        }
                    })?;
                    counts_store
                        .delete_references_into(&row.model_id, &row.model_version, &rows)
                        .map_err(|e| persistence_kit::StorageError::BackendError {
                            underlying: format!("{e:?}"),
                        })?;
                    Ok(())
                })
                .map_err(|e| CorpusKitError::StoreUnavailable(format!("{e:?}")))?;
        }
        Ok(())
    }

    /// The vocab-growth anchor (content-unit semantics).
    pub fn maintained_vocab_anchor(&self) -> usize {
        self.slots
            .iter()
            .filter_map(|slot| {
                slot.counts
                    .lock()
                    .unwrap()
                    .as_ref()
                    .map(|s| s.accumulator.counts_vocabulary_size())
            })
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
