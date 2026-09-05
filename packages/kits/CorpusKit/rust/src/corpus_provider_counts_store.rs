//! CorpusProviderCountsStore: persistence-kit-backed `corpus_provider_counts`
//! table. Rust mirror of Swift's `CorpusProviderCountsStore`.
//!
//! Persists a trainable provider's INCREMENTALLY-MAINTAINED statistics
//! ("counts") — the raw accumulated state a distributional provider
//! (RI/PPMI/LSA/NMF) builds from the corpus (vocabulary, document-frequencies,
//! co-occurrence counts, RI context vectors) — as an opaque per-provider blob
//! plus two cheap, queryable trigger columns. See the Swift file and
//! the Swift twin for the lifecycle. Standalone CorpusKit may publish the blob
//! at bounded ingest/reindex boundaries. Attached GLK freezes the published
//! blob between provider publications and records compact canonical-content
//! references; it never copies GLK Drawer text into this lane.
//!
//! Schema (one row per (model_id, model_version)):
//!   corpus_provider_counts (
//!     model_id      TEXT NOT NULL,
//!     model_version TEXT NOT NULL,
//!     counts        BLOB NOT NULL,    -- opaque per-provider serialized counts
//!     doc_count     INTEGER NOT NULL, -- durable monotonic document anchor
//!     vocab_size    INTEGER NOT NULL, -- durable monotonic vocabulary anchor
//!     updated_at    TIMESTAMP NOT NULL, -- TEXT ISO8601 at SQLite layer; never REAL
//!     ext           JSON              -- forward-compat slot; nullable
//!   )  PRIMARY KEY (model_id, model_version)
//!
//! `doc_count`/`vocab_size` are durable live anchors committed with attached
//! reference admission. Between publications they intentionally need not equal
//! the frozen blob's internal summary. NOT append-only: an incremental update
//! UPSERTs the row in place. Layering: core `corpus-kit`, depends only on
//! persistence-kit; never depends on `corpus-kit-providers` (counts bytes opaque).

use crate::error::{CorpusKitError, CorpusKitResult};
use persistence_kit::{
    Column, ColumnDeclaration, Migration, SchemaDeclaration, SchemaOperation, Storage,
    StoragePredicate, StorageRow, TableDeclaration, TypedValue,
};
use std::collections::{BTreeMap, HashMap};
use std::sync::Arc;
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// This store persists and returns opaque counts bytes produced by the
// provider's own serializer. It computes nothing.
// ─────────────────────────────────────────────────────────────────

/// A persisted provider-counts row: the opaque accumulated-statistics blob plus
/// the metadata that keys it and the two cheap trigger anchors. Rust mirror of
/// Swift's `PersistedCounts`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PersistedCounts {
    /// The provider model_id the counts were accumulated for.
    pub model_id: String,
    /// The provider model_version the counts were accumulated for.
    pub model_version: String,
    /// The provider-serialized accumulated counts (opaque to this store).
    pub counts: Vec<u8>,
    /// Canonical content identities admitted into this provider generation.
    pub document_count: usize,
    /// Durable, nondecreasing vocabulary-growth anchor.
    pub vocab_size: usize,
    /// When the counts were last persisted, in Unix seconds (the caller's
    /// `now`). Stored as TEXT ISO8601 at the SQLite layer per the schema
    /// invariant; the TypedValue carries the i64 seconds form.
    pub updated_at_secs: i64,
}

/// The growth anchors for a provider key — read without deserializing the blob.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CountsGrowthAnchor {
    pub document_count: usize,
    pub vocab_size: usize,
}

/// Crash-durable, reference-only counts record. Ordinary rows are post-base
/// deltas. `is_subsumed` marks content that a training snapshot included before
/// its delayed queue/direct admission committed, so that admission cannot fold
/// the same canonical content twice.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PersistedCountsReference {
    pub model_id: String,
    pub model_version: String,
    pub content_id: String,
    pub revision: i64,
    pub digest: String,
    pub updated_at_secs: i64,
    pub is_subsumed: bool,
    /// Sorted SHA-256 digests of genuinely novel terms accumulated across
    /// revisions of this identity since the published provider generation.
    pub growth_term_digests: Vec<String>,
}

/// Storage for a trainable embedding provider's maintained counts.
///
/// One row per (model_id, model_version). `upsert` writes/replaces it; `load`
/// reads the full row; `growth_anchor` reads only the cheap doc/vocab counts for
/// the retrain trigger; `delete_all` wipes every row. The store interprets none
/// of the bytes.
pub struct CorpusProviderCountsStore {
    storage: Arc<dyn Storage>,
}

// ─── Migration-invalidation sentinel ─────────────────────────────────────────
//
// The upgrade migration (`corpus_counts_migration_core` in apps/mootx01) zeroes
// the `counts` column to signal that the opaque per-provider accumulator is no
// longer valid (the new schema uses integer-keyed term pairs; the old blob
// format cannot be reused). The migration cannot:
//   • synthesise a new per-provider header — it operates on a provider-agnostic
//     column and carries no per-provider codec;
//   • delete the row — `doc_count` / `vocab_size` are monotone anchors the
//     migration is contractually required to preserve (pinned by upgrade.rs and
//     the corpus_counts_migration_convergence_tests.rs round-trip guard).
//
// An empty blob is therefore the defined "counts invalidated, rebuild from zero"
// signal. Callers that see `Ok(false)` from `restore_counts_into` already treat
// it as "start from zero"; the reindex latch the migration sets then rebuilds the
// counts on the next open-and-train cycle.
//
// `INVALIDATED_COUNTS_SENTINEL` and `is_invalidated_counts` are the single shared
// contract. Both the migration writer and the store reader go through this one
// predicate so they cannot drift independently. If the sentinel format ever
// changes (e.g. to carry a 4-byte magic header), this is the only edit site.

/// The byte value written by the counts migration to mark a row whose opaque
/// provider blob has been invalidated.
///
/// The migration writes an empty blob because:
///   1. It cannot synthesise a per-provider header (the column is opaque).
///   2. It cannot delete the row (the `doc_count`/`vocab_size` monotone anchors
///      must survive).
///
/// Readers call `is_invalidated_counts` on the raw `counts` bytes and return
/// `Ok(false)` — "nothing stored, start from zero" — before touching any provider.
pub const INVALIDATED_COUNTS_SENTINEL: &[u8] = &[];

