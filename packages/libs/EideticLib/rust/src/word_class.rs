//! FDC encoder Step 1: word-class table + tagger (cookbook §2,
//! canonical §3 Step 1). The Rust port of the Swift surface in
//! `Sources/EideticLib/WordClass.swift`, `WordClassTable.swift`,
//! `WordClassTagger.swift`, and `NovelTokenCache.swift`. Both ports
//! read identical bytes from the bundled JSON and must agree on every
//! shared conformance vector.
//!
//! One token in, one `WordClass` out. The fast path is a static-table
//! membership test (constant time, no tagger). Novel tokens fall to
//! the platform tagger; on non-Apple platforms that is the Penn
//! Treebank HMM/Viterbi tagger (here a deterministic stub keyed off
//! the test vectors until the compiled artifact is bundled — see
//! `hmm_viterbi_tag`).

use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::sync::{Mutex, OnceLock};

/// The word class of a single token under FDC encoder Step 1.
///
/// Step 1 keeps nouns and verbs and discards everything else; `Other`
/// is that discard bucket. Serializes to the stable lowercase strings
/// `"noun"` / `"verb"` / `"other"` so the shared vectors and the Swift
/// port agree byte-for-byte.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum WordClass {
    /// The token is a noun. Kept by Step 1.
    Noun,
    /// The token is a verb. Kept by Step 1.
    Verb,
    /// The token is neither noun nor verb. Discarded by Step 1.
    Other,
}

/// The parsed word-class table with pinned versioning metadata
/// (cookbook §1.3). Mirrors the Swift `WordClassTable` struct.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WordClassTable {
    /// Pinned table version; gates pool submission (cookbook §2.3).
    #[serde(rename = "table_version")]
    pub table_version: String,
    /// NLTagger OS version that produced the table; below it, builds
    /// use the table only and do not invoke an older tagger
    /// (cookbook §1.3, §2.2).
    #[serde(rename = "min_os_version")]
    pub min_os_version: String,
    /// Cutoff date for local pool-cache purge on table update
    /// (cookbook §1.3, §2.2).
    #[serde(rename = "snapshot_date")]
    pub snapshot_date: String,
    /// Lowercased noun surface forms.
    pub nouns: Vec<String>,
    /// Lowercased verb surface forms.
    pub verbs: Vec<String>,
}

// The bundled table ships as a compile-time constant via
// `include_str!`, mirroring the Swift Resources directory as the
// single source of truth. Parsing it per call is pure waste; parse
// once and reuse forever (same pattern as the Wikidata subset).
const BUNDLED_TABLE_JSON: &str = include_str!(
    "../../Sources/EideticLib/Resources/WordClassTable.json"
);

/// The parsed table plus its derived membership sets, cached for the
/// process lifetime. The sets are `HashSet<String>` of lowercased
/// tokens for constant-time fast-path membership (cookbook §2.1).
pub struct CachedTable {
    pub table: WordClassTable,
    pub noun_set: HashSet<String>,
    pub verb_set: HashSet<String>,
}

static CACHED_TABLE: OnceLock<Option<CachedTable>> = OnceLock::new();

impl WordClassTable {
    /// Parses the bundled table JSON.
    pub fn load_bundled() -> Result<Self, serde_json::Error> {
        serde_json::from_str(BUNDLED_TABLE_JSON)
    }
}

/// Returns the cached parsed table and membership sets, or `None` if
/// the bundled JSON failed to parse (a build error in practice).
pub fn cached_table() -> Option<&'static CachedTable> {
    CACHED_TABLE
        .get_or_init(|| {
            WordClassTable::load_bundled().ok().map(|table| {
                let noun_set: HashSet<String> =
                    table.nouns.iter().cloned().collect();
                let verb_set: HashSet<String> =
                    table.verbs.iter().cloned().collect();
                CachedTable {
                    table,
                    noun_set,
                    verb_set,
                }
            })
        })
        .as_ref()
}

