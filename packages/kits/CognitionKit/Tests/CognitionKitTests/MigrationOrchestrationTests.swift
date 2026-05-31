// MigrationOrchestrationTests.swift
//
// Conformance fixtures for the portable migration orchestration. These
// exact inputs, the recorded CALL SEQUENCE, and the assembled report are
// mirrored by the Rust port's `migration_orchestration` tests
// (CognitionKit/rust/src/migration_orchestration.rs) — both ports run the
// identical logic over an identical deterministic fake and must agree.
//
// SHARED FIXTURES (keep in lockstep with the Rust tests):
//   SEAM-1 clean, two plans -> full sequence, both survive, tie -> winner
//          "flat" (alphabetical), rankings [flat, nested]
//   SEAM-2 one empty-content origin entry -> dropped (never captured),
//          plan disqualified with lost ["blank"]
//   SEAM-3 benchmark marks one entry unrecallable -> disqualified with
//          lost [minted id "drawer-branch-p-1"]
//
// The fake mints DETERMINISTIC ids: branch -> "branch-<plan>", drawer ->
// "drawer-<branchID>-<captureIndex>". The Rust fake mints the same.

import XCTest
@testable import CognitionKit

/// Deterministic in-memory substrate. Records every call so the test can
/// assert the exact orchestration sequence, not just the final report.
private final class FakeSubstrate: RecipeSubstrate {
    /// Ordered log of every substrate call. Formats (identical in Rust):
    ///   "derive:<plan>"
    ///   "capture:<branchID>:<content>"
    ///   "benchmark:<branchID>"
    private(set) var calls: [String] = []

    /// Contents the benchmark treats as unrecallable (drives the
    /// benchmark-loss path). Matched on the captured entry's content.
    private let unrecallable: Set<String>

    /// Per-branch capture counter, for deterministic minted ids.
    private var captureCount: [String: Int] = [:]

    init(unrecallable: Set<String> = []) {
        self.unrecallable = unrecallable
    }

    func deriveBranch(planName: String) -> String {
        calls.append("derive:\(planName)")
        return "branch-\(planName)"
    }

    func capture(
        branchID: String, content: String, room: String,
        latticeCode: String, embeddingModelID: String, sensitivity: Int
    ) -> String {
        let n = captureCount[branchID, default: 0]
        captureCount[branchID] = n + 1
        calls.append("capture:\(branchID):\(content)")
        return "drawer-\(branchID)-\(n)"
    }

    func benchmark(
        branchID: String, corpus: [MigrationOrchestration.CorpusEntry]
    ) -> MigrationOrchestration.BenchmarkOutcome {
        calls.append("benchmark:\(branchID)")
        let notFound = corpus.filter { unrecallable.contains($0.content) }.map(\.id)
        let total = corpus.count
        let found = total - notFound.count
        let overlap: Float = total == 0 ? 0 : Float(found) / Float(total)
        let mrr: Float = found == 0 ? 0 : 1.0
        return MigrationOrchestration.BenchmarkOutcome(
            recallOverlap: overlap, meanReciprocalRank: mrr, notFound: notFound)
    }
}

final class MigrationOrchestrationTests: XCTestCase {

    private func plan(_ name: String, _ room: String, _ code: String)
        -> MigrationOrchestration.PlanInput {
        MigrationOrchestration.PlanInput(
            name: name, room: room, latticeCode: code,
            embeddingModelID: "test-v1", sensitivity: 0)
    }

