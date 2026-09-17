// FactExtractionDutyReconciliationTests.swift
//
// F2/F12 regression coverage. Two independent drivers of `.factExtraction`
// live in `runResidentDaemon`: the `FactExtractionSignal` (managed by the
// preference-reconciliation loop, `reconcilePreferenceSignal`) and the
// `dutyWorkerTasks` loop, a second, unconditional enqueue+drain cycle. Before
// this fix the duty-worker loop never consulted the live `fact_extraction`
// preference at all, so turning it off only tore down the signal and left
// the duty worker paying debt forever (F2); and the signal's own on-edge
// activation reused a `(any FactExtractor)?` VALUE captured once at daemon
// start, so an operator who flipped `fact_extraction` on after a daemon
// launched with it off (or staged a model asset afterward) found Signal 14
// permanently inert until the next restart (F12).
//
// `runFactExtractionDutyCycle` and `makeFactExtractionSpec` are the two
// testable seams the fix introduces — the same functions `runResidentDaemon`
// now calls in production.

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

private func openTestEstate() async throws -> (GeniusLocusKit, EstateHandle) {
    let kit = GeniusLocusKit()
    let owner = OwnerCredentials(ownerIdentifier: "fact-extraction-duty-reconciliation-tests")
    let storage = InMemoryStorage(
        configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
    let params = EstateProvisionParams(
        estateName: "FactExtraction Duty Reconciliation Test Estate",
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

private let testSpec = FactExtractorModelSpec(
    providerID: "duty-reconciliation-provider",
    modelID: "duty-reconciliation-model",
    modelVersion: "0.1",
    schemaVersion: "1",
    extractorKind: .foundationModel,
    maximumInputCharacters: 2_000,
    maximumFactsPerSource: 4)

private let testExtractor = ClosureFactExtractor(spec: testSpec) { _ in
    FactExtractionResponse(
        sourceDigest: "test",
        providerID: testSpec.providerID,
        modelID: testSpec.modelID,
        modelVersion: testSpec.modelVersion,
        schemaVersion: testSpec.schemaVersion,
        candidates: [])
}

// MARK: - F2: the duty worker must read the live preference every cycle

@Suite("AriaResident — fact-extraction duty worker (F2)")
struct FactExtractionDutyWorkerTests {

    @Test("an off preference skips the cycle and detaches the runtime extractor")
    func skipsAndDetachesWhenOff() async throws {
        let (kit, handle) = try await openTestEstate()
        defer { Task { try? await kit.close(handle) } }

        // Simulate a runtime extractor registered while the preference was on.
        _ = try await kit.activateFactExtractor(
            testExtractor, recipeID: "duty-off-test:v1", for: handle)
        #expect(await kit.registeredFactExtractor(for: handle) != nil)

        try await kit.provisionPreference(.factExtraction, .off, for: handle)

        let report = try await AriaResident.runFactExtractionDutyCycle(
            kit: kit, handle: handle, now: Date())

        #expect(report == nil, "an off preference must skip the cycle, not merely find zero debt")
        #expect(
            await kit.registeredFactExtractor(for: handle) == nil,
            "the off edge must detach the runtime extractor via unregisterFactExtractor"
        )
        #expect(
            try await kit.dutyDebt(.factExtraction, in: handle) == 0,
            "dutyDebt(.factExtraction) gates on the extractor being registered — detaching it must zero the debt too"
        )
    }

    @Test("an on preference runs the ordinary enqueue-then-drain cycle")
    func runsWhenOn() async throws {
        let (kit, handle) = try await openTestEstate()
        defer { Task { try? await kit.close(handle) } }

        _ = try await kit.activateFactExtractor(
            testExtractor, recipeID: "duty-on-test:v1", for: handle)
        try await kit.provisionPreference(.factExtraction, .on, for: handle)

        let report = try await AriaResident.runFactExtractionDutyCycle(
            kit: kit, handle: handle, now: Date())

        #expect(report != nil, "an on preference must run the cycle rather than skip it")
        #expect(
            await kit.registeredFactExtractor(for: handle) != nil,
            "the extractor must remain attached while the preference is on"
        )
    }
}

// MARK: - F12: the on-edge must rebuild the extractor via the factory, not a stale value

@Suite("AriaResident — fact-extraction on-edge activation (F12)")
struct FactExtractionOnEdgeActivationTests {

    @Test("makeFactExtractionSpec stays inert when the factory yields no extractor")
    func inertWithNilFactory() async throws {
        let (kit, handle) = try await openTestEstate()
        defer { Task { try? await kit.close(handle) } }

        let spec = await AriaResident.makeFactExtractionSpec(
            factExtractorFactory: nil, cadenceSeconds: 1, kit: kit, handle: handle)
        #expect(spec == nil)
    }

    @Test("the off\u{2192}on edge registers a freshly-built extractor, proving the factory is called each time")
    func offToOnEdgeRegistersFreshExtractor() async throws {
        let (kit, handle) = try await openTestEstate()
        defer { Task { try? await kit.close(handle) } }

        var ids: [String: SignalID] = [:]
        let name = FactExtractionSignal.signalName

        // Models the F12 scenario exactly: a factory that can only produce an
        // extractor NOW — a value captured once at daemon start (when the
        // preference was off) could never have observed this. Production
        // wires this closure into `ResidentConfig.factExtractorFactory`.
        let factory: @Sendable () async -> (any FactExtractor)? = { testExtractor }

        // While off: reconcilePreferenceSignal's `enabled: false` branch never
        // calls makeSpec at all, matching the running daemon's `factOn == false` path.
        try await AriaResident.reconcilePreferenceSignal(
            name: name, enabled: false, ids: &ids, kit: kit, handle: handle, now: Date()
        ) { nil }
        #expect(ids[name] == nil)

        // The off→on edge: `enabled: true` with no existing id invokes makeSpec.
        try await AriaResident.reconcilePreferenceSignal(
            name: name, enabled: true, ids: &ids, kit: kit, handle: handle, now: Date()
        ) {
            await AriaResident.makeFactExtractionSpec(
                factExtractorFactory: factory, cadenceSeconds: 1, kit: kit, handle: handle)
        }

        #expect(ids[name] != nil, "the on-edge must register the signal using the factory's freshly-built extractor")
        #expect(
            await kit.registeredFactExtractor(for: handle) != nil,
            "makeFactExtractionSpec must activate the extractor the factory just built"
        )
    }
}
