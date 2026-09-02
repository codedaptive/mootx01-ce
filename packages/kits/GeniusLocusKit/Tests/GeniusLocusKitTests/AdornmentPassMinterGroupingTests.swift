import AdornmentLib
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitSQLite
import Testing

@testable import GeniusLocusKit

/// A frame is ONE minter's rows: with per-minter engine routing
/// (multi-model mode), a row batch mixing minters would send one
/// minter's records through another minter's engine. This fake stamps
/// every claim with its frame's sequence number; the estate's stored
/// rows then witness that no frame ever carried two minters.
private actor FrameCounter {
    private var next = 0
    func take() -> Int { defer { next += 1 }; return next }
}

private final class FrameStampEngine: GoldMinerEngine, @unchecked Sendable {
    let identity: String
    let maxConcurrentMints = 4
    let supportsRowBatching: Bool
    private let counter = FrameCounter()
    init(identity: String = "test:frame-stamp", supportsRowBatching: Bool = true) {
        self.identity = identity
        self.supportsRowBatching = supportsRowBatching
    }
    func mint(prompt: String) async -> String? { "single" }
    func mintRows(_ rows: [String], maxLength: Int) async -> [String?] {
        let frame = await counter.take()
        return rows.map { _ in "frame-\(frame)" }
    }
}

/// In-flight witness: how many engine calls overlap at the peak.
private actor InFlight {
    private var current = 0
    var peak = 0
    func enter() { current += 1; peak = max(peak, current) }
    func exit() { current -= 1 }
}

/// A width-1 engine that witnesses its own concurrency on both
/// transports. Identity is a command name so the provenance guard admits
/// every active minter — the shape of the finding: several minters, one
/// serial command pipe. Each call holds a real window (20 ms) in which a
/// second concurrent call would register.
private final class PeakEngine: GoldMinerEngine, @unchecked Sendable {
    let identity = "command:shared-serial-pipe"
    let maxConcurrentMints = 1
    let supportsRowBatching: Bool
    let witness = InFlight()
    init(supportsRowBatching: Bool) { self.supportsRowBatching = supportsRowBatching }
    private func hold() async {
        await witness.enter()
        try? await Task.sleep(nanoseconds: 20_000_000)
        await witness.exit()
    }
    func mint(prompt: String) async -> String? {
        await hold()
        return "single-claim"
    }
    func mintRows(_ rows: [String], maxLength: Int) async -> [String?] {
        await hold()
        return rows.map { _ in "row-claim" }
    }
}

/// Serialized: every test here installs its engine into the process-wide
/// `GoldMiner.shared`, and the guard and lane tests read that slot back
/// through the pass's default `engineIdentityResolver` /
/// `laneEngineResolver`.
@Suite("AdornmentPass minter grouping", .serialized)
struct AdornmentPassMinterGroupingTests {

    private static let owner = OwnerCredentials(ownerIdentifier: "minter-grouping-test-owner")

