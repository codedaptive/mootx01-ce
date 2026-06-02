// AssociationRuleMining.swift
//
// Pairwise association-rule mining over the co-occurrence matrix O
// (cookbook § 6.3). The substrate accumulates `MatrixO` on every
// capture/mutate/expunge; this engine lifts inspectable single-
// antecedent → single-consequent rules off it.
//
// Pairwise-only, by the shape of `MatrixO`: `applyRow` iterates all
// ordered (i, j) field pairs of a row INCLUDING i == j, so the
// diagonal is retained — `O[(f,v),(f,v)]` is single-item support and
// `O[(fi,vi),(fj,vj)]` is 2-itemset support. That is enough for
// pairwise rules and NOT enough for k>2 itemsets (those need
// row-replay — a separate future mission).
//
// Two contract points the engine relies on (both verified against
// `SubstrateTypes/MatrixO.swift`):
//
//   1. Single-item support comes from `MatrixO`'s retained diagonal
//      (`O[A,A]`), NOT from `MatrixF` — `MatrixF` counts per-BIT
//      presence (216 cells, 36 fields × 6 bits), the wrong
//      denominator for a 6-bit field VALUE.
//   2. The diagonal is excluded when EMITTING rules: `O[A,A]` is
//      where support comes from, but an `A → A` self-rule would have
//      confidence ≡ 1 and carries no information.
//
// Metrics, with `N` = activeRowCount (injected by the caller, never
// derived from the matrix):
//
//     support(A,B)    = O[A,B] / N
//     confidence(A→B) = O[A,B] / O[A,A]
//     lift            = (O[A,B] · N) / (O[A,A] · O[B,B])
//     leverage        = O[A,B]/N − (O[A,A]/N)(O[B,B]/N)
//     conviction      = (1 − O[B,B]/N) / (1 − confidence)
//                       (+inf when confidence == 1)
//
// Pure engine, mirroring `MMRRank`: `MatrixO` + active row count +
// thresholds in, ranked `[AssociationRule]` out. No estate, no
// clocks, no randomness — invariant B-1 (no substrate access) holds,
// and the Swift and Rust versions (`rust/src/association_rule_mining.rs`)
// run identical math against identical in-code vectors.

import SubstrateTypes

/// A single (field, value) item — one cell of a row's 6-bit field
/// assignment, the unit antecedents and consequents are made of.
///
/// `Comparable` on the packed key `(field << 8) | value`, mirroring
/// `CooccurrenceKey`'s packed ordering so rule emission order is
/// fully specified and identical across the Swift and Rust versions.
public struct Item: Hashable, Comparable, Sendable, Codable {
    public let field: UInt8
    public let value: UInt8

    public init(field: UInt8, value: UInt8) {
        self.field = field
        self.value = value
    }

    /// Pack into a UInt16 for ordering.
    /// Layout (high → low): field:8 | value:8.
    @inlinable
    public var packed: UInt16 {
        return (UInt16(field) << 8) | UInt16(value)
    }

    public static func < (a: Item, b: Item) -> Bool {
        return a.packed < b.packed
    }
}

/// One mined pairwise rule `antecedent → consequent` with the five
/// standard metrics. `conviction` is `+inf` when confidence == 1
/// (the consequent always follows the antecedent in the data).
public struct AssociationRule: Equatable, Sendable, Codable {
    public let antecedent: Item
    public let consequent: Item
    public let support: Double
    public let confidence: Double
    public let lift: Double
    public let conviction: Double
    public let leverage: Double

    public init(
        antecedent: Item,
        consequent: Item,
        support: Double,
        confidence: Double,
        lift: Double,
        conviction: Double,
        leverage: Double
    ) {
        self.antecedent = antecedent
        self.consequent = consequent
        self.support = support
        self.confidence = confidence
        self.lift = lift
        self.conviction = conviction
        self.leverage = leverage
    }
}

/// Minimum-metric gates a candidate rule must clear to be emitted.
/// A rule passes when `support >= minSupport` AND
/// `confidence >= minConfidence`.
public struct MiningThresholds: Equatable, Sendable, Codable {
    public let minSupport: Double
    public let minConfidence: Double

    public init(minSupport: Double, minConfidence: Double) {
        self.minSupport = minSupport
        self.minConfidence = minConfidence
    }
}

