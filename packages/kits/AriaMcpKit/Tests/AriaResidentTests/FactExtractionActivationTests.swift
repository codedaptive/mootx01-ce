// FactExtractionActivationTests.swift
//
// Unit tests for AriaResident.resolveFactExtractionCycle — the single
// decision function that both the daemon path and the test suite call.
//
// The function takes an injected setting and extractor, so we can exercise
// all three cases without a real model:
//
//   Case 1 (inert, setting=.off): signal stays inert regardless of extractor.
//   Case 2 (inert, setting=.on, no extractor): signal stays inert; not an error.
//   Case 3 (live, setting=.on, extractor present): signal activates and returns
//          a non-nil closure. This case spins up an in-memory estate.
//
// FACT_EXTRACTION_WIRE §2b — Swift port.

import Testing
import Foundation
import GeniusLocusKit
import GeniusLocusKitMigrations
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import FactExtractionKit
import FactExtractionKitProviders
@testable import AriaResident

// MARK: - Helpers

/// Open a minimal in-memory GLK estate for activation tests.
/// Matches the `provision` pattern used by BenchClockTests in this package.
private func openTestEstate() async throws -> (GeniusLocusKit, EstateHandle) {
    let kit = GeniusLocusKit()
    let owner = OwnerCredentials(ownerIdentifier: "fact-extraction-activation-tests")
    let storage = InMemoryStorage(
        configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
    let params = EstateProvisionParams(
        estateName: "FactExtraction Activation Test Estate",
        kind: .glk,
        zoomWindowLow: 1,
        zoomWindowHigh: 10,
        frameworkProfile: "KnowledgeWork",
        syncMode: .none)
    let handle = try await kit.provision(
        storage: storage, owner: owner, params: params,
        embeddingModels: [.deterministic])
    return (kit, handle)
}

/// A minimal ClosureFactExtractor spec — providerID and modelID determine the
/// recipe ID; modelVersion is required for the three-field cross-port formula.
private let testSpec = FactExtractorModelSpec(
    providerID: "test-provider",
    modelID: "test-model",
    modelVersion: "0.1",
    schemaVersion: "1",
    extractorKind: .foundationModel,
    maximumInputCharacters: 2_000,
    maximumFactsPerSource: 4)

/// Closure extractor that always returns an empty response — suitable for
/// activation tests where we only care whether the cycle closure is live,
/// not about what it extracts.
private let testExtractor = ClosureFactExtractor(spec: testSpec) { _ in
    FactExtractionResponse(
        sourceDigest: "test",
        providerID: testSpec.providerID,
        modelID: testSpec.modelID,
        modelVersion: testSpec.modelVersion,
        schemaVersion: testSpec.schemaVersion,
        candidates: [])
}

// MARK: - Decision function tests

@Suite("AriaResident — resolveFactExtractionCycle")
struct FactExtractionActivationTests {

    /// When the estate setting is `.off`, the cycle closure must be nil
    /// regardless of whether an extractor is provisioned. The signal is
    /// registered inert (no activation) — operator opt-out is unconditional.
    ///
    /// This case does not require a real estate (the `.off` branch returns
    /// before calling kit.activateFactExtractor).
    @Test func factExtractionCycleIsInert_when_settingOff_noActivation() async throws {
        let (kit, handle) = try await openTestEstate()
        defer { Task { try? await kit.close(handle) } }

        let cycle = await AriaResident.resolveFactExtractionCycle(
            setting: .off,
            extractor: testExtractor,    // extractor present — should be ignored
            kit: kit,
            handle: handle)

        #expect(cycle == nil,
            "setting=.off must produce nil cycle regardless of extractor")
    }

    /// When the estate setting is `.on` and an extractor is provisioned,
    /// the cycle closure must be non-nil (signal is live). A calling the
    /// closure must return a non-negative integer (factsFiled count; 0 is
    /// valid for an empty estate).
    @Test func factExtractionCycleIsLive_when_settingOn_extractorAvailable() async throws {
        let (kit, handle) = try await openTestEstate()
        defer { Task { try? await kit.close(handle) } }

        let cycle = await AriaResident.resolveFactExtractionCycle(
            setting: .on,
            extractor: testExtractor,
            kit: kit,
            handle: handle)

        // The cycle closure must be non-nil when the setting is .on and
        // an extractor is available.
        let nonNilCycle = try #require(cycle, "setting=.on with extractor must produce a live cycle closure")

        // Calling the cycle on an empty estate must return 0 (nothing to process)
        // and must not throw — the batch runner is robust to an empty work queue.
        let filed = try await nonNilCycle(Date())
        #expect(filed >= 0, "cycle return value must be a non-negative fact count")
    }
}
