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

    @Test("Each backfill function routes its daemon quiesce through ResidentDaemonQuiesce")
    func backfillFunctionsQuiesceThroughTheSharedHelper() throws {
        let source = try String(contentsOf: Self.commandSourceURL, encoding: .utf8)

        // Source inspection is the right tool here: launchd is not testable
        // headless, but "every step goes through the one helper, and none
        // reaches launchd on its own" is a structural invariant that can be
        // checked statically. The helper itself is covered by
        // ResidentDaemonQuiesceTests with a recording daemon control.
        //
        // Each step is bounded by its own declaration and the doc comment
        // of the function that follows it in the file.
        let steps: [(name: String, start: String, end: String)] = [
            ("runKGFactIdentityBackfill",
             "private func runKGFactIdentityBackfill",
             "/// Bring every drawer's stored distilled representation up to the active"),
            ("runDistilledRepresentationConvergence",
             "private func runDistilledRepresentationConvergence",
             "/// ADORN-STORE-02 Part C:"),
            ("runAdornmentStoreMigration",
             "private func runAdornmentStoreMigration",
             "/// P5 of the shared-content"),
            ("runSharedContentReclaimIfPending",
             "private func runSharedContentReclaimIfPending",
             "/// CE-1.0.35-08: offer to encrypt"),
        ]
        for step in steps {
            let start = try #require(source.range(of: step.start)?.lowerBound)
            let end = try #require(
                source.range(of: step.end, range: start..<source.endIndex)?.lowerBound)
            let body = source[start..<end]
            #expect(body.contains("ResidentDaemonQuiesce.run("),
                    "\(step.name) must route its quiesce through the shared helper")
            #expect(body.contains("residentDataDirectory: MootPaths.residentDataDirectory(homeDirectory: home)"),
                    "\(step.name) must compare against the resident data directory")
            #expect(body.contains("daemon: .launchd(homeDirectory: home)"),
                    "\(step.name) must hand the helper the launchd seam")
            #expect(!body.contains("LaunchAgent.isDaemonRunning"),
                    "\(step.name) must not query launchd on its own")
            #expect(!body.contains("LaunchAgent.stopDaemon"),
                    "\(step.name) must not stop the daemon on its own")
            #expect(!body.contains("LaunchAgent.startDaemon"),
                    "\(step.name) must not start the daemon on its own")
        }
        // The command reaches launchd only through the helper's seam.
        #expect(!source.contains("LaunchAgent.stopDaemon"))
        #expect(!source.contains("LaunchAgent.startDaemon"))
    }

    @Test("The encryption migration selects the launchd seam only for the resident estate")
    func encryptionMigrationSelectsDaemonControlByPredicate() throws {
        let source = try String(contentsOf: Self.commandSourceURL, encoding: .utf8)
        let start = try #require(
            source.range(of: "private func runEstateEncryptionMigration")?.lowerBound)
        let end = try #require(
            source.range(of: "/// See the call site's doc comment. The gating", range: start..<source.endIndex)?.lowerBound)
        let body = source[start..<end]
        #expect(body.contains("MootPaths.isResidentEstate("))
        #expect(body.contains("daemon: resident ? .launchd(homeDirectory: home) : .none"))
    }

    @Test("runDistilledRepresentationConvergence uses two-key eligibility gate")
    func distilledRepresentationUseTwoKeyGate() throws {
        let source = try String(contentsOf: Self.commandSourceURL, encoding: .utf8)
        // Locate the runDistilledRepresentationConvergence function body.
        let funcStart = try #require(
            source.range(of: "private func runDistilledRepresentationConvergence")?.lowerBound)
        // The next private func starts the ADORN-STORE migration section; use it as the end anchor.
        let funcEnd = try #require(
            source.range(of: "/// ADORN-STORE-02 Part C:", range: funcStart..<source.endIndex)?.lowerBound)
        let body = source[funcStart..<funcEnd]
        // Both eligibility keys must appear in the function body.
        #expect(body.contains("distilledRepresentationsAwaitingReindex(handle: handle)"),
                "second eligibility key: awaiting-reindex count must be fetched")
        // The gate must check both keys with a logical-or.
        #expect(body.contains("regenerated > 0 || awaiting > 0"),
                "gate must fire on regenerated OR awaiting")
        // The crash-recovery branch message must be present.
        #expect(body.contains("index gap detected"),
                "crash-recovery message must name the detected gap")
    }

    @Test("runDistilledRepresentationConvergence prints the active converter id and runs the sweep, probe, reindex call tree")
    func distilledRepresentationConvergencePrintsActiveConverter() throws {
        let source = try String(contentsOf: Self.commandSourceURL, encoding: .utf8)
        let funcStart = try #require(
            source.range(of: "private func runDistilledRepresentationConvergence")?.lowerBound)
        let funcEnd = try #require(
            source.range(of: "/// ADORN-STORE-02 Part C:", range: funcStart..<source.endIndex)?.lowerBound)
        let body = source[funcStart..<funcEnd]
        // The printed converter is the kit constant, never a literal: the CLI
        // reports whatever converter GeniusLocusKit activates.
        #expect(body.contains("already at converter \\(GeniusLocusKit.distillationConverterID)"))
        #expect(body.contains("regenerated at converter \\(GeniusLocusKit.distillationConverterID)"))
        #expect(!body.contains("intent-span-v2"), "the command must not name a converter literally")
        // The call tree, in order: catalog (carries the 1.3 capsule), substores,
        // eligibility sweep, awaiting-reindex probe, reindex.
        let steps = [
            "GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: Date())",
            "kit.wireGLKSubstores(for: handle, backingStorage: storage)",
            "kit.distillItemsSweep(",
            "kit.distilledRepresentationsAwaitingReindex(handle: handle)",
            "kit.reindexCorpus(handle: handle, now: now)",
        ]
        var cursor = body.startIndex
        for step in steps {
            let found = try #require(body.range(of: step, range: cursor..<body.endIndex),
                                     "missing or out of order: \(step)")
            cursor = found.upperBound
        }
        // The upgrade command adds no migration step of its own for the digest
        // column: no capsule or ladder call outside the catalog.
        #expect(!body.contains("runDistilledSourceDigestColumnMigration"))
        #expect(!body.contains("LocusKitSchema.schema"))
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
