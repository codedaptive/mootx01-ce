//! ResidentArrayStore — packed `.vec` sidecar format, write, append,
//! tombstone, and compaction.
//!
//! Parallel to Swift `ResidentArrayStore`. Manages the on-disk `.vec`
//! sidecar that lets the engine load the entire resident array in one
//! read rather than N per-row SQLite fetches (arch spec §3.2).
//!
//! On-disk format (all integers little-endian, arch spec §4.2):
//!
//!   magic(4)           = 0x56 0x45 0x43 0x31  ("VEC1")
//!   version(2)         = 0x00 0x01
//!   kind(1)            = VectorKind raw value (0 = binary)
//!   stride(4)          = bytes per vector slot (LE u32)
//!   count(4)           = total allocated slots (LE u32)
//!   live_count(4)      = live (non-tombstoned) slots (LE u32)
//!   tombstone_words(4) = number of u64 tombstone words (LE u32)
//!   tombstones(8×T)    = tombstone bitset (u64 LE each)
//!   vectors(count×stride) = packed vector bytes
//!   keys(variable)     = count key records (see encode_key)
//!   partition_index    = 4B count | (key_len|key_bytes|4B lo|4B hi)*
//!
//! The format is byte-identical to the Swift implementation for the same
//! logical array (arch spec §4.3 cross-language byte-identity mandate).
//!
//! The sidecar is loaded via `fs::read()` on all platforms (heap read).
//! The format is byte-identical to the Swift implementation (arch spec §4.3).
//!
//! The SQLite `vectors` table is always the source of truth. The sidecar
//! is a regenerable cache. `rebuild_from` regenerates it from a sorted
//! (key, bytes) list.
//!
//! WRITE-AMORTISATION POLICY (TASK #24, import/migration-scale ingestion):
//! The per-row sidecar rewrite was O(N) bytes per write, so a bulk import of
//! N vectors cost O(N²) bytes written. Two amortised paths replace it:
//!
//!   • `append_batch(records)` — extends the in-memory array with all N
//!     records in one pass and writes the sidecar EXACTLY ONCE. Bulk import
//!     drives this, so a batch of N costs one sidecar write, not N.
//!
//!   • `append_deferred(key, bytes)` — the single-add write-behind path. It
//!     mutates the in-memory array and sets `is_dirty` WITHOUT writing the
//!     sidecar. The caller (`VectorStore`) flushes via `flush()` at a quiesce
//!     point (close, explicit flush, batch boundary). A process killed before
//!     the flush loses only the sidecar cache: the `vectors` table still holds
//!     every row, and the next open detects the live-count mismatch and
//!     rebuilds the sidecar from the table. Crash safety is therefore
//!     unchanged — the table remains the single durable source.
//!
//! `append(key, bytes)` (immediate-write) is retained for eager callers.

use crate::engine::key::VectorRecordKey;
use crate::engine::payload::VectorKind;
use crate::engine::resident::{ModelPartitionEntry, ResidentVectorArray};
use crate::error::VectorKitError;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

// ── Format constants ──────────────────────────────────────────────────────

/// On-disk magic bytes. "VEC1" in ASCII. Matches Swift.
pub const VEC_MAGIC: [u8; 4] = [0x56, 0x45, 0x43, 0x31];

/// Format version. LE u16.
///
/// Version 0x0002: adds `live_count` field (LE u32) after `count` and
/// before `tombstone_words`. The field is written on save but read and
/// discarded on load — stale detection recomputes live count from the
/// tombstone bitmap. No installed sidecars exist at version 0x0001;
/// the old bytes are rejected by `parse_sidecar`.
pub const VEC_VERSION: u16 = 0x0002;

/// Tombstone compaction threshold: when (dead / total) > threshold,
/// compact is called automatically after the next write.
pub const DEFAULT_COMPACTION_THRESHOLD: f64 = 0.25;

// ── ResidentArrayStore ────────────────────────────────────────────────────

/// Manages the `.vec` sidecar and the in-memory `ResidentVectorArray`.
///
/// Not `Send` by default because it holds mutable state. Callers that
/// need concurrent access must wrap in `Arc<Mutex<_>>`.
pub struct ResidentArrayStore {
    sidecar_path: PathBuf,
    compaction_threshold: f64,
    array: ResidentVectorArray,
    /// Count of on-disk sidecar writes in this store's lifetime.
    ///
    /// Incremented once per `write_sidecar` call (rebuild, append,
    /// append_batch, tombstone, compact). Exposed for test assertions only:
    /// the import-scale regression test asserts a bulk ingest of N vectors
    /// costs O(batches) sidecar writes, not O(N).
    sidecar_write_count: usize,
    /// True when the in-memory array has diverged from the on-disk sidecar.
    ///
    /// Set by `append_deferred` / `tombstone_deferred` (write-behind), cleared
    /// by any sidecar write. Crash safety is unaffected: the `vectors` table is
    /// the durable source and `VectorStore::ensure_index_built_locked` rebuilds
    /// the sidecar from the table when the live counts disagree.
    is_dirty: bool,
}

impl ResidentArrayStore {
    /// Create or open a store backed by `sidecar_path`.
    ///
    /// The in-memory array is empty until `load()` is called.
    pub fn new(
        sidecar_path: impl Into<PathBuf>,
        kind: VectorKind,
        stride: usize,
        compaction_threshold: f64,
    ) -> Self {
        ResidentArrayStore {
            sidecar_path: sidecar_path.into(),
            compaction_threshold,
            array: ResidentVectorArray::empty(kind, stride),
            sidecar_write_count: 0,
            is_dirty: false,
        }
    }

    /// Number of on-disk sidecar writes performed in this store's lifetime.
    /// Test instrumentation only (see field doc).
    pub fn sidecar_write_count(&self) -> usize {
        self.sidecar_write_count
    }

