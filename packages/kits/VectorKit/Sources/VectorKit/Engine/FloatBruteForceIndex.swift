// FloatBruteForceIndex.swift
//
// Float-lane brute-force dense index.
//
// Implements the DenseIndex seam for VectorKind.float32 vectors using
// an exact linear scan over a ResidentVectorArray. This is the float
// lane's conformance oracle and its production search path (arch spec §3.1).
//
// Metrics: cosine, L2, dot — via DenseMetric.float(FloatMetric), VectorKit's
// own float-lane metric type (ADR-008 persistencekit-vector-contract-correction).
//
// Determinism boundary (arch spec §6, §0):
// ─────────────────────────────────────────────────────────────────────
// THIS LANE IS NOT FOUR-WAY BIT-IDENTICAL.
//
// Float arithmetic (cosine, L2, dot) is reproducible within one
// build/config/platform but is NOT guaranteed bit-identical across
// Swift and Rust or across different hardware. This is a DOCUMENTED
// PROPERTY of IEEE-754 float arithmetic and of the float lane, not
// a bug or an I-7 violation. Tests assert within-config reproducibility
// (same answer every run on the same platform) and recall@k correctness;
// they do NOT and MUST NOT assert four-way bit-identity.
//
// A reviewer must not "fix" the float lane to chase four-way bit-identity.
// The binary lane (Lane A BruteForceIndex) is the four-way oracle lane.
// ─────────────────────────────────────────────────────────────────────
//
// Deterministic ordering: the brute-force scan produces a stable result
// by sorting (rawDistanceValue ASC, key ASC). "rawDistanceValue" is the
// float distance in its natural sense — smaller is nearer — so cosine
// and L2 sort ascending by distance, and dot sorts ascending by negative
// dot product (i.e. descending by similarity, but consistent with the
// "nearer first" contract at the seam).
//
// Thread-safety: FloatBruteForceIndex is an actor. Mutation (build, add,
// remove) is isolated. Search is read-only over the current array.
//
// Rule FT-1: this file does NOT modify any Lane F type. If a new field
// is needed on a shared type, stop and file an FT-1 update to Lane F.

import Foundation
import OSLog

private let log = Logger(subsystem: "com.mootx01.kit", category: "FloatBruteForceIndex")

// MARK: - FloatBruteForceIndex

