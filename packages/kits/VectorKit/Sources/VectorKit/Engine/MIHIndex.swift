// MIHIndex.swift
//
// Lane B — Binary Multi-Index Hashing: sub-linear EXACT Hamming k-NN.
//
// The whole point of MIH is that it is EXACT. The pigeonhole proposition
// (retrieval algorithms reference §1.1) guarantees: if two codes differ
// in at most r bits total, at least one of the m bands matches within
// ⌊r/m⌋ bits. Probing each band's hash table for all substrings within
// the per-band radius and unioning the candidates yields every true
// r-neighbour — no false negatives. False positives are removed by an
// exact full-distance check via EngramLib (I-7). The result is
// bit-for-bit identical to BruteForceIndex.search on the same inputs.
//
// Conformance gate (§3.3 of the arch spec, "BLOCKER"):
//   MIHIndexTests.swift asserts MIHIndex.search == BruteForceIndex.search
//   on all §1.10 canonical vectors AND on randomised fuzz inputs across
//   seeds, n, k, and m ∈ {4,8,16,32}. BruteForceIndex is the oracle.
//   Both indexes support vectors that share an itemID but differ in
//   vectorIndex or modelID (the VectorStore UNIQUE constraint is
//   (item_id, vector_index, model_id)) — each is retained independently.
//
// Key invariants (retrieval algorithms reference §1.8):
//   1. Band order 0,1,...,m−1. Fixed.
//   2. Flip-combination enumeration: colex order by ascending subset size
//      (§1.3). Only matters for trace reproducibility.
//   3. PostingList ids kept SORTED ASCENDING (§1.2 invariant). Candidate
//      streams are deterministic without relying on hash-map iteration order.
//   4. k-NN retention: retained = k codes minimising (dist, itemID)
//      lexicographically. Bounded max-heap evicts by (dist DESC, itemID DESC).
//   5. Result order: (dist ASC, itemID ASC).
//   6. Integer-only: distances are Int via EngramLib. No floats.
//   7. m is pinned config, never auto-derived (§1.6).
//
// Conformance restriction (§1.7 note): m ∈ {4,8,16,32} only. sub_bits ∈
// {64,32,16,8} guarantees each band lies within one u64 word — no
// word-straddle. The else-branch in §1.7 is unreachable for these m values.
//
// I-7 (arch spec §3.1, §3.4): ALL Hamming distances go through EngramLib
// (which routes to SubstrateKernel). MIH does candidate generation; the
// kernel does every distance. Zero XOR/popcount in this file.
//
// Enumeration-budget guard (DECISION_MIH_ENUM_BUDGET_2026-06-12):
//   MIH progressive-radius expansion is sub-linear only on clustered data.
//   On sparse/random data the k-th best Hamming distance can be ~120 bits,
//   causing the per-band colex enumeration to reach C(64,~30) ≈ 10^17 masks
//   — a hang. The guard tracks a running maskCount and, before each new
//   radius band, checks whether the projected total would exceed the budget
//   B = max(n, 2^20). When the budget would be exceeded and the heap is not
//   yet exact, the query falls back to a full O(n) brute-scan over `codes`
//   (already in memory). The brute scan reuses BoundedMaxHeap and EngramLib
//   distances — output is provably identical to BruteForceIndex. The fallback
//   degrades latency, never correctness. A .notice log line and an Intellectus
//   metric fire on fallback so operators see when m is poorly chosen.
//
// Thread-safety: MIHIndex is an actor. All mutation and reads are
// serialised through the actor boundary.

import Foundation
import EngramLib
import IntellectusLib
import OSLog

private let log = Logger(subsystem: "com.mootx01.kit", category: "VectorKit")

// MARK: - Allowed m values

/// Conformance-restricted band counts for MIH (§1.7 note).
///
/// Restricting to {4,8,16,32} keeps sub_bits ∈ {64,32,16,8}, ensuring
/// each band fits within one u64 word. m=2 (sub_bits=128, word-straddle)
/// is excluded from the conformance suite and requires a separate harness.
public enum MIHBandCount: UInt32, Sendable, CaseIterable {
    case m4  = 4
    case m8  = 8
    case m16 = 16
    case m32 = 32

    /// Bits per band: 256 / m.
    public var subBits: UInt32 { 256 / self.rawValue }
}

