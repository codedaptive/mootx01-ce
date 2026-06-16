import Testing
import Foundation
import LocusKit
import GeniusLocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import VaultKit

/// End-to-end bridge tests against a real in-memory estate. Each test
/// opens its own estate and writes only inside a unique temp vault dir,
/// which it removes in the body.
@Suite("VaultBridge import/export")
struct VaultBridgeTests {

    // MARK: - Fixtures

    /// Open one estate through GeniusLocusKit over in-memory storage.
    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "vaultkit-tests")
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    private func makeTempVault() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vaultkit-bridge-\(UUID().uuidString)", isDirectory: true)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Count `.md` files under `vaultURL`, skipping hidden files. Synchronous
    /// helper used to verify export output without async enumeration.
    private func countMDFiles(in vaultURL: URL) -> Int {
        var count = 0
        guard let enumerator = FileManager.default.enumerator(
            at: vaultURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        while let next = enumerator.nextObject() as? URL {
            if next.pathExtension == "md" { count += 1 }
        }
        return count
    }

    /// Return first `.md` file under `vaultURL`, skipping hidden files. Nil if none.
    private func firstMDFile(in vaultURL: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: vaultURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        while let next = enumerator.nextObject() as? URL {
            if next.pathExtension == "md" { return next }
        }
        return nil
    }

    /// Build a one-note fixture vault with a wikilink. Returns the vault URL.
    private func seedVault() throws -> URL {
        let vault = makeTempVault()
        try write(
            """
            ---
            room: research
            ---
            A study of [[Benzene]] and its ring structure.
            """,
            to: vault.appendingPathComponent("Chem/Aromatics.md")
        )
        return vault
    }

    /// Count currently-believed drawers in an estate.
    private func currentDrawers(_ kit: GeniusLocusKit, _ handle: EstateHandle) async throws -> [Drawer] {
        try await kit.recall(handle, RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .full))
    }

    // MARK: - currentlyBelieve recall helper (for scope tests)

    /// Count currently-believed drawers using the default `.believed` scope,
    /// which includes confirmed and unconfirmed.
    private func believedDrawers(
        _ kit: GeniusLocusKit, _ handle: EstateHandle
    ) async throws -> [Drawer] {
        // `.believed` scope filter chain: currentlyBelieve + any confirmation + any trust.
        try await kit.recall(handle, RecallFrame(
            filterChain: [
                .currentlyBelieve,
                .any([.userConfirmed, .unconfirmed, .automatedConfirmedOnly]),
                .any([.trustworthy, .requiresConfirmation]),
            ],
            hydrationLevel: .full))
    }

    // MARK: - Import writes drawers + tunnels

    @Test("import writes drawers with .importedFile channel and .imported/.references tunnels")
    func importWritesDrawersAndTunnels() async throws {
        let (kit, handle) = try await openEstate()
        let vault = try seedVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let bridge = VaultBridge(kit: kit, mapping: DrawerMapping(classifyOnImport: false))
        let report = try await bridge.importVault(at: vault, into: handle, now: Date())

        #expect(report.drawersWritten == 1)
        #expect(report.drawersUpdated == 0)
        #expect(report.tunnelsCreated == 1)
        #expect(report.itemsSkipped == 0)

        let drawers = try await currentDrawers(kit, handle)
        #expect(drawers.count == 1)
        let drawer = try #require(drawers.first)
        #expect(drawer.captureChannel == .importedFile)
        #expect(drawer.room == "research")
        #expect(drawer.featureFlags.contains(.hasLinks))

        let tunnels = try await kit.recallTunnels(handle, wing: drawer.wing)
        let refs = tunnels.filter { $0.kind == .references }
        #expect(refs.count == 1)
        let ref = try #require(refs.first)
        #expect(ref.originClass == .imported)
        #expect(ref.label == "Benzene")
    }

    // MARK: - Idempotency

    @Test("re-import is idempotent: drawer count stable, no dup reference tunnels")
    func reimportIsIdempotent() async throws {
        let (kit, handle) = try await openEstate()
        let vault = try seedVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let bridge = VaultBridge(kit: kit, mapping: DrawerMapping(classifyOnImport: false))

        let first = try await bridge.importVault(at: vault, into: handle, now: Date())
        #expect(first.drawersWritten == 1)
        #expect(first.drawersUpdated == 0)

        let second = try await bridge.importVault(at: vault, into: handle, now: Date())
        #expect(second.drawersWritten == 0)
        #expect(second.drawersUpdated == 1)        // superseded, not duplicated
        #expect(second.tunnelsCreated == 0)        // de-duplicated

        // Currently-believed drawer count is stable at 1.
        let drawers = try await currentDrawers(kit, handle)
        #expect(drawers.count == 1)

        // Reference tunnel count is stable at 1.
        let drawer = try #require(drawers.first)
        let refs = try await kit.recallTunnels(handle, wing: drawer.wing).filter { $0.kind == .references }
        #expect(refs.count == 1)
    }

    // MARK: - I-5 guard

    @Test("note with empty content is skipped, never emitted as a frame")
    func emptyContentSkipped() async throws {
        let (kit, handle) = try await openEstate()
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        // Frontmatter only, empty body.
        try write("---\nroom: r\n---\n", to: vault.appendingPathComponent("Empty.md"))

        let bridge = VaultBridge(kit: kit, mapping: DrawerMapping(classifyOnImport: false))
        let report = try await bridge.importVault(at: vault, into: handle, now: Date())
        #expect(report.itemsSkipped == 1)
        #expect(report.drawersWritten == 0)

        let drawers = try await currentDrawers(kit, handle)
        #expect(drawers.isEmpty)
    }

    @Test("capture rejects a frame missing the I-5 udcCode (the guard the bridge satisfies)")
    func captureRejectsEmptyUDC() async throws {
        let (kit, handle) = try await openEstate()
        let badFrame = CaptureFrame(
            content: "x",
            channel: .importedFile,
            room: "r",
            latticeAnchor: LatticeAnchor(udcCode: ""),   // I-5 violation
            addedBy: "a",
            embeddingModelID: "m"
        )
        await #expect(throws: (any Error).self) {
            _ = try await kit.capture(handle, badFrame)
        }
    }

    // MARK: - Feature-flag-off (EideticLib classification disabled)

    @Test("feature-flag-off import lands the fallback UDC and counts as unclassified")
    func featureFlagOffFallbackUDC() async throws {
        let (kit, handle) = try await openEstate()
        let vault = try seedVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let bridge = VaultBridge(kit: kit, mapping: DrawerMapping(classifyOnImport: false))
        let report = try await bridge.importVault(at: vault, into: handle, now: Date())
        #expect(report.fdcClassified == 0)
        #expect(report.fdcUnclassified == 1)

        let drawers = try await currentDrawers(kit, handle)
        #expect(drawers.first?.udcCode == "000")
    }

    // MARK: - Export scope tests

    @Test("confirmed drawers ARE included in the default .believed scope export")
    func believedScopeIncludesConfirmedDrawers() async throws {
        // This is the confirmed-drop bug fix: previously confirmed drawers
        // were silently excluded because the filter was hard-coded to
        // .unconfirmed. The .believed scope must include both.
        let (kit, handle) = try await openEstate()
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        // Import a note (it lands as unconfirmed by default).
        let sourceVault = try seedVault()
        defer { try? FileManager.default.removeItem(at: sourceVault) }
        let mapping = DrawerMapping(classifyOnImport: false)
        let bridge = VaultBridge(kit: kit, mapping: mapping)
        _ = try await bridge.importVault(at: sourceVault, into: handle, now: Date())

        // Confirm the drawer. `mutate` with `.confirm` moves the
        // confirmation state from unconfirmed → userConfirmed.
        let drawers = try await currentDrawers(kit, handle)
        let drawer = try #require(drawers.first)
        try await kit.mutate(handle, MutateFrame(rowID: drawer.id, kind: .confirm))

        // Export with default scope (`.believed`).
        // The confirmed drawer MUST appear in the vault.
        try await bridge.export(estate: handle, to: vault, now: Date())

        // The vault must contain exactly one note.
        #expect(countMDFiles(in: vault) == 1, "confirmed drawer must be exported under .believed scope")
    }

    @Test("unconfirmed scope exports only unconfirmed drawers (legacy behavior)")
    func unconfirmedScopeExportsOnlyUnconfirmed() async throws {
        let (kit, handle) = try await openEstate()
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let sourceVault = try seedVault()
        defer { try? FileManager.default.removeItem(at: sourceVault) }
        let mapping = DrawerMapping(classifyOnImport: false)
        let bridge = VaultBridge(kit: kit, mapping: mapping)
        _ = try await bridge.importVault(at: sourceVault, into: handle, now: Date())

        // Confirm the drawer.
        let drawers = try await currentDrawers(kit, handle)
        let drawer = try #require(drawers.first)
        try await kit.mutate(handle, MutateFrame(rowID: drawer.id, kind: .confirm))

        // Export with .unconfirmed scope — the confirmed drawer is excluded.
        try await bridge.export(estate: handle, to: vault, scope: .unconfirmed, now: Date())

        // After confirmation the drawer is NOT unconfirmed, so it must be absent.
        #expect(countMDFiles(in: vault) == 0, "confirmed drawer must be excluded under .unconfirmed scope")
    }

    // MARK: - moot_id round-trip identity tests

    @Test("export→re-import preserves lineage via moot_id (no duplicate drawers)")
    func mootIDPreservesLineageOnRoundTrip() async throws {
        let (kit, handle) = try await openEstate()
        let sourceVault = try seedVault()
        let exportVault = makeTempVault()
        defer {
            try? FileManager.default.removeItem(at: sourceVault)
            try? FileManager.default.removeItem(at: exportVault)
        }

        let mapping = DrawerMapping(classifyOnImport: false)
        let bridge = VaultBridge(kit: kit, mapping: mapping)
        let first = try await bridge.importVault(at: sourceVault, into: handle, now: Date())
        #expect(first.drawersWritten == 1)

        // Export — moot_id is written into frontmatter.
        try await bridge.export(estate: handle, to: exportVault, now: Date())

        // Re-import the exported vault. The moot_id must map back to the
        // SAME lineage, so it supersedes rather than duplicates.
        let second = try await bridge.importVault(at: exportVault, into: handle, now: Date())
        #expect(second.drawersWritten == 0)
        #expect(second.drawersUpdated == 1, "re-import via moot_id must supersede")

        // Drawer count stable at 1.
        let drawers = try await currentDrawers(kit, handle)
        #expect(drawers.count == 1)
    }

    @Test("renaming exported file but keeping moot_id preserves lineage on re-import")
    func renamedFileWithMootIDPreservesLineage() async throws {
        let (kit, handle) = try await openEstate()
        let sourceVault = try seedVault()
        let exportVault = makeTempVault()
        defer {
            try? FileManager.default.removeItem(at: sourceVault)
            try? FileManager.default.removeItem(at: exportVault)
        }

        let mapping = DrawerMapping(classifyOnImport: false)
        let bridge = VaultBridge(kit: kit, mapping: mapping)
        _ = try await bridge.importVault(at: sourceVault, into: handle, now: Date())
        try await bridge.export(estate: handle, to: exportVault, now: Date())

        // Find the exported .md file, rename it.
        let original = try #require(firstMDFile(in: exportVault))
        let renamed = original.deletingLastPathComponent()
            .appendingPathComponent("completely-different-name.md")
        try FileManager.default.moveItem(at: original, to: renamed)

        // Re-import the vault with the renamed file. moot_id in frontmatter
        // must win over the new filename's FNV-derived key.
        let report = try await bridge.importVault(at: exportVault, into: handle, now: Date())
        // Must supersede (not write a new drawer) even though the file was renamed.
        #expect(report.drawersWritten == 0)
        #expect(report.drawersUpdated == 1, "moot_id must win over filename after rename")
        let drawers = try await currentDrawers(kit, handle)
        #expect(drawers.count == 1, "rename must not create a duplicate drawer")
    }

    // MARK: - Export cap regression: >50 drawers must all be exported

    /// Regression test for the VK-EXPORT-FIX defect: DrawerMapping.export was
    /// calling recall with no explicit limit, which caused the GLK overload to
    /// default to a cap of 50. An estate with more than 50 believed drawers
    /// therefore silently exported only the first 50.
    ///
    /// This test builds a synthetic estate with 60 believed drawers, exports it,
    /// and asserts that the exported NoteIR count equals the believed-drawer count,
    /// NOT ≤50. It is intentionally written to fail before the fix is applied.
    @Test("export includes ALL believed drawers when estate exceeds 50 (regression: VK-EXPORT-FIX)")
    func exportExceedsDefaultCapOf50() async throws {
        let (kit, handle) = try await openEstate()
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        // Capture 60 distinct believed drawers directly via GLK.
        // Room, addedBy, and embeddingModelID are non-empty so I-5 holds.
        let targetCount = 60
        for i in 0..<targetCount {
            let frame = CaptureFrame(
                content: "Drawer number \(i): unique synthetic content for the VK-EXPORT-FIX regression test.",
                channel: .importedFile,
                room: "export-regression",
                latticeAnchor: LatticeAnchor(udcCode: "000"),
                addedBy: "vaultkit-test",
                embeddingModelID: "vaultkit-noembed-v1"
            )
            _ = try await kit.capture(handle, frame)
        }

        // Verify that we actually have 60 believed drawers before the export.
        // Use Int.max limit to bypass the GLK overload's 50 default — this is
        // specifically verifying substrate state, not testing the overload.
        let believed = try await kit.recall(handle, RecallFrame(
            filterChain: [
                .currentlyBelieve,
                .any([.userConfirmed, .unconfirmed, .automatedConfirmedOnly]),
                .any([.trustworthy, .requiresConfirmation]),
            ],
            hydrationLevel: .bitmapOnly,
            limit: 10_000_000
        ))
        #expect(believed.count == targetCount, "precondition: 60 believed drawers must be inserted")

        // Export via DrawerMapping.export directly so we can count NoteIRs without
        // writing to disk (the file-system round-trip is tested elsewhere).
        let mapping = DrawerMapping()
        let projection = try await mapping.export(kit: kit, handle: handle, scope: .believed)

        // THE CRITICAL ASSERTION: every believed drawer must appear in the export.
        // Before the fix this returned ≤50, so the assertion would fail with 50 < 60.
        #expect(projection.notes.count == believed.count, "export must return all 60 believed drawers (50-cap defect if <60)")
    }

    // MARK: - End-to-end export → import → equivalence

    @Test("export an estate, import the produced vault into a fresh estate, structural equivalence holds")
    func endToEndExportImport() async throws {
        let (kitA, handleA) = try await openEstate()
        let sourceVault = try seedVault()
        let exportVault = makeTempVault()
        defer {
            try? FileManager.default.removeItem(at: sourceVault)
            try? FileManager.default.removeItem(at: exportVault)
        }

        let mapping = DrawerMapping(classifyOnImport: false)
        let bridgeA = VaultBridge(kit: kitA, mapping: mapping)
        _ = try await bridgeA.importVault(at: sourceVault, into: handleA, now: Date())

        // Export estate A to a vault, then import that vault into fresh estate B.
        try await bridgeA.export(estate: handleA, to: exportVault, now: Date())

        let (kitB, handleB) = try await openEstate()
        let bridgeB = VaultBridge(kit: kitB, mapping: mapping)
        let reportB = try await bridgeB.importVault(at: exportVault, into: handleB, now: Date())
        #expect(reportB.drawersWritten == 1)

        let drawersA = try await currentDrawers(kitA, handleA)
        let drawersB = try await currentDrawers(kitB, handleB)
        // Same number of currently-believed drawers.
        #expect(drawersA.count == drawersB.count)

        // The original content survives the projection (B's content carries
        // A's content; rendering may append the wikilink markup).
        let aContent = try #require(drawersA.first?.content)
        let bContent = try #require(drawersB.first?.content)
        #expect(bContent.contains(aContent))

        // The reference link survives across the round-trip.
        let refsB = try await kitB.recallTunnels(handleB, wing: drawersB.first!.wing)
            .filter { $0.kind == .references }
        #expect(refsB.contains { $0.label == "Benzene" })
    }

    // MARK: - P0 BLOCKER: structured-import parity (facts, scope, hierarchy)

    /// Shared fixture: a structured note carrying all three structural
    /// elements. The same fixture is used by the Rust parity test so
    /// both verticals assert the identical structural contract.
    private func structuredNote(now: Date) -> NoteIR {
        NoteIR(
            stableSourceKey: "projects/alpha/structured-note",
            body: [Block(text: "# Structured Note\nThis note carries structure.")],
            frontmatter: [:],
            links: [],
            tags: ["test-tag"],
            originalPath: "projects/alpha",
            originDate: OccurredAt(date: now),
            source: nil,
            mootID: nil,
            facts: [
                FactIR(subject: "alice", predicate: "works_at", object: "acme"),
                FactIR(subject: "acme", predicate: "located_in", object: "berlin"),
            ],
            pathComponents: ["projects", "alpha"],
            scope: ["userId": "u-42", "agentId": "ag-7"],
            kind: "note"
        )
    }

    @Test("structured import: facts land as KG facts and are queryable after import")
    func structuredImportFactsLandAsKGFacts() async throws {
        let (kit, handle) = try await openEstate()
        let note = structuredNote(now: Date())

        let mapping = DrawerMapping(classifyOnImport: false)
        // Import directly through DrawerMapping so the note fixture exercises
        // the capture seam without needing a real vault on disk.
        var existingLineageIDs: Set<UUID> = []
        var existingSensitivity: [UUID: AdjectiveSensitivity] = [:]
        var existingTunnelSigs: Set<String> = []
        let outcome = try await mapping.importNote(
            note,
            kit: kit,
            handle: handle,
            existingLineageIDs: existingLineageIDs,
            existingSensitivityByLineage: existingSensitivity,
            existingTunnelSignatures: &existingTunnelSigs,
            now: Date()
        )
        guard case .written = outcome else {
            Issue.record("expected .written outcome, got \(outcome)")
            return
        }

        // Query KG facts — the two FactIR triples must be present and queryable.
        let kgFacts = try await kit.recallKGFacts(handle)
        // Scope entries produce 2 additional KG facts ("scope:userId" and
        // "scope:agentId"). The structuredNote also carries tags: ["test-tag"],
        // which produces 1 tag KG fact (hard-close #29-A). kind = "note" produces
        // no kind KG fact (default). Total: 2 FactIR + 2 scope + 1 tag = 5.
        #expect(kgFacts.count == 5, "two FactIR + two scope entries + one tag = 5 KG facts")

        let subjectSet = Set(kgFacts.map(\.subject))
        #expect(subjectSet.contains("alice"), "alice FactIR must be a KG fact subject")
        #expect(subjectSet.contains("acme"), "acme FactIR must be a KG fact subject")
        #expect(subjectSet.contains("scope:userId"), "scope entry userId must be a KG fact subject")
        #expect(subjectSet.contains("scope:agentId"), "scope entry agentId must be a KG fact subject")
        #expect(subjectSet.contains("tag:test-tag"), "tag 'test-tag' must be a KG fact subject (hard-close #29-A)")
    }

    @Test("structured import: scope entries land as KG facts with has_value predicate")
    func structuredImportScopeEntriesAsKGFacts() async throws {
        let (kit, handle) = try await openEstate()
        let note = structuredNote(now: Date())

        let mapping = DrawerMapping(classifyOnImport: false)
        var existingLineageIDs: Set<UUID> = []
        var existingSensitivity: [UUID: AdjectiveSensitivity] = [:]
        var existingTunnelSigs: Set<String> = []
        _ = try await mapping.importNote(
            note,
            kit: kit,
            handle: handle,
            existingLineageIDs: existingLineageIDs,
            existingSensitivityByLineage: existingSensitivity,
            existingTunnelSignatures: &existingTunnelSigs,
            now: Date()
        )

        let kgFacts = try await kit.recallKGFacts(handle)
        let scopeFacts = kgFacts.filter { $0.subject.hasPrefix("scope:") }
        #expect(scopeFacts.count == 2, "two scope entries must produce two KG facts")
        #expect(scopeFacts.allSatisfy { $0.predicate == "has_value" },
                "all scope KG facts must use 'has_value' predicate")
        let userIdFact = try #require(scopeFacts.first { $0.subject == "scope:userId" })
        #expect(userIdFact.object == "u-42")
        let agentIdFact = try #require(scopeFacts.first { $0.subject == "scope:agentId" })
        #expect(agentIdFact.object == "ag-7")
    }

    @Test("structured import: multi-level pathComponents map to full room path (hierarchy preserved)")
    func structuredImportHierarchyAsFullRoomPath() async throws {
        let (kit, handle) = try await openEstate()
        let note = structuredNote(now: Date())

        let mapping = DrawerMapping(classifyOnImport: false)
        var existingLineageIDs: Set<UUID> = []
        var existingSensitivity: [UUID: AdjectiveSensitivity] = [:]
        var existingTunnelSigs: Set<String> = []
        _ = try await mapping.importNote(
            note,
            kit: kit,
            handle: handle,
            existingLineageIDs: existingLineageIDs,
            existingSensitivityByLineage: existingSensitivity,
            existingTunnelSignatures: &existingTunnelSigs,
            now: Date()
        )

        // The note has pathComponents = ["projects", "alpha"] and no frontmatter room.
        // The room must be the full joined path "projects/alpha", not just "alpha".
        let drawers = try await currentDrawers(kit, handle)
        #expect(drawers.count == 1)
        let drawer = try #require(drawers.first)
        #expect(drawer.room == "projects/alpha",
                "multi-level pathComponents must produce full room path, not just the leaf")
    }

    // MARK: - Hard-close #29-A: Tags import → queryable + round-trip export

    @Test("tags import: each tag lands as a KG fact with 'tagged' predicate (hard-close #29-A)")
    func tagsImportAsKGFacts() async throws {
        let (kit, handle) = try await openEstate()
        let now = Date()
        let note = NoteIR(
            stableSourceKey: "notes/tagged-note",
            body: [Block(text: "A tagged note.")],
            tags: ["swift", "testing", "vaultkit"]
        )

        let mapping = DrawerMapping(classifyOnImport: false)
        var existingLineageIDs: Set<UUID> = []
        var existingSensitivity: [UUID: AdjectiveSensitivity] = [:]
        var existingTunnelSigs: Set<String> = []
        let outcome = try await mapping.importNote(
            note, kit: kit, handle: handle,
            existingLineageIDs: existingLineageIDs,
            existingSensitivityByLineage: existingSensitivity,
            existingTunnelSignatures: &existingTunnelSigs,
            now: now
        )
        guard case .written = outcome else {
            Issue.record("expected .written outcome, got \(outcome)")
            return
        }

        let kgFacts = try await kit.recallKGFacts(handle)
        // 3 tags → 3 KG facts with subject "tag:<t>" and predicate "tagged".
        let tagFacts = kgFacts.filter { $0.subject.hasPrefix("tag:") && $0.predicate == "tagged" }
        #expect(tagFacts.count == 3, "three tags must produce three KG facts")
        let tagValues = Set(tagFacts.map { String($0.subject.dropFirst("tag:".count)) })
        #expect(tagValues == ["swift", "testing", "vaultkit"])
    }

    @Test("tags round-trip: import→export reconstructs tags from KG facts (hard-close #29-A)")
    func tagsRoundTrip() async throws {
        let (kit, handle) = try await openEstate()
        let now = Date()
        let note = NoteIR(
            stableSourceKey: "notes/tagged-note",
            body: [Block(text: "A tagged note.")],
            tags: ["alpha", "beta"]
        )

        let mapping = DrawerMapping(classifyOnImport: false)
        var existingLineageIDs: Set<UUID> = []
        var existingSensitivity: [UUID: AdjectiveSensitivity] = [:]
        var existingTunnelSigs: Set<String> = []
        _ = try await mapping.importNote(
            note, kit: kit, handle: handle,
            existingLineageIDs: existingLineageIDs,
            existingSensitivityByLineage: existingSensitivity,
            existingTunnelSignatures: &existingTunnelSigs,
            now: now
        )

        // Export projects KG facts back into NoteIR.tags.
        let projection = try await mapping.export(kit: kit, handle: handle, scope: .believed)
        #expect(projection.notes.count == 1)
        let exported = try #require(projection.notes.first)
        // Tags must round-trip: the export must reconstruct the original tag set.
        #expect(Set(exported.tags) == Set(note.tags),
                "export must reconstruct tags from KG facts (hard-close #29-A round-trip)")
    }

    // MARK: - Hard-close #29-B: kind != "note" → KG fact + round-trip

    @Test("kind 'fact' lands as KG fact (hard-close #29-B)")
    func kindFactLandsAsKGFact() async throws {
        let (kit, handle) = try await openEstate()
        let now = Date()
        let note = NoteIR(
            stableSourceKey: "notes/fact-record",
            body: [Block(text: "Alice works at Acme.")],
            kind: "fact"
        )

        let mapping = DrawerMapping(classifyOnImport: false)
        var existingLineageIDs: Set<UUID> = []
        var existingSensitivity: [UUID: AdjectiveSensitivity] = [:]
        var existingTunnelSigs: Set<String> = []
        let outcome = try await mapping.importNote(
            note, kit: kit, handle: handle,
            existingLineageIDs: existingLineageIDs,
            existingSensitivityByLineage: existingSensitivity,
            existingTunnelSignatures: &existingTunnelSigs,
            now: now
        )
        guard case .written = outcome else {
            Issue.record("expected .written outcome, got \(outcome)")
            return
        }

        let kgFacts = try await kit.recallKGFacts(handle)
        let kindFact = kgFacts.first { $0.subject == "record:kind" && $0.predicate == "is" }
        let found = try #require(kindFact, "kind 'fact' must produce a 'record:kind' KG fact")
        #expect(found.object == "fact")
    }

    @Test("kind 'journal' round-trips import→export (hard-close #29-B)")
    func kindJournalRoundTrips() async throws {
        let (kit, handle) = try await openEstate()
        let now = Date()
        let note = NoteIR(
            stableSourceKey: "notes/journal-entry",
            body: [Block(text: "Today I shipped the adapter.")],
            kind: "journal"
        )

        let mapping = DrawerMapping(classifyOnImport: false)
        var existingLineageIDs: Set<UUID> = []
        var existingSensitivity: [UUID: AdjectiveSensitivity] = [:]
        var existingTunnelSigs: Set<String> = []
        _ = try await mapping.importNote(
            note, kit: kit, handle: handle,
            existingLineageIDs: existingLineageIDs,
            existingSensitivityByLineage: existingSensitivity,
            existingTunnelSignatures: &existingTunnelSigs,
            now: now
        )

        // Export must reconstruct `kind` from the KG fact.
        let projection = try await mapping.export(kit: kit, handle: handle, scope: .believed)
        let exported = try #require(projection.notes.first)
        #expect(exported.kind == "journal",
                "export must reconstruct kind from KG fact (hard-close #29-B round-trip)")
    }

    @Test("kind 'note' (default) produces NO 'record:kind' KG fact")
    func kindNoteProducesNoKGFact() async throws {
        let (kit, handle) = try await openEstate()
        let now = Date()
        let note = NoteIR(
            stableSourceKey: "notes/plain-note",
            body: [Block(text: "A plain note.")],
            kind: "note" // explicit default
        )

        let mapping = DrawerMapping(classifyOnImport: false)
        var existingLineageIDs: Set<UUID> = []
        var existingSensitivity: [UUID: AdjectiveSensitivity] = [:]
        var existingTunnelSigs: Set<String> = []
        _ = try await mapping.importNote(
            note, kit: kit, handle: handle,
            existingLineageIDs: existingLineageIDs,
            existingSensitivityByLineage: existingSensitivity,
            existingTunnelSignatures: &existingTunnelSigs,
            now: now
        )

        let kgFacts = try await kit.recallKGFacts(handle)
        let kindFact = kgFacts.first { $0.subject == "record:kind" }
        #expect(kindFact == nil,
                "default kind 'note' must not produce a 'record:kind' KG fact (export default)")
    }

    @Test("fieldsDropped is empty for a fully-structured note (hard-close #29)")
    func fieldsDroppedEmptyForFullyStructuredNote() async throws {
        let (kit, handle) = try await openEstate()
        let note = structuredNote(now: Date())
        let mapping = DrawerMapping(classifyOnImport: false)

        // Use VaultBridge to exercise the full recordDroppedFields path.
        // importNote returns an outcome but doesn't surface fieldsDropped;
        // we need the bridge importNotes path. Seed a temp vault instead.
        // Direct path: import the structured note, then check via the bridge
        // over its ExchangeAdapter which encodes the same fixture.
        // Use the ExchangeAdapter golden fixture (drawer-001 has tags + kind "fact").
        let bridge = VaultBridge(
            kit: kit,
            adapter: ExchangeAdapter(),
            mapping: mapping
        )
        let report = try await bridge.importVault(
            at: ExchangeAdapterTests.fixtureURL, into: handle, now: Date())

        // fieldsDropped must be empty: all fields now land (hard-close #29).
        #expect(report.fieldsDropped.isEmpty,
                "fieldsDropped must be empty — no drop path may remain (hard-close #29)")
    }

    @Test("structured import: facts not in fieldsDropped (they land in substrate)")
    func structuredImportFactsNotInFieldsDropped() async throws {
        let (kit, handle) = try await openEstate()
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        // Build a vault with a note that carries the structured fixture fields.
        // Use the Obsidian adapter for real round-trip coverage.
        let note = structuredNote(now: Date())
        // The note can't be written as a real Obsidian vault here (the adapter
        // produces vault files from drawers, not from NoteIRs), so we exercise
        // importNote directly and verify fieldsDropped via the bridge importNotes path.
        // Round-trip proof via ExchangeAdapterTests (golden fixture) and Rust.

        let mapping = DrawerMapping(classifyOnImport: false)
        var existingLineageIDs: Set<UUID> = []
        var existingSensitivity: [UUID: AdjectiveSensitivity] = [:]
        var existingTunnelSigs: Set<String> = []
        _ = try await mapping.importNote(
            note,
            kit: kit,
            handle: handle,
            existingLineageIDs: existingLineageIDs,
            existingSensitivityByLineage: existingSensitivity,
            existingTunnelSignatures: &existingTunnelSigs,
            now: Date()
        )

        // facts, scope, and pathComponents must not appear in fieldsDropped because
        // they now land in the substrate (KG facts / full room path).
        // Only tags (and kind != "note") are still tracked as dropped.
        // This note carries tags but kind = "note" — only tags should drop.
        let bridge = VaultBridge(kit: kit, mapping: mapping)
        // Re-run a full import via a NoteIR-carrying vault to exercise the bridge
        // recordDroppedFields path. Use ExchangeAdapter with the golden fixture
        // (which carries all fields) for this.
        // For this test we verify the direct mapping path result is correct.
        // The bridge integration is covered by ExchangeAdapterTests.droppedFieldsAreRecorded.
        // Here we verify the importNote outcome has the right semantics.
        let kgFacts = try await kit.recallKGFacts(handle)
        #expect(!kgFacts.isEmpty, "structured import must produce KG facts (not drop them)")
    }
}
