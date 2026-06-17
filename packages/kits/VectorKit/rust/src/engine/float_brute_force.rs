//! FloatBruteForceIndex — Lane C Rust twin.
//!
//! Exact brute-force linear scan for VectorKind::Float32 vectors.
//! Implements the DenseIndex trait for float32 payloads over a
//! ResidentVectorArray.
//!
//! # Determinism boundary (arch spec §6)
//!
//! THIS LANE IS NOT FOUR-WAY BIT-IDENTICAL.
//!
//! Float arithmetic (cosine, L2, dot) is reproducible within one
//! build/config/platform but is NOT guaranteed bit-identical across
//! Swift and Rust or across different hardware. This is a DOCUMENTED
//! PROPERTY of IEEE-754 float arithmetic and of the float lane, not
//! a bug or an I-7 violation. Tests assert within-config reproducibility
//! and recall correctness; they do NOT assert four-way bit-identity.
//!
//! A reviewer must not "fix" this lane to chase four-way bit-identity.
//! The binary lane (Lane A BruteForceIndex) is the four-way oracle lane.
//!
//! # Rule FT-1
//!
//! This file does NOT modify any Lane F shared type. If a new field is
//! needed on a shared type, stop and file an FT-1 update to Lane F.

use crate::engine::hit::DenseHit;
use crate::engine::key::VectorRecordKey;
use crate::engine::metric::{DenseMetric, FloatMetric};
use crate::engine::payload::{VectorKind, VectorPayload};
use crate::engine::resident::ResidentVectorArray;
use crate::engine::seam::{DenseIndex, IndexKind, MetadataFilter, SearchDirection};
use crate::error::VectorKitError;

// MARK: - FloatBruteForceIndex

/// Brute-force exact linear scan for the float32 dense lane.
///
/// Implements `DenseIndex` for `VectorKind::Float32` payloads. Every
/// search performs a complete O(n) scan of the resident array. This is
/// correct and required — it is the float lane's conformance oracle.
///
/// Metrics: `Float(FloatMetric::Cosine)`, `Float(FloatMetric::L2)`,
/// `Float(FloatMetric::Dot)`. Passing a binary metric throws
/// `VectorKitError::InvalidPayload`.
///
/// Float determinism: reproducible within one build/config. NOT
/// four-way bit-identical across Swift and Rust. See module docstring.
pub struct FloatBruteForceIndex {
    /// The packed resident array backing all searches. None before
    /// the first build() call; search on None returns empty.
    array: Option<ResidentVectorArray>,
}

impl FloatBruteForceIndex {
    /// Construct an empty index.
    pub fn new() -> Self {
        FloatBruteForceIndex { array: None }
    }

    /// k-FARTHEST neighbours by a float metric — the most DISSIMILAR
    /// vectors first (anti-similarity retrieval, mission 6b-modifiers-antisim).
    /// Parallel to Swift `FloatBruteForceIndex.searchFarthest`.
    ///
    /// Reuses the exact same linear scan and cosine distance as `search`;
    /// the ONLY difference is the sort: distance DESCENDING (largest cosine
    /// distance = smallest cosine similarity = most dissimilar) instead of
    /// ascending. No new distance math (mission guardrail). Tie-break stays
    /// `item_id` ASCENDING, identical to `search`, so the determinism
    /// contract holds in both directions.
    ///
    /// Errors are the same `InvalidPayload` cases as `search`.
    pub fn search_farthest(
        &self,
        probe: &VectorPayload,
        metric: DenseMetric,
        k: usize,
        filter: Option<&MetadataFilter>,
    ) -> Result<Vec<DenseHit>, VectorKitError> {
        self.search_directed(probe, metric, k, filter, SearchDirection::Farthest)
    }

