// NodeAnomaly.swift
//
// The node-layer WRITE-TIME anomaly read (ADR-DIFFUSION-001 §9, build step §11.2).
//
// Diffusion's integration is cold (dreaming folds the motion model), but the
// anticipation it produces is read HOT. This is the first hot read: at/after a
// write, classify a node's motion into a surfaceable anomaly —
//   • churning   — the node is being rapidly re-edited (recent volatility high)
//   • reanchored — its topic has moved (a supersession-of-place)
// Either is "worth a second look right now".
//
// `classify` is a PURE function of a NodeMotion, so it is deterministic and
// conformance-portable to Rust (node_anomaly.rs). The live read surface folds
// the node's FRESH per-row audit trail (which includes the just-written event,
// unlike the UnifiedAuditLog that is only fed on dream/open) — Swift-side glue.

import Foundation

/// A node-layer anomaly verdict, read hot at write time.
public struct NodeAnomaly: Sendable, Equatable {
    /// The node this verdict describes.
    public let rowID: UUID
    /// The node's decay-weighted recent-mutation mass (carried through for callers).
    public let volatility: Double
    /// The node is being rapidly re-edited — recent volatility over threshold.
    public let isChurning: Bool
    /// The node's topic has moved across its history (supersession-of-place).
    public let reanchored: Bool
    /// The node's current UDC anchor, or nil when none recorded.
    public let currentAnchor: UInt64?

    /// Any anomaly worth surfacing at write time.
    public var isAnomalous: Bool { isChurning || reanchored }

    public init(
        rowID: UUID,
        volatility: Double,
        isChurning: Bool,
        reanchored: Bool,
        currentAnchor: UInt64?
    ) {
        self.rowID = rowID
        self.volatility = volatility
        self.isChurning = isChurning
        self.reanchored = reanchored
        self.currentAnchor = currentAnchor
    }
}

/// The pure node-anomaly classifier over a NodeMotion.
public enum NodeAnomalyClassifier {

    /// Volatility at/above which a node is "churning". With the node λ default
    /// (0.5/day) a same-day mutation contributes ~1.0, so ~3 recent same-day
    /// edits crosses this. Informed prior — ablate (ADR-DIFFUSION-001 §12).
    public static let defaultChurnThreshold: Double = 3.0

    /// Classify a node's motion into a write-time anomaly verdict.
    public static func classify(
        motion: NodeMotion,
        churnThreshold: Double = defaultChurnThreshold
    ) -> NodeAnomaly {
        NodeAnomaly(
            rowID: motion.rowID,
            volatility: motion.volatility,
            isChurning: motion.volatility >= churnThreshold,
            reanchored: motion.reanchored,
            currentAnchor: motion.currentAnchor
        )
    }
}

// MARK: - Live write-time read (Swift-side glue over the fresh audit trail)

public extension GeniusLocusKit {

    /// Write-time node anomaly read: fold the node's FRESH per-row audit trail and
    /// classify it. Uses the live LocusKit trail (`estate.auditTrail`), which
    /// includes the just-written event — unlike the UnifiedAuditLog, which is fed
    /// on dream/open — so the verdict is accurate immediately after a write.
    ///
    /// - Parameters:
    ///   - handle: the estate. Must be open.
    ///   - rowID: the node's drawer id (UUID string).
    ///   - now: reference instant for the decay (defaults to the wall clock at the
    ///     API boundary; the fold itself never reads the clock).
    ///   - lambdaPerDay: node decay constant (large = fast layer).
    ///   - churnThreshold: volatility at/above which the node is "churning".
    /// - Returns: the node's `NodeAnomaly` verdict.
    func nodeAnomaly(
        for handle: EstateHandle,
        rowID: String,
        now: Date = Date(),
        lambdaPerDay: Double = NodeMotionFold.defaultNodeLambda,
        churnThreshold: Double = NodeAnomalyClassifier.defaultChurnThreshold
    ) async throws -> NodeAnomaly {
        let estate = try estate(for: handle)
        let events = try await estate.auditTrail(rowID: rowID)
        let entries = events.flatMap { AuditBridge.bridge($0) }
        // The bridged entries are keyed by the row's UUID; the fold filters on it.
        let uuid = UUID(uuidString: rowID) ?? UUID()
        let motion = NodeMotionFold.fold(
            entries: entries, rowID: uuid, now: now, lambdaPerDay: lambdaPerDay)
        return NodeAnomalyClassifier.classify(motion: motion, churnThreshold: churnThreshold)
    }
}
