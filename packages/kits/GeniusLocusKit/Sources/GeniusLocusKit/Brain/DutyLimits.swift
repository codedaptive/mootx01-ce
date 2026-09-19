// DutyLimits.swift — batch limits and the fact source lease for the row-debt
// duties (GENIUSLOCUSKIT_SPEC § DUTY_LIFECYCLE). The host supplies them from
// the settings module; the kit never reads a file. Absent, the defaults equal
// the constants the kit shipped with. The span-encode batch is not here: it is
// an estate manifest value (`provisionedEncoderBatch`).

import Foundation
import MootProductIdentity

public struct DutyLimits: Sendable, Equatable {
    /// Sources per fact-extraction batch.
    public var factExtractionBatch: Int
    /// Rows per subject-backfill sweep.
    public var subjectBackfillBatch: Int
    /// Per-source in-flight fence while a model call runs, in seconds. It must
    /// exceed the extractor's request timeout, otherwise a slow call can be
    /// claimed twice.
    public var factSourceLeaseSeconds: Int
    /// Containers scored per anomaly-sweep batch (ADR-026: a chest is at
    /// most 500 drawers; a first scoring is at most 250 000 pairs, every
    /// later write is linear).
    public var anomalySweepChests: Int
    /// Rooms re-binned per chest-rebin batch (a re-bin is one sort and one
    /// transaction).
    public var chestRebinBatch: Int

    public init(factExtractionBatch: Int = 16,
                subjectBackfillBatch: Int = 32,
                factSourceLeaseSeconds: Int = 120,
                anomalySweepChests: Int = 8,
                chestRebinBatch: Int = 1) {
        self.factExtractionBatch = max(1, factExtractionBatch)
        self.subjectBackfillBatch = max(1, subjectBackfillBatch)
        self.factSourceLeaseSeconds = max(1, factSourceLeaseSeconds)
        self.anomalySweepChests = max(1, anomalySweepChests)
        self.chestRebinBatch = max(1, chestRebinBatch)
    }

    /// The limits the product settings module carries (`duties` object).
    public init(settings: MootProductIdentity.Settings) {
        self.init(factExtractionBatch: settings.dutyFactExtractionBatch,
                  subjectBackfillBatch: settings.dutySubjectBackfillBatch,
                  factSourceLeaseSeconds: settings.dutyFactSourceLeaseSeconds,
                  anomalySweepChests: settings.dutyAnomalySweepChests,
                  chestRebinBatch: settings.dutyChestRebinBatch)
    }
}

public extension GeniusLocusKit {
    /// Install the limits for `handle`. Absent, `DutyLimits()` applies.
    func configureDutyLimits(_ limits: DutyLimits, for handle: EstateHandle) {
        dutyLimitsByHandle[handle] = limits
    }

    /// The limits in force for `handle`.
    func dutyLimits(for handle: EstateHandle) -> DutyLimits {
        dutyLimitsByHandle[handle] ?? DutyLimits()
    }
}