/// Returns `true` when `bytes` carries the migration-invalidation sentinel —
/// an empty slice meaning "counts cleared by upgrade; rebuild from zero".
///
/// This is the single predicate both the migration writer and the store reader
/// use. Keeping them on one predicate means a future sentinel format change is
/// a single-site edit, and neither end can interpret a different shape
/// independently.
///
/// Deliberate narrow scope: only the empty slice is the sentinel. A non-empty
/// but undecodable blob still propagates `DecodingFailure` loudly, which is the
/// correct response to genuine corruption: swallowing it would convert real
/// on-disk corruption into silent data loss.
pub fn is_invalidated_counts(bytes: &[u8]) -> bool {
    bytes.is_empty()
}

const SUBSUMED_REFERENCE_EXT: &[u8] = br#"{"kind":"subsumed"}"#;

fn growth_reference_ext(terms: &[String]) -> Option<Vec<u8>> {
    let sorted: std::collections::BTreeSet<_> = terms
        .iter()
        .filter(|term| {
            term.len() == 64
                && term
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        })
        .cloned()
        .collect();
    if sorted.is_empty() {
        return None;
    }
    let body = sorted
        .iter()
        .map(|term| format!("\"{term}\""))
        .collect::<Vec<_>>()
        .join(",");
    Some(format!("{{\"kind\":\"growth\",\"terms\":[{body}]}}").into_bytes())
}

fn decode_reference_ext(bytes: &[u8]) -> (bool, Vec<String>) {
    if bytes == SUBSUMED_REFERENCE_EXT {
        return (true, Vec::new());
    }
    let Ok(value) = serde_json::from_slice::<serde_json::Value>(bytes) else {
        return (false, Vec::new());
    };
    if value.get("kind").and_then(|v| v.as_str()) != Some("growth") {
        return (false, Vec::new());
    }
    let mut terms: Vec<String> = value
        .get("terms")
        .and_then(|v| v.as_array())
        .into_iter()
        .flatten()
        .filter_map(|v| v.as_str())
        .filter(|term| {
            term.len() == 64
                && term
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        })
        .map(str::to_string)
        .collect();
    terms.sort();
    terms.dedup();
    (false, terms)
}

impl CorpusProviderCountsStore {
    /// Additive schema declaration for the maintained-counts table. Mirrors the
    /// Swift `CorpusProviderCountsStore.schemaDeclaration`. Not append-only: an
    /// incremental update UPSERTs the (model_id, model_version) row.
    pub fn schema_declaration() -> SchemaDeclaration {
        SchemaDeclaration::new(
            "CorpusKitCounts",
            4,
            vec![
                TableDeclaration::new(
                    "corpus_provider_counts",
                    vec![
                        ColumnDeclaration::text("model_id"),
                        ColumnDeclaration::text("model_version"),
                        // BLOB: the provider-serialized raw counts bytes.
                        ColumnDeclaration::blob("counts"),
                        // INTEGER growth anchors — NOT Bool flags.
                        ColumnDeclaration::int("doc_count"),
                        ColumnDeclaration::int("vocab_size"),
                        // TIMESTAMP maps to TEXT ISO8601 (schema invariant) — never REAL.
                        ColumnDeclaration::timestamp("updated_at"),
                        // nullable entity ext slots forward-compat slot; nullable JSON; omitted on upsert in 1.0.
                        ColumnDeclaration::json("ext").nullable(),
                    ],
                    vec!["model_id".to_string(), "model_version".to_string()],
                ),
                TableDeclaration::new(
                    "corpus_provider_count_references",
                    vec![
                        ColumnDeclaration::text("model_id"),
                        ColumnDeclaration::text("model_version"),
                        ColumnDeclaration::text("content_id"),
                        ColumnDeclaration::int("revision"),
                        ColumnDeclaration::text("digest"),
                        ColumnDeclaration::timestamp("updated_at"),
                        ColumnDeclaration::json("ext").nullable(),
                    ],
                    vec![
                        "model_id".to_string(),
                        "model_version".to_string(),
                        "content_id".to_string(),
                    ],
                ),
                Self::vocab_table(),
                Self::term_dictionary_table(),
                Self::term_payload_table(),
            ],
        )
        .with_migrations(vec![
            // v2 -> v3: create the term table. Additive only — no existing row
            // is read, rewritten, or moved. This is the first migration this
            // kit has ever had, and keeping it to a CREATE is deliberate:
            // transforming a multi-gigabyte estate inside the open path is the
            // failure shape ee#49 was.
            Migration {
                from_version: 2,
                to_version: 3,
                operations: vec![SchemaOperation::CreateTable(Self::vocab_table())],
            },
            // v3 -> v4 (CORPUS-COUNTS-01): create the integer-keyed pair.
            // CREATEs only — legacy-row drops belong to `mootx01 upgrade`,
            // never the open path (ee#49). Mirrors the Swift v3→v4 migration.
            Migration {
                from_version: 3,
                to_version: 4,
                operations: vec![
                    SchemaOperation::CreateTable(Self::term_dictionary_table()),
                    SchemaOperation::CreateTable(Self::term_payload_table()),
                ],
            },
        ])
    }

    /// One row per unique term across all models (v4). Shared by the
    /// declaration and the v3→v4 migration. Mirrors Swift
    /// `CorpusProviderCountsStore.termDictionaryTable`.
    fn term_dictionary_table() -> TableDeclaration {
        TableDeclaration::new(
            "corpus_provider_term_dictionary",
            vec![
                // INTEGER PRIMARY KEY (rowid alias): ids allocated by
                // insertion, dense, stable for the life of the estate.
                ColumnDeclaration::int("term_id"),
                ColumnDeclaration::text("term"),
                // Bitmask of models that know this term (bit = the model's
                // registry integer). Multi-valued state — bitmask territory.
                ColumnDeclaration::int("models"),
            ],
            vec!["term_id".to_string()],
        )
    }

    /// Per-(model, term) payload bytes (v4). No model_version column: a
    /// version bump drops the model's rows and sets the reindex latch.
    /// Payload-side model bitmask REJECTED (design §2.3): single-valued key;
    /// a bitwise AND cannot use an index. Mirrors Swift `termPayloadTable`.
    fn term_payload_table() -> TableDeclaration {
        TableDeclaration::new(
            "corpus_provider_term_payload",
            vec![
                ColumnDeclaration::int("model_id"),
                ColumnDeclaration::int("term_id"),
                ColumnDeclaration::blob("vector"),
            ],
            vec!["model_id".to_string(), "term_id".to_string()],
        )
    }

