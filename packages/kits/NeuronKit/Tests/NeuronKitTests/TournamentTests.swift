import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import GeniusLocusKit
@testable import NeuronKit

/// Tournament scoring, gate, ranking, and I-16 tests — NK-TOUR-01.
///
/// Two test layers, by necessity:
///
/// - Multi-branch ranking / tie-break / all-disqualified are unit-tested
///   against the pure `NeuronKit.rankTournament` core with fabricated
///   `BenchmarkReport` fixtures (built via the public initializer). The
///   benchmark compares origin-corpus IDs against the per-branch minted
///   drawer IDs, so a single shared corpus can yield a non-disqualified
///   report for at most one branch — fabricated reports are the only way
///   to exercise several survivors with controlled scores. This is the
///   "in-test fixture path for benchmark() results" the mission calls
///   for, not a new mock layer: the reports are real `BenchmarkReport`
///   values and the branches are real handles.
///
/// - Single-branch survive, empty input, and the I-16 read-only property
///   are integration-tested end-to-end through the public
///   `runTournament`, which calls the real NK-BR-01 `benchmark`. Estate
///   setup mirrors `NK_BR_01_BranchBenchmarkTests`.
@Suite("Tournament scoring, gate, ranking, and I-16")
struct TournamentTests {

    // MARK: - Deterministic time inputs (never the wall clock)

    /// Fixed evaluation instant for every test — the determinism rule:
    /// `evaluatedAt`/`interval` are inputs, never read from the clock.
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    private var fixedInterval: DateInterval {
        DateInterval(start: fixedNow, duration: 60)
    }

    // MARK: - Estate / branch helpers (mirror NK_BR_01_BranchBenchmarkTests)

