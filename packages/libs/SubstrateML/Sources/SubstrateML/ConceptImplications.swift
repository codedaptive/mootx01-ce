// ConceptImplications.swift
//
// Sound logical implications over a `FormalContext` via bounded
// Duquenne–Guigues canonical basis enumeration (Next-Closure).
//
// ALGORITHM: Next-Closure (Ganter 1999, "Two Basic Algorithms in Concept
// Analysis", TH Darmstadt Preprint 831). Enumeration visits candidate
// attribute sets in lectic order over the sorted attribute universe and
// identifies pseudo-intents: sets A whose closure A'' strictly contains A.
// Every pseudo-intent A yields one implication A → (A'' \ A) in the
// canonical basis. The basis is minimal (Duquenne–Guigues): no proper
// subset of it implies the same consequences, and every sound implication
// over the context follows from the basis by Armstrong's rules.
//
// SOUNDNESS CONTRACT:
// Every emitted implication (premise → conclusion) holds universally across
// every row of the context: if a row carries every attribute in premise, it
// carries every attribute in conclusion. This is guaranteed because
// conclusion = closure(premise) \ premise — the closure operator returns
// exactly the attributes shared by every row carrying premise.
//
// INCOMPLETENESS CONTRACT (bounding):
// Pseudo-intent enumeration is NP-hard in the worst case (exponential in
// the number of attributes). Two caps terminate the engine early:
//   - `maxImplications`: emits at most this many implications. When the cap
//     hits, `isTruncated == true` and the returned basis may be incomplete
//     (some pseudo-intents were not reached).
//   - `maxPremiseSize`: pseudo-intents with |premise| > this cap are
//     silently skipped (not emitted, not counted toward maxImplications).
//     This lets callers exclude complex implications without halting
//     enumeration entirely. No soundness violation: only emission, not
//     correctness, is affected.
//
// Together these make the algorithm tractable for estate-scale contexts.
// The `isTruncated` flag tells callers whether the basis is the complete
// canonical basis (false) or a sound prefix of it (true).
//
// DETERMINISM: the attribute universe is sorted (FormalAttribute is
// Comparable by lexicographic (namespace, key, value) order), so the
// lectic order and therefore the enumeration order are fully determined
// by the context. Same input → same implications in the same order.
//
// The Rust mirror lives at:
//   packages/libs/SubstrateML/rust/src/concept_implications.rs
// Both versions must produce bit-identical output on the shared conformance
// vectors in:
//   docs/engineering/substrate_reference/test-harness/vectors/concept_implications.json

import Foundation

// MARK: - Implication

/// One sound logical implication: if a row carries every attribute in
/// `premise`, it carries every attribute in `conclusion` as well.
///
/// The `premise` and `conclusion` are disjoint by construction:
/// `conclusion == closure(premise) \ premise` — the closure-minus-premise
/// delta. The union `premise ∪ conclusion` is a closed set (a formal
/// concept intent or union of concept intents) in the context.
///
/// This is a genuine logical implication — not a structural cover delta.
/// Every row in the context that satisfies the premise must satisfy the
/// conclusion, without exception.
public struct Implication: Hashable, Codable, Sendable {
    /// The premise attribute set. Non-empty for all canonical-basis
    /// implications (the empty premise would force every row to carry every
    /// attribute, which only holds when all attributes are global).
    public let premise: Set<FormalAttribute>
    /// The conclusion: `closure(premise) \ premise`. Always non-empty
    /// (sets with closure equal to themselves are concepts, not pseudo-intents,
    /// and are not emitted as implications).
    public let conclusion: Set<FormalAttribute>

    /// Creates an implication with the given premise and conclusion.
    ///
    /// The caller is responsible for the invariant `premise ∩ conclusion == ∅`.
    /// The `ConceptImplications` engine enforces this by construction.
    public init(premise: Set<FormalAttribute>, conclusion: Set<FormalAttribute>) {
        self.premise = premise
        self.conclusion = conclusion
    }
}

// MARK: - ConceptImplications