    /// The model → integer registry for the v4 pair. In-code and
    /// deterministic — the identical table ships in both ports; the integer
    /// doubles as the dictionary bitmask's bit index. Unknown models error
    /// rather than auto-assigning (extending the registry is a deliberate,
    /// reviewed act; derived rows are rebuildable via the reindex latch).
    /// Mirrors Swift `CorpusProviderCountsStore.modelRegistry`.
    fn model_int(model_id: &str) -> CorpusKitResult<i64> {
        match model_id {
            "random-indexing-v1" => Ok(0),
            "ppmi-v1" => Ok(1),
            "lsa-v1" => Ok(2),
            "nmf-v1" => Ok(3),
            other => Err(CorpusKitError::ModelUnavailable(format!(
                "modelID '{other}' is not in the counts model registry — add it (both ports) \
                 before persisting term payloads for it"
            ))),
        }
    }

    /// The term-keyed vocabulary table, shared by the declaration and its
    /// v2->v3 migration so the two cannot drift. Mirrors the Swift
    /// `CorpusProviderCountsStore.vocabTable`.
    fn vocab_table() -> TableDeclaration {
        TableDeclaration::new(
            "corpus_provider_vocab",
            vec![
                ColumnDeclaration::text("model_id"),
                ColumnDeclaration::text("model_version"),
                ColumnDeclaration::text("term"),
                // The provider's per-term payload, byte-identical to what the
                // blob format writes for this term (RandomIndexing: 2048
                // little-endian f32, 8192 bytes).
                ColumnDeclaration::blob("vector"),
                ColumnDeclaration::json("ext").nullable(),
            ],
            vec![
                "model_id".to_string(),
                "model_version".to_string(),
                "term".to_string(),
            ],
        )
    }

    pub fn new(storage: Arc<dyn Storage>) -> Self {
        CorpusProviderCountsStore { storage }
    }

    /// Insert or replace the counts row for a provider key. Keyed by the
    /// composite primary key: an incremental update replaces the prior counts in
    /// place. `updated_at_secs` is the caller's `now` (determinism).
    pub fn upsert(&self, row: &PersistedCounts) -> CorpusKitResult<()> {
        self.upsert_into(row, &self.storage.row_store())
    }

    /// Transaction-scoped variant: write through the CALLER's row store so
    /// the counts row commits atomically with its basis row (the corrective
    /// pass's basis+counts atomic commit).
    pub fn upsert_into(
        &self,
        row: &PersistedCounts,
        row_store: &std::sync::Arc<dyn persistence_kit::RowStore>,
    ) -> CorpusKitResult<()> {
        let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
        values.insert("model_id".into(), TypedValue::Text(row.model_id.clone()));
        values.insert(
            "model_version".into(),
            TypedValue::Text(row.model_version.clone()),
        );
        values.insert("counts".into(), TypedValue::Blob(row.counts.clone()));
        values.insert(
            "doc_count".into(),
            TypedValue::Int(row.document_count as i64),
        );
        values.insert("vocab_size".into(), TypedValue::Int(row.vocab_size as i64));
        values.insert(
            "updated_at".into(),
            TypedValue::Timestamp(row.updated_at_secs),
        );
        row_store
            .upsert(
                "corpus_provider_counts",
                values,
                &["model_id".to_string(), "model_version".to_string()],
            )
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        Ok(())
    }

    /// Persist a provider's maintained counts, splitting them into term rows
    /// when the provider supports it and writing one blob when it does not.
    ///
    /// This is the ONLY place that decides between the two layouts, mirroring
    /// the Swift `persistCounts`. Every write path routes through it: a
    /// provider term-split by one path and blob-written by another would leave
    /// the two representations disagreeing for the same key, and the read side
    /// prefers term rows, so the blob write would silently lose.
    ///
    /// **Sentinel-preserving flush guard** — when the migration has invalidated
    /// the stored counts (empty-blob sentinel) and the in-memory accumulator is
    /// still empty (nothing has been accumulated since the migration), writing
    /// here would serialise a valid-but-empty accumulator blob over the sentinel,
    /// destroying the invalidation signal. The guard prevents that:
    ///
    /// The discriminator is the WRITE PATH, not the accumulator's size: only a
    /// full-corpus retrain (`clears_invalidation = true`) may replace the
    /// sentinel. See the guard body for why size alone was not enough.
    ///
    /// With the sentinel preserved, the next call to `restore_counts_into` returns
    /// `Ok(false)`, and the reindex-path guard at the corpus layer fires, triggering
    /// the full retrain the migration intends. A zero-vocabulary basis is never
    /// published over a trained basis.
    pub fn persist_counts_into(
        &self,
        provider: &dyn crate::TrainableEmbeddingBasis,
        model_id: &str,
        model_version: &str,
        document_count: usize,
        vocab_size: usize,
        updated_at_secs: i64,
        row_store: &Arc<dyn persistence_kit::RowStore>,
        clears_invalidation: bool,
    ) -> CorpusKitResult<()> {
        // Sentinel-preserving flush. Only a FULL-CORPUS retrain may replace the
        // migration-invalidation sentinel; every other write path leaves it
        // standing, whatever the accumulator holds.
        //
        // An earlier version keyed this on `counts_vocabulary_size() == 0`,
        // reasoning that an accumulator with any term is a genuine flush. That
        // is wrong precisely in the window the sentinel covers. Between the
        // migration and the queued full reindex, ANY ingest — one MCP write is
        // enough — puts a term in the fresh accumulator, so the flush proceeded
        // and wrote a valid PARTIAL blob over the sentinel. Because the
        // migration preserves the old `doc_count` anchor, a later population
        // guard could then see document count equal to the active chunk count,
        // accept those partial counts as complete, and publish a basis trained
        // only on post-migration content — dropping the preexisting corpus from
        // the index until some later full rebuild.
        //
        // `clears_invalidation` is an explicit parameter rather than a default
        // so a new call site cannot acquire the right to clear the sentinel by
        // omission. Preserving it wrongly costs a rebuild; clearing it wrongly
        // costs recall.
        if !clears_invalidation {
            if let Some(stored) = Self::load_from(row_store, model_id, model_version)? {
                if is_invalidated_counts(&stored.counts) {
                    return Ok(());
                }
            }
        }

        match provider.decompose_counts() {
            Some((header, terms)) => {
                // `header` is a complete, decodable counts blob with an empty
                // map, so the column stays NOT NULL.
                let row = PersistedCounts {
                    model_id: model_id.to_string(),
                    model_version: model_version.to_string(),
                    counts: header,
                    document_count,
                    vocab_size,
                    updated_at_secs,
                };
                self.upsert_into(&row, row_store)?;
                // v4: the integer-keyed pair is the write target; clear v3
                // rows so the pair is unambiguously the truth for this key.
                self.replace_term_payloads_into(model_id, &terms, row_store)?;
                self.delete_vocab_into(model_id, model_version, row_store)
            }
            None => {
                let row = PersistedCounts {
                    model_id: model_id.to_string(),
                    model_version: model_version.to_string(),
                    counts: provider.serialize_counts(),
                    document_count,
                    vocab_size,
                    updated_at_secs,
                };
                self.upsert_into(&row, row_store)?;
                // A key can be reused by a provider that does not decompose;
                // clear term rows in BOTH layouts so the blob is unambiguously
                // the whole truth for this key.
                self.delete_vocab_into(model_id, model_version, row_store)?;
                self.delete_term_payloads_into(model_id, row_store)
            }
        }
    }

