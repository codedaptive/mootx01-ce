import Foundation
import LocusKit
import VectorKit
import CorpusKit

/// Vector-similarity signal — architecture spec §11.2 row 6.
///
/// What it does: reads the estate's VectorStore on schedule, finds row
/// pairs whose embeddings have drifted into similarity proximity since
/// the last pass, and emits `associate` proposals for each candidate pair.
///
/// How pairs are found: the emit closure samples the 50 most recently
/// filed item IDs via `VectorStore.recentItemIDs(limit:)`, retrieves each
/// row's engram via `getVector(itemID:modelID:)`, and calls
/// `VectorStore.findNearest(probe:modelID:limit:)` to locate nearby
/// vectors. Pairs within `proximityThreshold` Hamming distance (default
/// 64 — 25% of 256 bits) are deduplicated and emitted as
/// `AssociationFrame` values with weight = 1 − (distance / 256).
///
/// TWO row populations are mined (same lane split as the contradiction
/// hunter): drawer-keyed rows under the caller's `modelID` (bespoke
/// lanes and test-planted vectors), and — when a `Corpus` is supplied —
/// chunk-keyed rows under the corpus's own modelID, which is the ONLY
/// lane production estates populate (EstateLifecycle registers
/// `corpus.sharedVectorStore`; the encode drain keys every row by chunk
/// UUID). Chunk hits map back to their owning drawers via
/// `Corpus.sourceIDs(forChunkIDs:)`; same-drawer chunk pairs collapse,
/// and both lanes deduplicate together on drawer-pair keys, so every
/// emitted `AssociationFrame` carries DRAWER ids.
///
/// Routing: every emission goes through the `associate` verb at the
/// GLK-02 boundary, which records the provenance bit `vector_similarity`
/// per architecture spec §2.5 / cookbook §2.5 (provenance bitmap
/// amendments — bit 3 vector_similarity).
///
/// ADMIN — weight is the entrance gate. It is derived FREE from the
/// already-computed proximity-gate Hamming distance (no extra origin-side
/// work to obtain it), and carried on the `AssociationFrame`. But it is
/// VESTIGIAL past the `associate` verb: the association row has no weight
/// column, so the verb accepts and discards it (see `Verbs.associate`,
/// the drop site). The value is computed and plumbed on purpose — a
/// pre-2.0 gauntlet experiment will test whether feeding weight into
/// recall improves results; until that runs, it is honestly carried and
/// dropped, never persisted and never silently fabricated.
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
    /// `recentItemIDs` + `getVector` + `findNearest` on each five-minute
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
    ///     `VectorStore.addVector(itemID:engram:modelID:modelVersion:filedAt:)`.
    ///   - proximityThreshold: Maximum Hamming distance (0-256) for a
    ///     pair to qualify as an association candidate. Default 64.
    ///   - corpus: The estate's `Corpus`, when one is registered. Enables
    ///     the chunk-keyed corpus lane — the row population production
    ///     estates actually hold. `nil` (the default) scans only the
    ///     drawer-keyed `modelID` lane, which is correct for tests that
    ///     plant drawer-keyed vectors directly.
    public static func spec(
        vectorStore: VectorStore,
        modelID: String,
        proximityThreshold: Int = defaultProximityThreshold,
        corpus: Corpus? = nil
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
                    corpus: corpus,
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
        corpus: Corpus?,
        context: SignalContext
    ) async -> [SignalEmission] {
        var emissions: [SignalEmission] = []

        let itemIDs: [String]
        do {
            // Newest-first probe sample: the 50 most recently filed items.
            // New captures are what need association screening; the prior
            // ascending-item_id enumeration was a static UUID-ordered window
            // that new content rarely entered on a large estate.
            itemIDs = try await vectorStore.recentItemIDs(limit: maxProbeCount)
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
        // Both lanes below key on DRAWER ids, so they dedupe together.
        var seenPairs: Set<String> = []

        // Lane 1 — drawer-keyed rows under the caller's `modelID`. Rows
        // whose item is not in this lane fail `getVector` and fall through.
        for itemID in itemIDs {
            // getVector returns Engram? — try? flattens to Engram? in Swift 5.7+,
            // so guard let gives Engram (non-optional). Skip rows with no vector.
            guard let probeEngram = try? await vectorStore.getVector(
                itemID: itemID, modelID: modelID) else { continue }

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
                guard match.itemID != itemID else { continue }
                guard match.distance <= proximityThreshold else { continue }

                // Canonical pair key: lexicographically smaller ID first
                // so (A,B) and (B,A) map to the same set element.
                let pairKey = itemID < match.itemID
                    ? "\(itemID)||\(match.itemID)"
                    : "\(match.itemID)||\(itemID)"

                guard seenPairs.insert(pairKey).inserted else { continue }

                // Weight is inverse-proportional to Hamming distance:
                // distance=0 → weight=1.0 (identical), distance=256 → weight=0.0.
                let weight = 1.0 - Double(match.distance) / 256.0
                candidatePairs.append(
                    (a: min(itemID, match.itemID),
                     b: max(itemID, match.itemID),
                     weight: weight))
            }
        }

        // Lane 2 — chunk-keyed corpus rows. On a production estate this is
        // the ONLY populated lane: the encode drain keys every vector row by
        // chunk UUID under the corpus provider's modelID, so lane 1 finds
        // nothing there. Mine the same probe sample on the corpus lane and
        // map chunk hits back to their owning drawers (chunk → source_id via
        // the corpus's warm map). Chunk pairs from the SAME drawer collapse.
        // First hit wins per drawer pair — findNearest returns matches in
        // ascending distance, so the first hit for a pair is its closest
        // chunk evidence. Mirrors the contradiction hunter's lane split.
        if let corpus {
            let corpusModelID = await corpus.modelID
            var chunkMatches: [(a: String, b: String, weight: Double)] = []
            var involvedChunkIDs: Set<UUID> = []
            for itemID in itemIDs {
                guard let probeUUID = UUID(uuidString: itemID),
                      let probeEngram = try? await vectorStore.getVector(
                          itemID: itemID, modelID: corpusModelID) else { continue }
                guard let matches = try? await vectorStore.findNearest(
                    probe: probeEngram,
                    modelID: corpusModelID,
                    limit: neighboursPerProbe) else { continue }
                for match in matches {
                    guard match.itemID != itemID,
                          match.distance <= proximityThreshold,
                          let matchUUID = UUID(uuidString: match.itemID) else { continue }
                    involvedChunkIDs.insert(probeUUID)
                    involvedChunkIDs.insert(matchUUID)
                    chunkMatches.append(
                        (a: itemID, b: match.itemID,
                         weight: 1.0 - Double(match.distance) / 256.0))
                }
            }
            if !chunkMatches.isEmpty {
                let owners = await corpus.sourceIDs(forChunkIDs: Array(involvedChunkIDs))
                for match in chunkMatches {
                    guard let ua = UUID(uuidString: match.a),
                          let ub = UUID(uuidString: match.b),
                          let sourceA = owners[ua], let sourceB = owners[ub],
                          sourceA != sourceB else { continue }
                    let pairKey = sourceA < sourceB
                        ? "\(sourceA)||\(sourceB)"
                        : "\(sourceB)||\(sourceA)"
                    guard seenPairs.insert(pairKey).inserted else { continue }
                    candidatePairs.append(
                        (a: min(sourceA, sourceB),
                         b: max(sourceA, sourceB),
                         weight: match.weight))
                }
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
