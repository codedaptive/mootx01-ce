// NounType.swift
//
// Phase 6.3 (DECISION_SUBSTRATELIB_PRESHIP_REFACTOR_2026-05-28.md §6.6)
// Moved from SubstrateLib/Sources/SubstrateLib/Verbs.swift.
//
// The eight noun categories that a substrate row can hold,
// per cookbook §2.5. Raw values are wire-stable and must never
// be renumbered.

import Foundation

public enum NounType: UInt8, Sendable {
    case drawer = 0
    case tunnel = 1
    case kgFact = 2
    case diaryEntry = 3
    case proposal = 4
    case association = 5
    case learnedReference = 6
    case ambientSample = 7
}
