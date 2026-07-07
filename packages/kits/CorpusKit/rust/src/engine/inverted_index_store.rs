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
    // ADR-026: term_freqs and doc_lengths are NO LONGER held in RAM.
    // They are loaded from SQLite on demand inside `top_k`/`build_index`
    // and discarded after the InvertedIndex is built. This eliminates
    // ~500MB of HashMap heap on a 50K-memory estate.
    /// Cached (parameters, index, term_mapping). Cleared by every write
    /// so the next query reloads from SQLite and rebuilds.
    cached: Option<(BM25Parameters, InvertedIndex, HashMap<String, u32>)>,
}

impl InvertedIndexStore {
    /// Create and open a store backed by the given SQLite connection.
    ///
    /// Creates tables if absent (idempotent) and loads existing state.
    /// ADR-026: open validates tables are accessible but does NOT load
    /// term frequencies or document lengths into RAM. They are loaded
    /// from SQLite on demand inside `top_k` and discarded after the
    /// InvertedIndex is built.
    pub fn open(conn: Connection) -> Result<Self, rusqlite::Error> {
        Self::create_tables(&conn)?;
        Ok(InvertedIndexStore {
            state: Mutex::new(StoreState {
                conn,
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

        // Remove existing state from durable tables only.
        Self::delete_from_db(&state.conn, item_id)?;

        if tokens.is_empty() { state.cached = None; return Ok(()); }

        // Compute term frequencies.
        let mut tf: HashMap<String, usize> = HashMap::new();
        for t in tokens { *tf.entry(t.clone()).or_insert(0) += 1; }
        let doc_len = tokens.len();

        // Persist to SQLite only — no in-memory mirror (ADR-026).
        for (term, freq) in &tf {
            state.conn.execute(
                "INSERT OR REPLACE INTO iix_termfreqs (term, item_id, freq) VALUES (?1, ?2, ?3)",
                params![term, item_id, *freq as i64],
            )?;
        }
        state.conn.execute(
            "INSERT OR REPLACE INTO iix_doclens (item_id, length) VALUES (?1, ?2)",
            params![item_id, doc_len as i64],
        )?;
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

    // MARK: — Shard merge (EXT-4 bulk import)

    /// Merge a shard database's postings into this store's durable tables in
    /// ONE pass — the EXT-4 "rapid clone" seam. Parallel import workers each
    /// write their slice's postings into a private shard file (same iix_*
    /// schema, same install key — see `IngestPostingsShard`); the single writer
    /// then attaches each shard and copies its rows with a single
    /// `INSERT OR REPLACE ... SELECT ... ORDER BY` per table. SQLite performs
    /// the copy internally (no per-row statement/bind from our code), and the
    /// ORDER BY walks the shard's primary-key b-tree so destination inserts
    /// arrive in key order (append-locality — far fewer page writes and
    /// SQLCipher page-crypto ops than random-order per-row upserts).
    ///
    /// DURABLE TABLES ONLY: the in-memory term/doc maps are NOT updated here —
    /// the import path folds the workers' already-computed tf maps via
    /// `fold_postings` (no re-read). OR REPLACE preserves idempotency under
    /// queue-retry re-delivery (identical content → identical postings).
    /// ATTACH cannot run inside a transaction, so the bracket is
    /// attach → BEGIN IMMEDIATE → copy → COMMIT → DETACH.
    pub fn merge_shard(&self, shard_path: &str) -> Result<(), rusqlite::Error> {
        let state = self.state.lock().expect("mutex poisoned");
        persistence_kit::attach_with_install_key(&state.conn, shard_path, "iixshard")?;
        let merged = (|| -> Result<(), rusqlite::Error> {
            state.conn.execute_batch("BEGIN IMMEDIATE")?;
            let res = (|| -> Result<(), rusqlite::Error> {
                state.conn.execute_batch(
                    "INSERT OR REPLACE INTO iix_termfreqs (term, item_id, freq)
                       SELECT term, item_id, freq FROM iixshard.iix_termfreqs
                       ORDER BY term, item_id;
                     INSERT OR REPLACE INTO iix_doclens (item_id, length)
                       SELECT item_id, length FROM iixshard.iix_doclens
                       ORDER BY item_id;",
                )
            })();
            match res {
                Ok(()) => state.conn.execute_batch("COMMIT"),
                Err(e) => {
                    let _ = state.conn.execute_batch("ROLLBACK");
                    Err(e)
                }
            }
        })();
        // Always detach, success or failure — a stuck attach wedges later merges.
        let _ = state.conn.execute_batch("DETACH DATABASE iixshard");
        merged
    }

    /// Fold worker-computed postings into the in-memory maps — the memory twin
    /// of `merge_shard` (which writes only the durable tables). Items are
    /// `(item_id, term→freq, doc_len)`; re-delivered items replace their prior
    /// entries (same semantics as `index`'s delete-then-insert for an item that
    /// was already present). Clears the cached BM25 index once for the batch.
    /// ADR-026: no in-memory mirror. The durable tables (written by
    /// merge_shard) are the source of truth; just invalidate the cache.
    pub fn fold_postings(
        &self,
        _items: &[(String, HashMap<String, usize>, usize)],
    ) -> Result<(), rusqlite::Error> {
        let mut state = self.state.lock().expect("mutex poisoned");
        state.cached = None;
        Ok(())
    }

    /// Remove a document from the index.
    pub fn remove(&self, item_id: &str) -> Result<(), rusqlite::Error> {
        let mut state = self.state.lock().expect("mutex poisoned");
        Self::delete_from_db(&state.conn, item_id)?;
        state.cached = None;
        Ok(())
    }

    fn delete_from_db(conn: &Connection, item_id: &str) -> Result<(), rusqlite::Error> {
        conn.execute("DELETE FROM iix_termfreqs WHERE item_id = ?1", params![item_id])?;
        conn.execute("DELETE FROM iix_doclens WHERE item_id = ?1", params![item_id])?;
        Ok(())
    }

    // ADR-026: delete_mem removed — no in-memory mirror to update.

    // MARK: — Index building

    /// Rebuild the `InvertedIndex` from current term/doc state.
    ///
    /// Kept for API parity with the Swift twin's `buildIndex(parameters:)`,
    /// which does serve from its cache. `InvertedIndex` does not implement
    /// `Clone`, so this method cannot hand a cached copy to a caller by
    /// value without cloning it — it always rebuilds. Nothing in this crate
    /// calls it: the hot query path is `top_k`, which reads the store's
    /// parameter-keyed cache by reference under the lock instead of
    /// extracting an owned copy.
    /// ADR-026: loads term_freqs and doc_lengths from SQLite into transient
    /// locals, builds the index, and discards the raw dictionaries.
    pub fn build_index(&self, parameters: BM25Parameters) -> (InvertedIndex, HashMap<String, u32>) {
        let state = self.state.lock().expect("mutex poisoned");
        let mut term_freqs = TermFreqTable::new();
        let mut doc_lengths = HashMap::new();
        // Errors during load produce an empty index (fail-open for reads).
        let _ = Self::load_state(&state.conn, &mut term_freqs, &mut doc_lengths);
        BM25Weighting::build(&term_freqs, &doc_lengths, parameters)
    }

    // MARK: — Convenience top-k

    /// Build (or return cached) the index and return top-k SparseHit results.
    ///
    /// Builds only when the cache is empty or was built for different
    /// `parameters` (first query, or first query after `index`/`remove`/
    /// `fold_postings`/`clear_all` invalidated it); otherwise queries the
    /// already-built index in place through the held lock. Previously this
    /// called `build_index`, which rebuilt the whole `InvertedIndex` from
    /// the raw term-frequency table on every query — O(vocabulary ×
    /// documents) per query instead of O(query terms × matching postings).
    /// ADR-026: loads term_freqs and doc_lengths from SQLite when cache
    /// is stale, builds the InvertedIndex, caches THAT, discards the
    /// raw dictionaries. No persistent in-memory mirror.
    pub fn top_k(
        &self,
        query_terms: &[String],
        k: usize,
        parameters: BM25Parameters,
        algorithm: Algorithm,
    ) -> Vec<SparseHit> {
        let mut state = self.state.lock().expect("mutex poisoned");
        let needs_build = match &state.cached {
            Some((cached_params, _, _)) => *cached_params != parameters,
            None => true,
        };
        if needs_build {
            // Load from SQLite into transient locals — released after build.
            let mut term_freqs = TermFreqTable::new();
            let mut doc_lengths = HashMap::new();
            let _ = Self::load_state(&state.conn, &mut term_freqs, &mut doc_lengths);
            let (index, term_mapping) =
                BM25Weighting::build(&term_freqs, &doc_lengths, parameters);
            state.cached = Some((parameters, index, term_mapping));
        }
        let (_, index, term_mapping) = state.cached.as_ref().expect("cache populated above");
        let query = BM25Weighting::query_pairs(query_terms, term_mapping);
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
        state.cached = None;
        Ok(())
    }

    /// Number of indexed documents. Queries the durable table (ADR-026).
    pub fn document_count(&self) -> usize {
        let state = self.state.lock().expect("mutex poisoned");
        state.conn
            .query_row("SELECT COUNT(*) FROM iix_doclens", [], |r| r.get::<_, i64>(0))
            .unwrap_or(0) as usize
    }
}

// MARK: — IngestPostingsShard (EXT-4 bulk import)

/// A parallel import worker's PRIVATE postings shard — the producer half of the
/// EXT-4 shard-merge pattern. Each worker owns one shard file (created beside
/// the estate so the sibling `db.key` applies — the shard is encrypted with the
/// SAME install key as the estate, keeping tokenized user content protected at
/// rest), accumulates its slice's postings in memory, and `finish()` writes
/// them in ONE sorted transaction. The single writer then folds every shard
/// into the durable index via `InvertedIndexStore::merge_shard`.
///
/// Sorted before insert so the shard's (term, item_id) primary-key b-tree is
/// built append-order — the merge's `SELECT ... ORDER BY` is then a straight
/// index scan and the DESTINATION receives key-ordered rows (append-locality).
pub struct IngestPostingsShard {
    path: String,
    conn: Connection,
    rows: Vec<(String, String, i64)>,
    doclens: Vec<(String, i64)>,
}

impl IngestPostingsShard {
    /// Create a fresh shard at `path` with EXCLUSIVE-create semantics: the call
    /// FAILS if a file already exists at `path` rather than deleting or reusing
    /// it (codex b92be5bc — remove-and-open let a concurrent import's live shard
    /// be destroyed/replaced at a predictable path). Shard names carry the
    /// estate's db stem, so a collision means a concurrent import of the SAME
    /// estate — a caller bug (the import drain lease serializes those) that must
    /// surface loudly, never be silently absorbed. Stale shards from a CRASHED
    /// prior import are swept by `ingest_batch_import_sharded` at entry (safe
    /// under the lease), not here. Applies the install key from the sibling
    /// `db.key` (if present) before any SQL, then creates the iix_* schema.
    pub fn create(path: &str) -> Result<Self, rusqlite::Error> {
        // Claim the name atomically (O_CREAT|O_EXCL). SQLite treats the
        // resulting zero-byte file as a fresh database.
        std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(path)
            .map_err(|e| {
                rusqlite::Error::SqliteFailure(
                    rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_CANTOPEN),
                    Some(format!(
                        "import shard exclusive-create failed at {path}: {e} \
                         (existing file = concurrent import collision, not reused)"
                    )),
                )
            })?;
        let conn = Connection::open(path)?;
        persistence_kit::apply_install_encryption_to_conn(&conn, path)?;
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS iix_termfreqs (
                term     TEXT NOT NULL,
                item_id  TEXT NOT NULL,
                freq     INTEGER NOT NULL,
                PRIMARY KEY (term, item_id)
            );
            CREATE TABLE IF NOT EXISTS iix_doclens (
                item_id  TEXT NOT NULL PRIMARY KEY,
                length   INTEGER NOT NULL
            );",
        )?;
        Ok(IngestPostingsShard {
            path: path.to_string(),
            conn,
            rows: Vec::new(),
            doclens: Vec::new(),
        })
    }

    /// Accumulate one document's postings (term→freq) and length in memory.
    pub fn add(&mut self, item_id: &str, tf: &HashMap<String, usize>, doc_len: usize) {
        for (term, freq) in tf {
            self.rows
                .push((term.clone(), item_id.to_string(), *freq as i64));
        }
        self.doclens.push((item_id.to_string(), doc_len as i64));
    }

    /// Sort and write every accumulated row in ONE transaction, then close the
    /// connection. Returns the shard path for the subsequent `merge_shard`.
    pub fn finish(mut self) -> Result<String, rusqlite::Error> {
        self.rows.sort_unstable();
        self.doclens.sort_unstable();
        self.conn.execute_batch("BEGIN IMMEDIATE")?;
        let res = (|| -> Result<(), rusqlite::Error> {
            {
                let mut stmt = self.conn.prepare_cached(
                    "INSERT OR REPLACE INTO iix_termfreqs (term, item_id, freq) VALUES (?1, ?2, ?3)",
                )?;
                for (term, item_id, freq) in &self.rows {
                    stmt.execute(params![term, item_id, freq])?;
                }
            }
            {
                let mut stmt = self.conn.prepare_cached(
                    "INSERT OR REPLACE INTO iix_doclens (item_id, length) VALUES (?1, ?2)",
                )?;
                for (item_id, len) in &self.doclens {
                    stmt.execute(params![item_id, len])?;
                }
            }
            Ok(())
        })();
        match res {
            Ok(()) => self.conn.execute_batch("COMMIT")?,
            Err(e) => {
                let _ = self.conn.execute_batch("ROLLBACK");
                return Err(e);
            }
        }
        Ok(self.path.clone())
    }

    /// Best-effort removal of a merged (or abandoned) shard file and its WAL/SHM
    /// sidecars.
    pub fn remove_file(path: &str) {
        let _ = std::fs::remove_file(path);
        let _ = std::fs::remove_file(format!("{path}-wal"));
        let _ = std::fs::remove_file(format!("{path}-shm"));
    }
}