// MARK: - Internal structures (not public — DenseIndex seam is the surface)

/// One band's hash table. Maps substring bit-value → sorted list of full
/// VectorRecordKeys.
///
/// Keyed by VectorRecordKey (not just itemID) so that two distinct vectors
/// that share the same itemID but differ in vectorIndex or modelID are both
/// retained as separate posting-list entries (secfix/punt-vector: MIH itemID
/// collision fix). The VectorStore schema uniqueness constraint is
/// (item_id, vector_index, model_id); the posting list respects that same
/// triple by carrying the full key.
///
/// The ids in each posting list are kept sorted ascending (§1.2 invariant):
/// candidate enumeration is then deterministic regardless of Swift Dictionary
/// iteration order.
private struct SubstringTable: Sendable {
    /// key: substring bit-value as UInt64, value: VectorRecordKeys sorted ascending.
    var map: [UInt64: [VectorRecordKey]] = [:]

    /// Insert `id` into the posting list for `key`, maintaining sort order.
    mutating func insert(key: UInt64, id: VectorRecordKey) {
        if map[key] == nil { map[key] = [] }
        let idx = lowerBound(in: map[key]!, for: id)
        map[key]!.insert(id, at: idx)
    }

    /// Remove `id` from the posting list for `key`.
    /// Drops the entry entirely if the posting list becomes empty
    /// (consistent across Swift and Rust: §1.5 note).
    mutating func remove(key: UInt64, id: VectorRecordKey) {
        guard var list = map[key] else { return }
        if let i = list.firstIndex(of: id) { list.remove(at: i) }
        if list.isEmpty { map.removeValue(forKey: key) }
        else { map[key] = list }
    }
}

/// Binary search lower-bound: index at which `target` should be inserted
/// to keep `arr` sorted ascending (VectorRecordKey.Comparable order).
private func lowerBound(in arr: [VectorRecordKey], for target: VectorRecordKey) -> Int {
    var lo = 0, hi = arr.count
    while lo < hi {
        let mid = lo + (hi - lo) / 2
        if arr[mid] < target { lo = mid + 1 } else { hi = mid }
    }
    return lo
}

// MARK: - Bounded max-heap

/// Retains the best k (dist, key) pairs by (dist ASC, key ASC).
///
/// Internally a binary max-heap ordered by (dist DESC, key DESC), so
/// the root is always the WORST retained element — the one evicted when a
/// strictly better candidate arrives.
///
/// §1.8 rule 4: among codes tied at the boundary distance, those with
/// smaller keys are kept. "key" here is the full VectorRecordKey, which
/// orders by (itemID, vectorIndex, modelID, modelVersion) per §0.3.
/// This means two vectors sharing the same itemID but differing in
/// vectorIndex or modelID are each retained independently — no collapse.
///
/// Eviction key: (dist DESC, key DESC) — evict largest dist, then among
/// ties evict the largest VectorRecordKey.
private struct BoundedMaxHeap {
    let capacity: Int
    private(set) var elements: [(dist: Int, key: VectorRecordKey)] = []

    init(capacity: Int) {
        self.capacity = capacity
        elements.reserveCapacity(capacity + 1)
    }

    var size: Int { elements.count }

    /// Distance of the worst element (root). Only valid when size > 0.
    var worstDist: Int { elements[0].dist }

    /// Offer `(dist, key)` to the heap.
    ///
    /// If not full: always insert.
    /// If full: insert only if `(dist, key)` is strictly better than
    /// the current worst. "Better" = lexicographically smaller by
    /// (dist, key) — smaller dist, or equal dist and smaller VectorRecordKey.
    mutating func offer(dist: Int, key: VectorRecordKey) {
        if elements.count < capacity {
            elements.append((dist, key))
            siftUp(from: elements.count - 1)
        } else {
            // Only replace if strictly better than the worst.
            let w = elements[0]
            let betterThanWorst: Bool
            if dist < w.dist {
                betterThanWorst = true
            } else if dist == w.dist && key < w.key {
                betterThanWorst = true
            } else {
                betterThanWorst = false
            }
            if !betterThanWorst { return }
            elements[0] = (dist, key)
            siftDown(from: 0)
        }
    }

    /// Return results sorted (dist ASC, key ASC) — the oracle final order.
    func sortedAscending() -> [(dist: Int, key: VectorRecordKey)] {
        elements.sorted {
            if $0.dist != $1.dist { return $0.dist < $1.dist }
            return $0.key < $1.key
        }
    }

