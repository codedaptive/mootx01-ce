import AdornmentLib
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitSQLite
import Testing

@testable import GeniusLocusKit

/// Fan-out behavior of `AdornmentPass.run` (GENIUSLOCUSKIT_SPEC § 16.1):
/// pairs are minted through a width-bounded task group sized by the
/// engine's declared `maxConcurrentMints` (or the explicit `width`
/// override these tests use, so the pass's concurrency never depends on
/// the machine's engine availability).
///
/// Golden pins:
///   - Width > 1 genuinely overlaps generator calls (rendezvous witness).
///   - Every pair still lands exactly once — counters and stored rows
///     match the serial loop's contract.
///   - Width 1 preserves strict one-at-a-time generation.
@Suite("AdornmentPass fan-out")
struct AdornmentPassFanOutTests {

    private static let owner = OwnerCredentials(ownerIdentifier: "fanout-test-owner")

    /// Rendezvous gate: releases every waiter once `expected` callers have
    /// arrived. A serial caller sequence never reaches `expected`
    /// simultaneous waiters and times out instead — the concurrency witness.
    private actor Rendezvous {
        private let expected: Int
        private var arrived = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var released = false
        var peakSimultaneous = 0

        init(expected: Int) { self.expected = expected }

        func arriveAndWait() async {
            arrived += 1
            peakSimultaneous = max(peakSimultaneous, arrived)
            if arrived >= expected { release() }
            if released { arrived -= 1; return }
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                if released { cont.resume(); return }
                waiters.append(cont)
            }
            arrived -= 1
        }

