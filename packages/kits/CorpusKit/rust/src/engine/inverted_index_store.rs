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
use persistence_kit::{BackendConfiguration, Storage};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

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

    /// Open an `InvertedIndexStore` whose backing `Connection` is derived from
    /// the provided `Storage` instance.
    ///
    /// For SQLite backends, opens a separate `rusqlite::Connection` to the same
    /// on-disk database file. WAL-mode SQLite allows concurrent readers and writers;
    /// `InvertedIndexStore` holds the write lock only during `begin_batch` /
    /// `commit_batch` windows, which corpus.rs sequences AFTER the main
    /// `Storage`-connection transaction has committed — the two connections never
    /// hold overlapping write locks simultaneously.
    ///
    /// For encrypted estates (those with a sibling `db.key` file), the
    /// per-install SQLCipher key is applied to the private connection via
    /// `persistence_kit::apply_install_encryption_to_conn` before any other SQL.
    /// This mirrors the key-application step in `SqliteStorage::new` and ensures
    /// the private connection can read the encrypted database header. The key
    /// application uses CorpusKit's rusqlite, which acquires SQLCipher support
    /// through Cargo feature unification with PersistenceKit's
    /// `bundled-sqlcipher-vendored-openssl` feature.
    ///
    /// For InMemory and PostgreSQL backends, opens an ephemeral `:memory:`
    /// connection — the IIX state is rebuilt on every open (matching the
    /// ephemeral nature of those backends).
    ///
    /// Mirrors Swift `InvertedIndexStore.init(storage:)` + `open()` in two steps.
    pub fn open_for_storage(storage: &Arc<dyn Storage>) -> Result<Self, rusqlite::Error> {
        let conn = match &storage.configuration().backend {
            BackendConfiguration::Sqlite { path, busy_timeout_secs } => {
                let conn = Connection::open(path)?;
                // Apply the per-install SQLCipher key BEFORE any other SQL. For
                // plaintext estates (no sibling db.key), this is a no-op. For
                // encrypted estates the PRAGMA key must be the first statement or
                // the database header reads as NOTADB (SQLITE_NOTADB).
                persistence_kit::apply_install_encryption_to_conn(&conn, path)?;
                let timeout_ms = (*busy_timeout_secs * 1000.0) as u32;
                conn.busy_timeout(std::time::Duration::from_millis(timeout_ms as u64))?;
                conn
            }
            // InMemory and PostgreSQL: use an ephemeral in-memory connection.
            // InMemory storage has no disk path; the IIX state is rebuilt on every
            // open (same as the pre-IIX body-scan path), which is acceptable since
            // InMemory storage itself is ephemeral.
            _ => Connection::open_in_memory()?,
        };
        Self::open(conn)
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

    // MARK: — Batch transaction bracket

    // A bulk ingest indexes tens of thousands of documents in one drain batch.
    // Without a transaction each `index` call autocommits (and, past the WAL
    // autocheckpoint threshold, triggers a checkpoint) — the drain thread then
    // sits in `sqlite3_step`/`PagerCommitPhaseOne`/`WalCheckpoint` and the
    // machine idles at ~1 core regardless of embed parallelism. Bracketing the
    // whole batch's writes in ONE transaction collapses N autocommits into a
    // single commit. This sidecar owns a PRIVATE connection (separate from
    // Corpus.storage), and SQLite is single-writer: a held `BEGIN IMMEDIATE`
    // takes the file write lock, so `Corpus::ingest_batch` sequences this
    // window AFTER the storage-connection transaction has committed — the two
    // connections never hold overlapping write locks. Mirrors the Swift twin's
    // beginBatch/commitBatch/rollbackBatch.

    /// Open a write transaction on the sidecar connection. Caller MUST pair with
    /// `commit_batch` (success) or `rollback_batch` (error). `BEGIN IMMEDIATE`
    /// acquires the write lock up front.
    pub fn begin_batch(&self) -> Result<(), rusqlite::Error> {
        let state = self.state.lock().expect("mutex poisoned");
        state.conn.execute_batch("BEGIN IMMEDIATE")
    }

    /// Commit the transaction opened by `begin_batch`.
    pub fn commit_batch(&self) -> Result<(), rusqlite::Error> {
        let state = self.state.lock().expect("mutex poisoned");
        state.conn.execute_batch("COMMIT")
    }

    /// Roll back the transaction opened by `begin_batch` (best-effort). The
    /// in-memory term/doc maps mutated during the batch are NOT reverted here;
    /// `ingest_batch` propagates the error, the drain aborts the batch, and the
    /// at-least-once queue retry re-ingests — re-indexing an item is idempotent
    /// (`index` deletes then re-inserts), so the maps converge on retry.
    pub fn rollback_batch(&self) -> Result<(), rusqlite::Error> {
        let state = self.state.lock().expect("mutex poisoned");
        let _ = state.conn.execute_batch("ROLLBACK");
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

    /// Delete all persisted term frequencies and document lengths, and clear
    /// in-memory state.
    ///
    /// Mirrors Swift `InvertedIndexStore.deleteAll()` and is used by
    /// `Corpus.destroy_recall_index` to wipe the durable inverted index in
    /// one call (no per-item iteration needed). The store is left empty but
    /// structurally intact: tables and indices remain, only rows are removed.
    pub fn clear_all(&self) -> Result<(), rusqlite::Error> {
        let mut state = self.state.lock().expect("mutex poisoned");
        state.conn.execute("DELETE FROM iix_termfreqs", [])?;
        state.conn.execute("DELETE FROM iix_doclens", [])?;
        state.term_freqs.clear();
        state.doc_lengths.clear();
        state.cached = None;
        Ok(())
    }

    /// Number of indexed documents.
    pub fn document_count(&self) -> usize {
        let state = self.state.lock().expect("mutex poisoned");
        state.doc_lengths.len()
    }
}
