// ConflictProjectionSectionTests.swift
//
// DCP M4 — the typed proving lane's report section through the MCP tool
// surface. moot_lens_contradiction routes through the same evaluator as
// moot_dream / moot_hunt_contradictions (one renderer, M0 §7), so the
// lens is the cheapest end-to-end probe: no vector store required.
// Ledger case F13 (restricted+normal pair redaction) lives here per
// SUBSTRATEML_SPEC § 5.29; the secret-ceiling counted-but-silent case rides
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

    /// F13 — restricted+normal pair: counted, but the block collapses to
    /// the coordinate-digest line. No source ids, no value digests, no
    /// dense rows for the pair.

    /// Secret ceiling: the pair is COUNTED in `proven: N` and emits no
    /// block at all — not even the redacted line.
}
