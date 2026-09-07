// EmbeddingProviderConsumptionTests.swift
//
// Tests for embedding_provider manifest key consumption in wireSubstores.
//
// ## What is under test
//
// `GeniusLocusKit.wireSubstores(for:kind:backingStorage:embeddingModels:)` now
// reads the `embedding_provider` manifest key set by `provisionEmbeddingProvider`
// and augments the model ensemble before constructing `CorpusContentEngine`.
//
// The key is read at WIRE time (not at provision-write time), so the test
// must:
//   1. Provision the estate (first provision: no key yet → default ensemble).
//   2. Write the key via `provisionEmbeddingProvider`.
//   3. Close the estate (which closes the storage connection).
//   4. Open a fresh `SQLiteStorage` to the SAME file URL and call `provision`
//      again — this is the second wire pass, and `wireSubstores` now sees the
//      key.
//
// A fresh `SQLiteStorage` is required for the second provision because `close`
// terminates the SQLite connection, and the same storage object cannot be
// re-used after close. Creating a new `SQLiteStorage` with the same URL re-opens
// the existing on-disk database, which still holds the key written in step 2.
//
// ## Coverage
//
//   (a) apple-nl-v1 provisioned → corpus has NL provider in its slot list.
//       NaturalLanguage-gated: the test body is compiled only when
//       `canImport(NaturalLanguage)` is true (Apple platforms). On non-Apple
//       platforms the test is a compile-time no-op.
//
//   (b) Absent key → corpus slot list equals exactly the five-signal default.
//       This is the byte-identical guarantee: no key → no change.
//
//   (c) Unknown model ID → corpus slot list equals the five-signal default.
//       The unknown-ID path emits an OSLog warning but does NOT crash or add
//       a partial/broken slot.
//
// ## Storage strategy
//
// SQLite storage is used in all tests so the manifest key written in one
// lifecycle survives through close + re-open. Each reopen creates a NEW
// `SQLiteStorage` at the same URL but with a fresh `EstateConfiguration`
// (the estateID in `EstateConfiguration` is a placeholder; the authoritative
// estate UUID lives in the manifest table inside the database).
//
// The `lifetime: .ephemeral` provision param prevents Ed25519 identity keys
// from being written to the real Keychain during test runs.

import Testing
import Foundation
import LocusKit
import CorpusKit
import PersistenceKit
import PersistenceKitSQLite
@testable import GeniusLocusKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Returns a unique scratch SQLite URL per call (UUID-suffixed temp file).
/// The caller is responsible for passing the same URL to `sqliteStorageAt(_:)`
/// when a second connection to the same database is needed.
private func scratchURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("glk-embed-prov-cons-\(UUID().uuidString).sqlite3")
}

/// Open (or create) a SQLite-backed estate storage at `url`.
/// Can be called multiple times on the same URL to get independent connection
/// objects to the same on-disk database — required for close + reopen.
private func sqliteStorageAt(_ url: URL) throws -> any Storage {
    // EstateConfiguration.estateID is a placeholder; the authoritative
    // estate UUID lives in the manifest table written by DrawerStore.
    try SQLiteStorage(configuration: EstateConfiguration(
        estateID: UUID(),
        backend: .sqlite(url: url, busyTimeout: 5.0)))
}

