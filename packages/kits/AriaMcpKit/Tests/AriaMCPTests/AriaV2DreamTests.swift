import AriaMCPWire
import Foundation
import GeniusLocusKit
import PersistenceKit
import PersistenceKitInMemory
import Testing
@testable import AriaMCP

@Suite("ARIA v2 direct dream lower lane")
struct AriaV2DreamTests {
    @Test("request accepts only the canonical selected-estate key")
    func strictRequest() throws {
        let estateID = UUID()
        let request = try AriaV2Dream.Request(arguments: .object([
            "estate_id": .string(estateID.uuidString),
        ]))
        #expect(request.estateID == estateID)

        for value in [
            JSONValue.object(["estateID": .string(estateID.uuidString)]),
            .object(["estate_id": .string("not-a-uuid")]),
            .object(["estate_id": .string(estateID.uuidString), "now": .string("2026-01-01T00:00:00Z")]),
        ] {
            #expect(throws: JSONRPCError.self) {
                _ = try AriaV2Dream.Request(arguments: value)
            }
        }
    }

    @Test("completed receipt projects the frozen dream data shape")
    func completedReceipt() async throws {
        let authority = try await dreamAuthority()
        let service = AriaV2Dream.Service(
            authority: authority,
            lower: DreamLower(outcome: .completed(.init(
                candidatesConsidered: 7, proposalsEmitted: ["drawer-a", "drawer-b"],
                suppressedDuplicates: 2, belowThreshold: 1,
                contradictionsProposed: 4, contradictionCandidatesBorderline: 5,
                subjectsBackfilled: 6, associationsWritten: 7,
                associationsNonUniqueProbes: 8))))
        let result = try await service.execute(arguments: .object([:]))
        let data = try #require(result.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue)
        #expect(data["candidatesConsidered"] == .integer(7))
        #expect(data["proposalsEmitted"] == .array([.string("drawer-a"), .string("drawer-b")]))
        #expect(data["suppressedDuplicates"] == .integer(2))
        #expect(data["belowThreshold"] == .integer(1))
        #expect(data["contradictionsProposed"] == .integer(4))
        #expect(data["contradictionCandidatesBorderline"] == .integer(5))
        #expect(data["subjectsBackfilled"] == .integer(6))
        #expect(data["associationsWritten"] == .integer(7))
        #expect(data["associationsNonUniqueProbes"] == .integer(8))
    }

    @Test("scheduler source status is not replaced by a completed result")
    func schedulerStatus() async throws {
        let service = AriaV2Dream.Service(authority: try await dreamAuthority(), lower: DreamLower(outcome: .alreadyRunning))
        let result = try await service.execute(arguments: .object([:]))
        let error = try #require(result.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue)
        #expect(error["code"] == .string("dream_already_running"))
    }

    @Test("lower refusal remains structured and distinct from malformed input")
    func lowerRefusal() async throws {
        let refusal = AriaV2OperationalRefusal(code: "dream_unavailable", message: "Dream engine unavailable.", retryable: true)
        let service = AriaV2Dream.Service(authority: try await dreamAuthority(), lower: DreamLower(refusal: refusal))
        let result = try await service.execute(arguments: .object([:]))
        #expect(result.objectValue?["isError"] == .bool(true))
        #expect(result.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue?["code"] == .string("dream_unavailable"))
    }

    private struct DreamAuthority: AriaV2Dream.Authority {
        let admission: AriaV2Dream.Admission

        func admit(requestedEstateID: UUID?) async -> Result<AriaV2Dream.Admission, AriaV2Dream.Failure> {
            guard requestedEstateID == nil || requestedEstateID == admission.estateID else {
                return .failure(.refusal(.init(code: "estate_unavailable", message: "Estate unavailable.", retryable: false)))
            }
            return .success(admission)
        }

        func revalidate(_ admission: AriaV2Dream.Admission) async -> Result<Void, AriaV2Dream.Failure> {
            .success(())
        }
    }

    private struct DreamLower: AriaV2Dream.Lower {
        let result: Result<AriaV2Dream.SourceOutcome, AriaV2Dream.Failure>

        init(outcome: AriaV2Dream.SourceOutcome) { result = .success(outcome) }
        init(refusal: AriaV2OperationalRefusal) { result = .failure(.refusal(refusal)) }

        func run(
            _ admission: AriaV2Dream.Admission,
            request: AriaV2Dream.Request
        ) async -> Result<AriaV2Dream.SourceOutcome, AriaV2Dream.Failure> {
            result
        }
    }

    private func dreamAuthority() async throws -> DreamAuthority {
        let storage = InMemoryStorage(configuration: .init(estateID: UUID(), backend: .inMemory))
        let kit = GeniusLocusKit()
        let handle = try await kit.open(storage: storage, owner: .init(ownerIdentifier: "dream-test"))
        return DreamAuthority(admission: .init(
            estateID: handle.estateUUID, handle: handle, callerBinding: "test-caller",
            authorizationGeneration: "test-generation", now: Date(timeIntervalSince1970: 1_700_000_000)))
    }
}
