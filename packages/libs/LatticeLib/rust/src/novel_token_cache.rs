// novel_token_cache.rs — Novel-token accumulation cache with submit-and-purge cycle
//
// Port of NovelTokenCache.swift (cookbook §2.2, §2.3, canonical §3 Step 1).
//
// When a token is not in the static word-class table, the word_class path
// returns WordClass::Other (the Rust non-Apple stub — no HMM artifact is
// bundled yet) and records the result here. The cache flushes to the pool at
// exactly POOL_SUBMIT_THRESHOLD (50) entries and drains; entries below the
// threshold are kept indefinitely (canonical §3 Step 1). Flush is
// fire-and-forget: no retry, never on the hot encode path.
//
// The `submitter` closure is injected so tests can assert the drain without a
// network call; the default is a no-op until the pool endpoint is wired
// (cookbook §2.2). This exactly mirrors the Swift default `submitter: { _ in }`.
//
// Process-wide singleton: `SHARED_NOVEL_CACHE` is initialized once via
// `OnceLock`, mirroring Swift's `LatticeLib.sharedNovelCache` static `let`.
// The mutable pending list is guarded by a `Mutex` (Swift uses `NSLock`).
//
// CONFORMANCE NOTE
// The static-table fast path covers all conformance-vector tokens. Novel-token
// recording does not affect the returned `WordClass` and therefore does not
// affect encode/FDC conformance. The accumulation behavior is tested
// separately (novel_token_cache_test.rs / NovelTokenCacheTests.swift).

use std::sync::{Mutex, OnceLock};
use serde::{Deserialize, Serialize};

use crate::word_class::WordClass;

// ─── Pool submit threshold ───────────────────────────────────────────────────

/// The novel-token cache flush trigger (cookbook §9). Pinned constant of the
/// encoder contract — do not change without a new table version and
/// conformance-vector regeneration. Mirrors `NovelTokenCache.poolSubmitThreshold`
/// in Swift (value: 50).
pub const POOL_SUBMIT_THRESHOLD: usize = 50;

// ─── Wire-format types ────────────────────────────────────────────────────────

/// One entry in a pool submission: a token and the tag the tagger assigned it.
/// The `tag` is the uppercase Penn-style form (`"NOUN"` / `"VERB"` / `"OTHER"`)
/// per the wire format (cookbook §2.3). Mirrors `PoolEntry` in Swift.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PoolEntry {
    pub token: String,
    pub tag: String,
}

impl PoolEntry {
    pub fn new(token: impl Into<String>, tag: impl Into<String>) -> Self {
        PoolEntry { token: token.into(), tag: tag.into() }
    }
}

/// The pool submission wire format (cookbook §2.3). The server validates
/// `table_version` against the current shipping table and discards submissions
/// made against a stale table version. Mirrors `PoolSubmission` in Swift
/// (including the snake_case JSON keys defined by `CodingKeys`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PoolSubmission {
    pub table_version: String,
    pub platform: String,
    pub tagger_version: String,
    pub entries: Vec<PoolEntry>,
}

impl PoolSubmission {
    pub fn new(
        table_version: impl Into<String>,
        platform: impl Into<String>,
        tagger_version: impl Into<String>,
        entries: Vec<PoolEntry>,
    ) -> Self {
        PoolSubmission {
            table_version: table_version.into(),
            platform: platform.into(),
            tagger_version: tagger_version.into(),
            entries,
        }
    }
}

// ─── WordClass → Penn tag ────────────────────────────────────────────────────

/// The uppercase Penn-style tag string for the pool wire format (cookbook §2.3).
/// Mirrors `WordClass.poolTag` in Swift: `Noun`→`"NOUN"`, `Verb`→`"VERB"`,
/// `Other`→`"OTHER"`.
pub fn pool_tag(wc: WordClass) -> &'static str {
    match wc {
        WordClass::Noun => "NOUN",
        WordClass::Verb => "VERB",
        WordClass::Other => "OTHER",
    }
}

// ─── Submitter type alias ─────────────────────────────────────────────────────

/// A pool submitter. Fire-and-forget; no retry obligation.
/// Mirrors `NovelTokenCache.Submitter` in Swift (`@Sendable (PoolSubmission) -> Void`).
pub type Submitter = Box<dyn Fn(PoolSubmission) + Send + Sync>;

// ─── NovelTokenCache ──────────────────────────────────────────────────────────