    /// Restore a provider's maintained counts, preferring term rows and falling
    /// back to the legacy single blob.
    ///
    /// Preference order (highest to lowest):
    ///   1. **Migration-invalidation sentinel** — an empty `counts` blob written
    ///      by the upgrade migration to signal that the opaque per-provider
    ///      accumulator is no longer valid. Returns `Ok(false)` without touching
    ///      the provider; callers adopt the `doc_count`/`vocab_size` anchors from
    ///      the row and start training from zero. The reindex latch the migration
    ///      sets then rebuilds the counts on the next open-and-train cycle.
    ///   2. **v4 integer-keyed pair** (`corpus_provider_term_dictionary` /
    ///      `corpus_provider_term_payload`) — the current layout.
    ///   3. **v3 text-keyed vocab rows** (`corpus_provider_vocab`) — legacy layout,
    ///      converted to term rows on the next persist.
    ///   4. **Legacy single blob** — the original format; used when neither term
    ///      table has entries for this model.
    ///
    /// "Empty at layers 2-4" means "not written in that layout", never "empty
    /// vocabulary". Mirrors the Swift chain.
    ///
    /// Returns `false` when nothing is stored (no row, or the invalidation
    /// sentinel); callers already treat this as "start from zero".
    ///
    /// **Non-empty but undecodable blobs still propagate `DecodingFailure`.**
    /// The sentinel intercepts only the empty-slice case. A non-empty corrupt
    /// blob is the correct signal for genuine on-disk corruption and must not
    /// be silenced: swallowing it would discard real statistics without a word.
    pub fn restore_counts_into(
        &self,
        provider: &mut dyn crate::TrainableEmbeddingBasis,
        model_id: &str,
        model_version: &str,
    ) -> CorpusKitResult<bool> {
        let Some(persisted) = self.load(model_id, model_version)? else {
            return Ok(false);
        };
        // Sentinel check: the migration writes an empty blob to invalidate stale
        // provider counts while preserving the monotone anchors (doc_count /
        // vocab_size). Returning Ok(false) here means "nothing stored, start from
        // zero" — the same contract every caller already handles. This intercept
        // must fire before any of the v4/v3/blob branches so that even surviving
        // v4 term rows (the migration does not delete the term dictionary or
        // payload tables, so those rows can outlive the invalidated blob)
        // cannot cause restore_counts_from_parts to forward the empty header to
        // the provider's BasisReader::expect_magic, which rejects empty slices.
        if is_invalidated_counts(&persisted.counts) {
            return Ok(false);
        }
        // Format-version gate: a counts blob written by another codec generation
        // for this provider (same magic, other version byte) cannot be restored —
        // its layout is not the one `provider` reads. Treat it exactly like the
        // sentinel: "no usable counts, rebuild from the corpus". The caller's
        // corpus-path retrain then re-persists counts in the current format.
        // `provider` is a freshly constructed instance by contract (every caller
        // reconstructs one from the empty factory blob before restoring into it),
        // so its `serialize_counts()` is the small header-only frame to compare.
        let current_frame = provider.serialize_counts();
        if crate::basis_blob_frame::is_stale_version(&persisted.counts, &current_frame) {
            eprintln!(
                "[corpus] counts for {model_id}@{model_version} are format v{}; this build writes v{}. Treating as no counts; the corpus-path retrain rebuilds them.",
                crate::basis_blob_frame::format_version(&persisted.counts).unwrap_or(0),
                crate::basis_blob_frame::format_version(&current_frame).unwrap_or(0)
            );
            return Ok(false);
        }
        // Preference order: v4 integer-keyed pair → v3 term rows → legacy
        // blob. Empty at each layer means "not written in that layout",
        // never "empty vocabulary". Mirrors the Swift chain.
        let v4_terms = self.load_term_payloads(model_id)?;
        if !v4_terms.is_empty() {
            provider.restore_counts_from_parts(&persisted.counts, &v4_terms)?;
            return Ok(true);
        }
        let terms = self.load_vocab(model_id, model_version)?;
        if terms.is_empty() {
            provider.restore_counts(&persisted.counts)?;
        } else {
            provider.restore_counts_from_parts(&persisted.counts, &terms)?;
        }
        Ok(true)
    }