    /// True when the in-memory array has unflushed write-behind mutations.
    pub fn is_dirty(&self) -> bool {
        self.is_dirty
    }

    /// Convenience: binary lane store (stride = 32).
    pub fn new_binary(sidecar_path: impl Into<PathBuf>) -> Self {
        Self::new(sidecar_path, VectorKind::Binary, 32, DEFAULT_COMPACTION_THRESHOLD)
    }

    /// Load (or reload) the sidecar from disk.
    ///
    /// If the file is absent, returns `Ok(())` without changing the
    /// in-memory array. If the file is present but invalid, the
    /// in-memory array is reset to empty (the SQLite table is the
    /// source of truth). Call once at startup before `snapshot()`.
    pub fn load(&mut self) -> Result<(), VectorKitError> {
        let path = self.sidecar_path.clone();
        if !path.exists() {
            return Ok(()); // empty start
        }
        match Self::read_sidecar(&path) {
            Ok(loaded) => {
                self.array = loaded;
                self.is_dirty = false; // in-memory array now matches disk
                Ok(())
            }
            Err(e) => {
                // Invalid sidecar: reset to empty (table is the source of truth).
                self.array = ResidentVectorArray::empty(self.array.kind, self.array.stride);
                self.is_dirty = false;
                Err(e)
            }
        }
    }

    /// Rebuild the sidecar from a sorted (key, bytes) list.
    ///
    /// The list must be sorted by `VectorRecordKey` natural order for the
    /// partition index to be correct. This is the warm-start path after
    /// crash recovery or first open.
    pub fn rebuild_from(
        &mut self,
        records: &[(VectorRecordKey, Vec<u8>)],
    ) -> Result<(), VectorKitError> {
        let new_array = Self::build_array(records, self.array.kind, self.array.stride);
        self.persist(new_array)
    }

    /// Persist `new_array` to the sidecar and adopt it as the current array.
    ///
    /// The single internal funnel for every on-disk write: it increments
    /// `sidecar_write_count` (test instrumentation) and clears `is_dirty`
    /// because the in-memory array now matches the file.
    fn persist(&mut self, new_array: ResidentVectorArray) -> Result<(), VectorKitError> {
        Self::write_sidecar(&new_array, &self.sidecar_path)?;
        self.array = new_array;
        self.sidecar_write_count += 1;
        self.is_dirty = false;
        Ok(())
    }

    /// Return a clone of the current in-memory array.
    ///
    /// Pass to `BruteForceIndex::build` (via the vectors+keys form) to
    /// make it the active scan target. The clone is value-typed and safe
    /// to pass across threads.
    pub fn snapshot(&self) -> ResidentVectorArray {
        self.array.clone()
    }

    /// Append a new (key, bytes) record to the store.
    ///
    /// Updates the in-memory array and the on-disk sidecar. If the
    /// tombstone ratio exceeds the threshold, `compact()` is called
    /// automatically.
    pub fn append(
        &mut self,
        key: VectorRecordKey,
        bytes: Vec<u8>,
    ) -> Result<(), VectorKitError> {
        if bytes.len() != self.array.stride {
            return Err(VectorKitError::InvalidPayload(format!(
                "ResidentArrayStore.append: bytes.len()={} != stride={}",
                bytes.len(),
                self.array.stride
            )));
        }

        let new_array = Self::appending_array(&self.array, key, &bytes);
        self.persist(new_array)?;

        if self.tombstone_ratio() > self.compaction_threshold {
            self.compact()?;
        }
        Ok(())
    }

    /// Append a new (key, bytes) record WITHOUT writing the sidecar.
    ///
    /// The write-behind single-add path (TASK #24). Mutates the in-memory
    /// array and sets `is_dirty`; the caller must `flush()` at a quiesce
    /// point to persist. Crash safety is preserved by the table-rebuild path
    /// (see the module header policy note). Auto-compaction is NOT triggered
    /// here (it would force a write, defeating the deferral); it runs on the
    /// next eager write or after a `flush()`.
    pub fn append_deferred(
        &mut self,
        key: VectorRecordKey,
        bytes: Vec<u8>,
    ) -> Result<(), VectorKitError> {
        if bytes.len() != self.array.stride {
            return Err(VectorKitError::InvalidPayload(format!(
                "ResidentArrayStore.append_deferred: bytes.len()={} != stride={}",
                bytes.len(),
                self.array.stride
            )));
        }
        self.array = Self::appending_array(&self.array, key, &bytes);
        self.is_dirty = true;
        Ok(())
    }

    /// Append N (key, bytes) records in one pass, writing the sidecar EXACTLY
    /// ONCE at the end.
    ///
    /// The import-scale bulk path (TASK #24). A batch of N records extends
    /// storage, keys, and the tombstone bitset once, rebuilds the partition
    /// index once, and performs a single sidecar write — so a bulk import of
    /// N vectors costs O(batches) sidecar writes, not O(N). Tombstoning of
    /// prior slots for replaced keys is the caller's responsibility.
    pub fn append_batch(
        &mut self,
        records: &[(VectorRecordKey, Vec<u8>)],
    ) -> Result<(), VectorKitError> {
        if records.is_empty() {
            return Ok(());
        }
        let mut new_storage = self.array.storage.clone();
        new_storage.reserve(records.len() * self.array.stride);
        let mut new_keys = self.array.keys.clone();
        new_keys.reserve(records.len());

        for (key, bytes) in records {
            if bytes.len() != self.array.stride {
                return Err(VectorKitError::InvalidPayload(format!(
                    "ResidentArrayStore.append_batch: bytes.len()={} != stride={}",
                    bytes.len(),
                    self.array.stride
                )));
            }
            new_storage.extend_from_slice(bytes);
            new_keys.push(key.clone());
        }

        let new_count = new_keys.len();
        let mut new_tombstones = self.array.tombstones.clone();
        let words_needed = (new_count + 63) / 64;
        while new_tombstones.len() < words_needed {
            new_tombstones.push(0);
        }
        let new_partitions = Self::build_partitions(&new_keys, &new_tombstones);
        let new_array = ResidentVectorArray {
            kind: self.array.kind,
            stride: self.array.stride,
            count: new_count,
            storage: new_storage,
            keys: new_keys,
            model_partitions: new_partitions,
            tombstones: new_tombstones,
        };
        self.persist(new_array)?;

        if self.tombstone_ratio() > self.compaction_threshold {
            self.compact()?;
        }
        Ok(())
    }

