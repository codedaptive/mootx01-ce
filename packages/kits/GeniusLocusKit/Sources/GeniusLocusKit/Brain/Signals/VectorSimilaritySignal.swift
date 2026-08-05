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
/// How pairs are found: the emit closure samples up to `probeLimit` most
/// recently filed item IDs via `VectorStore.recentItemIDs(limit:)`,
/// retrieves each row's engram via `getVector(itemID:modelID:)`, and calls
/// `VectorStore.findNearest(probe:modelID:limit:)` to locate nearby
/// vectors. Pairs within `proximityThreshold` Hamming distance (default
/// 64 — 25% of 256 bits) are deduplicated and emitted as
/// `AssociationFrame` values with weight = 1 − (distance / 256).
///
/// The probe window is one-sided: probes are recency-sampled (newest first),
/// while neighbors are searched across the whole estate. Two dormant old
/// items will never pair unless one of them was probed while recent. This
/// is the documented limitation the `probeLimit` parameter exists to relieve
/// — callers such as the dream associate step and the benchmark protocol v2
/// can widen the window when a full-estate sweep is warranted.
///
/// TWO model populations are mined (same lane split as the contradiction
/// hunter): Drawer-keyed rows under the caller's `modelID` (bespoke lanes and
/// test-planted vectors), and — when a `CorpusContentEngine` is supplied —
/// Drawer-keyed rows under CorpusKit's own model ID. Shared-content 1.1 keys
/// both directly by canonical Drawer ID, so no passage-to-Drawer identity map
/// exists. Both lanes deduplicate on Drawer-pair keys.
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
/// recall improves results; until that runs, it is faithfully carried and
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

    /// Default number of item IDs sampled per pass from the VectorStore.
    /// Bounded to keep each 5-minute fire O(N·K) in the number of
    /// stored vectors rather than quadratic: 50 probes × 5 neighbours
    /// = 250 distance comparisons per pass. Callers that need a wider
    /// or narrower window pass an explicit `probeLimit` to `spec(...)`.
    public static let defaultProbeLimit: Int = 50

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
    ///   - corpus: The estate's `CorpusContentEngine`, when registered.
    ///     Enables its Drawer-keyed model population. `nil` scans only the
    ///     caller-selected `modelID` population.
    ///   - probeLimit: Maximum number of item IDs sampled from the
    ///     VectorStore on each pass via `recentItemIDs(limit:)`. Default
    ///     `defaultProbeLimit` (50). Resident behavior is byte-unchanged
    ///     at the default. Widen for callers that need a broader recency
    ///     window — the dream associate step and benchmark protocol v2
    ///     are the expected non-default users. The probe window is
    ///     one-sided: probes are recency-sampled (newest first), while
    ///     neighbors search the whole estate; two dormant old items
    ///     never pair unless one was probed while recent — this is
    ///     the limitation widening `probeLimit` relieves.
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
        probeLimit: Int = defaultProbeLimit,
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
                    probeLimit: probeLimit,
                    corpus: corpus,
                    edgeChecker: edgeChecker,
                    context: context)
            })
    }

    // MARK: - Proximity pass

    /// Execute one proximity scan pass: sample probe drawer IDs, find
    /// nearby neighbours, deduplicate pairs, emit AssociateFrames.
    ///
    /// The two-lane kNN scan is delegated to `ProximityScanCore.candidates`
    /// (shared with `GeniusLocusKit.associateSweep`) so the scan logic
    /// lives in exactly one place.
    ///
    /// If `edgeChecker` is provided, pairs with a persisted association
    /// are filtered out before emission (FINDING-3 optimization).
    private static func proximityPass(
        vectorStore: VectorStore,
        modelID: String,
        proximityThreshold: Int,
        probeLimit: Int,
        corpus: CorpusContentEngine?,
        edgeChecker: AssociationEdgeChecker?,
        context: SignalContext
    ) async -> [SignalEmission] {
        var emissions: [SignalEmission] = []

        let itemIDs: [String]
        do {
            // Newest-first probe sample bounded by `probeLimit`. New captures
            // are what need association screening; the prior ascending-item_id
            // enumeration was a static UUID-ordered window that new content
            // rarely entered on a large estate. The probe window is one-sided:
            // neighbors search the whole estate, so two dormant old items never
            // pair unless one was probed while recent — widening `probeLimit`
            // is how callers relieve that constraint.
            itemIDs = try await vectorStore.recentItemIDs(limit: probeLimit)
        } catch {
            emissions.append(.diagnostic(DiagnosticReport(
                title: "vector_similarity.scan.summary",
                detail: "probe-source scan failed: \(error); signal=\(context.signalID.rawValue)",
                observedAt: context.now)))
            return emissions
        }

        // Two-lane kNN scan via shared core (also used by associateSweep verb).
        // ProximityScanCore.candidates applies within-pass symmetric pair dedup
        // and returns unique (a, b, weight) candidates.
        let candidatePairs = await ProximityScanCore.candidates(
            in: vectorStore,
            itemIDs: itemIDs,
            modelID: modelID,
            proximityThreshold: proximityThreshold,
            corpus: corpus,
            neighboursPerProbe: ProximityScanCore.neighboursPerProbe
        )

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