    /// Replace the stored per-term payloads for a model (v4), maintaining the
    /// term dictionary. Term ids are allocated explicitly as max(term_id)+n —
    /// deterministic and port-parallel. Mirrors Swift `replaceTermPayloads`.
    pub fn replace_term_payloads_into(
        &self,
        model_id: &str,
        terms: &[(String, Vec<u8>)],
        row_store: &Arc<dyn persistence_kit::RowStore>,
    ) -> CorpusKitResult<()> {
        let model = Self::model_int(model_id)?;
        let bit: i64 = 1 << model;

        // Load the dictionary once: term → (term_id, models bitmask).
        let mut dict: BTreeMap<String, (i64, i64)> = BTreeMap::new();
        let mut max_id: i64 = 0;
        let dict_rows = row_store
            .query("corpus_provider_term_dictionary", None, &[], None, None)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        for row in &dict_rows {
            let (Some(TypedValue::Int(id)), Some(TypedValue::Text(term)), Some(TypedValue::Int(models))) =
                (row.get("term_id"), row.get("term"), row.get("models"))
            else {
                continue;
            };
            dict.insert(term.clone(), (*id, *models));
            max_id = max_id.max(*id);
        }

        // Replace this model's payload generation (delete-then-insert, same
        // idiom as replace_vocab_into).
        let model_predicate = StoragePredicate::Eq(
            Column::new("corpus_provider_term_payload", "model_id"),
            TypedValue::Int(model),
        );
        row_store
            .delete("corpus_provider_term_payload", &model_predicate)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;

        for (term, vector) in terms {
            let term_id: i64 = match dict.get(term).copied() {
                Some((id, models)) => {
                    if models & bit == 0 {
                        let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
                        values.insert("term_id".into(), TypedValue::Int(id));
                        values.insert("term".into(), TypedValue::Text(term.clone()));
                        values.insert("models".into(), TypedValue::Int(models | bit));
                        row_store
                            .upsert(
                                "corpus_provider_term_dictionary",
                                values,
                                &["term_id".to_string()],
                            )
                            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
                        dict.insert(term.clone(), (id, models | bit));
                    }
                    id
                }
                None => {
                    max_id += 1;
                    let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
                    values.insert("term_id".into(), TypedValue::Int(max_id));
                    values.insert("term".into(), TypedValue::Text(term.clone()));
                    values.insert("models".into(), TypedValue::Int(bit));
                    row_store
                        .upsert(
                            "corpus_provider_term_dictionary",
                            values,
                            &["term_id".to_string()],
                        )
                        .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
                    dict.insert(term.clone(), (max_id, bit));
                    max_id
                }
            };
            let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
            values.insert("model_id".into(), TypedValue::Int(model));
            values.insert("term_id".into(), TypedValue::Int(term_id));
            values.insert("vector".into(), TypedValue::Blob(vector.clone()));
            row_store
                .upsert(
                    "corpus_provider_term_payload",
                    values,
                    &["model_id".to_string(), "term_id".to_string()],
                )
                .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        }
        Ok(())
    }

    /// Every stored term/vector pair for a model from the v4 pair. EMPTY when
    /// the model has no v4 rows or the estate predates v4 — callers fall back,
    /// never read empty as "empty vocabulary". Mirrors Swift `loadTermPayloads`.
    pub fn load_term_payloads(
        &self,
        model_id: &str,
    ) -> CorpusKitResult<Vec<(String, Vec<u8>)>> {
        let Ok(model) = Self::model_int(model_id) else {
            return Ok(Vec::new());
        };
        let row_store = self.storage.row_store();
        let payload_predicate = StoragePredicate::Eq(
            Column::new("corpus_provider_term_payload", "model_id"),
            TypedValue::Int(model),
        );
        let payload_rows = row_store
            .query("corpus_provider_term_payload", Some(&payload_predicate), &[], None, None)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        if payload_rows.is_empty() {
            return Ok(Vec::new());
        }

        // Join-free: dictionary filtered by this model's bit, id → term.
        let bit: i64 = 1 << model;
        let mut term_by_id: BTreeMap<i64, String> = BTreeMap::new();
        let dict_rows = row_store
            .query("corpus_provider_term_dictionary", None, &[], None, None)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        for row in &dict_rows {
            let (Some(TypedValue::Int(id)), Some(TypedValue::Text(term)), Some(TypedValue::Int(models))) =
                (row.get("term_id"), row.get("term"), row.get("models"))
            else {
                continue;
            };
            if models & bit != 0 {
                term_by_id.insert(*id, term.clone());
            }
        }

        Ok(payload_rows
            .iter()
            .filter_map(|row| {
                let id = match row.get("term_id") {
                    Some(TypedValue::Int(i)) => *i,
                    _ => return None,
                };
                let vector = match row.get("vector") {
                    Some(TypedValue::Blob(b)) => b.clone(),
                    _ => return None,
                };
                term_by_id.get(&id).map(|term| (term.clone(), vector))
            })
            .collect())
    }

    /// Drop a model's v4 payload rows and clear its dictionary bits. Rows
    /// whose bitmask reaches zero stay — a dead term row is harmless and its
    /// id is reused by the next writer. Mirrors Swift `deleteTermPayloads`.
    pub fn delete_term_payloads_into(
        &self,
        model_id: &str,
        row_store: &Arc<dyn persistence_kit::RowStore>,
    ) -> CorpusKitResult<()> {
        let Ok(model) = Self::model_int(model_id) else {
            return Ok(());
        };
        let bit: i64 = 1 << model;
        let model_predicate = StoragePredicate::Eq(
            Column::new("corpus_provider_term_payload", "model_id"),
            TypedValue::Int(model),
        );
        row_store
            .delete("corpus_provider_term_payload", &model_predicate)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        let dict_rows = row_store
            .query("corpus_provider_term_dictionary", None, &[], None, None)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        for row in &dict_rows {
            let (Some(TypedValue::Int(id)), Some(TypedValue::Text(term)), Some(TypedValue::Int(models))) =
                (row.get("term_id"), row.get("term"), row.get("models"))
            else {
                continue;
            };
            if models & bit != 0 {
                let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
                values.insert("term_id".into(), TypedValue::Int(*id));
                values.insert("term".into(), TypedValue::Text(term.clone()));
                values.insert("models".into(), TypedValue::Int(models & !bit));
                row_store
                    .upsert(
                        "corpus_provider_term_dictionary",
                        values,
                        &["term_id".to_string()],
                    )
                    .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
            }
        }
        Ok(())
    }

    /// Replace the stored vocabulary for a provider key with `terms`.
    ///
    /// Delete-then-insert through the caller's row store so a retrain becomes
    /// visible atomically with its counts and basis rows and never leaves a
    /// union of two generations. Each bound value is one term's vector, so no
    /// single bind scales with vocabulary — the whole point of the table.
    /// Mirrors Swift `replaceVocab(modelID:modelVersion:terms:into:)`.
    pub fn replace_vocab_into(
        &self,
        model_id: &str,
        model_version: &str,
        terms: &[(String, Vec<u8>)],
        row_store: &Arc<dyn persistence_kit::RowStore>,
    ) -> CorpusKitResult<()> {
        self.delete_vocab_into(model_id, model_version, row_store)?;
        for (term, vector) in terms {
            let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
            values.insert("model_id".into(), TypedValue::Text(model_id.to_string()));
            values.insert(
                "model_version".into(),
                TypedValue::Text(model_version.to_string()),
            );
            values.insert("term".into(), TypedValue::Text(term.clone()));
            values.insert("vector".into(), TypedValue::Blob(vector.clone()));
            row_store
                .upsert(
                    "corpus_provider_vocab",
                    values,
                    &[
                        "model_id".to_string(),
                        "model_version".to_string(),
                        "term".to_string(),
                    ],
                )
                .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        }
        Ok(())
    }