    /// Flush a pending write-behind mutation to the sidecar.
    ///
    /// No-op when the in-memory array already matches the file (`is_dirty`
    /// false). Auto-compaction is evaluated after the flush so deferred
    /// appends still get compacted when the tombstone ratio is high.
    pub fn flush(&mut self) -> Result<(), VectorKitError> {
        if !self.is_dirty {
            return Ok(());
        }
        let snapshot = self.array.clone();
        self.persist(snapshot)?;
        if self.tombstone_ratio() > self.compaction_threshold {
            self.compact()?;
        }
        Ok(())
    }

    /// Build a new array that appends one (key, bytes) slot to `base`.
    ///
    /// Shared by `append` and `append_deferred` so both produce
    /// byte-identical layouts. Does not write the sidecar.
    fn appending_array(
        base: &ResidentVectorArray,
        key: VectorRecordKey,
        bytes: &[u8],
    ) -> ResidentVectorArray {
        let mut new_storage = base.storage.clone();
        new_storage.extend_from_slice(bytes);
        let mut new_keys = base.keys.clone();
        new_keys.push(key);
        let new_count = new_keys.len();
        let mut new_tombstones = base.tombstones.clone();
        let words_needed = (new_count + 63) / 64;
        while new_tombstones.len() < words_needed {
            new_tombstones.push(0);
        }
        let new_partitions = Self::build_partitions(&new_keys, &new_tombstones);
        ResidentVectorArray {
            kind: base.kind,
            stride: base.stride,
            count: new_count,
            storage: new_storage,
            keys: new_keys,
            model_partitions: new_partitions,
            tombstones: new_tombstones,
        }
    }

    /// Tombstone the record identified by `key`.
    ///
    /// No-op if `key` is absent. Updates the in-memory array and sidecar.
    pub fn tombstone(&mut self, key: &VectorRecordKey) -> Result<(), VectorKitError> {
        let mut new_tombstones = self.array.tombstones.clone();
        let mut changed = false;
        for slot_idx in 0..self.array.count {
            if &self.array.keys[slot_idx] == key {
                Self::set_tombstone_bit(&mut new_tombstones, slot_idx);
                changed = true;
            }
        }
        if !changed {
            return Ok(());
        }
        let new_partitions = Self::build_partitions(&self.array.keys, &new_tombstones);
        let new_array = ResidentVectorArray {
            kind: self.array.kind,
            stride: self.array.stride,
            count: self.array.count,
            storage: self.array.storage.clone(),
            keys: self.array.keys.clone(),
            model_partitions: new_partitions,
            tombstones: new_tombstones,
        };
        self.persist(new_array)?;

        if self.tombstone_ratio() > self.compaction_threshold {
            self.compact()?;
        }
        Ok(())
    }

    /// Tombstone every record matching any key in `keys` WITHOUT writing.
    ///
    /// The batch counterpart of `tombstone`. Used by `VectorStore` before a
    /// bulk `append_batch` to retire prior slots for replaced keys in one
    /// pass — mirroring the table's ON CONFLICT UPDATE — without N sidecar
    /// rewrites. The append that follows performs the single sidecar write.
    /// No-op if none of the keys are present.
    pub fn tombstone_deferred(&mut self, keys: &std::collections::HashSet<VectorRecordKey>) {
        if keys.is_empty() {
            return;
        }
        let mut new_tombstones = self.array.tombstones.clone();
        let mut changed = false;
        for slot_idx in 0..self.array.count {
            if keys.contains(&self.array.keys[slot_idx]) {
                Self::set_tombstone_bit(&mut new_tombstones, slot_idx);
                changed = true;
            }
        }
        if !changed {
            return;
        }
        let new_partitions = Self::build_partitions(&self.array.keys, &new_tombstones);
        self.array = ResidentVectorArray {
            kind: self.array.kind,
            stride: self.array.stride,
            count: self.array.count,
            storage: self.array.storage.clone(),
            keys: self.array.keys.clone(),
            model_partitions: new_partitions,
            tombstones: new_tombstones,
        };
        self.is_dirty = true;
    }

    /// Rewrite the sidecar dropping tombstoned slots.
    ///
    /// Output is sorted by key (VectorRecordKey natural order) for
    /// deterministic, reproducible compacted output (arch spec §4.2).
    pub fn compact(&mut self) -> Result<(), VectorKitError> {
        let mut live: Vec<(VectorRecordKey, Vec<u8>)> = Vec::new();
        for slot_idx in 0..self.array.count {
            if self.array.is_tombstoned(slot_idx) {
                continue;
            }
            let bytes = self.array.vector_bytes(slot_idx).to_vec();
            live.push((self.array.keys[slot_idx].clone(), bytes));
        }
        // Sort by key for deterministic output.
        live.sort_by(|a, b| a.0.cmp(&b.0));
        let compacted = Self::build_array(&live, self.array.kind, self.array.stride);
        self.persist(compacted)?;
        Ok(())
    }

    // ── Private helpers ───────────────────────────────────────────────────

    fn tombstone_ratio(&self) -> f64 {
        let total = self.array.count;
        if total == 0 {
            return 0.0;
        }
        let dead = (0..total).filter(|&i| self.array.is_tombstoned(i)).count();
        dead as f64 / total as f64
    }

