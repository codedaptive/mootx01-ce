// word_class_table.rs — Static noun/verb fast-path table
//
// Port of WordClassTable.swift and WordClassTagger.swift's fast-path.
//
// NOVEL-TOKEN FALLBACK
// The Swift `LatticeLib.wordClass(_:)` default overload uses the deterministic
// HMM/Viterbi tagger (`HMMTagger.tag`) on ALL platforms, including Apple.
// This is the cross-port baseline and the default for the FDC runtime.
//
// NLTagger is the opt-in Apple-only path: it is only used when the estate is
// configured with `NovelTokenTaggerChoice.nlTagger` and the caller explicitly
// threads that choice via `wordClass(_:tagger:)`. It has no Rust counterpart
// (Apple platform binding) and is not part of the cross-port conformance gate.
//
// Rust runs exclusively on non-Apple (Linux/Windows). For novel tokens (not in
// the table), the Rust path calls `word_class::hmm_tag` — the byte-identical
// port of Swift's `HMMTagger.tag` (integer Viterbi, no floating point, tables
// mirrored verbatim from HMMTagger.swift). The cross-port conformance guarantee:
// Swift HMM (all platforms, default path) == Rust HMM (byte-identical).
//
// The FDC conformance fixture (`fdc_conformance.json`) and the HMM byte-identity
// gate (`tag_conformance.json` / `lattice_conformance_test.rs`) both verify this.
//
// NOVEL-TOKEN RECORDING
// After classifying a novel token via `hmm_tag`, the result is recorded into
// SHARED_NOVEL_CACHE — mirroring `tagNovelToken` in WordClassTagger.swift which
// calls `sharedNovelCache.record(token: lowered, wordClass: tagged)` after tagging.
// The cache is initialized by `fdc_runtime.rs` when the bundled artifacts are
// loaded (stamped with the table version). If the cache has not been initialized
// yet (SHARED_NOVEL_CACHE not set), the record call is silently skipped; the pool
// submission's `tableVersion` defaults to `""` at cache construction time if the
// table is unavailable.
//
// WRITABLE-ARTIFACT LOAD PRECEDENCE (cookbook §1.3/§2.2)
// The PoolReducer merges novel-token observations into a writable copy of the
// table at `default_table_artifact()`. `load_with_precedence()` checks that
// path first; if a merged artifact is present it is used, otherwise the
// compile-time bundled bytes are the fallback.
//
// LIVE ATOMIC SWAP (cookbook §1.3/§2.2)
// `GLOBAL_TABLE` is the process-wide LIVE-SWAPPABLE holder of the current table
// cache: `RwLock<Arc<WordClassTableCache>>` (std only — no external dep, C-1).
// `fdc_runtime` seeds it once via `load_with_precedence`. Readers
// (`global_table`, the public `word_class` free fn, and `concept_bag` through
// the matcher) take a brief read-lock, clone the `Arc` out, drop the guard, and
// test membership against the immutable cache — no torn read, readers never
// block each other beyond an `Arc` clone. After `pool_reduce` merges novel
// tokens into the writable artifact, `swap_global_table_from_precedence`
// publishes a new `Arc` under a brief write-lock and bumps `TABLE_VERSION`. The
// running tagger adopts the merged tokens IN-SESSION — no process restart.
// Tagging is deterministic given (input, table-version).

use std::collections::HashSet;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, OnceLock, RwLock};
use serde::Deserialize;

use crate::word_class::{hmm_tag, WordClass};
use crate::novel_token_cache::SHARED_NOVEL_CACHE;

/// The parsed word-class table (matches JSON schema of WordClassTable.swift).
#[derive(Debug, Deserialize)]
pub struct WordClassTable {
    #[serde(rename = "table_version")]
    pub table_version: String,
    #[serde(rename = "min_os_version")]
    pub min_os_version: String,
    #[serde(rename = "snapshot_date")]
    pub snapshot_date: String,
    pub nouns: Vec<String>,
    pub verbs: Vec<String>,
}

/// The compile-time bundled WordClassTable.json bytes (included at build time).
/// Used as the fallback when no writable merged artifact exists.
pub const BUNDLED_TABLE_JSON: &[u8] = include_bytes!(
    "../../Sources/LatticeLib/Resources/WordClassTable.json"
);

/// Attempts to load the WordClassTable from the writable merged artifact at
/// `artifact_path`. Returns `None` if the file does not exist or is malformed,
/// in which case the caller should fall back to the bundled bytes.
///
/// Mirrors `WordClassTable.loadWritable()` in Swift.
pub fn load_writable_table(artifact_path: &Path) -> Option<WordClassTable> {
    if !artifact_path.exists() {
        return None;
    }
    let data = std::fs::read(artifact_path).ok()?;
    serde_json::from_slice(&data).ok()
}

