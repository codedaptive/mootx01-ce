//! BruteForceIndex — Lane A binary brute-force dense index.
//!
//! Parallel to Swift `BruteForceIndex`. This is the conformance ORACLE:
//! all binary search paths (MIH in Lane B) are gated against its output.
//!
//! I-7 (arch spec §3.1 / §3.4): **VectorKit performs NO Hamming math.**
//! Every distance computation is delegated to `engram_lib::EngramLib::distances`
//! which routes through `SubstrateKernel::hamming_distance_batch` —
//! four-way conformance-gated. There is no XOR/popcount in this file.
//!
//! Deterministic ordering (retrieval algorithms reference §0.3):
//!   primary: `raw_distance` ascending (nearer first);
//!   tie-break: `key.item_id` ascending (smaller id wins).
//! This total order is applied over ALL candidates, then truncated to k.
//! The tie-break must use itemID ordering, not insertion order — which
//! is why we use `EngramLib::distances` (all distances) rather than
//! `EngramLib::find_nearest` (top-k by insertion-index tie-break).
//!
//! Thread-safety: `BruteForceIndex` holds its state behind a `Mutex`-free
//! mutable reference; callers that share an index across threads must
//! use their own synchronisation. In the Rust port the index is typically
//! owned by a single-threaded executor or wrapped in `Arc<Mutex<_>>`.

use crate::engine::hit::DenseHit;
use crate::engine::key::VectorRecordKey;
use crate::engine::metric::DenseMetric;
use crate::engine::payload::{VectorKind, VectorPayload};
use crate::engine::resident::ResidentVectorArray;
use crate::engine::seam::{DenseIndex, IndexKind, MetadataFilter};
use crate::error::VectorKitError;
use engram_lib::{Engram, EngramLib};

/// The binary brute-force dense index.
///
/// Only `.binary(.hamming)` is supported (Lane A). Jaccard and float
/// metrics return `VectorKitError::InvalidPayload`.
#[derive(Debug)]
pub struct BruteForceIndex {
    array: ResidentVectorArray,
}

impl BruteForceIndex {
    /// Create an empty index for the binary lane (stride = 32 bytes).
    pub fn new() -> Self {
        BruteForceIndex {
            array: ResidentVectorArray::empty(VectorKind::Binary, 32),
        }
    }

    /// Return a reference to the current resident array.
    pub fn array(&self) -> &ResidentVectorArray {
        &self.array
    }

    // --- Private helpers ---

    /// Extract the Engram from a 32-byte slot payload.
    ///
    /// The binary lane's canonical wire form (arch spec §2.1) is 32 bytes =
    /// 4×u64 little-endian. `Fingerprint256::from_le_bytes` interprets
    /// them in exactly this order. Do not reorder.
    fn bytes_to_engram(bytes: &[u8]) -> Option<Engram> {
        if bytes.len() != 32 {
            return None;
        }
        // Decode 4×u64 little-endian from the 32-byte wire form.
        let b0 = u64::from_le_bytes(bytes[0..8].try_into().ok()?);
        let b1 = u64::from_le_bytes(bytes[8..16].try_into().ok()?);
        let b2 = u64::from_le_bytes(bytes[16..24].try_into().ok()?);
        let b3 = u64::from_le_bytes(bytes[24..32].try_into().ok()?);
        Some(Engram::new(b0, b1, b2, b3))
    }

    /// Extract the Engram from a VectorPayload (binary kind, 32 bytes).
    fn payload_to_engram(payload: &VectorPayload) -> Result<Engram, VectorKitError> {
        if payload.kind != VectorKind::Binary {
            return Err(VectorKitError::InvalidPayload(format!(
                "BruteForceIndex: payload.kind must be Binary, got {:?}",
                payload.kind
            )));
        }
        if payload.bytes.len() != 32 {
            return Err(VectorKitError::InvalidPayload(format!(
                "BruteForceIndex: binary payload must be 32 bytes, got {}",
                payload.bytes.len()
            )));
        }
        Self::bytes_to_engram(&payload.bytes).ok_or_else(|| {
            VectorKitError::InvalidPayload("BruteForceIndex: could not decode Engram".into())
        })
    }

