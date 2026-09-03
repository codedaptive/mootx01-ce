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

    @Test("--backfill-only flag is declared in UpgradeCommand")
    func backfillOnlyFlagDeclared() throws {
        let source = try String(contentsOf: Self.commandSourceURL, encoding: .utf8)
        // The property wrapper and the flag name must both be present.
        #expect(source.contains("backfill-only"))
        #expect(source.contains("backfillOnly"))
    }

    @Test("--backfill-only branch calls only the four data-dir backfills and exits non-zero on failure")
    func backfillOnlyBranchIsHeadless() throws {
        let source = try String(contentsOf: Self.commandSourceURL, encoding: .utf8)
        // The backfillOnly branch must contain all four backfill calls in order.
        let branchStart = try #require(
            source.range(of: "if backfillOnly {")?.lowerBound)
        let branchEnd = try #require(
            source.range(of: "return\n        }\n\n        // --check:", range: branchStart..<source.endIndex)?.upperBound)
        let branch = source[branchStart..<branchEnd]
        // All four backfills must appear (runAdornmentRequiredBackfill renamed
        // to runAdornmentStoreMigration in ADORN-STORE-02 Part C).
        #expect(branch.contains("await runKGFactIdentityBackfill(home: home)"))
        #expect(branch.contains("await runAdornmentStoreMigration(home: home)"))
        #expect(branch.contains("await runSharedContentReclaimIfPending(home: home)"))
        #expect(branch.contains("await runDistilledRepresentationConvergence(home: home)"))
        // A failed step must surface as a non-zero exit for scripted callers.
        #expect(branch.contains("throw ExitCode.failure"))
        // launchd and network calls must NOT appear in the branch.
        #expect(!branch.contains("convergeDaemonBundle"))
        #expect(!branch.contains("restartAgents"))
        #expect(!branch.contains("offerEstateEncryptionIfNeeded"))
        #expect(!branch.contains("download"))
    }

    @Test("Each backfill function captures daemon state and restarts the daemon inline")
    func backfillFunctionsRestartDaemonInline() throws {
        let source = try String(contentsOf: Self.commandSourceURL, encoding: .utf8)

        // Each function must capture wasRunning before its stop call so it
        // can restart unconditionally of the caller (Finding 1 fix).
        // We verify the pattern by asserting startDaemon appears inside each
        // function body. Source-inspection is the right tool here: launchd is
        // not testable headless, but the presence of the restart call in each
        // function body is a structural invariant that can be checked statically.

        // runKGFactIdentityBackfill must contain the inline restart.
        // kgEnd anchor: the doc comment for the next function — renamed from
        // ADORN-BACKFILL to ADORN-STORE-02 in Part C.
        let kgStart = try #require(
            source.range(of: "private func runKGFactIdentityBackfill")?.lowerBound)
        let kgEnd = try #require(
            source.range(of: "/// ADORN-STORE-02 Part C:", range: kgStart..<source.endIndex)?.lowerBound)
        let kgBody = source[kgStart..<kgEnd]
        #expect(kgBody.contains("let wasRunning = LaunchAgent.isDaemonRunning()"),
                "runKGFactIdentityBackfill must capture wasRunning before the stop call")
        #expect(kgBody.contains("LaunchAgent.startDaemon(homeDirectory: home)"),
                "runKGFactIdentityBackfill must restart the daemon inline")

        // runAdornmentStoreMigration must contain the inline restart.
        // (renamed from runAdornmentRequiredBackfill in ADORN-STORE-02 Part C)
        let adStart = try #require(
            source.range(of: "private func runAdornmentStoreMigration")?.lowerBound)
        let adEnd = try #require(
            source.range(of: "/// P5 of the shared-content", range: adStart..<source.endIndex)?.lowerBound)
        let adBody = source[adStart..<adEnd]
        #expect(adBody.contains("let wasRunning = LaunchAgent.isDaemonRunning()"),
                "runAdornmentStoreMigration must capture wasRunning before the stop call")
        #expect(adBody.contains("LaunchAgent.startDaemon(homeDirectory: home)"),
                "runAdornmentStoreMigration must restart the daemon inline")

        // runSharedContentReclaimIfPending must contain the inline restart.
        let rcStart = try #require(
            source.range(of: "private func runSharedContentReclaimIfPending")?.lowerBound)
        let rcEnd = try #require(
            source.range(of: "/// CE-1.0.35-08: offer to encrypt", range: rcStart..<source.endIndex)?.lowerBound)
        let rcBody = source[rcStart..<rcEnd]
        #expect(rcBody.contains("let wasRunning = LaunchAgent.isDaemonRunning()"),
                "runSharedContentReclaimIfPending must capture wasRunning before the stop call")
        #expect(rcBody.contains("LaunchAgent.startDaemon(homeDirectory: home)"),
                "runSharedContentReclaimIfPending must restart the daemon inline")
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
