// TwentyRowEstateFixtureTests.swift
//
// Self-test for the twenty-row plaintext estate generator. A fixture that other
// missions build their assertions on has to be trustworthy first: if the
// generator silently produced 19 rows or an encrypted file, every downstream
// test would be asserting against the wrong ground truth.
//
// The refuse-to-run test is the one that matters most. It is the mechanical
// enforcement of Bob's ruling that no test touches the production estate.

import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitSQLite
import Testing
@testable import LocusKitEstateFixture

@Suite("Twenty-row plaintext estate fixture")
struct TwentyRowEstateFixtureTests {

    // MARK: - 1. Counts match the manifest

    @Test("Generated estate matches its manifest, and the manifest matches the contract")
    func generatedCountsMatchManifest() async throws {
        let manifest = try await TwentyRowEstateFixture.generateInTemporaryDirectory()
        defer { TwentyRowEstateFixture.cleanup(manifest) }

        // The manifest is the assertion surface, so first prove the manifest
        // itself reports the shape the fixture contract promises.
        #expect(manifest.drawerCount == 20, "the contract is twenty drawers")
        #expect(manifest.factCount >= 6, "the contract is at least six KG facts")
        #expect(manifest.tunnelCount == 2, "the contract is exactly two tunnels")
        #expect(manifest.wings.count == 3, "the contract is three wings")
        #expect(manifest.rooms.count >= 4, "the contract is at least four rooms")
        #expect(manifest.drawerIDs.count == manifest.drawerCount)
        #expect(manifest.factIDs.count == manifest.factCount)
        #expect(manifest.tunnelIDs.count == manifest.tunnelCount)

        // Then prove the file on disk agrees with the manifest, reading through
        // a fresh store so nothing is trusted from the generation session.
        let configuration = EstateConfiguration(
            estateID: UUID(), backend: .sqlite(url: manifest.estateURL))
        let store = try await DrawerStore(storage: try SQLiteStorage(configuration: configuration))

        let drawers = try await store.allDrawers()
        #expect(drawers.count == manifest.drawerCount,
            "on-disk drawer count must equal the manifest's count")