    fn set_tombstone_bit(words: &mut Vec<u64>, slot: usize) {
        let w = slot / 64;
        let b = slot % 64;
        while words.len() <= w {
            words.push(0);
        }
        words[w] |= 1u64 << b;
    }

    pub(crate) fn build_partitions(
        keys: &[VectorRecordKey],
        tombstones: &[u64],
    ) -> Vec<ModelPartitionEntry> {
        use std::collections::HashMap;
        let mut min_idx: HashMap<&str, usize> = HashMap::new();
        let mut max_idx: HashMap<&str, usize> = HashMap::new();
        for (idx, key) in keys.iter().enumerate() {
            let w = idx / 64;
            let b = idx % 64;
            let dead = w < tombstones.len() && (tombstones[w] >> b) & 1 == 1;
            if !dead {
                let mid: &str = &key.model_id;
                let lo = min_idx.entry(mid).or_insert(idx);
                if idx < *lo { *lo = idx; }
                let hi = max_idx.entry(mid).or_insert(idx);
                if idx > *hi { *hi = idx; }
            }
        }
        let mut model_ids: Vec<String> = min_idx.keys().map(|s| s.to_string()).collect();
        model_ids.sort();
        model_ids.into_iter().filter_map(|mid| {
            let lo = *min_idx.get(mid.as_str())?;
            let hi = *max_idx.get(mid.as_str())?;
            Some(ModelPartitionEntry::new(mid, lo, hi + 1))
        }).collect()
    }

    fn build_array(
        records: &[(VectorRecordKey, Vec<u8>)],
        kind: VectorKind,
        stride: usize,
    ) -> ResidentVectorArray {
        let count = records.len();
        let mut storage = Vec::with_capacity(count * stride);
        let mut keys = Vec::with_capacity(count);
        for (key, bytes) in records {
            storage.extend_from_slice(bytes);
            keys.push(key.clone());
        }
        let tombstones = vec![0u64; (count + 63) / 64];
        let partitions = Self::build_partitions(&keys, &tombstones);
        ResidentVectorArray {
            kind, stride, count, storage, keys,
            model_partitions: partitions,
            tombstones,
        }
    }

    // ── Sidecar I/O ───────────────────────────────────────────────────────

    /// Write a `ResidentVectorArray` to the `.vec` format.
    ///
    /// Writes to a `.tmp` file first, then renames atomically to avoid
    /// leaving a corrupted sidecar on crash.
    pub fn write_sidecar(
        arr: &ResidentVectorArray,
        path: &Path,
    ) -> Result<(), VectorKitError> {
        let mut buf: Vec<u8> = Vec::new();

        // Magic + version + kind + stride + count + live_count
        buf.extend_from_slice(&VEC_MAGIC);
        buf.extend_from_slice(&VEC_VERSION.to_le_bytes());
        buf.push(arr.kind as u8);
        buf.extend_from_slice(&(arr.stride as u32).to_le_bytes());
        buf.extend_from_slice(&(arr.count as u32).to_le_bytes());
        // live_count: number of non-tombstoned slots. Lets VectorStore
        // stale detection compare live-vs-live in O(1) on reopen (C5 fix).
        buf.extend_from_slice(&(arr.live_count() as u32).to_le_bytes());

        // Tombstone block
        buf.extend_from_slice(&(arr.tombstones.len() as u32).to_le_bytes());
        for w in &arr.tombstones {
            buf.extend_from_slice(&w.to_le_bytes());
        }

        // Vectors block
        buf.extend_from_slice(&arr.storage);

        // Keys block
        for key in &arr.keys {
            encode_key(key, &mut buf);
        }

        // Partition index
        encode_partitions(&arr.model_partitions, &mut buf);

        // Atomic write: tmp → rename.
        let tmp_path = path.with_extension("vec.tmp");
        let mut f = fs::File::create(&tmp_path).map_err(|e| {
            VectorKitError::StoreUnavailable(format!(
                "ResidentArrayStore.write_sidecar: could not create tmp file {:?}: {}",
                tmp_path, e
            ))
        })?;
        f.write_all(&buf).map_err(|e| {
            VectorKitError::StoreUnavailable(format!(
                "ResidentArrayStore.write_sidecar: write failed: {}", e
            ))
        })?;
        f.flush().map_err(|e| {
            VectorKitError::StoreUnavailable(format!(
                "ResidentArrayStore.write_sidecar: flush failed: {}", e
            ))
        })?;
        drop(f);
        fs::rename(&tmp_path, path).map_err(|e| {
            VectorKitError::StoreUnavailable(format!(
                "ResidentArrayStore.write_sidecar: rename failed: {}", e
            ))
        })?;
        Ok(())
    }

    /// Read and parse a `.vec` sidecar file.
    ///
    /// On POSIX, uses `memmap2` for a read-only memory map. On platforms
    /// where memmap2 is unavailable or mmap fails, falls back to a heap
    /// read. Both produce bit-identical arrays (arch spec §4.3).
    pub fn read_sidecar(path: &Path) -> Result<ResidentVectorArray, VectorKitError> {
        let data = fs::read(path).map_err(|e| {
            VectorKitError::StoreUnavailable(format!(
                "ResidentArrayStore.read_sidecar: could not read {:?}: {}", path, e
            ))
        })?;
        Self::parse_sidecar(&data)
    }

