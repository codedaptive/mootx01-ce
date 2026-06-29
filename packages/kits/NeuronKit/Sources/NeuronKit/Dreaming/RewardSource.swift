// RewardSource.swift
//
// The dreaming daemon's reward-source seam (NEURONKIT_SPEC § 3.1 tick
// step 1, conformance C-15).
//
// The spec describes a TWO-SOURCE reward:
//   1a. explicit: DiaryEntry.reward — a quality score the substrate or
//       user assigned; populated by write-time callers (user rating,
//       model confidence, or an explicit recall signal). Present on
//       DiaryEntry since LocusKit schema v1.
//   1b. implicit: RecallTraceItem.used — what callers actually acted on.
//
// PRECEDENCE: when a diary entry carries a non-nil `reward`,
// `ExplicitDiaryRewardSource` returns it directly; when nil it falls
// back to the trace-derived `RecallTraceRewardSource` value (1.0 when
// the trace item was used, 0.0 otherwise). The daemon's default
// wiring is `RecallTraceRewardSource` — no change to existing behaviour
// for callers that never set DiaryEntry.reward.
//
// Wiring diagram (NEURONKIT_SPEC § 3.1 step 1):
//   DreamingDaemon ──uses──> RewardSource protocol
//       ├── RecallTraceRewardSource  (default, implicit, C-15)
//       └── ExplicitDiaryRewardSource  (explicit, when reward present)
//           └── fallback: RecallTraceRewardSource when reward == nil

import Foundation
import LocusKit

/// Which reward signal a `RewardSource` derives reward from.
///
/// Both cases are now live: `recallTrace` is the default implicit source
/// (RecallTraceItem.used); `explicitDiaryReward` is backed by
/// DiaryEntry.reward, which exists on the substrate since schema v1.
public enum RewardSourceKind: String, Sendable, Codable, CaseIterable, Equatable {

    /// Implicit relevance: `RecallTraceItem.used`. Default source (C-15).
    case recallTrace

    /// Explicit quality: `DiaryEntry.reward`. Populated by callers that
    /// have a quality signal (user rating, model confidence, etc.).
    case explicitDiaryReward
}

/// Derives a reward value in `[0, 1]` from a recall-trace row.
///
/// Dependency seam. The daemon depends on this protocol, not on any concrete
/// substrate field. Two concrete sources are available: the default implicit
/// `RecallTraceRewardSource` and the explicit `ExplicitDiaryRewardSource`.
/// Both conform to this protocol so the daemon is independent of the
/// reward source selection.
public protocol RewardSource: Sendable {

    /// The signal this source derives reward from. Used so callers (and
    /// conformance tests) can assert which source is wired.
    var kind: RewardSourceKind { get }

    /// Derived reward for a recall-trace row, in `[0, 1]`.
    func reward(for item: RecallTraceItem) -> Float
}

/// The implicit recall-trace reward: `RecallTraceItem.used`.
///
/// Derivation per NEURONKIT_SPEC § 3.1 step 1b: `used == true → 1.0`,
/// `used == false → 0.0`. This is the default live implicit relevance
/// signal — rows callers actually acted on score 1.0, rows returned but
/// ignored score 0.0. Non-conformant to ignore this source (C-15).
public struct RecallTraceRewardSource: RewardSource {

    public init() {}

    public var kind: RewardSourceKind { .recallTrace }

    /// `used → 1.0`, otherwise `0.0`. `RecallTraceItem.used` reads bit 0
    /// of the row's `operationalBitmap` (no Bool stored property).
    public func reward(for item: RecallTraceItem) -> Float {
        item.used ? 1.0 : 0.0
    }
}

/// The explicit diary reward: `DiaryEntry.reward` (NEURONKIT_SPEC § 3.1
/// step 1a). Reads `DiaryEntry.reward` from diary entries keyed by
/// `RecallTraceItem.target` and returns the explicit quality score when
/// present.
///
/// PRECEDENCE: explicit reward from `DiaryEntry.reward` takes priority
/// over the implicit trace-derived signal. When `DiaryEntry.reward` is
/// nil for a given target the fallback source (`RecallTraceRewardSource`)
/// is consulted, so existing recall-trace behaviour is preserved for
/// rows without an explicit reward.
///
/// Usage: the caller constructs the reward map from diary entries and
/// passes it here; this source is then deterministic and free of
/// substrate I/O. `DreamingSubstrateReader` has no diary-entry read
/// method — diary reward loading is a caller responsibility.
public struct ExplicitDiaryRewardSource: RewardSource {

    /// Explicit rewards by drawer target ID. Populated from
    /// `DiaryEntry.reward` for entries whose `topic` or metadata links
    /// them to a target drawer. When a key is absent the fallback is used.
    public let rewardsByTarget: [String: Float]

    /// The fallback source consulted when `rewardsByTarget` has no entry
    /// for a target, or when the diary reward is nil. Default is
    /// `RecallTraceRewardSource`.
    public let fallback: any RewardSource

    public init(
        rewardsByTarget: [String: Float],
        fallback: any RewardSource = RecallTraceRewardSource()
    ) {
        self.rewardsByTarget = rewardsByTarget
        self.fallback = fallback
    }

    public var kind: RewardSourceKind { .explicitDiaryReward }

    /// Returns the explicit diary reward when present, otherwise delegates
    /// to `fallback`. Precedence: explicit → fallback. This matches the
    /// spec's two-source taxonomy: explicit diary reward (step 1a) overrides
    /// implicit trace signal (step 1b) when available.
    public func reward(for item: RecallTraceItem) -> Float {
        if let explicit = rewardsByTarget[item.target] {
            return explicit
        }
        return fallback.reward(for: item)
    }
}