    // MARK: - Max-heap maintenance (ordered by (dist DESC, key DESC))

    /// Returns true if element at index i is "worse" (higher priority in
    /// the max-heap = larger (dist, key)) than the element at j.
    private func isWorse(_ i: Int, _ j: Int) -> Bool {
        let a = elements[i], b = elements[j]
        if a.dist != b.dist { return a.dist > b.dist }
        return a.key > b.key
    }

    private mutating func siftUp(from start: Int) {
        var i = start
        while i > 0 {
            let parent = (i - 1) / 2
            if isWorse(i, parent) { elements.swapAt(i, parent); i = parent }
            else { break }
        }
    }

    private mutating func siftDown(from start: Int) {
        var i = start
        let n = elements.count
        while true {
            let l = 2 * i + 1, r = 2 * i + 2
            var top = i
            if l < n && isWorse(l, top) { top = l }
            if r < n && isWorse(r, top) { top = r }
            if top == i { break }
            elements.swapAt(i, top)
            i = top
        }
    }
}

// MARK: - MIHIndex

/// Binary Multi-Index Hashing index. Sub-linear EXACT Hamming k-NN.
///
/// Implements the `DenseIndex` seam for the binary lane. Band hash
/// tables provide sub-linear candidate generation; EngramLib provides
/// exact full-distance computation on the candidate set (I-7).
///
/// The result of every `search` call is bit-for-bit identical to
/// BruteForceIndex.search on the same inputs. This is not aspirational —
/// it is the mandatory conformance gate (arch spec §3.3 BLOCKER).
///
/// Configuration:
///   - `bandCount`: number of bands m ∈ {4,8,16,32}.
///   - `maskBudget`: maximum cumulative flip-mask evaluations per query.
///     Default `nil` means `max(n, 2^20)` computed at query time. When
///     the projected enumeration would exceed the budget and the heap is
///     not yet exact, the query falls back to a full O(n) brute scan.
///     Override with a fixed Int for testing (e.g. pass 1 to force
///     immediate fallback on any non-trivial query).
///
/// Thread-safety: actor. All state is actor-isolated.
public actor MIHIndex: DenseIndex {

    // MARK: - Configuration (nonisolated — safe to read without hopping)

    /// Number of bands m. Pinned at construction.
    public nonisolated let m: UInt32

    /// Bits per band: 256 / m.
    public nonisolated let subBits: UInt32

    /// Maximum cumulative flip-mask count per query.
    ///
    /// `nil` means compute dynamically as max(n, 1<<20) each query.
    /// A fixed value overrides the dynamic formula — useful in tests
    /// that need deterministic fallback thresholds regardless of n.
    /// Both Swift and Rust use the same formula so both fall back at
    /// the same radius (bit-identical projection arithmetic per
    /// DECISION_MIH_ENUM_BUDGET_2026-06-12).
    public nonisolated let fixedMaskBudget: Int?

    // MARK: - DenseIndex protocol requirement

    public nonisolated let kind: IndexKind = .mih

    // MARK: - Actor-isolated state

    /// m substring hash tables, one per band. Index t = band t.
    private var tables: [SubstringTable]

    /// Full 256-bit codes keyed by VectorRecordKey, for exact full-distance
    /// re-check.
    ///
    /// MIH uses this for the candidate verification step (I-7: every distance
    /// through EngramLib). The key is the full VectorRecordKey — NOT just
    /// itemID. Using the full key means two distinct vectors that share the
    /// same itemID but differ in vectorIndex or modelID each get their own
    /// entry. This is required because the VectorStore schema's UNIQUE
    /// constraint is (item_id, vector_index, model_id), and a search must
    /// return all live vectors, not just the first one per itemID.
    /// (secfix/punt-vector: MIH itemID collision fix)
    private var codes: [VectorRecordKey: Engram] = [:]

    // MARK: - Init

    /// Create an empty MIH index with the given band count.
    ///
    /// `bandCount` must be in {4,8,16,32} to satisfy the §1.7
    /// conformance restriction. The enum enforces this statically.
    ///
    /// `maskBudget`: override the automatic `max(n, 2^20)` budget with
    /// a fixed value. Pass `nil` for the default adaptive policy.
    /// The default is `nil`; the `VectorStore` callers leave it nil.
    public init(bandCount: MIHBandCount, maskBudget: Int? = nil) {
        self.m               = bandCount.rawValue
        self.subBits         = bandCount.subBits
        self.fixedMaskBudget = maskBudget
        self.tables          = Array(repeating: SubstringTable(), count: Int(bandCount.rawValue))
    }

    // MARK: - DenseIndex — build

    /// Rebuild the MIH index from a ResidentVectorArray.
    ///
    /// Clears all existing state, then inserts every live
    /// (non-tombstoned) record. O(n·m) substring insertions.
    /// Each record is keyed by its full VectorRecordKey so that distinct
    /// vectors sharing the same itemID (different vectorIndex or modelID)
    /// are all retained independently.
    public func build(from array: ResidentVectorArray) async {
        codes  = [:]
        tables = Array(repeating: SubstringTable(), count: Int(m))

        for slot in 0..<Int(array.count) {
            guard !array.isTombstoned(slot) else { continue }
            guard let bytes = array.vectorBytes(at: slot) else { continue }
            let k = array.keys[slot]
            do {
                let engram = try VectorPayload(kind: .binary, dim: 256, bytes: bytes).asEngram()
                insertIntoTables(id: k, engram: engram)
                codes[k] = engram
            } catch {
                log.error("MIHIndex.build: skipping corrupted slot \(slot): \(error)")
            }
        }
    }

    // MARK: - DenseIndex — search

    /// k-nearest binary vectors by Hamming distance (exact, sub-linear).
    ///
    /// Returns up to k DenseHit values sorted `(rawDistance ASC,
    /// key.itemID ASC)`. Result is EXACT — identical to BruteForceIndex.
    ///
    /// - Parameters:
    ///   - probe: must be `.binary` kind, exactly 32 bytes.
    ///   - metric: must be `.binary(.hamming)`.
    ///   - k: maximum result count.
    ///   - filter: optional modelID/modelVersion pre-filter.
    ///
    /// - Throws: `VectorKitError.invalidPayload` for invalid inputs.
    public func search(
        probe:  VectorPayload,
        metric: DenseMetric,
        k:      Int,
        filter: MetadataFilter?
    ) async throws -> [DenseHit] {
        guard probe.kind == .binary else {
            throw VectorKitError.invalidPayload(
                "MIHIndex.search: probe.kind must be .binary, got \(probe.kind)")
        }
        guard probe.bytes.count == 32 else {
            throw VectorKitError.invalidPayload(
                "MIHIndex.search: binary probe must be exactly 32 bytes, got \(probe.bytes.count)")
        }
        guard case .binary(.hamming) = metric else {
            throw VectorKitError.invalidPayload(
                "MIHIndex.search: only .binary(.hamming) is supported; got \(metric)")
        }
        guard k > 0 else { return [] }
        guard !codes.isEmpty else { return [] }

        let probeEngram: Engram
        do {
            probeEngram = try probe.asEngram()
        } catch {
            throw VectorKitError.invalidPayload(
                "MIHIndex.search: could not decode probe as Engram — \(error)")
        }

        return knn(probe: probeEngram, k: k, filter: filter)
    }

    // MARK: - DenseIndex — add

    /// Add one binary vector record to the MIH index.
    ///
    /// Upsert semantics: if a record with the same full VectorRecordKey already
    /// exists, it is replaced. Posting lists maintain sorted-ascending order
    /// after the operation (§1.2 invariant preserved).
    ///
    /// Two records that share the same itemID but differ in vectorIndex or
    /// modelID are treated as DISTINCT entries (the VectorStore UNIQUE
    /// constraint is (item_id, vector_index, model_id)).
    ///
    /// - Throws: `VectorKitError.invalidPayload` for non-binary or
    ///   wrong-size payloads.
    public func add(key: VectorRecordKey, vector: VectorPayload) async throws {
        guard vector.kind == .binary else {
            throw VectorKitError.invalidPayload(
                "MIHIndex.add: vector.kind must be .binary, got \(vector.kind)")
        }
        guard vector.bytes.count == 32 else {
            throw VectorKitError.invalidPayload(
                "MIHIndex.add: binary vector must be 32 bytes, got \(vector.bytes.count)")
        }
        let engram = try vector.asEngram()
        // Upsert: remove existing entry for this exact key (if any).
        // The lookup is by FULL VectorRecordKey so only this specific
        // (itemID, vectorIndex, modelID, modelVersion) tuple is replaced —
        // sibling vectors sharing the same itemID are unaffected.
        if let existing = codes[key] {
            removeFromTables(id: key, engram: existing)
        }
        insertIntoTables(id: key, engram: engram)
        codes[key] = engram
    }

    // MARK: - DenseIndex — remove

    /// Remove the record identified by `key` from the index.
    ///
    /// No-op if `key` is absent. After removal the record is excluded from
    /// all future searches. Only the exact (itemID, vectorIndex, modelID,
    /// modelVersion) match is removed; sibling vectors sharing the same
    /// itemID but differing in vectorIndex or modelID are unaffected.
    public func remove(key: VectorRecordKey) async throws {
        guard let engram = codes[key] else { return }
        removeFromTables(id: key, engram: engram)
        codes.removeValue(forKey: key)
    }

    // MARK: - Progressive-radius k-NN (§1.4) with enumeration-budget guard

    /// The MIH exact k-NN algorithm with progressive radius expansion.
    ///
    /// Correctness invariant: after the loop processes total radius r,
    /// every code at full Hamming distance ≤ r has been examined
    /// (pigeonhole, §1.1). The stopping rule (heap full AND worstDist ≤ r)
    /// then guarantees no un-examined code can displace a retained
    /// neighbour. The output equals a brute-force sort-and-truncate.
    ///
    /// Enumeration-budget guard: before each new radius, the projected
    /// cumulative flip-mask count is checked against `budget` (computed
    /// as max(n, 2^20) unless overridden). When the projection exceeds
    /// the budget and the heap is not yet exact, the function falls back
    /// to `bruteScan` — an O(n) scan over `codes` that is identical in
    /// result to the enumeration that would have completed. Budget
    /// arithmetic is integer-only and bit-identical to the Rust port so
    /// both fall back at the same radius.
    private func knn(
        probe:  Engram,
        k:      Int,
        filter: MetadataFilter?
    ) -> [DenseHit] {
        let n = codes.count
        // Budget: max(n, 2^20) unless caller supplied a fixed override.
        // 2^20 ≈ 1M floor keeps clustered-but-deep legitimate queries working.
        // The `n` term means we never enumerate past the cost of a full scan.
        let budget = fixedMaskBudget ?? max(n, 1 << 20)

        // seen: full VectorRecordKeys that have been full-distance-checked.
        // Prevents processing the same record more than once across bands/radii.
        // Using the full key (not just itemID) means two records that share an
        // itemID but differ in vectorIndex or modelID are each tracked and
        // distance-checked independently.
        var seen = Set<VectorRecordKey>()
        seen.reserveCapacity(min(n, 256))

        var heap = BoundedMaxHeap(capacity: k)

        // Precompute the query band keys for all m bands. These are
        // constant for the whole progressive-radius loop.
        let probeBands: [UInt64] = (0..<Int(m)).map { t in
            extractBand(from: probe, bandIndex: UInt32(t))
        }

        // Running count of flip-mask evaluations across all radii and bands.
        // Compared against `budget` before each new radius to bound work.
        var maskCount = 0

        var r = 0
        while true {
            // Per-band radius for this total radius r (§1.1):
            //   ⌊r/m⌋ for (m − r%m) bands,
            //   ⌊r/m⌋+1 for the first (r%m) bands.
            let rho   = r / Int(m)   // integer division = ⌊r/m⌋
            let extra = r % Int(m)   // first `extra` bands use rho+1

            // The maximum per-band rho at this radius (the first `extra`
            // bands use rho+1; remaining use rho).
            let maxBandRho = rho + (extra > 0 ? 1 : 0)

            // Projection: cumulative flip-masks the whole query would consume
            // at the next radius step. This is m × Σ_{d=0..maxBandRho} C(subBits,d).
            // Using the conservative upper bound (all m bands at maxBandRho)
            // avoids a per-band sum while remaining integer-only.
            // This matches the Rust port's arithmetic exactly so both
            // fall back at the same radius.
            let projected = Int(m) * cumulativeChoose(subBits: Int(subBits), rho: maxBandRho)

            // If the projected total would exceed the budget AND the heap is
            // not yet exact, abandon enumeration and fall back to a full O(n)
            // brute scan over `codes`. The scan is identical in result.
            if maskCount + projected > budget {
                let isExact = heap.size == k && heap.worstDist <= r
                if !isExact {
                    log.notice("MIHIndex fell back to brute scan: m=\(self.m) n=\(n) rho=\(maxBandRho) budget=\(budget)")
                    Intellectus.report(.metric(
                        name: "vectorkit.mih.enumeration_fallback",
                        value: 1.0,
                        tags: [
                            "kit":    "VectorKit",
                            "m":      "\(self.m)",
                            "n":      "\(n)",
                            "rho":    "\(maxBandRho)",
                            "budget": "\(budget)"
                        ],
                        ts: Date().timeIntervalSince1970
                    ))
                    return bruteScan(probe: probe, k: k, filter: filter)
                }
            }

            // Iterate bands in fixed order 0,1,...,m-1 (§1.8 rule 1).
            for t in 0..<Int(m) {
                let bandRho  = rho + (t < extra ? 1 : 0)
                let querySub = probeBands[t]

                // Enumerate all flip-combinations of the query substring
                // within band Hamming radius bandRho, look up each key
                // in the band table, and full-distance-check new candidates.
                // maskCount is incremented once per flip-mask call via the
                // closure wrapper below.
                enumerateBandCandidatesCounted(
                    table:     tables[t],
                    querySub:  querySub,
                    rho:       bandRho,
                    probe:     probe,
                    filter:    filter,
                    seen:      &seen,
                    heap:      &heap,
                    maskCount: &maskCount
                )
            }

            // STOPPING RULE (§1.4): heap is full AND worst retained distance
            // ≤ r. Every un-examined code has distance > r ≥ worstDist —
            // it cannot improve the heap. Exact.
            if heap.size == k && heap.worstDist <= r { break }
            // Short-circuit: once every indexed code has been seen, no further
            // candidates exist regardless of how much Hamming space remains.
            // Prevents O(2^subBits) enumeration when n < k.
            if seen.count >= codes.count { break }
            if r == 256 { break } // fewer than k codes exist; exhausted
            r += 1
        }

        // Build DenseHit array from the sorted heap output
        // ((dist ASC, key ASC) where key is the full VectorRecordKey).
        // The key is stored directly in the heap element — no secondary lookup.
        return heap.sortedAscending().map { (dist, key) in
            DenseHit(key: key, hammingDistance: dist)
        }
    }

    // MARK: - Brute-scan fallback (O(n) over codes)

    /// Full O(n) scan over the resident `codes` dictionary.
    ///
    /// Called when the enumeration-budget guard fires. Iterates every
    /// stored code, applies the optional filter, distances via EngramLib
    /// (I-7), offers to the same BoundedMaxHeap. Output is provably
    /// identical to BruteForceIndex.search because it uses the same
    /// codes, the same distances, and the same heap.
    private func bruteScan(
        probe:  Engram,
        k:      Int,
        filter: MetadataFilter?
    ) -> [DenseHit] {
        var heap = BoundedMaxHeap(capacity: k)
        for (recordKey, codeEngram) in codes {
            if let f = filter, !f.accepts(recordKey) { continue }
            let dist = EngramLib.distance(probe, codeEngram)
            heap.offer(dist: dist, key: recordKey)
        }
        // Sort ascending (dist ASC, key ASC) — oracle order (§0.3 extended
        // to full VectorRecordKey for same-itemID disambiguation).
        return heap.sortedAscending().map { (dist, key) in
            DenseHit(key: key, hammingDistance: dist)
        }
    }

    // MARK: - Band candidate enumeration (§1.3)

    /// Enumerate candidate ids from `table` within band radius `rho` of
    /// `querySub` (colex order), full-distance-check each new one, offer
    /// to `heap`. Increments `maskCount` once per flip-mask evaluated.
    ///
    /// Enumeration order (§1.3 canonical): increasing subset size d =
    /// 0,1,...,rho; within fixed d, colex order of bit-position subsets
    /// (ascending order of the flip-mask integer). Position indices are
    /// 0..(subBits-1) with 0 = LSB.
    private func enumerateBandCandidatesCounted(
        table:     SubstringTable,
        querySub:  UInt64,
        rho:       Int,
        probe:     Engram,
        filter:    MetadataFilter?,
        seen:      inout Set<VectorRecordKey>,
        heap:      inout BoundedMaxHeap,
        maskCount: inout Int
    ) {
        colexFlipMasks(subBits: Int(subBits), maxHamming: rho) { flipMask in
            maskCount += 1
            let lookupKey = querySub ^ flipMask
            guard let posting = table.map[lookupKey] else { return }
            // posting is sorted ascending (§1.2 invariant) — deterministic order.
            for recordKey in posting {
                // Deduplicate by FULL VectorRecordKey so two records sharing the
                // same itemID (but differing in vectorIndex or modelID) are each
                // checked independently — neither is suppressed as "already seen."
                guard seen.insert(recordKey).inserted else { continue }
                // Per-record metadata filter.
                if let f = filter, !f.accepts(recordKey) { continue }
                // I-7: ALL Hamming distances through EngramLib (SubstrateKernel).
                guard let codeEngram = codes[recordKey] else { continue }
                let dist = EngramLib.distance(probe, codeEngram)
                heap.offer(dist: dist, key: recordKey)
            }
        }
    }

    // MARK: - Band extraction (§1.7)

    /// Extract band `bandIndex` from a 256-bit Engram as a UInt64.
    ///
    /// Canonical bit numbering (§0.1): bit i lives in word w[i/64] at
    /// position i%64 (0 = LSB). The four words w[0..3] map to:
    ///   w[0] = block0 (bits 0-63)
    ///   w[1] = block1 (bits 64-127)
    ///   w[2] = block2 (bits 128-191)
    ///   w[3] = block3 (bits 192-255)
    ///
    /// For m ∈ {4,8,16,32}: sub_bits ∈ {64,32,16,8}. Every band lies
    /// wholly within one word (lo_off + sub_bits ≤ 64 always). The
    /// word-straddle else-branch from §1.7 is dead code for these m values.
    ///
    /// Reference formula (§1.7):
    ///   start   = bandIndex * sub_bits
    ///   lo_word = start / 64
    ///   lo_off  = start % 64
    ///   mask    = (sub_bits==64) ? UInt64.max : (1<<sub_bits)-1
    ///   return (w[lo_word] >> lo_off) & mask
    private func extractBand(from engram: Engram, bandIndex: UInt32) -> UInt64 {
        let start  = bandIndex &* subBits
        let loWord = Int(start / 64)
        let loOff  = start % 64

        // Select the word containing this band.
        let word: UInt64
        switch loWord {
        case 0: word = engram.block0
        case 1: word = engram.block1
        case 2: word = engram.block2
        case 3: word = engram.block3
        default: word = 0  // unreachable for m ∈ {4,8,16,32}
        }

        // subBits == 64 only when m == 4 (one word per band); mask is all-ones.
        // Otherwise mask covers the low subBits bits.
        let mask: UInt64 = subBits == 64 ? UInt64.max : (UInt64(1) << subBits) &- 1
        return (word >> loOff) & mask
    }

    // MARK: - Table helpers

    private func insertIntoTables(id: VectorRecordKey, engram: Engram) {
        for t in 0..<Int(m) {
            let sub = extractBand(from: engram, bandIndex: UInt32(t))
            tables[t].insert(key: sub, id: id)
        }
    }

    private func removeFromTables(id: VectorRecordKey, engram: Engram) {
        for t in 0..<Int(m) {
            let sub = extractBand(from: engram, bandIndex: UInt32(t))
            tables[t].remove(key: sub, id: id)
        }
    }
}

