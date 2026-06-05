// AprioriMining.swift
//
// Standard Apriori algorithm (Agrawal & Srikant 1994) over
// `RowAttributeView` rows. Produces multi-antecedent rules:
//
//   {A, B, …} → C
//
// where all items are drawn from the `Item` type shared with
// `AssociationRuleMining`. At `maxK = 2` (one antecedent item)
// the output is equivalent to `mineAssociationRules` on the same
// data: both count co-occurrence at row granularity and apply the
// same metric formulas, so results agree for identical inputs.
//
// Why a separate rule type (`AprioriRule`) rather than reusing
// `AssociationRule`: `AssociationRule.antecedent` is a single
// `Item`, not an `[Item]`. `AssociationRuleMining.swift` is
// off-limits (MX-2 constraint). The two engines share `Item` as
// the atom and are otherwise independent.
//
// Algorithm outline:
//   1. Convert each `RowAttributeView` to a `Set<Item>`.
//   2. Find frequent 1-itemsets (support ≥ minSupport).
//   3. Join: generate size-k candidates from frequent (k-1)-itemsets
//      that share a lexicographic prefix of length k-2 (Apriori join).
//   4. Count candidate support with subset tests against row sets.
//   5. Prune candidates below minSupport.
//   6. Repeat steps 3–5 until k > maxK or no new frequent itemsets.
//   7. Extract rules from all frequent itemsets of size ≥ 2.
//      Each item in the itemset can be the consequent; the rest form
//      the antecedent.
//   8. Filter by minSupport, minConfidence, minLift.
//   9. Sort: lift ↓, confidence ↓, evidenceCount ↓.
//
// Metric definitions (N = total rows):
//
//   let AB = count(rows ⊇ antecedent ∪ {consequent})
//   let A  = count(rows ⊇ antecedent)
//   let B  = count(rows ⊇ {consequent})
//
//   support    = AB / N
//   confidence = AB / A
//   lift       = (AB × N) / (A × B)   ≡ support / (P(A) × P(B))
//   leverage   = AB/N − (A/N)(B/N)
//   conviction = (1 − B/N) / (1 − confidence)   [+inf when conf = 1]

import SubstrateTypes

// MARK: - Public types

/// Minimum-metric gates for the Apriori engine.
///
/// `maxK` bounds the total itemset size (antecedent + consequent).
/// At `maxK = 2` the engine emits only pairwise rules (equivalent to
/// `mineAssociationRules`). Default is 3.
public struct AprioriThresholds: Equatable, Sendable, Codable {
    /// Minimum fraction of rows that must contain the full itemset.
    public let minSupport: Double
    /// Minimum conditional probability P(consequent | antecedent).
    public let minConfidence: Double
    /// Minimum lift. Must be ≥ 1.0 to suppress spurious anti-correlated
    /// rules; raising it further limits output to strongly co-occurring
    /// patterns.
    public let minLift: Double
    /// Maximum total itemset size (antecedent items + 1 consequent).
    /// Capped below at 2; values < 2 are promoted to 2 so at least
    /// pairwise rules can be emitted.
    public let maxK: Int

    public init(
        minSupport: Double,
        minConfidence: Double,
        minLift: Double = 1.0,
        maxK: Int = 3
    ) {
        self.minSupport = minSupport
        self.minConfidence = minConfidence
        self.minLift = minLift
        self.maxK = max(2, maxK)
    }
}

/// One mined rule `antecedent → consequent` with five standard
/// metrics and a raw evidence count.
///
/// `antecedent` is sorted ascending on `Item.packed` for
/// deterministic equality and serialisation across Swift and Rust.
///
/// `conviction` is `+inf` when `confidence == 1`.
public struct AprioriRule: Equatable, Sendable, Codable {
    public let antecedent: [Item]
    public let consequent: Item
    public let support: Double
    public let confidence: Double
    public let lift: Double
    public let conviction: Double
    public let leverage: Double
    /// Raw row count: rows containing the full antecedent ∪ consequent.
    /// Used as the third sort key and as an interpretability handle for
    /// callers that want to inspect raw evidence.
    public let evidenceCount: Int

    public init(
        antecedent: [Item],
        consequent: Item,
        support: Double,
        confidence: Double,
        lift: Double,
        conviction: Double,
        leverage: Double,
        evidenceCount: Int
    ) {
        self.antecedent = antecedent
        self.consequent = consequent
        self.support = support
        self.confidence = confidence
        self.lift = lift
        self.conviction = conviction
        self.leverage = leverage
        self.evidenceCount = evidenceCount
    }
}

