// ResidentVectorArray.swift
//
// The packed hot-path resident array: the heart of the dense engine.
//
// Lane F foundation type. Every search index (BruteForceIndex in Lane A,
// MIHIndex in Lane B, FloatBruteForceIndex in Lane C) reads from a
// ResidentVectorArray. It is defined here so all lanes share the same
// in-memory format without mutual dependencies.
//
// Design:
//   - Fixed stride + contiguous = a kernel scan is a linear walk with no
//     per-row decode or allocation. Measured split on the current
//     VectorStore.findNearest: fetch+decode=87% of latency, kernel=0.4%.
//     Loading the array once amortises the fetch cost across all queries.
//     (arch spec §3.2)
//   - The `keys` array is parallel to the vectors: keys[i] identifies the
//     record at byte offset i*stride in the storage block.
//   - Model partitioning: a sorted [(modelID, range)] slice index lets
//     a model-scoped scan walk only the vectors for that model. Build
//     this index from the sorted key array in O(n).
//
// Thread-safety: ResidentVectorArray is a struct (value type). Mutation
// (append, tombstone) is safe only from the actor that owns it. Read-only
// access (scan) is safe to share.
//
// Binary conformance: the logical layout here (kind, stride, count,
// packed bytes[], parallel keys[]) must match the on-disk .vec sidecar
// format defined in arch spec §4.2. The ResidentArrayStore (Lane A) is
// responsible for write/load/mmap; this type is the in-memory
// representation. The two must agree on stride and key ordering.
//
// Lane F only defines the type. Lane A (BruteForceIndex +
// ResidentArrayStore) builds it from the `vectors` table and maintains
// it.

import Foundation

// MARK: - Model partition

/// One entry in the model partition index: a modelID and the range of
/// indices in `keys`/storage that belong to that model. Ranges are
/// non-overlapping, sorted by modelID ascending, and together cover
/// 0..<count with no gaps.
public struct ModelPartitionEntry: Sendable, Equatable {
    /// The model this partition covers.
    public let modelID: String
    /// Half-open index range [start, end) into the keys and storage arrays.
    public let range: Range<Int>

    public init(modelID: String, range: Range<Int>) {
        self.modelID = modelID
        self.range = range
    }
}

// MARK: - ResidentVectorArray

/// A packed, fixed-stride, in-memory array of vectors with a parallel
/// key index and a sorted model-partition lookup.
///
/// Ownership and mutation are managed by the Lane A ResidentArrayStore
/// actor. This type is the data contract — the shape every Lane reads.
///
/// Thread-safety: value type. Safe to pass across actors once built.
public struct ResidentVectorArray: Sendable {

    // MARK: - Stored properties

    /// The numeric kind of every vector in this array.
    /// All vectors in one array have the same kind — the engine
    /// does not mix kinds in a single array.
    public let kind: VectorKind

    /// Bytes per vector slot. Binary: 32. Float32: dim×4. Int8: dim.
    /// Fixed for the lifetime of the array.
    public let stride: UInt32

    /// Number of live (non-tombstoned) vector slots.
    ///
    /// Note: after tombstoning, count may differ from
    /// storage.count / stride. The scan must respect the tombstone
    /// bitmap. Compaction resets count to equal the live slot count.
    public let count: UInt32

    /// Raw vector bytes: count × stride bytes, contiguous, packed.
    ///
    /// Slot i occupies bytes[i*stride ..< (i+1)*stride].
    /// All slots are live unless the corresponding tombstone bit is set.
    ///
    /// On Apple platforms this buffer may be mmap-backed (read-only).
    /// On platforms without usable mmap semantics it is heap-allocated.
    /// Both paths produce bit-identical scan results (mmap is a load
    /// optimisation, not a semantic; arch spec §4.3).
    public let storage: [UInt8]

    /// Per-slot record keys, parallel to storage. keys[i] identifies
    /// the record whose vector occupies storage slot i.
    /// Invariant: keys.count == Int(count) after any compaction.
    public let keys: [VectorRecordKey]

    /// Sorted model partition index. Each entry gives a modelID and
    /// the [start, end) range of indices in keys/storage that belong
    /// to that model. Sorted by modelID ascending so a binary search
    /// finds a model's range in O(log m).
    ///
    /// A scan restricted to model_id M walks only
    /// partition(M).range over the storage array.
    public let modelPartitions: [ModelPartitionEntry]