    /// Every stored term/vector pair for a provider key.
    ///
    /// Returns EMPTY both when the provider has no vocabulary and when the
    /// estate predates the term table — callers must read empty as "fall back
    /// to the legacy blob", never as "the vocabulary is empty". Order is
    /// unspecified: only the blob WRITER needs UTF-8 byte ordering for
    /// cross-port determinism; the reader builds a map.
    pub fn load_vocab(
        &self,
        model_id: &str,
        model_version: &str,
    ) -> CorpusKitResult<Vec<(String, Vec<u8>)>> {
        let predicate = Self::vocab_key_predicate(model_id, model_version);
        let rows = self
            .storage
            .row_store()
            .query("corpus_provider_vocab", Some(&predicate), &[], None, None)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        Ok(rows
            .iter()
            .filter_map(|row| {
                let term = match row.get("term") {
                    Some(TypedValue::Text(t)) => t.clone(),
                    _ => return None,
                };
                let vector = match row.get("vector") {
                    Some(TypedValue::Blob(b)) => b.clone(),
                    _ => return None,
                };
                Some((term, vector))
            })
            .collect())
    }

    /// Drop the stored vocabulary for a provider key.
    pub fn delete_vocab_into(
        &self,
        model_id: &str,
        model_version: &str,
        row_store: &Arc<dyn persistence_kit::RowStore>,
    ) -> CorpusKitResult<()> {
        let predicate = Self::vocab_key_predicate(model_id, model_version);
        row_store
            .delete("corpus_provider_vocab", &predicate)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        Ok(())
    }

    /// Provider-key predicate for the term table, shared by load and delete so
    /// the two can never disagree about what "this provider key" means.
    fn vocab_key_predicate(model_id: &str, model_version: &str) -> StoragePredicate {
        StoragePredicate::And(vec![
            StoragePredicate::Eq(
                Column::new("corpus_provider_vocab", "model_id"),
                TypedValue::Text(model_id.to_string()),
            ),
            StoragePredicate::Eq(
                Column::new("corpus_provider_vocab", "model_version"),
                TypedValue::Text(model_version.to_string()),
            ),
        ])
    }

    /// Load the full persisted counts for a provider key, or `None` if none.
    pub fn load(
        &self,
        model_id: &str,
        model_version: &str,
    ) -> CorpusKitResult<Option<PersistedCounts>> {
        Self::load_from(&self.storage.row_store(), model_id, model_version)
    }

    /// Read only the growth anchors (doc/vocab counts) for a provider key,
    /// without deserializing the counts blob — the cheap read the vocab-growth
    /// retrain trigger uses each time it evaluates staleness.
    pub fn growth_anchor(
        &self,
        model_id: &str,
        model_version: &str,
    ) -> CorpusKitResult<Option<CountsGrowthAnchor>> {
        let rows = self.query_key(model_id, model_version)?;
        Ok(rows.first().and_then(|row| {
            let document_count = match row.get("doc_count") {
                Some(TypedValue::Int(i)) => *i as usize,
                _ => return None,
            };
            let vocab_size = match row.get("vocab_size") {
                Some(TypedValue::Int(i)) => *i as usize,
                _ => return None,
            };
            Some(CountsGrowthAnchor {
                document_count,
                vocab_size,
            })
        }))
    }

    /// Insert an idempotent reference delta through the caller's transaction.
    /// No canonical text or token inventory is stored in this row.
    pub fn upsert_reference_into(
        &self,
        row: &PersistedCountsReference,
        row_store: &std::sync::Arc<dyn persistence_kit::RowStore>,
    ) -> CorpusKitResult<()> {
        let mut values = BTreeMap::new();
        values.insert("model_id".into(), TypedValue::Text(row.model_id.clone()));
        values.insert(
            "model_version".into(),
            TypedValue::Text(row.model_version.clone()),
        );
        values.insert(
            "content_id".into(),
            TypedValue::Text(row.content_id.clone()),
        );
        values.insert("revision".into(), TypedValue::Int(row.revision));
        values.insert("digest".into(), TypedValue::Text(row.digest.clone()));
        values.insert(
            "updated_at".into(),
            TypedValue::Timestamp(row.updated_at_secs),
        );
        values.insert(
            "ext".into(),
            if row.is_subsumed {
                TypedValue::Json(SUBSUMED_REFERENCE_EXT.to_vec())
            } else if let Some(bytes) = growth_reference_ext(&row.growth_term_digests) {
                TypedValue::Json(bytes)
            } else {
                TypedValue::Null
            },
        );
        row_store
            .upsert(
                "corpus_provider_count_references",
                values,
                &[
                    "model_id".to_string(),
                    "model_version".to_string(),
                    "content_id".to_string(),
                ],
            )
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        Ok(())
    }

    /// Whether this provider generation already carries a pending delta for a
    /// canonical identity. The serialized queue batch uses this to keep a
    /// remove/re-add idempotent in memory as well as on disk.
    pub fn has_reference(
        &self,
        model_id: &str,
        model_version: &str,
        content_id: &str,
    ) -> CorpusKitResult<bool> {
        let predicate = StoragePredicate::And(vec![
            StoragePredicate::Eq(
                Column::new("corpus_provider_count_references", "model_id"),
                TypedValue::Text(model_id.to_string()),
            ),
            StoragePredicate::Eq(
                Column::new("corpus_provider_count_references", "model_version"),
                TypedValue::Text(model_version.to_string()),
            ),
            StoragePredicate::Eq(
                Column::new("corpus_provider_count_references", "content_id"),
                TypedValue::Text(content_id.to_string()),
            ),
        ]);
        let rows = self
            .storage
            .row_store()
            .query(
                "corpus_provider_count_references",
                Some(&predicate),
                &[],
                Some(1),
                None,
            )
            .map_err(|error| CorpusKitError::StoreUnavailable(error.to_string()))?;
        Ok(!rows.is_empty())
    }

