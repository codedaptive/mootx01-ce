//! ResidentVectorArray — packed fixed-stride in-memory array.
//!
//! Parallel to Swift `ResidentVectorArray`. Holds all vectors for a
//! single lane (kind + stride) in one contiguous byte slice, with a
//! separate keys vec and a model-partition map for constant-time range
//! lookup by model_id.
//!
//! Tombstones use a compact bitset: bit `i` in `tombstones[i/64]` at
//! position `i % 64` marks slot `i` as logically deleted. The brute-force
//! scanner skips tombstoned slots. Compaction of this low-level struct is
//! triggered by the concrete index calling `build()`. The higher-level
//! `ResidentArrayStore` that wraps this struct auto-compacts (in-memory
//! array + sidecar) once the tombstone ratio crosses the 0.25 threshold on
//! a write — compaction is neither deferred nor missing at that layer.

use crate::engine::key::VectorRecordKey;
use crate::engine::payload::VectorKind;

/// Model partition: a contiguous run of slots sharing the same
/// `model_id` in a sorted `ResidentVectorArray`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModelPartitionEntry {
    pub model_id: String,
    /// Inclusive start index within the array.
    pub start: usize,
    /// Exclusive end index (one past the last slot for this model).
    pub end: usize,
}

impl ModelPartitionEntry {
    pub fn new(model_id: impl Into<String>, start: usize, end: usize) -> Self {
        ModelPartitionEntry {
            model_id: model_id.into(),
            start,
            end,
        }
    }

    pub fn range(&self) -> std::ops::Range<usize> {
        self.start..self.end
    }
}

/// Packed in-memory array of vectors for one lane.
///
/// All slots have the same kind and stride (byte width per vector):
/// - Binary: stride = 32 (256 bits = 4 × u64)
/// - Float32: stride = dim × 4
/// - Int8: stride = dim × 1
#[derive(Debug, Clone)]
pub struct ResidentVectorArray {
    pub kind: VectorKind,
    /// Byte count per vector slot.
    pub stride: usize,
    /// Total number of allocated vector slots, including tombstoned slots.
    ///
    /// This is the slot count of the storage block, NOT the live record
    /// count. After tombstoning, some slots are logically deleted but still
    /// occupy space in storage until compaction. Use `live_count()` to get
    /// the number of non-tombstoned slots; stale detection compares
    /// live_count() against the table binary-row count (C5 fix).
    pub count: usize,
    /// Raw bytes: count × stride. storage.len() == count * stride.
    pub storage: Vec<u8>,
    /// Key for each slot. keys.len() == count.
    pub keys: Vec<VectorRecordKey>,
    /// Model partitions (sorted, non-overlapping, covering [0, count)).
    pub model_partitions: Vec<ModelPartitionEntry>,
    /// Tombstone bitset. tombstones.len() == (count + 63) / 64.
    /// Bit `i % 64` of `tombstones[i / 64]` is 1 when slot `i` is
    /// logically deleted.
    pub tombstones: Vec<u64>,
}

impl ResidentVectorArray {
    /// Construct an empty array for the given kind and stride.
    pub fn empty(kind: VectorKind, stride: usize) -> Self {
        ResidentVectorArray {
            kind,
            stride,
            count: 0,
            storage: Vec::new(),
            keys: Vec::new(),
            model_partitions: Vec::new(),
            tombstones: Vec::new(),
        }
    }

    /// Number of live (non-tombstoned) slots in this array.
    ///
    /// Computed from the tombstone bitmap; O(count/64) to walk the words.
    /// Used by stale detection in `VectorStore.ensure_index_built_locked`
    /// to compare the sidecar live count against the table binary-row
    /// count — both represent the number of live records, so a match means
    /// the sidecar is up-to-date (C5 fix).
    ///
    /// Also written to the sidecar header's `live_count` field on save;
    /// on load the field is read and discarded — stale detection recomputes
    /// live count from the tombstone bitmap.
    pub fn live_count(&self) -> usize {
        (0..self.count).filter(|&i| !self.is_tombstoned(i)).count()
    }

    /// Return the byte slice for slot `i`. Panics if `i >= count`.
    pub fn vector_bytes(&self, i: usize) -> &[u8] {
        let start = i * self.stride;
        &self.storage[start..start + self.stride]
    }

    /// Return true if slot `i` is tombstoned (logically deleted).
    pub fn is_tombstoned(&self, i: usize) -> bool {
        let word = i / 64;
        let bit = i % 64;
        if word >= self.tombstones.len() {
            false
        } else {
            (self.tombstones[word] >> bit) & 1 == 1
        }
    }

    /// Return the slot range for `model_id` via binary search on the
    /// sorted partitions vec. Returns `None` if the model_id is absent.
    pub fn partition_range(&self, model_id: &str) -> Option<std::ops::Range<usize>> {
        // Binary search on the sorted model_partitions.
        let idx = self
            .model_partitions
            .binary_search_by(|p| p.model_id.as_str().cmp(model_id));
        match idx {
            Ok(i) => Some(self.model_partitions[i].range()),
            Err(_) => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::payload::VectorKind;

    #[test]
    fn empty_array_has_zero_count() {
        let arr = ResidentVectorArray::empty(VectorKind::Binary, 32);
        assert_eq!(arr.count, 0);
        assert!(arr.keys.is_empty());
    }

    #[test]
    fn tombstone_bit_set_and_check() {
        let mut arr = ResidentVectorArray::empty(VectorKind::Binary, 32);
        arr.count = 3;
        arr.tombstones = vec![0u64]; // one u64 word covers 64 slots
        // Slot 1: set bit 1
        arr.tombstones[0] |= 1 << 1;
        assert!(!arr.is_tombstoned(0));
        assert!(arr.is_tombstoned(1));
        assert!(!arr.is_tombstoned(2));
    }

    #[test]
    fn partition_range_binary_search() {
        let mut arr = ResidentVectorArray::empty(VectorKind::Binary, 32);
        arr.count = 6;
        arr.model_partitions = vec![
            ModelPartitionEntry::new("model-a", 0, 3),
            ModelPartitionEntry::new("model-b", 3, 6),
        ];
        assert_eq!(arr.partition_range("model-a"), Some(0..3));
        assert_eq!(arr.partition_range("model-b"), Some(3..6));
        assert_eq!(arr.partition_range("model-c"), None);
    }
}