    /// Shared scan-and-rank for both directions. `search` (the trait method)
    /// calls this with `Nearest`; `search_farthest` calls it with `Farthest`.
    /// The validation, scan, and cosine arithmetic are identical for both —
    /// only the ordering differs.
    fn search_directed(
        &self,
        probe: &VectorPayload,
        metric: DenseMetric,
        k: usize,
        filter: Option<&MetadataFilter>,
        direction: SearchDirection,
    ) -> Result<Vec<DenseHit>, VectorKitError> {
        if probe.kind != VectorKind::Float32 {
            return Err(VectorKitError::InvalidPayload(format!(
                "FloatBruteForceIndex.search: probe.kind={:?}; expected Float32",
                probe.kind
            )));
        }
        let float_metric = match metric {
            DenseMetric::Float(fm) => fm,
            _ => {
                return Err(VectorKitError::InvalidPayload(format!(
                    "FloatBruteForceIndex.search: metric={:?} is not a float metric; use the binary lane for binary metrics",
                    metric
                )));
            }
        };

        let arr = match &self.array {
            None => return Ok(vec![]),
            Some(a) => a,
        };
        if arr.kind != VectorKind::Float32 {
            return Err(VectorKitError::InvalidPayload(format!(
                "FloatBruteForceIndex.search: resident array kind={:?}; expected Float32",
                arr.kind
            )));
        }
        if arr.stride == 0 {
            return Ok(vec![]);
        }
        let dim = arr.stride / 4;
        if probe.bytes.len() != arr.stride {
            return Err(VectorKitError::InvalidPayload(format!(
                "FloatBruteForceIndex.search: probe byte count {} does not match array stride {}",
                probe.bytes.len(),
                arr.stride
            )));
        }

        let probe_floats = decode_f32_le(&probe.bytes);

        // Collect scored candidates (shared scan — same cosine for both directions).
        let mut scored: Vec<(f32, &VectorRecordKey)> = Vec::with_capacity(arr.count);
        for i in 0..arr.count {
            if arr.is_tombstoned(i) {
                continue;
            }
            if i >= arr.keys.len() {
                continue;
            }
            let key = &arr.keys[i];
            if let Some(f) = filter {
                if !f.accepts(key) {
                    continue;
                }
            }
            let slot_bytes = arr.vector_bytes(i);
            let slot_floats = decode_f32_le(slot_bytes);
            let candidate: Vec<f32> = if slot_floats.len() == dim {
                slot_floats
            } else {
                let mut v = slot_floats;
                v.resize(dim, 0.0);
                v
            };
            let dist = float_distance(&probe_floats, &candidate, float_metric);
            scored.push((dist, key));
        }

        // Sort by direction; tie-break is key ascending in BOTH directions.
        //   Nearest  → distance ascending  (smallest cosine distance first).
        //   Farthest → distance descending (largest cosine distance first =
        //              most dissimilar first, anti-similarity).
        scored.sort_by(|a, b| {
            let primary = match direction {
                SearchDirection::Nearest => a.0.partial_cmp(&b.0),
                SearchDirection::Farthest => b.0.partial_cmp(&a.0),
            }
            .unwrap_or(std::cmp::Ordering::Equal);
            primary.then(a.1.cmp(b.1))
        });

        // Take top k and convert to DenseHit.
        let results: Vec<DenseHit> = scored
            .iter()
            .take(k)
            .map(|(dist, key)| {
                let raw = float_to_raw(*dist);
                DenseHit {
                    key: (*key).clone(),
                    raw_distance: raw,
                    metric,
                }
            })
            .collect();

        Ok(results)
    }
}

impl Default for FloatBruteForceIndex {
    fn default() -> Self {
        Self::new()
    }
}

impl DenseIndex for FloatBruteForceIndex {
    fn kind(&self) -> IndexKind {
        IndexKind::BruteForce
    }

    /// (Re-)build the index from a resident array.
    ///
    /// For FloatBruteForceIndex the array IS the index. O(1) — the scan
    /// happens at search time.
    fn build(
        &mut self,
        vectors: &[VectorPayload],
        keys: &[VectorRecordKey],
    ) -> Result<(), VectorKitError> {
        // Build a ResidentVectorArray from the provided vectors and keys.
        // All vectors must be Float32 and have the same byte length.
        if vectors.is_empty() {
            self.array = Some(ResidentVectorArray::empty(VectorKind::Float32, 0));
            return Ok(());
        }
        let stride = vectors[0].bytes.len();
        if !vectors.iter().all(|v| v.kind == VectorKind::Float32 && v.bytes.len() == stride) {
            return Err(VectorKitError::InvalidPayload(
                "FloatBruteForceIndex.build: all vectors must be Float32 with identical byte length".into(),
            ));
        }
        let storage: Vec<u8> = vectors.iter().flat_map(|v| v.bytes.iter().copied()).collect();
        let count = vectors.len();
        let mut arr = ResidentVectorArray {
            kind: VectorKind::Float32,
            stride,
            count,
            storage,
            keys: keys.to_vec(),
            model_partitions: vec![],
            tombstones: vec![],
        };
        arr.model_partitions = build_partitions(&arr.keys);
        self.array = Some(arr);
        Ok(())
    }

