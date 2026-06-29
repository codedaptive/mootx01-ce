import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit

/// LatentThemesLens — the conscious "what you're actually about" recipe
/// (Lens 2, Topics). Recalls a set of drawers, builds the co-occurrence
/// of their metadata field-values, and factors it (NeuronKit
/// `latentThemes` → MatrixNMF) into soft latent themes — the emergent
/// topics in how the estate is filed, with mixed membership.
///
/// The recipe entry point is `LatentThemesLens` (the result type
/// `LatentThemes` is the bare NeuronKit type; the recipe namespace is
/// suffixed to avoid shadowing it, per the lens naming convention).
///
/// Layer discipline (SPEC § 5, B-1/B-2): the recipe SEQUENCES — recall
/// via GLK, factor via NeuronKit. Read-only; no capability gate (a
/// structural read + a reasoning surface, not a declared
/// `NeuronKitCapability` function).
///
/// Co-occurrence model: within each recalled drawer, its field-value
/// labels (`room:`, `kind:`, `channel:`, `sensitivity:`) all co-occur —
/// the same field-value co-occurrence the matrix tier accumulates from
/// the audit log, built here directly from the recalled set so the
/// recipe stays a pure sequence over the GLK recall verb. The label
/// tokens spell the Swift case names (`kind:prose`, `channel:typed`,
/// `sensitivity:normal`) — the canonical vocabulary both versions emit.
///
/// Swift version of `run_latent_themes`.
public enum LatentThemesLens {

    /// Fixed deterministic NMF seed so a given recalled set yields
    /// identical themes across runs (reproducible reasoning, per the
    /// determinism rule). Matches the Rust version. "LATENT01".
    private static let seed: UInt64 = 0x4C41_5445_4E54_3031

    /// The metadata field-value labels of a drawer — the tokens whose
    /// co-occurrence the lens factors. Sorted and deduplicated so the
    /// pair walk below is deterministic.
    private static func fieldValueLabels(_ drawer: Drawer) -> [String] {
        let labels = Set([
            "room:\(drawer.parentNodeId)",
            "kind:\(drawer.contentKind)",
            "channel:\(drawer.captureChannel)",
            "sensitivity:\(drawer.adjectiveSensitivity)",
        ])
        return labels.sorted()
    }

    /// Recall via `frame`, then factor the recalled set's metadata
    /// field-value co-occurrence into `k` soft latent themes. Read-only;
    /// a recall failure propagates.
    public static func run(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        frame: LocusKit.RecallFrame,
        k: Int
    ) async throws -> LatentThemes {
        let drawers = try await kit.recall(handle, frame)

        var labels = Set<String>()
        // Canonical (a < b) pair -> co-occurrence weight.
        var cooccurrence: [String: Double] = [:]
        var pairKeys: [String: (String, String)] = [:]
        for drawer in drawers {
            let fieldValues = fieldValueLabels(drawer)
            labels.formUnion(fieldValues)
            for i in fieldValues.indices {
                for j in fieldValues.indices.dropFirst(i + 1) {
                    let key = "\(fieldValues[i])\u{1F}\(fieldValues[j])"
                    cooccurrence[key, default: 0] += 1
                    pairKeys[key] = (fieldValues[i], fieldValues[j])
                }
            }
        }

        // Sorted labels and pair keys ⇒ a deterministic input order into
        // the factorization (same discipline as the Rust BTree walk).
        let labelVector = labels.sorted()
        let pairs = cooccurrence.keys.sorted().map { key in
            (labelA: pairKeys[key]!.0, labelB: pairKeys[key]!.1, weight: cooccurrence[key]!)
        }

        return NeuronKit.latentThemes(
            labels: labelVector, cooccurrence: pairs, k: k, seed: seed)
    }
}
