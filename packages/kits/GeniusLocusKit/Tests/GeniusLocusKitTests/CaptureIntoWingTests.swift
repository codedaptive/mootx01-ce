// CaptureIntoWingTests.swift
//
// GLK-level capture-into-wing conformance tests.
//
// Verifies that the wing slot on CaptureFrame threads all the way through
// the GeniusLocusKit capture surface (kit.capture → EncodeIntake → EstateVerbs)
// so the stored drawer lands in the requested wing.
//
// Tests at this layer complement the LocusKit-level CaptureIntoWingTests:
// LocusKit tests prove the estate_verbs layer; these tests prove the GLK
// VerbSurface + EncodeIntake layer does not swallow the wing before dispatch.

import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import SubstrateTypes
@testable import GeniusLocusKit

@Suite("GLK Capture-into-wing — CaptureFrame.wing threads through GLK")
struct CaptureIntoWingTests {

    // MARK: - Infrastructure

    /// Provision a minimal GLK estate (no Corpus/VectorStore needed — we only
    /// assert on the LocusKit drawer that capture returns, not semantic recall).
    private func openEstateKit() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "glk-wing-test-owner")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        let params = EstateProvisionParams(
            estateName: "Wing Test Estate",
            kind: .glk,
            zoomWindowLow: 1,
            zoomWindowHigh: 10,
            frameworkProfile: "KnowledgeWork",
            syncMode: .none
        )
        let handle = try await kit.provision(
            storage: storage, owner: owner, params: params,
            embeddingModels: [.deterministic])
        return (kit, handle)
    }

    // MARK: - Explicit wing

    @Test("GLK capture with explicit wing stores drawer in that wing")
    func glk_capture_explicitWing_drawerLandsInWing() async throws {
        let (kit, handle) = try await openEstateKit()
        defer { Task { try? await kit.close(handle) } }

        let frame = CaptureFrame(
            content: "user canon content via GLK",
            channel: .typed,
            room: "notes",
            latticeAnchor: .udc("004"),
            addedBy: "glk-test-agent",
            embeddingModelID: "test-model-v1",
            wing: "User Canon"
        )
        // Use .impatient so the drawer returns synchronously with no drain wait
        // — we only need the LocusKit Drawer from capture, not BM25 indexing.
        let drawer = try await kit.capture(handle, frame, mode: .impatient)
        let estate = try await kit.estate(for: handle)
        let names = try await estate.resolveNodeNames(parentNodeIds: [drawer.parentNodeId])
        #expect(names[drawer.parentNodeId]?.wing == "User Canon",
            "GLK capture must thread the explicit wing through to the stored drawer")
    }

    @Test("GLK capture with explicit wing 'Personal' stores drawer in Personal wing")
    func glk_capture_personalWing_drawerLandsInPersonal() async throws {
        let (kit, handle) = try await openEstateKit()
        defer { Task { try? await kit.close(handle) } }

        let frame = CaptureFrame(
            content: "personal diary note via GLK",
            channel: .typed,
            room: "diary",
            latticeAnchor: .udc("100"),
            addedBy: "glk-test-agent",
            embeddingModelID: "test-model-v1",
            wing: "Personal"
        )
        let drawer = try await kit.capture(handle, frame, mode: .impatient)
        let estate = try await kit.estate(for: handle)
        let names = try await estate.resolveNodeNames(parentNodeIds: [drawer.parentNodeId])
        #expect(names[drawer.parentNodeId]?.wing == "Personal")
    }

    // MARK: - Default wing (nil)

    @Test("GLK capture with nil wing files drawer in default wing (Agentic Memory)")
    func glk_capture_nilWing_drawerLandsInDefaultWing() async throws {
        let (kit, handle) = try await openEstateKit()
        defer { Task { try? await kit.close(handle) } }

        // No wing: argument — existing caller pattern, backward compat preserved.
        let frame = CaptureFrame(
            content: "agentic capture via GLK",
            channel: .typed,
            room: "inbox",
            latticeAnchor: .udc("004"),
            addedBy: "glk-test-agent",
            embeddingModelID: "test-model-v1"
        )
        let drawer = try await kit.capture(handle, frame, mode: .impatient)
        let estate = try await kit.estate(for: handle)
        let names = try await estate.resolveNodeNames(parentNodeIds: [drawer.parentNodeId])
        #expect(names[drawer.parentNodeId]?.wing == defaultWingName,
            "nil wing must fall through to the estate default '\(defaultWingName)'")
    }
}