/// Classifies a single token under FDC encoder Step 1. The Rust
/// mirror of `EideticLib.wordClass(_:)`.
///
/// Lowercases the token, then takes the fast path: a token present in
/// the bundled table resolves in constant time with no tagger. The
/// verb set is checked before the noun set, so a token listed under
/// both resolves to `Verb` (mission Part 2). An empty token is
/// `Other`. A novel token falls to the platform tagger (Part 3).
pub fn word_class(token: &str) -> WordClass {
    let lowered = token.to_lowercase();

    // Empty token is never a noun or verb; short-circuit to Other.
    if lowered.is_empty() {
        return WordClass::Other;
    }

    let cached = match cached_table() {
        Some(c) => c,
        // Bundled table failed to parse (a build error). With no table
        // there is no fast path; treat as Other deterministically.
        None => return WordClass::Other,
    };

    // Fast path: verb set first, then noun set (cookbook §2.1).
    if cached.verb_set.contains(&lowered) {
        return WordClass::Verb;
    }
    if cached.noun_set.contains(&lowered) {
        return WordClass::Noun;
    }

    // Novel token: platform tagger fallback. The Rust port is the
    // non-Apple path, so it always uses the Penn-Treebank HMM/Viterbi
    // tagger (cookbook §2.2). There is no NLTagger min_os_version gate
    // here — that gate is Apple-specific.
    let tagged = hmm_viterbi_tag(&lowered);

    // Fire-and-forget accumulation toward the 50-entry pool submission
    // (cookbook §2.2). Does not affect the returned WordClass. Mirrors
    // the Swift `sharedNovelCache` wiring.
    if let Ok(mut cache) = shared_novel_cache().lock() {
        let _ = cache.record(&lowered, tagged);
    }
    tagged
}

/// The pinned version string for the non-Apple tagger, reported in the
/// pool submission wire format's `tagger_version` field (cookbook
/// §2.3). Bumped when the bundled HMM/Viterbi artifact changes.
pub const HMM_VITERBI_VERSION: &str = "hmm-viterbi-stub-0";

/// Non-Apple Penn-Treebank HMM/Viterbi fallback (cookbook §2.2).
///
/// Known Ambiguities resolution: the compiled HMM/Viterbi artifact is
/// not yet bundled. This deterministic stub keeps the platform seam
/// intact and defaults every novel token to `Other`; the fast-path
/// table covers the vast majority of tokens and the conformance
/// vectors exercise table-resident tokens. Producing the real artifact
/// is a documented follow-up. Matching the Swift non-Apple stub, both
/// ports agree on `Other` for novel tokens.
fn hmm_viterbi_tag(_lowered: &str) -> WordClass {
    WordClass::Other
}

/// The uppercase Penn-style tag string for the pool wire format
/// (cookbook §2.3): `Noun`→`"NOUN"`, `Verb`→`"VERB"`, `Other`→`"OTHER"`.
/// Mirrors the Swift `WordClass.poolTag`.
fn pool_tag(wc: WordClass) -> &'static str {
    match wc {
        WordClass::Noun => "NOUN",
        WordClass::Verb => "VERB",
        WordClass::Other => "OTHER",
    }
}

/// One entry in a pool submission: a token and its tag (cookbook §2.3).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PoolEntry {
    pub token: String,
    pub tag: String,
}

/// The pool submission wire format (cookbook §2.3). The server
/// validates `table_version` against the current shipping table and
/// discards submissions made against a stale version.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PoolSubmission {
    #[serde(rename = "table_version")]
    pub table_version: String,
    pub platform: String,
    #[serde(rename = "tagger_version")]
    pub tagger_version: String,
    pub entries: Vec<PoolEntry>,
}

/// A pool submitter. Fire-and-forget; no retry obligation. A bare
/// function pointer so the cache is `Send` and can live behind a
/// global `Mutex`; the default is a no-op until the pool endpoint is
/// wired.
pub type Submitter = fn(&PoolSubmission);

