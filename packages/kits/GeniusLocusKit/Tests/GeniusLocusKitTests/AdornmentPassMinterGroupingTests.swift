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
    let identity = "test:frame-stamp"
    let maxConcurrentMints = 4
    var supportsRowBatching: Bool { true }
    private let counter = FrameCounter()
    func mint(prompt: String) async -> String? { "single" }
    func mintRows(_ rows: [String], maxLength: Int) async -> [String?] {
        let frame = await counter.take()
        return rows.map { _ in "frame-\(frame)" }
    }
}

@Suite("AdornmentPass minter grouping", .serialized)
struct AdornmentPassMinterGroupingTests {

    private static let owner = OwnerCredentials(ownerIdentifier: "minter-grouping-test-owner")

    @Test("row frames never mix minters")
    func framesAreMinterHomogeneous() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glk-mgroup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: dir.appendingPathComponent("estate.sqlite3"))))
        let estate = try await LocusKit.Estate.create(storage: storage, owner: Self.owner)

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
        let result = try await AdornmentPass.run(
            estate: estate, batchSize: 100, now: Date(timeIntervalSince1970: 1_756_600_000))
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