/// Brute-force exact linear scan for the float32 dense lane.
///
/// Implements DenseIndex for VectorKind.float32 payloads. Every search
/// performs a complete O(n) scan of the resident array. This is correct
/// and required — it is the float lane's conformance oracle.
///
/// Metrics supported: `.float(.cosine)`, `.float(.l2)`, `.float(.dot)`.
/// Passing a binary metric to a FloatBruteForceIndex is a programming
/// error and throws VectorKitError.invalidPayload.
///
/// Float determinism: reproducible within one build/config. NOT
/// four-way bit-identical across Swift and Rust. See the file header.
public actor FloatBruteForceIndex: DenseIndex {

    // MARK: - State

    /// The packed resident array backing all searches.
    ///
    /// May be nil before the first build() call. Search on a nil array
    /// returns an empty result set.
    private var array: ResidentVectorArray?

    // MARK: - DenseIndex

    /// Always .bruteForce — this is the float lane's linear-scan oracle.
    nonisolated public var kind: IndexKind { .bruteForce }

    /// (Re-)build the index from a resident array.
    ///
    /// For FloatBruteForceIndex the array IS the index: build() stores
    /// the reference and returns. The scan happens at search time.
    /// O(1) — the cost is the caller's cost of building the array.
    ///
    /// - Parameter array: must have kind == .float32. If a binary or
    ///   int8 array is passed, build() logs a warning and stores it
    ///   anyway; the error will surface on the first search call.
    public func build(from array: ResidentVectorArray) async {
        if array.kind != .float32 {
            log.warning("FloatBruteForceIndex.build called with kind=\(String(describing: array.kind)); expected .float32")
        }
        self.array = array
        log.debug("FloatBruteForceIndex built: \(array.count) vectors, stride \(array.stride)")
    }

    /// k-nearest neighbours by a float metric, optionally filtered.
    ///
    /// Performs a complete linear scan. Complexity: O(n × d) where d is
    /// the vector dimensionality (stride / 4). Results are sorted by
    /// distance ascending then key ascending (tie-break).
    ///
    /// Throws VectorKitError.invalidPayload if:
    ///   - probe.kind is not .float32
    ///   - metric is not a float metric (.binary metrics are binary-lane only)
    ///   - probe.dim does not match the index's stride (dim × 4 bytes)
    public func search(
        probe: VectorPayload,
        metric: DenseMetric,
        k: Int,
        filter: MetadataFilter?
    ) async throws -> [DenseHit] {
        guard probe.kind == .float32 else {
            throw VectorKitError.invalidPayload(
                "FloatBruteForceIndex.search: probe.kind=\(probe.kind); expected .float32")
        }
        guard case .float(let distanceMetric) = metric else {
            throw VectorKitError.invalidPayload(
                "FloatBruteForceIndex.search: metric=\(metric) is not a float metric; use the binary lane for binary metrics")
        }
        guard let arr = array else {
            return []
        }
        guard arr.kind == .float32 else {
            throw VectorKitError.invalidPayload(
                "FloatBruteForceIndex.search: resident array kind=\(arr.kind); expected .float32")
        }
        let expectedByteCount = Int(probe.dim) * 4
        guard probe.bytes.count == expectedByteCount else {
            throw VectorKitError.invalidPayload(
                "FloatBruteForceIndex.search: probe has \(probe.bytes.count) bytes; expected \(expectedByteCount) for dim=\(probe.dim)")
        }
        guard Int(arr.stride) == expectedByteCount else {
            throw VectorKitError.invalidPayload(
                "FloatBruteForceIndex.search: array stride=\(arr.stride) does not match probe dim×4=\(expectedByteCount)")
        }

        // Nearest = smaller cosine distance first (the DenseIndex contract).
        let scored = try scan(probe: probe, metric: distanceMetric, arr: arr, filter: filter)
        return rank(scored, k: k, metric: metric, direction: .nearest)
    }

    /// k-FARTHEST neighbours by a float metric — the most DISSIMILAR
    /// vectors first (anti-similarity retrieval, mission 6b-modifiers-antisim).
    ///
    /// Reuses the exact same linear scan and the same cosine distance as
    /// `search`; the ONLY difference is the sort: distance DESCENDING (the
    /// largest cosine distance = the smallest cosine similarity = the most
    /// dissimilar) instead of ascending. No new distance math (mission
    /// guardrail: "farthest reuses the same cosine, just bottom-K ordering").
    ///
    /// "Bottom-K by cosine similarity" cannot be faked by negating a
    /// nearest-list: the farthest items are not in the nearest top-K at
    /// all, so the index must rank by the opposite end. That is exactly
    /// what this method does.
    ///
    /// Tie-break stays itemID ASCENDING (identical to `search`) so two
    /// items at the same distance order the same in both directions — the
    /// determinism contract holds regardless of direction.
    ///
    /// Throws the same `VectorKitError.invalidPayload` cases as `search`.
    public func searchFarthest(
        probe: VectorPayload,
        metric: DenseMetric,
        k: Int,
        filter: MetadataFilter?
    ) async throws -> [DenseHit] {
        guard probe.kind == .float32 else {
            throw VectorKitError.invalidPayload(
                "FloatBruteForceIndex.searchFarthest: probe.kind=\(probe.kind); expected .float32")
        }
        guard case .float(let distanceMetric) = metric else {
            throw VectorKitError.invalidPayload(
                "FloatBruteForceIndex.searchFarthest: metric=\(metric) is not a float metric; use the binary lane for binary metrics")
        }
        guard let arr = array else {
            return []
        }
        guard arr.kind == .float32 else {
            throw VectorKitError.invalidPayload(
                "FloatBruteForceIndex.searchFarthest: resident array kind=\(arr.kind); expected .float32")
        }
        let expectedByteCount = Int(probe.dim) * 4
        guard probe.bytes.count == expectedByteCount else {
            throw VectorKitError.invalidPayload(
                "FloatBruteForceIndex.searchFarthest: probe has \(probe.bytes.count) bytes; expected \(expectedByteCount) for dim=\(probe.dim)")
        }
        guard Int(arr.stride) == expectedByteCount else {
            throw VectorKitError.invalidPayload(
                "FloatBruteForceIndex.searchFarthest: array stride=\(arr.stride) does not match probe dim×4=\(expectedByteCount)")
        }

        let scored = try scan(probe: probe, metric: distanceMetric, arr: arr, filter: filter)
        return rank(scored, k: k, metric: metric, direction: .farthest)
    }

    // MARK: - Scan + rank (shared by nearest and farthest)

    /// Linear scan: compute the float distance for every live, filter-passing
    /// slot. Shared verbatim by `search` (nearest) and `searchFarthest` so the
    /// distance arithmetic — the cosine itself — is identical for both
    /// directions; only the subsequent ordering differs.
    private func scan(
        probe: VectorPayload,
        metric: FloatMetric,
        arr: ResidentVectorArray,
        filter: MetadataFilter?
    ) throws -> [(distance: Float, key: VectorRecordKey)] {
        let probeFloats = try probe.asFloats()
        let dim = Int(probe.dim)

        // Collect scored candidates. We allocate once and sort in place.
        // No per-row allocation inside the hot loop.
        var scored: [(distance: Float, key: VectorRecordKey)] = []
        scored.reserveCapacity(Int(arr.count))

        for i in 0..<Int(arr.count) {
            guard !arr.isTombstoned(i) else { continue }
            guard let key = arr.keys.indices.contains(i) ? Optional(arr.keys[i]) : nil else { continue }
            if let f = filter, !f.accepts(key) { continue }

            let slotBytes = arr.vector_bytesUnchecked(at: i, stride: Int(arr.stride))
            let slotFloats = floatSlice(from: slotBytes, count: dim)

            let dist = floatDistance(probe: probeFloats, candidate: slotFloats, metric: metric)
            scored.append((distance: dist, key: key))
        }
        return scored
    }

    /// Order the scored candidates and take the top `k`.
    ///
    /// `.nearest`  — distance ASCENDING (smallest cosine distance first).
    /// `.farthest` — distance DESCENDING (largest cosine distance first =
    ///               most dissimilar first, anti-similarity).
    ///
    /// In BOTH directions the tie-break is itemID ASCENDING (§0.3), so the
    /// nearest path is byte-identical to the pre-antisim implementation.
    private func rank(
        _ scored: [(distance: Float, key: VectorRecordKey)],
        k: Int,
        metric: DenseMetric,
        direction: SearchDirection
    ) -> [DenseHit] {
        var ordered = scored
        ordered.sort { lhs, rhs in
            if lhs.distance != rhs.distance {
                switch direction {
                case .nearest:  return lhs.distance < rhs.distance
                case .farthest: return lhs.distance > rhs.distance
                }
            }
            // Tie-break is identical in both directions: itemID ascending.
            return lhs.key < rhs.key
        }

        // Take top k and convert to DenseHit.
        // rawDistance stores the Float bit pattern as Int32.
        // floatDistance accessor on DenseHit reconstructs it.
        let topK = ordered.prefix(max(0, k))
        return topK.map { entry in
            let bits = entry.distance.bitPattern      // UInt32 IEEE-754
            let raw  = Int32(bitPattern: bits)        // same bit pattern, reinterpreted
            return DenseHit(key: entry.key, rawDistance: raw, metric: metric)
        }
    }

    /// Add a single float32 vector record to the index.
    ///
    /// Appends to the resident array in place; the added record is
    /// immediately searchable on the next `search` call. Tombstoned
    /// slots are preserved.
    ///
    /// Throws `VectorKitError.invalidPayload` if the vector kind is not float32
    /// or if the vector's byte count does not match the index's established stride
    /// (i.e. all vectors in one index must have the same dimension). A mismatched
    /// vector would corrupt the resident array and cause an out-of-bounds slice
    /// on the next `search` call — the guard makes that a thrown error instead.
    public func add(key: VectorRecordKey, vector: VectorPayload) async throws {
        guard vector.kind == .float32 else {
            throw VectorKitError.invalidPayload(
                "FloatBruteForceIndex.add: vector.kind=\(vector.kind); expected .float32")
        }
        if array == nil {
            // First add: establishes the index's stride. All subsequent adds
            // must carry a vector.bytes.count equal to this stride.
            array = ResidentVectorArray.empty(kind: .float32, stride: UInt32(vector.bytes.count))
        }
        guard let existing = array else { return }

        // Dimension guard: a vector whose byte count differs from the established
        // stride would corrupt the resident array (storage is a flat byte buffer
        // indexed by stride*slot). Throw rather than silently corrupt.
        guard vector.bytes.count == Int(existing.stride) else {
            throw VectorKitError.invalidPayload(
                "FloatBruteForceIndex.add: vector has \(vector.bytes.count) bytes "
                + "but index stride=\(existing.stride); all vectors in one index "
                + "must share the same dimension")
        }

        // Append to the existing array: new storage, new keys list.
        var newStorage = existing.storage
        newStorage.append(contentsOf: vector.bytes)
        var newKeys = existing.keys
        newKeys.append(key)
        let newCount = existing.count + 1

        // Rebuild model partitions from the new sorted-by-key layout.
        // For FloatBruteForceIndex the append order mirrors insert order;
        // partition is rebuilt from scratch after each add.
        let partitions = buildPartitions(keys: newKeys)

        array = ResidentVectorArray(
            kind: .float32,
            stride: existing.stride,
            count: newCount,
            storage: newStorage,
            keys: newKeys,
            modelPartitions: partitions,
            tombstones: existing.tombstones  // preserve existing tombstones; new slot is live
        )
        log.debug("FloatBruteForceIndex.add: \(newCount) vectors total")
    }

    /// Tombstone the record identified by key.
    ///
    /// The record is excluded from future searches. The underlying slot
    /// is compacted out on the next build() call.
    public func remove(key: VectorRecordKey) async throws {
        guard let arr = array else { return }

        // Find the slot index for this key.
        guard let slotIndex = arr.keys.firstIndex(of: key) else {
            // Key not present: no-op per the DenseIndex contract.
            return
        }

        // Set tombstone bit i: tombstones[i/64] |= (1 << (i%64))
        let word = slotIndex / 64
        let bit  = slotIndex % 64
        var newTombstones = arr.tombstones

        // Expand the tombstone array if the word index is out of range.
        while newTombstones.count <= word {
            newTombstones.append(0)
        }
        newTombstones[word] |= (UInt64(1) << bit)

        array = ResidentVectorArray(
            kind: arr.kind,
            stride: arr.stride,
            count: arr.count,
            storage: arr.storage,
            keys: arr.keys,
            modelPartitions: arr.modelPartitions,
            tombstones: newTombstones
        )
        log.debug("FloatBruteForceIndex.remove: tombstoned slot \(slotIndex)")
    }
}