// MARK: - Engine

/// Apriori multi-antecedent association-rule engine.
///
/// Pure function: `RowAttributeView` rows + thresholds in,
/// `[AprioriRule]` out. No estate, no clocks, no randomness.
/// The Swift and Rust versions (`rust/src/apriori_mining.rs`) run
/// identical math against the same conformance vectors.
public enum AprioriMining {

    /// Mine association rules from a row-replay dataset.
    ///
    /// - Parameters:
    ///   - rows: categorical features per row, built via
    ///     `RowAttributeView.from(auditEntries:)` or by direct
    ///     construction for testing. Empty input returns empty.
    ///   - thresholds: minimum support, confidence, lift, and maxK gates.
    /// - Returns: rules sorted by lift ↓, confidence ↓, evidenceCount ↓.
    public static func mine(
        rows: [RowAttributeView],
        thresholds: AprioriThresholds
    ) -> [AprioriRule] {
        guard !rows.isEmpty else { return [] }

        let n = rows.count
        let nDouble = Double(n)

        // Convert each row to a Set<Item> for O(1) membership testing in
        // the subset-support counting step.
        let rowSets: [Set<Item>] = rows.map { view in
            Set(view.attributes.map { Item(field: $0.field, value: $0.value) })
        }

        // Step 1: frequent 1-itemsets.
        var singleCounts: [Item: Int] = [:]
        for rowSet in rowSets {
            for item in rowSet {
                singleCounts[item, default: 0] += 1
            }
        }

        // `allFrequent` accumulates every frequent itemset (1..maxK)
        // so rule generation can look up antecedent and consequent
        // supports in O(1) after the main loop.
        var allFrequent: [HashableItemset: Int] = [:]

        var prevLevel: [HashableItemset] = []
        for (item, count) in singleCounts {
            let support = Double(count) / nDouble
            if support >= thresholds.minSupport {
                let hs = HashableItemset(items: [item])
                allFrequent[hs] = count
                prevLevel.append(hs)
            }
        }
        prevLevel.sort(by: itemsetLess)

        // Steps 2..maxK: join, count, prune.
        for _ in 2...thresholds.maxK {
            guard !prevLevel.isEmpty else { break }
            let candidates = aprioriJoin(from: prevLevel)
            guard !candidates.isEmpty else { break }

            var nextLevel: [HashableItemset] = []
            for candidate in candidates {
                let candidateSet = Set(candidate.items)
                let count = rowSets.filter { candidateSet.isSubset(of: $0) }.count
                let support = Double(count) / nDouble
                if support >= thresholds.minSupport {
                    allFrequent[candidate] = count
                    nextLevel.append(candidate)
                }
            }
            prevLevel = nextLevel.sorted(by: itemsetLess)
        }

        // Step 3: extract rules from all frequent itemsets of size ≥ 2.
        // Iterate over itemsets in canonical lexicographic order to make
        // rule generation order deterministic regardless of dictionary
        // hash layout (Swift Dictionary iteration order is not defined).
        var rules: [AprioriRule] = []

        let sortedFrequent = allFrequent.keys
            .filter { $0.items.count >= 2 }
            .sorted(by: itemsetLess)

        for hs in sortedFrequent {
            let abCount = allFrequent[hs]!
            let items = hs.items

            for consequentIdx in 0..<items.count {
                let consequent = items[consequentIdx]
                let antecedent = itemsRemoving(items, at: consequentIdx)

                guard let aCount = allFrequent[HashableItemset(items: antecedent)],
                      aCount > 0 else { continue }

                // Single-item support for consequent (needed for lift/conviction).
                guard let bCount = allFrequent[HashableItemset(items: [consequent])],
                      bCount > 0 else { continue }

                let support = Double(abCount) / nDouble
                let confidence = Double(abCount) / Double(aCount)
                // lift = P(A∪B) / (P(A) * P(B)) = (AB * N) / (A * B)
                let lift = (Double(abCount) * nDouble) / (Double(aCount) * Double(bCount))

                guard support >= thresholds.minSupport,
                      confidence >= thresholds.minConfidence,
                      lift >= thresholds.minLift else { continue }

                let leverage = Double(abCount) / nDouble
                    - (Double(aCount) / nDouble) * (Double(bCount) / nDouble)
                let conviction: Double
                if confidence >= 1.0 {
                    conviction = .infinity
                } else {
                    conviction = (1.0 - Double(bCount) / nDouble) / (1.0 - confidence)
                }

                rules.append(AprioriRule(
                    antecedent: antecedent,
                    consequent: consequent,
                    support: support,
                    confidence: confidence,
                    lift: lift,
                    conviction: conviction,
                    leverage: leverage,
                    evidenceCount: abCount
                ))
            }
        }

        // Sort: lift ↓, confidence ↓, evidenceCount ↓,
        // then lexicographic (antecedent packed keys ↑, consequent packed ↑).
        // The four-key total order guarantees identical output across runs
        // and across Swift/Rust dictionary implementations (which may iterate
        // in different hash orders, producing different input orderings to sort).
        rules.sort {
            if $0.lift != $1.lift { return $0.lift > $1.lift }
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            if $0.evidenceCount != $1.evidenceCount { return $0.evidenceCount > $1.evidenceCount }
            // Lexicographic tie-break on antecedent then consequent.
            for (a, b) in zip($0.antecedent, $1.antecedent) {
                if a.packed != b.packed { return a.packed < b.packed }
            }
            if $0.antecedent.count != $1.antecedent.count {
                return $0.antecedent.count < $1.antecedent.count
            }
            return $0.consequent.packed < $1.consequent.packed
        }

        return rules
    }
}

