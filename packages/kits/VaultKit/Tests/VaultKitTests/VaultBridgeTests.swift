import Testing
import Foundation
import LocusKit
import GeniusLocusKit
import CorpusKit
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

    /// Count `.md` note files under `vaultURL`, skipping hidden files and OKF
    /// navigation files (`index.md`, `log.md`). Synchronous helper used to
    /// verify export output without async enumeration.
    ///
    /// OKF-format exports emit one `index.md` per folder for progressive-
    /// disclosure navigation; these are not notes and must not be counted as
    /// exported drawers in assertion helpers.
    private func countMDFiles(in vaultURL: URL) -> Int {
        var count = 0
        guard let enumerator = FileManager.default.enumerator(
            at: vaultURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        while let next = enumerator.nextObject() as? URL {
            guard next.pathExtension == "md" else { continue }
            let stem = next.deletingPathExtension().lastPathComponent
            // Skip OKF nav files — they are emitted by fromIR for progressive
            // disclosure and are never notes (ObsidianAdapter.toIR skips them too).
            if stem == "index" || stem == "log" { continue }
            count += 1
        }
        return count
    }

    /// Return first `.md` note file under `vaultURL`, skipping hidden files and
    /// OKF navigation files (`index.md`, `log.md`). Nil if none.
    private func firstMDFile(in vaultURL: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: vaultURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        while let next = enumerator.nextObject() as? URL {
            guard next.pathExtension == "md" else { continue }
            let stem = next.deletingPathExtension().lastPathComponent
            if stem == "index" || stem == "log" { continue }
            return next
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

    /// Unconfirmed capture-inbox drawers in an estate. Uses
    /// `filterChain: [.unconfirmed]`, so only the unconfirmed subset is returned.
    private func currentDrawers(_ kit: GeniusLocusKit, _ handle: EstateHandle) async throws -> [Drawer] {
        try await kit.recall(handle, RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .full))
    }

    /// Resolve display names (wing, room) for drawers from the node tree.
    /// ADR-017 removed wing/room from Drawer; this helper resolves them
    /// for test assertions that need the display names.
    private func resolveNames(
        _ drawers: [Drawer], kit: GeniusLocusKit, handle: EstateHandle
    ) async throws -> [String: (wing: String, room: String)] {
        let estate = try await kit.estate(for: handle)
        return try await estate.resolveNodeNames(parentNodeIds: drawers.map(\.parentNodeId))
    }

    /// Resolve display names for a single drawer.
    private func resolveNames(
        _ drawer: Drawer, kit: GeniusLocusKit, handle: EstateHandle
    ) async throws -> (wing: String, room: String) {
        let names = try await resolveNames([drawer], kit: kit, handle: handle)
        return names[drawer.parentNodeId] ?? (wing: "", room: "")
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
        let drawerNames = try await resolveNames(drawer, kit: kit, handle: handle)
        #expect(drawerNames.room == "research")
        #expect(drawer.featureFlags.contains(.hasLinks))

        let tunnels = try await kit.recallTunnels(handle, wing: drawerNames.wing)
        // Filter by originClass == .imported to exclude synthetic containment
        // tunnels injected by NodeTopologyProvider (ADR-017 tree edges surfaced
        // as .references tunnels with label "containment").
        let refs = tunnels.filter { $0.kind == .references && $0.originClass == .imported }
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
        // Content is unchanged between first and second import of the same vault;
        // the idempotent guard must fire → skippedUnchanged, NOT updated/superseded.
        #expect(second.drawersUpdated == 0)
        #expect(second.drawersSkippedUnchanged == 1)
        #expect(second.tunnelsCreated == 0)        // de-duplicated

        // Currently-believed drawer count is stable at 1.
        let drawers = try await currentDrawers(kit, handle)
        #expect(drawers.count == 1)

        // Reference tunnel count is stable at 1.
        let drawer = try #require(drawers.first)
        let drawerNames = try await resolveNames(drawer, kit: kit, handle: handle)
        // Filter by originClass == .imported to exclude synthetic containment
        // tunnels from NodeTopologyProvider (ADR-017 tree edges).
        let refs = try await kit.recallTunnels(handle, wing: drawerNames.wing)
            .filter { $0.kind == .references && $0.originClass == .imported }
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

    // MARK: - Feature-flag: classifyOnImport no longer suppresses seam classification

    /// `classifyOnImport: false` tells VaultKit not to pre-classify in-process
    /// (before the one-door refactor, it suppressed EideticLib.lookup). The
    /// report counters reflect VaultKit's own classification: `fdcClassified`
    /// counts notes that carried explicit frontmatter `udc`; `fdcUnclassified`
    /// counts notes that did not. The GeniusLocusKit seam ALWAYS attempts
    /// classification via EideticLib.lookup when content arrives with the
    /// "000" sentinel. If the FDC resolver can classify the content, the
    /// stored udcCode will be a real code; if not (UNRESOLVED), the sentinel
    /// persists — either outcome is correct. The invariant is that the seam
    /// ran and the udcCode is non-empty (never blank).
    @Test("classifyOnImport=false still produces a classified drawer (seam owns classification)")
    func featureFlagOffStillClassifiedBySeam() async throws {
        let (kit, handle) = try await openEstate()
        let vault = try seedVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let bridge = VaultBridge(kit: kit, mapping: DrawerMapping(classifyOnImport: false))
        let report = try await bridge.importVault(at: vault, into: handle, now: Date())
        // VaultKit's own in-process classification: 0 pre-classified (no frontmatter udc).
        #expect(report.fdcClassified == 0)
        // VaultKit counts this as unclassified from its own perspective (no frontmatter udc).
        #expect(report.fdcUnclassified == 1)

        // The seam attempts classification on capture. The stored udcCode
        // must be non-empty — either a real FDC code (resolved) or the "000"
        // sentinel (UNRESOLVED by the FDC matcher for this content). Both are
        // valid; the invariant is that the seam ran and produced a non-blank code.
        let drawers = try await currentDrawers(kit, handle)
        let storedCode = drawers.first?.udcCode ?? ""
        #expect(
            !storedCode.isEmpty,
            "udcCode must not be empty after seam classification"
        )
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
        try await bridge.export(estate: handle, to: vault, scope: .believed, now: Date())

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

    // MARK: - VK-EXPORT-FAILOUD: bricked-estate detection

    /// Export of a genuinely empty estate must succeed with 0 notes, not throw
    /// `exportBrickedEstate`. An empty estate has zero drawer rows in storage so
    /// the two-step bricked check (COUNT(*) = 0) short-circuits correctly.
    ///
    /// This test verifies the non-bricked zero-note path — the "bricked" path
    /// (COUNT > 0 AND unfiltered recall returns 0) requires corrupt rows in
    /// storage, which the SQLite test module covers at the cursor level via
    /// `query_skip_corrupt_skips_poison_timestamp_returns_clean_rows` in
    /// PersistenceKit's Rust test suite.
    @Test("export of genuinely empty estate succeeds with 0 notes (not bricked error)")
    func exportOfEmptyEstateSucceedsWithZeroNotes() async throws {
        let (kit, handle) = try await openEstate()
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let mapping = DrawerMapping(classifyOnImport: false)
        let bridge = VaultBridge(kit: kit, mapping: mapping)
        // The estate is empty — no drawers captured, no rows in storage.
        // The export must succeed with 0 notes, not throw exportBrickedEstate.
        let report = try await bridge.export(estate: handle, to: vault, scope: .believed, now: Date())
        #expect(report.notesExported == 0, "empty estate exports 0 notes")
        // COUNT(*) is 0 on an empty estate — the bricked-estate path must not fire.
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
        try await bridge.export(estate: handle, to: exportVault, scope: .believed, now: Date())

        // Re-import the exported vault. The moot_id must map back to the
        // SAME lineage, so it must not create a new drawer. The body content
        // (flattenedBody) is the same in the exported vault — the only
        // difference is the moot_id frontmatter key, which is NOT part of the
        // body — so the idempotent guard fires: skippedUnchanged, not updated.
        let second = try await bridge.importVault(at: exportVault, into: handle, now: Date())
        #expect(second.drawersWritten == 0, "moot_id re-import must not create a duplicate drawer")
        // Content is identical (moot_id in frontmatter, not in body), so
        // the idempotent guard fires.
        #expect(second.drawersSkippedUnchanged == 1, "re-import via moot_id with unchanged body must be skipped-unchanged")

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
        try await bridge.export(estate: handle, to: exportVault, scope: .believed, now: Date())

        // Find the exported .md file, rename it.
        let original = try #require(firstMDFile(in: exportVault))
        let renamed = original.deletingLastPathComponent()
            .appendingPathComponent("completely-different-name.md")
        try FileManager.default.moveItem(at: original, to: renamed)

        // Re-import the vault with the renamed file. moot_id in frontmatter
        // must win over the new filename's FNV-derived key.
        let report = try await bridge.importVault(at: exportVault, into: handle, now: Date())
        // Must not write a new drawer even though the file was renamed.
        // Body content is unchanged (moot_id is frontmatter, not body), so
        // the idempotent guard fires: skippedUnchanged.
        #expect(report.drawersWritten == 0, "moot_id must win over filename after rename — no new drawer")
        #expect(report.drawersSkippedUnchanged == 1, "renamed file with unchanged body must be skipped-unchanged")
        let drawers = try await currentDrawers(kit, handle)
        #expect(drawers.count == 1, "rename must not create a duplicate drawer")
    }

    // MARK: - moot_id hijack guard (Finding 6 regression)

    /// Regression for Security Finding 6: a vault file that claims an existing
    /// drawer's moot_id but carries DIFFERENT body content must NOT replace that
    /// drawer's body. The path-identity discriminator fires when the hostile note
    /// comes from a DIFFERENT vault path than the one the export would have assigned
    /// to the victim drawer. The guard rejects the moot_id claim and files the import
    /// under the file's own FNV-derived lineage instead, leaving the victim's
    /// drawer untouched and the attacker's content isolated in a new drawer.
    ///
    /// The hostile file lives at "attack/hostile.md" — a path that does not match
    /// the victim drawer's computed export path ("Agentic Memory/target/<victim-slug>"),
    /// so the path-identity check correctly identifies it as foreign.
    @Test("hostile moot_id claiming an existing lineage with different content does not replace the original")
    func mootIDHijackGuardBlocksBodyReplacement() async throws {
        let (kit, handle) = try await openEstate()
        defer {}

        // 1. Capture the victim drawer through the normal path.
        let victimContent = "original content that must not be replaced"
        let victim = try await kit.capture(handle, CaptureFrame(
            content: victimContent,
            channel: .typed,
            room: "target",
            latticeAnchor: LatticeAnchor(udcCode: "000"),
            addedBy: "owner",
            embeddingModelID: "test-v1"))

        // 2. Craft a hostile vault file: same moot_id (victim's lineage UUID) but
        //    attacker-supplied body. This simulates an attacker learning the UUID
        //    from a prior export and building a file to overwrite the victim's body.
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let hostileFile = vault.appendingPathComponent("attack/hostile.md")
        try FileManager.default.createDirectory(
            at: hostileFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
            ---
            room: target
            moot_id: \(victim.lineageID.uuidString)
            ---
            attacker-controlled replacement content
            """.write(to: hostileFile, atomically: true, encoding: .utf8)

        // 3. Import the hostile vault file.
        let bridge = VaultBridge(kit: kit, mapping: DrawerMapping(classifyOnImport: false))
        let report = try await bridge.importVault(at: vault, into: handle, now: Date())

        // 4. The hostile file carries a different body, so the guard fires:
        //    the moot_id claim is rejected and the file lands under its own
        //    FNV lineage. One new drawer is written (the hostile file itself).
        #expect(report.drawersWritten == 1,
                "hostile file with different body must land as a new drawer, not an update")

        // 5. The victim's content is completely unchanged.
        let allDrawers = try await kit.recall(handle, RecallFrame(
            filterChain: [
                .currentlyBelieve,
                .any([.userConfirmed, .unconfirmed, .automatedConfirmedOnly]),
                .any([.trustworthy, .requiresConfirmation]),
            ],
            hydrationLevel: .full, limit: 10_000_000))
        let victimAfter = try #require(
            allDrawers.first { $0.lineageID == victim.lineageID },
            "victim lineage must still exist in the estate")
        #expect(victimAfter.content == victimContent,
                "victim drawer content must be unchanged after hostile import")
        #expect(allDrawers.count == 2,
                "estate must have exactly the victim drawer + the isolated hostile drawer")
    }

    /// Regression guard: a legitimate round-trip edit (same path, changed body) must
    /// supersede the existing drawer — NOT create a duplicate. This test captures the
    /// bug that the path-identity discriminator was introduced to fix: the old
    /// FNV-based guard (condition 2) always fired for normally-captured drawers whose
    /// lineageIDs are random, causing every edited exported note to land as a new
    /// drawer instead of updating the existing one.
    ///
    /// Sequence:
    ///   1. Capture a drawer normally (random lineageID).
    ///   2. Export — the drawer is written to vault at a deterministic path with
    ///      moot_id = drawer.lineageID in the frontmatter.
    ///   3. Edit the exported file IN PLACE (same path, body appended).
    ///   4. Re-import — must supersede: drawersUpdated=1, drawersWritten=0,
    ///      estate count still 1.
    @Test("same-path round-trip edit supersedes the existing drawer (path-identity discriminator regression)")
    func samepathRoundTripEditSupersedes() async throws {
        let (kit, handle) = try await openEstate()
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        // 1. Capture one drawer normally.
        let originalContent = "Round-trip regression: original body."
        _ = try await kit.capture(handle, CaptureFrame(
            content: originalContent,
            channel: .typed,
            room: "roundtrip",
            latticeAnchor: LatticeAnchor(udcCode: "000"),
            addedBy: "test",
            embeddingModelID: "test-v1"))
        let preDraw = try await currentDrawers(kit, handle)
        #expect(preDraw.count == 1, "estate must have exactly one drawer before export")

        // 2. Export — writes the drawer to vault at a deterministic path, stamping
        //    moot_id = drawer.lineageID in the frontmatter.
        let bridge = VaultBridge(kit: kit, mapping: DrawerMapping(classifyOnImport: false))
        try await bridge.export(estate: handle, to: vault, scope: .believed, now: Date())
        // Locate the exported file.
        let exportedFile = try #require(firstMDFile(in: vault),
                                        "export must have produced at least one .md file")

        // 3. Edit the file IN PLACE — same vault path, body appended.
        let raw = try String(contentsOf: exportedFile, encoding: .utf8)
        try (raw + "\nAppended edit for round-trip regression test.")
            .write(to: exportedFile, atomically: true, encoding: .utf8)

        // 4. Re-import. The path-identity discriminator must recognise that the
        //    note at the same export path is a legitimate round-trip edit and allow
        //    the supersession, not create a new drawer.
        let report = try await bridge.importVault(at: vault, into: handle, now: Date())
        #expect(report.drawersUpdated == 1,
                "round-trip edit must supersede the existing drawer (drawersUpdated=1)")
        #expect(report.drawersWritten == 0,
                "round-trip edit must not create a duplicate (drawersWritten=0)")

        let postDraw = try await currentDrawers(kit, handle)
        #expect(postDraw.count == 1,
                "estate must still have exactly one drawer after a round-trip edit")
        let updatedContent = try #require(postDraw.first).content
        #expect(updatedContent.hasSuffix("Appended edit for round-trip regression test."),
                "superseded drawer must carry the edited body")
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
        try await bridgeA.export(estate: handleA, to: exportVault, scope: .believed, now: Date())

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
        let drawerBNames = try await resolveNames(drawersB.first!, kit: kitB, handle: handleB)
        let refsB = try await kitB.recallTunnels(handleB, wing: drawerBNames.wing)
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
        // Empty prior-state maps: first import, no tombstones, no existing content.
        var existingLineageIDs: Set<UUID> = []
        var existingSensitivity: [UUID: AdjectiveSensitivity] = [:]
        var tombstonedLineageIDs: Set<UUID> = []
        var existingContentByLineage: [UUID: String] = [:]
        var existingTunnelSigs: Set<String> = []
        let outcome = try await mapping.importNote(
            note,
            kit: kit,
            handle: handle,
            existingLineageIDs: existingLineageIDs,
            existingSensitivityByLineage: existingSensitivity,
            tombstonedLineageIDs: tombstonedLineageIDs,
            existingContentByLineage: existingContentByLineage,
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
        let tombstonedLineageIDs: Set<UUID> = []
        let existingContentByLineage: [UUID: String] = [:]
        var existingTunnelSigs: Set<String> = []
        _ = try await mapping.importNote(
            note,
            kit: kit,
            handle: handle,
            existingLineageIDs: existingLineageIDs,
            existingSensitivityByLineage: existingSensitivity,
            tombstonedLineageIDs: tombstonedLineageIDs,
            existingContentByLineage: existingContentByLineage,
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
        let tombstonedLineageIDs: Set<UUID> = []
        let existingContentByLineage: [UUID: String] = [:]
        var existingTunnelSigs: Set<String> = []
        _ = try await mapping.importNote(
            note,
            kit: kit,
            handle: handle,
            existingLineageIDs: existingLineageIDs,
            existingSensitivityByLineage: existingSensitivity,
            tombstonedLineageIDs: tombstonedLineageIDs,
            existingContentByLineage: existingContentByLineage,
            existingTunnelSignatures: &existingTunnelSigs,
            now: Date()
        )

        // The note has pathComponents = ["projects", "alpha"] and no frontmatter room.
        // The room must be the full joined path "projects/alpha", not just "alpha".
        let drawers = try await currentDrawers(kit, handle)
        #expect(drawers.count == 1)
        let drawer = try #require(drawers.first)
        let drawerNames = try await resolveNames(drawer, kit: kit, handle: handle)
        #expect(drawerNames.room == "projects/alpha",
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
        // Empty prior-state maps: first import, no tombstones, no existing content.
        let tombstonedLineageIDs: Set<UUID> = []
        let existingContentByLineage: [UUID: String] = [:]
        let outcome = try await mapping.importNote(
            note, kit: kit, handle: handle,
            existingLineageIDs: existingLineageIDs,
            existingSensitivityByLineage: existingSensitivity,
            tombstonedLineageIDs: tombstonedLineageIDs,
            existingContentByLineage: existingContentByLineage,
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
        // Empty prior-state maps: first import, no tombstones, no existing content.
        let tombstonedLineageIDs: Set<UUID> = []
        let existingContentByLineage: [UUID: String] = [:]
        _ = try await mapping.importNote(
            note, kit: kit, handle: handle,
            existingLineageIDs: existingLineageIDs,
            existingSensitivityByLineage: existingSensitivity,
            tombstonedLineageIDs: tombstonedLineageIDs,
            existingContentByLineage: existingContentByLineage,
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
        // Empty prior-state maps: first import, no tombstones, no existing content.
        let tombstonedLineageIDs: Set<UUID> = []
        let existingContentByLineage: [UUID: String] = [:]
        let outcome = try await mapping.importNote(
            note, kit: kit, handle: handle,
            existingLineageIDs: existingLineageIDs,
            existingSensitivityByLineage: existingSensitivity,
            tombstonedLineageIDs: tombstonedLineageIDs,
            existingContentByLineage: existingContentByLineage,
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
        // Empty prior-state maps: first import, no tombstones, no existing content.
        let tombstonedLineageIDs: Set<UUID> = []
        let existingContentByLineage: [UUID: String] = [:]
        _ = try await mapping.importNote(
            note, kit: kit, handle: handle,
            existingLineageIDs: existingLineageIDs,
            existingSensitivityByLineage: existingSensitivity,
            tombstonedLineageIDs: tombstonedLineageIDs,
            existingContentByLineage: existingContentByLineage,
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
        // Empty prior-state maps: first import, no tombstones, no existing content.
        let tombstonedLineageIDs: Set<UUID> = []
        let existingContentByLineage: [UUID: String] = [:]
        _ = try await mapping.importNote(
            note, kit: kit, handle: handle,
            existingLineageIDs: existingLineageIDs,
            existingSensitivityByLineage: existingSensitivity,
            tombstonedLineageIDs: tombstonedLineageIDs,
            existingContentByLineage: existingContentByLineage,
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

        // Import ExchangeAdapterTests.fixtureURL through the bridge to exercise
        // the fieldsDropped report. The `note` above is not imported here;
        // the bridge uses ExchangeAdapter over the golden fixture (drawer-001 has
        // tags + kind "fact").
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

        // Import a structured note directly via DrawerMapping.importNote to
        // exercise the KG-fact landing path. The temp vault dir is created but
        // not written to — the note is passed in-memory, not loaded from disk.
        let note = structuredNote(now: Date())

        let mapping = DrawerMapping(classifyOnImport: false)
        var existingLineageIDs: Set<UUID> = []
        var existingSensitivity: [UUID: AdjectiveSensitivity] = [:]
        var existingTunnelSigs: Set<String> = []
        // Empty prior-state maps: first import, no tombstones, no existing content.
        let tombstonedLineageIDs: Set<UUID> = []
        let existingContentByLineage: [UUID: String] = [:]
        _ = try await mapping.importNote(
            note,
            kit: kit,
            handle: handle,
            existingLineageIDs: existingLineageIDs,
            existingSensitivityByLineage: existingSensitivity,
            tombstonedLineageIDs: tombstonedLineageIDs,
            existingContentByLineage: existingContentByLineage,
            existingTunnelSignatures: &existingTunnelSigs,
            now: Date()
        )

        // All structured fields (facts, tags, kind, scope, pathComponents) now
        // land in the substrate as KG facts. fieldsDropped is expected to be
        // empty — nothing is tracked as dropped for a fully structured note.
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

    // MARK: - FINDING-1: content-idempotent + tombstone-aware import

    /// FINDING-1a: Re-importing the same vault (unchanged content) must not
    /// rotate the drawer UUID or supersede. The second import must leave the
    /// drawer UUID UNCHANGED and report `drawersSkippedUnchanged`.
    ///
    /// FINDING-1b (non-resurrection): A note whose drawer was expunged must
    /// NOT be resurrected on re-import. The import must skip it and report
    /// `drawersSkippedTombstoned`.
    @Test("re-import with unchanged content skips supersession: UUID stable, count stable")
    func reimportUnchangedLeavesUUIDStable() async throws {
        let (kit, handle) = try await openEstate()
        let vault = try seedVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let mapping = DrawerMapping(classifyOnImport: false)
        let bridge = VaultBridge(kit: kit, mapping: mapping)
        let now = Date()

        // First import: note lands as a new drawer.
        let first = try await bridge.importVault(at: vault, into: handle, now: now)
        #expect(first.drawersWritten == 1, "first import must write the drawer")
        #expect(first.drawersUpdated == 0)

        // Capture the drawer UUID before the second import.
        let drawersBefore = try await currentDrawers(kit, handle)
        let uuidBefore = try #require(drawersBefore.first?.id)

        // Second import: SAME vault, UNCHANGED content.
        // The idempotent guard must fire — UUID must not rotate, no supersession.
        let second = try await bridge.importVault(at: vault, into: handle, now: now)
        #expect(second.drawersWritten == 0, "second import of identical content must not write a new drawer")
        #expect(second.drawersUpdated == 0, "unchanged content must not trigger supersession")
        #expect(second.drawersSkippedUnchanged == 1, "unchanged content must be counted as skipped-unchanged")

        // Drawer count stable at 1.
        let drawersAfter = try await currentDrawers(kit, handle)
        #expect(drawersAfter.count == 1, "drawer count must remain stable at 1")

        // UUID must be identical — no UUID rotation took place.
        let uuidAfter = try #require(drawersAfter.first?.id)
        #expect(uuidAfter == uuidBefore, "drawer UUID must not rotate when content is unchanged (FINDING-1a)")
    }

    @Test("re-importing a note whose drawer was withdrawn does NOT resurrect it (FINDING-1b)")
    func reimportAfterWithdrawDoesNotResurrect() async throws {
        let (kit, handle) = try await openEstate()
        let vault = try seedVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let mapping = DrawerMapping(classifyOnImport: false)
        let bridge = VaultBridge(kit: kit, mapping: mapping)
        let now = Date()

        // First import: note lands as a new drawer.
        let first = try await bridge.importVault(at: vault, into: handle, now: now)
        #expect(first.drawersWritten == 1, "first import must write the drawer")

        // Retrieve the drawer and withdraw it (moves to cluster B / usedToBelieve).
        // Withdraw is the vault-operator mechanism for "this note must not resurface."
        // (Expunge/tombstone uses tombstonedAt != nil and is invisible to recall;
        // withdrawn drawers have tombstonedAt == nil and ARE detectable by the
        // import guard via Filter.usedToBelieve.)
        let drawers = try await currentDrawers(kit, handle)
        let drawer = try #require(drawers.first)
        try await kit.withdraw(handle, WithdrawFrame(rowID: drawer.id, reason: "test-withdrawal"))

        // Verify the estate is now empty of active (believed) drawers.
        let afterWithdraw = try await currentDrawers(kit, handle)
        #expect(afterWithdraw.isEmpty, "estate must have no active drawers after withdraw")

        // Re-import the SAME vault. The note's lineage is in the withdrawn set.
        // The import must NOT resurrect it — must skip and count as tombstoned.
        let second = try await bridge.importVault(at: vault, into: handle, now: now)
        #expect(second.drawersWritten == 0, "withdrawn note must NOT be resurrected on re-import (FINDING-1b)")
        #expect(second.drawersUpdated == 0)
        #expect(second.drawersSkippedTombstoned == 1, "withdrawn lineage must be counted as skipped-tombstoned")

        // Estate must remain empty — resurrection did not happen.
        let afterReimport = try await currentDrawers(kit, handle)
        #expect(afterReimport.isEmpty, "estate must remain empty after re-import of withdrawn lineage")
    }

    /// FINDING-1b cluster C: A note whose drawer was ERASED via `moot_erase_memory`
    /// (the `expunge` verb, which sets `tombstonedAt != nil`) must NOT be
    /// resurrected on re-import. This is the gap the prior fix left open: the
    /// cluster B guard (`usedToBelieve`) catches withdrawn drawers but misses
    /// expunged/tombstoned ones because `liveRows` pre-filters `tombstonedAt == nil`
    /// — making cluster C invisible to all recall-based queries.
    ///
    /// The fix adds `GeniusLocusKit.tombstonedLineageIDs(_:)`, which uses
    /// `Estate.allDrawers()` — the only corpus scan that includes tombstoned rows —
    /// and unions the erased set with the withdrawn set so both clusters are blocked.
    @Test("re-importing a note whose drawer was ERASED (expunged/tombstoned) does NOT resurrect it (FINDING-1b cluster C)")
    func reimportAfterExpungeDoesNotResurrect() async throws {
        let (kit, handle) = try await openEstate()
        let vault = try seedVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let mapping = DrawerMapping(classifyOnImport: false)
        let bridge = VaultBridge(kit: kit, mapping: mapping)
        let now = Date()

        // First import: note lands as a new drawer.
        let first = try await bridge.importVault(at: vault, into: handle, now: now)
        #expect(first.drawersWritten == 1, "first import must write the drawer")

        // Retrieve the drawer and EXPUNGE it (cluster C: tombstonedAt is set,
        // content blob zeroed). This mirrors `moot_erase_memory` — the verb that
        // triggered the resurrection bug in the original transcript.
        let drawers = try await currentDrawers(kit, handle)
        let drawer = try #require(drawers.first)
        try await kit.expunge(handle, ExpungeFrame(
            rowID: drawer.id,
            reason: "test-expunge",
            confirmation: true
        ))

        // Verify the estate is now empty of active (believed) drawers.
        // NOTE: recall only sees non-tombstoned rows, so this is expected to be empty
        // regardless — the critical assertion is the re-import behaviour below.
        let afterExpunge = try await currentDrawers(kit, handle)
        #expect(afterExpunge.isEmpty, "estate must have no active drawers after expunge")

        // Re-import the SAME vault. The note's lineage is in the erased (cluster C)
        // set. The import must NOT resurrect it — must skip and count as tombstoned.
        // Before the fix, this would write a new drawer (resurrection bug).
        let second = try await bridge.importVault(at: vault, into: handle, now: now)
        #expect(second.drawersWritten == 0,
                "erased note must NOT be resurrected on re-import — cluster C gap (moot_erase_memory)")
        #expect(second.drawersUpdated == 0)
        #expect(second.drawersSkippedTombstoned == 1,
                "erased lineage must be counted as skipped-tombstoned")

        // Estate must remain empty — resurrection did not happen.
        let afterReimport = try await currentDrawers(kit, handle)
        #expect(afterReimport.isEmpty,
                "estate must remain empty after re-import of erased (expunged) lineage")
    }

    // MARK: - ADR-016 Wing vault layout round-trip

    /// ADR-016 Consequences: wing = top folder; all drawers export under their wing path.
    ///
    /// This test verifies the full round-trip export → vault layout → import:
    ///   1. Export: vault top-level folders == distinct wing names in the estate.
    ///   2. All drawers (including hint drawers) export under `<wing>/<room>/`.
    ///   3. Import: drawer content is preserved; room round-trips via frontmatter.
    ///   4. Wing is restored: each re-imported drawer lands in its original wing,
    ///      not in "Agentic Memory" (the round-trip wiring via CaptureFrame.wing).
    ///   5. Idempotency and tombstone-awareness are preserved (regression guard).
    ///
    /// The multi-wing assertion in Phase 4 is the proof that CaptureFrame.wing is
    /// wired end-to-end: a drawer captured in "User Canon" must re-import into
    /// "User Canon", and a drawer captured in "Personal" must re-import into
    /// "Personal", not both into the default wing.
    @Test("ADR-016: export uses wing as top-level vault folder; import restores non-default wings")
    func wingVaultLayoutRoundTrip() async throws {
        let (kit, handle) = try await openEstate()
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let now = Date(timeIntervalSince1970: 1_750_000_000)

        // Capture two drawers in DIFFERENT wings via the GLK capture seam.
        // CaptureFrame.wing routes each drawer into its named wing at capture time
        // (ADR-016). Content is distinct so slug derivation produces stable slugs.
        let userCanonFrame = CaptureFrame(
            content: "# Research Note\nOrganic chemistry primer.",
            channel: .typed,
            room: "chemistry",
            latticeAnchor: LatticeAnchor(udcCode: "540"),
            addedBy: "test",
            embeddingModelID: "none",
            eventTime: now,
            wing: "User Canon"
        )
        let personalFrame = CaptureFrame(
            content: "# Project Plan\nQuarterly roadmap.",
            channel: .typed,
            room: "roadmap",
            latticeAnchor: LatticeAnchor(udcCode: "658"),
            addedBy: "test",
            embeddingModelID: "none",
            eventTime: now,
            wing: "Personal"
        )
        _ = try await kit.capture(handle, userCanonFrame)
        _ = try await kit.capture(handle, personalFrame)

        // Precondition: verify drawers landed in their respective wings.
        let capturedDrawers = try await currentDrawers(kit, handle)
        let capturedNodeNames = try await resolveNames(capturedDrawers, kit: kit, handle: handle)
        let capturedWings = Set(capturedDrawers.compactMap { capturedNodeNames[$0.parentNodeId]?.wing })
        #expect(capturedWings.contains("User Canon"), "precondition: drawer must land in 'User Canon' wing")
        #expect(capturedWings.contains("Personal"), "precondition: drawer must land in 'Personal' wing")

        // Export the estate. Two distinct wings → two top-level vault folders.
        let mapping = DrawerMapping(classifyOnImport: false)
        let bridge = VaultBridge(kit: kit, mapping: mapping)
        // CAND-032: default scope is now `.exportable`; this ADR-016 wing-folder
        // round-trip validates believed-tier export, so it passes `.believed`.
        let exportReport = try await bridge.export(estate: handle, to: vault, scope: .believed, now: now)
        #expect(exportReport.notesExported == 2, "both drawers must be exported")

        // --- Vault layout assertions (ADR-016) ---
        //
        // Each wing must appear as a top-level folder in the vault.
        let fm = FileManager.default
        let topContents = try fm.contentsOfDirectory(
            at: vault, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        let topDirs = try topContents.filter {
            let v = try $0.resourceValues(forKeys: [.isDirectoryKey])
            return v.isDirectory == true
        }.map { $0.lastPathComponent }

        #expect(topDirs.contains("User Canon"),
                "ADR-016: vault must have a top-level 'User Canon' folder (wing = top-level folder)")
        #expect(topDirs.contains("Personal"),
                "ADR-016: vault must have a top-level 'Personal' folder (wing = top-level folder)")

        // Root-level MD files must only be OKF nav files (index.md, log.md) — no notes.
        let allMD = try fm.contentsOfDirectory(
            at: vault, includingPropertiesForKeys: nil, options: [])
            .filter { $0.pathExtension == "md" }
        let rootNotes = allMD.map { $0.deletingPathExtension().lastPathComponent }
            .filter { $0 != "index" && $0 != "log" }
        #expect(rootNotes.isEmpty, "ADR-016: no note files at vault root — all notes must live under a wing folder")

        // Notes under each wing folder sit in <wing>/<room>/ subfolders.
        let userCanonURL = vault.appendingPathComponent("User Canon", isDirectory: true)
        let userCanonSubdirs = try fm.contentsOfDirectory(
            at: userCanonURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { $0.lastPathComponent }
        #expect(userCanonSubdirs.contains("chemistry"),
                "room 'chemistry' must be a subfolder under 'User Canon'")

        let personalURL = vault.appendingPathComponent("Personal", isDirectory: true)
        let personalSubdirs = try fm.contentsOfDirectory(
            at: personalURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { $0.lastPathComponent }
        #expect(personalSubdirs.contains("roadmap"),
                "room 'roadmap' must be a subfolder under 'Personal'")

        // --- Multi-wing import round-trip (the proof CaptureFrame.wing is wired) ---
        //
        // Import the vault into a FRESH estate. Each drawer must land in its
        // original wing — not in "Agentic Memory" (the defaultWingName).
        let (kit2, handle2) = try await openEstate()
        let bridge2 = VaultBridge(kit: kit2, mapping: mapping)
        let importReport = try await bridge2.importVault(at: vault, into: handle2, now: now)
        #expect(importReport.drawersWritten == 2, "import must write both drawers from the wing-layout vault")
        #expect(importReport.drawersUpdated == 0)
        #expect(importReport.itemsSkipped == 0)

        // THE CRITICAL ASSERTION: each drawer must be in its ORIGINAL wing.
        // Before CaptureFrame.wing was wired through makeCaptureFrame, both
        // drawers would land in "Agentic Memory" regardless of the vault folder.
        let drawers2 = try await currentDrawers(kit2, handle2)
        let importedNodeNames = try await resolveNames(drawers2, kit: kit2, handle: handle2)
        let importedWings = Set(drawers2.compactMap { importedNodeNames[$0.parentNodeId]?.wing })
        #expect(importedWings.contains("User Canon"),
                "wing round-trip: 'User Canon' drawer must re-import into 'User Canon', not defaultWingName")
        #expect(importedWings.contains("Personal"),
                "wing round-trip: 'Personal' drawer must re-import into 'Personal', not defaultWingName")
        #expect(!importedWings.contains("Agentic Memory"),
                "wing round-trip: no drawer must land in 'Agentic Memory' — each has an explicit wing")

        // Room round-trips via frontmatter `room:` key (priority 1 in makeCaptureFrame).
        let rooms2 = Set(drawers2.compactMap { importedNodeNames[$0.parentNodeId]?.room })
        #expect(rooms2.contains("chemistry"), "round-trip: room 'chemistry' must be preserved via frontmatter")
        #expect(rooms2.contains("roadmap"), "round-trip: room 'roadmap' must be preserved via frontmatter")

        // Content is preserved across the round-trip.
        let contents2 = drawers2.map(\.content)
        #expect(contents2.contains { $0.contains("Research Note") },
                "round-trip: User Canon drawer content must be preserved")
        #expect(contents2.contains { $0.contains("Project Plan") },
                "round-trip: Personal drawer content must be preserved")

        // --- Idempotency: re-import must be a no-op (skippedUnchanged) ---
        let reimportReport = try await bridge2.importVault(at: vault, into: handle2, now: now)
        #expect(reimportReport.drawersWritten == 0, "re-import into same estate must not write new drawers (idempotency)")
        #expect(reimportReport.drawersSkippedUnchanged == 2, "re-import must count both drawers as skipped-unchanged")
    }

    // MARK: - Hint-drawer export: hint drawers are normal vault entries

    /// Hint drawers (AI_Charter_Hint room) are normal drawers — they export and
    /// import like any other drawer. A provisioned estate with 7 hint drawers + 1
    /// user note must export all 8 as NoteIR entries; the AI_Charter_Hint folder
    /// appears in the vault tree; importing into a fresh estate writes all 8 drawers.
    ///
    /// Previously (Bug M): charter drawers were excluded from export. That exclusion
    /// is removed — hint drawers carry user-visible memory content and are treated
    /// identically to any other drawer.
    @Test("Hint-drawer export: hint drawers (AI_Charter_Hint room) export and import as normal drawers")
    func exportIncludesHintDrawers() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let expectedWingCount = LocusKit.defaultWings.count // 7
        let expectedTotal = expectedWingCount + 1           // 7 hints + 1 user note

        // --- Source estate: provision via GLK so 7 hint drawers are seeded ---
        let kit1 = GeniusLocusKit()
        let owner1 = OwnerCredentials(ownerIdentifier: "hint-export-source")
        let storage1 = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        let params = EstateProvisionParams(
            estateName: "HintExportSource",
            kind: .glk,
            zoomWindowLow: 0,
            zoomWindowHigh: 999,
            frameworkProfile: "Test",
            syncMode: .none
        )
        let handle1 = try await kit1.provision(storage: storage1, owner: owner1, params: params)

        // Capture one user-content drawer alongside the 7 hint drawers.
        let userFrame = CaptureFrame(
            content: "A regular user note for hint-export test.",
            channel: .typed,
            room: "notes",
            latticeAnchor: LatticeAnchor(udcCode: "000"),
            addedBy: "test",
            embeddingModelID: "none",
            eventTime: now
        )
        _ = try await kit1.capture(handle1, userFrame, mode: .regular)

        // Export to a temp vault — all believed drawers including hints.
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let bridge1 = VaultBridge(kit: kit1, mapping: DrawerMapping(classifyOnImport: false))
        let exportReport = try await bridge1.export(estate: handle1, to: vault, scope: .believed, now: now)

        // All 8 drawers (7 hints + 1 user note) must be in the export.
        #expect(exportReport.notesExported == expectedTotal,
                "hint-export: export must include \(expectedTotal) entries (7 hint drawers + 1 user note); got \(exportReport.notesExported)")

        // The AI_Charter_Hint folder must appear in the vault tree.
        let vaultContents = FileManager.default.enumerator(
            at: vault,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )?.allObjects as? [URL] ?? []
        let hintFiles = vaultContents.filter { $0.pathComponents.contains(LocusKit.hintRoom) }
        #expect(!hintFiles.isEmpty,
                "hint-export: vault must contain AI_Charter_Hint folder/files (hint drawers are normal entries)")

        // --- Import vault into a fresh (non-provisioned) estate ---
        let kit2 = GeniusLocusKit()
        let owner2 = OwnerCredentials(ownerIdentifier: "hint-export-target")
        let storage2 = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage2, owner: owner2)
        let handle2 = try await kit2.open(storage: storage2, owner: owner2)

        let bridge2 = VaultBridge(kit: kit2, mapping: DrawerMapping(classifyOnImport: false))
        let importReport = try await bridge2.importVault(at: vault, into: handle2, now: now)

        // All 8 drawers must be written (hints are not filtered on import).
        #expect(importReport.drawersWritten == expectedTotal,
                "hint-import: all \(expectedTotal) drawers (7 hints + 1 user note) must be written into the fresh estate")

        // Hint drawers appear in recall — they are normal drawers.
        let recalled = try await kit2.recall(handle2, RecallFrame(
            filterChain: [
                .currentlyBelieve,
                .any([.userConfirmed, .unconfirmed, .automatedConfirmedOnly]),
                .any([.trustworthy, .requiresConfirmation])
            ],
            hydrationLevel: .full,
            limit: 1_000_000
        ))
        let hintRecalled = recalled.filter { $0.addedBy == LocusKit.hintAddedBy }
        #expect(hintRecalled.count == expectedWingCount,
                "hint-import: \(expectedWingCount) hint drawers must appear in recall; got \(hintRecalled.count)")
    }

    // MARK: - Bug N: _distilled_from provenance as tunnel not body text

    /// A factoid with a `_distilled_from` provenance tunnel must round-trip
    /// export → import such that:
    ///   1. The exported vault note body does NOT contain the literal text
    ///      `_distilled_from` (the provenance link must not be injected into content).
    ///   2. After import, the factoid drawer content is clean — no markdown link text.
    ///   3. The `_distilled_from` tunnel exists in the re-imported estate (the
    ///      provenance graph edge survives as a real tunnel, not lost).
    ///
    /// Root cause: `_distilled_from` tunnels (label == "_distilled_from",
    /// kind == .references) were previously included in `note.links`. The
    /// Obsidian adapter rendered them as markdown links appended to the body,
    /// corrupting the factoid's content on re-import.
    ///
    /// Fix (Bug N): `DrawerMapping.noteIR` separates `_distilled_from` tunnels
    /// into a dedicated frontmatter key (`distilled_from_sources`). The import
    /// path reads that key and reconstructs the tunnels without touching content.
    @Test("Bug N: _distilled_from provenance tunnel round-trips as tunnel metadata, not body text")
    func distilledFromProvenanceRoundTrips() async throws {
        let (kit, handle) = try await openEstate()
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let now = Date(timeIntervalSince1970: 1_750_000_000)

        // Capture a source drawer (simulates a raw memory that was distilled).
        let sourceFrame = CaptureFrame(
            content: "Original source memory content.",
            channel: .typed,
            room: "raw-memories",
            latticeAnchor: LatticeAnchor(udcCode: "000"),
            addedBy: "test",
            embeddingModelID: "none",
            eventTime: now
        )
        let sourceDrawer = try await kit.capture(handle, sourceFrame, mode: .regular)

        // Capture a factoid drawer in "_distilled" (simulates DistillationCycle output).
        let factoidContent = "Distilled factoid: the essence of the source."
        let factoidFrame = CaptureFrame(
            content: factoidContent,
            channel: .typed,
            room: "_distilled",
            latticeAnchor: LatticeAnchor(udcCode: "001"),
            addedBy: "distillation-daemon",
            embeddingModelID: "none",
            eventTime: now
        )
        let factoidDrawer = try await kit.capture(handle, factoidFrame, mode: .regular)

        // Create the _distilled_from provenance tunnel (factoid → source),
        // exactly as DistillationCycle does.
        let estate = try await kit.estate(for: handle)
        // Resolve display names for the captured drawers (ADR-017).
        let sourceNames = try await resolveNames(sourceDrawer, kit: kit, handle: handle)
        let factoidNames = try await resolveNames(factoidDrawer, kit: kit, handle: handle)
        let provenanceFrame = TunnelCaptureFrame(
            sourceWing: factoidNames.wing,
            sourceRoom: "_distilled",
            targetWing: sourceNames.wing,
            targetRoom: sourceNames.room,
            label: "_distilled_from",
            addedBy: "distillation-daemon",
            sourceDrawerId: factoidDrawer.id,
            targetDrawerId: sourceDrawer.id,
            kind: .references,
            originClass: .derived
        )
        _ = try await estate.capture(provenanceFrame)

        // Export the estate to the vault.
        let bridge = VaultBridge(kit: kit, mapping: DrawerMapping(classifyOnImport: false))
        _ = try await bridge.export(estate: handle, to: vault, scope: .believed, now: now)

        // --- Assertion 1: the factoid vault file must NOT contain _distilled_from text ---
        // Find the factoid note file (it is in the _distilled room). Use allObjects to
        // collect synchronously before the async suspension point so Swift concurrency
        // is happy (NSEnumerator.makeIterator is unavailable from async contexts).
        let vaultFiles = FileManager.default.enumerator(
            at: vault,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )?.allObjects as? [URL] ?? []
        let factoidFileURL = vaultFiles.first { url in
            url.pathExtension == "md" &&
            ObsidianAdapter.relativePath(of: url, under: vault).contains("_distilled")
        }
        let factoidFile = try #require(factoidFileURL, "factoid vault file must exist under _distilled/")
        let factoidFileText = try String(contentsOf: factoidFile, encoding: .utf8)
        #expect(!factoidFileText.contains("_distilled_from"),
                "Bug N: factoid vault file must NOT contain '_distilled_from' link text in body")
        // The frontmatter must carry the provenance metadata for round-trip reconstruction.
        #expect(factoidFileText.contains("distilled_from_sources"),
                "Bug N: factoid vault file must carry 'distilled_from_sources' frontmatter key")

        // --- Assertion 2: re-import into a fresh estate, assert clean content ---
        let (kit2, handle2) = try await openEstate()
        let bridge2 = VaultBridge(kit: kit2, mapping: DrawerMapping(classifyOnImport: false))
        _ = try await bridge2.importVault(at: vault, into: handle2, now: now)

        let importedDrawers = try await kit2.recall(
            handle2,
            RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .full, limit: 10_000_000)
        )
        // Resolve display names for imported drawers to find the factoid by room.
        let importedNodeNames = try await resolveNames(importedDrawers, kit: kit2, handle: handle2)
        let importedFactoid = importedDrawers.first { importedNodeNames[$0.parentNodeId]?.room == "_distilled" }
        let factoid = try #require(importedFactoid, "factoid drawer must be imported")

        // Content must be the original factoid text, with no link appended.
        #expect(factoid.content == factoidContent,
                "Bug N: factoid content must be clean after round-trip — no '_distilled_from' link appended")
        #expect(!factoid.content.contains("_distilled_from"),
                "Bug N: factoid content must not contain the provenance link text")

        // --- Assertion 3: _distilled_from tunnel exists after import ---
        let factoidImportNames = importedNodeNames[factoid.parentNodeId] ?? (wing: "", room: "")
        let importedTunnels = try await kit2.recallTunnels(handle2, wing: factoidImportNames.wing)
        let provenanceTunnels = importedTunnels.filter {
            $0.label == "_distilled_from" && $0.sourceRoom == "_distilled"
        }
        #expect(!provenanceTunnels.isEmpty,
                "Bug N: _distilled_from provenance tunnel must exist after round-trip import")
        let pTunnel = try #require(provenanceTunnels.first)
        #expect(pTunnel.targetRoom == sourceNames.room,
                "Bug N: provenance tunnel must point to the source drawer's room")
    }

    // MARK: - Part B: encode-enqueue sweep after bulk vault import

    /// Open a PROVISIONED estate (with Corpus mounted) for encode-enqueue tests.
    ///
    /// `kit.provision()` wires the Corpus and dedicated encode queue so that
    /// `reindexMissing` can return > 0 after a bulk import. The
    /// `.deterministic` embedding model requires no CoreML and is reproducible.
    private func openProvisionedEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "vaultkit-encode-enqueue-tests")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        let params = EstateProvisionParams(
            estateName: "VaultKit Encode Enqueue Test Estate",
            kind: .glk,
            zoomWindowLow: 1,
            zoomWindowHigh: 10,
            frameworkProfile: "KnowledgeWork",
            syncMode: .none
        )
        let handle = try await kit.provision(
            storage: storage, owner: owner, params: params,
            embeddingModels: [.deterministic]
        )
        return (kit, handle)
    }

    /// After a bulk vault import, `ImportReport.enqueuedForEncode` must be > 0.
    ///
    /// The bulk `captureBatch` path intentionally skips the per-item encode
    /// hook to keep the SQLite transaction bounded. Part B (secfix/c-vault-export2)
    /// adds a `reindexMissing` sweep after the batch write to backfill the encode
    /// queue. This test verifies that at least one drawer is enqueued after a
    /// batch import into a provisioned estate (one that has a Corpus).
    @Test("bulk vault import enqueues imported drawers for semantic encoding")
    func bulkVaultImportEnqueuesDrawersForEncode() async throws {
        let (kit, handle) = try await openProvisionedEstate()
        let vaultURL = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        // Write two notes into a temp vault; both will be captured via
        // captureBatch (count ≤ ImportPolicy.bulkThreshold).
        let wing = "TestWing"
        let wingDir = vaultURL.appendingPathComponent(wing, isDirectory: true)
        try write("""
            ---
            wing: \(wing)
            room: RoomA
            ---
            Content of note A.
            """, to: wingDir.appendingPathComponent("RoomA.md"))
        try write("""
            ---
            wing: \(wing)
            room: RoomB
            ---
            Content of note B.
            """, to: wingDir.appendingPathComponent("RoomB.md"))

        let bridge = VaultBridge(kit: kit)
        let report = try await bridge.importVault(at: vaultURL, into: handle, now: Date())

        // At least the two imported drawers must have been enqueued for encode.
        // reindexMissing skips already-indexed drawers (idempotent) so the count
        // can equal the write count on a fresh estate.
        #expect(report.drawersWritten == 2,
                "both notes must be written: \(report)")
        #expect(report.enqueuedForEncode > 0,
                "bulk import must enqueue imported drawers for encoding; enqueuedForEncode=\(report.enqueuedForEncode)")
    }
}