    /// Open a fresh estate through GeniusLocusKit backed by in-memory
    /// storage.
    private func openEstate(owner: String = "nk-tour-01-owner") async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let credentials = OwnerCredentials(ownerIdentifier: owner)
        _ = try await LocusKit.Estate.create(storage: storage, owner: credentials)
        let handle = try await kit.open(storage: storage, owner: credentials)
        return (kit, handle)
    }

    /// Derive `count` active branches from one fresh estate. Used by the
    /// unit-layer tests, which only need real handles (for `branchID`)
    /// and pair them with fabricated reports.
    private func deriveBranches(_ count: Int) async throws -> [any BranchHandle] {
        let (kit, handle) = try await openEstate()
        var branches: [any BranchHandle] = []
        for index in 0..<count {
            branches.append(try await NeuronKit.deriveBranch(name: "branch-\(index)", from: handle, in: kit))
        }
        return branches
    }

    /// Capture one drawer into a branch and return the stored `Drawer`
    /// (whose generated `id` the corpus fixtures correlate against).
    @discardableResult
    private func captureIntoBranch(_ branch: any BranchHandle, content: String) async throws -> Drawer {
        let frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: "nk-tour-01",
            latticeAnchor: .udc("000"),
            addedBy: "nk-tour-01",
            embeddingModelID: "test-model-v1"
        )
        return try await branch.capture(frame)
    }

    /// Count rows currently recall-able from a branch via a bare
    /// content-agnostic chain — used by the I-16 read-only test.
    /// UserConfirmed: all rows written via capture() are stamped at write time.
    private func branchRowCount(_ branch: any BranchHandle) async throws -> Int {
        let frame = RecallFrame(
            filterChain: [.userConfirmed],
            hydrationLevel: .structured,
            ordering: .byCaptureTimeDesc
        )
        return try await branch.recall(frame).count
    }

    /// Build a fabricated `BenchmarkReport` with controlled ranking
    /// inputs. `recallPrecision` and `newInBranch` are not read by the
    /// ranking core; they carry mirror/empty values so the fixture is a
    /// well-formed report.
    private func makeReport(
        branchID: BranchID,
        overlap: Float,
        mrr: Float,
        notFound: [String] = []
    ) -> BenchmarkReport {
        BenchmarkReport(
            branchID: branchID,
            queryCount: 3,
            recallOverlap: overlap,
            recallPrecision: overlap,
            meanReciprocalRank: mrr,
            notFoundInBranch: notFound,
            newInBranch: [],
            evaluatedAt: fixedNow
        )
    }

    /// A clean corpus whose entry IDs equal a branch's own captured
    /// drawer IDs, so the branch recalls every concept with no silent
    /// loss. Distinct contents avoid substring collisions so each query
    /// resolves to exactly one drawer.
    private func cleanCorpusForBranch(_ branch: any BranchHandle) async throws -> ExternalCorpus {
        let a = try await captureIntoBranch(branch, content: "nk-tour-alpha-concept")
        let b = try await captureIntoBranch(branch, content: "nk-tour-bravo-concept")
        let c = try await captureIntoBranch(branch, content: "nk-tour-charlie-concept")
        return ExternalCorpus(name: "clean", entries: [
            ExternalEntry(id: a.id, content: a.content, tags: []),
            ExternalEntry(id: b.id, content: b.content, tags: []),
            ExternalEntry(id: c.id, content: c.content, tags: []),
        ])
    }

    // MARK: - Test 1: disqualification gate excludes a silent-loss branch

    @Test("disqualification gate excludes a silent-loss branch")
    func disqualificationGateExcludesSilentLossBranch() async throws {
        let branch = try await deriveBranches(1)[0]
        let report = makeReport(branchID: branch.branchID, overlap: 0.9, mrr: 0.9, notFound: ["lost-concept"])

        let result = NeuronKit.rankTournament(
            scored: [(branch: branch, report: report)],
            evaluatedAt: fixedNow,
            interval: fixedInterval
        )

        #expect(result.disqualified.count == 1)
        #expect(result.disqualified.first?.reason == .silentLoss(notFoundCount: 1))
        #expect(result.disqualified.first?.branch.branchID == branch.branchID)
        // Disqualified branch is absent from ranking and is not the winner.
        #expect(result.ranking.isEmpty)
        #expect(result.winner == nil)
    }

    // MARK: - Test 2: a zero-silent-loss branch survives and is ranked

    @Test("a zero-silent-loss branch survives and is ranked")
    func zeroSilentLossBranchSurvivesAndRanks() async throws {
        // End-to-end through the real benchmark: one clean branch whose
        // corpus IDs equal its own drawer IDs recalls everything.
        let branch = try await deriveBranches(1)[0]
        let corpus = try await cleanCorpusForBranch(branch)

        let result = try await NeuronKit.runTournament(
            branches: [branch],
            against: corpus,
            evaluatedAt: fixedNow,
            interval: fixedInterval
        )

        #expect(result.disqualified.isEmpty)
        #expect(result.ranking.count == 1)
        #expect(result.ranking.first?.branch.branchID == branch.branchID)
        #expect(result.ranking.first?.report.notFoundInBranch.isEmpty ?? false)
        #expect(result.winner?.branch.branchID == branch.branchID)
    }

    // MARK: - Test 3: survivors rank descending by combined score

    @Test("survivors rank descending by combined score")
    func rankingIsDescendingByCombinedScore() async throws {
        let branches = try await deriveBranches(3)
        let high = branches[0]   // 1.0 * 1.0 = 1.00
        let mid = branches[1]    // 0.8 * 0.5 = 0.40
        let low = branches[2]    // 0.6 * 0.5 = 0.30

        // Supplied out of score order to prove the core sorts.
        let scored: [(branch: any BranchHandle, report: BenchmarkReport)] = [
            (branch: mid, report: makeReport(branchID: mid.branchID, overlap: 0.8, mrr: 0.5)),
            (branch: high, report: makeReport(branchID: high.branchID, overlap: 1.0, mrr: 1.0)),
            (branch: low, report: makeReport(branchID: low.branchID, overlap: 0.6, mrr: 0.5)),
        ]

        let result = NeuronKit.rankTournament(scored: scored, evaluatedAt: fixedNow, interval: fixedInterval)

        #expect(result.ranking.map { $0.branch.branchID } == [high.branchID, mid.branchID, low.branchID])
        // Scores are strictly descending.
        #expect(result.ranking[0].combinedScore > result.ranking[1].combinedScore)
        #expect(result.ranking[1].combinedScore > result.ranking[2].combinedScore)
        #expect(result.winner?.branch.branchID == result.ranking.first?.branch.branchID)
        #expect(result.winner?.branch.branchID == high.branchID)
    }

    // MARK: - Test 4: ties break on branch identifier, deterministically

    @Test("ties break on branch identifier, deterministically")
    func tieBreakIsStableAndDeterministic() async throws {
        let branches = try await deriveBranches(2)
        // Equal combined scores (1.0 * 1.0 each) force the tie-break path.
        let scored: [(branch: any BranchHandle, report: BenchmarkReport)] = [
            (branch: branches[0], report: makeReport(branchID: branches[0].branchID, overlap: 1.0, mrr: 1.0)),
            (branch: branches[1], report: makeReport(branchID: branches[1].branchID, overlap: 1.0, mrr: 1.0)),
        ]
        // Expected order is ascending branchID string, independent of
        // input order.
        let expectedOrder = branches
            .sorted { $0.branchID.uuidString < $1.branchID.uuidString }
            .map { $0.branchID }

        let firstRun = NeuronKit.rankTournament(scored: scored, evaluatedAt: fixedNow, interval: fixedInterval)
        let secondRun = NeuronKit.rankTournament(scored: scored, evaluatedAt: fixedNow, interval: fixedInterval)

        #expect(firstRun.ranking.map { $0.branch.branchID } == expectedOrder)
        // Identical across two runs on the same input.
        #expect(firstRun == secondRun)
    }

    // MARK: - Test 5: every branch disqualified yields no winner

    @Test("every branch disqualified yields no winner")
    func allDisqualifiedYieldsNoWinner() async throws {
        let branches = try await deriveBranches(2)
        let scored: [(branch: any BranchHandle, report: BenchmarkReport)] = [
            (branch: branches[0], report: makeReport(branchID: branches[0].branchID, overlap: 0.5, mrr: 0.5, notFound: ["x"])),
            (branch: branches[1], report: makeReport(branchID: branches[1].branchID, overlap: 0.5, mrr: 0.5, notFound: ["y", "z"])),
        ]

        let result = NeuronKit.rankTournament(scored: scored, evaluatedAt: fixedNow, interval: fixedInterval)

        #expect(result.winner == nil)
        #expect(result.ranking.isEmpty)
        #expect(result.disqualified.count == 2)
        #expect(result.disqualified[1].reason == .silentLoss(notFoundCount: 2))
    }

    // MARK: - Test 6: empty input yields an empty advisory report

    @Test("empty input yields an empty advisory report")
    func emptyInputYieldsEmptyReport() async throws {
        // No branches → benchmark is never called; the corpus is inert.
        let corpus = ExternalCorpus(name: "empty-input", entries: [
            ExternalEntry(id: "c1", content: "alpha", tags: []),
        ])

        let result = try await NeuronKit.runTournament(
            branches: [],
            against: corpus,
            evaluatedAt: fixedNow,
            interval: fixedInterval
        )

        #expect(result.winner == nil)
        #expect(result.ranking.isEmpty)
        #expect(result.disqualified.isEmpty)
        #expect(result.evaluatedAt == fixedNow)
        #expect(result.interval == fixedInterval)
    }

    // MARK: - Test 7: I-16 — the tournament is advisory and mutates nothing

    @Test("I-16 — the tournament is advisory and mutates nothing")
    func tournamentIsAdvisoryAndPerformsNoMutation() async throws {
        // Structural I-16 assertion. runTournament's only substrate touch
        // is the read-only benchmark (which drives only recall). The
        // promotion verb lives on the GeniusLocusKit surface
        // (glkPromoteBranch) and is neither imported nor reachable here —
        // there is nothing on BranchHandle to promote with. We confirm
        // the branch is left untouched: status and drawer count are
        // unchanged after the tournament runs.
        let branch = try await deriveBranches(1)[0]
        let corpus = try await cleanCorpusForBranch(branch)

        let statusBefore = branch.status
        let countBefore = try await branchRowCount(branch)

        _ = try await NeuronKit.runTournament(
            branches: [branch],
            against: corpus,
            evaluatedAt: fixedNow,
            interval: fixedInterval
        )

        #expect(branch.status == statusBefore,
            "runTournament must not transition branch status — winner is advisory (I-16)")
        #expect(branch.status == .active)
        let countAfter = try await branchRowCount(branch)
        #expect(countBefore == countAfter,
            "runTournament must issue no write verbs — branch drawer count must be unchanged")
    }
}