    // SEAM-1 — clean, two plans: full sequence + tie-break ranking
    func testSeam1CleanTwoPlans() throws {
        let fake = FakeSubstrate()
        let origin = [
            MigrationOrchestration.OriginEntry(id: "a", content: "alpha"),
            MigrationOrchestration.OriginEntry(id: "b", content: "beta"),
        ]
        let report = try MigrationOrchestration.run(
            substrate: fake,
            plans: [plan("flat", "r1", "000"), plan("nested", "r2", "100")],
            origin: origin)

        // Exact call sequence — the heart of the orchestration gate.
        XCTAssertEqual(fake.calls, [
            "derive:flat",
            "capture:branch-flat:alpha",
            "capture:branch-flat:beta",
            "benchmark:branch-flat",
            "derive:nested",
            "capture:branch-nested:alpha",
            "capture:branch-nested:beta",
            "benchmark:branch-nested",
        ])

        // Both clean → both survive; equal scores → alphabetical.
        XCTAssertTrue(report.disqualified.isEmpty)
        XCTAssertEqual(report.rankings.map(\.name), ["flat", "nested"])
        XCTAssertEqual(report.winner, "flat")
        // Per-plan branch ids threaded through.
        XCTAssertEqual(report.planResults.map(\.branchID),
                       ["branch-flat", "branch-nested"])
        XCTAssertEqual(report.planResults.first?.recallOverlap, 1.0)
    }

    // SEAM-2 — empty-content entry dropped (never captured) → disqualified
    func testSeam2EmptyContentDropped() throws {
        let fake = FakeSubstrate()
        let origin = [
            MigrationOrchestration.OriginEntry(id: "good", content: "valid"),
            MigrationOrchestration.OriginEntry(id: "blank", content: "   "),
        ]
        let report = try MigrationOrchestration.run(
            substrate: fake, plans: [plan("only", "r1", "000")], origin: origin)

        // The blank entry is NOT captured.
        XCTAssertEqual(fake.calls, [
            "derive:only",
            "capture:branch-only:valid",
            "benchmark:branch-only",
        ])
        XCTAssertTrue(report.rankings.isEmpty)
        XCTAssertNil(report.winner)
        XCTAssertEqual(report.disqualified.map(\.name), ["only"])
        XCTAssertEqual(report.disqualified.first?.lostConcepts, ["blank"])
    }

    // SEAM-3 — benchmark marks one captured entry unrecallable
    func testSeam3BenchmarkNotFound() throws {
        let fake = FakeSubstrate(unrecallable: ["beta"])
        let origin = [
            MigrationOrchestration.OriginEntry(id: "a", content: "alpha"),
            MigrationOrchestration.OriginEntry(id: "b", content: "beta"),
        ]
        let report = try MigrationOrchestration.run(
            substrate: fake, plans: [plan("p", "r1", "000")], origin: origin)

        XCTAssertEqual(fake.calls, [
            "derive:p",
            "capture:branch-p:alpha",
            "capture:branch-p:beta",
            "benchmark:branch-p",
        ])
        // "beta" was captured second → minted id "drawer-branch-p-1",
        // reported not-found → plan disqualified on that minted id.
        XCTAssertTrue(report.rankings.isEmpty)
        XCTAssertEqual(report.disqualified.map(\.name), ["p"])
        XCTAssertEqual(report.disqualified.first?.lostConcepts,
                       ["drawer-branch-p-1"])
    }

    // Guards mirror the production run().
    func testEmptyPlansThrows() {
        let fake = FakeSubstrate()
        XCTAssertThrowsError(
            try MigrationOrchestration.run(substrate: fake, plans: [], origin: [])
        ) { error in
            XCTAssertEqual(error as? RecipeError,
                           .insufficientBranches(minimum: 1, provided: 0))
        }
        // No substrate calls made before the guard.
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testDuplicatePlanNameThrows() {
        let fake = FakeSubstrate()
        XCTAssertThrowsError(
            try MigrationOrchestration.run(
                substrate: fake,
                plans: [plan("dup", "r1", "000"), plan("dup", "r2", "100")],
                origin: [MigrationOrchestration.OriginEntry(id: "a", content: "x")])
        ) { error in
            XCTAssertEqual(error as? RecipeError, .duplicatePlanName("dup"))
        }
        XCTAssertTrue(fake.calls.isEmpty)
    }
}
