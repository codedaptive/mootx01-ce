// AssociateSweep.swift
//
// The association-sweep verb and its shared proximity-scan core.
//
// One implementation, two triggers — the standing VectorSimilaritySignal
// (resident five-minute cadence) and the on-demand `associateSweep` verb
// (dream step 3.5, benchmark protocol v2). Pattern mirrors ContradictionHunt:
// one core, accessible to both the scheduler path and the verb path.
//
// ProximityScanCore encapsulates the two-lane kNN scan (drawer-keyed lane
// under the caller's modelID, corpus lane under the corpus's own modelID),
// within-pass symmetric pair dedup, and weight computation. It is the shared
// inner loop that replaces the duplicated scan in VectorSimilaritySignal.
//
// associateSweep drives ProximityScanCore and then:
//   - loads all existing active associations upfront → settled set
//   - filters candidates against the settled set
//   - writes survivors directly through estate.associate(_:now:)
//   - returns AssociateSweepReport with probed/candidatePairs/written/deduplicated

import Foundation
import LocusKit
import VectorKit
import CorpusKit

// MARK: - Report

/// Outcome of one `associateSweep` pass.
///
/// Fields mirror the ContradictionHuntReport shape so callers can reason
/// about both passes with consistent vocabulary.
///
/// - `probed`: number of item IDs sampled from the VectorStore (the probe set).
/// - `candidatePairs`: unique proximity pairs found by the two-lane kNN scan
///   before any settled-set filter is applied (within-pass dedup only).
/// - `written`: pairs written as new associations this pass.
/// - `deduplicated`: pairs skipped because an active association already exists
///   (settled-set filter — durable across calls).
public struct AssociateSweepReport: Sendable {
    /// Number of item IDs probed (the recency-ordered probe set).
    public let probed: Int
    /// Unique proximity-candidate pairs found by the two-lane kNN scan.
    public let candidatePairs: Int
    /// Pairs written as new associations this pass.
    public let written: Int
    /// Pairs skipped because an active association already existed.
    public let deduplicated: Int
}

// MARK: - Shared proximity scan core

/// Shared inner loop for the two-lane kNN proximity scan.
///
/// Both `VectorSimilaritySignal.proximityPass` and `GeniusLocusKit.associateSweep`
/// delegate here so the scan logic lives in exactly one place.
///
/// The core does NOT filter against existing associations — that responsibility
/// stays with the caller (signal uses an async `edgeChecker` closure;
/// `associateSweep` builds a settled set from `estate.allAssociations()`).
///
/// Two lanes are mined (same split as ContradictionHunt):
///   - Lane 1: drawer-keyed rows under the caller's `modelID`.
///   - Lane 2: drawer-keyed rows under the corpus provider's own model ID,
///     when a corpus is supplied. Shared-content 1.1 keys every row by
///     Drawer ID directly, so no chunk→drawer remap is needed.
///
/// Pair key: lexicographically smaller ID first, so (A,B) and (B,A) map
/// to the same element in the within-pass dedup set.
internal enum ProximityScanCore {

    /// Neighbours requested per probe via `findNearest`. Shared constant so
    /// `VectorSimilaritySignal` and `associateSweep` use identical k.
    static let neighboursPerProbe = 5

    /// Canonical pair key used for within-pass dedup and settled-set lookup.
    ///
    /// Produces the same string for (a, b) and (b, a) by placing the
    /// lexicographically smaller ID first.
    static func pairKey(_ a: String, _ b: String) -> String {
        a < b ? "\(a)||\(b)" : "\(b)||\(a)"
    }

