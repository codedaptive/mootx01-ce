import Foundation
import LocusKit
import VectorKit
import CorpusKit

/// Async closure type for checking whether a persisted association already
/// exists between two drawer IDs (in either direction). Passed to
/// `VectorSimilaritySignal.spec` to suppress redundant frame emissions.
///
/// Returns `true` when an active (non-tombstoned) association edge exists
/// between `drawerIdA` and `drawerIdB` in either direction.
/// Returns `false` when no such edge exists (the pair is a new candidate).
/// Returns `false` on any error — fail-open so a transient query failure
/// does not permanently suppress a valid candidate pair.
///
/// Production callers wire `DrawerStore.hasAssociationBetweenDrawers`
/// here. Default (nil) disables the optimization; correctness is
/// preserved by the DB-level INSERT-OR-IGNORE in addAssociation (FINDING-3).
public typealias AssociationEdgeChecker =
    @Sendable (String, String) async -> Bool

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
    ///   - edgeChecker: Optional async closure that returns `true` when
    ///     a persisted (non-tombstoned) association already exists between
    ///     the two drawer IDs in either direction (FINDING-3 optimization).
    ///     When non-nil, the pass skips pairs that already have an edge,
    ///     avoiding redundant frame emissions every 300 seconds. Correctness
    ///     is preserved even when `nil` — the DB-level INSERT-OR-IGNORE in
    ///     `addAssociation` is the primary guard; this check reduces churn.
    public static func spec(
        vectorStore: VectorStore,
        modelID: String,
        proximityThreshold: Int = defaultProximityThreshold,
        corpus: CorpusContentEngine? = nil,
        edgeChecker: AssociationEdgeChecker? = nil
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
                    edgeChecker: edgeChecker,
                    context: context)
            })
    }

    // MARK: - Proximity pass

    /// Execute one proximity scan pass: sample probe drawer IDs, find
    /// nearby neighbours, deduplicate pairs, emit AssociateFrames.
    /// If `edgeChecker` is provided, pairs with a persisted association
    /// are filtered out before emission (FINDING-3 optimization).
    private static func proximityPass(
        vectorStore: VectorStore,
        modelID: String,
        proximityThreshold: Int,
        corpus: CorpusContentEngine?,
        edgeChecker: AssociationEdgeChecker?,
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

        // Lane 2 — the corpus provider's rows. Shared-content 1.1: the
        // engine keys every vector row by the DRAWER ID itself, so a hit's
        // itemID is the owning drawer directly — no chunk→drawer remap and
        // no same-drawer chunk collapse (one row per drawer per lane).
        // Mirrors the contradiction hunter's lane split.
        if let corpus {
            let corpusModelID = await corpus.modelID
            for itemID in itemIDs {
                guard let probeEngram = try? await vectorStore.getVector(
                    itemID: itemID, modelID: corpusModelID) else { continue }
                guard let matches = try? await vectorStore.findNearest(
                    probe: probeEngram,
                    modelID: corpusModelID,
                    limit: neighboursPerProbe) else { continue }
                for match in matches {
                    guard match.itemID != itemID,
                          match.distance <= proximityThreshold else { continue }
                    let sourceA = itemID
                    let sourceB = match.itemID
                    let pairKey = sourceA < sourceB
                        ? "\(sourceA)||\(sourceB)"
                        : "\(sourceB)||\(sourceA)"
                    guard seenPairs.insert(pairKey).inserted else { continue }
                    candidatePairs.append(
                        (a: min(sourceA, sourceB),
                         b: max(sourceA, sourceB),
                         weight: 1.0 - Double(match.distance) / 256.0))
                }
            }
        }

        // FINDING-3 optimization: filter out pairs that already have a
        // persisted association. The DB-level INSERT-OR-IGNORE in
        // `addAssociation` is the primary correctness guard; this check
        // reduces churn (frame construction, queue writes, verb dispatch)
        // for unchanged vector neighborhoods every 300 seconds.
        // edgeChecker is fail-open: a transient error returns false so
        // a valid new pair is never permanently suppressed.
        var emittablePairs = candidatePairs
        if let check = edgeChecker {
            var filtered: [(a: String, b: String, weight: Double)] = []
            for pair in candidatePairs {
                let alreadyPersisted = await check(pair.a, pair.b)
                if !alreadyPersisted {
                    filtered.append(pair)
                }
            }
            emittablePairs = filtered
        }

        for pair in emittablePairs {
            emissions.append(.associate(AssociationFrame(
                a: pair.a,
                b: pair.b,
                weight: pair.weight)))
        }

        emissions.append(.diagnostic(DiagnosticReport(
            title: "vector_similarity.scan.summary",
            detail: "5-minute proximity pass found \(candidatePairs.count) candidate pair(s), emitting \(emittablePairs.count); signal=\(context.signalID.rawValue)",
            observedAt: context.now)))

        return emissions
    }
}
