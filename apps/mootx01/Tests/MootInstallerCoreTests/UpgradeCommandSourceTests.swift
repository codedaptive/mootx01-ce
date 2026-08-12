import Foundation
import Testing

@Suite("UpgradeCommand source invariants")
struct UpgradeCommandSourceTests {
    /// Resolve the UpgradeCommand.swift source file relative to this test file.
    private static var commandSourceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MootInstallerCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // apps/mootx01
            .appendingPathComponent("Sources/mootx01/Commands/UpgradeCommand.swift")
    }

    @Test("VACUUM failure after inventory trim reports the failure truthfully, not 'estate is unaffected'")
    func vacuumFailureMessageIsAccurate() throws {
        let source = try String(contentsOf: Self.commandSourceURL, encoding: .utf8)
        // The typed catch must exist — discriminates VACUUM failure (estate IS
        // affected, trim committed) from pre-trim errors (estate unchanged).
        #expect(source.contains("catch let err as StorageMaintenanceError"))
        // The accurate message names VACUUM as the failure site and confirms
        // the trim completed so the operator knows what happened.
        #expect(source.contains("VACUUM failed"))
        #expect(source.contains("The inventory trim completed (legacy vector keys cleared)"))
        #expect(source.contains("Freed pages are on the freelist"))
    }

    @Test("An already-current upgrade still runs the KG fact backfill")
    func currentVersionRunsKGFactBackfill() throws {
        let commandURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MootInstallerCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // apps/mootx01
            .appendingPathComponent("Sources/mootx01/Commands/UpgradeCommand.swift")
        let source = try String(contentsOf: commandURL, encoding: .utf8)

        let currentBranch = try #require(
            source.range(of: "guard let tag else {")?.lowerBound)
        let branchReturn = try #require(
            source.range(
                of: "\n                return",
                range: currentBranch..<source.endIndex)?.upperBound)
        let branch = source[currentBranch..<branchReturn]

        #expect(branch.contains("await runKGFactIdentityBackfill(home: home)"))
        #expect(branch.contains("restartAgents(home: home)"))
        #expect(branch.contains("offerEstateEncryptionIfNeeded(home: home)"))
    }
}