// MARK: - Private helpers

/// Compute the float distance between two float32 vectors.
///
/// All three float metrics are computed here:
/// - cosine: 1 − dot(a,b) / (‖a‖ × ‖b‖). Range roughly −1…2 (0 = identical).
/// - l2: √Σ(aᵢ−bᵢ)². Non-negative. Lower = nearer.
/// - dot: −Σ(aᵢ×bᵢ). Negated so that "smaller = nearer" sorting works
///   consistently for pre-normalised vectors where maximising dot product
///   is the goal. Consumers who need the raw dot should negate the result.
///
/// Float determinism: reproducible within one build/config on one
/// platform. NOT four-way bit-identical across Swift and Rust. This is
/// the documented float-lane boundary per arch spec §6.
private func floatDistance(
    probe: [Float],
    candidate: [Float],
    metric: FloatMetric
) -> Float {
    precondition(probe.count == candidate.count,
                 "floatDistance: probe.count \(probe.count) != candidate.count \(candidate.count)")
    switch metric {
    case .cosine:
        return cosineDistance(probe, candidate)
    case .l2:
        return l2Distance(probe, candidate)
    case .dot:
        // Negate so that "more similar = smaller distance" for sort-ascending.
        return -dotProduct(probe, candidate)
    }
}

/// Cosine distance: 1 − cos(a, b) = 1 − dot(a,b)/(‖a‖·‖b‖).
///
/// Returns 1.0 when either vector is zero (safe fallback; undefined
/// cosine is treated as maximum distance to avoid surfacing zero vectors
/// as spurious nearest neighbours).
private func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
    var dot: Float = 0
    var normA: Float = 0
    var normB: Float = 0
    for i in 0..<a.count {
        dot  += a[i] * b[i]
        normA += a[i] * a[i]
        normB += b[i] * b[i]
    }
    let denom = normA.squareRoot() * normB.squareRoot()
    guard denom > 0 else { return 1.0 }
    // Clamp to avoid sqrt rounding producing values slightly outside [-1, 1].
    let cosineSimilarity = (dot / denom).clamped(to: -1.0...1.0)
    return 1.0 - cosineSimilarity
}

