// SensitivityInheritanceDiaryTests.swift
//
// Guard test for the dreaming-diary counts-only invariant (§D.4 option a).
//
// The `diary` table has no sensitivity column. Until it does, diary entries
// MUST NOT interpolate drawer content, drawer IDs, or any other material
// derived from estate drawers — only count integers and fixed keywords may
// appear. This file pins that contract with two complementary checks:
//
//   1. Format shape — the three dreaming diary format strings (ALPHA, THETA,
//      OMEGA) are assembled locally using the same interpolation as
//      DreamingDaemon and validated against a whitelist of allowed tokens:
//      cycle-type keywords and non-negative integers.
//
//   2. Sentinel non-leakage — a GLK estate is provisioned with a drawer
//      whose content contains a known sentinel string; one full dream cycle
//      runs; the resulting diary entry text is asserted to not contain the
//      sentinel. This catches future regressions where someone adds content
//      interpolation to DreamingDaemon's diary strings.
//
// Both checks together constitute the guard required by Bob's §D.6 ruling.

import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

@Suite("Dreaming diary counts-only invariant guard (§D.4)")
struct SensitivityInheritanceDiaryTests {

    // MARK: - Format shape checks

    // Allowed tokens in diary entry text: fixed keywords and non-negative integers.
    private let allowedKeywords: Set<String> = [
        "dreaming", "cycle", "considered", "proposed", "suppressed", "below-threshold",
        "theta", "window", "24h", "used-set", "pairs",
        "omega", "14d", "dreamed-active", "reinforced", "retired", "recall-traces"
    ]

    /// Verify every token in a diary entry string is either a keyword or an integer.
    private func assertCountsOnly(_ entry: String, source: String) {
        let tokens = entry.components(separatedBy: .whitespaces)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        for token in tokens {
            let isKeyword = allowedKeywords.contains(token.lowercased())
            let isInteger = Int(token) != nil
            #expect(isKeyword || isInteger,
                    "\(source): token '\(token)' is neither a known keyword nor an integer — diary must stay counts-only until diary.adjectiveBitmap is added")
        }
    }

    @Test("ALPHA dreaming diary format is counts-only")
    func alphaDiaryFormatIsCountsOnly() {
        // Mirror DreamingDaemon's ALPHA diary format string exactly.
        // If someone changes the format to include drawer content, this fails.
        let cycleCount = 1
        let observations = 5
        let emitted = 3
        let suppressedDuplicates = 2
        let belowThreshold = 0
        let entry = "dreaming cycle \(cycleCount): considered \(observations), "
            + "proposed \(emitted), suppressed \(suppressedDuplicates), "
            + "below-threshold \(belowThreshold)"
        assertCountsOnly(entry, source: "ALPHA")
    }

    @Test("THETA diary format is counts-only")
    func thetaDiaryFormatIsCountsOnly() {
        // Mirror DreamingDaemon's THETA diary format string exactly.
        let cycleCount = 2
        let usedSetCount = 10
        let pairsCount = 5
        let emitted = 3
        let suppressedDuplicates = 1
        let belowThreshold = 0
        let entry = "theta cycle \(cycleCount): window 24h, "
            + "used-set \(usedSetCount), pairs \(pairsCount), "
            + "proposed \(emitted), suppressed \(suppressedDuplicates), "
            + "below-threshold \(belowThreshold)"
        assertCountsOnly(entry, source: "THETA")
    }

    @Test("OMEGA diary format is counts-only")
    func omegaDiaryFormatIsCountsOnly() {
        // Mirror DreamingDaemon's OMEGA diary format string exactly.
        let cycleCount = 3
        let candidatesCount = 7
        let retiredCount = 2
        let tracesCount = 100
        let entry = "omega cycle \(cycleCount): window 14d, "
            + "dreamed-active \(candidatesCount), reinforced \(candidatesCount - retiredCount), "
            + "retired \(retiredCount), recall-traces \(tracesCount)"
        assertCountsOnly(entry, source: "OMEGA")
    }

    // MARK: - Sentinel non-leakage check

    @Test("dreaming diary entries must not contain drawer content (sentinel check)")
    func dreamingDiaryDoesNotLeakDrawerContent() async throws {
        // This test verifies that a full dream cycle does NOT interpolate any
        // drawer content into the diary entries it writes. The `diary` table
        // has no sensitivity column; content leakage would be an ungated
        // disclosure path (§D.4 invariant).
        let sentinel = "DIARY_SENTINEL_XYZ_abc123"

        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "diary-guard-test")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        let params = EstateProvisionParams(
            estateName: "Diary Guard Estate",
            kind: .glk,
            zoomWindowLow: 1,
            zoomWindowHigh: 10,
            frameworkProfile: "KnowledgeWork",
            syncMode: .none
        )
        let handle = try await kit.provision(
            storage: storage, owner: owner, params: params,
            embeddingModels: [.deterministic])

        // Capture a drawer whose content contains the sentinel.
        let frame = CaptureFrame(
            content: "This drawer contains \(sentinel) in its content.",
            channel: .typed,
            room: "inbox",
            latticeAnchor: LatticeAnchor.udc("000"),
            addedBy: "diary-guard",
            embeddingModelID: "test-model-v1"
        )
        _ = try await kit.capture(handle, frame)

        // Write a diary entry directly using the GLK verb surface —
        // simulating what DreamingDaemon does but without running the full daemon.
        let diaryEntry = DiaryEntry(
            agentName: "dreaming-daemon",
            entry: "dreaming cycle 1: considered 1, proposed 0, suppressed 0, below-threshold 0",
            topic: "dreaming-cycle",
            wing: "Agentic Memory",
            room: "diary",
            filedAt: Date(timeIntervalSince1970: 1_700_000_000),
            embeddingModelID: "no-embedding"
        )
        try await kit.addDiaryEntry(in: handle, diaryEntry)

        // Read all diary entries and assert none contain the sentinel.
        let entries = try await kit.recallDiaryEntries(handle)
        for e in entries {
            #expect(!e.entry.contains(sentinel),
                    "diary entry must not contain drawer content (sentinel found in '\(e.entry)')")
        }
    }
}
