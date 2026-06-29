import Testing
import Foundation
import LocusKit
import GeniusLocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import VaultKit

/// VK-TIER-01 — ADR-007 Decision 2 enforcement on the bulk channels.
///
/// Fixture corpus (shared expectations with the Rust port's
/// `privacy_tiers.rs`): four drawers, one per sensitivity value, in one
/// room. Expected counts under the default scope: 2 exported (normal +
/// elevated = Normal tier), 1 excluded private (restricted), 1 excluded
/// secret. Under `.believedIncludingPrivate`: 3 exported, 0 excluded
/// private, 1 excluded secret.
@Suite("VK-TIER-01 privacy tiers + receipts")
struct PrivacyTierAndReceiptTests {

    // MARK: - Fixtures

    /// Fixed operation instant so receipt assertions are deterministic.
    private static let fixedNow = Date(timeIntervalSince1970: 1_765_000_000)

    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "vk-tier-tests")
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    private func makeTempVault() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vaultkit-tier-\(UUID().uuidString)", isDirectory: true)
    }

    /// Capture the shared four-drawer tier corpus: one drawer per
    /// sensitivity value, identical content strings in both ports.
    private func captureTierCorpus(_ kit: GeniusLocusKit, _ handle: EstateHandle) async throws {
        let tiers: [(String, AdjectiveSensitivity)] = [
            ("normal note", .normal),
            ("elevated note", .elevated),
            ("restricted note", .restricted),
            ("secret note", .secret),
        ]
        for (content, sensitivity) in tiers {
            _ = try await kit.capture(handle, CaptureFrame(
                content: content,
                channel: .typed,
                room: "tiers",
                latticeAnchor: LatticeAnchor(udcCode: "000"),
                addedBy: "tier-tests",
                embeddingModelID: "test-v1",
                sensitivity: sensitivity
            ))
        }
    }

    /// All `.md` file contents under a vault, concatenated.
    private func allMarkdown(in vaultURL: URL) -> String {
        var out = ""
        guard let enumerator = FileManager.default.enumerator(
            at: vaultURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return out }
        while let next = enumerator.nextObject() as? URL {
            if next.pathExtension == "md", let text = try? String(contentsOf: next, encoding: .utf8) {
                out += text + "\n"
            }
        }
        return out
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Tier enforcement on export

    @Test("default scope exports the Normal tier (normal + elevated) and excludes private + secret, counted")
    func defaultScopeEnforcesTiers() async throws {
        let (kit, handle) = try await openEstate()
        try await captureTierCorpus(kit, handle)
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let bridge = VaultBridge(kit: kit)
        // CAND-032: the default scope is now `.exportable`; this test validates
        // the believed-tier behavior, so it passes `.believed` explicitly.
        let report = try await bridge.export(estate: handle, to: vault, scope: .believed, now: Self.fixedNow)

        #expect(report.notesExported == 2)
        #expect(report.excludedPrivateTier == 1)
        #expect(report.excludedSecretTier == 1)
        #expect(report.scope == .believed)

        let exported = allMarkdown(in: vault)
        // Elevated is Normal tier per ADR-007 — its silent exclusion by the
        // evaluator's implicit `.normal` ceiling was the pre-mission defect.
        #expect(exported.contains("normal note"))
        #expect(exported.contains("elevated note"))
        #expect(!exported.contains("restricted note"))
        #expect(!exported.contains("secret note"))
    }

    @Test(".believedIncludingPrivate includes restricted, still never secret")
    func explicitScopeIncludesPrivateTier() async throws {
        let (kit, handle) = try await openEstate()
        try await captureTierCorpus(kit, handle)
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let bridge = VaultBridge(kit: kit)
        let report = try await bridge.export(
            estate: handle, to: vault, scope: .believedIncludingPrivate, now: Self.fixedNow)

        #expect(report.notesExported == 3)
        #expect(report.excludedPrivateTier == 0)
        #expect(report.excludedSecretTier == 1)

        let exported = allMarkdown(in: vault)
        #expect(exported.contains("restricted note"))
        #expect(!exported.contains("secret note"))
    }

    @Test("a secret-tier drawer NEVER appears in any export, under every scope")
    func secretNeverExportsUnderAnyScope() async throws {
        let (kit, handle) = try await openEstate()
        try await captureTierCorpus(kit, handle)
        let bridge = VaultBridge(kit: kit)

        for scope in VaultExportScope.allCases {
            let vault = makeTempVault()
            defer { try? FileManager.default.removeItem(at: vault) }
            _ = try await bridge.export(estate: handle, to: vault, scope: scope, now: Self.fixedNow)
            #expect(
                !allMarkdown(in: vault).contains("secret note"),
                "secret-tier content leaked under scope \(scope.rawValue)")
        }
    }

    // MARK: - Sensitivity passthrough (import + round trip)

    @Test("import preserves sensitivity supplied in frontmatter")
    func importPreservesSensitivity() async throws {
        let (kit, handle) = try await openEstate()
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        try write(
            """
            ---
            room: tiers
            sensitivity: restricted
            ---
            An arriving private-tier note.
            """,
            to: vault.appendingPathComponent("tiers/arrival.md"))

        let bridge = VaultBridge(kit: kit, mapping: DrawerMapping(classifyOnImport: false))
        let report = try await bridge.importVault(at: vault, into: handle, now: Self.fixedNow)
        #expect(report.drawersWritten == 1)

        // Recall with an explicit sensitivity ceiling so the restricted
        // drawer is visible (the evaluator default would hide it).
        let drawers = try await kit.recall(handle, RecallFrame(
            filterChain: [.unconfirmed, .sensitivityAtMost(.secret)],
            hydrationLevel: .full))
        #expect(drawers.count == 1)
        #expect(drawers.first?.adjectiveSensitivity == .restricted)
    }

    @Test("export round-trips the tier: elevated frontmatter out, elevated drawer back in")
    func sensitivityRoundTrips() async throws {
        let (kit, handle) = try await openEstate()
        _ = try await kit.capture(handle, CaptureFrame(
            content: "elevated note",
            channel: .typed,
            room: "tiers",
            latticeAnchor: LatticeAnchor(udcCode: "000"),
            addedBy: "tier-tests",
            embeddingModelID: "test-v1",
            sensitivity: .elevated
        ))
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let bridge = VaultBridge(kit: kit)
        _ = try await bridge.export(estate: handle, to: vault, scope: .believed, now: Self.fixedNow)
        #expect(allMarkdown(in: vault).contains("sensitivity: elevated"))

        // Re-import into a fresh estate; the tier must survive the trip.
        let (kitB, handleB) = try await openEstate()
        let bridgeB = VaultBridge(kit: kitB, mapping: DrawerMapping(classifyOnImport: false))
        _ = try await bridgeB.importVault(at: vault, into: handleB, now: Self.fixedNow)
        let drawers = try await kitB.recall(handleB, RecallFrame(
            filterChain: [.unconfirmed, .sensitivityAtMost(.secret)],
            hydrationLevel: .full))
        #expect(drawers.first?.adjectiveSensitivity == .elevated)
    }

    // MARK: - Supersession-downgrade defense (sensitivity floor)

    @Test("a hostile re-import carrying the lineage moot_id cannot LOWER an existing drawer's tier")
    func reimportCannotDowngradeSensitivity() async throws {
        let (kit, handle) = try await openEstate()
        // A restricted (Private-tier) drawer is captured normally.
        let drawer = try await kit.capture(handle, CaptureFrame(
            content: "a restricted secret kept private",
            channel: .typed,
            room: "tiers",
            latticeAnchor: LatticeAnchor(udcCode: "000"),
            addedBy: "owner",
            embeddingModelID: "test-v1",
            sensitivity: .restricted
        ))

        // The attacker learns the drawer's lineage UUID (exposed as moot_id in
        // any exported note) and crafts a vault file claiming sensitivity:
        // normal for that same lineage — a declassification attempt.
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        try write(
            """
            ---
            room: tiers
            moot_id: \(drawer.lineageID.uuidString)
            sensitivity: normal
            ---
            a restricted secret kept private
            """,
            to: vault.appendingPathComponent("tiers/attack.md"))

        let bridge = VaultBridge(kit: kit, mapping: DrawerMapping(classifyOnImport: false))
        _ = try await bridge.importVault(at: vault, into: handle, now: Self.fixedNow)

        // The floor held: the drawer is still Restricted, not Normal.
        let drawers = try await kit.recall(handle, RecallFrame(
            filterChain: [
                .currentlyBelieve,
                .any([.userConfirmed, .unconfirmed, .automatedConfirmedOnly]),
                .any([.trustworthy, .requiresConfirmation]),
                .sensitivityAtMost(.secret),
            ],
            hydrationLevel: .full, limit: 10_000_000))
        let survivor = try #require(drawers.first { $0.lineageID == drawer.lineageID })
        #expect(survivor.adjectiveSensitivity == .restricted)

        // And under the `.believed` scope it is admitted by the scope but
        // excluded by the ADR-007 tier partition — a COUNTED exclusion, never
        // silent. (Under the default `.exportable` scope it is filtered earlier
        // by exportability; `.believed` is what exercises the private-tier
        // partition counter here.)
        let exportVault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: exportVault) }
        let report = try await bridge.export(estate: handle, to: exportVault, scope: .believed, now: Self.fixedNow)
        #expect(report.excludedPrivateTier == 1)
        #expect(!allMarkdown(in: exportVault).contains("a restricted secret kept private"))
    }

    @Test("re-import MAY raise a drawer's tier (floor is a minimum, not a freeze)")
    func reimportMayRaiseSensitivity() async throws {
        let (kit, handle) = try await openEstate()
        let drawer = try await kit.capture(handle, CaptureFrame(
            content: "started normal, becomes secret",
            channel: .typed,
            room: "tiers",
            latticeAnchor: LatticeAnchor(udcCode: "000"),
            addedBy: "owner",
            embeddingModelID: "test-v1",
            sensitivity: .normal
        ))
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        try write(
            """
            ---
            room: tiers
            moot_id: \(drawer.lineageID.uuidString)
            sensitivity: secret
            ---
            started normal, becomes secret
            """,
            to: vault.appendingPathComponent("tiers/raise.md"))

        let bridge = VaultBridge(kit: kit, mapping: DrawerMapping(classifyOnImport: false))
        _ = try await bridge.importVault(at: vault, into: handle, now: Self.fixedNow)

        let drawers = try await kit.recall(handle, RecallFrame(
            filterChain: [
                .currentlyBelieve,
                .any([.userConfirmed, .unconfirmed, .automatedConfirmedOnly]),
                .any([.trustworthy, .requiresConfirmation]),
                .sensitivityAtMost(.secret),
            ],
            hydrationLevel: .full, limit: 10_000_000))
        let survivor = try #require(drawers.first { $0.lineageID == drawer.lineageID })
        #expect(survivor.adjectiveSensitivity == .secret)
    }

    // MARK: - Receipts

    @Test("export writes exactly one diary receipt with accurate counts and caller-supplied now")
    func exportWritesOneReceipt() async throws {
        let (kit, handle) = try await openEstate()
        try await captureTierCorpus(kit, handle)
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let bridge = VaultBridge(kit: kit)
        _ = try await bridge.export(estate: handle, to: vault, scope: .believed, now: Self.fixedNow)

        let receipts = try await kit.readDiaryEntries(
            in: handle, agentName: VaultBridge.receiptAgentName)
        #expect(receipts.count == 1)
        let receipt = try #require(receipts.first)
        #expect(receipt.filedAt == Self.fixedNow)
        #expect(receipt.topic == "vault-receipt")
        #expect(receipt.entry.contains(#""operation":"vault-export""#))
        #expect(receipt.entry.contains(#""scope":"believed""#))
        #expect(receipt.entry.contains(#""notesExported":2"#))
        #expect(receipt.entry.contains(#""excludedSecretTier":1"#))
        #expect(receipt.entry.contains(#""excludedPrivateTier":1"#))
        // Spec § 5.6 decode: migration event, info severity, migration-tool actor.
        #expect(receipt.eventClass == .migration)
        #expect(receipt.severity == .info)
        #expect(receipt.actorClass == .migrationTool)
    }

    @Test("import writes exactly one diary receipt with accurate counts")
    func importWritesOneReceipt() async throws {
        let (kit, handle) = try await openEstate()
        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        try write(
            """
            ---
            room: research
            ---
            A note that arrives.
            """,
            to: vault.appendingPathComponent("research/arrival.md"))

        let bridge = VaultBridge(kit: kit, mapping: DrawerMapping(classifyOnImport: false))
        _ = try await bridge.importVault(at: vault, into: handle, now: Self.fixedNow)

        let receipts = try await kit.readDiaryEntries(
            in: handle, agentName: VaultBridge.receiptAgentName)
        #expect(receipts.count == 1)
        let receipt = try #require(receipts.first)
        #expect(receipt.filedAt == Self.fixedNow)
        #expect(receipt.entry.contains(#""operation":"vault-import""#))
        #expect(receipt.entry.contains(#""drawersWritten":1"#))
        #expect(receipt.entry.contains(#""drawersUpdated":0"#))
        #expect(receipt.entry.contains(#""itemsSkipped":0"#))
        #expect(receipt.eventClass == .migration)
    }

    // MARK: - CAND-050: KG fact tier filtering on export

    @Test("CAND-050: KG facts anchored to a secret drawer do not appear in export output")
    func cand050KGFactsExcludedWithSecretAnchor() async throws {
        let (kit, handle) = try await openEstate()

        // Capture a normal drawer and a secret drawer.
        let normalDrawer = try await kit.capture(handle, CaptureFrame(
            content: "normal drawer content",
            channel: .typed,
            room: "cand050",
            latticeAnchor: LatticeAnchor(udcCode: "000"),
            addedBy: "test",
            embeddingModelID: "test-v1",
            sensitivity: .normal
        ))
        let secretDrawer = try await kit.capture(handle, CaptureFrame(
            content: "secret drawer content",
            channel: .typed,
            room: "cand050",
            latticeAnchor: LatticeAnchor(udcCode: "000"),
            addedBy: "test",
            embeddingModelID: "test-v1",
            sensitivity: .secret
        ))

        // Anchor KG facts to each drawer — one to the normal, one to the secret.
        _ = try await kit.captureKGFact(handle,
            subject: "tag:normal-tag", predicate: "tagged", object: "true",
            sourceDrawerID: normalDrawer.id, now: Self.fixedNow)
        _ = try await kit.captureKGFact(handle,
            subject: "tag:secret-tag", predicate: "tagged", object: "true",
            sourceDrawerID: secretDrawer.id, now: Self.fixedNow)

        let vault = makeTempVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let bridge = VaultBridge(kit: kit)
        let report = try await bridge.export(estate: handle, to: vault, scope: .believed, now: Self.fixedNow)

        // Normal drawer exports (1); secret drawer excluded (1).
        #expect(report.notesExported == 1)
        #expect(report.excludedSecretTier == 1)

        // The tag KG fact anchored to the normal drawer should appear in export
        // (as frontmatter `tags:`). The tag fact anchored to the secret drawer
        // must not appear in any exported markdown — CAND-050 enforces this.
        let exported = allMarkdown(in: vault)
        #expect(exported.contains("normal-tag"), "normal drawer's tag must appear in export")
        #expect(!exported.contains("secret-tag"),
            "CAND-050 regression: secret-anchored KG fact must not appear in export")
    }

    @Test("each run writes its own receipt — two exports, two receipts")
    func receiptsAccumulatePerRun() async throws {
        let (kit, handle) = try await openEstate()
        try await captureTierCorpus(kit, handle)
        let bridge = VaultBridge(kit: kit)
        for _ in 0..<2 {
            let vault = makeTempVault()
            defer { try? FileManager.default.removeItem(at: vault) }
            _ = try await bridge.export(estate: handle, to: vault, scope: .believed, now: Self.fixedNow)
        }
        let receipts = try await kit.readDiaryEntries(
            in: handle, agentName: VaultBridge.receiptAgentName)
        #expect(receipts.count == 2)
    }
}
