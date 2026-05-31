// MigrationBenchmarkTests.swift
//
// End-to-end tests of the MigrationBenchmark recipe against a real
// GeniusLocusKit estate over in-memory storage. Exercises every path:
// branch derivation + id-correlated population, the C-13 zero-silent-
// loss gate (pass AND fail), survivor ranking, gated promotion + loser
// discard, the disqualified-promotion guard, and the empty-plans guard.

import XCTest
import GeniusLocusKit
import LocusKit
import NeuronKit
import PersistenceKit
import PersistenceKitInMemory
import CognitionKit

final class MigrationBenchmarkTests: XCTestCase {

    private func makeEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(
                estateID: UUID(), backend: .inMemory))
        let handle = try await kit.open(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "migration-test"))
        return (kit, handle)
    }

    private func plan(_ name: String, room: String, code: String) -> MigrationPlan {
        MigrationPlan(
            name: name, room: room, latticeCode: code,
            embeddingModelID: "test-v1", sensitivity: .normal)
    }

    func testCleanCorpusBothPlansSurviveAndRank() async throws {
        let (kit, handle) = try await makeEstate()
        let origin = ExternalCorpus(name: "src", entries: [
            ExternalEntry(id: "a", content: "alpha topic concerning felines", tags: []),
            ExternalEntry(id: "b", content: "beta topic concerning canines", tags: []),
        ])
        let input = MigrationBenchmark.Input(
            origin: origin,
            plans: [
                plan("flat", room: "r1", code: "000"),
                plan("nested", room: "r2", code: "100"),
            ])

        let recipe = MigrationBenchmark()
        let out = try await recipe.run(input: input, estate: handle, kit: kit)

        // No silent loss: both plans captured both concepts.
        XCTAssertTrue(out.comparisonReport.disqualified.isEmpty)
        XCTAssertEqual(out.comparisonReport.rankings.count, 2)
        XCTAssertNotNil(out.comparisonReport.winnerPlanName)
        XCTAssertEqual(out.benchmarkReports.count, 2)
        // Every captured concept is recallable → no notFound on any branch.
        for report in out.benchmarkReports {
            XCTAssertTrue(report.notFoundInBranch.isEmpty)
        }

        // Gated promotion: promote the winner, discard the loser.
        let winnerName = try XCTUnwrap(out.comparisonReport.winnerPlanName)
        try await recipe.confirmPromotion(
            winnerPlanName: winnerName, output: out, estate: handle, kit: kit)

        let winner = try XCTUnwrap(out.branchesByPlan[winnerName])
        XCTAssertEqual(winner.status, .won)
        for (planName, branch) in out.branchesByPlan where planName != winnerName {
            XCTAssertEqual(branch.status, .discarded)
        }
    }

    func testEmptyContentEntryDisqualifiesPlan() async throws {
        let (kit, handle) = try await makeEstate()
        let origin = ExternalCorpus(name: "src", entries: [
            ExternalEntry(id: "good", content: "a perfectly valid concept", tags: []),
            ExternalEntry(id: "blank", content: "   ", tags: []),  // unmigratable
        ])
        let input = MigrationBenchmark.Input(
            origin: origin, plans: [plan("only", room: "r1", code: "000")])

        let recipe = MigrationBenchmark()
        let out = try await recipe.run(input: input, estate: handle, kit: kit)

        // The empty-content concept is a silent loss → plan disqualified.
        XCTAssertEqual(out.comparisonReport.disqualified.count, 1)
        XCTAssertTrue(out.comparisonReport.rankings.isEmpty)
        XCTAssertNil(out.comparisonReport.winnerPlanName)
        let dq = out.comparisonReport.disqualified[0]
        XCTAssertEqual(dq.planName, "only")
        XCTAssertTrue(dq.lostConcepts.contains("blank"))

        // C-5: promoting a disqualified plan throws silentConceptLoss.
        await XCTAssertThrowsErrorAsync(
            try await recipe.confirmPromotion(
                winnerPlanName: "only", output: out, estate: handle, kit: kit)
        ) { error in
            guard case RecipeError.silentConceptLoss = error else {
                return XCTFail("expected silentConceptLoss, got \(error)")
            }
        }
    }

    func testEmptyPlansThrowsInsufficientBranches() async throws {
        let (kit, handle) = try await makeEstate()
        let origin = ExternalCorpus(name: "src", entries: [
            ExternalEntry(id: "a", content: "anything", tags: []),
        ])
        let input = MigrationBenchmark.Input(origin: origin, plans: [])

        await XCTAssertThrowsErrorAsync(
            try await MigrationBenchmark().run(
                input: input, estate: handle, kit: kit)
        ) { error in
            XCTAssertEqual(error as? RecipeError,
                           .insufficientBranches(minimum: 1, provided: 0))
        }
    }

    func testCapabilityMetadataIsDeclared() {
        let recipe = MigrationBenchmark()
        XCTAssertEqual(recipe.name, "migration_benchmark")
        XCTAssertEqual(Set(recipe.requiredCapabilities),
                       [.deriveBranch, .benchmark, .promoteBranch])
    }

    // MARK: - Stateless (by-id) confirm path — the ARIA_MCP boundary

    func testIDBasedConfirmPromotesWinnerAndDiscardsLosers() async throws {
        let (kit, handle) = try await makeEstate()
        let origin = ExternalCorpus(name: "src", entries: [
            ExternalEntry(id: "a", content: "alpha topic concerning felines", tags: []),
            ExternalEntry(id: "b", content: "beta topic concerning canines", tags: []),
        ])
        let input = MigrationBenchmark.Input(
            origin: origin,
            plans: [
                plan("flat", room: "r1", code: "000"),
                plan("nested", room: "r2", code: "100"),
            ])
        let recipe = MigrationBenchmark()
        let out = try await recipe.run(input: input, estate: handle, kit: kit)

        let winnerID = try XCTUnwrap(out.comparisonReport.winnerBranchID)
        let loserIDs = out.comparisonReport.rankings
            .map(\.branchID)
            .filter { $0 != winnerID }

        // Confirm by id only — exactly what the stateless MCP confirm
        // tool has after a separate run call: ids from the prior report.
        try await recipe.confirmPromotion(
            winnerBranchID: winnerID,
            discardBranchIDs: loserIDs,
            estate: handle,
            kit: kit)

        // Resolve the winner back through the GLK accessor and assert it
        // was promoted; every loser was discarded. The await is pulled out
        // of XCTUnwrap because XCTUnwrap's autoclosure is not async.
        let winnerResolved = await kit.branchHandle(for: winnerID)
        let winner = try XCTUnwrap(winnerResolved)
        XCTAssertEqual(winner.status, .won)
        for id in loserIDs {
            let loserResolved = await kit.branchHandle(for: id)
            let loser = try XCTUnwrap(loserResolved)
            XCTAssertEqual(loser.status, .discarded)
        }
    }

    func testIDBasedConfirmGuardsAgainstDisqualifiedWinner() async throws {
        let (kit, handle) = try await makeEstate()
        // Derive one real branch so its id resolves; then assert that
        // naming it as winner while it is in the disqualified set raises
        // silentConceptLoss BEFORE any promotion (C-5 across the boundary).
        let branch = try await NeuronKit.deriveBranch(
            name: "p", from: handle, in: kit)
        await XCTAssertThrowsErrorAsync(
            try await MigrationBenchmark().confirmPromotion(
                winnerBranchID: branch.branchID,
                discardBranchIDs: [],
                disqualifiedBranchIDs: [branch.branchID],
                estate: handle, kit: kit)
        ) { error in
            guard case RecipeError.silentConceptLoss = error else {
                return XCTFail("expected silentConceptLoss, got \(error)")
            }
        }
        // The branch was never promoted — still active.
        XCTAssertEqual(branch.status, .active)
    }

    func testIDBasedConfirmUnknownBranchThrows() async throws {
        let (kit, handle) = try await makeEstate()
        await XCTAssertThrowsErrorAsync(
            try await MigrationBenchmark().confirmPromotion(
                winnerBranchID: UUID(),  // never derived by this kit
                discardBranchIDs: [],
                estate: handle, kit: kit)
        ) { error in
            guard case RecipeError.userConfirmationRequired = error else {
                return XCTFail("expected userConfirmationRequired, got \(error)")
            }
        }
    }

    func testGLKBranchAccessorReturnsNilForUnknownID() async throws {
        let (kit, _) = try await makeEstate()
        let resolved = await kit.branchHandle(for: UUID())
        XCTAssertNil(resolved)
    }
}

// MARK: - async throwing-assertion helper

/// Minimal async equivalent of `XCTAssertThrowsError`. XCTest's built-in
/// is synchronous; recipe calls are async, so the assertion is wrapped
/// here. Fails if the expression does not throw; otherwise hands the
/// thrown error to `handler` for inspection.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: String = "expected an error to be thrown",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ handler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail(message, file: file, line: line)
    } catch {
        handler(error)
    }
}
