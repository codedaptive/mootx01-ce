// BruteForceIndex.swift
//
// Lane A — the binary brute-force dense index and the conformance oracle.
//
// This is the reference implementation against which MIH (Lane B) is
// gated. It performs an exact linear scan over a ResidentVectorArray,
// delegating ALL Hamming arithmetic to EngramLib (which routes through
// SubstrateKernel) per I-7 (arch spec §3.1, §3.4):
//
//   "VectorKit performs NO Hamming math itself — route the distance/top-k
//    through the substrate kernel (EngramLib.findNearest /
//    SubstrateTypes HammingNN), which is already four-way conformance-gated."
//
// This invariant is what makes the binary lane's determinism boundary
// "bit-identical four-way." No Hamming arithmetic appears in this file.
// All XOR/popcount is inside EngramLib → SubstrateKernel.
//
// Deterministic ordering (arch spec §6, retrieval algorithms ref §0.3):
//   distance ASC, then key.itemID ASC.
// This total order matches a brute-force linear scan + sort, which is
// exactly why MIH is gated against this output.
//
// Model-partition slice: when the caller supplies a MetadataFilter with
// a modelID, the scan is restricted to that model's slot range from
// the sorted partition index (O(log m) lookup). Full scan is used when
// no filter is present.
//
// Thread-safety: BruteForceIndex is an actor. All mutation (build, add,
// remove) and reads (search) are serialised through the actor boundary.

import Foundation
import EngramLib
import OSLog

private let log = Logger(subsystem: "com.mootx01.kit", category: "VectorKit")