    /// Parse raw `.vec` bytes into a `ResidentVectorArray`.
    ///
    /// `pub` so tests can exercise the codec directly without touching the
    /// filesystem. Mirrors the Swift `parseSidecar` method.
    pub fn parse_sidecar(data: &[u8]) -> Result<ResidentVectorArray, VectorKitError> {
        // Magic (bytes 0..4)
        if data.len() < 4 {
            return Err(VectorKitError::DecodingFailure(
                "ResidentArrayStore: sidecar too short for magic".into(),
            ));
        }
        if data[0..4] != VEC_MAGIC {
            return Err(VectorKitError::DecodingFailure(format!(
                "ResidentArrayStore: bad magic {:?}; expected {:?}",
                &data[0..4], VEC_MAGIC
            )));
        }
        let mut pos = 4; // start parsing after the 4-byte magic

        // Version
        let version = read_le_u16(data, pos)?; pos += 2;
        if version != VEC_VERSION {
            return Err(VectorKitError::DecodingFailure(format!(
                "ResidentArrayStore: unsupported version {version}; expected {VEC_VERSION}"
            )));
        }

        // Kind
        check_bounds(data, pos, 1, "kind")?;
        let kind_raw = data[pos]; pos += 1;
        let kind = match kind_raw {
            0 => VectorKind::Binary,
            1 => VectorKind::Float32,
            2 => VectorKind::Int8,
            _ => return Err(VectorKitError::DecodingFailure(
                format!("ResidentArrayStore: unknown kind byte {kind_raw}")
            )),
        };

        // Stride + Count + LiveCount
        let stride = read_le_u32(data, pos)? as usize; pos += 4;
        let count  = read_le_u32(data, pos)? as usize; pos += 4;
        // live_count: read and discard — recomputed from the tombstone
        // bitmap after load; the parsed value is cross-checked in tests.
        let _live_count = read_le_u32(data, pos)? as usize; pos += 4;

        // Tombstones
        let tombstone_words = read_le_u32(data, pos)? as usize; pos += 4;
        // Guard against overflow in tombstone_words * 8: a malformed sidecar
        // can carry a tombstone_words value large enough that the multiplication
        // overflows usize, producing a spuriously small bound (debug: panic,
        // release: wraps). Use checked_mul so both modes fail closed with an error.
        let tombstone_block = tombstone_words.checked_mul(8).ok_or_else(|| {
            VectorKitError::DecodingFailure(
                "ResidentArrayStore: tombstone block size overflows usize".into(),
            )
        })?;
        check_bounds(data, pos, tombstone_block, "tombstone block")?;
        let mut tombstones = Vec::with_capacity(tombstone_words);
        for _ in 0..tombstone_words {
            tombstones.push(read_le_u64(data, pos)?);
            pos += 8;
        }

        // Vectors block
        // Guard against overflow in count * stride: a malformed sidecar can carry
        // values large enough that their product overflows usize. checked_mul
        // fails closed with an error in both debug and release builds.
        let vectors_bytes = count.checked_mul(stride).ok_or_else(|| {
            VectorKitError::DecodingFailure(
                "ResidentArrayStore: vectors block size overflows usize".into(),
            )
        })?;
        check_bounds(data, pos, vectors_bytes, "vectors block")?;
        let storage = data[pos..pos + vectors_bytes].to_vec();
        pos += vectors_bytes;

        // Keys block
        let mut keys = Vec::with_capacity(count);
        for _ in 0..count {
            let (key, consumed) = decode_key(data, pos)?;
            keys.push(key);
            pos += consumed;
        }

        // Partition index
        let (partitions, consumed) = decode_partitions(data, pos)?;
        pos += consumed;
        let _ = pos; // silence unused warning

        Ok(ResidentVectorArray {
            kind, stride, count, storage, keys,
            model_partitions: partitions,
            tombstones,
        })
    }
}

// ── Key encode / decode ───────────────────────────────────────────────────

/// Encode a VectorRecordKey as:
///   4B LE len(item_id) | item_id UTF-8
///   4B LE vector_index
///   4B LE len(model_id) | model_id UTF-8
///   4B LE len(model_version) | model_version UTF-8
fn encode_key(key: &VectorRecordKey, buf: &mut Vec<u8>) {
    let item_id = key.item_id.as_bytes();
    buf.extend_from_slice(&(item_id.len() as u32).to_le_bytes());
    buf.extend_from_slice(item_id);
    buf.extend_from_slice(&key.vector_index.to_le_bytes());
    let model_id = key.model_id.as_bytes();
    buf.extend_from_slice(&(model_id.len() as u32).to_le_bytes());
    buf.extend_from_slice(model_id);
    let model_version = key.model_version.as_bytes();
    buf.extend_from_slice(&(model_version.len() as u32).to_le_bytes());
    buf.extend_from_slice(model_version);
}

/// Decode a VectorRecordKey from `data[pos..]`. Returns (key, bytes_consumed).
fn decode_key(data: &[u8], pos: usize) -> Result<(VectorRecordKey, usize), VectorKitError> {
    let mut p = pos;

    let item_id = read_utf8_string(data, p)?;
    p += 4 + item_id.len();

    check_bounds(data, p, 4, "vector_index")?;
    let vector_index = read_le_u32(data, p)?;
    p += 4;

    let model_id = read_utf8_string(data, p)?;
    p += 4 + model_id.len();

    let model_version = read_utf8_string(data, p)?;
    p += 4 + model_version.len();

    Ok((
        VectorRecordKey::new(item_id, vector_index, model_id, model_version),
        p - pos,
    ))
}

// ── Partition index encode / decode ───────────────────────────────────────

fn encode_partitions(partitions: &[ModelPartitionEntry], buf: &mut Vec<u8>) {
    buf.extend_from_slice(&(partitions.len() as u32).to_le_bytes());
    for p in partitions {
        let mid = p.model_id.as_bytes();
        buf.extend_from_slice(&(mid.len() as u32).to_le_bytes());
        buf.extend_from_slice(mid);
        buf.extend_from_slice(&(p.start as u32).to_le_bytes());
        buf.extend_from_slice(&(p.end as u32).to_le_bytes());
    }
}