    /// k-nearest neighbours by a float metric, optionally filtered.
    ///
    /// Performs a complete linear scan. Results sorted by distance
    /// ascending, ties broken by key ascending (§0.3 tie-break rule).
    ///
    /// Errors:
    /// - `InvalidPayload` if probe.kind is not Float32
    /// - `InvalidPayload` if metric is not a float metric
    /// - `InvalidPayload` if probe byte length does not match stride
    fn search(
        &self,
        probe: &VectorPayload,
        metric: DenseMetric,
        k: usize,
        filter: Option<&MetadataFilter>,
    ) -> Result<Vec<DenseHit>, VectorKitError> {
        // Nearest = smaller cosine distance first (the DenseIndex contract).
        // The shared scan-and-rank lives in `search_directed`; `search_farthest`
        // (the anti-similarity sibling) calls it with the opposite direction.
        self.search_directed(probe, metric, k, filter, SearchDirection::Nearest)
    }

    /// Add a single float32 vector record to the index.
    ///
    /// Appends to the existing resident array. The slot is immediately
    /// searchable without a rebuild() call (unlike the binary BruteForceIndex
    /// which may require a build from the ResidentArrayStore).
    fn add(
        &mut self,
        key: VectorRecordKey,
        vector: VectorPayload,
    ) -> Result<(), VectorKitError> {
        if vector.kind != VectorKind::Float32 {
            return Err(VectorKitError::InvalidPayload(format!(
                "FloatBruteForceIndex.add: vector.kind={:?}; expected Float32",
                vector.kind
            )));
        }
        let stride = vector.bytes.len();
        let arr = self.array.get_or_insert_with(|| {
            ResidentVectorArray::empty(VectorKind::Float32, stride)
        });

        arr.storage.extend_from_slice(&vector.bytes);
        arr.keys.push(key);
        arr.count += 1;
        arr.model_partitions = build_partitions(&arr.keys);
        Ok(())
    }

    /// Mark the record identified by key as tombstoned.
    fn remove(&mut self, key: &VectorRecordKey) -> Result<(), VectorKitError> {
        let arr = match &mut self.array {
            None => return Ok(()),
            Some(a) => a,
        };
        let slot = match arr.keys.iter().position(|k| k == key) {
            None => return Ok(()), // not present: no-op
            Some(i) => i,
        };
        // Set bit `slot` in the tombstone bitset.
        let word = slot / 64;
        let bit  = slot % 64;
        while arr.tombstones.len() <= word {
            arr.tombstones.push(0u64);
        }
        arr.tombstones[word] |= 1u64 << bit;
        Ok(())
    }
}

// MARK: - Float distance functions

/// Compute the float distance between two float32 vectors.
///
/// Determinism boundary: reproducible within one build/config on one
/// platform. NOT four-way bit-identical (arch spec §6).
fn float_distance(probe: &[f32], candidate: &[f32], metric: FloatMetric) -> f32 {
    match metric {
        FloatMetric::Cosine => cosine_distance(probe, candidate),
        FloatMetric::L2     => l2_distance(probe, candidate),
        FloatMetric::Dot    => -dot_product(probe, candidate), // negate for "smaller = nearer"
    }
}

/// Cosine distance: 1 − cos(a, b).
///
/// Returns 1.0 when either vector is all-zero (safe fallback; undefined
/// cosine treated as maximum distance to avoid surfacing zero vectors
/// as spurious nearest neighbours).
fn cosine_distance(a: &[f32], b: &[f32]) -> f32 {
    let mut dot = 0.0_f32;
    let mut norm_a = 0.0_f32;
    let mut norm_b = 0.0_f32;
    let n = a.len().min(b.len());
    for i in 0..n {
        dot   += a[i] * b[i];
        norm_a += a[i] * a[i];
        norm_b += b[i] * b[i];
    }
    let denom = norm_a.sqrt() * norm_b.sqrt();
    if denom == 0.0 {
        return 1.0;
    }
    // Clamp to [-1, 1] to guard against sqrt rounding.
    let cosine_sim = (dot / denom).clamp(-1.0, 1.0);
    1.0 - cosine_sim
}

