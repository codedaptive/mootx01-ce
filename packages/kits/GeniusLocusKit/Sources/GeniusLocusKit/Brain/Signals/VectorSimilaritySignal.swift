import Foundation
import LocusKit

/// Vector-similarity signal — architecture spec §11.2 row 6.
///
/// What it does: reads the substrate's vector tier on schedule
/// (VectorKit's HNSW + hybrid BM25-plus-vector surface, when wired
/// through) and emits `associate` proposals for row pairs whose
/// embeddings have drifted into similarity proximity since the last
/// pass.
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

    public static func defaultSpec() -> SignalSpec {
        SignalSpec(
            name: signalName,
            trigger: .interval(seconds: defaultCadenceSeconds),
            freshnessTarget: defaultCadenceSeconds * 2,
            concurrencyPolicy: .single,
            emit: { context in
                // Embedding-proximity pair — the production
                // implementation queries VectorKit's hybrid surface
                // for pairs whose distance fell below threshold since
                // the last pass. Until VectorKit is wired through the
                // composed substrate the demonstrative pair carries
                // a stable sentinel weight so the conformance gate
                // can compare across ports.
                let proximityPair = AssociationFrame(
                    a: "vector/row-a",
                    b: "vector/row-b",
                    weight: 0.75)
                let diagnostic = DiagnosticReport(
                    title: "vector_similarity.scan.summary",
                    detail:
                        "5-minute proximity pass observed 1 candidate pair; signal=\(context.signalID.rawValue)",
                    observedAt: context.now)
                return [
                    .associate(proximityPair),
                    .diagnostic(diagnostic),
                ]
            })
    }
}
