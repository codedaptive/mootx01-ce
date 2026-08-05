// MiniLLMSubjectProducerTests.swift
//
// PR-10 verification for the Apple subject rider. The deterministic
// parts (post-pass, tier list, enablement gating) always run; the live
// on-device model test is CONDITIONAL on model availability — it skips
// cleanly on machines without Apple Intelligence, and the register gate
// (not byte-pinning) carries contract conformance when it does run.

import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

#if canImport(FoundationModels)

/// Availability bridge: Swift Testing traits and suites cannot carry
/// `@available`, so each test guards at runtime and this helper answers
/// the `.enabled(if:)` condition from a non-annotated context.
private var miniLLMModelAvailable: Bool {
    if #available(macOS 26.0, iOS 26.0, *) {
        return MiniLLMSubjectProducer.isModelAvailable
    }
    return false
}

@Suite("MiniLLM subject rider — Apple producer")
struct MiniLLMSubjectProducerTests {

    @Test func postProcessCollapsesAndUnwraps() {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        #expect(MiniLLMSubjectProducer.postProcess("  Deploy gate changed.  ")
                == "Deploy gate changed.")
        #expect(MiniLLMSubjectProducer.postProcess("Line one\nline two")
                == "Line one line two")
        #expect(MiniLLMSubjectProducer.postProcess("\"Quoted subject line.\"")
                == "Quoted subject line.")
        #expect(MiniLLMSubjectProducer.postProcess("\r\n  \"Wrapped.\"  \r")
                == "Wrapped.")
    }

    @Test func producerDeclaresTheModelTierAndLadder() {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let p = MiniLLMSubjectProducer()
        #expect(p.pipelineVersion == DrawerStore.subjectPipelineMiniLLMV1)
        // The ladder by construction: deterministic tiers only — never
        // ai-v1, never its own tier.
        #expect(p.regeneratesPipelines == ["consolidation-v1", "seed-v1"])
        #expect(!p.regeneratesPipelines.contains("ai-v1"))
        #expect(!p.regeneratesPipelines.contains(p.pipelineVersion))
    }

    @Test func enableRefusesWhenModelUnavailable() async throws {
        // Only meaningful on hosts WITHOUT the model; on model-equipped
        // hosts the positive path is covered by the live test below.
        guard !miniLLMModelAvailable else { return }
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        let creds = OwnerCredentials(ownerIdentifier: "minillm-enable")
        _ = try await LocusKit.Estate.create(storage: storage, owner: creds)
        let handle = try await kit.open(
            storage: storage, owner: creds,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        defer { Task { try? await kit.close(handle) } }
        await #expect(throws: GeniusLocusKitError.self) {
            try await kit.enableAppleSubjectRider(for: handle)
        }
    }

    /// LIVE on-device model test — fills a fixture estate's NULL rows
    /// with contract-conformant subjects. Skips when the model is not
    /// available on this machine.
    @Test(.enabled(if: miniLLMModelAvailable))
    func liveRiderFillsNullRowsWithConformantSubjects() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        let creds = OwnerCredentials(ownerIdentifier: "minillm-live")
        _ = try await LocusKit.Estate.create(storage: storage, owner: creds)
        let handle = try await kit.open(
            storage: storage, owner: creds,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        defer { Task { try? await kit.close(handle) } }
        let estate = try await kit.estate(for: handle)

        // ai-v1 row that must remain untouched + two NULL rows.
        let aiFrame = CaptureFrame(
            content: "The staging deploy gate now requires two approvals.",
            channel: .typed, room: "minillm-tests",
            latticeAnchor: LatticeAnchor(udcCode: "000"),
            addedBy: "minillm-tests", embeddingModelID: "test-model-v1",
            subject: "Staging deploy gate requires two approvals.")
        let aiDrawer = try await kit.capture(handle, aiFrame)
        for content in [
            "The quarterly planning meeting moved from Tuesday to Thursday this sprint.",
            "Sarah owns sending the updated calendar invites before Monday morning.",
        ] {
            let f = CaptureFrame(
                content: content, channel: .typed, room: "minillm-tests",
                latticeAnchor: LatticeAnchor(udcCode: "000"),
                addedBy: "minillm-tests", embeddingModelID: "test-model-v1")
            _ = try await kit.capture(handle, f)
        }

        try await kit.enableAppleSubjectRider(for: handle)
        let report = try await kit.subjectBackfillSweep(handle, batchLimit: 10, now: Date())
        // The register gate is the conformance arbiter: whatever was
        // written passed it; skipped rows stayed debt (a flaky model
        // must never store junk). At least the drain must be observable.
        #expect(report.written + report.skippedInadmissible == 2)
        let after = try await estate.allDrawers()
        for d in after where d.subjectPipelineVersion == DrawerStore.subjectPipelineMiniLLMV1 {
            #expect(SubjectRegister.violations(d.subject ?? "").isEmpty,
                    "stored rider subject must satisfy the register: \(d.subject ?? "")")
        }
        let ai = after.first { $0.id == aiDrawer.id }
        #expect(ai?.subjectPipelineVersion == "ai-v1", "ai-v1 must be untouched")
        // Drain lane reports the sweep's aftermath.
        let drains = try await kit.drainStatuses(handle)
        let lane = drains.first { $0.name == DrainStatus.subjectBackfillName }
        #expect(lane != nil)
        #expect(lane?.pending == report.remainingDebt)
    }
}
#endif