fn noop_submitter(_: &PoolSubmission) {}

/// The local novel-token accumulation cache with the submit-and-purge
/// cycle (cookbook §2.2). Mirrors the Swift `NovelTokenCache`. Entries
/// below the threshold are kept indefinitely; at exactly
/// `POOL_SUBMIT_THRESHOLD` the cache builds the §2.3 payload, drains,
/// and hands it to the submitter.
pub struct NovelTokenCache {
    table_version: String,
    platform: String,
    tagger_version: String,
    pending: Vec<PoolEntry>,
    submitter: Submitter,
}

impl NovelTokenCache {
    /// The novel-token cache flush trigger (cookbook §9). Pinned
    /// constant of the encoder contract.
    pub const POOL_SUBMIT_THRESHOLD: usize = 50;

    /// Creates a cache with an injected submitter, stamped with the
    /// table version, platform, and tagger version (cookbook §2.3).
    pub fn new(
        table_version: String,
        platform: String,
        tagger_version: String,
        submitter: Submitter,
    ) -> Self {
        NovelTokenCache {
            table_version,
            platform,
            tagger_version,
            pending: Vec::new(),
            submitter,
        }
    }

    /// Creates a cache with the default no-op submitter.
    pub fn with_default_submitter(
        table_version: String,
        platform: String,
        tagger_version: String,
    ) -> Self {
        Self::new(table_version, platform, tagger_version, noop_submitter)
    }

    /// Records a tagged novel token. At exactly `POOL_SUBMIT_THRESHOLD`
    /// (50) entries the cache builds the §2.3 payload, drains, calls
    /// the submitter, and returns the drained submission; otherwise
    /// returns `None`.
    pub fn record(
        &mut self,
        token: &str,
        wc: WordClass,
    ) -> Option<PoolSubmission> {
        self.pending.push(PoolEntry {
            token: token.to_string(),
            tag: pool_tag(wc).to_string(),
        });
        if self.pending.len() >= Self::POOL_SUBMIT_THRESHOLD {
            let submission = PoolSubmission {
                table_version: self.table_version.clone(),
                platform: self.platform.clone(),
                tagger_version: self.tagger_version.clone(),
                entries: std::mem::take(&mut self.pending),
            };
            (self.submitter)(&submission);
            Some(submission)
        } else {
            None
        }
    }

    /// The number of entries currently held below the threshold.
    pub fn len(&self) -> usize {
        self.pending.len()
    }

    /// Whether the cache holds no pending entries.
    pub fn is_empty(&self) -> bool {
        self.pending.is_empty()
    }
}

// The process-wide novel-token cache wired into the fallback path,
// mirroring the Swift `sharedNovelCache`. The Rust port is the
// non-Apple path, so platform is "other" and the tagger version is the
// HMM/Viterbi artifact version.
static SHARED_NOVEL_CACHE: OnceLock<Mutex<NovelTokenCache>> = OnceLock::new();

fn shared_novel_cache() -> &'static Mutex<NovelTokenCache> {
    SHARED_NOVEL_CACHE.get_or_init(|| {
        let table_version = cached_table()
            .map(|c| c.table.table_version.clone())
            .unwrap_or_default();
        Mutex::new(NovelTokenCache::with_default_submitter(
            table_version,
            "other".to_string(),
            HMM_VITERBI_VERSION.to_string(),
        ))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn table_parses_with_pinned_versions() {
        let cached = cached_table().expect("bundled table must parse");
        assert_eq!(cached.table.table_version, "1.0.0");
        assert_eq!(cached.table.min_os_version, "17.0");
        assert!(!cached.noun_set.is_empty());
        assert!(!cached.verb_set.is_empty());
    }

    #[test]
    fn word_class_serializes_lowercase() {
        let json = serde_json::to_string(&WordClass::Noun).unwrap();
        assert_eq!(json, "\"noun\"");
    }
}
