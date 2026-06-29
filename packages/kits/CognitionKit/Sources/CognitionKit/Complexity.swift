import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit

/// Complexity recipe output: Shannon entropy (and optional mutual information)
/// over the distribution of one or two label fields in the recalled set, plus
/// the total drawer count.
public struct ComplexityOutput: Sendable, Equatable {
    /// Entropy and mutual-information result from the Complexity lens.
    public let result: ComplexityResult
    /// Total drawers in the recalled set.
    public let totalCount: Int

    public init(result: ComplexityResult, totalCount: Int) {
        self.result = result
        self.totalCount = totalCount
    }
}

/// Complexity — Shannon entropy recipe (Lens 4, Topics).
///
/// Recalls a set of drawers via the estate handle, derives the count
/// distribution of one or two label fields across the recalled set
/// (following the same recall-and-group pattern as the Drift recipe), and
/// surfaces the Complexity lens to measure how uniform or concentrated the
/// estate's filing is. "How spread out are memories across rooms, and is
/// there redundancy between how I file by room vs by wing?"
///
/// Supported field names: `"room"`, `"wing"`, `"addedBy"`,
/// `"embeddingModelID"`. Both `"room"` and `"wing"` map to
/// `drawer.parentNodeId` (the same field); they are aliases, not
/// distinct dimensions. An unrecognised name maps all drawers to the key
/// `"_unknown"` (B-8 total-over-edge-input posture — the recipe never throws
/// on an invalid label).
///
/// Layer discipline (SPEC § 5, B-1/B-2): pure sequencing — recall via GLK +
/// NeuronKit `complexity`. Read-only (B-6, I-6). No write verb. The `now`
/// parameter is accepted for signature parity but is not read by this recipe.
///
/// Rust peer: `run_complexity` in `complexity_recipe.rs`. Shares the same
/// field-extraction and joint-matrix logic operating on the recalled drawer
/// rows.
public enum Complexity {

    /// Recall drawers, build their field-value distributions, and surface the
    /// Complexity lens.
    ///
    /// An empty recalled set yields entropy 0.0 (B-8).
    ///
    /// - Parameters:
    ///   - kit: Open GeniusLocusKit instance.
    ///   - handle: Open estate handle.
    ///   - frame: Recall frame controlling which drawers are fetched.
    ///   - fieldA: Name of the first label field. Supported values: `"room"`,
    ///     `"wing"`, `"addedBy"`, `"embeddingModelID"`.
    ///   - fieldB: Optional second label field; when non-nil, mutual
    ///     information between fieldA and fieldB is also computed.
    ///   - now: Current clock tick for determinism (I-6).
    public static func run(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        frame: LocusKit.RecallFrame,
        fieldA: String,
        fieldB: String? = nil,
        now: Date
    ) async throws -> ComplexityOutput {
        let drawers = try await kit.recall(handle, frame)
        let totalCount = drawers.count

        let (countsA, keysA) = distribution(from: drawers, field: fieldA)

        var countsB: [Float32]? = nil
        var joint: [[Float32]]? = nil
        if let fb = fieldB {
            let (cB, keysB) = distribution(from: drawers, field: fb)
            countsB = cB
            // Joint matrix [|keysA|][|keysB|]: joint[i][j] counts drawers
            // where fieldA=keysA[i] AND fieldB=keysB[j]. Sorted-key bins
            // are deterministic (same discipline as the Drift recipe's sorted
            // vocabulary).
            joint = jointMatrix(
                from: drawers, keysA: keysA, keysB: keysB,
                fieldA: fieldA, fieldB: fb)
        }

        let result = NeuronKit.complexity(
            countsA: countsA,
            countsB: countsB,
            joint: joint)

        return ComplexityOutput(result: result, totalCount: totalCount)
    }

    // MARK: - Private helpers

    /// Extract a label-field string value from a drawer.
    ///
    /// Supported field names: "room", "wing", "addedBy", "embeddingModelID".
    /// "room" and "wing" both return `parentNodeId` — the UUID of the parent
    /// room node. Display-name resolution is the caller's responsibility via
    /// `Estate.resolveNodeNames(parentNodeIds:)`.
    /// Any unrecognised name returns "_unknown" so the recipe never throws on
    /// an invalid label (B-8 total-over-edge-input posture).
    private static func fieldValue(_ drawer: Drawer, field: String) -> String {
        switch field {
        case "room":             return drawer.parentNodeId
        case "wing":             return drawer.parentNodeId
        case "addedBy":          return drawer.addedBy
        case "embeddingModelID": return drawer.embeddingModelID
        default:                 return "_unknown"
        }
    }

    /// Build a sorted count distribution for `field` over `drawers`.
    ///
    /// Returns `(counts, keys)` where `keys` is sorted so bin order is
    /// deterministic — matching the sorted-vocabulary discipline in Drift.
    private static func distribution(
        from drawers: [Drawer],
        field: String
    ) -> ([Float32], [String]) {
        var freq: [String: Int] = [:]
        for d in drawers {
            freq[fieldValue(d, field: field), default: 0] += 1
        }
        let keys = freq.keys.sorted()
        return (keys.map { Float32(freq[$0]!) }, keys)
    }

    /// Build a joint count matrix for mutual information.
    ///
    /// `joint[i][j]` is the count of drawers where `fieldA == keysA[i]` and
    /// `fieldB == keysB[j]`.
    private static func jointMatrix(
        from drawers: [Drawer],
        keysA: [String],
        keysB: [String],
        fieldA: String,
        fieldB: String
    ) -> [[Float32]] {
        let idxA = Dictionary(uniqueKeysWithValues: keysA.enumerated().map { ($1, $0) })
        let idxB = Dictionary(uniqueKeysWithValues: keysB.enumerated().map { ($1, $0) })
        var matrix = [[Float32]](
            repeating: [Float32](repeating: 0, count: keysB.count),
            count: keysA.count)
        for d in drawers {
            let va = fieldValue(d, field: fieldA)
            let vb = fieldValue(d, field: fieldB)
            if let ia = idxA[va], let ib = idxB[vb] {
                matrix[ia][ib] += 1
            }
        }
        return matrix
    }
}