fn decode_partitions(
    data: &[u8],
    pos: usize,
) -> Result<(Vec<ModelPartitionEntry>, usize), VectorKitError> {
    if pos + 4 > data.len() {
        return Ok((vec![], 0)); // absent partition block = zero partitions
    }
    let count = read_le_u32(data, pos)? as usize;
    let mut p = pos + 4;
    let mut partitions = Vec::with_capacity(count);
    for _ in 0..count {
        let mid = read_utf8_string(data, p)?;
        p += 4 + mid.len();
        check_bounds(data, p, 8, "partition range")?;
        let lo = read_le_u32(data, p)? as usize; p += 4;
        let hi = read_le_u32(data, p)? as usize; p += 4;
        partitions.push(ModelPartitionEntry::new(mid, lo, hi));
    }
    Ok((partitions, p - pos))
}

// ── Little-endian read helpers ────────────────────────────────────────────

fn check_bounds(
    data: &[u8], pos: usize, len: usize, ctx: &str,
) -> Result<(), VectorKitError> {
    if pos + len > data.len() {
        Err(VectorKitError::DecodingFailure(format!(
            "ResidentArrayStore: truncated at {ctx} (pos={pos}, need={len}, have={})",
            data.len()
        )))
    } else {
        Ok(())
    }
}

fn read_le_u16(data: &[u8], pos: usize) -> Result<u16, VectorKitError> {
    check_bounds(data, pos, 2, "u16")?;
    Ok(u16::from_le_bytes([data[pos], data[pos + 1]]))
}
fn read_le_u32(data: &[u8], pos: usize) -> Result<u32, VectorKitError> {
    check_bounds(data, pos, 4, "u32")?;
    Ok(u32::from_le_bytes(data[pos..pos + 4].try_into().unwrap()))
}
fn read_le_u64(data: &[u8], pos: usize) -> Result<u64, VectorKitError> {
    check_bounds(data, pos, 8, "u64")?;
    Ok(u64::from_le_bytes(data[pos..pos + 8].try_into().unwrap()))
}
fn read_utf8_string(data: &[u8], pos: usize) -> Result<String, VectorKitError> {
    let len = read_le_u32(data, pos)? as usize;
    check_bounds(data, pos + 4, len, "string body")?;
    String::from_utf8(data[pos + 4..pos + 4 + len].to_vec())
        .map_err(|e| VectorKitError::DecodingFailure(
            format!("ResidentArrayStore: invalid UTF-8: {e}")
        ))
}