        func release() {
            released = true
            for w in waiters { w.resume() }
            waiters.removeAll()
        }
    }

    private func makeEstate() async throws -> LocusKit.Estate {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glk-fanout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("estate.sqlite3")
        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .sqlite(url: url, busyTimeout: 5.0)))
        return try await LocusKit.Estate.create(storage: storage, owner: Self.owner)
    }

    /// Provision `count` drawers and one active minter; returns the estate
    /// carrying exactly `count` debt pairs.
    private func estateWithDebt(pairs count: Int) async throws -> LocusKit.Estate {
        let estate = try await makeEstate()
        for i in 0..<count {
            _ = try await estate.capture(CaptureFrame(
                content: "fan-out fixture drawer \(i) — deterministic content",
                channel: .typed,
                room: "fanout-room",
                latticeAnchor: LatticeAnchor(udcCode: "004"),
                addedBy: "fanout-test",
                embeddingModelID: "no-embedding",
                lineageID: UUID()))
        }
        try await estate.registerAdornmentMinter(AdornmentMinterDescriptor(
            id: "fanout-test-minter", name: "Fan-out Test Minter",
            family: "test", modelID: "stub", modelVersion: "1",
            promptDigest: "feedface00", parameters: [:], isActive: true))
        return estate
    }

    @Test("width 4 overlaps generator calls and still mints every pair once")
    func fanOutOverlapsAndCoversAllPairs() async throws {
        let estate = try await estateWithDebt(pairs: 8)
        // 4 concurrent entrants must meet inside the resolver before any
        // completes. A serial pass would deadlock here; the 10s watchdog
        // converts that into a loud failure instead of a hang.
        let gate = Rendezvous(expected: 4)
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            await gate.release()
        }
        defer { watchdog.cancel() }

        let result = try await AdornmentPass.run(
            estate: estate,
            width: 4,
            rowBatching: false,
            generatorResolver: { minter, drawer in
                await gate.arriveAndWait()
                return "adorned:\(drawer.id):\(minter.id)"
            },
            // The injected generator serves every minter under that
            // minter's own identity, so the provenance guard admits every
            // pair whatever engine the machine resolves.
            engineIdentityResolver: { $0 },
            now: Date(timeIntervalSince1970: 1_756_500_000))

        #expect(result.adornedPairs == 8, "all 8 pairs mint; got \(result.adornedPairs)")
        #expect(result.failedPairs == 0)
        #expect(result.skippedPairs == 0)
        let peak = await gate.peakSimultaneous
        #expect(peak >= 4, "width-4 pass must overlap 4 generator calls; peak was \(peak)")
        // Coverage is exact: a second pass finds zero debt.
        let remaining = try await estate.adornmentDebtBatch(limit: 100, afterDrawerID: nil)
        #expect(remaining.isEmpty, "no debt remains after a full-coverage pass")
    }

    /// In-flight counter: tracks how many resolver calls overlap.
    private actor InFlight {
        private var current = 0
        var peak = 0
        func enter() { current += 1; peak = max(peak, current) }
        func exit() { current -= 1 }
    }

    @Test("width 1 keeps generation strictly serial")
    func widthOneStaysSerial() async throws {
        let estate = try await estateWithDebt(pairs: 6)
        let witness = InFlight()

        let result = try await AdornmentPass.run(
            estate: estate,
            width: 1,
            rowBatching: false,
            generatorResolver: { minter, drawer in
                await witness.enter()
                // A real window in which a second concurrent call would be
                // observed if the pass ever overlapped at width 1.
                try? await Task.sleep(nanoseconds: 20_000_000)
                await witness.exit()
                return "adorned:\(drawer.id):\(minter.id)"
            },
            engineIdentityResolver: { $0 },
            now: Date(timeIntervalSince1970: 1_756_500_000))

        #expect(result.adornedPairs == 6)
        let peak = await witness.peak
        #expect(peak == 1, "width-1 pass must never overlap generator calls; peak was \(peak)")
    }

    /// Provision `count` drawers and two active minters: 2 × `count` pairs.
    private func estateWithTwoMinters(drawers count: Int) async throws -> LocusKit.Estate {
        let estate = try await makeEstate()
        for i in 0..<count {
            _ = try await estate.capture(CaptureFrame(
                content: "two-engine fixture drawer \(i) — deterministic content",
                channel: .typed,
                room: "fanout-room",
                latticeAnchor: LatticeAnchor(udcCode: "004"),
                addedBy: "fanout-test",
                embeddingModelID: "no-embedding",
                lineageID: UUID()))
        }
        for id in ["engine-lane-a", "engine-lane-b"] {
            try await estate.registerAdornmentMinter(AdornmentMinterDescriptor(
                id: id, name: id, family: "test", modelID: "stub",
                modelVersion: "1", promptDigest: "feedface-\(id)",
                parameters: [:], isActive: true))
        }
        return estate
    }

    @Test("minters on distinct width-1 engines still overlap across lanes")
    func distinctEnginesOverlap() async throws {
        // The converse of the shared-engine budget (codex finding 21):
        // lanes are per engine, so two minters served by two different
        // engines run concurrently even though each engine is serial.
        // `laneEngineResolver` models the two engines by name — the
        // shipped build cannot register two engines, so the resolver is
        // the seam that pins lane membership.
        let estate = try await estateWithTwoMinters(drawers: 3)
        let gate = Rendezvous(expected: 2)
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            await gate.release()
        }
        defer { watchdog.cancel() }

        let result = try await AdornmentPass.run(
            estate: estate,
            width: 1,
            rowBatching: false,
            generatorResolver: { minter, drawer in
                await gate.arriveAndWait()
                return "adorned:\(drawer.id):\(minter.id)"
            },
            engineIdentityResolver: { $0 },
            laneEngineResolver: { "engine-for-\($0)" },
            now: Date(timeIntervalSince1970: 1_756_500_000))

        #expect(result.adornedPairs == 6)
        #expect(result.failedPairs == 0)
        let peak = await gate.peakSimultaneous
        #expect(peak >= 2, "two engine lanes must overlap; peak was \(peak)")
    }

    @Test("minters on one width-1 engine share its budget")
    func sharedEngineSharesBudget() async throws {
        // Same estate, same width, one engine identity for both minters:
        // the lane budget collapses to one in-flight call. Literal twin of
        // the grouping suite's installed-engine tests, pinned here through
        // the resolver seam alone.
        let estate = try await estateWithTwoMinters(drawers: 3)
        let witness = InFlight()

        let result = try await AdornmentPass.run(
            estate: estate,
            width: 1,
            rowBatching: false,
            generatorResolver: { minter, drawer in
                await witness.enter()
                try? await Task.sleep(nanoseconds: 20_000_000)
                await witness.exit()
                return "adorned:\(drawer.id):\(minter.id)"
            },
            engineIdentityResolver: { $0 },
            laneEngineResolver: { _ in "one-shared-engine" },
            now: Date(timeIntervalSince1970: 1_756_500_000))

        #expect(result.adornedPairs == 6)
        let peak = await witness.peak
        #expect(peak == 1, "one engine lane at width 1 must never overlap; peak was \(peak)")
    }
}