    /// Determine the scan range [start, end) from the filter.
    fn scan_range(&self, filter: Option<&MetadataFilter>) -> std::ops::Range<usize> {
        if let Some(f) = filter {
            if let Some(ref mid) = f.model_id {
                return self.array.partition_range(mid).unwrap_or(0..0);
            }
        }
        0..self.array.count
    }

    /// Set tombstone bit for slot `slot` in a u64 bitset.
    fn set_tombstone_bit(words: &mut Vec<u64>, slot: usize) {
        let w = slot / 64;
        let b = slot % 64;
        while words.len() <= w {
            words.push(0);
        }
        words[w] |= 1u64 << b;
    }

    /// Rebuild model partitions from keys + tombstones. Mirrors Swift impl.
    fn build_partitions(
        keys: &[VectorRecordKey],
        tombstones: &[u64],
    ) -> Vec<crate::engine::resident::ModelPartitionEntry> {
        use std::collections::HashMap;
        let mut min_idx: HashMap<&str, usize> = HashMap::new();
        let mut max_idx: HashMap<&str, usize> = HashMap::new();
        for (idx, key) in keys.iter().enumerate() {
            let w = idx / 64;
            let b = idx % 64;
            let is_dead = w < tombstones.len() && (tombstones[w] >> b) & 1 == 1;
            if !is_dead {
                let mid: &str = &key.model_id;
                let lo = min_idx.entry(mid).or_insert(idx);
                if idx < *lo {
                    *lo = idx;
                }
                let hi = max_idx.entry(mid).or_insert(idx);
                if idx > *hi {
                    *hi = idx;
                }
            }
        }
        let mut model_ids: Vec<String> =
            min_idx.keys().map(|s| s.to_string()).collect();
        model_ids.sort();
        model_ids
            .into_iter()
            .filter_map(|mid| {
                let lo = *min_idx.get(mid.as_str())?;
                let hi = *max_idx.get(mid.as_str())?;
                Some(crate::engine::resident::ModelPartitionEntry::new(
                    mid,
                    lo,
                    hi + 1,
                ))
            })
            .collect()
    }
}

impl Default for BruteForceIndex {
    fn default() -> Self {
        Self::new()
    }
}

impl DenseIndex for BruteForceIndex {
    fn kind(&self) -> IndexKind {
        IndexKind::BruteForce
    }

    fn build(
        &mut self,
        vectors: &[VectorPayload],
        keys: &[VectorRecordKey],
    ) -> Result<(), VectorKitError> {
        // Validate lengths match.
        if vectors.len() != keys.len() {
            return Err(VectorKitError::InvalidPayload(format!(
                "BruteForceIndex.build: vectors.len()={} != keys.len()={}",
                vectors.len(),
                keys.len()
            )));
        }
        // Build packed storage.
        let mut storage = Vec::with_capacity(vectors.len() * 32);
        for v in vectors {
            if v.kind != VectorKind::Binary || v.bytes.len() != 32 {
                return Err(VectorKitError::InvalidPayload(
                    "BruteForceIndex.build: all vectors must be Binary with 32 bytes".into(),
                ));
            }
            storage.extend_from_slice(&v.bytes);
        }
        let tombstones = vec![0u64; (vectors.len() + 63) / 64];
        let partitions = Self::build_partitions(keys, &tombstones);
        self.array = ResidentVectorArray {
            kind: VectorKind::Binary,
            stride: 32,
            count: vectors.len(),
            storage,
            keys: keys.to_vec(),
            model_partitions: partitions,
            tombstones,
        };
        Ok(())
    }

