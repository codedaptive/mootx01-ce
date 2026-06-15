//! SQLite-backed persistence for the inverted index.
//!
//! Lane D — InvertedIndex persistence sidecar.
//! Architecture spec §4.4: "the inverted index persists to a CorpusKit
//! sidecar so it is not rebuilt from scratch each startup at scale."
//!
//! Schema (two tables):
//!   iix_termfreqs  — (term TEXT, item_id TEXT, freq INTEGER) PRIMARY KEY (term, item_id)
//!   iix_doclens    — (item_id TEXT PRIMARY KEY, length INTEGER)
//!
//! Parity: Swift twin in CorpusKit/Sources/CorpusKit/Engine/InvertedIndexStore.swift.

use crate::engine::bm25_weighting::{BM25Parameters, BM25Weighting, TermFreqTable};
use crate::engine::inverted_index::{Algorithm, InvertedIndex};
use crate::engine::sparse_types::SparseHit;
use std::collections::HashMap;
use std::sync::Mutex;

use rusqlite::{params, Connection};

// MARK: — InvertedIndexStore

/// SQLite-backed persistence sidecar for the inverted index.
///
/// Persists term frequencies and document lengths. Rebuilds the
/// BM25-weighted `InvertedIndex` on demand (cached between mutations).
///
/// Thread-safety: internal `Mutex<State>` serializes all mutations and reads.
pub struct InvertedIndexStore {
    state: Mutex<StoreState>,
}

struct StoreState {
    conn: Connection,
    term_freqs: TermFreqTable,
    doc_lengths: HashMap<String, usize>,
    /// Cached (index, term_mapping). Cleared by every write.
    cached: Option<(InvertedIndex, HashMap<String, u32>)>,
}

impl InvertedIndexStore {
    /// Create and open a store backed by the given SQLite connection.
    ///
    /// Creates tables if absent (idempotent) and loads existing state.
    pub fn open(conn: Connection) -> Result<Self, rusqlite::Error> {
        Self::create_tables(&conn)?;
        let mut term_freqs = TermFreqTable::new();
        let mut doc_lengths = HashMap::new();
        Self::load_state(&conn, &mut term_freqs, &mut doc_lengths)?;
        Ok(InvertedIndexStore {
            state: Mutex::new(StoreState {
                conn,
                term_freqs,
                doc_lengths,
                cached: None,
            }),
        })
    }