    /// Tombstone bitmap: bit i is set if slot i is logically deleted.
    /// Packed UInt64 words: tombstones[i/64] bit (i%64). The scan
    /// skips tombstoned slots. Compaction drops them and rebuilds
    /// this bitmap as all-zero.
    ///
    /// Using a packed UInt64 bitmap to represent deletion state is
    /// consistent with the no-Bool-stored-property doctrine
    /// (arch spec §4.2 note).
    public let tombstones: [UInt64]

    // MARK: - Computed slot counts

    /// Number of live (non-tombstoned) slots in this array.
    ///
    /// Computed from the tombstone bitmap; O(count/64) to walk the words.
    /// Used by VectorStore stale detection (`_ensureIndexBuilt`) to compare
    /// the sidecar live count against the table binary-row count — both
    /// represent the number of live records, so a match means the sidecar
    /// is up-to-date.
    ///
    /// Recomputed from the tombstone bitmap on each call (an O(count) walk).
    /// The Rust port additionally persists this value in its sidecar header
    /// (format 0x0002) for O(1) stale detection on reopen; the Swift sidecar
    /// recomputes it from the loaded bitmap instead — same result, different
    /// cost profile, both compare live-vs-live.
    public var liveCount: UInt32 {
        var live: UInt32 = 0
        for i in 0..<Int(count) {
            let w = i / 64
            let b = i % 64
            let dead = w < tombstones.count && (tombstones[w] >> UInt64(b)) & 1 == 1
            if !dead { live += 1 }
        }
        return live
    }

    // MARK: - Initialisers

    /// Designated initialiser. Callers are responsible for consistency
    /// between kind, stride, count, storage, keys, and modelPartitions.
    /// The ResidentArrayStore (Lane A) is the only production caller.
    public init(
        kind: VectorKind,
        stride: UInt32,
        count: UInt32,
        storage: [UInt8],
        keys: [VectorRecordKey],
        modelPartitions: [ModelPartitionEntry],
        tombstones: [UInt64]
    ) {
        self.kind = kind
        self.stride = stride
        self.count = count
        self.storage = storage
        self.keys = keys
        self.modelPartitions = modelPartitions
        self.tombstones = tombstones
    }

    /// Convenience: empty array of the given kind.
    ///
    /// The binary lane uses stride 32 (fixed). Float and int8 lanes
    /// require the caller to supply the correct stride from the
    /// embedding model's output dimension.
    public static func empty(kind: VectorKind, stride: UInt32) -> ResidentVectorArray {
        ResidentVectorArray(
            kind: kind,
            stride: stride,
            count: 0,
            storage: [],
            keys: [],
            modelPartitions: [],
            tombstones: []
        )
    }

    // MARK: - Partition lookup

    /// Return the index range for modelID, or nil if this array
    /// contains no vectors for that model.
    public func partitionRange(for modelID: String) -> Range<Int>? {
        // Binary search over sorted modelPartitions.
        var lo = 0
        var hi = modelPartitions.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            let entry = modelPartitions[mid]
            if entry.modelID == modelID {
                return entry.range
            } else if entry.modelID < modelID {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return nil
    }

    // MARK: - Tombstone check

    /// True if slot at index i has been tombstoned (logically deleted).
    ///
    /// Bit i lives in tombstones[i/64] at position i%64 (0 = LSB),
    /// consistent with the canonical bit-numbering of arch spec §0.1.
    public func isTombstoned(_ i: Int) -> Bool {
        let word = i / 64
        let bit  = i % 64
        guard word < tombstones.count else { return false }
        return (tombstones[word] >> bit) & 1 == 1
    }

    // MARK: - Slot accessor

    /// Return the raw bytes for slot i as a subarray.
    ///
    /// Returns nil if i is out of bounds or tombstoned. The bytes
    /// are a copy; the caller may read them without holding a
    /// reference to this array.
    public func vectorBytes(at i: Int) -> [UInt8]? {
        guard i >= 0 && i < Int(count) else { return nil }
        guard !isTombstoned(i) else { return nil }
        let start = i * Int(stride)
        let end   = start + Int(stride)
        guard end <= storage.count else { return nil }
        return Array(storage[start..<end])
    }
}