    private func makeEstate() async throws -> LocusKit.Estate {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glk-mgroup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: dir.appendingPathComponent("estate.sqlite3"))))
        return try await LocusKit.Estate.create(storage: storage, owner: Self.owner)
    }

    @Test("row frames never mix minters")
    func framesAreMinterHomogeneous() async throws {
        let estate = try await makeEstate()

        // 7 drawers x 2 active minters = 14 pairs; with 5-row frames the
        // pairs only fit homogeneously if grouping splits per minter.
        for i in 0..<7 {
            _ = try await estate.capture(CaptureFrame(
                content: "minter grouping fixture drawer \(i)",
                channel: .typed,
                room: "mgroup-room",
                latticeAnchor: LatticeAnchor(udcCode: "004"),
                addedBy: "mgroup-test",
                embeddingModelID: "no-embedding",
                lineageID: UUID()))
        }
        for id in ["arm-a", "arm-b"] {
            try await estate.registerAdornmentMinter(AdornmentMinterDescriptor(
                id: id, name: id, family: "test", modelID: "stub",
                modelVersion: "1", promptDigest: "feedface0\(id.suffix(1))",
                parameters: [:], isActive: true))
        }

        await GoldMiner.shared.install(engine: FrameStampEngine())
        // This test models multi-model routing (each minter served by its
        // own engine) with one stand-in engine, so the provenance guard is
        // told every minter is served under its own identity; the guard
        // itself is pinned by the tests below.
        let result = try await AdornmentPass.run(
            estate: estate, batchSize: 100,
            engineIdentityResolver: { $0 },
            now: Date(timeIntervalSince1970: 1_756_600_000))
        #expect(result.adornedPairs == 14)
        #expect(result.failedPairs == 0)

        let debt = try await estate.adornmentDebtBatch(limit: 100, afterDrawerID: nil)
        #expect(debt.isEmpty, "full coverage expected")

        // Witness: every frame stamp maps to exactly one minter id.
        var minterByFrame: [String: Set<String>] = [:]
        for row in try await allDrawerAdornments(estate: estate) {
            minterByFrame[row.text, default: []].insert(row.minterID)
        }
        #expect(!minterByFrame.isEmpty)
        for (frame, minters) in minterByFrame {
            #expect(minters.count == 1,
                    "frame \(frame) carried \(minters.count) minters: \(minters)")
        }
    }

    // ── Provenance guard (codex finding 17) ───────────────────────────
    // Two active minters — the installed engine's identity and a stale
    // one (the shape an estate carries after the p1 → p2 default upgrade,
    // because registration never retoggles activation) — over one drawer.
    // The pass adorns exactly the engine's pair, skips the stale pair, and
    // the stored row carries the engine's minter id only. Literal twin of
    // the Rust `pass_persists_only_under_the_engine_identity`:
    // (adorned, failed, skipped) == (1, 0, 1). Both transports are pinned
    // — the guard runs ahead of the split, and each path is exercised with
    // the default `engineIdentityResolver` reading `GoldMiner.shared`.

    private static let engineMinter = "test-engine-p2-s1"
    private static let staleMinter = "test-engine-p1-s1"

    /// One drawer, both minters active.
    private func estateWithStaleMinter() async throws -> LocusKit.Estate {
        let estate = try await makeEstate()
        _ = try await estate.capture(CaptureFrame(
            content: "provenance guard fixture drawer",
            channel: .typed,
            room: "guard-room",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "guard-test",
            embeddingModelID: "no-embedding",
            lineageID: UUID()))
        for (id, version) in [(Self.staleMinter, "p1-s1"), (Self.engineMinter, "p2-s1")] {
            try await estate.registerAdornmentMinter(AdornmentMinterDescriptor(
                id: id, name: id, family: "test", modelID: "test-engine",
                modelVersion: version, promptDigest: "digest-\(version)",
                parameters: [:], isActive: true))
        }
        return estate
    }

    private func guardExpectations(
        _ result: AdornmentPassResult, estate: LocusKit.Estate
    ) async throws {
        #expect(result.adornedPairs == 1)
        #expect(result.failedPairs == 0)
        #expect(result.skippedPairs == 1)
        let rows = try await allDrawerAdornments(estate: estate)
        #expect(rows.count == 1)
        #expect(rows.first?.minterID == Self.engineMinter)
        // The stale pair stays in debt: clearing it is the operator's
        // deactivation, never the pass's.
        let debt = try await estate.adornmentDebtBatch(limit: 100, afterDrawerID: nil)
        #expect(debt.map(\.minter.id) == [Self.staleMinter])
    }

    @Test("row-frame path persists only under the engine's minter identity")
    func rowFramePathHonorsEngineIdentity() async throws {
        let estate = try await estateWithStaleMinter()
        await GoldMiner.shared.install(
            engine: FrameStampEngine(identity: Self.engineMinter, supportsRowBatching: true))
        let result = try await AdornmentPass.run(
            estate: estate, batchSize: 100,
            now: Date(timeIntervalSince1970: 1_756_600_000))
        try await guardExpectations(result, estate: estate)
    }

    @Test("single-record path persists only under the engine's minter identity")
    func singlePathHonorsEngineIdentity() async throws {
        let estate = try await estateWithStaleMinter()
        await GoldMiner.shared.install(
            engine: FrameStampEngine(identity: Self.engineMinter, supportsRowBatching: false))
        let result = try await AdornmentPass.run(
            estate: estate, batchSize: 100, rowBatching: false,
            now: Date(timeIntervalSince1970: 1_756_600_000))
        try await guardExpectations(result, estate: estate)
    }

    @Test("a command engine carries no minter identity and mints every active minter")
    func commandEngineIsUnguarded() async throws {
        let estate = try await estateWithStaleMinter()
        // The harness seam: identity is a command name, not a minter id,
        // so the harness owns the active set exactly — twin of the Rust
        // `pass_without_engine_identity_mints_every_active_minter`.
        await GoldMiner.shared.install(
            engine: FrameStampEngine(identity: "command:fake-minter", supportsRowBatching: false))
        let result = try await AdornmentPass.run(
            estate: estate, batchSize: 100, rowBatching: false,
            now: Date(timeIntervalSince1970: 1_756_600_000))
        #expect(result.adornedPairs == 2)
        #expect(result.skippedPairs == 0)
        let minters = try await allDrawerAdornments(estate: estate).map(\.minterID).sorted()
        #expect(minters == [Self.staleMinter, Self.engineMinter])
    }

    // ── Per-engine lane budget (codex finding 21) ─────────────────────
    // Two active minters resolve to ONE width-1 engine. The pass must
    // key its lanes by the engine, so the engine never sees two calls in
    // flight — on either transport. The default `laneEngineResolver`
    // reads `GoldMiner.shared`, so this pins the production wiring.

    /// Four drawers, two active minters: 8 pairs, one serial engine.
    private func estateSharingOneEngine() async throws -> LocusKit.Estate {
        let estate = try await makeEstate()
        for i in 0..<4 {
            _ = try await estate.capture(CaptureFrame(
                content: "shared engine fixture drawer \(i)",
                channel: .typed,
                room: "lane-room",
                latticeAnchor: LatticeAnchor(udcCode: "004"),
                addedBy: "lane-test",
                embeddingModelID: "no-embedding",
                lineageID: UUID()))
        }
        for id in ["lane-a", "lane-b"] {
            try await estate.registerAdornmentMinter(AdornmentMinterDescriptor(
                id: id, name: id, family: "test", modelID: "stub",
                modelVersion: "1", promptDigest: "lane-digest-\(id)",
                parameters: [:], isActive: true))
        }
        return estate
    }

    @Test("two minters on one width-1 engine never overlap on the single path")
    func sharedSerialEngineStaysSerialOnSinglePath() async throws {
        let estate = try await estateSharingOneEngine()
        let engine = PeakEngine(supportsRowBatching: false)
        await GoldMiner.shared.install(engine: engine)
        let result = try await AdornmentPass.run(
            estate: estate, batchSize: 100, rowBatching: false,
            now: Date(timeIntervalSince1970: 1_756_600_000))
        #expect(result.adornedPairs == 8)
        #expect(result.failedPairs == 0)
        let peak = await engine.witness.peak
        #expect(peak == 1, "one width-1 engine must never see two mints in flight; peak was \(peak)")
    }

    @Test("two minters on one width-1 engine never overlap on the row-frame path")
    func sharedSerialEngineStaysSerialOnRowFramePath() async throws {
        let estate = try await estateSharingOneEngine()
        let engine = PeakEngine(supportsRowBatching: true)
        await GoldMiner.shared.install(engine: engine)
        // Frames are per minter, so two minters mean at least two frames
        // — the frames of one lane must still run one at a time.
        let result = try await AdornmentPass.run(
            estate: estate, batchSize: 100,
            now: Date(timeIntervalSince1970: 1_756_600_000))
        #expect(result.adornedPairs == 8)
        #expect(result.failedPairs == 0)
        let peak = await engine.witness.peak
        #expect(peak == 1, "one width-1 engine must never see two frames in flight; peak was \(peak)")
    }

    /// All stored adornments across the estate, via the public surface.
    private func allDrawerAdornments(
        estate: LocusKit.Estate
    ) async throws -> [StoredAdornment] {
        var out: [StoredAdornment] = []
        for drawer in try await estate.allDrawers() {
            out.append(contentsOf: try await estate.adornments(drawerID: drawer.id))
        }
        return out
    }
}
