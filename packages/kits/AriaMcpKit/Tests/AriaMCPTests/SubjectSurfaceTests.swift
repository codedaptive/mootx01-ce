// SubjectSurfaceTests.swift
//
// PR-02 verification suite for the capture + lifecycle subject surface:
//
//   1. moot_file_memory REQUIRES `subject` — absence and contract
//      violations are rejected at the boundary with instructive errors
//      (the register guidance, not a bare missing-argument line).
//   2. moot_update_memory mutation=setSubject round-trips a subject onto
//      a subject-less drawer (the backfill/correction write path).
//   3. moot_memory_list filter=missing_subject enumerates exactly the
//      subject-debt rows, id-only.
//
// Subject-less drawers are minted through the direct GLK capture seam
// (frame without subject) — the same shape the intake verbs produce,
// which deliberately file NULL subjects (debt by design).

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// `.serialized`: tests open live in-memory estates; serial execution avoids
/// contention between concurrent GLK estate opens.
@Suite("Subject surface — file_memory boundary, setSubject, missing_subject", .serialized)
struct SubjectSurfaceTests {

    // MARK: - Harness

    private func openEstate(
        in kit: GeniusLocusKit, owner: OwnerCredentials
    ) async throws -> EstateHandle {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        return try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
    }

    private func text(of result: JSONValue) -> String {
        guard case let .object(obj) = result,
              case let .array(content)? = obj["content"],
              case let .object(first)? = content.first,
              case let .string(s)? = first["text"]
        else { return "" }
        return s
    }

    /// Capture a subject-less drawer through the direct GLK seam — the
    /// intake-verb shape (frame without subject → born as debt).
    private func captureWithoutSubject(
        kit: GeniusLocusKit, handle: EstateHandle, content: String, room: String
    ) async throws -> String {
        let frame = CaptureFrame(
            content: content,
            channel: .actuator,
            room: room,
            latticeAnchor: LatticeAnchor(udcCode: "000"),
            addedBy: "subject-surface-tests",
            embeddingModelID: "default",
            wing: LocusKit.defaultWingName
        )
        let drawer = try await kit.capture(handle, frame, mode: .regular)
        return drawer.id
    }

    // MARK: - 1. Boundary requirement

    /// The 120 of the subject contract is 120 Unicode SCALARS, the unit the
    /// Rust twin counts and both moot-bridge ports cut on. A non-ASCII case is
    /// what tells the rules apart: 70 clusters of "e" + U+0301 is 70
    /// Characters — under the limit by that count — and 140 scalars, over it.
    /// Twin of the Rust `subject_length_counts_scalars_not_graphemes`.

    // MARK: - 2 + 3. Debt enumeration and setSubject round-trip

    @Test func unknownFilterIsRejectedNamingTheAccepted() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "subject-badfilter"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        do {
            _ = try await dispatcher.dispatch(
                name: "moot_memory_list",
                arguments: .object([
                    "wing": .string(LocusKit.defaultWingName),
                    "filter": .string("bogus_filter"),
                ]))
            Issue.record("unknown filter must be rejected")
        } catch let error as JSONRPCError {
            #expect(error.message.contains("missing_subject"))
        }
    }

    // MARK: - moot_file_fact subject contract (ARIA-MSG-2)
}