        let facts = try await store.allKGFacts()
        #expect(facts.count == manifest.factCount,
            "on-disk fact count must equal the manifest's count")

        // Every fact's provenance must point at a drawer that actually exists,
        // or "provenance back to specific drawers" is not true.
        let drawerIDSet = Set(drawers.map(\.id))
        for fact in facts {
            #expect(drawerIDSet.contains(fact.sourceDrawerID),
                "fact \(fact.id) must have provenance to a real drawer")
        }
    }

    // MARK: - 2. Plaintext header

    @Test("Generated estate file is plaintext SQLite, not ciphertext")
    func generatedFileIsPlaintextSQLite() async throws {
        let manifest = try await TwentyRowEstateFixture.generateInTemporaryDirectory()
        defer { TwentyRowEstateFixture.cleanup(manifest) }

        let handle = try #require(FileHandle(forReadingAtPath: manifest.estateURL.path))
        defer { try? handle.close() }
        let head = try #require(try handle.read(upToCount: 16))

        #expect(Array(head.prefix(TwentyRowEstateFixture.plaintextSQLiteMagic.count))
            == TwentyRowEstateFixture.plaintextSQLiteMagic,
            "the fixture must be PLAINTEXT: the encryption missions need an unencrypted starting point")
        #expect(try TwentyRowEstateFixture.hasPlaintextSQLiteHeader(at: manifest.estateURL))
    }

    // MARK: - 3. All four sensitivity tiers present and distinct

    @Test("All four provenance sensitivity tiers are present and map to distinct drawers")
    func fourSensitivityTiersArePresentAndDistinct() async throws {
        let manifest = try await TwentyRowEstateFixture.generateInTemporaryDirectory()
        defer { TwentyRowEstateFixture.cleanup(manifest) }

        let tiers: [Sensitivity] = [.normal, .elevated, .restricted, .secret]
        var seen: [String] = []
        for tier in tiers {
            let id = try #require(manifest.drawerIDsByProvenanceTier[tier],
                "manifest must name a drawer at provenance tier \(tier)")
            seen.append(id)
        }
        #expect(Set(seen).count == tiers.count,
            "each tier must map to a DISTINCT drawer, or a gate test cannot tell them apart")

        // Prove the tiers are real on disk, not just manifest bookkeeping.
        let configuration = EstateConfiguration(
            estateID: UUID(), backend: .sqlite(url: manifest.estateURL))
        let store = try await DrawerStore(storage: try SQLiteStorage(configuration: configuration))
        let drawers = try await store.allDrawers()
        let byID = Dictionary(uniqueKeysWithValues: drawers.map { ($0.id, $0) })

        for tier in tiers {
            let id = try #require(manifest.drawerIDsByProvenanceTier[tier])
            let drawer = try #require(byID[id], "tier \(tier) drawer must exist on disk")
            #expect(drawer.sensitivity == tier,
                "drawer \(id) must actually carry provenance sensitivity \(tier)")
        }

        // The sixteen filler rows must stay below the redaction boundary, so a
        // consumer counting gate-admitted rows gets a stable answer.
        let restrictedOrSecret = drawers.filter {
            $0.sensitivity == .restricted || $0.sensitivity == .secret
        }
        #expect(restrictedOrSecret.count == 2,
            "exactly one restricted and one secret row — fillers must never be above elevated")
    }

    // MARK: - 4. The refuse-to-run guard

    @Test("Generator refuses a path inside the real data directory")
    func refusesPathInsideRealDataDirectory() async throws {
        // Drive the guard with an INJECTED home and environment rather than the
        // real ones, so the test proves the logic without needing (or risking)
        // the actual production directory on the machine running it.
        let fakeHome = URL(fileURLWithPath: "/tmp/fixture-guard-home", isDirectory: true)
        let dataDirectory = TwentyRowEstateFixture.productionDataDirectory(
            environment: [:], homeDirectory: fakeHome)

        // The canonical production estate path, and a nested path under it.
        for target in [
            dataDirectory.appendingPathComponent("estate.sqlite"),
            dataDirectory.appendingPathComponent("nested/deeper/estate.sqlite"),
            dataDirectory,
        ] {
            #expect(throws: TwentyRowEstateFixture.FixtureError.self) {
                try TwentyRowEstateFixture.assertNotProductionPath(
                    target, environment: [:], homeDirectory: fakeHome)
            }
        }

        // A sibling directory whose name merely PREFIXES the data directory must
        // be allowed, or the guard is over-broad.
        let sibling = fakeHome
            .appendingPathComponent("Library/Application Support/com.mootx01.ce2/estate.sqlite")
        try TwentyRowEstateFixture.assertNotProductionPath(
            sibling, environment: [:], homeDirectory: fakeHome)

        // An ordinary temp path must be allowed.
        let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fixture-allowed.sqlite")
        try TwentyRowEstateFixture.assertNotProductionPath(
            temp, environment: [:], homeDirectory: fakeHome)
    }

    @Test("Guard honors the MOOTX01_DATA_DIR override")
    func refusesPathInsideEnvOverriddenDataDirectory() async throws {
        // When MOOTX01_DATA_DIR is set, THAT is the real data directory, so the
        // guard has to follow the override rather than only checking the
        // Application Support default.
        let overrideDir = URL(fileURLWithPath: "/tmp/fixture-guard-override", isDirectory: true)
        let environment = [TwentyRowEstateFixture.dataDirEnvVar: overrideDir.path]
        let fakeHome = URL(fileURLWithPath: "/tmp/fixture-guard-home", isDirectory: true)

        #expect(throws: TwentyRowEstateFixture.FixtureError.self) {
            try TwentyRowEstateFixture.assertNotProductionPath(
                overrideDir.appendingPathComponent("estate.sqlite"),
                environment: environment, homeDirectory: fakeHome)
        }

        // With the override in force, the Application Support default is no
        // longer the data directory and must not be refused.
        let defaultDir = fakeHome
            .appendingPathComponent("Library/Application Support/com.mootx01.ce/estate.sqlite")
        try TwentyRowEstateFixture.assertNotProductionPath(
            defaultDir, environment: environment, homeDirectory: fakeHome)
    }

    @Test("generate() refuses before creating any file")
    func generateRefusesWithoutWritingAnything() async throws {
        // The guard must run at step zero. If it ran after directory creation,
        // a refused call would still have littered the real data directory.
        let fakeHome = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fixture-guard-nowrite-\(UUID().uuidString)", isDirectory: true)
        let dataDirectory = TwentyRowEstateFixture.productionDataDirectory(
            environment: [:], homeDirectory: fakeHome)
        let target = dataDirectory.appendingPathComponent("estate.sqlite")

        await #expect(throws: TwentyRowEstateFixture.FixtureError.self) {
            try await TwentyRowEstateFixture.generate(
                at: target, environment: [:], homeDirectory: fakeHome)
        }

        #expect(!FileManager.default.fileExists(atPath: target.path),
            "a refused generate() must not create the estate file")
        #expect(!FileManager.default.fileExists(atPath: dataDirectory.path),
            "a refused generate() must not even create the directory")
    }

    // MARK: - 5. Determinism

    @Test("Row identity is deterministic across runs")
    func rowIdentityIsDeterministic() async throws {
        // stableID is what lets a consumer name a fixture row across runs.
        #expect(TwentyRowEstateFixture.stableID("row-normal-tier")
            == TwentyRowEstateFixture.stableID("row-normal-tier"))
        #expect(TwentyRowEstateFixture.stableID("row-normal-tier")
            != TwentyRowEstateFixture.stableID("row-secret-tier"))
        #expect(UUID(uuidString: TwentyRowEstateFixture.stableID("row-normal-tier")) != nil,
            "capture requires a UUID row identity, so stableID must parse as one")

        // Fact ids are derived from labels, so they are identical across two
        // independent generations even though drawer ids come from capture.
        let first = try await TwentyRowEstateFixture.generateInTemporaryDirectory()
        defer { TwentyRowEstateFixture.cleanup(first) }
        let second = try await TwentyRowEstateFixture.generateInTemporaryDirectory()
        defer { TwentyRowEstateFixture.cleanup(second) }

        #expect(first.factIDs == second.factIDs,
            "fact ids are label-derived and must be stable across generations")
        #expect(first.drawerCount == second.drawerCount)
        #expect(first.wings == second.wings)
        #expect(first.rooms == second.rooms)
    }

    // MARK: - 6. Tunnels

    @Test("Exactly two tunnels, one of them a precedes edge")
    func tunnelShapeMatchesContract() async throws {
        let manifest = try await TwentyRowEstateFixture.generateInTemporaryDirectory()
        defer { TwentyRowEstateFixture.cleanup(manifest) }

        #expect(manifest.tunnelCount == 2)
        #expect(!manifest.precedesTunnelID.isEmpty,
            "the manifest must name the precedes tunnel")
        #expect(manifest.tunnelIDs.contains(manifest.precedesTunnelID))

        let configuration = EstateConfiguration(
            estateID: UUID(), backend: .sqlite(url: manifest.estateURL))
        let store = try await DrawerStore(storage: try SQLiteStorage(configuration: configuration))
        let tunnels = try await store.allTunnels()
        #expect(tunnels.count == 2, "exactly two tunnels on disk")

        let precedes = try #require(tunnels.first { $0.id == manifest.precedesTunnelID })
        // "precedes" has no LocusKit TunnelKind case; the MCP surface maps the
        // kind string onto .blocks, so that is the substrate shape asserted here.
        #expect(precedes.label == "precedes")
        #expect(precedes.kind == .blocks)
    }
}