/// Build the standard `.glk` provision params used across all tests.
/// `estateName` is parameterised so each test gets a distinct manifest label.
private func glkParams(estateName: String) -> EstateProvisionParams {
    // lifetime: .ephemeral prevents SQLite-backed estates from writing an
    // Ed25519 identity key to the real Keychain during test runs.
    EstateProvisionParams(
        estateName: estateName,
        kind: .glk,
        zoomWindowLow: 1,
        zoomWindowHigh: 10,
        frameworkProfile: "KnowledgeWork",
        syncMode: .none,
        lifetime: .ephemeral)
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Consumption tests
// ─────────────────────────────────────────────────────────────────────────────

@Suite("EmbeddingProvider manifest key consumption in wireSubstores", .serialized)
struct EmbeddingProviderConsumptionTests {

    // (b) Absent key → byte-identical default five-signal ensemble
    //
    // When no `embedding_provider` key has been written to the estate manifest,
    // `applyProvisionedEmbeddingProvider` must return `baseModels` unchanged.
    // The corpus must therefore hold exactly the five-signal default.
    //
    // Pin: model IDs in insertion order from `CorpusEnsemble.defaultEnsemble()`.
    // If this pin fails because the default changed, update the expected array.
    // If it fails because extra models were added, the absent-key guard is broken.
    @Test("absent embedding_provider key leaves ensemble byte-identical to five-signal default")
    func absentKeyLeavesEnsembleUnchanged() async throws {
        let kit = GeniusLocusKit()
        let storage = try sqliteStorageAt(scratchURL())
        let owner = OwnerCredentials(ownerIdentifier: "embed-cons-absent")

        // Single provision, no key written — tests the absent-key guard directly.
        let handle = try await kit.provision(
            storage: storage,
            owner: owner,
            params: glkParams(estateName: "ConsumptionAbsentKeyEstate"))

        let corpus = try #require(
            await kit.corpusKits[handle],
            "provision(.glk) must register a CorpusContentEngine")
        let modelIDs = await corpus.providerGenerations().map(\.modelID)

        // Byte-identical pin: absent key must yield the RI-only default
        // (plan 70BC55F3, 2026-09-05; dense families off by default).
        // With DenseFamilies ON: four signals. With LSA ON: five signals.
        #if MOOTX01_LSA
        let expectedDefault = ["random-indexing-v1", "ppmi-v1", "lsa-v1", "nmf-v1", "fdc-v1"]
        #elseif MOOTX01_DENSE_FAMILIES
        let expectedDefault = ["random-indexing-v1", "ppmi-v1", "nmf-v1", "fdc-v1"]
        #else
        let expectedDefault = ["random-indexing-v1"]
        #endif
        #expect(
            modelIDs == expectedDefault,
            "absent key must yield the unchanged default ensemble, got \(modelIDs)")
    }

    // (c) Unknown model ID → falls back to default five-signal; no crash
    //
    // When `wireSubstores` encounters an unrecognised `embedding_provider` ID,
    // it logs an OSLog warning and returns `baseModels` unchanged. The corpus
    // must hold exactly the five-signal default — no partial/broken slot added.
    @Test("unknown embedding_provider key falls back to default five-signal")
    func unknownKeyFallsBackToDefault() async throws {
        let kit = GeniusLocusKit()
        let url = scratchURL()
        let owner = OwnerCredentials(ownerIdentifier: "embed-cons-unknown")
        let params = glkParams(estateName: "ConsumptionUnknownKeyEstate")

        // First provision: no key → default five-signal.
        let storage1 = try sqliteStorageAt(url)
        let handle1 = try await kit.provision(storage: storage1, owner: owner, params: params)

        // Write an unrecognised model ID to the manifest.
        try await kit.provisionEmbeddingProvider("unknown-provider-v99", for: handle1)

        // Close (terminates the storage1 connection).
        try await kit.close(handle1)

        // Second provision: new connection to the same on-disk database.
        // wireSubstores reads "unknown-provider-v99", logs a warning, falls back.
        let storage2 = try sqliteStorageAt(url)
        let handle2 = try await kit.provision(storage: storage2, owner: owner, params: params)
        let corpus = try #require(
            await kit.corpusKits[handle2],
            "second provision must register a CorpusContentEngine")
        let modelIDs = await corpus.providerGenerations().map(\.modelID)

        // Unknown ID must NOT add a slot. Ensemble must equal the default ensemble.
        // RI-only by default (plan 70BC55F3); four signals with DenseFamilies ON;
        // five with LSA ON.
        #if MOOTX01_LSA
        let expectedFallback = ["random-indexing-v1", "ppmi-v1", "lsa-v1", "nmf-v1", "fdc-v1"]
        #elseif MOOTX01_DENSE_FAMILIES
        let expectedFallback = ["random-indexing-v1", "ppmi-v1", "nmf-v1", "fdc-v1"]
        #else
        let expectedFallback = ["random-indexing-v1"]
        #endif
        #expect(
            modelIDs == expectedFallback,
            "unknown embedding_provider ID must fall back to the default ensemble, got \(modelIDs)")
    }