/// L2 (Euclidean) distance: √Σ(aᵢ − bᵢ)².
fn l2_distance(a: &[f32], b: &[f32]) -> f32 {
    let n = a.len().min(b.len());
    let sum: f32 = (0..n).map(|i| { let d = a[i] - b[i]; d * d }).sum();
    sum.sqrt()
}

/// Inner (dot) product: Σ(aᵢ × bᵢ). Caller negates for "smaller = nearer".
fn dot_product(a: &[f32], b: &[f32]) -> f32 {
    let n = a.len().min(b.len());
    (0..n).map(|i| a[i] * b[i]).sum()
}

/// Decode a byte slice as `dim` IEEE-754 little-endian f32 values.
fn decode_f32_le(bytes: &[u8]) -> Vec<f32> {
    bytes
        .chunks_exact(4)
        .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect()
}

/// Convert a float distance to the Rust DenseHit raw_distance convention:
/// `raw = (dist × 10_000) as i32`.
///
/// This matches the DenseHit.float_distance() inverse: `raw as f32 / 10_000.0`.
/// The 4-decimal-place quantisation is sufficient for all float metrics
/// (cosine ∈ [-1,2], L2 ∈ [0, ∞), dot is negated before storing).
///
/// Clamps to i32::MIN..=i32::MAX for very large L2 distances.
fn float_to_raw(dist: f32) -> i32 {
    let scaled = dist * 10_000.0;
    if scaled.is_nan() || scaled.is_infinite() {
        return if scaled > 0.0 { i32::MAX } else { i32::MIN };
    }
    (scaled as i64).clamp(i32::MIN as i64, i32::MAX as i64) as i32
}

// MARK: - Model partition builder

/// Build a sorted model partition list from a keys slice.
///
/// Iterates keys in order and records runs that share the same model_id.
/// Does not require keys to be sorted by model_id; records the actual
/// layout.
use crate::engine::resident::ModelPartitionEntry;

