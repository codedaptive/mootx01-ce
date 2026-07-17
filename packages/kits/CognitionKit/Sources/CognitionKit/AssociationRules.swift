// AssociationRules.swift
//
// AssociationRules — the conscious "what co-occurs with what" recipe (Analytics).
// Recalls a set of drawers, projects each drawer's categorical facets (room,
// kind, channel, sensitivity) into a per-call label vocabulary, builds the
// co-occurrence matrix O from the recalled set, and surfaces SubstrateML's
// pairwise association-rule mining.
//
// Layer discipline (SPEC § 5, B-1/B-2, I-1/I-2): the recipe only SEQUENCES.
//   - Estate read: one `GLK.recall` call (per I-2, reaches the estate only
//     through the passed handle and kit).
//   - Label projection: derive the substrate's categorical facets as
//     lowercase canonical strings (Swift case-name vocabulary, per § 4.2).
//   - MatrixO build: accumulate the co-occurrence using
//     `MatrixO.applyRow` (SubstrateTypes); no arithmetic in this file.
//   - Rule mining: one `mineAssociationRules` call — the engine owns all
//     metric computation; the recipe shapes inputs and relabels outputs.
// Capability gate: `.associationRuleMining` is verified before any estate
// touch (spec B-5, I-3).
//
// === Packed-item mapping (Part 2 design) ===
//
// `mineAssociationRules` addresses matrix cells as `Item(field:UInt8, value:UInt8)`
// where `field` and `value` must both be < 64 (6-bit constraint from SubstrateTypes
// MatrixO's `CooccurrenceKey`). The recipe uses a per-call sorted label→index
// table:
//
//   1. Collect the distinct string labels from all recalled drawers.
//      Each drawer contributes four labels of the form:
//        "kind:{caseName}", "channel:{caseName}", "sensitivity:{caseName}",
//        "room:{roomString}"
//      where `caseName` is the Swift enum case's own lowercase camelCase name —
//      the canonical substrate vocabulary (§ 4.2). Rooms are arbitrary strings.
//
//   2. Sort all distinct labels alphabetically and assign field index 0..N-1.
//      If N > 64, cap at 64 (discard labels with index >= 64); a warning is
//      recorded in the output. `value` is always 1 (presence item — each label
//      is a presence/absence feature for the drawer).
//
//   3. Build MatrixO: for each recalled drawer, call `applyRow(delta:1,
//      fieldValues:[(field, 1)])` with the indices of the drawer's labels.
//
//   4. Call `mineAssociationRules(matrix:activeRowCount:thresholds:)` where
//      `activeRowCount = drawerCount`. The engine returns `[AssociationRule]`
//      whose `antecedent.field` and `consequent.field` are label indices.
//
//   5. Relabel: map each `Item.field` back to the label string for the output.
//
// Overflow rule: if the sorted unique label count exceeds 64, only the first 64
// labels (by alphabetical sort order) are indexed; any drawer feature mapping
// to a label beyond index 63 is silently dropped for that row. This cannot
// panic (the precondition in MatrixO requires field < 64). The rule is
// deterministic within a call.
//
// Read-only (B-6): no write verb is issued.

import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import SubstrateML
import SubstrateTypes

// MARK: - Result type

/// One relabeled mined pairwise rule, with the five standard metrics.
/// The antecedent and consequent are the original string labels
/// (e.g. "room:study", "kind:prose") rather than the packed Item indices.
public struct AssociationRuleResult: Sendable, Equatable {
    /// The antecedent label string (e.g. "room:study").
    public let antecedent: String
    /// The consequent label string (e.g. "kind:prose").
    public let consequent: String
    public let support: Double
    public let confidence: Double
    public let lift: Double
    public let conviction: Double
    public let leverage: Double