    /// The pending reference for one canonical identity, if any. The digest
    /// distinguishes an idempotent re-admission from a revision.
    pub fn reference_for(
        &self,
        model_id: &str,
        model_version: &str,
        content_id: &str,
    ) -> CorpusKitResult<Option<PersistedCountsReference>> {
        let predicate = StoragePredicate::And(vec![
            StoragePredicate::Eq(
                Column::new("corpus_provider_count_references", "model_id"),
                TypedValue::Text(model_id.to_string()),
            ),
            StoragePredicate::Eq(
                Column::new("corpus_provider_count_references", "model_version"),
                TypedValue::Text(model_version.to_string()),
            ),
            StoragePredicate::Eq(
                Column::new("corpus_provider_count_references", "content_id"),
                TypedValue::Text(content_id.to_string()),
            ),
        ]);
        let rows = self
            .storage
            .row_store()
            .query(
                "corpus_provider_count_references",
                Some(&predicate),
                &[],
                Some(1),
                None,
            )
            .map_err(|error| CorpusKitError::StoreUnavailable(error.to_string()))?;
        Ok(rows.first().and_then(decode_reference))
    }

    /// Batch-fetch pending references for a set of canonical identities.
    /// Returns a HashMap keyed by content_id so callers can replace
    /// O(N) individual reference_for calls with a single WHERE…IN query.
    /// Empty input returns immediately without hitting the store.
    pub fn references_for(
        &self,
        model_id: &str,
        model_version: &str,
        content_ids: &[&str],
    ) -> CorpusKitResult<HashMap<String, PersistedCountsReference>> {
        if content_ids.is_empty() {
            return Ok(HashMap::new());
        }
        let values: Vec<TypedValue> = content_ids
            .iter()
            .map(|id| TypedValue::Text(id.to_string()))
            .collect();
        let predicate = StoragePredicate::And(vec![
            StoragePredicate::Eq(
                Column::new("corpus_provider_count_references", "model_id"),
                TypedValue::Text(model_id.to_string()),
            ),
            StoragePredicate::Eq(
                Column::new("corpus_provider_count_references", "model_version"),
                TypedValue::Text(model_version.to_string()),
            ),
            StoragePredicate::In(
                Column::new("corpus_provider_count_references", "content_id"),
                values,
            ),
        ]);
        let rows = self
            .storage
            .row_store()
            .query(
                "corpus_provider_count_references",
                Some(&predicate),
                &[],
                None,
                None,
            )
            .map_err(|error| CorpusKitError::StoreUnavailable(error.to_string()))?;
        let mut result = HashMap::new();
        for row in &rows {
            if let Some(reference) = decode_reference(row) {
                result.insert(reference.content_id.clone(), reference);
            }
        }
        Ok(result)
    }

    /// Persist the maintained-count anchors (document count + vocabulary) on
    /// the provider's counts row WITHOUT rewriting the base blob. The anchors
    /// commit in the SAME transaction as the reference mutation they reflect,
    /// so a process restart reads exactly the anchors the live process held —
    /// the governor's threshold decision is restart-deterministic. Returns
    /// false when the generation has no counts row yet (bootstrap edge; the
    /// caller upserts the full row instead).
    pub fn update_anchors_into(
        &self,
        model_id: &str,
        model_version: &str,
        document_count: usize,
        vocab_size: usize,
        row_store: &std::sync::Arc<dyn persistence_kit::RowStore>,
    ) -> CorpusKitResult<bool> {
        let mut values = BTreeMap::new();
        values.insert("doc_count".into(), TypedValue::Int(document_count as i64));
        values.insert("vocab_size".into(), TypedValue::Int(vocab_size as i64));
        let predicate = StoragePredicate::And(vec![
            StoragePredicate::Eq(
                Column::new("corpus_provider_counts", "model_id"),
                TypedValue::Text(model_id.to_string()),
            ),
            StoragePredicate::Eq(
                Column::new("corpus_provider_counts", "model_version"),
                TypedValue::Text(model_version.to_string()),
            ),
        ]);
        let updated = row_store
            .update("corpus_provider_counts", values, &predicate)
            .map_err(|error| CorpusKitError::StoreUnavailable(error.to_string()))?;
        Ok(updated > 0)
    }

    pub fn references(
        &self,
        model_id: &str,
        model_version: &str,
    ) -> CorpusKitResult<Vec<PersistedCountsReference>> {
        let predicate = StoragePredicate::And(vec![
            StoragePredicate::Eq(
                Column::new("corpus_provider_count_references", "model_id"),
                TypedValue::Text(model_id.to_string()),
            ),
            StoragePredicate::Eq(
                Column::new("corpus_provider_count_references", "model_version"),
                TypedValue::Text(model_version.to_string()),
            ),
        ]);
        let mut references: Vec<_> = self
            .storage
            .row_store()
            .query(
                "corpus_provider_count_references",
                Some(&predicate),
                &[],
                None,
                None,
            )
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?
            .iter()
            .filter_map(decode_reference)
            .collect();
        references.sort_by(|a, b| {
            (&a.content_id, a.revision, &a.digest).cmp(&(&b.content_id, b.revision, &b.digest))
        });
        Ok(references)
    }

    pub fn delete_references_into(
        &self,
        model_id: &str,
        model_version: &str,
        row_store: &std::sync::Arc<dyn persistence_kit::RowStore>,
    ) -> CorpusKitResult<()> {
        let predicate = StoragePredicate::And(vec![
            StoragePredicate::Eq(
                Column::new("corpus_provider_count_references", "model_id"),
                TypedValue::Text(model_id.to_string()),
            ),
            StoragePredicate::Eq(
                Column::new("corpus_provider_count_references", "model_version"),
                TypedValue::Text(model_version.to_string()),
            ),
        ]);
        row_store
            .delete("corpus_provider_count_references", &predicate)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        Ok(())
    }

    /// Delete one identity reference through the caller's transaction.
    pub fn delete_reference_into(
        &self,
        model_id: &str,
        model_version: &str,
        content_id: &str,
        row_store: &std::sync::Arc<dyn persistence_kit::RowStore>,
    ) -> CorpusKitResult<()> {
        let predicate = StoragePredicate::And(vec![
            StoragePredicate::Eq(
                Column::new("corpus_provider_count_references", "model_id"),
                TypedValue::Text(model_id.to_string()),
            ),
            StoragePredicate::Eq(
                Column::new("corpus_provider_count_references", "model_version"),
                TypedValue::Text(model_version.to_string()),
            ),
            StoragePredicate::Eq(
                Column::new("corpus_provider_count_references", "content_id"),
                TypedValue::Text(content_id.to_string()),
            ),
        ]);
        row_store
            .delete("corpus_provider_count_references", &predicate)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        Ok(())
    }

