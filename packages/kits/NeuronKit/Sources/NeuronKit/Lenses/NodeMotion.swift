// NodeMotion.swift
//
// The diffusion NODE-LAYER motion lens (ADR-DIFFUSION-001 §2/§4/§9, step §11.2).
//
// Diffusion is the time-axis peer of distillation; this is its bottom layer, the
// node. Structured exactly like the other temporal lenses here (Anticipation,
// Drift, AnomalyScan): a pure inner algorithm plus a `run(kit:handle:)` wrapper
// that reads the estate through GLK (NeuronKit depends on GeniusLocusKit). GLK
// owns the audit log + bridge (`kit.nodeAuditEntries`); NeuronKit owns the fold.
//
// • motion  — fold a node's {hlc, anchor} history with the node decay constant λ
//             into volatility + topic trajectory + reanchor.
// • anomaly — the HOT write-time read: classify that motion as churning /
//             reanchored (supersession-of-place) / stable.
//
// The decay weight exp(-λ·Δt_days) is the per-layer noise schedule: the node
// layer is HIGH frequency, so λ is LARGE. λ and the churn threshold are open
// ablation parameters (ADR §12). The folds are deterministic and conformance-
// portable to Rust (NeuronKit/rust diffusion/{node_motion,node_anomaly}.rs).

import Foundation
import GeniusLocusKit

// MARK: - Results

/// The node-layer motion model for a single row.
public struct NodeMotion: Sendable, Equatable {
    public let rowID: UUID
    /// Decay-weighted recent-mutation mass: Σ exp(-λ · Δt_days) over distinct
    /// mutation moments. High ⇒ actively churning; ~0 ⇒ long quiescent.
    public let volatility: Double
    /// Count of distinct mutation moments (distinct HLCs) folded.
    public let eventCount: Int
    /// Physical time (ms since epoch) of the most recent event, or nil.
    public let lastEventPhysicalMs: Int64?
    /// Ordered UDC anchors the node has occupied — its topic trajectory.
    public let anchorTrajectory: [UInt64]

    /// The node's current (latest) UDC anchor, or nil when none recorded.
    public var currentAnchor: UInt64? { anchorTrajectory.last }
    /// True when the node reanchored — its topic crossed ≥2 distinct codes.
    public var reanchored: Bool { Set(anchorTrajectory).count > 1 }

    public init(
        rowID: UUID,
        volatility: Double,
        eventCount: Int,
        lastEventPhysicalMs: Int64?,
        anchorTrajectory: [UInt64]
    ) {
        self.rowID = rowID
        self.volatility = volatility
        self.eventCount = eventCount
        self.lastEventPhysicalMs = lastEventPhysicalMs
        self.anchorTrajectory = anchorTrajectory
    }
}

/// A node-layer anomaly verdict, read hot at write time.
public struct NodeAnomaly: Sendable, Equatable {
    public let rowID: UUID
    public let volatility: Double
    /// The node is being rapidly re-edited — recent volatility over threshold.
    public let isChurning: Bool
    /// The node's topic has moved across its history (supersession-of-place).
    public let reanchored: Bool
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

// MARK: - The lens

/// The node-layer diffusion lens: pure folds + the estate-reading `run`/`anomaly`.
public enum NodeMotionLens {

    /// Informed-prior node decay constant, per DAY (fast layer). Ablate (ADR §12).
    public static let defaultNodeLambda: Double = 0.5

    /// Volatility at/above which a node is "churning". Ablate (ADR §12).
    public static let defaultChurnThreshold: Double = 3.0

    /// Milliseconds in one day — the Δt unit for the decay.
    private static let msPerDay: Double = 86_400_000.0

    // MARK: Pure cores (deterministic, conformance-gated)

    /// Fold a node's HLC-ordered audit entries into its motion model.
    /// Deterministic over (entries, now, λ). Pass `now`; never read the clock here.
    public static func fold(
        entries: [UnifiedAuditEntry],
        rowID: UUID,
        now: Date,
        lambdaPerDay: Double
    ) -> NodeMotion {
        // The packed-HLC layout truncates `physicalTime` to the low 40 bits of
        // epoch-ms, so HLC.physicalTime is `epoch_ms & (2^40 − 1)`, NOT the full
        // wall clock. Align `now` to that same 40-bit domain (and wrap the diff)
        // — otherwise the untruncated wall clock dwarfs the truncated physical and
        // every age reads as millennia, collapsing volatility to 0. The 2^40-ms
        // window is ~34 years, so a genuine wrap is a non-issue at these scales.
        let physicalMask: Int64 = (1 << 40) - 1
        let nowMs = Int64((now.timeIntervalSince1970 * 1000.0).rounded()) & physicalMask

        // One drawer write emits several field entries sharing one HLC; volatility
        // counts MUTATION MOMENTS, so fold over distinct HLCs.
        var seenPhysical = Set<Int64>()
        var volatility = 0.0
        var eventCount = 0
        var lastMs: Int64? = nil
        var trajectory: [UInt64] = []

        for entry in entries where entry.rowID == rowID {
            let physical = entry.hlc.physicalTime & physicalMask
            if seenPhysical.insert(physical).inserted {
                var dtMs = nowMs - physical
                if dtMs < 0 { dtMs += physicalMask + 1 }  // 40-bit wrap
                let ageDays = Double(dtMs) / msPerDay
                volatility += exp(-lambdaPerDay * ageDays)
                eventCount += 1
                if lastMs == nil || physical > lastMs! { lastMs = physical }
            }
            if entry.fieldPath == "latticeAnchor",
               case .integer(let coded) = entry.afterValue {
                trajectory.append(UInt64(bitPattern: coded))
            }
        }

        return NodeMotion(
            rowID: rowID,
            volatility: volatility,
            eventCount: eventCount,
            lastEventPhysicalMs: lastMs,
            anchorTrajectory: trajectory)
    }

    /// Classify a node's motion into a write-time anomaly verdict. Pure.
    public static func classify(
        motion: NodeMotion,
        churnThreshold: Double = defaultChurnThreshold
    ) -> NodeAnomaly {
        NodeAnomaly(
            rowID: motion.rowID,
            volatility: motion.volatility,
            isChurning: motion.volatility >= churnThreshold,
            reanchored: motion.reanchored,
            currentAnchor: motion.currentAnchor)
    }

    // MARK: Estate-reading lens entry (mimics Anticipate.run(kit:handle:))

    /// The node's motion model, read from the estate. Reads the node's FRESH
    /// bridged audit entries through GLK (`kit.nodeAuditEntries`) and folds them.
    public static func run(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        rowID: String,
        now: Date = Date(),
        lambdaPerDay: Double = defaultNodeLambda
    ) async throws -> NodeMotion {
        let entries = try await kit.nodeAuditEntries(for: handle, rowID: rowID)
        let uuid = UUID(uuidString: rowID) ?? UUID()
        return fold(entries: entries, rowID: uuid, now: now, lambdaPerDay: lambdaPerDay)
    }

    /// The node's write-time anomaly verdict, read from the estate.
    public static func anomaly(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        rowID: String,
        now: Date = Date(),
        lambdaPerDay: Double = defaultNodeLambda,
        churnThreshold: Double = defaultChurnThreshold
    ) async throws -> NodeAnomaly {
        let motion = try await run(
            kit: kit, handle: handle, rowID: rowID, now: now, lambdaPerDay: lambdaPerDay)
        return classify(motion: motion, churnThreshold: churnThreshold)
    }
}
