// FormalConceptAnalysis.swift
//
// Bounded Formal Concept Analysis over a materialized `FormalContext`,
// per MISSION_NEURON_BOUNDED_FCA_001. FCA finds *exact* attribute
// closures — the concepts that emerge from observed data rather than
// the authored taxonomy — distinct from Louvain (graph communities),
// NMF (soft themes), and Hamming recall (nearby fingerprints).
//
// The engine is pure data-in / data-out: it takes a fully-materialized
// `FormalContext` (rows × attributes) and reads no estate, no
// `MatrixO`, no clocks, no randomness. Building a context from the
// estate (which rows carry which `(field,value)` attributes) is the
// coupled part and is deferred to a Brain-layer seam/wrapper — NOT
// this file. The Swift conformance tests and the Rust version
// (`rust/src/formal_concept_analysis.rs`) exercise identical inputs
// and expected outputs, mirroring the `MMRRank` pure-engine +
// inline-conformance pattern.
//
// Bounding contract (the reason this is "bounded" FCA):
//   - NO full concept-lattice enumeration anywhere. Concepts are
//     seeded only from frequent single attributes; one closure per
//     seed; deduplicated by intent.
//   - NO exact Kuznetsov stability. Exact stability is exponential
//     (subset enumeration over the extent); v1 omits the computation
//     entirely. `FormalConcept.stability` is carried as an optional
//     so a future *sampled* estimator (fixed, seeded budget) is a
//     non-breaking addition; it is always `nil` in v1.

/// One typed attribute in the formal context: a `(namespace, key,
/// value)` triple. `Comparable` is lexicographic over the three
/// fields, in that order, which fixes the deterministic attribute
/// ordering every other guarantee in this file builds on.
public struct FormalAttribute: Hashable, Codable, Sendable, Comparable {
    public let namespace: String
    public let key: String
    public let value: String

    public init(namespace: String, key: String, value: String) {
        self.namespace = namespace
        self.key = key
        self.value = value
    }

    public static func < (lhs: FormalAttribute, rhs: FormalAttribute) -> Bool {
        if lhs.namespace != rhs.namespace { return lhs.namespace < rhs.namespace }
        if lhs.key != rhs.key { return lhs.key < rhs.key }
        return lhs.value < rhs.value
    }
}

/// One formal concept: a maximal `(extent, intent)` pair where every
/// row in `extent` carries every attribute in `intent`, and neither
/// side can grow without shrinking the other. Both sides are
/// materialized as sorted arrays at the boundary so output order is
/// deterministic and language-agnostic.
public struct FormalConcept: Hashable, Codable, Sendable {
    /// Rows carrying every attribute in `intent`, ascending.
    public let extent: [FormalContext.RowID]
    /// Attributes common to every row in `extent`, ascending.
    public let intent: [FormalAttribute]
    /// `extent.count`, the standard FCA support measure.
    public let support: Int
    /// Sampled Kuznetsov stability estimate. **Always `nil` in v1** —
    /// the exact computation is exponential and is deliberately
    /// omitted; the field reserves the shape for a future sampled
    /// estimator with a fixed, seeded budget (never exact subset
    /// enumeration).
    public let stability: Double?

    public init(
        extent: [FormalContext.RowID],
        intent: [FormalAttribute],
        support: Int,
        stability: Double? = nil
    ) {
        self.extent = extent
        self.intent = intent
        self.support = support
        self.stability = stability
    }
}

/// A materialized formal context: `rowCount` rows × a deduplicated,
/// sorted attribute universe, stored as bitsets in both directions
/// (rows-per-attribute and attributes-per-row) so the two derivation
/// operators are plain word-wise intersections.
///
/// Rows are addressed by a context-local 0-based index. The `RowID`
/// typealias is nested (not top-level) because `LocusKit` already
/// exports a top-level `RowID = String` on NeuronKit's import
/// surface; the deferred estate wrapper maps estate row identifiers
/// to these indices.
public struct FormalContext: Sendable {
    /// Context-local 0-based row index. Nested to avoid colliding
    /// with `LocusKit.RowID` (a `String`) on the module surface.
    public typealias RowID = UInt32

    /// The deduplicated attribute universe, ascending. Index in this
    /// array is the attribute's bit position in row bitsets.
    public let attributes: [FormalAttribute]

    /// Number of rows the context was materialized over.
    public let rowCount: Int

    /// `attributes[i]` → bitset over rows carrying that attribute.
    private let attributeRows: [FCABitSet]

    /// row → bitset over attribute indices that row carries.
    private let rowAttributes: [FCABitSet]