    /// Delete every counts row. Used by `Corpus::destroy_recall_index` so a
    /// destroyed corpus leaves no orphaned counts behind.
    pub fn delete_all(&self) -> CorpusKitResult<()> {
        self.storage
            .row_store()
            .delete(
                "corpus_provider_count_references",
                &StoragePredicate::IsTrue,
            )
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        self.storage
            .row_store()
            .delete("corpus_provider_counts", &StoragePredicate::IsTrue)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        // ALL term tables — v3 vocab AND the v4 dictionary/payload pair — are
        // this store's state, so a wholesale clear must include every one
        // (the restore path PREFERS the v4 pair, so stale v4 rows shadow the
        // truth). corpus_provider_vocab was missing here even pre-v4 — a
        // Swift/Rust parity gap this fix also closes.
        self.storage
            .row_store()
            .delete("corpus_provider_vocab", &StoragePredicate::IsTrue)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        self.storage
            .row_store()
            .delete("corpus_provider_term_dictionary", &StoragePredicate::IsTrue)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        self.storage
            .row_store()
            .delete("corpus_provider_term_payload", &StoragePredicate::IsTrue)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        Ok(())
    }

    fn query_key(&self, model_id: &str, model_version: &str) -> CorpusKitResult<Vec<StorageRow>> {
        Self::query_key_from(&self.storage.row_store(), model_id, model_version)
    }

    /// Query `corpus_provider_counts` through a caller-supplied row store and
    /// return the raw storage rows for this provider key.
    ///
    /// Both `query_key` and the flush guard's `load_from` path share this single
    /// predicate definition. `query_key` passes the store's own handle for
    /// standalone reads. `load_from` passes the caller's transaction handle so the
    /// precondition check reads the same transactional view the write will land in.
    fn query_key_from(
        row_store: &Arc<dyn persistence_kit::RowStore>,
        model_id: &str,
        model_version: &str,
    ) -> CorpusKitResult<Vec<StorageRow>> {
        let predicate = StoragePredicate::And(vec![
            StoragePredicate::Eq(
                Column::new("corpus_provider_counts", "model_id"),
                TypedValue::Text(model_id.to_string()),
            ),
            StoragePredicate::Eq(
                Column::new("corpus_provider_counts", "model_version"),
                TypedValue::Text(model_version.to_string()),
            ),
        ]);
        row_store
            .query(
                "corpus_provider_counts",
                Some(&predicate),
                &[],
                Some(1),
                None,
            )
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))
    }

    /// Load the persisted counts for a provider key through a caller-supplied
    /// row store, or `None` when no row exists for this key.
    ///
    /// `load` delegates here using the store's own handle for standalone reads.
    /// The flush guard in `persist_counts_into` calls this with the caller's
    /// transaction handle so the precondition check sees writes already made
    /// in that same transaction.
    fn load_from(
        row_store: &Arc<dyn persistence_kit::RowStore>,
        model_id: &str,
        model_version: &str,
    ) -> CorpusKitResult<Option<PersistedCounts>> {
        let rows = Self::query_key_from(row_store, model_id, model_version)?;
        Ok(rows.first().and_then(decode_counts))
    }
}

fn decode_reference(row: &StorageRow) -> Option<PersistedCountsReference> {
    let (is_subsumed, growth_term_digests) = match row.get("ext") {
        Some(TypedValue::Json(bytes)) | Some(TypedValue::Blob(bytes)) => {
            decode_reference_ext(bytes)
        }
        _ => (false, Vec::new()),
    };
    Some(PersistedCountsReference {
        model_id: match row.get("model_id") {
            Some(TypedValue::Text(value)) => value.clone(),
            _ => return None,
        },
        model_version: match row.get("model_version") {
            Some(TypedValue::Text(value)) => value.clone(),
            _ => return None,
        },
        content_id: match row.get("content_id") {
            Some(TypedValue::Text(value)) => value.clone(),
            _ => return None,
        },
        revision: match row.get("revision") {
            Some(TypedValue::Int(value)) => *value,
            _ => return None,
        },
        digest: match row.get("digest") {
            Some(TypedValue::Text(value)) => value.clone(),
            _ => return None,
        },
        updated_at_secs: decode_updated_at_secs(row.get("updated_at"))?,
        is_subsumed,
        growth_term_digests,
    })
}

/// Decode a counts row, tolerant of BOTH the semantic `Timestamp(i64)` form a
/// migrate-aware connection returns AND the raw `Text` ISO8601 form a fresh
/// connection returns on read — the same primitive-tolerance discipline
/// `basis_store::decode_basis` uses, so maintained counts are not silently
/// dropped on reopen. A row failing any field match yields `None`.
fn decode_counts(row: &StorageRow) -> Option<PersistedCounts> {
    let model_id = match row.get("model_id") {
        Some(TypedValue::Text(s)) => s.clone(),
        _ => return None,
    };
    let model_version = match row.get("model_version") {
        Some(TypedValue::Text(s)) => s.clone(),
        _ => return None,
    };
    let counts = match row.get("counts") {
        Some(TypedValue::Blob(b)) => b.clone(),
        _ => return None,
    };
    let document_count = match row.get("doc_count") {
        Some(TypedValue::Int(i)) => *i as usize,
        _ => return None,
    };
    let vocab_size = match row.get("vocab_size") {
        Some(TypedValue::Int(i)) => *i as usize,
        _ => return None,
    };
    let updated_at_secs = decode_updated_at_secs(row.get("updated_at"))?;
    Some(PersistedCounts {
        model_id,
        model_version,
        counts,
        document_count,
        vocab_size,
        updated_at_secs,
    })
}

/// Decode `updated_at` to epoch seconds, tolerant of `Timestamp(i64)` and `Text`
/// ISO8601 — mirrors `basis_store::decode_trained_at_secs` (same SQLite re-parse
/// caveat). Reuses the basis store's inline civil-date parser.
fn decode_updated_at_secs(value: Option<&TypedValue>) -> Option<i64> {
    match value {
        Some(TypedValue::Timestamp(secs)) => Some(*secs),
        Some(TypedValue::Text(s)) => crate::basis_store::parse_iso8601_utc(s),
        _ => None,
    }
}
