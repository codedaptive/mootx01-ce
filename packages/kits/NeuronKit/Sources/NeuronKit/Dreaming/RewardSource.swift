// RewardSource.swift
//
// The dreaming daemon's reward-source seam (NEURONKIT_SPEC § 3.1 tick
// step 1, conformance C-15).
//
// The spec describes a TWO-SOURCE reward:
//   1a. explicit: DiaryEntry.reward (a quality score the substrate or
//       user assigned).
//   1b. implicit: RecallTraceItem.used (what callers actually acted on).
//
// `DiaryEntry.reward` does NOT exist on the substrate at this base commit
// (LocusKit DiaryEntry.swift carries no `reward` field; it is a deferred
// hook noted at EstateVerbs.swift:155). Adding it would require editing
// LocusKit, which this mission must not do. So v1 is SINGLE-SOURCE: the
// only live reward signal is `RecallTraceItem.used`. This seam keeps the
// two-source shape — a `RewardSource` is selected by `RewardSourceKind`,
// v1 ships only `.recallTrace`, and `.explicitDiaryReward` is the
// documented slot a later substrate mission fills. The daemon defaults to
// `.recallTrace` and never reads `DiaryEntry.reward`.

import Foundation
import LocusKit

/// Which reward signal a `RewardSource` derives reward from.
///
/// `recallTrace` is the only source available in v1. `explicitDiaryReward`
/// is the documented seam for the future explicit `DiaryEntry.reward`
/// source; it is declared so the two-source taxonomy from the spec is
/// visible at the type level, but the substrate does not expose that
/// field yet, so no source implements it in v1.
public enum RewardSourceKind: String, Sendable, Codable, CaseIterable, Equatable {

    /// Implicit relevance: `RecallTraceItem.used`. The v1 live source.
    case recallTrace

    /// Explicit quality: `DiaryEntry.reward`. Future source; the
    /// substrate field does not exist yet, so no v1 source reads it.
    case explicitDiaryReward
}

/// Derives a reward value in `[0, 1]` from a recall-trace row.
///
/// Net-new seam. The daemon depends on this protocol, not on any concrete
/// substrate field, so the explicit `DiaryEntry.reward` source can be
/// added later behind the same protocol without changing the daemon.
public protocol RewardSource: Sendable {

    /// The signal this source derives reward from. Used so callers (and
    /// conformance tests) can assert which source is wired.
    var kind: RewardSourceKind { get }

    /// Derived reward for a recall-trace row, in `[0, 1]`.
    func reward(for item: RecallTraceItem) -> Float
}

/// The v1 single-source reward: `RecallTraceItem.used`.
///
/// Derivation per NEURONKIT_SPEC § 3.1 step 1b: `used == true → 1.0`,
/// `used == false → 0.0`. This is the live implicit relevance signal —
/// rows callers actually acted on score 1.0, rows returned but ignored
/// score 0.0. Ignoring this source is non-conformant (C-15).
public struct RecallTraceRewardSource: RewardSource {

    public init() {}

    public var kind: RewardSourceKind { .recallTrace }

    /// `used → 1.0`, otherwise `0.0`. `RecallTraceItem.used` reads bit 0
    /// of the row's `operationalBitmap` (no Bool stored property).
    public func reward(for item: RecallTraceItem) -> Float {
        item.used ? 1.0 : 0.0
    }
}