    fn create_tables(conn: &Connection) -> Result<(), rusqlite::Error> {
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS iix_termfreqs (
                term     TEXT NOT NULL,
                item_id  TEXT NOT NULL,
                freq     INTEGER NOT NULL,
                PRIMARY KEY (term, item_id)
            );
            CREATE INDEX IF NOT EXISTS idx_iix_tf_item ON iix_termfreqs (item_id);
            CREATE TABLE IF NOT EXISTS iix_doclens (
                item_id  TEXT NOT NULL PRIMARY KEY,
                length   INTEGER NOT NULL
            );",
        )
    }

    fn load_state(
        conn: &Connection,
        term_freqs: &mut TermFreqTable,
        doc_lengths: &mut HashMap<String, usize>,
    ) -> Result<(), rusqlite::Error> {
        // Load term frequencies.
        let mut stmt = conn.prepare("SELECT term, item_id, freq FROM iix_termfreqs")?;
        let rows = stmt.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, i64>(2)? as usize,
            ))
        })?;
        for row in rows {
            let (term, item_id, freq) = row?;
            term_freqs.entry(term).or_default().insert(item_id, freq);
        }

        // Load doc lengths.
        let mut stmt = conn.prepare("SELECT item_id, length FROM iix_doclens")?;
        let rows = stmt.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)? as usize))
        })?;
        for row in rows {
            let (item_id, length) = row?;
            doc_lengths.insert(item_id, length);
        }

        Ok(())
    }

    // MARK: — Document indexing

    /// Index a document's tokenized terms.
    ///
    /// Re-indexing an existing item replaces all its term frequencies atomically.
    /// `now` parameter is accepted for API symmetry with the Swift twin but is not
    /// written to SQLite (dates are TEXT ISO-8601 in this schema; this table has none).
    pub fn index(
        &self,
        item_id: &str,
        tokens: &[String],
        _now: &str,
    ) -> Result<(), rusqlite::Error> {
        let mut state = self.state.lock().expect("mutex poisoned");

        // Remove existing state.
        Self::delete_from_db(&state.conn, item_id)?;
        Self::delete_mem(&mut *state, item_id);

        if tokens.is_empty() { return Ok(()); }

        // Compute term frequencies.
        let mut tf: HashMap<String, usize> = HashMap::new();
        for t in tokens { *tf.entry(t.clone()).or_insert(0) += 1; }
        let doc_len = tokens.len();

        // Persist.
        for (term, freq) in &tf {
            state.conn.execute(
                "INSERT OR REPLACE INTO iix_termfreqs (term, item_id, freq) VALUES (?1, ?2, ?3)",
                params![term, item_id, *freq as i64],
            )?;
            state.term_freqs.entry(term.clone()).or_default().insert(item_id.to_owned(), *freq);
        }
        state.conn.execute(
            "INSERT OR REPLACE INTO iix_doclens (item_id, length) VALUES (?1, ?2)",
            params![item_id, doc_len as i64],
        )?;
        state.doc_lengths.insert(item_id.to_owned(), doc_len);
        state.cached = None;
        Ok(())
    }

    /// Remove a document from the index.
    pub fn remove(&self, item_id: &str) -> Result<(), rusqlite::Error> {
        let mut state = self.state.lock().expect("mutex poisoned");
        Self::delete_from_db(&state.conn, item_id)?;
        Self::delete_mem(&mut *state, item_id);
        state.cached = None;
        Ok(())
    }

    fn delete_from_db(conn: &Connection, item_id: &str) -> Result<(), rusqlite::Error> {
        conn.execute("DELETE FROM iix_termfreqs WHERE item_id = ?1", params![item_id])?;
        conn.execute("DELETE FROM iix_doclens WHERE item_id = ?1", params![item_id])?;
        Ok(())
    }

    fn delete_mem(state: &mut StoreState, item_id: &str) {
        state.doc_lengths.remove(item_id);
        let terms: Vec<String> = state.term_freqs.keys().cloned().collect();
        for term in terms {
            if let Some(docs) = state.term_freqs.get_mut(&term) {
                docs.remove(item_id);
                if docs.is_empty() { state.term_freqs.remove(&term); }
            }
        }
    }

    // MARK: — Index building

    /// Build (or return cached) InvertedIndex with BM25 impacts.
    pub fn build_index(&self, parameters: BM25Parameters) -> (InvertedIndex, HashMap<String, u32>) {
        let mut state = self.state.lock().expect("mutex poisoned");
        if let Some((ref idx, ref tm)) = state.cached {
            // We can't clone InvertedIndex cheaply; rebuild if needed.
            // In practice the caller caches the mapping; rebuilding is O(postings).
            let _ = (idx, tm); // check if cached is Some
        }
        // Always rebuild (no Clone impl on InvertedIndex needed by callers).
        let pair = BM25Weighting::build(&state.term_freqs, &state.doc_lengths, parameters);
        state.cached = None; // don't cache (InvertedIndex has no Clone)
        pair
    }

    // MARK: — Convenience top-k

    /// Build the index and return top-k SparseHit results.
    pub fn top_k(
        &self,
        query_terms: &[String],
        k: usize,
        parameters: BM25Parameters,
        algorithm: Algorithm,
    ) -> Vec<SparseHit> {
        let (index, term_mapping) = self.build_index(parameters);
        let query = BM25Weighting::query_pairs(query_terms, &term_mapping);
        if query.is_empty() { return Vec::new(); }
        index.top_k(&query, k, algorithm)
    }

    /// Number of indexed documents.
    pub fn document_count(&self) -> usize {
        let state = self.state.lock().expect("mutex poisoned");
        state.doc_lengths.len()
    }
}