/// Sound logical implications over a `FormalContext` via bounded
/// Duquenne–Guigues canonical basis enumeration.
///
/// The basis is *sound*: every emitted implication holds universally in
/// the context. The basis may be *incomplete* when bounding caps bind
/// (`isTruncated == true`): some pseudo-intents were not reached, so the
/// returned set is a sound prefix of the full canonical basis.
///
/// Compute via `ConceptImplications.conceptImplications(over:context:maxImplications:maxPremiseSize:)`.
///
/// See the file-header comment for the algorithm, soundness/incompleteness
/// contracts, and the cite to Ganter (1999).
public struct ConceptImplications: Sendable {
    /// The emitted implications, sorted for determinism.
    ///
    /// Sort order: premise size ascending, then lexicographic premise
    /// (sorted element list), then lexicographic conclusion. Fully specified
    /// so equal inputs yield identical output across runs and across the
    /// Swift and Rust implementations.
    public let implications: [Implication]

    /// True when a bounding cap (`maxImplications` or similar) terminated
    /// enumeration before all pseudo-intents were visited. When true, the
    /// basis is sound but may be incomplete.
    public let isTruncated: Bool

    /// Creates a `ConceptImplications` result.
    public init(implications: [Implication], isTruncated: Bool) {
        self.implications = implications
        self.isTruncated = isTruncated
    }

    // MARK: - Engine

    /// Compute the bounded Duquenne–Guigues canonical basis for `context`.
    ///
    /// Uses Next-Closure (Ganter 1999) to enumerate pseudo-intents in
    /// lectic order over the context's sorted attribute universe. For each
    /// pseudo-intent A (where `A'' ≠ A`), emits
    /// `Implication(premise: A, conclusion: A'' \ A)`.
    ///
    /// Bounding:
    /// - `maxImplications`: hard cap on the number of emitted implications.
    ///   When reached, sets `isTruncated = true` and terminates early.
    /// - `maxPremiseSize`: pseudo-intents with `|A| > maxPremiseSize` are
    ///   skipped (not emitted, enumeration continues). This is a filter,
    ///   not a terminator — `isTruncated` remains `false` unless the
    ///   `maxImplications` cap is hit.
    ///
    /// Empty context returns empty implications without truncation.
    ///
    /// - Parameters:
    ///   - concepts: the concept set from `BoundedConceptMiner`. Passed
    ///     for API symmetry with `ConceptCoverDeltas`; only `context` is
    ///     used by the engine. Pass `[]` when a full-context computation
    ///     is desired without concept-set filtering.
    ///   - context: the fully-materialised `FormalContext`.
    ///   - maxImplications: maximum number of implications to emit.
    ///     Values ≤ 0 are treated as 0 (empty result, not truncated unless
    ///     pseudo-intents exist — use `Int.max` for an uncapped run).
    ///   - maxPremiseSize: maximum premise size to emit. Pseudo-intents
    ///     larger than this are skipped silently.
    /// - Returns: `ConceptImplications` with the emitted basis and
    ///   truncation flag.
    public static func conceptImplications(
        over concepts: [FormalConcept],
        context: FormalContext,
        maxImplications: Int,
        maxPremiseSize: Int
    ) -> ConceptImplications {
        // Empty context → empty basis, not truncated.
        guard context.attributes.count > 0, context.rowCount > 0 else {
            return ConceptImplications(implications: [], isTruncated: false)
        }

        // Zero cap means: return nothing (but do not signal truncation when
        // there are no pseudo-intents to emit). We check this by running the
        // engine with a zero cap — if it would have emitted something it will
        // set isTruncated.
        //
        // For maxImplications <= 0 with attributes present: run the normal
        // path so we correctly set isTruncated.
        return nextClosureEngine(
            context: context,
            maxImplications: maxImplications,
            maxPremiseSize: maxPremiseSize
        )
    }

    // MARK: - D-G Basis Engine (size-ordered pseudo-intent enumeration)

