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

use crate::content::{
    CorpusContentChange, CorpusContentId, CorpusContentRecord, CorpusContentSource,
};
use crate::corpus::{Corpus, EmbeddingModelConfig, EncodeSpeed, FloatLaneOutcome, ProviderSlot};
use intellectus_lib::{report, StatSample};
use crate::document_store::CorpusDocumentStore;
use crate::engine::inverted_index_store::InvertedIndexStore;
use crate::error::{CorpusKitError, CorpusKitResult};
use crate::index_state_store::{CorpusIndexState, CorpusIndexStateStore};
use crate::basis_store::{BasisStore, PersistedBasis};
use crate::corpus_provider_counts_store::{CorpusProviderCountsStore, PersistedCounts};
use crate::schema_profile::{
    attached_declaration, standalone_declaration, CorpusContentConfiguration,
    CorpusIndexUnitPolicy, CorpusOperatingMode,
};
use crate::tokenizer::default_keyword_tokens;
use persistence_kit::{Column, Storage, StoragePredicate, TypedValue};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex};

/// GLK's room-rollup coordination callback (fired with Drawer IDs).
pub type ContentOnEncoded = Box<dyn Fn(&[String]) + Send + Sync>;
/// Test-only drain failure-injection hook (transient failure when Err).
pub type ContentIngestFailureHook = Box<dyn Fn(&str) -> Result<(), ()> + Send + Sync>;
use vectorkit::{
    VectorExactKey, VectorPayload, VectorPayloadInput, VectorRepresentationClaims,
    VectorRepresentationKey, VectorStore,
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
            CorpusContentChange::Upsert { id, revision, digest } => ContentIndexJob {
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
pub const CONTENT_ENGINE_INDEX_VERSION: i64 = 1;

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
    claims: VectorRepresentationClaims,
    slots: Vec<ProviderSlot>,
    /// Engine-owned content-reference queue state (P3). See
    /// content_engine_queue.rs.
    queue_state: Mutex<Option<crate::content_engine_queue::ContentQueueState>>,
    /// GLK's room-rollup coordination hook (fired with Drawer IDs).
    on_encoded: Mutex<Option<ContentOnEncoded>>,
    /// Declared encode speed (serial drain today; retained surface).
    encode_speed: Mutex<EncodeSpeed>,
    /// Test-only drain failure-injection hook.
    ingest_failure_hook: Mutex<Option<ContentIngestFailureHook>>,
    /// Test-only single-use forced float store error (default slot).
    forced_float_error: Mutex<Option<String>>,
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
        let claims = VectorRepresentationClaims::new(Arc::clone(&storage));

        let mut slots = Vec::with_capacity(models.len());
        for model in models {
            slots.push(Corpus::build_slot(model, &basis_store, &counts_store)?);
        }

        Ok(CorpusContentEngine {
            storage,
            configuration,
            source,
            inverted_index,
            vector_store,
            basis_store,
            counts_store,
            index_state,
            claims,
            slots,
            queue_state: Mutex::new(None),
            on_encoded: Mutex::new(None),
            encode_speed: Mutex::new(EncodeSpeed::Foreground),
            ingest_failure_hook: Mutex::new(None),
            forced_float_error: Mutex::new(None),
        })
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
    pub fn index_coverage_attestations(
        &self,
    ) -> CorpusKitResult<Vec<(String, i64, String)>> {
        Ok(self
            .index_state_all_states()?
            .into_iter()
            .map(|s| (s.content_id, s.revision, s.digest))
            .collect())
    }

    fn index_state_all_states(&self) -> CorpusKitResult<Vec<crate::index_state_store::CorpusIndexState>> {
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
        let ids = self.indexed_content_ids()?;
        let mut keys: Vec<VectorExactKey> = Vec::new();
        for id in &ids {
            for key in self.unit_keys(id)? {
                for slot in &self.slots {
                    keys.push(VectorExactKey::new(key.clone(), 0, slot.model_id.clone()));
                    keys.push(VectorExactKey::new(key.clone(), 1, slot.model_id.clone()));
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
                let entry = by_content.entry(id).or_insert(if nearest {
                    f32::MIN
                } else {
                    f32::MAX
                });
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
        for slot in &self.slots {
            let (model_id, model_version) = {
                let handle = slot.handle.lock().unwrap();
                let p = handle.provider();
                (p.model_id().to_string(), p.model_version().to_string())
            };
            for lane in [0u32, 1u32] {
                self.claims
                    .register_claim(
                        CLAIMS_CONSUMER,
                        &VectorRepresentationKey::new(model_id.clone(), model_version.clone(), lane),
                        now_millis,
                    )
                    .map_err(|e| CorpusKitError::StoreUnavailable(format!("{e:?}")))?;
            }
        }
        Ok(())
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
                self.index_record(&record, None, false, now_millis)?;
                Ok(true)
            }
            None => {
                self.clear_derived_state(id)?;
                Ok(false)
            }
        }
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
            CorpusContentChange::Upsert { id, revision, digest } => {
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
                self.index_record(&record, cursor, false, now_millis)?;
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

    fn index_record(
        &self,
        record: &CorpusContentRecord,
        applied_cursor: Option<&str>,
        force: bool,
        now_millis: i64,
    ) -> CorpusKitResult<()> {
        // Idempotence anchor: a checkpoint covering this exact (revision,
        // digest, index_version) means the derived rows are complete —
        // replay writes NOTHING. `force` (reindex) bypasses deliberately.
        if !force {
            if let Some(existing) = self.index_state.state(&record.id)? {
                if existing.revision == record.revision
                    && existing.digest == record.digest
                    && existing.index_version == CONTENT_ENGINE_INDEX_VERSION
                {
                    return Ok(());
                }
            }
        }
        self.register_claims(now_millis)?;
        self.first_ingest_train_if_needed(now_millis)?;

        let units = self.replace_units(record)?;

        for (key, text) in &units {
            self.inverted_index
                .index(key, &default_keyword_tokens(text), "")
                .map_err(|e| CorpusKitError::StoreUnavailable(format!("{e:?}")))?;
        }

        let mut rows: Vec<VectorPayloadInput> = Vec::with_capacity(units.len() * self.slots.len() * 2);
        for slot in &self.slots {
            let handle = slot.handle.lock().unwrap();
            let provider = handle.provider();
            for (key, text) in &units {
                let (engram, floats) = provider
                    .embed_pair(text)
                    .map_err(|e| CorpusKitError::EmbeddingFailed(format!("{e:?}")))?;
                rows.push(VectorPayloadInput {
                    item_id: key.clone(),
                    vector_index: 0,
                    payload: VectorPayload::from_engram(&engram),
                    model_id: provider.model_id().to_string(),
                    model_version: provider.model_version().to_string(),
                    filed_at_unix_secs: now_millis,
                });
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
        }
        if !rows.is_empty() {
            self.vector_store
                .add_payloads(&rows)
                .map_err(|e| CorpusKitError::StoreUnavailable(format!("{e:?}")))?;
        }

        self.fold_into_counts(&record.text);
        self.persist_counts(now_millis)?;

        // Checkpoint LAST.
        self.index_state.advance(&CorpusIndexState {
            content_id: record.id.clone(),
            revision: record.revision,
            digest: record.digest.clone(),
            index_version: CONTENT_ENGINE_INDEX_VERSION,
            applied_cursor: applied_cursor.map(str::to_string),
            updated_at_millis: now_millis,
        })?;
        Ok(())
    }

    /// Compute the record's index units under the configured policy,
    /// replacing durable passage rows and deleting STALE derived keys by
    /// exact key. Returns (key, text) pairs.
    fn replace_units(&self, record: &CorpusContentRecord) -> CorpusKitResult<Vec<(String, String)>> {
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
    fn delete_derived_rows(&self, unit_keys: &BTreeSet<String>) -> CorpusKitResult<()> {
        let model_ids: Vec<String> = self.slots.iter().map(|s| s.model_id.clone()).collect();
        let mut vector_keys: Vec<VectorExactKey> = Vec::new();
        for key in unit_keys {
            self.inverted_index
                .remove(key)
                .map_err(|e| CorpusKitError::StoreUnavailable(format!("{e:?}")))?;
            for model_id in &model_ids {
                vector_keys.push(VectorExactKey::new(key.clone(), 0, model_id.clone()));
                vector_keys.push(VectorExactKey::new(key.clone(), 1, model_id.clone()));
            }
        }
        self.vector_store
            .delete_vectors(&vector_keys)
            .map_err(|e| CorpusKitError::StoreUnavailable(format!("{e:?}")))?;
        Ok(())
    }

    /// Clear EVERYTHING derived for `id` (the remove path).
    fn clear_derived_state(&self, id: &str) -> CorpusKitResult<()> {
        let keys = self.unit_keys(id)?;
        self.delete_derived_rows(&keys)?;
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

    fn first_ingest_train_if_needed(&self, now_millis: i64) -> CorpusKitResult<()> {
        for slot in &self.slots {
            if slot.fresh_basis_blob.is_none() {
                continue;
            }
            let (model_id, model_version) = {
                let handle = slot.handle.lock().unwrap();
                let p = handle.provider();
                (p.model_id().to_string(), p.model_version().to_string())
            };
            let has_basis = self
                .basis_store
                .load(&model_id, &model_version)?
                .is_some();
            if !has_basis {
                self.train_slot(slot, now_millis)?;
            }
        }
        Ok(())
    }

    fn train_slot(&self, slot: &ProviderSlot, now_millis: i64) -> CorpusKitResult<()> {
        let Some(blob) = &slot.fresh_basis_blob else {
            return Ok(());
        };
        let texts = self.active_texts()?;
        if texts.is_empty() {
            return Ok(());
        }
        let mut handle = slot.handle.lock().unwrap();
        let Some(trainable) = handle.as_trainable() else {
            return Ok(());
        };
        let mut fresh = trainable.reconstruct_trainable_basis(blob)?;
        let text_refs: Vec<&str> = texts.iter().map(String::as_str).collect();
        fresh.train_on_corpus(&text_refs);
        let serialized = fresh.serialize_basis();
        let (model_id, model_version) = {
            let p = fresh.as_ref() as &dyn vectorkit::EmbeddingProvider;
            (p.model_id().to_string(), p.model_version().to_string())
        };
        self.basis_store.upsert(&PersistedBasis {
            model_id,
            model_version,
            basis: serialized,
            // Unix seconds per the store's field contract.
            trained_at_secs: now_millis / 1000,
            trained_chunk_count: texts.len(),
        })?;
        *handle = crate::corpus::ProviderHandle::Trainable(fresh);
        Ok(())
    }

    fn active_texts(&self) -> CorpusKitResult<Vec<String>> {
        let mut texts = Vec::new();
        for id in self.source.active_content_ids()? {
            if let Some(record) = self.source.record(&id)? {
                texts.push(record.text);
            }
        }
        Ok(texts)
    }

    /// Retrain every trainable slot from scratch and re-index every active
    /// content row (forced — a retrain changes the basis).
    pub fn reindex(&self, now_millis: i64) -> CorpusKitResult<()> {
        for slot in &self.slots {
            if slot.fresh_basis_blob.is_some() {
                self.train_slot(slot, now_millis)?;
            }
        }
        for id in self.source.active_content_ids()? {
            match self.source.record(&id)? {
                Some(record) => self.index_record(&record, None, true, now_millis)?,
                None => self.clear_derived_state(&id)?,
            }
        }
        self.persist_counts(now_millis)?;
        Ok(())
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
            let Some(state) = counts.as_ref() else { continue };
            self.counts_store.upsert(&PersistedCounts {
                model_id,
                model_version,
                counts: state.accumulator.serialize_counts(),
                document_count: state.document_count,
                vocab_size: state.accumulator.counts_vocabulary_size(),
                // Unix seconds per the store's field contract.
                updated_at_secs: now_millis / 1000,
            })?;
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