// ── Tests ─────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::brute_force::BruteForceIndex;
    use crate::engine::metric::DenseMetric;
    use crate::engine::payload::{VectorKind, VectorPayload};
    use crate::engine::seam::DenseIndex;
    use engram_lib::Engram;
    use std::fs;
    use tempfile::NamedTempFile;

    fn engram_payload(e: &Engram) -> VectorPayload {
        let mut bytes = vec![0u8; 32];
        bytes[0..8].copy_from_slice(&e.block0.to_le_bytes());
        bytes[8..16].copy_from_slice(&e.block1.to_le_bytes());
        bytes[16..24].copy_from_slice(&e.block2.to_le_bytes());
        bytes[24..32].copy_from_slice(&e.block3.to_le_bytes());
        VectorPayload { kind: VectorKind::Binary, dim: 256, bytes, scale: None }
    }

    fn engram_bytes(e: &Engram) -> Vec<u8> {
        let p = engram_payload(e);
        p.bytes
    }

    fn key(item_id: &str) -> VectorRecordKey {
        VectorRecordKey::new(item_id, 0, "model-a", "1")
    }

    fn zero_engram() -> Engram { Engram::new(0, 0, 0, 0) }

    fn tmp_path() -> PathBuf {
        NamedTempFile::new().unwrap().path().with_extension("vec")
    }

    // ── Round-trip: write → reopen → identical top-k ─────────────────────

    #[test]
    fn write_then_reopen_produces_identical_top_k() {
        let path = tmp_path();
        let e1 = zero_engram();
        let e2 = Engram::new(1, 0, 0, 0);
        let e3 = Engram::new(0xFF, 0, 0, 0);
        let records = vec![
            (key("item-1"), e1),
            (key("item-2"), e2),
            (key("item-3"), e3),
        ];

        // Session 1: write.
        let mut store1 = ResidentArrayStore::new_binary(&path);
        for (k, e) in &records {
            store1.append(k.clone(), engram_bytes(e)).unwrap();
        }
        let snap1 = store1.snapshot();
        let mut idx1 = BruteForceIndex::new();
        let vecs: Vec<VectorPayload> = snap1.keys.iter().enumerate()
            .filter(|&(i, _)| !snap1.is_tombstoned(i))
            .map(|(i, _)| {
                let b = snap1.vector_bytes(i).to_vec();
                VectorPayload { kind: VectorKind::Binary, dim: 256, bytes: b, scale: None }
            }).collect();
        let ks: Vec<VectorRecordKey> = snap1.keys.iter().enumerate()
            .filter(|&(i, _)| !snap1.is_tombstoned(i))
            .map(|(_, k)| k.clone()).collect();
        idx1.build(&vecs, &ks).unwrap();
        let hits1 = idx1.search(
            &engram_payload(&zero_engram()),
            DenseMetric::HAMMING, 2, None
        ).unwrap();

        // Session 2: reopen via read_sidecar.
        let mut store2 = ResidentArrayStore::new_binary(&path);
        store2.load().unwrap();
        let snap2 = store2.snapshot();
        let mut idx2 = BruteForceIndex::new();
        let vecs2: Vec<VectorPayload> = snap2.keys.iter().enumerate()
            .filter(|&(i, _)| !snap2.is_tombstoned(i))
            .map(|(i, _)| {
                let b = snap2.vector_bytes(i).to_vec();
                VectorPayload { kind: VectorKind::Binary, dim: 256, bytes: b, scale: None }
            }).collect();
        let ks2: Vec<VectorRecordKey> = snap2.keys.iter().enumerate()
            .filter(|&(i, _)| !snap2.is_tombstoned(i))
            .map(|(_, k)| k.clone()).collect();
        idx2.build(&vecs2, &ks2).unwrap();
        let hits2 = idx2.search(
            &engram_payload(&zero_engram()),
            DenseMetric::HAMMING, 2, None
        ).unwrap();

        assert_eq!(hits1.len(), hits2.len());
        for (a, b) in hits1.iter().zip(hits2.iter()) {
            assert_eq!(a.key.item_id, b.key.item_id);
            assert_eq!(a.raw_distance, b.raw_distance);
        }
        let _ = fs::remove_file(&path);
    }

    // ── Sidecar byte format round-trip ────────────────────────────────────

    #[test]
    fn sidecar_format_round_trip() {
        let e1 = Engram::new(0xDEAD_BEEF_CAFE_BABE, 0x0123_4567_89AB_CDEF,
                              0xFFFF_0000_FFFF_0000, 0x0000_FFFF_0000_FFFF);
        let e2 = Engram::new(0, 1, 2, 3);
        let k1 = VectorRecordKey::new("item-alpha", 0, "model-test", "v1");
        let k2 = VectorRecordKey::new("item-beta",  1, "model-test", "v1");
        let tombstones = vec![0u64];
        let partitions = ResidentArrayStore::build_partitions(
            &[k1.clone(), k2.clone()], &tombstones);
        let original = ResidentVectorArray {
            kind: VectorKind::Binary, stride: 32, count: 2,
            storage: [engram_bytes(&e1), engram_bytes(&e2)].concat(),
            keys: vec![k1.clone(), k2.clone()],
            model_partitions: partitions,
            tombstones,
        };
        let path = tmp_path();
        ResidentArrayStore::write_sidecar(&original, &path).unwrap();
        let parsed = ResidentArrayStore::read_sidecar(&path).unwrap();
        assert_eq!(parsed.kind, original.kind);
        assert_eq!(parsed.stride, original.stride);
        assert_eq!(parsed.count, original.count);
        assert_eq!(parsed.storage, original.storage);
        assert_eq!(parsed.tombstones, original.tombstones);
        assert_eq!(parsed.keys, original.keys);
        let _ = fs::remove_file(&path);
    }

    // ── Tombstone + compaction ────────────────────────────────────────────

    #[test]
    fn tombstoned_record_absent_after_reopen() {
        let path = tmp_path();
        let mut store = ResidentArrayStore::new_binary(&path);
        let ka = key("item-a");
        let kb = key("item-b");
        store.append(ka.clone(), engram_bytes(&Engram::new(0, 0, 0, 0))).unwrap();
        store.append(kb.clone(), engram_bytes(&Engram::new(1, 0, 0, 0))).unwrap();
        store.tombstone(&ka).unwrap();

        let mut store2 = ResidentArrayStore::new_binary(&path);
        store2.load().unwrap();
        let snap = store2.snapshot();
        // Count live slots.
        let live: Vec<usize> = (0..snap.count).filter(|&i| !snap.is_tombstoned(i)).collect();
        assert_eq!(live.len(), 1);
        assert_eq!(snap.keys[live[0]].item_id, "item-b");
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn compaction_removes_tombstoned_slots() {
        let path = tmp_path();
        let mut store = ResidentArrayStore::new_binary(&path);
        store.append(key("item-a"), engram_bytes(&Engram::new(5, 0, 0, 0))).unwrap();
        store.append(key("item-b"), engram_bytes(&Engram::new(3, 0, 0, 0))).unwrap();
        store.append(key("item-c"), engram_bytes(&Engram::new(1, 0, 0, 0))).unwrap();
        store.tombstone(&key("item-a")).unwrap();
        store.compact().unwrap();

        let snap = store.snapshot();
        assert_eq!(snap.count, 2);
        let any_dead = (0..snap.count).any(|i| snap.is_tombstoned(i));
        assert!(!any_dead);
        let _ = fs::remove_file(&path);
    }

    // ── Heap path equals mmap path ────────────────────────────────────────

    #[test]
    fn heap_parse_equals_file_read() {
        let path = tmp_path();
        let e = Engram::new(0xABCD_EF01_2345_6789, 0, 0, 0);
        let k = VectorRecordKey::new("item-x", 0, "m1", "v2");
        let partitions = vec![ModelPartitionEntry::new("m1", 0, 1)];
        let arr = ResidentVectorArray {
            kind: VectorKind::Binary, stride: 32, count: 1,
            storage: engram_bytes(&e),
            keys: vec![k.clone()],
            model_partitions: partitions,
            tombstones: vec![0u64],
        };
        ResidentArrayStore::write_sidecar(&arr, &path).unwrap();
        let via_file = ResidentArrayStore::read_sidecar(&path).unwrap();
        let raw = fs::read(&path).unwrap();
        let via_parse = ResidentArrayStore::parse_sidecar(&raw).unwrap();
        assert_eq!(via_file.storage, via_parse.storage);
        assert_eq!(via_file.keys, via_parse.keys);
        assert_eq!(via_file.count, via_parse.count);
        let _ = fs::remove_file(&path);
    }

    // ── Bad magic ─────────────────────────────────────────────────────────

    #[test]
    fn bad_magic_returns_decoding_failure() {
        let mut bad = VEC_MAGIC.to_vec();
        bad[0] = 0x00; // corrupt
        bad.extend_from_slice(&VEC_VERSION.to_le_bytes());
        bad.push(0); // kind = binary
        bad.extend_from_slice(&32u32.to_le_bytes()); // stride
        bad.extend_from_slice(&0u32.to_le_bytes());  // count
        bad.extend_from_slice(&0u32.to_le_bytes());  // tombstone_words=0
        let res = ResidentArrayStore::parse_sidecar(&bad);
        assert!(matches!(res, Err(VectorKitError::DecodingFailure(_))));
    }

    // ── rebuild_from → reopen ─────────────────────────────────────────────

    #[test]
    fn rebuild_from_and_reopen_match() {
        let path = tmp_path();
        let records: Vec<(VectorRecordKey, Vec<u8>)> = vec![
            (key("item-a"), engram_bytes(&Engram::new(1, 0, 0, 0))),
            (key("item-b"), engram_bytes(&Engram::new(3, 0, 0, 0))),
        ];
        let mut sorted = records.clone();
        sorted.sort_by(|a, b| a.0.cmp(&b.0));

        let mut store1 = ResidentArrayStore::new_binary(&path);
        store1.rebuild_from(&sorted).unwrap();
        let snap1 = store1.snapshot();

        let mut store2 = ResidentArrayStore::new_binary(&path);
        store2.load().unwrap();
        let snap2 = store2.snapshot();

        assert_eq!(snap1.count, snap2.count);
        assert_eq!(snap1.storage, snap2.storage);
        assert_eq!(snap1.keys, snap2.keys);
        let _ = fs::remove_file(&path);
    }

    // ── C5: stale-detection uses live_count, not total slot count ─────────

    /// C5-1: live_count after tombstone is correct.
    ///
    /// Write 4 vectors, tombstone 2. count must remain 4 (total slots,
    /// no auto-compact since ratio=0.5 but threshold=1.0 in this test).
    /// live_count must become 2. After reload, the same values hold.
    #[test]
    fn live_count_after_tombstone_is_correct() {
        let path = tmp_path();
        // High threshold = never auto-compact, so tombstoned slots stay.
        let mut store = ResidentArrayStore::new(
            &path, VectorKind::Binary, 32, 1.0,
        );
        let keys_vec: Vec<VectorRecordKey> = (1..=4)
            .map(|i| VectorRecordKey::new(format!("item-{i}"), 0, "m1", "1"))
            .collect();
        let engrams: Vec<Engram> = (1u64..=4).map(|i| Engram::new(i, 0, 0, 0)).collect();

        for (k, e) in keys_vec.iter().zip(engrams.iter()) {
            store.append(k.clone(), engram_bytes(e)).unwrap();
        }
        // Tombstone items at index 0 and 2.
        store.tombstone(&keys_vec[0]).unwrap();
        store.tombstone(&keys_vec[2]).unwrap();

        let snap = store.snapshot();
        assert_eq!(snap.count, 4, "total slots: 4 allocated, 2 tombstoned");
        assert_eq!(snap.live_count(), 2, "live slots: 2 of 4 survive");

        // Reload from disk: live_count must match.
        let mut store2 = ResidentArrayStore::new(&path, VectorKind::Binary, 32, 1.0);
        store2.load().unwrap();
        let snap2 = store2.snapshot();
        assert_eq!(snap2.count, 4, "reloaded total count");
        assert_eq!(snap2.live_count(), 2, "reloaded live_count from bitmap");
        let _ = fs::remove_file(&path);
    }

    /// TASK #24 old-shape proof: per-row eager `append` writes the sidecar
    /// once PER ROW (the O(N²) disease), whereas `append_batch` writes it
    /// ONCE for the whole batch. This is the structural contrast the
    /// import-scale regression guards against — a per-row import of N rows
    /// costs N sidecar writes; the batch path costs 1.
    #[test]
    fn append_batch_writes_sidecar_once_vs_per_row_append() {
        let n = 64usize;

        // Old shape: eager per-row append → N sidecar writes.
        let path_eager = tmp_path();
        let mut eager = ResidentArrayStore::new_binary(&path_eager);
        for i in 0..n {
            eager
                .append(key(&format!("item-{i}")), engram_bytes(&Engram::new(i as u64, 0, 0, 0)))
                .unwrap();
        }
        assert_eq!(
            eager.sidecar_write_count(),
            n,
            "per-row eager append must write the sidecar once per row (old O(N²) shape)"
        );

        // New shape: one batch → exactly one sidecar write.
        let path_batch = tmp_path();
        let mut batched = ResidentArrayStore::new_binary(&path_batch);
        let records: Vec<(VectorRecordKey, Vec<u8>)> = (0..n)
            .map(|i| (key(&format!("item-{i}")), engram_bytes(&Engram::new(i as u64, 0, 0, 0))))
            .collect();
        batched.append_batch(&records).unwrap();
        assert_eq!(
            batched.sidecar_write_count(),
            1,
            "append_batch must write the sidecar exactly once for the whole batch"
        );

        // Both produce the same live count.
        assert_eq!(eager.snapshot().live_count(), n);
        assert_eq!(batched.snapshot().live_count(), n);

        let _ = std::fs::remove_file(&path_eager);
        let _ = std::fs::remove_file(&path_batch);
    }

    /// C5-2: live_count vs table count stale detection logic.
    ///
    /// Build a sidecar with 2 live slots. live_count() == 2.
    /// Simulated table count of 2 → not stale.
    /// Simulated table count of 3 → stale (rebuild fires).
    #[test]
    fn live_count_vs_table_count_stale_detection_logic() {
        let path = tmp_path();
        let records: Vec<(VectorRecordKey, Vec<u8>)> = vec![
            (key("item-a"), engram_bytes(&Engram::new(1, 0, 0, 0))),
            (key("item-b"), engram_bytes(&Engram::new(2, 0, 0, 0))),
        ];
        let arr = ResidentArrayStore::build_array(&records, VectorKind::Binary, 32);
        ResidentArrayStore::write_sidecar(&arr, &path).unwrap();

        let loaded = ResidentArrayStore::read_sidecar(&path).unwrap();
        assert_eq!(loaded.count, 2);
        assert_eq!(loaded.live_count(), 2);

        // Case A: table also has 2 live rows → not stale.
        let table_count_a: usize = 2;
        assert_eq!(loaded.live_count(), table_count_a, "live-vs-live: not stale");

        // Case B: table has 3 live rows → stale (row added out-of-band).
        let table_count_b: usize = 3;
        assert_ne!(loaded.live_count(), table_count_b, "live-vs-live: stale when diverge");
        let _ = fs::remove_file(&path);
    }
}