    /// Execute one two-lane kNN proximity scan over the given probe item IDs.
    ///
    /// Returns candidate pairs with within-pass symmetric dedup applied.
    /// Does NOT filter against existing associations — callers apply their
    /// own settled-set or edge-checker filter on the returned array.
    ///
    /// - Parameters:
    ///   - vectorStore: The estate's `VectorStore`.
    ///   - itemIDs: Pre-fetched probe set (typically from `recentItemIDs(limit:)`).
    ///   - modelID: Embedding model for the drawer-keyed lane (Lane 1).
    ///   - proximityThreshold: Maximum Hamming distance (0-256) for a pair to qualify.
    ///   - corpus: Optional corpus engine for Lane 2. `nil` scans Lane 1 only.
    ///   - neighboursPerProbe: kNN k value. Defaults to `ProximityScanCore.neighboursPerProbe`.
    /// - Returns: Unique candidate pairs `(a: String, b: String, weight: Double)`, sorted
    ///   with a < b. Weight = 1 − (distance / 256).
    static func candidates(
        in vectorStore: VectorStore,
        itemIDs: [String],
        modelID: String,
        proximityThreshold: Int,
        corpus: CorpusContentEngine?,
        neighboursPerProbe: Int = ProximityScanCore.neighboursPerProbe
    ) async -> [(a: String, b: String, weight: Double)] {
        var result: [(a: String, b: String, weight: Double)] = []
        // Track seen pairs as canonical-key strings to deduplicate (A,B) vs
        // (B,A) from symmetric findNearest results. Both lanes key on DRAWER ids.
        var seenPairs: Set<String> = []

        // Lane 1 — drawer-keyed rows under the caller's `modelID`. Rows whose
        // item is not in this lane fail `getVector` and fall through silently.
        for itemID in itemIDs {
            // getVector returns Engram? — try? flattens to nil on failure so
            // the guard skips rows with no vector in this lane.
            guard let probeEngram = try? await vectorStore.getVector(
                itemID: itemID, modelID: modelID) else { continue }

            guard let matches = try? await vectorStore.findNearest(
                probe: probeEngram,
                modelID: modelID,
                limit: neighboursPerProbe) else { continue }

            for match in matches {
                guard match.itemID != itemID else { continue }
                guard match.distance <= proximityThreshold else { continue }

                // Canonical pair key: lexicographically smaller ID first so
                // (A,B) and (B,A) map to the same set element.
                let key = pairKey(itemID, match.itemID)
                guard seenPairs.insert(key).inserted else { continue }

                // Weight: 1 − distance/256. Identical vectors → 1.0.
                // ADMIN — weight is derived free from the already-computed
                // proximity-gate Hamming distance (no extra origin-side work
                // to obtain it). It is carried on the AssociationFrame but
                // VESTIGIAL past the `associate` verb, which has no weight
                // column to persist it into. Retained on purpose — a pre-2.0
                // gauntlet experiment will test whether weight improves recall.
                let weight = 1.0 - Double(match.distance) / 256.0
                result.append(
                    (a: min(itemID, match.itemID),
                     b: max(itemID, match.itemID),
                     weight: weight))
            }
        }

        // Lane 2 — the corpus provider's drawer-keyed rows. Shared-content 1.1:
        // the engine keys every vector row by DRAWER ID, so a hit's itemID is
        // the owning drawer directly — no chunk→drawer remap and no same-drawer
        // chunk collapse. Mirrors VectorSimilaritySignal Lane 2.
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
                    let key = pairKey(itemID, match.itemID)
                    guard seenPairs.insert(key).inserted else { continue }
                    result.append(
                        (a: min(itemID, match.itemID),
                         b: max(itemID, match.itemID),
                         weight: 1.0 - Double(match.distance) / 256.0))
                }
            }
        }

        return result
    }
}

// MARK: - associateSweep verb

public extension GeniusLocusKit {

