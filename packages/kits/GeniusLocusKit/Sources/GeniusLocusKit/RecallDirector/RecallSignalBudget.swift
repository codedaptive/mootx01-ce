/// The per-column weight budget the unionBest `.matrixAware` weighted score
/// (RecallDirector step 9) applies AFTER `signal:*` exclusion and
/// redistribution.
///
/// `RecallWeights.adaptive` hands step 9 a budget per scoring column. Before
/// COL-1 a column that carried no signal still consumed its budget: the term
/// evaluated to `weight × 0`, and the mass the optimizer had assigned to it was
/// silently lost. Because the agreement bonus and the pinned bonus are FIXED
/// magnitudes (0.05) outside the normalised budget, every lost slice of budget
/// made those two constants relatively heavier. This type makes the loss
/// explicit and closes it: an EXCLUDED column drops out of the budget and the
/// budget it held is redistributed proportionally over the columns that
/// remain, so the included columns always sum to the same total the optimizer
/// assigned. The factor the included columns grew by is exposed as
/// `redistribution`: step 10 scales the MMR similarity term by it, so column
/// exclusion changes the score's magnitude but never the relevance-versus-
/// diversity balance the MMR admits candidates on (COL-2).
///
/// ## Column keys (`RecallShape` lane keys, namespace `signal:`)
///
/// Every weighted column of step 9 has one key; a key steers the WHOLE column
/// (both halves of a shared budget):
///
///   - `signal:locus`      — `weights.locus` × the locus column.
///   - `signal:bm25`       — `weights.bm25` × the BM25 column.
///   - `signal:vector`     — `weights.vector`, shared half/half by the Hamming
///                           column and the dense float column.
///   - `signal:fieldFit`   — `weights.fieldFit` × the field-fit column.
///   - `signal:matrix`     — `weights.matrix`, shared half/half by the
///                           coOccurrence and temporal columns.
///   - `signal:graph`      — `weights.graph` × the graph column.
///   - `signal:preference` — the preference column, which draws the SAME
///                           `weights.graph` slice as graph (RecallWeights has
///                           no preference field; the two cold-path signals
///                           share one budget, as step 9 always did).
///   - `signal:agreement`  — the fixed signal-agreement bonus. It has no slice
///                           in `RecallWeights`, so excluding it removes the
///                           bonus and redistributes nothing.
///
/// ## Semantics of a `signal:*` weight `s`
///
///   - key absent, or `s == 1.0` — NEUTRAL. The column keeps its adaptive
///     budget exactly. With every key neutral and no absent column the
///     resolved budget is BYTE-IDENTICAL to `RecallWeights` (the back-compat
///     contract: `total / total` is exactly 1.0 in IEEE arithmetic and
///     `1.0 × w × 1.0` is exactly `w`).
///   - `s == 0` — EXCLUDE. The column's budget is removed from the included
///     total and the remaining included columns are scaled by
///     `total / includedTotal` so they still sum to `total`.
///   - `s < 0`  — SUPPRESS. The column's contribution is SUBTRACTED (the same
///     demotion semantics the per-lane keys carry). A suppressed column stays
///     IN the included total; suppression never triggers redistribution.
///   - any other `s > 0` — SCALE. The column's budget is multiplied by `s`.
///     Scaling never triggers redistribution either; only exclusion does.
///
/// The per-lane keys that predate this namespace (`locus`, `bm25`, `hamming`,
/// `dense`, `fieldFit`, `coOccurrence`, `temporal`, `graph`, `preference`)
/// keep their contract unchanged: they scale a column's term WITHOUT
/// redistribution and compose multiplicatively on top of this budget.
///
/// ## Absent columns (COL-1 automatic rule)
///
/// `absentColumns` names columns whose signal store is empty for this
/// recall: no MatrixTier rows behind fieldFit/coOccurrence/temporal, no graph
/// cache entry for any candidate, no preference mark for any candidate. An
/// absent column is excluded exactly as `s == 0` is, without any shape
/// having asked for it. The director decides absence; this type only applies
/// it, so the arithmetic stays a pure function the conformance vectors can
/// pin on both ports.
struct RecallSignalBudget: Equatable, Sendable {

    /// The eight steerable columns, in the fixed order the budget sums them.
    /// The order is load-bearing for cross-port byte-identity: both ports sum
    /// `total` and `includedTotal` in this exact order.
    enum Column: String, CaseIterable, Sendable {
        case locus, bm25, vector, fieldFit, matrix, graph, preference, agreement