#if canImport(NaturalLanguage) && APPLE_ENCODERS
    // (a) apple-nl-v1 provisioned → corpus has NL provider slot
    // (APPLE_ENCODERS ON; off by default, plan 70BC55F3, 2026-09-05)
    //
    // Setting `embedding_provider = "apple-nl-v1"` in the estate manifest causes
    // `wireSubstores` to append `.nlEmbedding(provider: AppleNLProvider())` to the
    // base ensemble on the next wire pass, producing a six-slot corpus.
    //
    // This test is compiled only on Apple platforms where NaturalLanguage can be
    // imported. The test covers the full provision → write-key → close → reopen
    // cycle required to exercise wire-time key consumption.
    @Test("provisioned apple-nl-v1 adds NL provider slot to corpus ensemble")
    func appleNLProvisionedAddsSlot() async throws {
        let kit = GeniusLocusKit()
        let url = scratchURL()
        let owner = OwnerCredentials(ownerIdentifier: "embed-cons-apple-nl")
        let params = glkParams(estateName: "ConsumptionAppleNLEstate")

        // First provision: no key yet → five-signal default.
        let storage1 = try sqliteStorageAt(url)
        let handle1 = try await kit.provision(storage: storage1, owner: owner, params: params)

        // Write "apple-nl-v1" as the provisioned provider.
        // The key is persisted in the manifest table; it survives close.
        try await kit.provisionEmbeddingProvider("apple-nl-v1", for: handle1)

        // Close (terminates the storage1 connection).
        try await kit.close(handle1)

        // Second provision: new connection to the same database.
        // wireSubstores reads "apple-nl-v1" and appends .nlEmbedding to the ensemble.
        let storage2 = try sqliteStorageAt(url)
        let handle2 = try await kit.provision(storage: storage2, owner: owner, params: params)
        let corpus = try #require(
            await kit.corpusKits[handle2],
            "second provision must register a CorpusContentEngine")
        let modelIDs = await corpus.providerGenerations().map(\.modelID)

        // The NL slot must be present; default slots must be intact.
        // NL provider is appended AFTER the default ensemble (last slot).
        #expect(
            modelIDs.contains("apple-nl-v1"),
            "provisioned apple-nl-v1 must add an NL provider slot; got \(modelIDs)")

        // Total slots: default count + 1 NL.
        // RI-only default → 2 slots; DenseFamilies (4 signals) → 5 slots;
        // LSA (5 signals) → 6 slots.
        #if MOOTX01_LSA
        let expectedCount = 6
        let expectedPrefix: [String] = ["random-indexing-v1", "ppmi-v1", "lsa-v1", "nmf-v1", "fdc-v1"]
        #elseif MOOTX01_DENSE_FAMILIES
        let expectedCount = 5
        let expectedPrefix: [String] = ["random-indexing-v1", "ppmi-v1", "nmf-v1", "fdc-v1"]
        #else
        let expectedCount = 2
        let expectedPrefix: [String] = ["random-indexing-v1"]
        #endif
        #expect(
            modelIDs.count == expectedCount,
            "ensemble must have exactly \(expectedCount) slots (default + 1 NL), got \(modelIDs.count): \(modelIDs)")

        // First N slots must be the default ensemble in insertion order.
        #expect(
            Array(modelIDs.prefix(expectedPrefix.count)) == expectedPrefix,
            "first \(expectedPrefix.count) slots must be the default ensemble in insertion order, got \(Array(modelIDs.prefix(expectedPrefix.count)))")
    }
#endif
}
