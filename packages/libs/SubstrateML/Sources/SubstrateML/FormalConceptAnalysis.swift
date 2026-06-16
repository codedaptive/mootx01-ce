// FormalConceptAnalysis.swift
//
// Bounded Formal Concept Analysis over a materialized `FormalContext`.
// FCA finds *exact* attribute closures — the concepts that emerge from
// observed data rather than the authored taxonomy — distinct from
// Louvain (graph communities), NMF (soft themes), and Hamming recall
// (nearby fingerprints).
//
// The engine is pure data-in / data-out: it takes a fully-materialized
// `FormalContext` (rows × attributes) and reads no estate, no
// `MatrixO`, no clocks. Randomness is injected via an explicit seed
// (StabilityEstimator uses SplitMix64 seeded from the caller's seed XOR
// the concept's FNV hash). Building a context from the estate (which
// rows carry which `(field,value)` attributes) is the coupled part and
// lives in the cognition tier, NOT this pure engine — CognitionKit's
// `FormalConcepts` recipe builds the context from recalled drawers. The Swift
// conformance tests and the Rust version
// (`packages/libs/SubstrateML/rust/src/formal_concept_analysis.rs`) exercise identical inputs
// and expected outputs, mirroring the pure-engine + inline-conformance
// pattern used by other SubstrateML engines.
//
// Bounding contract (the reason this is "bounded" FCA):
//   - NO full concept-lattice enumeration anywhere. Concepts are
//     seeded by default only from frequent single attributes (`.single`
//     mode). `.multi` mode additionally seeds from frequent 2-attribute
//     pairs (capped by `maxSeeds`); still one closure per seed;
//     deduplicated by intent.
//   - NO exact Kuznetsov stability. Exact stability is exponential
//     (subset enumeration over the extent); v1 omits the computation
//     entirely. When `BoundedConceptMiner.stabilityBudget > 0`, the
//     sampled `StabilityEstimator` populates `FormalConcept.stability`.
//     The field remains `nil` when `stabilityBudget == 0` (the default).

import Foundation
import SubstrateTypes

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

// MARK: - Seed mode

/// Controls which seeds the bounded concept miner explores.
///
/// `.single` (default) seeds only from frequent single attributes —
/// the v1 behavior. `.multi` additionally seeds from frequent
/// 2-attribute combinations, generating more concepts in contexts
/// where 2-attribute pairs co-occur frequently without being dominated
/// by a single-attribute seed. The miner's bounding contract holds in
/// both modes: no full lattice enumeration, dedup by intent, truncation
/// to `maxConcepts`.
public enum SeedMode: Hashable, Codable, Sendable {
    /// Single-attribute seeds only. V1 default behavior.
    case single
    /// Single-attribute plus frequent 2-attribute pair seeds.
    case multi
}

// MARK: - Concept cover deltas

/// One cover delta in the concept order.
///
/// `lowerIntent` is the less-specific concept's intent (concept A);
/// `addedAttributes` is `B.intent − A.intent` — the attributes the
/// more-specific concept B gains over A. The pair (A, B) is a direct
/// cover: no concept C in the emitted set has an intent strictly
/// between A.intent and B.intent.
///
/// This is NOT a logical implication. `lowerIntent` present in a row
/// does NOT guarantee `addedAttributes` is also present; rows outside
/// B's extent may carry A's attributes without carrying the delta.
public struct CoverDelta: Hashable, Codable, Sendable {
    /// The less-specific (lower) concept's intent.
    public let lowerIntent: Set<FormalAttribute>
    /// Attributes added by the more-specific concept: `B.intent − A.intent`.
    public let addedAttributes: Set<FormalAttribute>

    public init(lowerIntent: Set<FormalAttribute>, addedAttributes: Set<FormalAttribute>) {
        self.lowerIntent = lowerIntent
        self.addedAttributes = addedAttributes
    }
}