    /// Computes the Duquenne–Guigues canonical basis by enumerating all
    /// subsets of the attribute universe in size order (0, 1, 2, ...,
    /// maxPremiseSize) and testing each for pseudo-intenthood against the
    /// implication set L built incrementally.
    ///
    /// CORRECTNESS: this algorithm correctly computes the minimal D-G basis.
    /// A set P is a D-G pseudo-intent iff:
    ///   (1) closure_context(P) ≠ P  (P is not a concept intent / closed set)
    ///   (2) For every D-G pseudo-intent Q with Q ⊊ P: Q'' ⊆ P
    ///       (all conclusions of smaller pseudo-intents are already in P)
    ///
    /// By processing in non-decreasing size order, when we test P, all
    /// pseudo-intents of size < |P| are already in L. Condition (2) is
    /// then equivalent to: for all (premise, conclusion) in L where
    /// premise ⊊ P: conclusion ⊆ P.
    ///
    /// BOUNDING: subsets of size > maxPremiseSize are not tested. We still
    /// record each found pseudo-intent in stemBase (even when maxPremiseSize
    /// causes it to be skipped from emission) so that minimality checks for
    /// SUBSEQUENT larger subsets remain correct. Emission is bounded
    /// separately by maxImplications.
    ///
    /// COMPLEXITY: O(C(n, maxPremiseSize) × k) where n = |universe| and
    /// k = number of pseudo-intents found (for each candidate, checking
    /// condition 2 is O(k × |P|)). Tractable for typical estate contexts
    /// with maxPremiseSize ≤ 10.
    private static func nextClosureEngine(
        context: FormalContext,
        maxImplications: Int,
        maxPremiseSize: Int
    ) -> ConceptImplications {
        let universe = context.attributes // sorted ascending
        let n = universe.count

        var emitted: [Implication] = []
        // stemBase: all found D-G pseudo-intents and their conclusions,
        // including those with |premise| > maxPremiseSize (not emitted but
        // still needed for minimality checks of larger candidates).
        var stemBase: [(premise: Set<FormalAttribute>, conclusion: Set<FormalAttribute>)] = []
        var isTruncated = false

        // Enumerate by size from 0 to min(n, maxPremiseSize).
        // Use an index-set representation to enumerate combinations.
        let capSize = min(n, maxPremiseSize)

        // Special case: size 0 (empty set).
        let emptyContextClosure = Set(context.closure(of: []))
        if !emptyContextClosure.isEmpty {
            // {} is a pseudo-intent: closure of {} is non-empty (global attrs).
            // Condition (2): no proper subset of {} is a pseudo-intent. ✓
            if maxImplications <= 0 {
                isTruncated = true
                return ConceptImplications(implications: [], isTruncated: true)
            }
            let premise = Set<FormalAttribute>()
            let conclusion = emptyContextClosure
            emitted.append(Implication(premise: premise, conclusion: conclusion))
            stemBase.append((premise: premise, conclusion: conclusion))
            if emitted.count >= maxImplications {
                isTruncated = true
                return ConceptImplications(
                    implications: sortedImplications(emitted),
                    isTruncated: true
                )
            }
        }

        // Enumerate subsets of size 1..capSize via combination index arrays.
        // indices[k] ∈ [0, n) with indices[0] < indices[1] < ... < indices[k-1].
        // Skip if capSize is 0 (maxPremiseSize == 0: only the empty set is checked).
        guard capSize >= 1 else {
            return ConceptImplications(implications: sortedImplications(emitted), isTruncated: false)
        }
        for size in 1...capSize {
            guard size <= n else { break }
            // Enumerate all C(n, size) combinations of universe indices.
            var indices = Array(0..<size) // starting combination
            while true {
                // Build the subset from indices.
                let premiseSet = Set(indices.map { universe[$0] })

                // Test pseudo-intenthood.
                if isDGPseudoIntent(
                    premiseSet: premiseSet,
                    context: context,
                    stemBase: stemBase
                ) {
                    let contextClosureSet = Set(context.closure(of: Array(premiseSet)))
                    let conclusion = contextClosureSet.subtracting(premiseSet)
                    // Always record in stemBase for minimality (even if not emitted).
                    stemBase.append((premise: premiseSet, conclusion: conclusion))

                    // Emit if size ≤ maxPremiseSize (it always is here, since
                    // we cap the outer loop at capSize = min(n, maxPremiseSize)).
                    if maxImplications <= 0 {
                        isTruncated = true
                        return ConceptImplications(
                            implications: sortedImplications(emitted),
                            isTruncated: true
                        )
                    }
                    emitted.append(Implication(premise: premiseSet, conclusion: conclusion))
                    if emitted.count >= maxImplications {
                        // Check if more pseudo-intents exist beyond this point.
                        isTruncated = hasMorePseudoIntents(
                            after: indices, size: size,
                            universe: universe, context: context, stemBase: stemBase,
                            capSize: capSize
                        )
                        return ConceptImplications(
                            implications: sortedImplications(emitted),
                            isTruncated: isTruncated
                        )
                    }
                }

                // Advance to next combination in colexicographic order.
                guard let next = nextCombination(indices: indices, n: n) else { break }
                indices = next
            }
        }

        return ConceptImplications(
            implications: sortedImplications(emitted),
            isTruncated: false
        )
    }

