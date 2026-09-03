// IndexCompositionSettingTests.swift
//
// The index composition policy is a stored estate setting (LocusKit manifest
// key index_composition_policy). These tests pin the contract both ports
// share:
//   (a) an open reads the stored setting and ignores MOOT_INDEX_COMPOSITION;
//   (b) provision seeds the setting: the environment's policy id when set,
//       `.current` otherwise; an invalid value seeds `.current`;
//   (c) changing the setting and rebuilding the lanes leaves every index row
//       carrying the new id, and a serving open under a changed setting
//       without that rebuild is refused;
//   (d) a malformed stored value refuses the open.
//
// Rust twin: rust/src/coordinator.rs tests (`index_composition_setting`).

import CorpusKit
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitSQLite
import Testing

@testable import GeniusLocusKit

private let settingNow = Date(timeIntervalSince1970: 1_756_100_000)

private func scratchURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("glk-index-composition-\(UUID().uuidString).sqlite3")
}

private func sqliteStorageAt(_ url: URL) throws -> any Storage {
    try SQLiteStorage(configuration: EstateConfiguration(
        estateID: UUID(),
        backend: .sqlite(url: url, busyTimeout: 5.0)))
}

private func glkParams(estateName: String) -> EstateProvisionParams {
    // lifetime: .ephemeral keeps the Ed25519 identity key out of the Keychain.
    EstateProvisionParams(
        estateName: estateName,
        kind: .glk,
        zoomWindowLow: 1,
        zoomWindowHigh: 10,
        frameworkProfile: "KnowledgeWork",
        syncMode: .none,
        lifetime: .ephemeral)
}

/// Run `body` with MOOT_INDEX_COMPOSITION set to `value` (removed when nil)
/// and restore the previous value afterwards. The suite is serialized.
private func withCreationSeed<T>(
    _ value: String?, _ body: () async throws -> T
) async throws -> T {
    let key = GeniusLocusKit.indexCompositionPolicyEnvironmentKey
    let previous = ProcessInfo.processInfo.environment[key]
    if let value { setenv(key, value, 1) } else { unsetenv(key) }
    defer {
        if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
    }
    return try await body()
}

@Suite("Index composition policy — stored estate setting", .serialized)
struct IndexCompositionSettingTests {

    // MARK: (b) The creation seed