// MARK: - Public free function

/// Mines multi-antecedent association rules from row-replay data.
///
/// Thin wrapper over `AprioriMining.mine` for call sites that prefer
/// a free-function API consistent with `mineAssociationRules`.
public func mineAprioriRules(
    rows: [RowAttributeView],
    thresholds: AprioriThresholds
) -> [AprioriRule] {
    AprioriMining.mine(rows: rows, thresholds: thresholds)
}

// MARK: - Internal helpers

/// Hashable wrapper for a sorted `[Item]` slice.
///
/// `items` MUST be sorted ascending by `Item.packed` before wrapping.
/// The sort invariant is established at construction sites in this file;
/// callers outside this file use `AprioriMining.mine` and never touch
/// `HashableItemset` directly.
private struct HashableItemset: Hashable {
    let items: [Item]

    func hash(into hasher: inout Hasher) {
        hasher.combine(items.count)
        for item in items { hasher.combine(item.packed) }
    }

    static func == (lhs: HashableItemset, rhs: HashableItemset) -> Bool {
        guard lhs.items.count == rhs.items.count else { return false }
        return zip(lhs.items, rhs.items).allSatisfy { $0 == $1 }
    }
}

/// Lexicographic comparison for sorted itemsets (by `Item.packed`).
private func itemsetLess(_ a: HashableItemset, _ b: HashableItemset) -> Bool {
    for i in 0..<min(a.items.count, b.items.count) {
        if a.items[i].packed != b.items[i].packed {
            return a.items[i].packed < b.items[i].packed
        }
    }
    return a.items.count < b.items.count
}

/// Return `items` with the element at `index` removed, preserving sort order.
private func itemsRemoving(_ items: [Item], at index: Int) -> [Item] {
    var result = items
    result.remove(at: index)
    return result
}

/// Apriori join step: produce size-k candidates from a sorted list of
/// frequent size-(k-1) itemsets.
///
/// Two (k-1)-itemsets are joined when they share the first (k-2) items
/// lexicographically (the "prefix condition"). Since `level` is sorted,
/// itemsets that share a prefix are contiguous, so the O(n^2) scan is
/// efficient in practice for the small item counts typical of this domain.
///
/// For k=2 (generating from 1-itemsets): all pairs combine, because the
/// shared prefix of length 0 is vacuously true.
private func aprioriJoin(from level: [HashableItemset]) -> [HashableItemset] {
    guard !level.isEmpty else { return [] }
    let prevK = level[0].items.count
    let prefixLen = prevK - 1   // items to share (0 for 1→2)

    var candidates: [HashableItemset] = []
    let count = level.count

    for i in 0..<count {
        for j in (i + 1)..<count {
            let a = level[i].items
            let b = level[j].items

            // Shared-prefix condition (vacuously true when prefixLen == 0).
            var shared = true
            for p in 0..<prefixLen {
                if a[p] != b[p] { shared = false; break }
            }
            // Since items are sorted and a < b lexicographically,
            // a[prevK-1] < b[prevK-1] when the prefix matches —
            // so the new item b[prevK-1] extends the itemset in order.
            if shared {
                var candidate = a
                candidate.append(b[prevK - 1])
                candidates.append(HashableItemset(items: candidate))
            }
        }
    }
    return candidates
}