// MARK: - Binomial prefix sum (integer-only, parity-gated with Rust)

/// Cumulative binomial coefficient Σ_{d=0..rho} C(n, d).
///
/// Used by the enumeration-budget guard to project the total flip-mask
/// count before committing to a new radius band. This is the dominant
/// term in E_band(rho) = Σ_{d=0..rho} C(sub_bits, d) from the decision memo.
///
/// Implementation: iterative multiplication avoids factorial overflow on
/// typical values (sub_bits ∈ {8,16,32,64}, rho bounded by sub_bits).
/// For sub_bits=64 and rho=32 the individual C(64,d) terms fit in Int64
/// up to about d=20 before the intermediate product would overflow Int.
/// We cap the running sum at Int.max to avoid overflow — a saturating
/// return still correctly triggers the budget guard. This matches the
/// Rust port's saturating_add logic exactly so both fall back at the
/// same radius (DECISION_MIH_ENUM_BUDGET_2026-06-12 §conformance).
///
/// The function is integer-only (no floats) so results are bit-identical
/// across Swift (macOS/iOS arm64) and Rust (x86_64/aarch64).
internal func cumulativeChoose(subBits: Int, rho: Int) -> Int {
    guard subBits > 0 && rho >= 0 else { return 0 }

    // C(n,0) = 1 for any n ≥ 0.
    var sum = 1
    var c   = 1   // current C(subBits, d)
    var d   = 0

    while d < rho {
        d += 1
        if d > subBits { break } // C(n, d) = 0 for d > n
        // C(subBits, d) = C(subBits, d-1) * (subBits - d + 1) / d
        // Use overflow-safe arithmetic: if the intermediate value would
        // overflow Int, saturate to Int.max and stop — budget is exceeded.
        let (mul, didOverflow) = c.multipliedReportingOverflow(by: subBits - d + 1)
        if didOverflow {
            return Int.max
        }
        c = mul / d
        // Saturating add: Int.max means "budget definitely exceeded".
        let (newSum, sumOverflowed) = sum.addingReportingOverflow(c)
        if sumOverflowed {
            return Int.max
        }
        sum = newSum
    }
    return sum
}