/// The local novel-token accumulation cache with the submit-and-purge cycle
/// (cookbook §2.2). Thread-safe: the mutable pending list is guarded by a
/// `Mutex` (Swift uses `NSLock`). The cache drains when the count reaches
/// `POOL_SUBMIT_THRESHOLD` (50), builds the §2.3 wire payload, and hands it to
/// the injected submitter — fire-and-forget, outside the lock.
///
/// Mirrors `NovelTokenCache` in Swift.
pub struct NovelTokenCache {
    pending: Mutex<Vec<PoolEntry>>,
    table_version: String,
    platform: String,
    tagger_version: String,
    submitter: Submitter,
}

impl NovelTokenCache {
    /// Creates a cache that builds submissions stamped with the given
    /// table version, platform (`"other"` on non-Apple), and tagger version.
    ///
    /// The `submitter` is invoked with the drained submission when the cache
    /// reaches the threshold. Defaults to a no-op until the pool endpoint is
    /// wired (cookbook §2.2). On non-Apple platforms the tagger version is
    /// `"hmm-viterbi-stub-0"`, mirroring Swift's `currentTaggerVersion` for the
    /// `#else` branch.
    pub fn new(
        table_version: impl Into<String>,
        platform: impl Into<String>,
        tagger_version: impl Into<String>,
        submitter: Submitter,
    ) -> Self {
        NovelTokenCache {
            pending: Mutex::new(Vec::new()),
            table_version: table_version.into(),
            platform: platform.into(),
            tagger_version: tagger_version.into(),
            submitter,
        }
    }

    /// Creates a cache with a no-op submitter. Mirrors the Swift default
    /// `submitter: { _ in }`.
    pub fn new_noop(
        table_version: impl Into<String>,
        platform: impl Into<String>,
        tagger_version: impl Into<String>,
    ) -> Self {
        Self::new(table_version, platform, tagger_version, Box::new(|_| {}))
    }

    /// Records a tagged novel token. When the count reaches
    /// `POOL_SUBMIT_THRESHOLD` (50), the cache builds the §2.3 wire payload,
    /// drains, and hands the payload to the injected submitter — exactly at 50,
    /// not before. Submit happens outside the lock (fire-and-forget).
    ///
    /// Mirrors `NovelTokenCache.record(token:wordClass:)` in Swift.
    pub fn record(&self, token: &str, word_class: WordClass) {
        let submission = {
            let mut pending = self.pending.lock().unwrap();
            pending.push(PoolEntry::new(token, pool_tag(word_class)));
            if pending.len() >= POOL_SUBMIT_THRESHOLD {
                let entries = std::mem::replace(&mut *pending, Vec::new());
                Some(PoolSubmission::new(
                    &self.table_version,
                    &self.platform,
                    &self.tagger_version,
                    entries,
                ))
            } else {
                None
            }
        };
        // Submit outside the lock: fire-and-forget, off the caller's critical
        // section. Mirrors the Swift implementation which calls submitter(submission)
        // after lock.unlock().
        if let Some(s) = submission {
            (self.submitter)(s);
        }
    }

    /// The number of entries currently held below the threshold.
    /// Mirrors `NovelTokenCache.count` in Swift.
    pub fn count(&self) -> usize {
        self.pending.lock().unwrap().len()
    }
}

// ─── Process-wide singleton ───────────────────────────────────────────────────

/// The process-wide novel-token accumulation cache wired into the fallback path
/// (cookbook §2.2). Stamped with the bundled table version, the platform
/// string, and the tagger version. Uses the no-op submitter until the pool
/// endpoint is wired.
///
/// Mirrors `LatticeLib.sharedNovelCache` (Swift static `let`) in
/// `WordClassTagger.swift`. On non-Apple platforms (the only Rust target):
/// - platform = `"other"` (mirrors Swift `currentPlatform` `#else` branch)
/// - tagger_version = `"hmm-viterbi-stub-0"` (mirrors Swift
///   `currentTaggerVersion` `#else` branch and the comment "Mirrors the Rust
///   port's HMM_VITERBI_VERSION" in `WordClassTagger.swift`)
pub static SHARED_NOVEL_CACHE: OnceLock<NovelTokenCache> = OnceLock::new();