    @Test("the creation seed is the environment's policy id when valid, else .current")
    func creationSeedIsPure() {
        #expect(GeniusLocusKit.indexCompositionPolicyCreationSeed(environment: [:]) == .current)
        #expect(GeniusLocusKit.indexCompositionPolicyCreationSeed(
            environment: ["MOOT_INDEX_COMPOSITION": ""]) == .current)
        #expect(GeniusLocusKit.indexCompositionPolicyCreationSeed(
            environment: ["MOOT_INDEX_COMPOSITION": "lex=originalPlusAdornments;dense=distilled"])
            == .lexicalAdornments)
        #expect(GeniusLocusKit.indexCompositionPolicyCreationSeed(
            environment: ["MOOT_INDEX_COMPOSITION": "cell B"]) == .current)
    }

    @Test("provision without MOOT_INDEX_COMPOSITION stores .current; with it, stores that id")
    func provisionSeedsTheSetting() async throws {
        try await withCreationSeed(nil) {
            let kit = GeniusLocusKit()
            let handle = try await kit.provision(
                storage: try sqliteStorageAt(scratchURL()),
                owner: OwnerCredentials(ownerIdentifier: "icp-seed-absent"),
                params: glkParams(estateName: "SeedAbsent"))
            #expect(try await kit.storedIndexCompositionPolicy(for: handle) == .current)
            #expect(await kit.indexCompositionPolicy(for: handle) == .current)
            try await kit.close(handle)
        }
        try await withCreationSeed(IndexCompositionPolicy.denseAdornments.id) {
            let kit = GeniusLocusKit()
            let handle = try await kit.provision(
                storage: try sqliteStorageAt(scratchURL()),
                owner: OwnerCredentials(ownerIdentifier: "icp-seed-present"),
                params: glkParams(estateName: "SeedPresent"))
            #expect(try await kit.storedIndexCompositionPolicy(for: handle) == .denseAdornments)
            // The wired Corpus runs the seeded policy, not the default.
            #expect(await kit.indexCompositionPolicy(for: handle) == .denseAdornments)
            try await kit.close(handle)
        }
    }

    // MARK: (a) Open reads the stored setting and ignores the environment

    @Test("a serving open runs the stored setting whatever the environment says")
    func openReadsTheStoredSettingNotTheEnvironment() async throws {
        let url = scratchURL()
        let owner = OwnerCredentials(ownerIdentifier: "icp-open-stored")
        try await withCreationSeed(nil) {
            let kit = GeniusLocusKit()
            let handle = try await kit.provision(
                storage: try sqliteStorageAt(url), owner: owner,
                params: glkParams(estateName: "OpenStored"))
            #expect(try await kit.storedIndexCompositionPolicy(for: handle) == .current)
            try await kit.close(handle)
        }
        // A different policy in the environment at open time changes nothing:
        // the estate was created under .current and keeps running it.
        try await withCreationSeed(IndexCompositionPolicy.bothAdornments.id) {
            let kit = GeniusLocusKit()
            let storage = try sqliteStorageAt(url)
            let handle = try await kit.open(
                storage: storage, owner: owner,
                identityKeyStore: InMemoryEstateIdentityKeyStore())
            try await kit.wireGLKSubstores(for: handle, backingStorage: storage)
            #expect(await kit.indexCompositionPolicy(for: handle) == .current)
            #expect(try await kit.storedIndexCompositionPolicy(for: handle) == .current)
            try await kit.close(handle)
        }
    }

    // MARK: (c) Changing the setting rebuilds every row under the new id

    @Test("set + reindex leaves every index row under the new id; a serving open without the rebuild is refused")
    func changingTheSettingRebuildsEveryRow() async throws {
        let url = scratchURL()
        let owner = OwnerCredentials(ownerIdentifier: "icp-set-reindex")
        let newPolicy = IndexCompositionPolicy.lexicalAdornments

        try await withCreationSeed(nil) {
            // Create the estate under .current with two indexed items.
            let kit = GeniusLocusKit()
            let handle = try await kit.provision(
                storage: try sqliteStorageAt(url), owner: owner,
                params: glkParams(estateName: "SetReindex"))
            for text in ["Alice keeps bees in Lisbon.", "Bob repairs clocks in Porto."] {
                _ = try await kit.capture(handle, CaptureFrame(
                    content: text,
                    channel: .typed,
                    room: "setting-room",
                    latticeAnchor: LatticeAnchor(udcCode: "000"),
                    addedBy: "icp-test",
                    embeddingModelID: "test-model-v1",
                    eventTime: settingNow))
            }
            try await kit.reindexCorpus(handle: handle, now: settingNow)
            let before = try await kit.indexCompositionPolicyRowCounts(for: handle)
            #expect(before.keys.sorted() == [IndexCompositionPolicy.current.id])
            #expect((before[IndexCompositionPolicy.current.id] ?? 0) >= 2)

            // Write the new setting; the rows still carry the old id.
            try await kit.setIndexCompositionPolicy(newPolicy, for: handle)
            #expect(try await kit.storedIndexCompositionPolicy(for: handle) == newPolicy)
            try await kit.close(handle)
        }

        // A serving open (no rebuild committed) is refused: the rows disagree
        // with the stored setting.
        do {
            let kit = GeniusLocusKit()
            let storage = try sqliteStorageAt(url)
            let handle = try await kit.open(
                storage: storage, owner: owner,
                identityKeyStore: InMemoryEstateIdentityKeyStore())
            await #expect(throws: (any Error).self) {
                try await kit.wireGLKSubstores(for: handle, backingStorage: storage)
            }
            try? await kit.close(handle)
        }

        // The rebuild path: open with the rebuild committed, reindex, and
        // every active row carries the new id.
        do {
            let kit = GeniusLocusKit()
            let storage = try sqliteStorageAt(url)
            let handle = try await kit.open(
                storage: storage, owner: owner,
                identityKeyStore: InMemoryEstateIdentityKeyStore())
            try await kit.wireGLKSubstores(for: handle, backingStorage: storage, reindexPending: true)
            #expect(await kit.indexCompositionPolicy(for: handle) == newPolicy)
            try await kit.reindexCorpus(handle: handle, now: settingNow)
            let after = try await kit.indexCompositionPolicyRowCounts(for: handle)
            #expect(after.keys.sorted() == [newPolicy.id])
            #expect((after[newPolicy.id] ?? 0) >= 2)
            try await kit.close(handle)
        }

        // And a plain serving open now succeeds under the new setting.
        do {
            let kit = GeniusLocusKit()
            let storage = try sqliteStorageAt(url)
            let handle = try await kit.open(
                storage: storage, owner: owner,
                identityKeyStore: InMemoryEstateIdentityKeyStore())
            try await kit.wireGLKSubstores(for: handle, backingStorage: storage)
            #expect(await kit.indexCompositionPolicy(for: handle) == newPolicy)
            try await kit.close(handle)
        }
    }

    // MARK: (d) A malformed stored value refuses the open

    @Test("a stored value that is not a policy id refuses the open")
    func malformedStoredValueIsRefused() async throws {
        let url = scratchURL()
        let owner = OwnerCredentials(ownerIdentifier: "icp-malformed")
        try await withCreationSeed(nil) {
            let kit = GeniusLocusKit()
            let handle = try await kit.provision(
                storage: try sqliteStorageAt(url), owner: owner,
                params: glkParams(estateName: "Malformed"))
            let estate = try await kit.estate(for: handle)
            try await estate.setMeta(key: GeniusLocusKit.indexCompositionPolicyMetaKey, value: "cell B")
            try await kit.close(handle)
        }
        let kit = GeniusLocusKit()
        let storage = try sqliteStorageAt(url)
        let handle = try await kit.open(
            storage: storage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        await #expect(throws: GeniusLocusKitError.self) {
            try await kit.wireGLKSubstores(for: handle, backingStorage: storage)
        }
        try? await kit.close(handle)
    }
}
