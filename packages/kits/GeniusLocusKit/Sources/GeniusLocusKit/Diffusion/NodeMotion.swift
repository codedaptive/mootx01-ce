// NodeMotion.swift
//
// The node-layer motion model (ADR-DIFFUSION-001 §2/§4, build step §11.2).
//
// Diffusion is the time-axis peer of distillation: it folds the reduced items'
// positions over time into per-layer motion. This file is the BOTTOM layer —
// the node. It folds one node's audit history `{verb, hlc, anchor}` (no content
// fingerprint yet; that is Option 3b) into:
//   • volatility       — decay-weighted recent-mutation mass (is this node churning?)
//   • topic trajectory — the ordered UDC anchors it has occupied
//   • reanchor         — whether its topic moved (a supersession-of-place signal)
//
// The decay weight `exp(-λ · Δt_days)` is the per-layer noise schedule: the node
// layer is HIGH frequency, so λ is LARGE (recent events dominate; old churn
// fades fast). λ is an open ablation parameter (ADR §12) — pass it explicitly;
// `defaultNodeLambda` is an informed prior, not a ratified value.
//
// `fold` is a PURE function of the node's entries + a reference instant, so it
// is deterministic and conformance-portable to Rust (node_motion.rs).

import Foundation

/// The node-layer motion model for a single row (drawer/item).
public struct NodeMotion: Sendable, Equatable {
    /// The node this motion describes.
    public let rowID: UUID
    /// Decay-weighted recent-mutation mass: Σ exp(-λ · Δt_days) over the node's
    /// distinct mutation moments. High ⇒ actively churning; ~0 ⇒ long quiescent.
    public let volatility: Double
    /// Count of distinct mutation moments (distinct HLCs) folded.
    public let eventCount: Int
    /// Physical time (ms since epoch) of the node's most recent event, or nil
    /// when the node has no audit history.
    public let lastEventPhysicalMs: Int64?
    /// The ordered UDC anchors the node has occupied — its topic trajectory,
    /// from the bridged `latticeAnchor` entries (Option 3a).
    public let anchorTrajectory: [UInt64]

    /// The node's current (latest) UDC anchor, or nil when none was recorded.
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

/// The pure node-layer fold. Deterministic over (entries, now, λ).
public enum NodeMotionFold {

    /// Informed-prior node decay constant, per DAY. The node layer is the fast
    /// (high-frequency) layer, so λ is large: at this value a mutation contributes
    /// ~0.61 weight after one day and ~0.08 after five. Ablate, do not treat as
    /// ratified (ADR-DIFFUSION-001 §12).
    public static let defaultNodeLambda: Double = 0.5

    /// Milliseconds in one day — the Δt unit for the decay.
    private static let msPerDay: Double = 86_400_000.0

    /// Fold a node's HLC-ordered audit entries into its motion model.
    ///
    /// - Parameters:
    ///   - entries: the node's `.locus`-tier entries, HLC-ordered (as returned by
    ///     `UnifiedAuditLog.entries(forRow:tier:)`). Entries that belong to other
    ///     rows are ignored defensively.
    ///   - rowID: the node being folded.
    ///   - now: the reference instant for the decay (pass it; never read the clock
    ///     inside — determinism rule).
    ///   - lambdaPerDay: the node decay constant (large = fast layer).
    /// - Returns: the node's `NodeMotion`.
    public static func fold(
        entries: [UnifiedAuditEntry],
        rowID: UUID,
        now: Date,
        lambdaPerDay: Double
    ) -> NodeMotion {
        let nowMs = Int64((now.timeIntervalSince1970 * 1000.0).rounded())

        // One drawer write emits several field entries sharing one HLC. Volatility
        // counts MUTATION MOMENTS, not field entries, so fold over distinct HLCs.
        var seenPhysical = Set<Int64>()
        var volatility = 0.0
        var eventCount = 0
        var lastMs: Int64? = nil

        var trajectory: [UInt64] = []

        for entry in entries where entry.rowID == rowID {
            let physical = entry.hlc.physicalTime

            // Distinct mutation moment → one decay-weighted contribution.
            if seenPhysical.insert(physical).inserted {
                let ageDays = max(0.0, Double(nowMs - physical)) / msPerDay
                volatility += exp(-lambdaPerDay * ageDays)
                eventCount += 1
                if lastMs == nil || physical > lastMs! { lastMs = physical }
            }

            // Topic trajectory: the anchor codes, in HLC order.
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
            anchorTrajectory: trajectory
        )
    }
}

// MARK: - Live convenience (Swift-side glue over the estate's audit log)

public extension GeniusLocusKit {

    /// The node-layer motion model for `rowID` in `handle`'s estate.
    ///
    /// Reads the node's `.locus` audit history from the estate's UnifiedAuditLog
    /// (populated by `feedAuditLog` on open / dream) and folds it through the pure
    /// `NodeMotionFold`. A row with no audit history folds to an empty motion
    /// (volatility 0, no trajectory). This is Swift-side glue over live storage —
    /// the portable, conformance-gated core is `NodeMotionFold.fold`.
    ///
    /// - Parameters:
    ///   - handle: the estate. Must be open.
    ///   - rowID: the node to fold.
    ///   - now: reference instant for the decay (defaults to the wall clock at the
    ///     API boundary; the engine itself never reads the clock).
    ///   - lambdaPerDay: node decay constant (large = fast layer).
    func nodeMotion(
        for handle: EstateHandle,
        rowID: UUID,
        now: Date = Date(),
        lambdaPerDay: Double = NodeMotionFold.defaultNodeLambda
    ) throws -> NodeMotion {
        let log = try auditLog(for: handle)
        let entries = log.entries(forRow: rowID, tier: .locus)
        return NodeMotionFold.fold(
            entries: entries, rowID: rowID, now: now, lambdaPerDay: lambdaPerDay)
    }
}