/// The binary brute-force dense index. Exact Hamming top-k over a
/// ResidentVectorArray. **The conformance oracle**: MIH and all other
/// binary indexes are gated against this output.
///
/// Only `.binary(.hamming)` is supported in Lane A. Callers that
/// request `.binary(.jaccard)` or any float metric receive
/// `VectorKitError.invalidPayload`.
///
/// All Hamming arithmetic is delegated to `EngramLib` (I-7 absolute).
/// Zero Hamming math in this file.
public actor BruteForceIndex: DenseIndex {

    // MARK: - State

    /// The current packed resident array. Replaced on each `build`.
    private var array: ResidentVectorArray

    // MARK: - DenseIndex

    /// This is a brute-force index.
    public nonisolated let kind: IndexKind = .bruteForce

    // MARK: - Init

    /// Construct an empty brute-force index for the binary lane.
    ///
    /// The index accepts `add` calls immediately, or a `build(from:)` to
    /// replace the full array in one shot from a ResidentArrayStore.
    public init() {
        self.array = ResidentVectorArray.empty(kind: .binary, stride: 32)
    }

    // MARK: - DenseIndex — build

    /// Replace the current resident array with `newArray`.
    ///
    /// For brute-force, "building" means replacing the array; there is
    /// no secondary index structure. O(1) reference swap.
    public func build(from newArray: ResidentVectorArray) async {
        array = newArray
    }

    // MARK: - DenseIndex — search

    /// k-nearest binary vectors by Hamming distance (exact linear scan).
    ///
    /// Returns up to k DenseHit values sorted by `(rawDistance ASC, key ASC)`
    /// where the key comparison is the full VectorRecordKey order
    /// (itemID, vectorIndex, modelID, modelVersion). The primary tie-break
    /// is itemID per §0.3; secondary breaks on vectorIndex and modelID
    /// produce a strict total order so that two records sharing the same
    /// itemID but differing in vectorIndex or modelID are both returned
    /// in deterministic order.
    ///
    /// - Parameters:
    ///   - probe: must be `.binary` kind with exactly 32 bytes.
    ///   - metric: must be `.binary(.hamming)`.
    ///   - k: maximum results; may return fewer if fewer live records
    ///     survive the filter.
    ///   - filter: optional model-partition pre-filter. A modelID
    ///     constraint uses the partition index to restrict the scan.
    ///
    /// - Throws: `VectorKitError.invalidPayload` for incompatible probe
    ///   or metric.
    public func search(
        probe: VectorPayload,
        metric: DenseMetric,
        k: Int,
        filter: MetadataFilter?
    ) async throws -> [DenseHit] {
        // --- Input validation ---
        guard probe.kind == .binary else {
            throw VectorKitError.invalidPayload(
                "BruteForceIndex.search: probe.kind must be .binary, got \(probe.kind)")
        }
        guard probe.bytes.count == 32 else {
            throw VectorKitError.invalidPayload(
                "BruteForceIndex.search: binary probe must be exactly 32 bytes, got \(probe.bytes.count)")
        }
        guard case .binary(.hamming) = metric else {
            throw VectorKitError.invalidPayload(
                "BruteForceIndex.search: only .binary(.hamming) is supported in Lane A; got \(metric)")
        }
        guard k > 0 else { return [] }

        // --- Convert probe bytes to Engram ---
        // VectorPayload.asEngram() reconstructs the Engram from the
        // canonical 4×UInt64 LE wire form. No Hamming math here.
        let probeEngram: Engram
        do {
            probeEngram = try probe.asEngram()
        } catch {
            throw VectorKitError.invalidPayload(
                "BruteForceIndex.search: could not decode probe as Engram — \(error)")
        }

        // --- Determine scan range (model-partition slice or full) ---
        // The partition index lets us skip models we don't need. When
        // a modelID filter is present but the model is absent, return
        // empty immediately.
        let scanRange = slotRange(for: filter)
        guard !scanRange.isEmpty else { return [] }

        // --- Collect live Engrams and their keys from the scan range ---
        // `engrams` and `slotIndices` are parallel arrays: engrams[i] is
        // the Engram for slot slotIndices[i]. We pass engrams to EngramLib
        // and use slotIndices to map results back to VectorRecordKeys.
        var engrams: [Engram] = []
        var slotIndices: [Int] = []
        engrams.reserveCapacity(scanRange.count)
        slotIndices.reserveCapacity(scanRange.count)

        for slotIdx in scanRange {
            // Skip tombstoned slots.
            guard !array.isTombstoned(slotIdx) else { continue }
            // Apply per-slot metadata filter (modelVersion etc.)
            let key = array.keys[slotIdx]
            if let f = filter, !f.accepts(key) { continue }
            // Reconstruct Engram from packed slot bytes. Corrupted slots
            // are skipped with a diagnostic log — the scan must not abort
            // on a single bad row.
            guard let bytes = array.vectorBytes(at: slotIdx) else { continue }
            do {
                let slot = VectorPayload(kind: .binary, dim: 256, bytes: bytes)
                engrams.append(try slot.asEngram())
                slotIndices.append(slotIdx)
            } catch {
                log.error("BruteForceIndex: skipping corrupted slot \(slotIdx): \(error)")
            }
        }

        guard !engrams.isEmpty else { return [] }

        // --- Delegate ALL Hamming computation to EngramLib (I-7) ---
        // EngramLib.distances routes to SubstrateKernel.hammingDistanceBatch,
        // which is four-way conformance-gated. We use the batch-distance
        // API (not findNearest) so we get ALL distances and can apply the
        // correct total order ourselves.
        //
        // We do NOT use EngramLib.findNearest here because it applies an
        // insertion-order tie-break (by array index), while the oracle
        // contract requires itemID-ascending tie-break. Using only the
        // distances — the actual Hamming math — and sorting ourselves
        // is the correct division of labour: EngramLib provides the
        // kernel-gated distances, we provide the total order.
        let distances = EngramLib.distances(probe: probeEngram, candidates: engrams)

        // --- Build DenseHit list for all live candidates ---
        var allHits: [DenseHit] = (0..<engrams.count).map { i in
            let slotIdx = slotIndices[i]
            return DenseHit(key: array.keys[slotIdx], hammingDistance: distances[i])
        }

        // --- Sort to enforce total order: (distance ASC, key ASC) ---
        // The primary order is distance ASC (§0.3). The tie-break uses the
        // full VectorRecordKey comparison — (itemID, vectorIndex, modelID,
        // modelVersion) — which is a strict total order. Using the full key
        // (rather than just itemID) ensures deterministic results when two
        // distinct records share the same itemID but differ in vectorIndex
        // or modelID (the VectorStore UNIQUE constraint is
        // (item_id, vector_index, model_id), so both records are valid and
        // must each be returned). Sorting first guarantees that among
        // candidates tied at the k-th boundary distance, the ones with
        // smaller keys are kept — not the ones that happen to be first in
        // the array.
        allHits.sort { lhs, rhs in
            if lhs.rawDistance != rhs.rawDistance {
                return lhs.rawDistance < rhs.rawDistance
            }
            return lhs.key < rhs.key
        }

        // Truncate to k after sorting.
        if allHits.count > k { allHits = Array(allHits.prefix(k)) }
        return allHits
    }

    // MARK: - DenseIndex — add

    /// Add one binary vector record to the index.
    ///
    /// If a record with the same `VectorRecordKey` already exists, the
    /// existing slot is tombstoned before the new one is appended (upsert
    /// semantics). The array is rebuilt from scratch on each call — for
    /// high-churn use cases, drive mutation through `ResidentArrayStore`
    /// which maintains the live array incrementally, then call
    /// `build(from:)` with the updated array.
    ///
    /// - Throws: `VectorKitError.invalidPayload` for non-binary or
    ///   wrong-size payloads.
    public func add(key: VectorRecordKey, vector: VectorPayload) async throws {
        guard vector.kind == .binary else {
            throw VectorKitError.invalidPayload(
                "BruteForceIndex.add: vector.kind must be .binary, got \(vector.kind)")
        }
        guard vector.bytes.count == 32 else {
            throw VectorKitError.invalidPayload(
                "BruteForceIndex.add: binary vector must be 32 bytes, got \(vector.bytes.count)")
        }

        // Tombstone any existing slot with the same key (upsert).
        var newTombstones = array.tombstones
        for slotIdx in 0..<Int(array.count) where array.keys[slotIdx] == key {
            Self.setTombstoneBit(&newTombstones, slot: slotIdx)
        }

        // Append the new slot at the end of the storage block.
        var newStorage = array.storage
        newStorage.append(contentsOf: vector.bytes)
        var newKeys = array.keys
        newKeys.append(key)
        let newCount = UInt32(newKeys.count)

        // Extend the tombstone bitset to cover the new (live) slot.
        let wordsNeeded = (Int(newCount) + 63) / 64
        while newTombstones.count < wordsNeeded { newTombstones.append(0) }

        // Rebuild sorted model partitions from the new key array.
        let newPartitions = Self.buildPartitions(keys: newKeys,
                                                 tombstones: newTombstones)

        array = ResidentVectorArray(
            kind: .binary,
            stride: 32,
            count: newCount,
            storage: newStorage,
            keys: newKeys,
            modelPartitions: newPartitions,
            tombstones: newTombstones
        )
    }

    // MARK: - DenseIndex — remove

    /// Tombstone the record identified by `key`.
    ///
    /// No-op if `key` is absent. The tombstoned slot is excluded from
    /// all future searches. Storage is not reclaimed until compaction
    /// (handled by ResidentArrayStore).
    public func remove(key: VectorRecordKey) async throws {
        var newTombstones = array.tombstones
        var changed = false
        for slotIdx in 0..<Int(array.count) where array.keys[slotIdx] == key {
            Self.setTombstoneBit(&newTombstones, slot: slotIdx)
            changed = true
        }
        guard changed else { return }
        let newPartitions = Self.buildPartitions(keys: array.keys,
                                                 tombstones: newTombstones)
        array = ResidentVectorArray(
            kind: .binary,
            stride: array.stride,
            count: array.count,
            storage: array.storage,
            keys: array.keys,
            modelPartitions: newPartitions,
            tombstones: newTombstones
        )
    }

    // MARK: - Snapshot accessor

    /// Return a value-copy of the current resident array.
    ///
    /// Used by VectorStore when it needs to iterate the resident array
    /// to locate keys for tombstoning (deleteVector, deleteAllVectors).
    /// The returned ResidentVectorArray is a value type — safe to read
    /// across actor boundaries after the call resolves.
    public func currentSnapshot() -> ResidentVectorArray {
        array
    }

    // MARK: - Private helpers

    /// Return the slot range to scan for the given filter.
    ///
    /// If the filter specifies a modelID and the partition index has an
    /// entry for it, return that entry's range. Otherwise return the
    /// full [0, count) range. An absent-model filter returns empty.
    private func slotRange(for filter: MetadataFilter?) -> Range<Int> {
        if let mid = filter?.modelID {
            return array.partitionRange(for: mid) ?? 0..<0
        }
        return 0..<Int(array.count)
    }

    /// Set bit `slot` in the tombstone bitset (UInt64 packed, bit i%64
    /// of word i/64, 0 = LSB; matches arch spec §4.2 tombstone layout
    /// and the isTombstoned accessor in ResidentVectorArray).
    static func setTombstoneBit(_ words: inout [UInt64], slot: Int) {
        let w = slot / 64
        let b = slot % 64
        while words.count <= w { words.append(0) }
        words[w] |= (UInt64(1) << b)
    }

    /// Rebuild a sorted model-partition index from the key array.
    ///
    /// For each modelID, the partition entry covers the span
    /// [first live slot index, last live slot index + 1). Tombstoned
    /// slots are excluded from the partition computation so that
    /// `slotRange(for:)` returns a tight range.
    ///
    /// The result is sorted by modelID ascending, consistent with the
    /// ResidentVectorArray binary-search invariant.
    static func buildPartitions(
        keys: [VectorRecordKey],
        tombstones: [UInt64]
    ) -> [ModelPartitionEntry] {
        // Collect the min and max slot index for each live model.
        var minIdx: [String: Int] = [:]
        var maxIdx: [String: Int] = [:]
        for (idx, key) in keys.enumerated() {
            let w = idx / 64
            let b = idx % 64
            let isTombstoned: Bool = w < tombstones.count
                && (tombstones[w] >> b) & 1 == 1
            if !isTombstoned {
                let mid = key.modelID
                if minIdx[mid] == nil || idx < minIdx[mid]! { minIdx[mid] = idx }
                if maxIdx[mid] == nil || idx > maxIdx[mid]! { maxIdx[mid] = idx }
            }
        }
        return minIdx.keys.sorted().compactMap { modelID in
            guard let lo = minIdx[modelID], let hi = maxIdx[modelID] else { return nil }
            return ModelPartitionEntry(modelID: modelID, range: lo..<(hi + 1))
        }
    }
}