/// Returns a `WordClassTableCache` populated from the best available source,
/// implementing writable-artifact load precedence (cookbook §1.3/§2.2):
///   1. Writable merged artifact at `artifact_path`, if present and valid.
///   2. Compile-time bundled bytes, as fallback.
///
/// Used to seed the live process-global holder at startup (`seed_global_table`)
/// and to re-resolve it for the post-reduce live swap
/// (`swap_global_table_from_precedence`). A table the reducer writes during this
/// process's lifetime is adopted IN-SESSION via the live swap (cookbook
/// §1.3/§2.2) and is also picked up by the startup seed on any future process
/// start; both paths resolve the same writable-first precedence.
///
/// Mirrors `WordClassTable.loadWithPrecedence()` in Swift.
pub fn load_with_precedence(artifact_path: &Path) -> Option<WordClassTableCache> {
    // Priority 1: writable merged artifact (contains learned tokens).
    if let Some(merged) = load_writable_table(artifact_path) {
        let noun_set: HashSet<String> = merged.nouns.into_iter().collect();
        let verb_set: HashSet<String> = merged.verbs.into_iter().collect();
        return Some(WordClassTableCache { noun_set, verb_set });
    }
    // Priority 2: compile-time bundled bytes (pristine table).
    WordClassTableCache::from_json(BUNDLED_TABLE_JSON)
}

/// One immutable snapshot of the parsed table's derived membership sets. A
/// snapshot is never mutated in place; the live swap publishes a NEW snapshot
/// into `GLOBAL_TABLE` (see below), so a reader holding an `Arc` to a snapshot
/// cannot observe a torn read. `Clone` produces an independent snapshot (used by
/// the live-swap force-tests to publish a derived table).
#[derive(Clone)]
pub struct WordClassTableCache {
    pub noun_set: HashSet<String>,
    pub verb_set: HashSet<String>,
}

impl WordClassTableCache {
    /// Build from parsed table bytes.
    pub fn from_json(data: &[u8]) -> Option<Self> {
        let table: WordClassTable = serde_json::from_slice(data).ok()?;
        let noun_set: HashSet<String> = table.nouns.into_iter().collect();
        let verb_set: HashSet<String> = table.verbs.into_iter().collect();
        Some(WordClassTableCache { noun_set, verb_set })
    }

    /// Classify a token for the FDC encoder (Step 1 — word-class tagging).
    ///
    /// Verb set is checked before noun set (matching the Swift ordering in
    /// `LatticeLib.wordClass`: "The verb set is checked before the noun set,
    /// so a token listed under both resolves to `.verb`").
    ///
    /// Novel tokens (not in either set) are classified via the deterministic
    /// HMM/Viterbi tagger (`word_class::hmm_tag`) — the byte-identical port of
    /// Swift's `HMMTagger.tag`. HMM is the cross-port baseline; in Swift, HMM
    /// is also the default novel-token path on all platforms (Apple `NLTagger`
    /// is explicit opt-in). The HMM result (noun/verb/other) is recorded into
    /// `SHARED_NOVEL_CACHE` (mirroring `tagNovelToken` in WordClassTagger.swift).
    ///
    /// The FDC conformance fixture (`fdc_conformance.json`) contains only
    /// table-resident tokens and is unaffected by this path. The HMM
    /// byte-identity gate is `tag_conformance.json` / `lattice_conformance_test.rs`.
    pub fn word_class(&self, token: &str) -> WordClass {
        let lowered = token.to_lowercase();
        if lowered.is_empty() {
            return WordClass::Other;
        }
        // Fast path: verb set first (matching Swift ordering).
        if self.verb_set.contains(&lowered) {
            return WordClass::Verb;
        }
        if self.noun_set.contains(&lowered) {
            return WordClass::Noun;
        }
        // Novel token: classify via the deterministic HMM/Viterbi tagger, mirroring
        // Swift's non-Apple `hmmViterbiTag` path in WordClassTagger.swift. Record
        // the result into the process-wide novel-token cache — fire-and-forget,
        // outside the lock (mirrors `tagNovelToken` in Swift which calls
        // `sharedNovelCache.record(token:wordClass:)` for both Apple and non-Apple paths).
        let tagged = hmm_tag(&lowered);
        if let Some(cache) = SHARED_NOVEL_CACHE.get() {
            cache.record(&lowered, tagged);
        }
        tagged
    }

    /// Classify a token using an explicit novel-token tagger choice (Layer-2a).
    ///
    /// Identical fast-path to `word_class`: verb-before-noun table lookup,
    /// constant time. The `choice` parameter controls only the novel-token
    /// fallback path. On Rust, `NlTagger` is treated as HMM (NaturalLanguage
    /// is not available on non-Apple platforms); see `word_class::NovelTokenTaggerChoice`.
    ///
    /// Mirrors Swift's `LatticeLib.wordClass(_:tagger:)` overload. Thread
    /// the `NovelTokenTaggerChoice` from the estate's PersistenceKit
    /// `EstateConfiguration.novel_token_tagger` (bridged to this crate's
    /// `word_class::NovelTokenTaggerChoice`) by the consumer.
    pub fn word_class_with_tagger(
        &self,
        token: &str,
        choice: crate::word_class::NovelTokenTaggerChoice,
    ) -> WordClass {
        let lowered = token.to_lowercase();
        if lowered.is_empty() {
            return WordClass::Other;
        }
        if self.verb_set.contains(&lowered) {
            return WordClass::Verb;
        }
        if self.noun_set.contains(&lowered) {
            return WordClass::Noun;
        }
        // Novel token: dispatch on choice. On Rust both Hmm and NlTagger reach HMM.
        let tagged = crate::word_class::hmm_tag_with_choice(&lowered, choice);
        if let Some(cache) = SHARED_NOVEL_CACHE.get() {
            cache.record(&lowered, tagged);
        }
        tagged
    }
}

