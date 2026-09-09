import AriaMCPWire
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import Testing
@testable import AriaMCP

@Suite("ARIA v2 production memory-list snapshot provider")
struct AriaV2MemoryListProductionSnapshotProviderTests {
    @Test("capture provenance admits only raw normal and elevated")
    func captureProvenanceAdmission() {
        for raw in [0, 16] {
            #expect(AriaV2MemoryListProductionSnapshotProvider.isPublicCaptureProvenance(Int64(raw) << 30))
        }
        for raw in [32, 48, 63] {
            #expect(!AriaV2MemoryListProductionSnapshotProvider.isPublicCaptureProvenance(Int64(raw) << 30))
        }
    }

    @Test("projects only current bulk-exportable rows in the requested scope")
    func filtersAndProjectsCompleteSnapshot() async throws {
        let fixture = try await makeFixture()
        let authority = TestAuthorizationAuthority(states: [fixture.state, fixture.state, fixture.state])
        let provider = AriaV2MemoryListProductionSnapshotProvider(
            kit: fixture.kit, handle: fixture.handle, authorizationAuthority: authority)

        let all = try await provider.immutableAuthorizedSnapshot(
            estateID: fixture.handle.estateUUID, wing: "Memory", room: "Inbox", filter: nil,
            authorization: fixture.authorization)
        #expect(all.rows.count == 2)
        let publicRow = try #require(all.rows.first {
            $0.projection["subject"] == .string("Public subject")
        })
        #expect(publicRow.visibilityState == "bulk_exportable")
        #expect(publicRow.eligibilityState == "current")
        #expect(publicRow.ancestryNames == ["Memory", "Inbox"])
        #expect(publicRow.projection == [
            "fetch": fetch(memoryID: publicRow.memoryID),
            "provenance": .string("federation_aggregate"),
            "subject": .string("Public subject"),
        ])

        let debt = try await provider.immutableAuthorizedSnapshot(
            estateID: fixture.handle.estateUUID, wing: "Memory", room: "Inbox", filter: "missing_subject",
            authorization: fixture.authorization)
        #expect(debt.rows.count == 1)
        #expect(debt.rows[0].projection == [
            "fetch": fetch(memoryID: debt.rows[0].memoryID),
        ])

        let elevated = try await provider.immutableAuthorizedSnapshot(
            estateID: fixture.handle.estateUUID, wing: "Memory", room: "Other", filter: nil,
            authorization: fixture.authorization)
        #expect(elevated.rows.count == 1)
        #expect(elevated.rows[0].projection["subject"] == .string("Elevated provenance control"))
    }

    @Test("refuses if authorization generation changes around snapshot capture")
    func refusesChangedAuthorization() async throws {
        let fixture = try await makeFixture()
        let changed = AriaV2MemoryListAuthorizationState(
            estateID: fixture.handle.estateUUID,
            callerID: fixture.authorization.callerID,
            contextID: fixture.authorization.contextID,
            policyVersion: fixture.authorization.policyVersion,
            generation: "generation-2"
        )
        let authority = TestAuthorizationAuthority(states: [fixture.state, changed, changed])
        let provider = AriaV2MemoryListProductionSnapshotProvider(
            kit: fixture.kit, handle: fixture.handle, authorizationAuthority: authority)

        await #expect(throws: AriaV2MemoryListProductionSnapshotError.authorizationChanged) {
            _ = try await provider.immutableAuthorizedSnapshot(
                estateID: fixture.handle.estateUUID, wing: "Memory", room: nil, filter: nil,
                authorization: fixture.authorization)
        }
    }

    private func makeFixture() async throws -> (
        kit: GeniusLocusKit,
        handle: EstateHandle,
        authorization: AriaV2MemoryListAuthorization,
        state: AriaV2MemoryListAuthorizationState
    ) {
        let storage = InMemoryStorage(configuration: .init(estateID: UUID(), backend: .inMemory))
        let kit = GeniusLocusKit()
        let handle = try await kit.open(storage: storage, owner: .init(ownerIdentifier: "provider-test"))
        let estate = try await kit.estate(for: handle)
        _ = try await estate.capture(CaptureFrame(
            content: "public record", channel: .typed, room: "Inbox", latticeAnchor: .udc("004"),
            addedBy: "test", embeddingModelID: "test-model", sourceType: .federationAggregate,
            exportability: .public_, wing: "Memory", subject: "Public subject"
        ))
        _ = try await estate.capture(CaptureFrame(
            content: "subject debt", channel: .typed, room: "Inbox", latticeAnchor: .udc("004"),
            addedBy: "test", embeddingModelID: "test-model", exportability: .public_, wing: "Memory"
        ))
        _ = try await estate.capture(CaptureFrame(
            content: "restricted record", channel: .typed, room: "Inbox", latticeAnchor: .udc("004"),
            addedBy: "test", embeddingModelID: "test-model", sensitivity: .restricted,
            exportability: .public_, wing: "Memory"
        ))
        _ = try await estate.capture(CaptureFrame(
            content: "elevated provenance control", channel: .typed, room: "Other", latticeAnchor: .udc("004"),
            addedBy: "test", embeddingModelID: "test-model", provenanceSensitivity: .elevated,
            exportability: .public_, wing: "Memory", subject: "Elevated provenance control"
        ))
        _ = try await estate.capture(CaptureFrame(
            content: "restricted provenance hidden", channel: .typed, room: "Inbox", latticeAnchor: .udc("004"),
            addedBy: "test", embeddingModelID: "test-model", provenanceSensitivity: .restricted,
            exportability: .public_, wing: "Memory", subject: "Restricted provenance hidden"
        ))
        _ = try await estate.capture(CaptureFrame(
            content: "secret provenance hidden", channel: .typed, room: "Inbox", latticeAnchor: .udc("004"),
            addedBy: "test", embeddingModelID: "test-model", provenanceSensitivity: .secret,
            exportability: .public_, wing: "Memory", subject: "Secret provenance hidden"
        ))
        let authorization = AriaV2MemoryListAuthorization(
            callerID: "caller", contextID: "context", policyVersion: "memory-list-v1")
        let state = AriaV2MemoryListAuthorizationState(
            estateID: handle.estateUUID, callerID: authorization.callerID,
            contextID: authorization.contextID, policyVersion: authorization.policyVersion,
            generation: "generation-1")
        return (kit, handle, authorization, state)
    }

    private func fetch(memoryID: UUID) -> JSONValue {
        .object([
            "tool": .string("moot_memory_get"),
            "arguments": .object([
                "memory_id": .string(AriaV2ArgumentDecoder.canonicalUUID(memoryID)),
            ]),
        ])
    }
}

private actor TestAuthorizationAuthority: AriaV2MemoryListAuthorizationAuthority {
    private var states: [AriaV2MemoryListAuthorizationState]
    private var index = 0

    init(states: [AriaV2MemoryListAuthorizationState]) {
        self.states = states
    }

    func authorizeMemoryList(
        estateID: UUID,
        authorization: AriaV2MemoryListAuthorization
    ) async throws -> AriaV2MemoryListAuthorizationState {
        _ = (estateID, authorization)
        let position = min(index, states.count - 1)
        index += 1
        return states[position]
    }
}