    public init(
        antecedent: String, consequent: String,
        support: Double, confidence: Double,
        lift: Double, conviction: Double, leverage: Double
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

// MARK: - Recipe

/// Pairwise association-rule mining over a recalled drawer set.
public struct AssociationRules: Recipe {

    public struct Input: Sendable {
        /// The estate recall frame.
        public let frame: RecallFrame
        /// Minimum-metric gates for rule emission.
        public let thresholds: MiningThresholds

        public init(frame: RecallFrame, thresholds: MiningThresholds) {
            self.frame = frame
            self.thresholds = thresholds
        }
    }

    public struct Output: Sendable {
        /// Mined rules with string-relabeled antecedents and consequents,
        /// in ascending packed `(antecedent, consequent)` label-index order
        /// (deterministic within a call).
        public let rules: [AssociationRuleResult]
        /// Number of drawers the matrix was built from.
        public let drawerCount: Int
        /// True if the unique label count exceeded 64 and was capped.
        /// Labels with index >= 64 (sorted order) were silently dropped.
        public let labelOverflow: Bool

        public init(rules: [AssociationRuleResult], drawerCount: Int, labelOverflow: Bool) {
            self.rules = rules
            self.drawerCount = drawerCount
            self.labelOverflow = labelOverflow
        }
    }

    public init() {}

    public let name = "association_rules"
    public let version = "1.0.0"
    public let description =
        "Recall a frame, project each drawer's categorical facets into a co-occurrence matrix, and mine pairwise association rules."

    /// Requires the `associationRuleMining` capability gate (spec I-3).
    /// The engine itself (`mineAssociationRules`) lives in SubstrateML.
    public let requiredCapabilities: [NeuronKitCapability] = [.associationRuleMining]

    public func run(
        input: Input,
        estate: EstateHandle,
        kit: GeniusLocusKit
    ) async throws -> Output {
        // B-5: verify capabilities before any substrate touch.
        try verifyCapabilities(required: requiredCapabilities)

        // 1. Recall drawers via the GLK recall verb (I-2: no direct substrate).
        let drawers = try await kit.recall(estate, input.frame)
        let drawerCount = drawers.count

        guard drawerCount > 0 else {
            return Output(rules: [], drawerCount: 0, labelOverflow: false)
        }

        // 2. Build the per-call label vocabulary.
        // Each label is a "axis:caseName" string using the substrate's
        // canonical lowercase camelCase vocabulary (§ 4.2).
        let (labels, labelOverflow) = buildLabelTable(from: drawers)

        // 3. Build MatrixO from the recalled set.
        var matrix = MatrixO()
        let maxLabel = UInt8(labels.count - 1)
        for drawer in drawers {
            let fieldValues = drawerFieldValues(drawer, labels: labels, maxIndex: maxLabel)
            matrix.applyRow(delta: 1, fieldValues: fieldValues)
        }

        // 4. Mine association rules (engine owns all metric computation).
        let rawRules = mineAssociationRules(
            matrix: matrix,
            activeRowCount: Int64(drawerCount),
            thresholds: input.thresholds)

        // 5. Relabel the engine's Item indices back to label strings.
        let results: [AssociationRuleResult] = rawRules.compactMap { rule in
            let ai = Int(rule.antecedent.field)
            let ci = Int(rule.consequent.field)
            guard ai < labels.count, ci < labels.count else { return nil }
            return AssociationRuleResult(
                antecedent: labels[ai],
                consequent: labels[ci],
                support: rule.support,
                confidence: rule.confidence,
                lift: rule.lift,
                conviction: rule.conviction,
                leverage: rule.leverage)
        }

        return Output(rules: results, drawerCount: drawerCount, labelOverflow: labelOverflow)
    }
}

// MARK: - Apriori recipe

/// Multi-antecedent association-rule mining over the estate's audit log.
///
/// Delegates entirely to `GeniusLocusKit.mineAprioriRules(estate:thresholds:)`.
/// No label projection is needed: the engine works on raw `(field, value)` items
/// derived from the `RowAttributeView` of the audit log.
///
/// The recipe's output preserves the engine's `AprioriRule` values verbatim so
/// callers can inspect all five metrics and the full multi-item antecedent list.
public struct AprioriRules: Recipe {

    public struct Input: Sendable {
        /// Apriori threshold gates: minSupport, minConfidence, minLift, maxK.
        public let thresholds: AprioriThresholds

        public init(thresholds: AprioriThresholds) {
            self.thresholds = thresholds
        }
    }

    public struct Output: Sendable {
        /// Mined rules sorted by lift DESC, confidence DESC, evidenceCount DESC.
        public let rules: [AprioriRule]

        public init(rules: [AprioriRule]) {
            self.rules = rules
        }
    }

    public init() {}

    public let name = "apriori_rules"
    public let version = "1.0.0"
    public let description =
        "Read the estate's audit log and mine multi-antecedent association rules via the Apriori algorithm."

    /// Requires the `associationRuleMining` capability gate (spec I-3).
    public let requiredCapabilities: [NeuronKitCapability] = [.associationRuleMining]

    public func run(
        input: Input,
        estate: EstateHandle,
        kit: GeniusLocusKit
    ) async throws -> Output {
        // B-5: verify capabilities before any substrate touch.
        try verifyCapabilities(required: requiredCapabilities)

        // Delegate to GeniusLocusKit: refresh audit log, build RowAttributeView
        // rows, run AprioriMining. No math duplicated here.
        let rules = try await kit.mineAprioriRules(estate: estate,
                                                   thresholds: input.thresholds)
        return Output(rules: rules)
    }
}

// MARK: - Label-table helpers

/// Canonical lowercase string for a `ContentKind` case.
/// Uses the Swift case name, which is the substrate vocabulary per § 4.2.
private func contentKindLabel(_ kind: ContentKind) -> String {
    switch kind {
    case .prose:          return "kind:prose"
    case .code:           return "kind:code"
    case .transcript:     return "kind:transcript"
    case .list:           return "kind:list"
    case .structuredJSON: return "kind:structuredJSON"
    case .imageCaption:   return "kind:imageCaption"
    case .fingerprintOnly: return "kind:fingerprintOnly"
    case .dataset:         return "kind:dataset"
    }
}

/// Canonical lowercase string for a `CaptureChannel` case.
private func captureChannelLabel(_ channel: CaptureChannel) -> String {
    switch channel {
    case .typed:        return "channel:typed"
    case .voiced:       return "channel:voiced"
    case .ocr:          return "channel:ocr"
    case .importedFile: return "channel:importedFile"
    case .sensor:       return "channel:sensor"
    case .actuator:     return "channel:actuator"
    }
}

/// Canonical lowercase string for an `AdjectiveSensitivity` case.
private func sensitivityLabel(_ sensitivity: AdjectiveSensitivity) -> String {
    switch sensitivity {
    case .normal:     return "sensitivity:normal"
    case .elevated:   return "sensitivity:elevated"
    case .restricted: return "sensitivity:restricted"
    case .secret:     return "sensitivity:secret"
    }
}

/// The four categorical label strings for a single recalled drawer.
private func drawerLabels(_ drawer: Drawer) -> [String] {
    [
        contentKindLabel(drawer.contentKind),
        captureChannelLabel(drawer.captureChannel),
        sensitivityLabel(drawer.adjectiveSensitivity),
        "room:\(drawer.parentNodeId)",
    ]
}

/// Capacity constant: MatrixO requires field < 64 (6-bit field index).
private let maxFieldCount = 64

/// Build a sorted, deduplicated label array from the recalled drawer set.
/// Returns the label array (up to `maxFieldCount` entries) and whether
/// the distinct-label count exceeded the cap.
private func buildLabelTable(from drawers: [Drawer]) -> ([String], Bool) {
    var seen = Set<String>()
    for drawer in drawers {
        for label in drawerLabels(drawer) {
            seen.insert(label)
        }
    }
    let sorted = seen.sorted()
    let overflow = sorted.count > maxFieldCount
    let capped = overflow ? Array(sorted.prefix(maxFieldCount)) : sorted
    return (capped, overflow)
}

/// The `(field, value)` presence items for a drawer under the given label table.
/// Each label present in the drawer contributes one item with `field = labelIndex`
/// and `value = 1`. Labels absent from the table (overflow) are silently dropped.
private func drawerFieldValues(
    _ drawer: Drawer,
    labels: [String],
    maxIndex: UInt8
) -> [(field: UInt8, value: UInt8)] {
    // Build a fast lookup: label → field index.
    // This is a small array (≤ 64 entries), so linear scan is fine.
    let drawerLabelSet = drawerLabels(drawer)
    var result: [(field: UInt8, value: UInt8)] = []
    result.reserveCapacity(drawerLabelSet.count)
    for label in drawerLabelSet {
        if let idx = labels.firstIndex(of: label) {
            let field = UInt8(idx) // idx < maxFieldCount ≤ 64; safe cast
            result.append((field: field, value: 1))
        }
    }
    return result
}
