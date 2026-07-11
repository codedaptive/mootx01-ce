// MigrationBenchmarkTests.swift
//
// End-to-end tests of the MigrationBenchmark recipe against a real
// GeniusLocusKit estate over in-memory storage. Exercises every path:
// branch derivation + id-correlated population, the C-13 zero-silent-
// loss gate (pass AND fail), survivor ranking, gated promotion + loser
// discard, the disqualified-promotion guard, and the empty-plans guard.
//
// ISOLATION: all tests that call MigrationBenchmark.run() acquire the
// process-wide cognitionTestMutex (CognitionTestLock.swift). After the
// cp-cognitionkit-report telemetry addition, recipe-run functions emit
// to the Intellectus global singleton. A concurrent telemetry test that
// holds the singleton enabled would otherwise receive this test's
// emissions into its capturing sink and corrupt exact-count assertions.
// This is the same discipline NeuronKit applies to BradleyTerry/Dreaming/
// HybridRecall tests (IntellectusTestLock.swift).
//
// Tests that throw BEFORE the telemetry emit site (empty plans, duplicate
// names) or that do not call run() (metadata, branch accessor) do not
// need the lock.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import PersistenceKit
import PersistenceKitInMemory
@testable import CognitionKit

@Suite("MigrationBenchmarkTests")
struct MigrationBenchmarkTests {

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

    @Test("clean corpus: both plans survive and rank")
    func cleanCorpusBothPlansSurviveAndRank() async throws {
        // Acquire the lock: MigrationBenchmark.run emits cognitionkit.recipe.run
        // to Intellectus. A concurrent telemetry test with the singleton enabled
        // would count this test's emissions in its capturing sink. See file comment.
        try await withCognitionLock {
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
            #expect(out.comparisonReport.disqualified.isEmpty)
            #expect(out.comparisonReport.rankings.count == 2)
            #expect(out.comparisonReport.winnerPlanName != nil)
            #expect(out.benchmarkReports.count == 2)
            // Every captured concept is recallable → no notFound on any branch.
            for report in out.benchmarkReports {
                #expect(report.notFoundInBranch.isEmpty)
            }

            // Gated promotion: promote the winner, discard the loser.
            let winnerName = try #require(out.comparisonReport.winnerPlanName)
            try await recipe.confirmPromotion(
                winnerPlanName: winnerName, output: out, estate: handle, kit: kit)

            let winner = try #require(out.branchesByPlan[winnerName])
            #expect(winner.status == .won)
            for (planName, branch) in out.branchesByPlan where planName != winnerName {
                #expect(branch.status == .discarded)
            }
        }
    }