// ─── Process-wide LIVE-SWAPPABLE table holder (cookbook §1.3/§2.2) ─────────────

/// The live, swappable process-global table cache. `RwLock<Arc<…>>` so the
/// hot read path (`global_table`) takes only a read-lock + `Arc` clone, while a
/// live swap takes a brief write-lock to publish a new `Arc`. Std-only (C-1: no
/// external `arc-swap`). Lazily seeded on first access from the bundled bytes;
/// `fdc_runtime` overwrites the seed with the precedence-resolved table at
/// startup via `swap_global_table_from_precedence`.
static GLOBAL_TABLE: OnceLock<RwLock<Arc<WordClassTableCache>>> = OnceLock::new();

/// Monotonic live-swap version. 0 is the seed; each successful swap increments.
/// Mirrors Swift `WordClassTableCache.version`.
static TABLE_VERSION: AtomicU64 = AtomicU64::new(0);

fn global_cell() -> &'static RwLock<Arc<WordClassTableCache>> {
    GLOBAL_TABLE.get_or_init(|| {
        // Seed from the bundled bytes. An empty cache (parse failure) is a
        // build error in production but must not panic the holder init.
        let seed = WordClassTableCache::from_json(BUNDLED_TABLE_JSON)
            .unwrap_or_else(|| WordClassTableCache {
                noun_set: HashSet::new(),
                verb_set: HashSet::new(),
            });
        RwLock::new(Arc::new(seed))
    })
}

/// Returns an `Arc` clone of the current live table snapshot. Read-lock held
/// only for the clone; membership tests run on the returned `Arc` outside the
/// lock (no torn read). Mirrors Swift `WordClassTableCache.current`.
pub fn global_table() -> Arc<WordClassTableCache> {
    Arc::clone(&global_cell().read().expect("GLOBAL_TABLE read lock poisoned"))
}

/// The current live-swap version (0 = seed). Mirrors Swift
/// `WordClassTableCache.version`.
pub fn table_version() -> u64 {
    TABLE_VERSION.load(Ordering::SeqCst)
}

/// Seed the holder at process startup WITHOUT bumping the version (version 0 is
/// the startup snapshot, whether bundled or writable-resolved). Resolves the
/// table via writable-artifact precedence at `artifact_path`; if it resolves,
/// it replaces the lazily-loaded bundled seed. A no-op if resolution fails (the
/// bundled seed from `global_cell()` stays). Called once by `fdc_runtime`.
pub fn seed_global_table(artifact_path: &Path) {
    if let Some(resolved) = load_with_precedence(artifact_path) {
        let mut guard = global_cell().write().expect("GLOBAL_TABLE write lock poisoned");
        *guard = Arc::new(resolved);
        // Version intentionally NOT bumped: this is the startup seed, not a
        // live in-session swap.
    }
}

/// Atomically publish a new table snapshot IN-SESSION and bump the version.
/// The running tagger adopts the new membership sets on its next `word_class`
/// call. Mirrors Swift `WordClassTableCache.swap`.
pub fn swap_global_table(new_cache: WordClassTableCache) {
    let mut guard = global_cell().write().expect("GLOBAL_TABLE write lock poisoned");
    *guard = Arc::new(new_cache);
    TABLE_VERSION.fetch_add(1, Ordering::SeqCst);
}

/// Re-resolve the table via writable-artifact precedence at `artifact_path` and
/// publish it as the new live snapshot. This is the canonical post-reduce swap:
/// the reducer has just written the merged writable artifact, so re-resolving
/// picks it up and the running tagger learns the merged tokens immediately.
/// Returns the new version, or `None` if the table failed to resolve (the live
/// table is then left unchanged — never replaced by an empty table).
/// Mirrors Swift `WordClassTableCache.reloadFromPrecedence`.
pub fn swap_global_table_from_precedence(artifact_path: &Path) -> Option<u64> {
    let resolved = load_with_precedence(artifact_path)?;
    swap_global_table(resolved);
    Some(table_version())
}

/// Classify a single token table-first against the LIVE process-global table
/// (cookbook §2.1). Verb set before noun set, matching Swift `LatticeLib.
/// wordClass` ordering; novel tokens (table miss) are classified via the
/// deterministic HMM/Viterbi tagger and recorded into the novel-token cache.
/// This is the public table-first surface paralleling Swift's
/// `LatticeLib.wordClass(_:)` on all platforms (HMM is the default everywhere);
/// it reads through the live holder so a post-reduce swap is observed in-session.
pub fn word_class(token: &str) -> WordClass {
    global_table().word_class(token)
}