        /// The `RecallShape` lane key that steers this column.
        var laneKey: String { "signal:\(rawValue)" }
    }

    /// The lane-key prefix every column key carries.
    static let keyPrefix = "signal:"

    /// Effective budget for the locus column.
    var locus: Float
    /// Effective budget for the BM25 column.
    var bm25: Float
    /// Effective budget shared by the Hamming and dense columns (each takes half).
    var vector: Float
    /// Effective budget for the field-fit column.
    var fieldFit: Float
    /// Effective budget shared by the coOccurrence and temporal columns (each takes half).
    var matrix: Float
    /// Effective budget for the graph column.
    var graph: Float
    /// Effective budget for the preference column (drawn from `weights.graph`).
    var preference: Float
    /// Multiplier on the fixed signal-agreement bonus: `1.0` neutral, `0` excluded,
    /// otherwise the caller's signed scale.
    var agreement: Float

    /// The redistribution factor ρ = `total / includedTotal` every included
    /// column's budget was multiplied by: exactly 1.0 when no column is
    /// excluded (and in the all-excluded case, where nothing was scaled),
    /// greater than 1.0 otherwise. RecallDirector step 10 multiplies the MMR
    /// similarity term by ρ so the diversity penalty keeps its pre-exclusion
    /// weight against a relevance score that redistribution grew by ρ (COL-2:
    /// unscaled, ρ = 2.67 on the MMR-2 fixture admitted two near-duplicates of
    /// the query into a three-hit result).
    var redistribution: Float

    /// Whether the column is excluded (budget zero by exclusion or absence),
    /// used by the director to decide which columns the explainer reports as
    /// dropped. Scaled and suppressed columns are NOT excluded.
    var excluded: Set<Column>

    /// Resolve the effective per-column budget.
    ///
    /// - Parameters:
    ///   - weights: the adaptive weights step 8 produced.
    ///   - signalWeight: the resolver for a `signal:*` lane key (shape-explicit,
    ///     else provisioned, else `1.0`). It is the same closure step 9 uses for
    ///     the per-lane keys, so precedence is identical.
    ///   - absentColumns: columns the director found empty for this recall.
    /// - Returns: the resolved budget; byte-identical to `weights` when every key
    ///   is neutral and `absentColumns` is empty.
    static func resolve(
        weights: RecallWeights,
        signalWeight: (String) -> Float,
        absentColumns: Set<Column>
    ) -> RecallSignalBudget {
        // Adaptive budget per column, in summation order. Preference draws the
        // graph slice — the shared-budget rule step 9 has always applied.
        let base: [(Column, Float)] = [
            (.locus, weights.locus),
            (.bm25, weights.bm25),
            (.vector, weights.vector),
            (.fieldFit, weights.fieldFit),
            (.matrix, weights.matrix),
            (.graph, weights.graph),
            (.preference, weights.graph),
        ]
        var excluded: Set<Column> = []
        var total: Float = 0
        var includedTotal: Float = 0
        var signed: [Column: Float] = [:]
        for (column, w) in base {
            let s = signalWeight(column.laneKey)
            total += w
            if s == 0 || absentColumns.contains(column) {
                excluded.insert(column)
                signed[column] = 0
            } else {
                includedTotal += w
                signed[column] = s
            }
        }
        // Redistribution factor. `total / includedTotal` is exactly 1.0 when
        // nothing is excluded (IEEE: x / x == 1.0 for finite non-zero x). When
        // EVERY budgeted column is excluded there is nothing to redistribute
        // to; the factor is 1.0 and every column reads 0.
        let factor: Float = includedTotal > 0 ? total / includedTotal : 1.0
        func effective(_ column: Column, _ w: Float) -> Float {
            excluded.contains(column) ? 0 : (signed[column] ?? 1.0) * w * factor
        }
        // Agreement has no adaptive slice: its weight is the signed scale itself.
        let agreementScale = absentColumns.contains(.agreement) ? 0 : signalWeight(Column.agreement.laneKey)
        if agreementScale == 0 { excluded.insert(.agreement) }
        return RecallSignalBudget(
            locus: effective(.locus, weights.locus),
            bm25: effective(.bm25, weights.bm25),
            vector: effective(.vector, weights.vector),
            fieldFit: effective(.fieldFit, weights.fieldFit),
            matrix: effective(.matrix, weights.matrix),
            graph: effective(.graph, weights.graph),
            preference: effective(.preference, weights.graph),
            agreement: agreementScale,
            redistribution: factor,
            excluded: excluded
        )
    }
}
