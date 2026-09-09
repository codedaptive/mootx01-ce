// MemoryToolAdapterSensitivityTests.swift
//
// The `memory` tool's sensitivity gate: the adapter is a bulk,
// path-addressed surface with no grant ceremony, so it must match
// BitmapEvaluator's default no-claims recall posture — Normal-tier
// drawers (adjective sensitivity normal/elevated) are visible, restricted
// and secret drawers neither list nor resolve. Edits must carry the source
// drawer's tier forward (a re-capture hardcoding .normal used to DOWNGRADE
// elevated drawers). Adapted from PR #13 with the canonical
// `Drawer.adjectiveSensitivity` accessor instead of a hand-rolled decode.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

@Suite("Anthropic memory tool sensitivity gate", .serialized)
struct MemoryToolAdapterSensitivityTests {
    private func makeHarness() async throws -> (GeniusLocusKit, EstateHandle, ToolDispatcher) {
        // The memory tool is opt-in; enable it for these dispatch-behavior
        // tests through the dispatcher's injected environment. Never setenv:
        // the process environment is shared with concurrently running suites
        // (the tool-count contract gates), so a process-global toggle races them.
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "memory-tool-sensitivity-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
        return (kit, handle, ToolDispatcher(kit: kit, handle: handle,
                                            environment: ["MOOTX01_MEMORY_TOOL": "1"]))
    }

    @discardableResult
    private func seed(
        _ content: String,
        path: String,
        sensitivity: AdjectiveSensitivity,
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> Drawer {
        let room = String(path.dropFirst("/memories/".count))
        let frame = CaptureFrame(
            content: content,
            channel: .actuator,
            room: room,
            latticeAnchor: .udc("000"),
            addedBy: "aria-mcp-tests",
            embeddingModelID: "test-model-v1",
            sensitivity: sensitivity,
            provenanceChannel: .mcpAgent,
            sourceType: .imported,
            wing: "memories"
        )
        return try await kit.capture(handle, frame, mode: .regular)
    }

    private func text(of result: JSONValue) -> String {
        result.objectValue?["content"]?.arrayValue?
            .first?.objectValue?["text"]?.stringValue ?? ""
    }

    /// Security (Codex b5716d8): the memory tool is opt-in. With the flag
    /// disabled, a hard-coded tools/call to `memory` must be REFUSED at
    /// dispatch — not merely hidden from tools/list — mirroring the vault
    /// disabled-refusal.

    // MARK: - Write side floors at the live grant ceiling

    /// Read the drawer in the `memories` wing whose content contains
    /// `marker` through an explicit sensitivity filter, which suppresses the
    /// default `.elevated` ceiling that hides a restricted or secret row.
    private func filedTier(
        of marker: String, at tier: AdjectiveSensitivity, kit: GeniusLocusKit, handle: EstateHandle
    ) async throws -> AdjectiveSensitivity? {
        let drawers = try await kit.recall(
            handle,
            RecallFrame(filterChain: [.sensitivity(tier)], hydrationLevel: .full, limit: 50))
        return drawers.first { $0.tombstonedAt == nil && $0.content.contains(marker) }?.adjectiveSensitivity
    }
}
