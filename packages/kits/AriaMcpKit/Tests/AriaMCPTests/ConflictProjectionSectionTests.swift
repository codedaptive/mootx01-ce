// ConflictProjectionSectionTests.swift
//
// DCP M4 — the typed proving lane's report section through the MCP tool
// surface. moot_lens_contradiction routes through the same evaluator as
// moot_dream / moot_hunt_contradictions (one renderer, M0 §7), so the
// lens is the cheapest end-to-end probe: no vector store required.
// Ledger case F13 (restricted+normal pair redaction) lives here per
// DCP_M0_CONTRACT §10; the secret-ceiling counted-but-silent case rides
// along. Rust twin: dispatch_tests conflict-projection cases.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

@Suite("Conflict projection — MCP report section", .serialized)
struct ConflictProjectionSectionTests {

    private func text(of result: JSONValue) -> String {
        guard case let .object(obj) = result,
              case let .array(content)? = obj["content"],
              case let .object(first)? = content.first,
              case let .string(s)? = first["text"]
        else { return "" }
        return s
    }

    private func makeDispatcher(
        owner: String
    ) async throws -> (ToolDispatcher, GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        let creds = OwnerCredentials(ownerIdentifier: owner)
        _ = try await LocusKit.Estate.create(storage: storage, owner: creds)
        let handle = try await kit.open(
            storage: storage, owner: creds,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        return (ToolDispatcher(kit: kit, handle: handle), kit, handle)
    }

    /// Capture a drawer at `sensitivity` and file one employer claim
    /// from it; both drawers share one event time so the typed pair is
    /// concurrent (validity_overlap).
    private func plantClaim(
        _ kit: GeniusLocusKit, _ handle: EstateHandle,
        content: String, employer: String,
        sensitivity: AdjectiveSensitivity
    ) async throws {
        let drawer = try await kit.capture(handle, CaptureFrame(
            content: content,
            channel: .typed,
            room: "conflict-section-tests",
            latticeAnchor: LatticeAnchor(udcCode: "000"),
            addedBy: "conflict-section-tests",
            embeddingModelID: "test-model-v1",
            sensitivity: sensitivity,
            eventTime: Date(timeIntervalSince1970: 1_690_000_000)))
        _ = try await kit.captureKGFact(
            handle, subject: "Sarah Chen C0", predicate: "employer",
            object: employer, sourceDrawerID: drawer.id,
            now: Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// Normal+normal pair: the lens appends the full typed section with
    /// a PROVEN block, value digests, temporal bases, reasons, and the
    /// legacy grouped-objects view stays present above it.
    @Test func lensAppendsFullTypedSection() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher(owner: "cps-normal")
        try await plantClaim(kit, handle, content: "Claim one.",
                             employer: "Acme Robotics", sensitivity: .normal)
        try await plantClaim(kit, handle, content: "Claim two.",
                             employer: "Beta Corp", sensitivity: .normal)
        let body = text(of: try await dispatcher.dispatch(
            name: "moot_lens_contradiction", arguments: .object([:])))
        // Legacy view intact (additive contract).
        #expect(body.contains("conflicting_facts: 1 subject+predicate pair(s)"))
        // Typed section.
        #expect(body.contains("proven: 1"))
        #expect(body.contains("historical: 0"))
        #expect(body.contains("compatible: 0"))
        #expect(body.contains("unknown_or_invalid: 0"))
        #expect(body.contains("coverage: 2/2"))
        // The lens has no lexical lane — no candidates line.
        #expect(!body.contains("candidates:"))
        #expect(body.contains("  PROVEN "))
        #expect(body.contains("    rule: dim.person.employer@1"))
        #expect(body.contains("    coordinate: person:sarah chen c0|employer"))
        #expect(body.contains(" vs "))
        #expect(body.contains("    time: t:pt:1690000000 | t:pt:1690000000"))
        #expect(body.contains(
            "    reasons: same_coordinate, validity_overlap, values_exclusive"))
    }

    /// F13 — restricted+normal pair: counted, but the block collapses to
    /// the coordinate-digest line. No source ids, no value digests, no
    /// dense rows for the pair.
    @Test func f13RestrictedPairIsRedacted() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher(owner: "cps-restricted")
        try await plantClaim(kit, handle, content: "Public claim.",
                             employer: "Acme Robotics", sensitivity: .normal)
        try await plantClaim(kit, handle, content: "Restricted claim.",
                             employer: "Beta Corp", sensitivity: .restricted)
        let body = text(of: try await dispatcher.dispatch(
            name: "moot_lens_contradiction", arguments: .object([:])))
        #expect(body.contains("proven: 1"))
        #expect(body.contains("a conflicting claim exists at "))
        #expect(body.contains("[restricted]"))
        // The full block never renders: no rule line, no value digests,
        // no temporal bases.
        #expect(!body.contains("  PROVEN "))
        #expect(!body.contains("    rule: "))
        #expect(!body.contains("    values: "))
    }

    /// Secret ceiling: the pair is COUNTED in `proven: N` and emits no
    /// block at all — not even the redacted line.
    @Test func secretCeilingIsCountedButSilent() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher(owner: "cps-secret")
        try await plantClaim(kit, handle, content: "Public claim.",
                             employer: "Acme Robotics", sensitivity: .normal)
        try await plantClaim(kit, handle, content: "Secret claim.",
                             employer: "Beta Corp", sensitivity: .secret)
        let body = text(of: try await dispatcher.dispatch(
            name: "moot_lens_contradiction", arguments: .object([:])))
        #expect(body.contains("proven: 1"))
        #expect(!body.contains("  PROVEN "))
        #expect(!body.contains("[restricted]"))
    }
}