/// Mines pairwise association rules from a co-occurrence matrix.
///
/// Rules are emitted only for OBSERVED co-occurrences — the
/// off-diagonal cells `MatrixO` actually stores (the matrix drops
/// zero cells, so absent pairs have no observed support and yield
/// no rule regardless of thresholds).
///
/// - Parameters:
///   - matrix: the co-occurrence matrix O. Read-only input; the
///     retained diagonal supplies single-item support.
///   - activeRowCount: `N`, the number of active rows the matrix was
///     accumulated over. Injected by the caller — the engine never
///     derives it (the matrix has no row count). `N <= 0` returns
///     empty.
///   - thresholds: minimum support and confidence gates.
/// - Returns: rules sorted ascending on the packed
///   `(antecedent, consequent)` key. The pair is unique per rule, so
///   the order is total — no residual ties — and identical across
///   the Swift and Rust versions.
public func mineAssociationRules(
    matrix: MatrixO,
    activeRowCount: Int64,
    thresholds: MiningThresholds
) -> [AssociationRule] {
    return AssociationRuleEngine.mine(
        matrix: matrix,
        activeRowCount: activeRowCount,
        thresholds: thresholds
    )
}

/// Pure pairwise rule-mining core. Internal so the Swift conformance
/// tests and the Rust version run identical math against the same
/// vectors; the public `mineAssociationRules` is the thin wrapper.
///
/// No estate, no clocks, no randomness — every output is a
/// deterministic function of the inputs.
internal enum AssociationRuleEngine {

    /// Mines rules in a single ordered pass over `matrix.entries`.
    ///
    /// `entries` is canonically sorted by `CooccurrenceKey.packed`
    /// ascending — i.e. lexicographically on (fieldI, valueI,
    /// fieldJ, valueJ) — which IS ascending packed
    /// (antecedent, consequent) order. Emitting during the ordered
    /// scan therefore yields the documented output order with no
    /// explicit sort.
    static func mine(
        matrix: MatrixO,
        activeRowCount: Int64,
        thresholds: MiningThresholds
    ) -> [AssociationRule] {
        // Two-pass over the same canonical scan, kept in one body so
        // the conformance-critical control flow (guard order, gate
        // order, emission order) reads top to bottom in both versions.
        // N <= 0: no population to measure support against.
        guard activeRowCount > 0 else { return [] }
        let n = Double(activeRowCount)

        // Pass 1 — single-item support off the retained diagonal:
        // O[A,A] for every item the matrix has seen alone or with
        // others. (`applyRow` writes the diagonal on every row, so
        // any item with presence has a diagonal cell.)
        var singleSupport: [Item: Int64] = [:]
        for entry in matrix.entries {
            let key = entry.key
            if key.fieldI == key.fieldJ && key.valueI == key.valueJ {
                singleSupport[Item(field: key.fieldI, value: key.valueI)] = entry.count
            }
        }

        // Pass 2 — emit rules from off-diagonal cells, in entry
        // (= packed-key) order.
        var rules: [AssociationRule] = []
        for entry in matrix.entries {
            let key = entry.key
            let antecedent = Item(field: key.fieldI, value: key.valueI)
            let consequent = Item(field: key.fieldJ, value: key.valueJ)

            // The diagonal is support storage, not a rule: an A → A
            // self-rule has confidence ≡ 1 and is excluded.
            if antecedent == consequent { continue }

            // O[A,A] == 0: the antecedent has no single-item support
            // to condition on. O[B,B] == 0: the consequent has no
            // base rate for lift/conviction. Either way, skip.
            guard let countAA = singleSupport[antecedent], countAA > 0 else { continue }
            guard let countBB = singleSupport[consequent], countBB > 0 else { continue }

            let countAB = Double(entry.count)
            let support = countAB / n
            let confidence = countAB / Double(countAA)

            // Threshold gates — below-threshold rules are dropped.
            guard support >= thresholds.minSupport,
                  confidence >= thresholds.minConfidence else { continue }

            let lift = (countAB * n) / (Double(countAA) * Double(countBB))
            let leverage = countAB / n
                - (Double(countAA) / n) * (Double(countBB) / n)
            let conviction: Double
            if confidence == 1.0 {
                // The consequent never fails to follow the
                // antecedent — conviction's denominator is zero.
                conviction = .infinity
            } else {
                conviction = (1.0 - Double(countBB) / n) / (1.0 - confidence)
            }

            rules.append(AssociationRule(
                antecedent: antecedent,
                consequent: consequent,
                support: support,
                confidence: confidence,
                lift: lift,
                conviction: conviction,
                leverage: leverage
            ))
        }

        return rules
    }
}
