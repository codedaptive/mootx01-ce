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

    @Test func fileMemoryWithoutSubjectIsRejectedInstructively() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "subject-missing"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        await #expect(throws: JSONRPCError.self) {
            _ = try await dispatcher.dispatch(
                name: "moot_file_memory",
                arguments: .object([
                    "content": .string("content without a subject"),
                    "location": .string("subject-tests"),
                ]))
        }
        do {
            _ = try await dispatcher.dispatch(
                name: "moot_file_memory",
                arguments: .object([
                    "content": .string("content without a subject"),
                    "location": .string("subject-tests"),
                ]))
        } catch let error as JSONRPCError {
            // Instructive, register-bearing error — not the generic
            // missing-argument line.
            #expect(error.message.contains("subject"))
            #expect(error.message.contains("NEXT AI"),
                    "the error must teach the register, got: \(error.message)")
        }
    }

    @Test func fileMemoryOversizeSubjectIsRejected() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "subject-oversize"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let oversize = String(repeating: "x", count: DrawerStore.subjectLengthContract + 1)
        do {
            _ = try await dispatcher.dispatch(
                name: "moot_file_memory",
                arguments: .object([
                    "content": .string("some content"),
                    "subject": .string(oversize),
                    "location": .string("subject-tests"),
                ]))
            Issue.record("oversize subject must be rejected")
        } catch let error as JSONRPCError {
            #expect(error.message.contains("\(DrawerStore.subjectLengthContract)"))
        }
    }

    @Test func fileMemoryWithSubjectSucceeds() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "subject-happy"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let result = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("The quarterly planning meeting moved to Thursday."),
                "subject": .string("Quarterly planning moved to Thursday."),
                "location": .string("subject-tests"),
            ]))
        #expect(text(of: result).contains("filed memory"))
    }

    // MARK: - 2 + 3. Debt enumeration and setSubject round-trip

    @Test func missingSubjectFilterListsExactlyTheDebtRowsAndSetSubjectClearsThem() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "subject-debt"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // One drawer WITH a subject (through the boundary) …
        _ = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("Filed with a subject."),
                "subject": .string("Row filed with a subject at capture."),
                "location": .string("subject-tests"),
            ]))
        // … and one WITHOUT (direct seam — the intake shape).
        let debtID = try await captureWithoutSubject(
            kit: kit, handle: handle,
            content: "Imported without a subject.", room: "subject-tests")

        // The debt enumerator lists exactly the subject-less row, id-only.
        let listed = try await dispatcher.dispatch(
            name: "moot_memory_list",
            arguments: .object([
                "wing": .string(LocusKit.defaultWingName),
                "filter": .string("missing_subject"),
            ]))
        let listText = text(of: listed)
        #expect(listText.contains("1 drawer(s)"), "exactly one debt row expected: \(listText)")
        #expect(listText.contains(debtID))
        #expect(!listText.contains("Imported without a subject"),
                "debt rows are id-only — no content preview")

        // setSubject round-trip: backfill the debt row …
        let updated = try await dispatcher.dispatch(
            name: "moot_update_memory",
            arguments: .object([
                "id": .string(debtID),
                "mutation": .string("setSubject"),
                "subject": .string("Imported row: subject backfilled interactively."),
            ]))
        #expect(text(of: updated).contains("updated memory"))

        // … and the debt list is now empty.
        let relisted = try await dispatcher.dispatch(
            name: "moot_memory_list",
            arguments: .object([
                "wing": .string(LocusKit.defaultWingName),
                "filter": .string("missing_subject"),
            ]))
        #expect(text(of: relisted).contains("0 drawer(s)"),
                "debt must be cleared after setSubject: \(text(of: relisted))")
    }

    @Test func setSubjectWithoutSubjectArgIsRejected() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "subject-setsubject-missing"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let id = try await captureWithoutSubject(
            kit: kit, handle: handle, content: "needs a subject", room: "subject-tests")

        do {
            _ = try await dispatcher.dispatch(
                name: "moot_update_memory",
                arguments: .object([
                    "id": .string(id),
                    "mutation": .string("setSubject"),
                ]))
            Issue.record("setSubject without subject arg must be rejected")
        } catch let error as JSONRPCError {
            #expect(error.message.contains("subject"))
        }
    }

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
}