    /// attribute → its index in `attributes` (closure-operator lookup).
    private let attributeIndex: [FormalAttribute: Int]

    /// Materializes a context from per-row attribute sets. Row `i` of
    /// `rows` becomes `RowID(i)`. Duplicate attributes within a row
    /// are collapsed; the attribute universe is the sorted union
    /// across all rows.
    public init(rows: [[FormalAttribute]]) {
        let rowCount = rows.count
        let universe = Array(Set(rows.flatMap { $0 })).sorted()
        var index: [FormalAttribute: Int] = [:]
        index.reserveCapacity(universe.count)
        for (i, attribute) in universe.enumerated() { index[attribute] = i }

        var attributeRows = Array(
            repeating: FCABitSet(bitCount: rowCount), count: universe.count
        )
        var rowAttributes = Array(
            repeating: FCABitSet(bitCount: universe.count), count: rowCount
        )
        for (row, rowAttrs) in rows.enumerated() {
            for attribute in rowAttrs {
                // Force-unwrap is safe: `universe` is the union of all
                // row attributes, so every attribute has an index.
                let a = index[attribute]!
                attributeRows[a].set(row)
                rowAttributes[row].set(a)
            }
        }

        self.attributes = universe
        self.rowCount = rowCount
        self.attributeRows = attributeRows
        self.rowAttributes = rowAttributes
        self.attributeIndex = index
    }

    // MARK: - Derivation operators

    /// The extent of an intent: every row carrying *all* of the given
    /// attributes, ascending. Standard FCA semantics: the empty
    /// intent's extent is all rows; an attribute absent from the
    /// context constrains the extent to empty.
    public func extent(of intent: [FormalAttribute]) -> [RowID] {
        extentBits(of: intent).setBits.map { RowID($0) }
    }

    /// The intent of an extent: every attribute carried by *all* of
    /// the given rows, ascending. Standard FCA semantics: the empty
    /// extent's intent is all attributes. Row indices `>= rowCount`
    /// never occur in engine output and are ignored here (they
    /// reference no row, so they cannot constrain the intersection).
    public func intent(of extent: [RowID]) -> [FormalAttribute] {
        var bits = FCABitSet(bitCount: attributes.count, allSet: true)
        for row in extent where Int(row) < rowCount {
            bits.formIntersection(rowAttributes[Int(row)])
        }
        return bits.setBits.map { attributes[$0] }
    }

    /// The closure of an intent: `intent(extent(intent))` — the
    /// largest attribute set shared by exactly the rows the input
    /// selects. Idempotent: `closure(closure(x)) == closure(x)`.
    public func closure(of intent: [FormalAttribute]) -> [FormalAttribute] {
        var bits = FCABitSet(bitCount: attributes.count, allSet: true)
        let rows = extentBits(of: intent)
        for row in rows.setBits {
            bits.formIntersection(rowAttributes[row])
        }
        return bits.setBits.map { attributes[$0] }
    }

    // MARK: - Internal bitset forms (shared by the miner)

    /// `extent(of:)` in bitset form, before the sorted-array boundary.
    internal func extentBits(of intent: [FormalAttribute]) -> FCABitSet {
        var bits = FCABitSet(bitCount: rowCount, allSet: true)
        for attribute in intent {
            guard let a = attributeIndex[attribute] else {
                // Unknown attribute: no row carries it.
                return FCABitSet(bitCount: rowCount)
            }
            bits.formIntersection(attributeRows[a])
        }
        return bits
    }

    /// Rows carrying the attribute at universe index `a` (the miner's
    /// single-attribute support source).
    internal func rowsBits(ofAttributeAt a: Int) -> FCABitSet {
        attributeRows[a]
    }

    /// The intent (as sorted attributes) of a row bitset — the miner's
    /// closure step without re-deriving the extent.
    internal func intentAttributes(ofRowBits rows: FCABitSet) -> [FormalAttribute] {
        var bits = FCABitSet(bitCount: attributes.count, allSet: true)
        for row in rows.setBits {
            bits.formIntersection(rowAttributes[row])
        }
        return bits.setBits.map { attributes[$0] }
    }
}

// MARK: - Bounded concept miner