    @Test("empty-content entry disqualifies plan")
    func emptyContentEntryDisqualifiesPlan() async throws {
        // Acquire the lock: MigrationBenchmark.run emits. See file comment.
        try await withCognitionLock {
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
            #expect(out.comparisonReport.disqualified.count == 1)
            #expect(out.comparisonReport.rankings.isEmpty)
            #expect(out.comparisonReport.winnerPlanName == nil)
            let dq = out.comparisonReport.disqualified[0]
            #expect(dq.planName == "only")
            #expect(dq.lostConcepts.contains("blank"))

            // C-5: promoting a disqualified plan throws silentConceptLoss.
            await #expect {
                try await recipe.confirmPromotion(
                    winnerPlanName: "only", output: out, estate: handle, kit: kit)
            } throws: { error in
                guard case RecipeError.silentConceptLoss = error else { return false }
                return true
            }

            // C-5 is server-side: the run DISCARDED the disqualified branch,
            // so it can never be promoted — not by the in-process path, and
            // not by a stateless caller replaying its id with no
            // disqualification claim (the reported bypass shape).
            let dqBranch = try #require(await kit.branchHandle(for: dq.branchID))
            #expect(dqBranch.status == .discarded)
            await #expect {
                try await recipe.confirmPromotion(
                    winnerBranchID: dq.branchID,
                    discardBranchIDs: [],
                    estate: handle, kit: kit)
            } throws: { error in
                guard case RecipeError.silentConceptLoss = error else { return false }
                return true
            }
            #expect(dqBranch.status == .discarded, "the bypass attempt must not change branch state")
        }
    }

    @Test("over-cap plan count throws tooManyPlans before deriving")
    func overCapPlanCountThrows() async throws {
        let (kit, handle) = try await makeEstate()
        let origin = ExternalCorpus(name: "src", entries: [
            ExternalEntry(id: "a", content: "anything", tags: []),
        ])
        let plans = (0...MigrationBenchmark.maxPlans).map {
            plan("plan-\($0)", room: "r\($0)", code: "000")
        }
        let input = MigrationBenchmark.Input(origin: origin, plans: plans)
        await #expect {
            _ = try await MigrationBenchmark().run(input: input, estate: handle, kit: kit)
        } throws: { error in
            guard case RecipeError.tooManyPlans = error else { return false }
            return true
        }
    }

    @Test("over-cap origin entries throws tooManyOriginEntries before deriving")
    func overCapOriginEntriesThrows() async throws {
        let (kit, handle) = try await makeEstate()
        let entries = (0...MigrationBenchmark.maxOriginEntries).map {
            ExternalEntry(id: "e\($0)", content: "c\($0)", tags: [])
        }
        let origin = ExternalCorpus(name: "src", entries: entries)
        let input = MigrationBenchmark.Input(
            origin: origin, plans: [plan("only", room: "r1", code: "000")])
        await #expect {
            _ = try await MigrationBenchmark().run(input: input, estate: handle, kit: kit)
        } throws: { error in
            guard case RecipeError.tooManyOriginEntries = error else { return false }
            return true
        }
    }

    @Test("empty plans throws insufficientBranches")
    func emptyPlansThrowsInsufficientBranches() async throws {
        let (kit, handle) = try await makeEstate()
        let origin = ExternalCorpus(name: "src", entries: [
            ExternalEntry(id: "a", content: "anything", tags: []),
        ])
        let input = MigrationBenchmark.Input(origin: origin, plans: [])

        await #expect(throws: RecipeError.insufficientBranches(minimum: 1, provided: 0)) {
            try await MigrationBenchmark().run(input: input, estate: handle, kit: kit)
        }
    }

    @Test("capability metadata is declared")
    func capabilityMetadataIsDeclared() {
        let recipe = MigrationBenchmark()
        #expect(recipe.name == "migration_benchmark")
        #expect(Set(recipe.requiredCapabilities) == [.deriveBranch, .benchmark, .promoteBranch])
    }

    // MARK: - Stateless (by-id) confirm path — the ARIA_MCP boundary

    @Test("id-based confirm promotes winner and discards losers")
    func idBasedConfirmPromotesWinnerAndDiscardsLosers() async throws {
        // Acquire the lock: MigrationBenchmark.run emits. See file comment.
        try await withCognitionLock {
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

            let winnerID = try #require(out.comparisonReport.winnerBranchID)
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
            // was promoted; every loser was discarded.
            let winner = try #require(await kit.branchHandle(for: winnerID))
            #expect(winner.status == .won)
            for id in loserIDs {
                let loser = try #require(await kit.branchHandle(for: id))
                #expect(loser.status == .discarded)
            }
        }
    }

    @Test("id-based confirm refuses a discarded branch with no caller claim")
    func idBasedConfirmRefusesDiscardedBranch() async throws {
        let (kit, handle) = try await makeEstate()
        // Derive one real branch and discard it (what `run` does to a
        // disqualified plan). Naming it as winner — with NO client-supplied
        // disqualification set, the exact reported bypass — must raise
        // silentConceptLoss BEFORE any promotion (C-5 across the boundary).
        let branch = try await NeuronKit.deriveBranch(
            name: "p", from: handle, in: kit)
        try await branch.discard()
        await #expect {
            try await MigrationBenchmark().confirmPromotion(
                winnerBranchID: branch.branchID,
                discardBranchIDs: [],
                estate: handle, kit: kit)
        } throws: { error in
            guard case RecipeError.silentConceptLoss = error else { return false }
            return true
        }
        // The branch was never promoted — still discarded.
        #expect(branch.status == .discarded)
    }

    @Test("id-based confirm unknown branch throws")
    func idBasedConfirmUnknownBranchThrows() async throws {
        let (kit, handle) = try await makeEstate()
        await #expect {
            try await MigrationBenchmark().confirmPromotion(
                winnerBranchID: UUID(),  // never derived by this kit
                discardBranchIDs: [],
                estate: handle, kit: kit)
        } throws: { error in
            guard case RecipeError.userConfirmationRequired = error else { return false }
            return true
        }
    }

    @Test("GLK branch accessor returns nil for unknown id")
    func glkBranchAccessorReturnsNilForUnknownID() async throws {
        let (kit, _) = try await makeEstate()
        let resolved = await kit.branchHandle(for: UUID())
        #expect(resolved == nil)
    }

    // MARK: - Concurrency + robustness improvements

    @Test("duplicate plan names are rejected")
    func duplicatePlanNamesAreRejected() async throws {
        let (kit, handle) = try await makeEstate()
        let origin = ExternalCorpus(name: "src", entries: [
            ExternalEntry(id: "a", content: "anything at all", tags: []),
        ])
        let input = MigrationBenchmark.Input(
            origin: origin,
            plans: [
                plan("same", room: "r1", code: "000"),
                plan("same", room: "r2", code: "100"),  // duplicate name
            ])
        await #expect(throws: RecipeError.duplicatePlanName("same")) {
            try await MigrationBenchmark().run(input: input, estate: handle, kit: kit)
        }
    }

    @Test("parallel run is deterministic across many plans")
    func parallelRunIsDeterministicAcrossManyPlans() async throws {
        // Acquire the lock: MigrationBenchmark.run emits. See file comment.
        // Note: this test calls run() TWICE; both are inside the lock so
        // neither run can race with a telemetry test's capturing sink.
        try await withCognitionLock {
            // The plan loop now runs concurrently. The result must be
            // identical to a serial run: every plan benchmarks its own clean
            // corpus, all survive, and the winner + ranking order are stable
            // (score desc, ties by plan name asc) regardless of which task
            // finished first. Four plans exercise the task group.
            let (kit, handle) = try await makeEstate()
            let origin = ExternalCorpus(name: "src", entries: [
                ExternalEntry(id: "a", content: "alpha concerning felines", tags: []),
                ExternalEntry(id: "b", content: "beta concerning canines", tags: []),
                ExternalEntry(id: "c", content: "gamma concerning equines", tags: []),
            ])
            let input = MigrationBenchmark.Input(
                origin: origin,
                plans: [
                    plan("delta", room: "r1", code: "000"),
                    plan("alpha", room: "r2", code: "100"),
                    plan("charlie", room: "r3", code: "200"),
                    plan("bravo", room: "r4", code: "300"),
                ])
            let recipe = MigrationBenchmark()
            let out = try await recipe.run(input: input, estate: handle, kit: kit)

            // All four clean plans survive; none disqualified.
            #expect(out.comparisonReport.disqualified.isEmpty)
            #expect(out.comparisonReport.rankings.count == 4)
            #expect(out.benchmarkReports.count == 4)
            #expect(out.branchesByPlan.count == 4)

            // All four branches are distinct, live handles.
            let branchIDs = Set(out.branchesByPlan.values.map(\.branchID))
            #expect(branchIDs.count == 4)

            // Determinism: equal scores ⇒ tie-break by plan name ascending.
            // With identical clean corpora every score ties, so the ranking
            // must be alphabetical by plan name.
            let ranked = out.comparisonReport.rankings.map(\.planName)
            #expect(ranked == ["alpha", "bravo", "charlie", "delta"])
            #expect(out.comparisonReport.winnerPlanName == "alpha")

            // Run again — the winner is stable across independent concurrent runs.
            let out2 = try await recipe.run(input: input, estate: handle, kit: kit)
            #expect(out2.comparisonReport.rankings.map(\.planName) == ["alpha", "bravo", "charlie", "delta"])
        }
    }
}