/// L2 (Euclidean) distance: √Σ(aᵢ−bᵢ)².
private func l2Distance(_ a: [Float], _ b: [Float]) -> Float {
    var sum: Float = 0
    for i in 0..<a.count {
        let diff = a[i] - b[i]
        sum += diff * diff
    }
    return sum.squareRoot()
}

/// Inner (dot) product: Σ(aᵢ × bᵢ).
///
/// The caller negates for "smaller = nearer" sorting.
private func dotProduct(_ a: [Float], _ b: [Float]) -> Float {
    var sum: Float = 0
    for i in 0..<a.count { sum += a[i] * b[i] }
    return sum
}

/// Decode a byte slice into a [Float] array, interpreting each 4-byte
/// group as an IEEE-754 little-endian float32.
///
/// The byte layout is the canonical VectorPayload.floats() wire format.
/// No copy beyond the allocation of the Float array.
private func floatSlice(from bytes: ArraySlice<UInt8>, count: Int) -> [Float] {
    var result = [Float]()
    result.reserveCapacity(count)
    var idx = bytes.startIndex
    for _ in 0..<count {
        let b0 = bytes[idx]; idx = bytes.index(after: idx)
        let b1 = bytes[idx]; idx = bytes.index(after: idx)
        let b2 = bytes[idx]; idx = bytes.index(after: idx)
        let b3 = bytes[idx]; idx = bytes.index(after: idx)
        let bits = UInt32(b0) | (UInt32(b1) << 8) | (UInt32(b2) << 16) | (UInt32(b3) << 24)
        result.append(Float(bitPattern: bits))
    }
    return result
}