/// Bounded concept mining over a materialized `FormalContext`.
///
/// "Bounded" is the contract, not a tuning detail: the miner seeds
/// only from frequent single attributes (support ≥ `minSupport`),
/// takes ONE closure per seed, deduplicates by intent, and truncates
/// to `maxConcepts` — it never enumerates the full concept lattice,
/// and it computes no stability (see `FormalConcept.stability`).
/// Cost is O(|attributes| × closure), closure being plain bitset
/// intersections — polynomial, no exponential path.
///
/// Deterministic by construction: seeds are visited in the context's
/// sorted attribute order, and the result ordering is fully
/// specified (support desc, then intent size asc, then lexicographic
/// intent), so equal inputs yield identical output across runs and
/// across the Swift and Rust versions.
public struct BoundedConceptMiner: Sendable {
    /// Minimum extent size for a seed attribute and for an emitted
    /// concept. Values below 1 are clamped to 1 (an empty-extent
    /// concept is never emitted).
    public let minSupport: Int
    /// Maximum intent size of an emitted concept; closures larger
    /// than this are skipped.
    public let maxIntentSize: Int
    /// Maximum number of concepts returned (post-sort truncation).
    public let maxConcepts: Int

    public init(minSupport: Int, maxIntentSize: Int, maxConcepts: Int) {
        self.minSupport = minSupport
        self.maxIntentSize = maxIntentSize
        self.maxConcepts = maxConcepts
    }

    /// Mines bounded concepts from `context`. Returns concepts sorted
    /// by support descending, then intent size ascending, then
    /// lexicographic intent (the stable key), truncated to
    /// `maxConcepts`.
    public func mine(context: FormalContext) -> [FormalConcept] {
        guard maxConcepts > 0, maxIntentSize > 0, context.rowCount > 0 else {
            return []
        }
        let support = Swift.max(1, minSupport)

        // Seed pass: one closure per frequent single attribute,
        // deduplicated by intent. Sorted-attribute iteration order
        // makes the dedup map's insertion history deterministic.
        var byIntent: [[FormalAttribute]: FormalConcept] = [:]
        for a in 0..<context.attributes.count {
            let rows = context.rowsBits(ofAttributeAt: a)
            if rows.popcount < support { continue }

            // closure([seed]) — extent is exactly the seed's rows
            // (single-attribute intent), so the closure is one
            // intent-derivation over that row bitset.
            let intent = context.intentAttributes(ofRowBits: rows)
            if intent.count > maxIntentSize { continue }
            if byIntent[intent] != nil { continue }

            byIntent[intent] = FormalConcept(
                extent: rows.setBits.map { FormalContext.RowID($0) },
                intent: intent,
                support: rows.popcount,
                stability: nil
            )
        }

        // Fully-specified ordering: support desc, intent size asc,
        // then lexicographic intent as the stable key.
        var concepts = Array(byIntent.values)
        concepts.sort { lhs, rhs in
            if lhs.support != rhs.support { return lhs.support > rhs.support }
            if lhs.intent.count != rhs.intent.count {
                return lhs.intent.count < rhs.intent.count
            }
            return lhs.intent.lexicographicallyPrecedes(rhs.intent)
        }
        if concepts.count > maxConcepts {
            concepts.removeLast(concepts.count - maxConcepts)
        }
        return concepts
    }
}

// MARK: - Bitset

/// Minimal fixed-width bitset over `UInt64` words. Internal so the
/// context, the miner, and the tests share one implementation; the
/// Rust version mirrors it word-for-word.
internal struct FCABitSet: Sendable, Equatable {
    private(set) var words: [UInt64]
    let bitCount: Int

    /// All-zero (default) or all-one over exactly `bitCount` bits.
    /// The trailing partial word is masked on the all-set path so
    /// iteration and popcount never see phantom bits.
    init(bitCount: Int, allSet: Bool = false) {
        self.bitCount = bitCount
        let wordCount = (bitCount + 63) / 64
        if allSet {
            var words = Array(repeating: ~UInt64(0), count: wordCount)
            let trailing = bitCount % 64
            if trailing != 0, wordCount > 0 {
                words[wordCount - 1] = (UInt64(1) << trailing) - 1
            }
            self.words = words
        } else {
            self.words = Array(repeating: 0, count: wordCount)
        }
    }

    mutating func set(_ bit: Int) {
        words[bit / 64] |= UInt64(1) << (bit % 64)
    }

    mutating func formIntersection(_ other: FCABitSet) {
        for i in 0..<words.count {
            words[i] &= other.words[i]
        }
    }

    /// Number of set bits.
    var popcount: Int {
        words.reduce(0) { $0 + $1.nonzeroBitCount }
    }

    /// Set bit positions, ascending — the deterministic iteration
    /// order every sorted-array boundary derives from.
    var setBits: [Int] {
        var bits: [Int] = []
        bits.reserveCapacity(popcount)
        for (w, var word) in words.enumerated() {
            while word != 0 {
                let bit = word.trailingZeroBitCount
                bits.append(w * 64 + bit)
                word &= word - 1
            }
        }
        return bits
    }
}