    /// k-nearest binary vectors by Hamming distance (exact linear scan).
    ///
    /// Uses `EngramLib::distances` (I-7) to compute ALL candidate distances
    /// via the substrate kernel, then sorts by `(distance ASC, item_id ASC)`
    /// and truncates to k. This gives the correct total order regardless of
    /// insertion order.
    fn search(
        &self,
        probe: &VectorPayload,
        metric: DenseMetric,
        k: usize,
        filter: Option<&MetadataFilter>,
    ) -> Result<Vec<DenseHit>, VectorKitError> {
        // Input validation.
        if probe.kind != VectorKind::Binary {
            return Err(VectorKitError::InvalidPayload(format!(
                "BruteForceIndex.search: probe.kind must be Binary, got {:?}",
                probe.kind
            )));
        }
        if !matches!(metric, DenseMetric::Binary(crate::engine::metric::BinaryMetric::Hamming)) {
            return Err(VectorKitError::InvalidPayload(format!(
                "BruteForceIndex.search: Lane A only supports Binary(Hamming); got {:?}",
                metric
            )));
        }
        if k == 0 {
            return Ok(vec![]);
        }

        let probe_engram = Self::payload_to_engram(probe)?;
        let scan = self.scan_range(filter);
        if scan.is_empty() {
            return Ok(vec![]);
        }

        // Collect live (non-tombstoned) Engrams and their slot indices.
        let mut engrams: Vec<Engram> = Vec::new();
        let mut slot_indices: Vec<usize> = Vec::new();
        for slot_idx in scan {
            if self.array.is_tombstoned(slot_idx) {
                continue;
            }
            // Per-slot metadata filter (model_version, etc.)
            let key = &self.array.keys[slot_idx];
            if let Some(f) = filter {
                if !f.accepts(key) {
                    continue;
                }
            }
            let bytes = self.array.vector_bytes(slot_idx);
            if let Some(e) = Self::bytes_to_engram(bytes) {
                engrams.push(e);
                slot_indices.push(slot_idx);
            }
        }

        if engrams.is_empty() {
            return Ok(vec![]);
        }

        // --- Delegate ALL Hamming computation to EngramLib (I-7) ---
        // EngramLib::distances calls SubstrateKernel::hamming_distance_batch,
        // which is four-way conformance-gated. We are the oracle because
        // we do no math ourselves.
        let distances = EngramLib::distances(&probe_engram, &engrams);

        // Build DenseHit for all live candidates.
        let mut all_hits: Vec<DenseHit> = (0..engrams.len())
            .map(|i| DenseHit {
                key: self.array.keys[slot_indices[i]].clone(),
                raw_distance: distances[i] as i32,
                metric,
            })
            .collect();

        // Sort by (distance ASC, item_id ASC) — the oracle total order.
        // Sorting over all candidates ensures the correct k winners at
        // tie boundaries (not insertion-order-dependent).
        all_hits.sort_by(|a, b| {
            a.raw_distance
                .cmp(&b.raw_distance)
                .then(a.key.item_id.cmp(&b.key.item_id))
        });

        // Truncate to k.
        all_hits.truncate(k);
        Ok(all_hits)
    }