/// Structural lens over the concept order: the set of cover deltas
/// over an emitted concept set.
///
/// For each pair (A, B) where A.intent is a strict subset of B.intent
/// and no intermediate concept C in the input list has intent strictly
/// between A.intent and B.intent, one `CoverDelta` is emitted:
/// `lowerIntent = A.intent`, `addedAttributes = B.intent − A.intent`.
///
/// This is **NOT an implication basis**. A cover delta from A to B does
/// NOT assert that every row containing A.intent also contains
/// B.intent's additional attributes. Rows outside B's extent may carry
/// A's attributes without carrying the delta. For sound logical
/// implications, use `ConceptImplications.conceptImplications(over:context:maxImplications:maxPremiseSize:)`.
///
/// Compute via `ConceptCoverDeltas.covering(concepts:)`.
public struct ConceptCoverDeltas: Sendable {
    /// Cover deltas sorted by lowerIntent size ascending, then
    /// addedAttributes size ascending, then lexicographic lowerIntent,
    /// then lexicographic addedAttributes. Ordering is fully specified
    /// and deterministic.
    public let coverDeltas: [CoverDelta]

    public init(coverDeltas: [CoverDelta]) {
        self.coverDeltas = coverDeltas
    }

    /// Compute cover deltas over a bounded concept set.
    ///
    /// For each pair (A, B) where A.intent ⊂ B.intent (strict), emits
    /// one `CoverDelta(lowerIntent: A.intent, addedAttributes: B.intent − A.intent)`
    /// when no concept C in the list has A.intent ⊂ C.intent ⊂ B.intent
    /// (the cover condition). Cost is O(n²·m) where n = `concepts.count`
    /// and m = average intent size — acceptable because `n` is bounded
    /// by `maxConcepts`.
    ///
    /// - Parameter concepts: the concept set from `BoundedConceptMiner`.
    ///   Empty input returns empty cover deltas.
    /// - Returns: cover deltas, deterministically ordered.
    public static func covering(concepts: [FormalConcept]) -> ConceptCoverDeltas {
        guard concepts.count >= 2 else { return ConceptCoverDeltas(coverDeltas: []) }

        // Sort by intent size ascending; equal sizes fall back to
        // lexicographic intent for a stable sort key.
        let sorted = concepts.sorted {
            if $0.intent.count != $1.intent.count {
                return $0.intent.count < $1.intent.count
            }
            return $0.intent.lexicographicallyPrecedes($1.intent)
        }
        let intentSets = sorted.map { Set($0.intent) }

        var coverDeltas: [CoverDelta] = []

        for i in 0..<sorted.count {
            for j in (i + 1)..<sorted.count {
                let si = intentSets[i]
                let sj = intentSets[j]

                // si must be a strict subset of sj.
                guard si.count < sj.count, si.isSubset(of: sj) else { continue }

                // Cover condition: no intermediate concept at k with
                // si ⊂ sk ⊂ sj. k ranges (i+1)..<j; any concept with
                // intent strictly between si and sj in set order must
                // have size strictly between si.count and sj.count, and
                // after sorting by size those concepts appear at indices
                // between i and j.
                var hasIntermediate = false
                for k in (i + 1)..<j {
                    let sk = intentSets[k]
                    if sk.count > si.count, sk.count < sj.count,
                       si.isSubset(of: sk), sk.isSubset(of: sj) {
                        hasIntermediate = true
                        break
                    }
                }

                if !hasIntermediate {
                    coverDeltas.append(CoverDelta(
                        lowerIntent: si,
                        addedAttributes: sj.subtracting(si)
                    ))
                }
            }
        }

        // Fully-specified sort for determinism.
        coverDeltas.sort { lhs, rhs in
            if lhs.lowerIntent.count != rhs.lowerIntent.count {
                return lhs.lowerIntent.count < rhs.lowerIntent.count
            }
            if lhs.addedAttributes.count != rhs.addedAttributes.count {
                return lhs.addedAttributes.count < rhs.addedAttributes.count
            }
            let lp = lhs.lowerIntent.sorted(), rp = rhs.lowerIntent.sorted()
            if lp != rp { return lp.lexicographicallyPrecedes(rp) }
            return lhs.addedAttributes.sorted().lexicographicallyPrecedes(rhs.addedAttributes.sorted())
        }

        return ConceptCoverDeltas(coverDeltas: coverDeltas)
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
    /// Sampled Kuznetsov stability estimate. `nil` when the miner ran
    /// with `stabilityBudget == 0` (the default, preserving nil
    /// behavior). Populated by `StabilityEstimator.estimate` when
    /// `stabilityBudget > 0`. Never exact Kuznetsov stability —
    /// always a sampled approximation. See SUBSTRATEML_SPEC_v0.8 §5.21.
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
/// typealias is nested (not top-level) because consumers that also
/// import LocusKit would encounter a top-level `RowID = String`
/// collision; the cognition-tier estate wrapper (CognitionKit
/// `FormalConcepts`) maps estate row identifiers to these indices.
public struct FormalContext: Sendable {
    /// Context-local 0-based row index. Nested to avoid colliding
    /// with `LocusKit.RowID` (a `String`) on a consumer's import
    /// surface when both modules are imported together.
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

    /// Materializes a context from `RowAttributeView` rows.
    ///
    /// Each `(field, value)` pair in a view becomes one `FormalAttribute`:
    ///   - `namespace = "row"` — marks origin as row-replay data.
    ///   - `key      = String(field)` — the vocabulary-index field.
    ///   - `value    = String(value)` — the attribute value (bit position
    ///     for bitmap fields, low-byte integer for integer fields).
    ///
    /// Row order in the returned context matches the order of `views`.
    /// Rows that carry zero attributes (empty `attributes` array) are
    /// retained as empty-row contexts: they contribute no attributes
    /// but do affect the extent of the empty intent.
    ///
    /// This factory is the shared entry point for FCA and Apriori over
    /// the audit log (cookbook §5.3 / §6.3). Build `views` with
    /// `RowAttributeView.from(auditEntries:)`.
    public static func from(rowAttributeViews views: [RowAttributeView]) -> FormalContext {
        let rows = views.map { view in
            view.attributes.map { a in
                FormalAttribute(namespace: "row", key: String(a.field), value: String(a.value))
            }
        }
        return FormalContext(rows: rows)
    }

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
/// to `maxConcepts`. Cost is O(|attributes| × closure) — polynomial,
/// no exponential path.
///
/// When `stabilityBudget > 0`, each emitted concept is additionally
/// passed to `StabilityEstimator.estimate(concept:context:budget:seed:)`
/// and the result is stored in `FormalConcept.stability`. This is the
/// sampled (bounded) approximation — never exact Kuznetsov stability.
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
    /// Seed strategy. Default `.single` preserves v1 behavior exactly
    /// (all existing tests pass unchanged). `.multi` additionally seeds
    /// from frequent 2-attribute combinations.
    public let seedMode: SeedMode
    /// Maximum number of 2-attribute seed pairs explored in `.multi`
    /// mode. Caps computational cost for contexts with many frequent
    /// attributes. Ignored in `.single` mode. `Int.max` (default)
    /// means no cap beyond `maxConcepts`.
    public let maxSeeds: Int
    /// Number of Bernoulli(p=0.5) samples for the sampled stability
    /// estimator. Zero (default) skips stability estimation entirely,
    /// leaving `FormalConcept.stability == nil` — the v1 behavior.
    public let stabilityBudget: Int
    /// Seed for the stability estimator. Mixed with each concept's FNV
    /// hash to give per-concept deterministic RNG streams. The canonical
    /// conformance seed is `0xCAFEBABEDEADBEEF`; this default matches
    /// the conformance vectors so callers that do not override get the
    /// conformance-gated behavior out of the box.
    public let stabilitySeed: UInt64

    public init(
        minSupport: Int,
        maxIntentSize: Int,
        maxConcepts: Int,
        seedMode: SeedMode = .single,
        maxSeeds: Int = Int.max,
        stabilityBudget: Int = 0,
        stabilitySeed: UInt64 = 0xCAFEBABEDEADBEEF
    ) {
        self.minSupport = minSupport
        self.maxIntentSize = maxIntentSize
        self.maxConcepts = maxConcepts
        self.seedMode = seedMode
        self.maxSeeds = maxSeeds
        self.stabilityBudget = stabilityBudget
        self.stabilitySeed = stabilitySeed
    }

    /// Mines bounded concepts from `context`. Returns concepts sorted
    /// by support descending, then intent size ascending, then
    /// lexicographic intent (the stable key), truncated to
    /// `maxConcepts`.
    ///
    /// In `.single` mode (default): seeds from frequent single
    /// attributes only — identical to v1 behavior.
    ///
    /// In `.multi` mode: additionally seeds from frequent 2-attribute
    /// pairs. Each pair whose extent ≥ `minSupport` generates one
    /// closure (deduped by intent). The number of pairs tried is
    /// capped by `maxSeeds`.
    public func mine(context: FormalContext) -> [FormalConcept] {
        guard maxConcepts > 0, maxIntentSize > 0, context.rowCount > 0 else {
            return []
        }
        let support = Swift.max(1, minSupport)

        // Single-attribute seed pass: one closure per frequent
        // attribute, deduplicated by intent. Sorted-attribute
        // iteration order makes the dedup map deterministic.
        var byIntent: [[FormalAttribute]: FormalConcept] = [:]
        var frequentAttrIndices: [Int] = []

        for a in 0..<context.attributes.count {
            let rows = context.rowsBits(ofAttributeAt: a)
            if rows.popcount < support { continue }
            frequentAttrIndices.append(a)

            // closure([seed]) — single-attribute extent; the closure
            // is one intent-derivation over that row bitset.
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

        // Multi-attribute seed pass (only in .multi mode): seed from
        // frequent 2-attribute pairs of the frequent single attributes.
        // Pairs are visited in sorted-attribute index order (i < j),
        // which is deterministic. The number of pairs tried is capped
        // by maxSeeds to bound combinatorial cost.
        if seedMode == .multi {
            var pairsTried = 0
            outerLoop: for i in 0..<frequentAttrIndices.count {
                for j in (i + 1)..<frequentAttrIndices.count {
                    guard pairsTried < maxSeeds else { break outerLoop }
                    pairsTried += 1

                    let ai = frequentAttrIndices[i]
                    let aj = frequentAttrIndices[j]

                    // Extent of the pair = intersection of each
                    // attribute's row bitset.
                    var pairRows = context.rowsBits(ofAttributeAt: ai)
                    pairRows.formIntersection(context.rowsBits(ofAttributeAt: aj))
                    if pairRows.popcount < support { continue }

                    let intent = context.intentAttributes(ofRowBits: pairRows)
                    if intent.count > maxIntentSize { continue }
                    if byIntent[intent] != nil { continue }

                    byIntent[intent] = FormalConcept(
                        extent: pairRows.setBits.map { FormalContext.RowID($0) },
                        intent: intent,
                        support: pairRows.popcount,
                        stability: nil
                    )
                }
            }
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

        // When a stability budget is set, estimate stability for each
        // emitted concept. Zero budget preserves the v1 nil behavior.
        if stabilityBudget > 0 {
            concepts = concepts.map { concept in
                FormalConcept(
                    extent: concept.extent,
                    intent: concept.intent,
                    support: concept.support,
                    stability: StabilityEstimator.estimate(
                        concept: concept,
                        context: context,
                        budget: stabilityBudget,
                        seed: stabilitySeed
                    )
                )
            }
        }

        return concepts
    }
}

// MARK: - Stability Estimator

/// Sampled approximation of Kuznetsov stability for one formal concept.
///
/// Exact Kuznetsov stability enumerates all subsets of the extent —
/// exponential in extent size. This estimator draws `budget` independent
/// Bernoulli(p=0.5) samples and counts the fraction that reproduce the
/// concept's original intent when the closure is recomputed over the
/// sampled subset. Bernoulli p=0.5 is simpler than fixed-size
/// sample-without-replacement: no edge cases around empty or full
/// draws, and both outcomes are valid inputs to the closure operator.
///
/// Properties:
///   - **Bounded**: O(budget × |extent|) per concept.
///   - **Deterministic**: same (concept, context, budget, seed) → same
///     output across runs and across the Swift and Rust ports.
///   - **Bounded approximation**: not exact Kuznetsov stability and
///     never exact subset enumeration. See SUBSTRATEML_SPEC_v0.8 §5.21.
public enum StabilityEstimator {

    /// Estimate the sampled stability of `concept` in `context`.
    ///
    /// For each of `budget` iterations: draw a Bernoulli(p=0.5) subset
    /// of `concept.extent` (each row independently included when the
    /// low bit of the next SplitMix64 word is 1), compute
    /// `context.intent(of: subset)`, and count the fraction equal to
    /// `concept.intent`.
    ///
    /// The per-concept RNG seed is `seed ^ FNV.hash64(canonicalKey)`,
    /// giving each concept its own deterministic stream while keeping
    /// the relationship between seed and output uniform — the same
    /// mixing convention as `FloatSimHash` and `RandomWalks`.
    ///
    /// - Parameters:
    ///   - concept: the concept whose stability to estimate.
    ///   - context: the context the concept was mined from.
    ///   - budget: number of Bernoulli samples. Returns `0.0` when ≤ 0.
    ///   - seed: caller-supplied base seed. Canonical conformance seed
    ///     is `0xCAFEBABEDEADBEEF`.
    /// - Returns: estimated stability in `[0.0, 1.0]`.
    public static func estimate(
        concept: FormalConcept,
        context: FormalContext,
        budget: Int,
        seed: UInt64
    ) -> Double {
        guard budget > 0, !concept.extent.isEmpty else { return 0.0 }

        // XOR with the concept's FNV hash gives each concept a unique
        // deterministic SplitMix64 stream — identical mixing in Rust.
        let perConceptSeed = seed ^ FNV.hash64(canonicalKey(concept))
        var rng = SplitMix64(seed: perConceptSeed)
        var hits = 0

        for _ in 0..<budget {
            // Bernoulli(p=0.5): include each extent row when bit 0 of
            // the next RNG word is 1.
            var subset: [FormalContext.RowID] = []
            for rowID in concept.extent {
                if rng.next() & 1 == 1 { subset.append(rowID) }
            }
            // intent(∅) = all attributes (FCA convention). For a
            // non-top concept this almost always misses, which is
            // the correct Bernoulli outcome.
            if context.intent(of: subset) == concept.intent { hits += 1 }
        }

        return Double(hits) / Double(budget)
    }

    /// Canonical string key for per-concept seed mixing.
    ///
    /// Format: extent row indices (comma-separated decimal) + "|" +
    /// intent attributes as "namespace:key:value" ("|"-joined). Both
    /// sides are already sorted at the `FormalConcept` boundary, so
    /// this key is deterministic and identical across Swift and Rust.
    private static func canonicalKey(_ concept: FormalConcept) -> String {
        let extentPart = concept.extent.map { String($0) }.joined(separator: ",")
        let intentPart = concept.intent
            .map { "\($0.namespace):\($0.key):\($0.value)" }
            .joined(separator: "|")
        return "\(extentPart)|\(intentPart)"
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
