import Foundation
import LocusKit
import VectorKit

/// Vector-similarity signal — architecture spec §11.2 row 6.
///
/// What it does: reads the estate's VectorStore on schedule, finds row
/// pairs whose embeddings have drifted into similarity proximity since
/// the last pass, and emits `associate` proposals for each candidate pair.
///
/// How pairs are found: the emit closure scans up to 50 stored drawer
/// IDs via `VectorStore.findByKeyword("", limit:)`, retrieves each row's
/// engram via `getVector(drawerID:modelID:)`, and calls
/// `VectorStore.findNearest(probe:modelID:limit:)` to locate nearby
/// vectors. Pairs within `proximityThreshold` Hamming distance (default
/// 64 — 25% of 256 bits) are deduplicated and emitted as
/// `AssociationFrame` values with weight = 1 − (distance / 256).
///
/// Routing: every emission goes through the `associate` verb at the
/// GLK-02 boundary. The verb adds the weight delta to the association
/// edge and records the provenance bit `vector_similarity` per
/// architecture spec §2.5 / cookbook §2.5 (provenance bitmap
/// amendments — bit 3 vector_similarity).
///
/// Cadence: every five minutes — matches the cookbook §15.2 bucket-
/// boundary work that the dreaming daemon's hot-path Rule 4 runs at,
/// so vector similarity stays fresh on the same cadence as ambient
/// fingerprint maintenance.
public enum VectorSimilaritySignal {

    /// Default cadence in seconds (300 = 5 minutes). Cookbook §15.2.
    public static let defaultCadenceSeconds: TimeInterval = 300

    /// Stable name surfaced in `SignalReport.name`.
    public static let signalName = "vector-similarity"

    /// Maximum Hamming distance (0-256) for a pair to qualify as a
    /// proximity candidate. 64 = 25% of 256 bits — empirically
    /// separates meaningful semantic similarity from noise at the
    /// SimHash scale used by this substrate.
    public static let defaultProximityThreshold: Int = 64

    /// Maximum drawer IDs sampled per pass from the VectorStore.
    /// Bounded to keep each 5-minute fire O(N·K) in the number of
    /// stored vectors rather than quadratic: 50 probes × 5 neighbours
    /// = 250 distance comparisons per pass.
    private static let maxProbeCount = 50

    /// Neighbours requested per probe via findNearest. Small limit keeps
    /// the scan bounded; the signal's goal is proximity detection, not
    /// exhaustive ranking.
    private static let neighboursPerProbe = 5

    /// Build the VectorSimilaritySignal spec for production use.
    ///
    /// The VectorStore is captured by the emit closure and queried via
    /// `findByKeyword` + `getVector` + `findNearest` on each five-minute
    /// pass. When the store is empty (e.g. during tests that have not
    /// filed any vectors) the pass produces zero candidate pairs and
    /// emits only a summary diagnostic.
    ///
    /// - Parameters:
    ///   - vectorStore: The estate's `VectorStore`. Caller opens the
    ///     VectorStore schema before passing. The store's lifecycle is
    ///     owned by the caller.
    ///   - modelID: The embedding model whose stored vectors are scanned.
    ///     Must match the `modelID` used when filing embeddings via
    ///     `VectorStore.addVector`.
    ///   - proximityThreshold: Maximum Hamming distance (0-256) for a
    ///     pair to qualify as an association candidate. Default 64.
    public static func spec(
        vectorStore: VectorStore,
        modelID: String,
        proximityThreshold: Int = defaultProximityThreshold
    ) -> SignalSpec {
        SignalSpec(
            name: signalName,
            trigger: .interval(seconds: defaultCadenceSeconds),
            freshnessTarget: defaultCadenceSeconds * 2,
            concurrencyPolicy: .single,
            emit: { context in
                await proximityPass(
                    vectorStore: vectorStore,
                    modelID: modelID,
                    proximityThreshold: proximityThreshold,
                    context: context)
            })
    }

    // MARK: - Proximity pass

    /// Execute one proximity scan pass: sample probe drawer IDs, find
    /// nearby neighbours, deduplicate pairs, emit AssociateFrames.
    private static func proximityPass(
        vectorStore: VectorStore,
        modelID: String,
        proximityThreshold: Int,
        context: SignalContext
    ) async -> [SignalEmission] {
        var emissions: [SignalEmission] = []

        // Sample candidate drawer IDs. An empty-string keyword query
        // matches all rows (LIKE '%%' = all strings), returning up to
        // maxProbeCount drawer IDs ordered by drawer_id ascending.
        let drawerIDs: [String]
        do {
            drawerIDs = try await vectorStore.findByKeyword("", limit: maxProbeCount)
        } catch {
            emissions.append(.diagnostic(DiagnosticReport(
                title: "vector_similarity.scan.summary",
                detail: "probe-source scan failed: \(error); signal=\(context.signalID.rawValue)",
                observedAt: context.now)))
            return emissions
        }

        var candidatePairs: [(a: String, b: String, weight: Double)] = []
        // Track seen pairs as sorted (smaller, larger) string tuples
        // to deduplicate (A,B) vs (B,A) from symmetric findNearest results.
        var seenPairs: Set<String> = []

        for drawerID in drawerIDs {
            // getVector returns Engram? — try? flattens to Engram? in Swift 5.7+,
            // so guard let gives Engram (non-optional). Skip rows with no vector.
            guard let probeEngram = try? await vectorStore.getVector(
                drawerID: drawerID, modelID: modelID) else { continue }

            let matches: [VectorMatch]
            do {
                matches = try await vectorStore.findNearest(
                    probe: probeEngram,
                    modelID: modelID,
                    limit: neighboursPerProbe)
            } catch {
                continue
            }

            for match in matches {
                guard match.drawerID != drawerID else { continue }
                guard match.distance <= proximityThreshold else { continue }

                // Canonical pair key: lexicographically smaller ID first
                // so (A,B) and (B,A) map to the same set element.
                let pairKey = drawerID < match.drawerID
                    ? "\(drawerID)||\(match.drawerID)"
                    : "\(match.drawerID)||\(drawerID)"

                guard seenPairs.insert(pairKey).inserted else { continue }

                // Weight is inverse-proportional to Hamming distance:
                // distance=0 → weight=1.0 (identical), distance=256 → weight=0.0.
                let weight = 1.0 - Double(match.distance) / 256.0
                candidatePairs.append(
                    (a: min(drawerID, match.drawerID),
                     b: max(drawerID, match.drawerID),
                     weight: weight))
            }
        }

        for pair in candidatePairs {
            emissions.append(.associate(AssociationFrame(
                a: pair.a,
                b: pair.b,
                weight: pair.weight)))
        }

        emissions.append(.diagnostic(DiagnosticReport(
            title: "vector_similarity.scan.summary",
            detail: "5-minute proximity pass found \(candidatePairs.count) candidate pair(s); signal=\(context.signalID.rawValue)",
            observedAt: context.now)))

        return emissions
    }
}
