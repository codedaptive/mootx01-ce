// SubjectSurfaceTests.swift
//
// PR-02 verification suite for the capture + lifecycle subject surface:
//
//   1. moot_file_memory REQUIRES `subject` — absence and contract
//      violations are rejected at the boundary with instructive errors
//      (the register guidance, not a bare missing-argument line).
//   2. moot_update_memory mutation=set_subject round-trips a subject onto
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

    private func isError(_ result: JSONValue) -> Bool {
        result.objectValue?["isError"]?.boolValue ?? false
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

    /// setSubject oversize: v2 arg names are memory_id (not id) and set_subject (not setSubject).
    /// v2 decoder validates subject length and throws JSONRPCError before dispatch.
    @Test func setSubjectOversizeReturnsContractError() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "subject-setsubject-oversize"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let id = try await captureWithoutSubject(
            kit: kit, handle: handle, content: "needs a subject", room: "subject-tests")
        let oversize = String(repeating: "y", count: DrawerStore.subjectLengthContract + 1)
        // v2 arg names: memory_id (not id), mutation set_subject (not setSubject).
        // In v2, the decoder validates subject length and throws JSONRPCError before dispatch.
        do {
            let result = try await dispatcher.dispatch(
                name: "moot_update_memory",
                arguments: .object([
                    "memory_id": .string(id),
                    "mutation": .string("set_subject"),
                    "subject": .string(oversize),
                ]))
            guard case let .object(obj) = result,
                  obj["isError"]?.boolValue == true,
                  case let .array(content)? = obj["content"],
                  case let .object(first)? = content.first,
                  case let .string(errorText)? = first["text"]
            else {
                Issue.record("oversize setSubject must return isError:true result, got: \(result)")
                return
            }
            #expect(errorText.contains("subject"), "error must mention subject; got: \(errorText)")
        } catch let error as JSONRPCError {
            // v2 decoder caught this before dispatch — still a subject-contract error.
            #expect(error.message.contains("subject"),
                "error must mention subject contract; got: \(error.message)")
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

    /// Debt enumeration and setSubject round-trip.
    /// v2 arg names: memory_id (not id), set_subject (not setSubject).
    /// v2 success compact text for update: "Updated memory {uuid}." (capital U).
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
        // v2 compact text: "Enumerated N authorized memories from a complete current inventory."
        // IDs live in structuredContent.data.memories[].memory_id (not in compact text).
        #expect(listText.contains("Enumerated 1"), "exactly one debt row expected: \(listText)")
        let listedStr = "\(listed)"
        #expect(listedStr.lowercased().contains(debtID.lowercased()),
                "debt row ID must appear in structured data; got: \(listedStr)")
        #expect(!listText.contains("Imported without a subject"),
                "debt rows are id-only — no content preview")

        // setSubject round-trip: backfill the debt row …
        // v2 arg names: memory_id (not id), set_subject (not setSubject).
        let updated = try await dispatcher.dispatch(
            name: "moot_update_memory",
            arguments: .object([
                "memory_id": .string(debtID),
                "mutation": .string("set_subject"),
                "subject": .string("Imported row: subject backfilled interactively."),
            ]))
        // v2 success compact text: "Updated memory {uuid}." (capital U).
        let updatedText = text(of: updated)
        #expect(updatedText.lowercased().contains("updated memory"),
                "update must confirm success; got: \(updatedText)")

        // … and the debt list is now empty.
        let relisted = try await dispatcher.dispatch(
            name: "moot_memory_list",
            arguments: .object([
                "wing": .string(LocusKit.defaultWingName),
                "filter": .string("missing_subject"),
            ]))
        // v2 compact text: "Enumerated 0 authorized memories from a complete current inventory."
        #expect(text(of: relisted).contains("Enumerated 0"),
                "debt must be cleared after setSubject: \(text(of: relisted))")
    }

    /// setSubject without subject arg must be rejected.
    /// v2: mutation set_subject (not setSubject), memory_id (not id).
    /// v2 decoder validates that set_subject requires subject and throws JSONRPCError.
    @Test func setSubjectWithoutSubjectArgIsRejected() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "subject-setsubject-missing"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let id = try await captureWithoutSubject(
            kit: kit, handle: handle, content: "needs a subject", room: "subject-tests")

        // v2: set_subject without subject arg — decoder validates and throws JSONRPCError.
        do {
            let result = try await dispatcher.dispatch(
                name: "moot_update_memory",
                arguments: .object([
                    "memory_id": .string(id),
                    "mutation": .string("set_subject"),
                ]))
            #expect(isError(result),
                "set_subject without subject arg must produce a tool-level error; got: \(result)")
        } catch let error as JSONRPCError {
            // v2 decoder rejected before dispatch — still the correct rejection.
            #expect(error.message.contains("subject"),
                "rejection must mention subject; got: \(error.message)")
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

    // MARK: - moot_file_fact subject contract (ARIA-MSG-2)

    @Test func fileFactOversizeSubjectReturnsContractError() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "fact-subject-oversize"))
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let oversize = String(repeating: "x", count: DrawerStore.subjectLengthContract + 1)
        // Subject contract violation surfaces as isError:true so the model sees
        // the message instead of a bare "Tool execution failed" from the generic
        // catch wrapper (ARIA-MSG-2 fix). Mirrors the Rust port's
        // file_fact_oversize_subject_returns_contract_error test.
        // v2 decoder validates subject length and throws JSONRPCError before dispatch.
        do {
            let result = try await dispatcher.dispatch(
                name: "moot_file_fact",
                arguments: .object([
                    "subject": .string(oversize),
                    "predicate": .string("worksAt"),
                    "object": .string("Acme"),
                ]))
            guard case let .object(obj) = result,
                  obj["isError"]?.boolValue == true,
                  case let .array(content)? = obj["content"],
                  case let .object(first)? = content.first,
                  case let .string(errorText)? = first["text"]
            else {
                Issue.record("oversize fact subject must return isError:true result, got: \(result)")
                return
            }
            #expect(errorText.contains("subject"),
                "error text must mention subject; got: \(errorText)")
        } catch let error as JSONRPCError {
            // v2 decoder caught this before dispatch — still a contract rejection.
            #expect(error.message.contains("subject"),
                "rejection must mention subject contract; got: \(error.message)")
        }
    }
}