    fn add(
        &mut self,
        key: VectorRecordKey,
        vector: VectorPayload,
    ) -> Result<(), VectorKitError> {
        if vector.kind != VectorKind::Binary || vector.bytes.len() != 32 {
            return Err(VectorKitError::InvalidPayload(
                "BruteForceIndex.add: vector must be Binary with 32 bytes".into(),
            ));
        }

        // Tombstone any existing slot with the same key (upsert).
        let mut new_tombstones = self.array.tombstones.clone();
        for slot_idx in 0..self.array.count {
            if self.array.keys[slot_idx] == key {
                Self::set_tombstone_bit(&mut new_tombstones, slot_idx);
            }
        }

        // Append the new slot.
        let mut new_storage = self.array.storage.clone();
        new_storage.extend_from_slice(&vector.bytes);
        let mut new_keys = self.array.keys.clone();
        new_keys.push(key);
        let new_count = new_keys.len();

        // Extend tombstone bitset for the new (live) slot.
        let words_needed = (new_count + 63) / 64;
        while new_tombstones.len() < words_needed {
            new_tombstones.push(0);
        }

        let new_partitions = Self::build_partitions(&new_keys, &new_tombstones);
        self.array = ResidentVectorArray {
            kind: VectorKind::Binary,
            stride: 32,
            count: new_count,
            storage: new_storage,
            keys: new_keys,
            model_partitions: new_partitions,
            tombstones: new_tombstones,
        };
        Ok(())
    }