fn build_partitions(keys: &[VectorRecordKey]) -> Vec<ModelPartitionEntry> {
    if keys.is_empty() {
        return vec![];
    }
    let mut result = Vec::new();
    let mut run_start = 0;
    let mut run_model = keys[0].model_id.clone();
    for i in 1..keys.len() {
        if keys[i].model_id != run_model {
            result.push(ModelPartitionEntry::new(run_model.clone(), run_start, i));
            run_start = i;
            run_model = keys[i].model_id.clone();
        }
    }
    result.push(ModelPartitionEntry::new(run_model, run_start, keys.len()));
    result
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::metric::DenseMetric;
    use crate::engine::payload::VectorPayload;
    use crate::engine::seam::MetadataFilter;

    fn key(item_id: &str) -> VectorRecordKey {
        VectorRecordKey::new(item_id, 0, "model", "1")
    }

    fn fp(floats: &[f32]) -> VectorPayload {
        VectorPayload::from_f32(floats)
    }

    // MARK: - Build

    #[test]
    fn build_empty_array_returns_empty_search() {
        let mut idx = FloatBruteForceIndex::new();
        idx.build(&[], &[]).unwrap();
        let probe = fp(&[1.0, 0.0]);
        let results = idx
            .search(&probe, DenseMetric::COSINE, 5, None)
            .unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn search_before_build_returns_empty() {
        let idx = FloatBruteForceIndex::new();
        let probe = fp(&[1.0, 0.0]);
        let results = idx.search(&probe, DenseMetric::COSINE, 5, None).unwrap();
        assert!(results.is_empty());
    }

    // MARK: - Cosine

    #[test]
    fn cosine_identical_vectors_distance_near_zero() {
        let mut idx = FloatBruteForceIndex::new();
        let v = vec![0.6_f32, 0.8];
        idx.build(&[fp(&v)], &[key("a")]).unwrap();
        let results = idx.search(&fp(&v), DenseMetric::COSINE, 1, None).unwrap();
        assert_eq!(results.len(), 1);
        let dist = results[0].float_distance().unwrap();
        assert!(dist.abs() < 1e-3, "expected ~0 cosine distance, got {}", dist);
    }

    #[test]
    fn cosine_orthogonal_vectors_distance_near_one() {
        let mut idx = FloatBruteForceIndex::new();
        idx.build(
            &[fp(&[1.0_f32, 0.0]), fp(&[0.0, 1.0])],
            &[key("a"), key("b")],
        )
        .unwrap();
        let results = idx
            .search(&fp(&[1.0, 0.0]), DenseMetric::COSINE, 2, None)
            .unwrap();
        assert_eq!(results.len(), 2);
        assert_eq!(results[0].key.item_id, "a");
        let dist_a = results[0].float_distance().unwrap();
        let dist_b = results[1].float_distance().unwrap();
        assert!(dist_a.abs() < 1e-3, "a distance should be ~0, got {}", dist_a);
        assert!((dist_b - 1.0).abs() < 1e-3, "b distance should be ~1, got {}", dist_b);
    }

    #[test]
    fn cosine_zero_vector_fallback_distance_one() {
        let mut idx = FloatBruteForceIndex::new();
        idx.build(&[fp(&[0.0_f32, 0.0, 0.0])], &[key("zero")]).unwrap();
        let results = idx
            .search(&fp(&[1.0, 0.0, 0.0]), DenseMetric::COSINE, 1, None)
            .unwrap();
        assert_eq!(results.len(), 1);
        let dist = results[0].float_distance().unwrap();
        assert!((dist - 1.0).abs() < 1e-3, "zero-vector fallback should be 1.0, got {}", dist);
    }

    // MARK: - L2

    #[test]
    fn l2_identical_distance_zero() {
        let mut idx = FloatBruteForceIndex::new();
        let v = vec![3.0_f32, 4.0];
        idx.build(&[fp(&v)], &[key("a")]).unwrap();
        let results = idx.search(&fp(&v), DenseMetric::L2, 1, None).unwrap();
        let dist = results[0].float_distance().unwrap();
        assert!(dist.abs() < 1e-3, "identical L2 distance should be 0, got {}", dist);
    }

    #[test]
    fn l2_pythagorean_triple() {
        let mut idx = FloatBruteForceIndex::new();
        idx.build(&[fp(&[0.0_f32, 0.0])], &[key("origin")]).unwrap();
        let results = idx
            .search(&fp(&[3.0, 4.0]), DenseMetric::L2, 1, None)
            .unwrap();
        let dist = results[0].float_distance().unwrap();
        assert!((dist - 5.0).abs() < 0.01, "expected distance 5, got {}", dist);
    }

    #[test]
    fn l2_nearest_of_three() {
        let mut idx = FloatBruteForceIndex::new();
        idx.build(
            &[fp(&[10.0_f32, 0.0]), fp(&[3.0, 0.0]), fp(&[1.0, 0.0])],
            &[key("far"), key("medium"), key("near")],
        )
        .unwrap();
        let results = idx
            .search(&fp(&[0.0, 0.0]), DenseMetric::L2, 3, None)
            .unwrap();
        assert_eq!(results[0].key.item_id, "near");
        assert_eq!(results[1].key.item_id, "medium");
        assert_eq!(results[2].key.item_id, "far");
    }

    // MARK: - Dot

    #[test]
    fn dot_higher_product_ranks_first() {
        let mut idx = FloatBruteForceIndex::new();
        idx.build(
            &[fp(&[0.1_f32, 0.0]), fp(&[1.0, 0.0])],
            &[key("weak"), key("strong")],
        )
        .unwrap();
        let results = idx
            .search(&fp(&[1.0, 0.0]), DenseMetric::DOT, 2, None)
            .unwrap();
        // "strong" has higher dot → lower negated distance → ranks first
        assert_eq!(results[0].key.item_id, "strong");
        assert_eq!(results[1].key.item_id, "weak");
    }

    // MARK: - Errors

    #[test]
    fn search_rejects_binary_probe() {
        let idx = FloatBruteForceIndex::new();
        let binary_payload = VectorPayload {
            kind: VectorKind::Binary,
            dim: 256,
            bytes: vec![0u8; 32],
            scale: None,
        };
        assert!(idx.search(&binary_payload, DenseMetric::COSINE, 1, None).is_err());
    }

    #[test]
    fn search_rejects_binary_metric() {
        let mut idx = FloatBruteForceIndex::new();
        idx.build(&[fp(&[1.0_f32, 0.0])], &[key("a")]).unwrap();
        assert!(idx.search(&fp(&[1.0, 0.0]), DenseMetric::HAMMING, 1, None).is_err());
    }

    #[test]
    fn search_rejects_dim_mismatch() {
        let mut idx = FloatBruteForceIndex::new();
        idx.build(&[fp(&[1.0_f32, 0.0, 0.0])], &[key("a")]).unwrap(); // dim=3
        assert!(idx.search(&fp(&[1.0_f32, 0.0]), DenseMetric::COSINE, 1, None).is_err()); // dim=2
    }

    #[test]
    fn add_rejects_binary_vector() {
        let mut idx = FloatBruteForceIndex::new();
        let binary_payload = VectorPayload {
            kind: VectorKind::Binary,
            dim: 256,
            bytes: vec![0u8; 32],
            scale: None,
        };
        assert!(idx.add(key("x"), binary_payload).is_err());
    }

    // MARK: - Tie-break

    #[test]
    fn tie_break_by_item_id_ascending() {
        let mut idx = FloatBruteForceIndex::new();
        let v = vec![1.0_f32, 0.0];
        // Three identical vectors — all equidistant from probe.
        idx.build(
            &[fp(&v), fp(&v), fp(&v)],
            &[key("zzz"), key("aaa"), key("mmm")],
        )
        .unwrap();
        let results = idx
            .search(&fp(&v), DenseMetric::COSINE, 3, None)
            .unwrap();
        assert_eq!(results.len(), 3);
        assert_eq!(results[0].key.item_id, "aaa");
        assert_eq!(results[1].key.item_id, "mmm");
        assert_eq!(results[2].key.item_id, "zzz");
    }

    // MARK: - Farthest (anti-similarity, mission 6b-modifiers-antisim)

    #[test]
    fn farthest_returns_most_dissimilar_first() {
        let mut idx = FloatBruteForceIndex::new();
        idx.build(
            &[fp(&[1.0_f32, 0.0]), fp(&[1.0, 1.0]), fp(&[-1.0, 0.0])],
            &[key("a"), key("b"), key("c")],
        )
        .unwrap();
        let results = idx
            .search_farthest(&fp(&[1.0, 0.0]), DenseMetric::COSINE, 3, None)
            .unwrap();
        assert_eq!(results.len(), 3);
        assert_eq!(results[0].key.item_id, "c"); // most dissimilar first
        assert_eq!(results[1].key.item_id, "b");
        assert_eq!(results[2].key.item_id, "a"); // most similar last
    }

    #[test]
    fn farthest_is_reverse_of_nearest_on_distinct_distances() {
        let mut idx = FloatBruteForceIndex::new();
        idx.build(
            &[fp(&[1.0_f32, 0.0]), fp(&[1.0, 1.0]), fp(&[-1.0, 0.0])],
            &[key("near"), key("mid"), key("far")],
        )
        .unwrap();
        let probe = fp(&[1.0, 0.0]);
        let nearest = idx.search(&probe, DenseMetric::COSINE, 3, None).unwrap();
        let farthest = idx
            .search_farthest(&probe, DenseMetric::COSINE, 3, None)
            .unwrap();
        let n: Vec<&str> = nearest.iter().map(|h| h.key.item_id.as_str()).collect();
        let f: Vec<&str> = farthest.iter().map(|h| h.key.item_id.as_str()).collect();
        assert_eq!(n, vec!["near", "mid", "far"]);
        assert_eq!(f, vec!["far", "mid", "near"]);
    }

    #[test]
    fn farthest_tie_break_by_item_id_ascending() {
        let mut idx = FloatBruteForceIndex::new();
        let v = vec![1.0_f32, 0.0];
        // Three identical vectors → identical distance; tie-break must be
        // item_id ASCENDING in BOTH directions (the determinism contract).
        idx.build(
            &[fp(&v), fp(&v), fp(&v)],
            &[key("zzz"), key("aaa"), key("mmm")],
        )
        .unwrap();
        let results = idx
            .search_farthest(&fp(&v), DenseMetric::COSINE, 3, None)
            .unwrap();
        let ids: Vec<&str> = results.iter().map(|h| h.key.item_id.as_str()).collect();
        assert_eq!(ids, vec!["aaa", "mmm", "zzz"]);
    }

    #[test]
    fn farthest_respects_filter() {
        let mut idx = FloatBruteForceIndex::new();
        let ka = VectorRecordKey::new("a", 0, "model-a", "1");
        let kb = VectorRecordKey::new("b", 0, "model-a", "1");
        let kz = VectorRecordKey::new("z", 0, "model-b", "1");
        idx.build(
            &[fp(&[1.0_f32, 0.0]), fp(&[-1.0, 0.0]), fp(&[-1.0, 0.0])],
            &[ka, kb, kz],
        )
        .unwrap();
        let filter = MetadataFilter {
            model_id: Some("model-a".to_string()),
            model_version: None,
        };
        let results = idx
            .search_farthest(&fp(&[1.0, 0.0]), DenseMetric::COSINE, 1, Some(&filter))
            .unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].key.item_id, "b"); // dissimilar model-a row
    }

    #[test]
    fn farthest_rejects_binary_metric() {
        let mut idx = FloatBruteForceIndex::new();
        idx.build(&[fp(&[1.0_f32, 0.0])], &[key("a")]).unwrap();
        assert!(idx
            .search_farthest(&fp(&[1.0, 0.0]), DenseMetric::HAMMING, 1, None)
            .is_err());
    }

    #[test]
    fn k_larger_than_corpus_returns_all() {
        let mut idx = FloatBruteForceIndex::new();
        idx.build(
            &[fp(&[1.0_f32, 0.0]), fp(&[0.0, 1.0])],
            &[key("a"), key("b")],
        )
        .unwrap();
        let results = idx
            .search(&fp(&[1.0, 0.0]), DenseMetric::COSINE, 100, None)
            .unwrap();
        assert_eq!(results.len(), 2);
    }

    // MARK: - Filter

    #[test]
    fn filter_by_model_id_excludes_other_models() {
        let mut idx = FloatBruteForceIndex::new();
        let v = fp(&[1.0_f32, 0.0]);
        let ka = VectorRecordKey::new("a", 0, "model-a", "1");
        let kb = VectorRecordKey::new("b", 0, "model-b", "1");
        idx.build(&[v.clone(), v.clone()], &[ka, kb]).unwrap();
        let filter = MetadataFilter {
            model_id: Some("model-a".to_string()),
            model_version: None,
        };
        let results = idx
            .search(&v, DenseMetric::COSINE, 5, Some(&filter))
            .unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].key.item_id, "a");
    }

    // MARK: - Tombstone

    #[test]
    fn tombstoned_slot_excluded_from_search() {
        let mut idx = FloatBruteForceIndex::new();
        let v = fp(&[1.0_f32, 0.0]);
        idx.build(
            &[v.clone(), fp(&[0.0, 1.0])],
            &[key("a"), key("b")],
        )
        .unwrap();
        idx.remove(&key("a")).unwrap();
        let results = idx
            .search(&v, DenseMetric::COSINE, 5, None)
            .unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].key.item_id, "b");
    }

    // MARK: - Incremental add

    #[test]
    fn add_then_search_finds_added_vector() {
        let mut idx = FloatBruteForceIndex::new();
        let v = fp(&[1.0_f32, 0.0]);
        idx.add(key("added"), v.clone()).unwrap();
        let results = idx.search(&v, DenseMetric::COSINE, 1, None).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].key.item_id, "added");
    }

    // MARK: - Reproducibility

    #[test]
    fn cosine_search_is_reproducible() {
        // Float lane: reproducible within one build/config (arch spec §6).
        // Same inputs → same outputs on the same platform. Does NOT assert
        // cross-platform or cross-build bit-identity.
        let mut idx = FloatBruteForceIndex::new();
        idx.build(
            &[fp(&[0.6_f32, 0.8]), fp(&[0.0, 1.0]), fp(&[0.8, 0.6])],
            &[key("a"), key("b"), key("c")],
        )
        .unwrap();
        let probe = fp(&[0.707_f32, 0.707]);

        let first = idx.search(&probe, DenseMetric::COSINE, 3, None).unwrap();
        let second = idx.search(&probe, DenseMetric::COSINE, 3, None).unwrap();

        let ids_first: Vec<_>  = first.iter().map(|h| &h.key.item_id).collect();
        let ids_second: Vec<_> = second.iter().map(|h| &h.key.item_id).collect();
        assert_eq!(ids_first, ids_second);
        let raw_first: Vec<_>  = first.iter().map(|h| h.raw_distance).collect();
        let raw_second: Vec<_> = second.iter().map(|h| h.raw_distance).collect();
        assert_eq!(raw_first, raw_second);
    }
}