/// Initialize the process-wide cache. Must be called once before `word_class`
/// is invoked on novel tokens. The runtime (`fdc_runtime.rs`) calls this when
/// loading the bundled artifacts so the table version is available.
///
/// If called more than once, the second and subsequent calls are no-ops
/// (OnceLock contract). Mirroring Swift's `sharedNovelCache` static let which
/// reads `WordClassTableCache.table?.tableVersion ?? ""` at initialization.
pub(crate) fn init_shared_cache(table_version: &str) {
    SHARED_NOVEL_CACHE.get_or_init(|| {
        NovelTokenCache::new_noop(
            table_version,
            "other",          // mirrors Swift currentPlatform #else branch
            "hmm-viterbi-stub-0", // mirrors Swift currentTaggerVersion #else branch
        )
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex as StdMutex};

    // ─── PoolEntry ────────────────────────────────────────────────────────────

    #[test]
    fn pool_entry_fields_stored_correctly() {
        let e = PoolEntry::new("running", "VERB");
        assert_eq!(e.token, "running");
        assert_eq!(e.tag, "VERB");
    }

    #[test]
    fn pool_entry_equality() {
        let a = PoolEntry::new("dog", "NOUN");
        let b = PoolEntry::new("dog", "NOUN");
        assert_eq!(a, b);
        let c = PoolEntry::new("cat", "NOUN");
        assert_ne!(a, c);
    }

    // ─── PoolSubmission ───────────────────────────────────────────────────────

    #[test]
    fn pool_submission_fields_stored_correctly() {
        let entries = vec![PoolEntry::new("dog", "NOUN")];
        let s = PoolSubmission::new("v1.0", "other", "hmm-viterbi-stub-0", entries.clone());
        assert_eq!(s.table_version, "v1.0");
        assert_eq!(s.platform, "other");
        assert_eq!(s.tagger_version, "hmm-viterbi-stub-0");
        assert_eq!(s.entries, entries);
    }

    #[test]
    fn pool_submission_json_round_trip_uses_snake_case_keys() {
        // Verifies that the wire format uses snake_case keys matching
        // Swift's PoolSubmission.CodingKeys (table_version, tagger_version).
        let entries = vec![PoolEntry::new("run", "VERB")];
        let sub = PoolSubmission::new("v1.0", "other", "hmm-viterbi-stub-0", entries);
        let json = serde_json::to_string(&sub).unwrap();
        assert!(json.contains("\"table_version\""), "json must contain table_version key");
        assert!(json.contains("\"tagger_version\""), "json must contain tagger_version key");
        let back: PoolSubmission = serde_json::from_str(&json).unwrap();
        assert_eq!(back.table_version, "v1.0");
    }

    // ─── pool_tag ─────────────────────────────────────────────────────────────

    #[test]
    fn pool_tag_maps_noun_to_uppercase_noun() {
        assert_eq!(pool_tag(WordClass::Noun), "NOUN");
    }

    #[test]
    fn pool_tag_maps_verb_to_uppercase_verb() {
        assert_eq!(pool_tag(WordClass::Verb), "VERB");
    }

    #[test]
    fn pool_tag_maps_other_to_uppercase_other() {
        assert_eq!(pool_tag(WordClass::Other), "OTHER");
    }

    // ─── NovelTokenCache — accumulation below threshold ───────────────────────

    #[test]
    fn cache_count_is_zero_on_init() {
        let cache = NovelTokenCache::new_noop("v1", "other", "hmm-viterbi-stub-0");
        assert_eq!(cache.count(), 0);
    }

    #[test]
    fn cache_accumulates_below_threshold_without_submitting() {
        let submitted: Arc<StdMutex<Vec<PoolSubmission>>> = Arc::new(StdMutex::new(Vec::new()));
        let submitted_clone = submitted.clone();
        let cache = NovelTokenCache::new(
            "v1", "other", "hmm-viterbi-stub-0",
            Box::new(move |s| { submitted_clone.lock().unwrap().push(s); }),
        );
        // Record 49 tokens — one below the threshold.
        for i in 0..49 {
            cache.record(&format!("noveltoken{}", i), WordClass::Other);
        }
        assert_eq!(cache.count(), 49);
        assert_eq!(submitted.lock().unwrap().len(), 0, "no submission before threshold");
    }

    // ─── NovelTokenCache — drain at exactly 50 ────────────────────────────────

    #[test]
    fn cache_drains_at_pool_submit_threshold() {
        let submitted: Arc<StdMutex<Vec<PoolSubmission>>> = Arc::new(StdMutex::new(Vec::new()));
        let submitted_clone = submitted.clone();
        let cache = NovelTokenCache::new(
            "v1.0", "other", "hmm-viterbi-stub-0",
            Box::new(move |s| { submitted_clone.lock().unwrap().push(s); }),
        );
        for i in 0..POOL_SUBMIT_THRESHOLD {
            cache.record(&format!("token{}", i), WordClass::Other);
        }
        // After exactly 50 records: pending is empty (drained), submitter called once.
        assert_eq!(cache.count(), 0, "pending must drain after threshold");
        let subs = submitted.lock().unwrap();
        assert_eq!(subs.len(), 1, "submitter must be called exactly once at threshold");
        assert_eq!(subs[0].entries.len(), POOL_SUBMIT_THRESHOLD);
    }

    #[test]
    fn submission_carries_correct_metadata() {
        let submitted: Arc<StdMutex<Vec<PoolSubmission>>> = Arc::new(StdMutex::new(Vec::new()));
        let submitted_clone = submitted.clone();
        let cache = NovelTokenCache::new(
            "v2.0", "other", "hmm-viterbi-stub-0",
            Box::new(move |s| { submitted_clone.lock().unwrap().push(s); }),
        );
        for i in 0..POOL_SUBMIT_THRESHOLD {
            cache.record(&format!("w{}", i), WordClass::Verb);
        }
        let subs = submitted.lock().unwrap();
        assert_eq!(subs[0].table_version, "v2.0");
        assert_eq!(subs[0].platform, "other");
        assert_eq!(subs[0].tagger_version, "hmm-viterbi-stub-0");
        // Every entry should carry the VERB tag.
        assert!(subs[0].entries.iter().all(|e| e.tag == "VERB"));
    }

    #[test]
    fn cache_resets_and_accumulates_again_after_drain() {
        // After one flush at 50, the cache should accept new entries and flush again.
        let submitted: Arc<StdMutex<Vec<PoolSubmission>>> = Arc::new(StdMutex::new(Vec::new()));
        let submitted_clone = submitted.clone();
        let cache = NovelTokenCache::new(
            "v1", "other", "hmm-viterbi-stub-0",
            Box::new(move |s| { submitted_clone.lock().unwrap().push(s); }),
        );
        for i in 0..POOL_SUBMIT_THRESHOLD {
            cache.record(&format!("batch1_{}", i), WordClass::Noun);
        }
        assert_eq!(submitted.lock().unwrap().len(), 1);
        assert_eq!(cache.count(), 0);
        // Second batch.
        for i in 0..POOL_SUBMIT_THRESHOLD {
            cache.record(&format!("batch2_{}", i), WordClass::Other);
        }
        assert_eq!(submitted.lock().unwrap().len(), 2);
        assert_eq!(cache.count(), 0);
    }

    #[test]
    fn entries_below_threshold_are_preserved_across_records() {
        // Records below threshold persist until the threshold is hit.
        let submitted: Arc<StdMutex<Vec<PoolSubmission>>> = Arc::new(StdMutex::new(Vec::new()));
        let submitted_clone = submitted.clone();
        let cache = NovelTokenCache::new(
            "v1", "other", "hmm-viterbi-stub-0",
            Box::new(move |s| { submitted_clone.lock().unwrap().push(s); }),
        );
        cache.record("alpha", WordClass::Noun);
        cache.record("beta", WordClass::Verb);
        assert_eq!(cache.count(), 2);
        // Fill up to threshold with remaining entries.
        for i in 0..(POOL_SUBMIT_THRESHOLD - 2) {
            cache.record(&format!("filler{}", i), WordClass::Other);
        }
        let subs = submitted.lock().unwrap();
        assert_eq!(subs.len(), 1);
        // The first two entries in the submission must be alpha/beta in order.
        assert_eq!(subs[0].entries[0].token, "alpha");
        assert_eq!(subs[0].entries[0].tag, "NOUN");
        assert_eq!(subs[0].entries[1].token, "beta");
        assert_eq!(subs[0].entries[1].tag, "VERB");
    }

    #[test]
    fn threshold_constant_is_50() {
        // POOL_SUBMIT_THRESHOLD is a pinned encoder-contract constant.
        assert_eq!(POOL_SUBMIT_THRESHOLD, 50);
    }
}
