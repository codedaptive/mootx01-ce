// migration/mod.rs — Rust mirror of GeniusLocusKit's migration API.
//
// Currently ships ExternalCorpus and ExternalEntry, mirroring the
// Swift types in Migration/ExternalCorpus.swift. The hybrid_recall
// method routes through CorpusKit's Corpus struct, mirroring Swift's
// ExternalCorpus.hybridRecall(via:limit:now:).

use corpus_kit::{Corpus, CorpusKitResult, ScoredChunk};

/// A single entry in an external reference corpus used for migration
/// benchmarking. Mirrors Swift's `ExternalEntry`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExternalEntry {
    /// Stable identifier from the source system.
    pub id: String,
    /// Verbatim text — the basis for the derived recall query.
    pub content: String,
    /// Classification tags carried from the source system.
    pub tags: Vec<String>,
}

impl ExternalEntry {
    pub fn new(
        id: impl Into<String>,
        content: impl Into<String>,
        tags: Vec<String>,
    ) -> Self {
        ExternalEntry {
            id: id.into(),
            content: content.into(),
            tags,
        }
    }
}

/// An external corpus for benchmark comparison. Mirrors Swift's
/// `ExternalCorpus`.
#[derive(Debug, Clone)]
pub struct ExternalCorpus {
    /// Human-readable corpus name.
    pub name: String,
    /// The reference entries.
    pub entries: Vec<ExternalEntry>,
}

impl ExternalCorpus {
    pub fn new(name: impl Into<String>, entries: Vec<ExternalEntry>) -> Self {
        ExternalCorpus {
            name: name.into(),
            entries,
        }
    }

    /// Execute hybrid BM25+vector recall for each corpus entry via the
    /// supplied `Corpus`. Returns one `Vec<ScoredChunk>` per entry, in
    /// entry order. Entries with empty content return an empty vec.
    ///
    /// Mirrors Swift's `ExternalCorpus.hybridRecall(via:limit:now:)`.
    ///
    /// - `corpus`: the estate's `Corpus`. Caller opens it from the same
    ///   storage backing the estate so chunk embeddings index the estate's
    ///   content.
    /// - `limit`: maximum scored chunks per entry.
    /// - `now_millis`: Unix epoch milliseconds for deterministic time.
    pub fn hybrid_recall(
        &self,
        corpus: &Corpus,
        limit: usize,
        now_millis: i64,
    ) -> CorpusKitResult<Vec<Vec<ScoredChunk>>> {
        let mut results: Vec<Vec<ScoredChunk>> = Vec::with_capacity(self.entries.len());
        for entry in &self.entries {
            if entry.content.trim().is_empty() {
                results.push(Vec::new());
                continue;
            }
            let hits = corpus.recall(&entry.content, limit, now_millis)?;
            results.push(hits);
        }
        Ok(results)
    }
}