/// Build the model partition index from a keys array.
///
/// Iterates the keys in order and records consecutive runs sharing the
/// same modelID. The keys array need not be sorted — partitions record
/// the actual layout, not a sorted projection. When keys are inserted
/// in modelID order the partition is compact; when interleaved, each
/// model gets one entry per run.
///
/// For FloatBruteForceIndex the partition is built but the brute-force
/// scan walks every slot via `filter.accepts(key)` rather than using
/// `partitionRange(for:)` to skip ranges.
private func buildPartitions(keys: [VectorRecordKey]) -> [ModelPartitionEntry] {
    guard !keys.isEmpty else { return [] }
    var result: [ModelPartitionEntry] = []
    var runStart = 0
    var runModel = keys[0].modelID
    for i in 1..<keys.count {
        if keys[i].modelID != runModel {
            result.append(ModelPartitionEntry(modelID: runModel, range: runStart..<i))
            runStart = i
            runModel = keys[i].modelID
        }
    }
    result.append(ModelPartitionEntry(modelID: runModel, range: runStart..<keys.count))
    return result
}

// MARK: - ResidentVectorArray unsafe slot accessor

extension ResidentVectorArray {
    /// Return the raw bytes for slot i as an ArraySlice, without bounds
    /// checking beyond what the guard in the caller provides.
    ///
    /// This avoids the Optional-returning public vectorBytes(at:) and the
    /// copy it implies when we know the index is in range and live.
    ///
    /// Only FloatBruteForceIndex calls this; it guards tombstone and range
    /// before the call.
    fileprivate func vector_bytesUnchecked(at i: Int, stride: Int) -> ArraySlice<UInt8> {
        let start = i * stride
        return storage[start..<(start + stride)]
    }
}

// MARK: - Float.clamped helper

private extension Float {
    /// Clamp to a closed range without importing any additional module.
    func clamped(to range: ClosedRange<Float>) -> Float {
        return Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }
}