    fn remove(&mut self, key: &VectorRecordKey) -> Result<(), VectorKitError> {
        let mut new_tombstones = self.array.tombstones.clone();
        let mut changed = false;
        for slot_idx in 0..self.array.count {
            if &self.array.keys[slot_idx] == key {
                Self::set_tombstone_bit(&mut new_tombstones, slot_idx);
                changed = true;
            }
        }
        if !changed {
            return Ok(()); // no-op
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
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::metric::DenseMetric;
    use crate::engine::payload::{VectorKind, VectorPayload};
    use engram_lib::Engram;

    /// Build a 32-byte binary payload from an Engram (4×u64 LE).
    /// Accesses Fingerprint256 fields directly (block0..block3 are pub fields).
    fn engram_payload(e: &Engram) -> VectorPayload {
        let mut bytes = vec![0u8; 32];
        bytes[0..8].copy_from_slice(&e.block0.to_le_bytes());
        bytes[8..16].copy_from_slice(&e.block1.to_le_bytes());
        bytes[16..24].copy_from_slice(&e.block2.to_le_bytes());
        bytes[24..32].copy_from_slice(&e.block3.to_le_bytes());
        VectorPayload { kind: VectorKind::Binary, dim: 256, bytes, scale: None }
    }

    fn key(item_id: &str) -> VectorRecordKey {
        VectorRecordKey::new(item_id, 0, "model-a", "1")
    }

    fn zero_engram() -> Engram { Engram::new(0, 0, 0, 0) }
    fn zero_payload() -> VectorPayload { engram_payload(&zero_engram()) }

    // ── Conformance gate ───────────────────────────────────────────────────
    //
    // Mirrors the hamming_nn_topk_tie.json vector: 5 candidates all at
    // Hamming distance 1 from the zero anchor. Top-3 must be the three
    // with the smallest item_ids (tie-break by item_id ASC, §0.3).

    #[test]
    fn conformance_gate_hamming_nn_topk_tie() {
        let anchor = zero_engram();
        // Same codes as hamming_nn_topk_tie.json.
        // row_id=1 → block0=1,  row_id=2 → block0=2, row_id=3 → block0=8,
        // row_id=4 → block0=4,  row_id=5 → block0=16
        let candidates: Vec<(&str, Engram)> = vec![
            ("00000000-0000-0000-0000-000000000005", Engram::new(16, 0, 0, 0)),
            ("00000000-0000-0000-0000-000000000003", Engram::new(8,  0, 0, 0)),
            ("00000000-0000-0000-0000-000000000001", Engram::new(1,  0, 0, 0)),
            ("00000000-0000-0000-0000-000000000004", Engram::new(4,  0, 0, 0)),
            ("00000000-0000-0000-0000-000000000002", Engram::new(2,  0, 0, 0)),
        ];
        let mut idx = BruteForceIndex::new();
        for (item_id, e) in &candidates {
            idx.add(key(item_id), engram_payload(e)).unwrap();
        }
        let hits = idx.search(
            &engram_payload(&anchor),
            DenseMetric::HAMMING,
            3,
            None,
        ).unwrap();
        assert_eq!(hits.len(), 3);
        for h in &hits { assert_eq!(h.raw_distance, 1); }
        assert_eq!(hits[0].key.item_id, "00000000-0000-0000-0000-000000000001");
        assert_eq!(hits[1].key.item_id, "00000000-0000-0000-0000-000000000002");
        assert_eq!(hits[2].key.item_id, "00000000-0000-0000-0000-000000000003");
    }

    // ── MIH spec vectors ──────────────────────────────────────────────────

    #[test]
    fn mih_vector1_exact_small_index_k2() {
        let mut idx = BruteForceIndex::new();
        idx.add(key("id-1"), engram_payload(&Engram::new(0, 0, 0, 0))).unwrap();
        idx.add(key("id-2"), engram_payload(&Engram::new(7, 0, 0, 0))).unwrap();
        idx.add(key("id-3"), engram_payload(&Engram::new(0xFF, 0, 0, 0))).unwrap();
        idx.add(key("id-4"), engram_payload(&Engram::new(0, 0, 0, 0x8000_0000_0000_0000))).unwrap();
        let hits = idx.search(&zero_payload(), DenseMetric::HAMMING, 2, None).unwrap();
        assert_eq!(hits.len(), 2);
        assert_eq!(hits[0].key.item_id, "id-1");
        assert_eq!(hits[0].raw_distance, 0);
        assert_eq!(hits[1].key.item_id, "id-4");
        assert_eq!(hits[1].raw_distance, 1);
    }

    #[test]
    fn mih_vector2_tie_break_by_item_id() {
        let mut idx = BruteForceIndex::new();
        idx.add(key("id-1"), engram_payload(&Engram::new(0, 0, 0, 0))).unwrap();
        idx.add(key("id-2"), engram_payload(&Engram::new(7, 0, 0, 0))).unwrap();
        idx.add(key("id-3"), engram_payload(&Engram::new(0xFF, 0, 0, 0))).unwrap();
        idx.add(key("id-4"), engram_payload(&Engram::new(0, 0, 0, 0x8000_0000_0000_0000))).unwrap();
        idx.add(key("id-5"), engram_payload(&Engram::new(1, 0, 0, 0))).unwrap();
        let hits = idx.search(&zero_payload(), DenseMetric::HAMMING, 2, None).unwrap();
        assert_eq!(hits.len(), 2);
        assert_eq!(hits[0].key.item_id, "id-1"); assert_eq!(hits[0].raw_distance, 0);
        assert_eq!(hits[1].key.item_id, "id-4"); assert_eq!(hits[1].raw_distance, 1);
    }

    #[test]
    fn mih_vector3_multiband_three_way_tie() {
        let mut idx = BruteForceIndex::new();
        idx.add(key("id-10"), engram_payload(&Engram::new(3, 3, 0, 0))).unwrap();
        idx.add(key("id-11"), engram_payload(&Engram::new(0, 0, 0, 0x0F))).unwrap();
        idx.add(key("id-12"), engram_payload(&Engram::new(0x0F, 0, 0, 0))).unwrap();
        idx.add(key("id-13"), engram_payload(&Engram::new(1, 0, 0, 0))).unwrap();
        let hits = idx.search(&zero_payload(), DenseMetric::HAMMING, 3, None).unwrap();
        assert_eq!(hits.len(), 3);
        assert_eq!(hits[0].key.item_id, "id-13"); assert_eq!(hits[0].raw_distance, 1);
        assert_eq!(hits[1].key.item_id, "id-10"); assert_eq!(hits[1].raw_distance, 4);
        assert_eq!(hits[2].key.item_id, "id-11"); assert_eq!(hits[2].raw_distance, 4);
    }

    #[test]
    fn mih_vector4_fewer_than_k() {
        let mut idx = BruteForceIndex::new();
        idx.add(key("id-1"), engram_payload(&Engram::new(0, 0, 0, 0))).unwrap();
        let hits = idx.search(&zero_payload(), DenseMetric::HAMMING, 5, None).unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].key.item_id, "id-1");
        assert_eq!(hits[0].raw_distance, 0);
    }