// MARK: - Colex flip-mask enumeration (§1.3)

/// Call `body(flipMask)` for each flip-mask of Hamming weight 0..maxHamming
/// over `subBits` bit positions, in colex order.
///
/// Colex order (§1.3): increasing subset size d = 0,1,...,maxHamming.
/// Within fixed d, combinations of bit positions in ascending integer order
/// of the flip mask (equivalently: ascending value of OR of chosen
/// (1 << position) bits). Position 0 = LSB.
///
/// For d=0: one call with flipMask=0.
/// For d > subBits: no calls (no combinations exist).
///
/// This function is the canonical enumeration per §1.3 of the retrieval
/// algorithms reference. The final k-NN output order is sort-invariant,
/// but pinning enumeration order ensures reproducible intermediate state
/// for trace logging and conformance vector generation.
///
/// Implementation uses Gosper's hack to advance through all d-bit
/// combinations in ascending integer order.
///
/// Internal (not private) so the `matchesActualEnumerationCount` parity
/// test in MIHIndexTests can verify cumulativeChoose against the real
/// enumeration count without duplicating the algorithm.
internal func colexFlipMasks(subBits: Int, maxHamming: Int, body: (UInt64) -> Void) {
    guard subBits > 0 && subBits <= 64 && maxHamming >= 0 else { return }
    let n = subBits

    for d in 0...maxHamming {
        if d == 0 {
            body(0)
            continue
        }
        if d > n { break } // no combinations of d from n when d > n

        // Start mask: lowest d bits set (ascending-first in colex order).
        var mask: UInt64
        if d == 64 {
            mask = UInt64.max
        } else {
            mask = (UInt64(1) << d) &- 1
        }

        // Upper limit: first mask with bit n set (excluded).
        // For n=64, the limit wraps to 0, so we guard on d==n specially.
        let limit: UInt64
        if n < 64 {
            limit = UInt64(1) << n
        } else {
            limit = 0  // n==64: all 64-bit masks are valid; stop after mask overflow
        }

        // Iterate over all d-bit combinations in ascending order (Gosper's hack).
        while true {
            // Bounds check: for n < 64 stop at limit; for n==64 stop on overflow.
            if n < 64 && mask >= limit { break }

            body(mask)

            // Gosper's hack: compute the next combination in ascending order.
            //   c    = lowest set bit of mask
            //   r    = mask + c        (clears the trailing run of 1s, then carries)
            //   next = (((r ^ mask) >> 2) / c) | r
            // This advances mask to the next integer with the same popcount.
            let c = mask & (0 &- mask)        // lowest set bit
            let (r, overflow) = mask.addingReportingOverflow(c)
            if overflow { break }             // mask + c overflowed: done

            let xrm = r ^ mask
            // xrm >> 2 divides by 4; c is a power of 2.
            // Safe: c >= 1 so division is exact.
            let next = (xrm >> 2) / c | r

            // For n == 64: check if we've cycled back (all combinations exhausted).
            if n == 64 && next <= mask { break }

            mask = next
        }
    }
}
