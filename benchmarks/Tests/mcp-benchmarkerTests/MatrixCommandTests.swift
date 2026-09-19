// MatrixCommandTests.swift — the Swift half of the matrix cross-port gate.
//
// The same seven behaviours are pinned in `rust/src/matrix_command.rs`. The
// pure functions are what the two ports must agree on: which rows get probed,
// and what counts as a divergence between two cells. If either drifts, the two
// ports stop measuring the same thing.

import Testing
import Foundation
import EstateEncryption
@testable import mcp_benchmarker

@Suite("Matrix command")
struct MatrixCommandTests {

    private func ids(_ n: Int) -> [String] {
        (0..<n).map { String(format: "id-%03d", $0) }
    }

    /// The sample is a stride across ingest order, not a prefix: a prefix would
    /// probe only the oldest rows.
    @Test("probe selection spreads across the manifest")
    func probeSelectionSpreads() {
        let picked = matrixProbeIDs(manifestUUIDs: ids(100), sampleSize: 5)
        #expect(picked == ["id-000", "id-020", "id-040", "id-060", "id-080"])
    }

    @Test("probe selection is deterministic")
    func probeSelectionIsDeterministic() {
        #expect(matrixProbeIDs(manifestUUIDs: ids(100), sampleSize: 7)
                == matrixProbeIDs(manifestUUIDs: ids(100), sampleSize: 7))
    }

    /// A manifest smaller than the sample is taken whole rather than padded.
    @Test("a small manifest is taken whole")
    func smallManifestTakenWhole() {
        #expect(matrixProbeIDs(manifestUUIDs: ids(3), sampleSize: 10) == ids(3))
        #expect(matrixProbeIDs(manifestUUIDs: [], sampleSize: 10).isEmpty)
        #expect(matrixProbeIDs(manifestUUIDs: ids(10), sampleSize: 0).isEmpty)
    }

    private func result(_ lists: [[String]]) -> MatrixQueryResult {
        MatrixQueryResult(probes: lists.count, found: 0, foundAtOne: 0, resultIDs: lists)
    }

    /// Divergence counts probes whose ranked list differs, including reordering
    /// that a scalar recall comparison would hide.
    @Test("divergence counts reordering, not just membership")
    func divergenceCountsReordering() {
        let a = result([["x", "y"], ["p", "q"]])
        let same = result([["x", "y"], ["p", "q"]])
        let reordered = result([["y", "x"], ["p", "q"]])
        #expect(matrixCellDivergence(a, same) == 0)
        #expect(matrixCellDivergence(a, reordered) == 1)
    }

    @Test("divergence on mismatched lengths reports the larger")
    func divergenceMismatchedLengths() {
        #expect(matrixCellDivergence(result([["x"]]), result([["x"], ["y"]])) == 2)
    }

    @Test("self recall is zero for no probes")
    func selfRecallZeroForNoProbes() {
        let empty = result([])
        #expect(empty.selfRecall == 0.0)
        #expect(empty.selfRecallAtOne == 0.0)
    }

    /// The key is a pure function of the seed and is 32 bytes, which is what
    /// the cipher requires.
    @Test("matrix key is deterministic and 32 bytes")
    func matrixKeyShape() {
        #expect(matrixKey(seed: 7).count == 32)
        #expect(matrixKey(seed: 7) == matrixKey(seed: 7))
        #expect(matrixKey(seed: 7) != matrixKey(seed: 8))
    }

    private func scratchDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("matrix-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    #if MOOTX01_HARNESS_KEYFILE
    /// The key the harness hands the server is the key it converted with. A
    /// round trip that returned anything else would open the database with the
    /// wrong key and read as corruption.
    @Test("install key round-trips")
    func installKeyRoundTrips() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let key = matrixKey(seed: 11)
        try EstateEncryptionMigrator.writeInstallKey(key, inDirectory: dir)
        #expect(try EstateEncryptionMigrator.loadOrCreateInstallKey(inDirectory: dir) == key)
    }

    /// Writing replaces rather than honours an existing file. A key left by an
    /// earlier cell is not the key this database was converted with.
    @Test("writing an install key replaces an earlier one")
    func installKeyWriteReplaces() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try EstateEncryptionMigrator.writeInstallKey(matrixKey(seed: 1), inDirectory: dir)
        let second = matrixKey(seed: 2)
        try EstateEncryptionMigrator.writeInstallKey(second, inDirectory: dir)
        #expect(try EstateEncryptionMigrator.loadOrCreateInstallKey(inDirectory: dir) == second)
    }

    /// A file of the wrong length is tampered, not a prompt to regenerate:
    /// regenerating would leave every database encrypted under the real key
    /// permanently unopenable.
    @Test("a malformed install key fails loud")
    func malformedInstallKeyFailsLoud() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data([1, 2, 3]).write(to: EstateEncryptionMigrator.installKeyURL(inDirectory: dir))
        #expect(throws: EstateEncryptionMigrator.MigrationError.self) {
            try EstateEncryptionMigrator.loadOrCreateInstallKey(inDirectory: dir)
        }
    }

    /// Created owner-only, so a key sitting in a shared temp directory is not
    /// readable by other users on the machine.
    @Test("a created install key is owner-only and 32 bytes")
    func createdInstallKeyIsOwnerOnly() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let key = try EstateEncryptionMigrator.loadOrCreateInstallKey(inDirectory: dir)
        #expect(key.count == EstateEncryptionMigrator.installKeyByteCount)

        let path = EstateEncryptionMigrator.installKeyURL(inDirectory: dir).path
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        #expect(mode?.int16Value == 0o600)

        // A second call returns the SAME key rather than minting a new one.
        #expect(try EstateEncryptionMigrator.loadOrCreateInstallKey(inDirectory: dir) == key)
    }
    #endif
}