    #[test]
    fn mih_vector5_delete_then_query() {
        let mut idx = BruteForceIndex::new();
        idx.add(key("id-1"), engram_payload(&Engram::new(0, 0, 0, 0))).unwrap();
        idx.add(key("id-2"), engram_payload(&Engram::new(7, 0, 0, 0))).unwrap();
        idx.add(key("id-3"), engram_payload(&Engram::new(0xFF, 0, 0, 0))).unwrap();
        idx.add(key("id-4"), engram_payload(&Engram::new(0, 0, 0, 0x8000_0000_0000_0000))).unwrap();
        idx.remove(&key("id-4")).unwrap();
        let hits = idx.search(&zero_payload(), DenseMetric::HAMMING, 2, None).unwrap();
        assert_eq!(hits.len(), 2);
        assert_eq!(hits[0].key.item_id, "id-1"); assert_eq!(hits[0].raw_distance, 0);
        assert_eq!(hits[1].key.item_id, "id-2"); assert_eq!(hits[1].raw_distance, 3);
    }

    #[test]
    fn model_id_filter_restricts_scan() {
        let mut idx = BruteForceIndex::new();
        let ka = VectorRecordKey::new("item-a", 0, "model-a", "1");
        let kb = VectorRecordKey::new("item-b", 0, "model-b", "1");
        idx.add(ka, engram_payload(&Engram::new(0, 0, 0, 0))).unwrap();
        idx.add(kb, engram_payload(&Engram::new(0xFF, 0, 0, 0))).unwrap();
        let filter = MetadataFilter { model_id: Some("model-a".into()), model_version: None };
        let hits = idx.search(&zero_payload(), DenseMetric::HAMMING, 10, Some(&filter)).unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].key.item_id, "item-a");
    }

    #[test]
    fn empty_index_returns_empty() {
        let idx = BruteForceIndex::new();
        let hits = idx.search(&zero_payload(), DenseMetric::HAMMING, 5, None).unwrap();
        assert!(hits.is_empty());
    }

    #[test]
    fn k_zero_returns_empty() {
        let mut idx = BruteForceIndex::new();
        idx.add(key("id-1"), engram_payload(&zero_engram())).unwrap();
        let hits = idx.search(&zero_payload(), DenseMetric::HAMMING, 0, None).unwrap();
        assert!(hits.is_empty());
    }

    #[test]
    fn non_binary_probe_returns_error() {
        let idx = BruteForceIndex::new();
        let float_probe = VectorPayload {
            kind: VectorKind::Float32,
            dim: 2,
            bytes: vec![0u8; 8],
            scale: None,
        };
        let res = idx.search(&float_probe, DenseMetric::HAMMING, 1, None);
        assert!(matches!(res, Err(VectorKitError::InvalidPayload(_))));
    }

    #[test]
    fn build_from_vecs_and_search() {
        let e1 = Engram::new(1, 0, 0, 0);
        let e2 = Engram::new(3, 0, 0, 0);
        let k1 = key("item-1");
        let k2 = key("item-2");
        let vectors = vec![engram_payload(&e1), engram_payload(&e2)];
        let keys = vec![k1.clone(), k2.clone()];
        let mut idx = BruteForceIndex::new();
        idx.build(&vectors, &keys).unwrap();
        let hits = idx.search(&zero_payload(), DenseMetric::HAMMING, 2, None).unwrap();
        assert_eq!(hits.len(), 2);
        assert_eq!(hits[0].key.item_id, "item-1");
        assert_eq!(hits[0].raw_distance, 1);
        assert_eq!(hits[1].key.item_id, "item-2");
        assert_eq!(hits[1].raw_distance, 2);
    }
}