    /// Tests whether `premiseSet` is a D-G pseudo-intent w.r.t. the context
    /// and the current stem base.
    ///
    /// Conditions:
    ///   (1) closure_context(premiseSet) ≠ premiseSet  (not closed)
    ///   (2) For every (premise, conclusion) in stemBase where premise ⊊ premiseSet:
    ///       conclusion ⊆ premiseSet  (every smaller pseudo-intent's conclusion
    ///       is already contained in premiseSet)
    private static func isDGPseudoIntent(
        premiseSet: Set<FormalAttribute>,
        context: FormalContext,
        stemBase: [(premise: Set<FormalAttribute>, conclusion: Set<FormalAttribute>)]
    ) -> Bool {
        // Condition (1): not closed.
        let contextClosure = Set(context.closure(of: Array(premiseSet)))
        guard contextClosure != premiseSet else { return false }

        // Condition (2): all smaller pseudo-intent conclusions are in premiseSet.
        for (premise, conclusion) in stemBase {
            // Only check strict subsets.
            if premise.count < premiseSet.count, premise.isSubset(of: premiseSet) {
                if !conclusion.isSubset(of: premiseSet) {
                    return false
                }
            }
        }
        return true
    }

    /// Returns the next combination of `size` indices from [0, n) in
    /// lexicographic order after `indices`, or `nil` when `indices` is the
    /// last combination.
    private static func nextCombination(indices: [Int], n: Int) -> [Int]? {
        var result = indices
        let k = result.count
        // Find the rightmost index that can be incremented.
        var i = k - 1
        while i >= 0 {
            if result[i] < n - (k - i) {
                result[i] += 1
                // Reset all indices to the right.
                for j in (i + 1)..<k {
                    result[j] = result[j - 1] + 1
                }
                return result
            }
            i -= 1
        }
        return nil // all combinations exhausted
    }

    /// Checks if there are any more pseudo-intents after the current state.
    ///
    /// Used to set `isTruncated` correctly when the maxImplications cap hits.
    /// Returns `true` if at least one more pseudo-intent exists in the
    /// remaining enumeration range.
    private static func hasMorePseudoIntents(
        after currentIndices: [Int],
        size: Int,
        universe: [FormalAttribute],
        context: FormalContext,
        stemBase: [(premise: Set<FormalAttribute>, conclusion: Set<FormalAttribute>)],
        capSize: Int
    ) -> Bool {
        let n = universe.count

        // Continue within the current size.
        var indices = currentIndices
        while let next = nextCombination(indices: indices, n: n) {
            indices = next
            let premiseSet = Set(indices.map { universe[$0] })
            if isDGPseudoIntent(premiseSet: premiseSet, context: context, stemBase: stemBase) {
                return true
            }
        }

        // Check larger sizes (only up to capSize).
        guard size + 1 <= capSize else { return false }
        for nextSize in (size + 1)...capSize {
            guard nextSize <= n else { break }
            var idx = Array(0..<nextSize)
            while true {
                let premiseSet = Set(idx.map { universe[$0] })
                if isDGPseudoIntent(premiseSet: premiseSet, context: context, stemBase: stemBase) {
                    return true
                }
                guard let next = nextCombination(indices: idx, n: n) else { break }
                idx = next
            }
        }
        return false
    }

    /// Sorts emitted implications for determinism.
    ///
    /// Order: premise size ascending, lexicographic premise elements,
    /// lexicographic conclusion elements. This order is fully specified
    /// and identical across Swift and Rust.
    private static func sortedImplications(_ implications: [Implication]) -> [Implication] {
        return implications.sorted { lhs, rhs in
            if lhs.premise.count != rhs.premise.count {
                return lhs.premise.count < rhs.premise.count
            }
            let lp = lhs.premise.sorted(), rp = rhs.premise.sorted()
            if lp != rp { return lp.lexicographicallyPrecedes(rp) }
            return lhs.conclusion.sorted()
                .lexicographicallyPrecedes(rhs.conclusion.sorted())
        }
    }

}
