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

    private static var packageRootURL: URL {
        commandSourceURL
            .deletingLastPathComponent()   // Commands
            .deletingLastPathComponent()   // mootx01 target
            .deletingLastPathComponent()   // Sources
    }

    @Test("both product manifests compile the legacy flat-layout migration call sites")
    func productManifestsEnableFlatLayoutMigration() throws {
        for manifest in ["Package.swift", "Package.community.swift"] {
            let source = try String(
                contentsOf: Self.packageRootURL.appendingPathComponent(manifest),
                encoding: .utf8)
            #expect(source.contains(".define(\"GLK_MIGRATION_FLAT_LAYOUT_TO_CATALOG\")"),
                    "\(manifest) must compile the 1.0.x flat-layout migration call sites")
        }
    }

    @Test("fact-extraction workers use the kernel-resolved current executable")
    func factExtractionWorkersDoNotTrustArgvZero() throws {
        let commands = Self.commandSourceURL.deletingLastPathComponent()
        for name in ["DreamCommand.swift", "ServeCommand.swift"] {
            let source = try String(
                contentsOf: commands.appendingPathComponent(name), encoding: .utf8)
            #expect(!source.contains("URL(fileURLWithPath: CommandLine.arguments[0])"),
                    "\(name) must not derive a worker executable from argv[0]")
            #expect(source.contains("resolvedCurrentExecutableURL()"),
                    "\(name) must use the kernel/bundle-derived executable resolver")
        }
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

    @Test("every fresh maintenance storage opens the vector schema before the reclaim and the span backfill use it")
    func freshMaintenanceStoragesOpenTheVectorSchema() throws {
        let source = try String(contentsOf: Self.commandSourceURL, encoding: .utf8)
        // A fresh SQLiteStorage carries no table declarations; the row store
        // derives the primary key of a delete from the declared table, so the
        // vector schema must be opened before the first use of each fresh
        // connection. The open must precede the use in source order.
        let backfillOpen = try #require(
            source.range(of: "try await backfillStorage.open(schema: VectorStore.schemaDeclaration)"))
        let backfillUse = try #require(
            source.range(of: "SpanEncodeBackfill.run(\n                    storage: backfillStorage"))
        #expect(backfillOpen.upperBound <= backfillUse.lowerBound,
                "the span backfill storage is opened with the vector schema before SpanEncodeBackfill.run")
        let reclaimOpen = try #require(
            source.range(of: "try await reclaimStorage.open(schema: VectorStore.schemaDeclaration)"))
        let reclaimUse = try #require(
            source.range(of: "VectorStore(storage: reclaimStorage)"))
        #expect(reclaimOpen.upperBound <= reclaimUse.lowerBound,
                "the reclaim storage is opened with the vector schema before the VectorStore is built on it")
    }

    @Test("--backfill-only flag is declared in UpgradeCommand")
    func backfillOnlyFlagDeclared() throws {
        let source = try String(contentsOf: Self.commandSourceURL, encoding: .utf8)
        // The property wrapper and the flag name must both be present.
        #expect(source.contains("backfill-only"))
        #expect(source.contains("backfillOnly"))
    }

    @Test("--backfill-only branch calls only the eight data-dir steps, gates them on the schema step, and exits non-zero on failure")
    func backfillOnlyBranchIsHeadless() throws {
        let source = try String(contentsOf: Self.commandSourceURL, encoding: .utf8)
        // The backfillOnly branch must contain all eight steps in order.
        let branchStart = try #require(
            source.range(of: "if estateOnly {")?.lowerBound)
        let branchEnd = try #require(
            source.range(of: "return\n        }\n\n        // --check:", range: branchStart..<source.endIndex)?.upperBound)
        let branch = source[branchStart..<branchEnd]
        // The schema step gates the rest: a refused version must stop the
        // sequence before any other step can open the schema and stamp it.
        #expect(branch.contains("guard await runSchemaUpgrade(estate: estate, home: home) else { throw ExitCode.failure }"))
        #expect(branch.contains("retireLegacyEncryptionOptOut(estate: estate)"))
        #expect(branch.contains("refreshManifest(estate: estate)"))
        #expect(branch.contains("await runKGFactIdentityBackfill(estate: estate, home: home)"))
        #expect(branch.contains("await runSharedContentReclaimIfPending(estate: estate, home: home)"))
        #expect(branch.contains("await runWholeRecordVacuum(estate: estate, home: home)"))
        #expect(branch.contains("await runSSCFactsBackfill(estate: estate, home: home)"))
        #expect(branch.contains("await runDensePoolingConvergence(estate: estate, home: home)"))
        #expect(branch.contains("await runSpanEncodeBackfill(estate: estate, home: home)"))
        #expect(branch.contains("await runVectorReclaim(estate: estate, home: home)"))
        // Retired steps must not come back.
        #expect(!branch.contains("runAdornmentStoreMigration"))
        #expect(!branch.contains("runDistilledRepresentationConvergence"))
        // The whole-record vacuum is the first estate open, so the migration
        // chain runs and reports there; the shared-content reclaim follows it
        // and collects the reclaim-pending state the 1.0 → 1.1 capsule leaves;
        // the ssc facts backfill follows; the dense pooling convergence runs
        // BEFORE the span-encode step, so the latter's estate open never
        // absorbs the rebuild unreported; the vector reclaim runs last, after
        // the span rows exist.
        let schemaAt = try #require(branch.range(of: "runSchemaUpgrade(estate: estate, home: home)")?.lowerBound)
        let reclAt = try #require(branch.range(of: "await runSharedContentReclaimIfPending(estate: estate, home: home)")?.lowerBound)
        let vacuumAt = try #require(branch.range(of: "await runWholeRecordVacuum(estate: estate, home: home)")?.lowerBound)
        let factsAt = try #require(branch.range(of: "await runSSCFactsBackfill(estate: estate, home: home)")?.lowerBound)
        let denseAt = try #require(branch.range(of: "await runDensePoolingConvergence(estate: estate, home: home)")?.lowerBound)
        let spanAt = try #require(branch.range(of: "await runSpanEncodeBackfill(estate: estate, home: home)")?.lowerBound)
        let reclaimAt = try #require(branch.range(of: "await runVectorReclaim(estate: estate, home: home)")?.lowerBound)
        #expect(schemaAt < vacuumAt && vacuumAt < reclAt && reclAt < factsAt && factsAt < denseAt
                && denseAt < spanAt && spanAt < reclaimAt,
                "schema → whole-record vacuum → shared-content reclaim → ssc facts → dense pooling → span encode → vector reclaim")
        // A failed step must surface as a non-zero exit for scripted callers.
        #expect(branch.contains("throw ExitCode.failure"))
        // launchd and network calls must NOT appear in the branch.
        #expect(!branch.contains("convergeDaemonBundle"))
        #expect(!branch.contains("restartAgents"))
        #expect(!branch.contains("offerEstateEncryptionIfNeeded"))
        #expect(!branch.contains("download"))
    }

    @Test("convergence runs SSC facts after identity before projection and a second run skips its rebuild")
    func convergenceIncludesIdempotentSSCFactsBackfill() throws {
        let source = try String(contentsOf: Self.commandSourceURL, encoding: .utf8)
        let convergenceStart = try #require(source.range(of: "private func runConvergence")?.lowerBound)
        let convergenceEnd = try #require(
            source.range(of: "    // MARK: - MACD-2c2 daemon-bundle convergence", range: convergenceStart..<source.endIndex)?.lowerBound)
        let convergence = source[convergenceStart..<convergenceEnd]
        let identityAt = try #require(convergence.range(of: "await runKGFactIdentityBackfill(estate: estate, home: home)")?.lowerBound)
        let factsAt = try #require(convergence.range(of: "await runSSCFactsBackfill(estate: estate, home: home)")?.lowerBound)
        let projectionAt = try #require(convergence.range(of: "await runSearchProjectionBackfill(estate: estate, home: home)")?.lowerBound)
        #expect(identityAt < factsAt && factsAt < projectionAt,
                "convergence must run kg_facts identity -> SSC facts -> search projection")

        let factsStart = try #require(source.range(of: "private func runSSCFactsBackfill")?.lowerBound)
        let factsEnd = try #require(
            source.range(of: "    private func runVectorReclaim", range: factsStart..<source.endIndex)?.lowerBound)
        let facts = source[factsStart..<factsEnd]
        #expect(facts.contains("if written > 0 {"),
                "the first convergence run rebuilds derived lanes only when facts were written")
        #expect(facts.contains("if written == 0 {"),
                "the second convergence run must be an SSC-facts no-op")
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
            ("runSchemaUpgrade",
             "private func runSchemaUpgrade",
             "/// MXE-MI: move pre-MXE-KH"),
            ("runKGFactIdentityBackfill",
             "private func runKGFactIdentityBackfill",
             "/// Bring the trainable provider bases a populated estate carries"),
            ("runDensePoolingConvergence",
             "private func runDensePoolingConvergence",
             "/// Provider keys (`model_id@model_version`) whose part-0 basis row carries"),
            ("runSpanEncodeBackfill",
             "private func runSpanEncodeBackfill",
             "/// Models whose vector rows `mootx01 upgrade` reclaims"),
            ("runVectorReclaim",
             "private func runVectorReclaim",
             "/// P5 of the shared-content"),
            ("runSharedContentReclaimIfPending",
             "private func runSharedContentReclaimIfPending",
             "/// Fold a pre-manifest `no-encrypt` marker"),
        ]
        for step in steps {
            let start = try #require(source.range(of: step.start)?.lowerBound)
            let end = try #require(
                source.range(of: step.end, range: start..<source.endIndex)?.lowerBound)
            let body = source[start..<end]
            #expect(body.contains("ResidentDaemonQuiesce.run("),
                    "\(step.name) must route its quiesce through the shared helper")
            #expect(body.contains("estatePIDURL: estate.pidURL,"),
                    "\(step.name) must decide the quiesce from the estate's own PID marker")
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
        #expect(body.contains("ResidentDaemonQuiesce.residentServes(pidURL: estate.pidURL)"))
        #expect(body.contains("daemon: resident ? .launchd(homeDirectory: home) : .none"))
    }

    @Test("runSchemaUpgrade reads the ledger raw, decides with upgradePath, and refuses by version before any open")
    func schemaUpgradeRefusesBeforeOpening() throws {
        let source = try String(contentsOf: Self.commandSourceURL, encoding: .utf8)
        let funcStart = try #require(
            source.range(of: "private func runSchemaUpgrade")?.lowerBound)
        let funcEnd = try #require(
            source.range(of: "/// MXE-MI: move pre-MXE-KH", range: funcStart..<source.endIndex)?.lowerBound)
        let body = source[funcStart..<funcEnd]
        // The decision comes from LocusKit's gate, on the raw ledger row.
        let steps = [
            "storage.currentSchemaVersion(for: LocusKitSchema.kitID)",
            "LocusKitSchema.upgradePath(storedVersion: stored)",
            "case .unsupported(let found):",
            "schema upgrade refused",
            "case .upgrade(let from):",
            "storage.open(schema: LocusKitSchema.schema)",
        ]
        var cursor = body.startIndex
        for step in steps {
            let found = try #require(body.range(of: step, range: cursor..<body.endIndex),
                                     "missing or out of order: \(step)")
            cursor = found.upperBound
        }
        // The refusal names the version found and changes nothing.
        #expect(body.contains("nothing was changed"))
        let current = try #require(body.range(of: "case .current:")?.lowerBound)
        let currentOpen = try #require(body.range(
            of: "storage.open(schema: LocusKitSchema.schema)", range: current..<body.endIndex)?.lowerBound)
        #expect(current < currentOpen,
                "a current estate must open its declared schema so upgrade converges the ledger")
        // No ladder walk of its own: one open of the declared schema is the hop.
        #expect(!body.contains("Migration(fromVersion"))
    }

    @Test("runSpanEncodeBackfill provisions the default encoder before wiring — migration writes the activation key")
    func spanEncodeProvisionsTheDefaultEncoder() throws {
        let source = try String(contentsOf: Self.commandSourceURL, encoding: .utf8)
        let funcStart = try #require(source.range(of: "private func runSpanEncodeBackfill")?.lowerBound)
        let funcEnd = try #require(source.range(of: "/// Models whose vector rows `mootx01 upgrade` reclaims", range: funcStart..<source.endIndex)?.lowerBound)
        let body = source[funcStart..<funcEnd]
        let provisionAt = try #require(body.range(of: "kit.provisionDefaultEncoderIfAbsent(for: handle)")?.lowerBound)
        let wireAt = try #require(body.range(of: "kit.wireGLKSubstores(for: handle, backingStorage: storage)")?.lowerBound)
        #expect(provisionAt < wireAt, "the key is written before the wire so the same open activates the encoder")
    }

    @Test("span backfill repairs indexed legacy versions and writes the canonical shared version")
    func spanBackfillRepairsLegacyContentVersions() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/mootx01/Commands/SpanEncodeBackfill.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(source.contains("activeDrawersAfterStrict(id: repairCursor, limit: repairPageSize)"))
        #expect(source.contains("strictSpanVectorSnapshot("))
        #expect(source.contains("SpanContentVersion.requiresRepair("))
        #expect(source.contains("SpanContentVersion.fnv1a64(drawer.content)"))
        #expect(!source.contains("columns: [\"content_hash\"]"))
    }

    @Test("runSpanEncodeBackfill and runVectorReclaim open through the migration catalog before touching the vector tier")
    func spanEncodeAndReclaimRunTheCatalogFirst() throws {
        let source = try String(contentsOf: Self.commandSourceURL, encoding: .utf8)
        for (name, end) in [
            ("private func runSpanEncodeBackfill", "/// Models whose vector rows `mootx01 upgrade` reclaims"),
            ("private func runVectorReclaim", "/// P5 of the shared-content"),
        ] {
            let funcStart = try #require(source.range(of: name)?.lowerBound)
            let funcEnd = try #require(source.range(of: end, range: funcStart..<source.endIndex)?.lowerBound)
            let body = source[funcStart..<funcEnd]
            // The catalog moves the vector tier's ledger rows to their SynapseKit
            // ids (1.4 → 1.5) before any store below opens under the new id.
            let catalogAt = try #require(body.range(of: "GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: Date())")?.lowerBound)
            let vectorAt = try #require(
                body.range(of: name.hasSuffix("Backfill") ? "SpanEncodeBackfill.run(" : "VectorStore(storage: reclaimStorage)")?.lowerBound)
            #expect(catalogAt < vectorAt, "\(name): the catalog must run before the vector tier is touched")
        }
        // The reclaim names the retired families once, in the shared constant.
        // lsa-v1 must never appear here: LSA is a live default-ensemble signal.
        #expect(source.contains("static let retiredDenseFamilyModelIDs = [\"nmf-v1\", \"ppmi-v1\", \"fdc-v1\"]"))
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

        #expect(branch.contains("await runKGFactIdentityBackfill(estate: estate, home: home)"))
        #expect(branch.contains("restartAgents(home: home)"))
        #expect(branch.contains("offerEstateEncryptionIfNeeded(estate: estate, home: home)"))
    }
}