    /// Run one bounded vector-similarity association sweep outside the standing-signal scheduler.
    ///
    /// Shape mirrors the accepted subject-sweep and huntContradictions patterns:
    /// one implementation, two triggers — the resident VectorSimilaritySignal
    /// cadence (via `proximityPass`) and this on-demand verb (dream step 3.5,
    /// benchmark protocol v2).
    ///
    /// Coverage argument:
    ///   - `probeLimit: nil` → ALL item IDs ("everything" coverage, for dream/benchmark use).
    ///   - `probeLimit: n` → the `n` most-recently-filed item IDs.
    ///
    /// Determinism: probe order is `ORDER BY filed_at DESC, item_id ASC` — the
    /// ORDER BY guaranteed by `VectorStore.recentItemIDs(limit:)`. Same-seed
    /// estates write the same association set on repeated calls, subject to the
    /// INSERT-OR-IGNORE dedup guard in `addAssociation`.
    ///
    /// Dedup: all existing active (non-tombstoned) associations are loaded upfront
    /// into a settled set before the scan runs. Tombstoned associations are excluded
    /// from the settled set — a re-sweep can recreate a deleted association.
    ///
    /// The DB-level INSERT-OR-IGNORE in `addAssociation` is the primary correctness
    /// guard against races; the settled set avoids unnecessary write attempts.
    ///
    /// - Parameters:
    ///   - handle: Open estate handle.
    ///   - probeLimit: Maximum item IDs to probe. `nil` = all items.
    ///   - now: Deterministic clock for association `filedAt` timestamps.
    /// - Returns: `AssociateSweepReport` with probed/candidatePairs/written/deduplicated counts.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if `handle` is not in the registry.
    func associateSweep(
        in handle: EstateHandle,
        probeLimit: Int?,
        now: Date
    ) async throws -> AssociateSweepReport {
        let estate = try estate(for: handle)

        // A missing VectorStore is not an error — the estate simply has no
        // vector index yet. Return a zero report identical to the signal's
        // no-op when the store is absent.
        guard let vectorStore = registeredVectorStore(for: handle) else {
            return AssociateSweepReport(probed: 0, candidatePairs: 0, written: 0, deduplicated: 0)
        }

        // Probe sample: recency-ordered item IDs bounded by `probeLimit`.
        // Int.max → exhausts the table (all items), correct for "everything" coverage.
        let limit = probeLimit ?? Int.max
        let itemIDs = try await vectorStore.recentItemIDs(limit: limit)
        guard !itemIDs.isEmpty else {
            return AssociateSweepReport(probed: 0, candidatePairs: 0, written: 0, deduplicated: 0)
        }

        // Durable settled set: load all ACTIVE (non-tombstoned) associations
        // so the sweep does not duplicate existing edges. Tombstoned rows are
        // excluded — a re-sweep may legitimately recreate a deleted association.
        var settledSet: Set<String> = []
        for assoc in try await estate.allAssociations() {
            if let a = assoc.sourceDrawerId, let b = assoc.targetDrawerId,
               assoc.tombstonedAt == nil {
                settledSet.insert(ProximityScanCore.pairKey(a, b))
            }
        }

        // Two-lane kNN scan via shared core.
        // modelID default: "minilm-v6" — the drawer-keyed lane default, same as
        // huntContradictions. Corpus lane 2 mined when a corpus is registered.
        let modelID = "minilm-v6"
        let candidates = await ProximityScanCore.candidates(
            in: vectorStore,
            itemIDs: itemIDs,
            modelID: modelID,
            proximityThreshold: VectorSimilaritySignal.defaultProximityThreshold,
            corpus: corpusKits[handle],
            neighboursPerProbe: ProximityScanCore.neighboursPerProbe
        )

        var written = 0
        var deduplicated = 0
        for pair in candidates {
            let key = ProximityScanCore.pairKey(pair.a, pair.b)
            if settledSet.contains(key) {
                deduplicated += 1
            } else {
                // Write directly through the estate verb surface (B-1 compliant).
                // LocusKit.AssociateFrame disambiguated from GeniusLocusKit.AssociateFrame.
                let frame = LocusKit.AssociateFrame(a: pair.a, b: pair.b, weight: pair.weight)
                do {
                    _ = try await estate.associate(frame, now: now)
                    written += 1
                    // Update settled set in-place to prevent within-pass re-attempts
                    // on the same pair from the other kNN direction.
                    settledSet.insert(key)
                } catch {
                    // Fail-soft: a single write failure (e.g. unknown drawer ID,
                    // transient storage error) does not abort the sweep. The
                    // INSERT-OR-IGNORE guard in addAssociation handles races.
                }
            }
        }

        return AssociateSweepReport(
            probed: itemIDs.count,
            candidatePairs: candidates.count,
            written: written,
            deduplicated: deduplicated
        )
    }
}
