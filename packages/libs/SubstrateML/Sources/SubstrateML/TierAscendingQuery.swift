// TierAscendingQuery.swift
//
// Tier-ascending query protocol per cookbook § 12.4 and paper § 9.3.
//
// Federation queries traverse from a single estate to its peers to
// the aggregate tier and back. The protocol is unidirectional in
// the query direction: queries ascend, results descend, peers do
// not transit between themselves without explicit pairing (non-
// transitivity, paper § 9.6).
//
// Query parameters:
//   originating estate UUID
//   primitive name (a CognitionKit primitive)
//   primitive input (serialized parameters)
//   target tier (peer | fleet_aggregate | industry_aggregate)
//   privacy budget (epsilon, delta)
//
// Implemented functions (local scope only; signing and forwarding
// are caller responsibilities):
//   1. Local: compute the exact local result (computeLocal).
//   2. Peer-side: apply DP noise to a contribution (applyDPToContribution).
//   3. Combine: merge local + noised peer results (combine).
//   4. PrivacyLedger: track per-peer budget consumption.
//   5. Combine: originating estate combines local + peer/aggregate.
//
// Used by:
//   § 12.4 cookbook  Protocol definition (this file)
//   § 9.3 paper      Protocol recapitulation
//   § 12.6 cookbook  DP OR-reduction at aggregation
//   § 12.7 cookbook  Privacy ledger consumption

import Foundation
import SubstrateTypes

public enum TargetTier: String, Sendable {
    case peer              = "peer"
    case fleetAggregate    = "fleet_aggregate"
    case industryAggregate = "industry_aggregate"
}

public struct TierAscendingQuery: Sendable {
    public let originatingEstate: UUID
    public let primitiveName: String
    public let primitiveInput: Data         // canonical-encoded primitive params
    public let targetTier: TargetTier
    public let privacyBudget: DPParameters
    public let queryHLC: HLC

    public init(originatingEstate: UUID, primitiveName: String,
                primitiveInput: Data, targetTier: TargetTier,
                privacyBudget: DPParameters, queryHLC: HLC) {
        self.originatingEstate = originatingEstate
        self.primitiveName = primitiveName
        self.primitiveInput = primitiveInput
        self.targetTier = targetTier
        self.privacyBudget = privacyBudget
        self.queryHLC = queryHLC
    }
}

public struct PeerResponse: Sendable {
    public let peerEstate: UUID
    public let contribution: RecallResult
    public let consumedEpsilon: Float64
    public let consumedDelta: Float64
}

public enum TierAscendingQueryProtocol {

    /// Step 1: compute the exact local result. Wrapper over a
    /// CognitionKit primitive dispatch.
    public static func computeLocal(query: TierAscendingQuery,
                                    dispatch: (String, Data) -> RecallResult) -> RecallResult {
        return dispatch(query.primitiveName, query.primitiveInput)
    }

    /// Step 4 (peer side): apply DP to the local result before
    /// returning. The peer's contribution is scored, then Laplace
    /// noise of scale 1/epsilon is added to each row's score.
    public static func applyDPToContribution(_ result: RecallResult,
                                             budget: DPParameters,
                                             rngSeed: UInt64) -> RecallResult {
        var rng = SplitMix64(seed: rngSeed)
        let scale = 1.0 / budget.epsilon
        let noised = result.rows.map { score -> RecallScore in
            let noise = Float32(DPORReduction.laplaceNoise(scale: scale, rng: &rng))
            return RecallScore(rowId: score.rowId, score: score.score + noise)
        }
        let ci: (Float32, Float32) = (-1.96 * Float32(scale), 1.96 * Float32(scale))
        return RecallResult(rows: noised,
                            breakdown: result.breakdown,
                            confidenceInterval: ci,
                            primitiveName: result.primitiveName)
    }

    /// Step 5: combine local exact result with noisy peer responses.
    /// Combine rule: union by RowId, sum scores, sort descending.
    /// The combined result carries the widest confidence interval
    /// from any peer.
    public static func combine(local: RecallResult,
                               peers: [PeerResponse]) -> RecallResult {
        var combined: [RowId: Float32] = [:]
        for s in local.rows {
            combined[s.rowId, default: 0] += s.score
        }
        var widestCI: (Float32, Float32)? = nil
        for peer in peers {
            for s in peer.contribution.rows {
                combined[s.rowId, default: 0] += s.score
            }
            if let ci = peer.contribution.confidenceInterval {
                if widestCI == nil
                    || (ci.upper - ci.lower) > (widestCI!.1 - widestCI!.0) {
                    widestCI = ci
                }
            }
        }
        let merged = combined
            .map { RecallScore(rowId: $0.key, score: $0.value) }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.rowId < rhs.rowId
            }
        return RecallResult(rows: merged,
                            breakdown: local.breakdown,
                            confidenceInterval: widestCI,
                            primitiveName: local.primitiveName)
    }
}

/// Privacy ledger: per-peer cumulative (epsilon, delta) consumed.
/// Refused queries that would exceed budget; reset daily.
public struct PrivacyLedger: Sendable {
    public private(set) var entries: [UUID: (epsilon: Float64, delta: Float64)] = [:]
    public let dailyBudget: DPParameters

    public init(dailyBudget: DPParameters = DPParameters()) {
        self.dailyBudget = dailyBudget
    }

    public func remaining(peer: UUID) -> (epsilon: Float64, delta: Float64) {
        let used = entries[peer] ?? (0, 0)
        return (max(0, dailyBudget.epsilon - used.epsilon),
                max(0, dailyBudget.delta - used.delta))
    }

    public func canConsume(peer: UUID, query: DPParameters) -> Bool {
        let rem = remaining(peer: peer)
        return rem.epsilon >= query.epsilon && rem.delta >= query.delta
    }

    public mutating func consume(peer: UUID, query: DPParameters) {
        var used = entries[peer] ?? (0, 0)
        used.epsilon += query.epsilon
        used.delta += query.delta
        entries[peer] = used
    }

    public mutating func dailyReset() {
        entries.removeAll()
    }
}
