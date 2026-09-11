import AriaMCPWire
import Foundation
import GeniusLocusKit
import PersistenceKit
import PersistenceKitInMemory
import Testing
@testable import AriaMCP

@Suite("ARIA v2 direct dream lower lane")
struct AriaV2DreamTests {
    @Test("request accepts estate_id, now, and associates; rejects unknown keys and malformed values")
    func strictRequest() throws {
        let estateID = UUID()
        let request = try AriaV2Dream.Request(arguments: .object([
            "estate_id": .string(estateID.uuidString),
        ]))
        #expect(request.estateID == estateID)

        // now and associates are now admitted; verify they are accepted
        let withNow = try AriaV2Dream.Request(arguments: .object([
            "now": .string("2026-01-01T00:00:00Z"),
        ]))
        #expect(withNow.now != nil)

        let withAssociates = try AriaV2Dream.Request(arguments: .object([
            "associates": .string("all"),
        ]))
        #expect(withAssociates.associates == "all")

        for value in [
            // unknown key
            JSONValue.object(["estateID": .string(estateID.uuidString)]),
            // malformed uuid
            .object(["estate_id": .string("not-a-uuid")]),
            // malformed now — not a valid ISO 8601 string
            .object(["now": .string("not-a-date")]),
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

        func admit(
            requestedEstateID: UUID?,
            requestedNow: Date?
        ) async -> Result<AriaV2Dream.Admission, AriaV2Dream.Failure> {
            guard requestedEstateID == nil || requestedEstateID == admission.estateID else {
                return .failure(.refusal(.init(code: "estate_unavailable", message: "Estate unavailable.", retryable: false)))
            }
            // Propagate caller now when provided — allows tests to verify the
            // now propagates through to the admission and lower engine.
            if let requestedNow {
                let updated = AriaV2Dream.Admission(
                    estateID: admission.estateID,
                    handle: admission.handle,
                    callerBinding: admission.callerBinding,
                    authorizationGeneration: admission.authorizationGeneration,
                    now: requestedNow)
                return .success(updated)
            }
            return .success(admission)
        }

        func revalidate(_ admission: AriaV2Dream.Admission) async -> Result<Void, AriaV2Dream.Failure> {
            .success(())
        }
    }

    /// Authority that enforces the 24-hour future ceiling on a caller-proposed
    /// `now`, exactly as `DispatcherV2DreamAuthority` does in production.
    private struct CeilingAuthority: AriaV2Dream.Authority {
        let admission: AriaV2Dream.Admission
        let wallNow: Date

        func admit(
            requestedEstateID: UUID?,
            requestedNow: Date?
        ) async -> Result<AriaV2Dream.Admission, AriaV2Dream.Failure> {
            if let proposed = requestedNow {
                let ceiling = wallNow.addingTimeInterval(24 * 3600)
                guard proposed <= ceiling else {
                    return .failure(.invalidArgument(
                        "Argument 'now' must not be more than 24 hours in the future."))
                }
                let updated = AriaV2Dream.Admission(
                    estateID: admission.estateID,
                    handle: admission.handle,
                    callerBinding: admission.callerBinding,
                    authorizationGeneration: admission.authorizationGeneration,
                    now: proposed)
                return .success(updated)
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

    @Test("now more than 24 hours in the future is refused as -32602 and never reaches lower engine")
    func nowFarFutureRefused() async throws {
        let wallNow = Date(timeIntervalSince1970: 1_700_000_000)
        let auth = try await dreamCeilingAuthority(wallNow: wallNow)
        // DreamLower counts how many times it is called; zero calls proves the
        // destructive path was never reached.
        let lower = CountingLower()
        let service = AriaV2Dream.Service(authority: auth, lower: lower)
        let farFuture = wallNow.addingTimeInterval(25 * 3600)
        let fmt = ISO8601DateFormatter()
        await #expect(throws: JSONRPCError.self) {
            _ = try await service.execute(arguments: .object([
                "now": .string(fmt.string(from: farFuture)),
            ]))
        }
        await #expect(lower.callCount == 0, "lower must not run when now is out of range")
    }

    @Test("now within the 24-hour window is accepted and propagates to the admission clock")
    func nowPropagatesInsideAdmission() async throws {
        let wallNow = Date(timeIntervalSince1970: 1_700_000_000)
        let auth = try await dreamCeilingAuthority(wallNow: wallNow)
        // Use a lower that records the admission.now it receives.
        let lower = NowCaptureLower()
        let service = AriaV2Dream.Service(authority: auth, lower: lower)
        let callerNow = wallNow.addingTimeInterval(2 * 3600) // 2 hours ahead — within ceiling
        let fmt = ISO8601DateFormatter()
        _ = try await service.execute(arguments: .object([
            "now": .string(fmt.string(from: callerNow)),
        ]))
        let captured = await lower.capturedNow
        // ISO8601DateFormatter round-trips with 1-second precision; allow ±1 s.
        let diff = abs((captured ?? .distantPast).timeIntervalSince(callerNow))
        #expect(diff <= 1, "admission.now must match the provided caller now; got diff=\(diff)s")
    }

    private func dreamAuthority() async throws -> DreamAuthority {
        let storage = InMemoryStorage(configuration: .init(estateID: UUID(), backend: .inMemory))
        let kit = GeniusLocusKit()
        let handle = try await kit.open(storage: storage, owner: .init(ownerIdentifier: "dream-test"))
        return DreamAuthority(admission: .init(
            estateID: handle.estateUUID, handle: handle, callerBinding: "test-caller",
            authorizationGeneration: "test-generation", now: Date(timeIntervalSince1970: 1_700_000_000)))
    }

    private func dreamCeilingAuthority(wallNow: Date) async throws -> CeilingAuthority {
        let storage = InMemoryStorage(configuration: .init(estateID: UUID(), backend: .inMemory))
        let kit = GeniusLocusKit()
        let handle = try await kit.open(storage: storage, owner: .init(ownerIdentifier: "dream-ceiling-test"))
        return CeilingAuthority(
            admission: .init(
                estateID: handle.estateUUID, handle: handle, callerBinding: "test-caller",
                authorizationGeneration: "test-generation", now: wallNow),
            wallNow: wallNow)
    }

    private actor CountingLower: AriaV2Dream.Lower {
        var callCount: Int = 0
        func run(
            _ admission: AriaV2Dream.Admission,
            request: AriaV2Dream.Request
        ) async -> Result<AriaV2Dream.SourceOutcome, AriaV2Dream.Failure> {
            callCount += 1
            return .success(.completed(.init(
                candidatesConsidered: 0, proposalsEmitted: [],
                suppressedDuplicates: 0, belowThreshold: 0,
                contradictionsProposed: 0, contradictionCandidatesBorderline: 0)))
        }
    }

    private actor NowCaptureLower: AriaV2Dream.Lower {
        var capturedNow: Date?
        func run(
            _ admission: AriaV2Dream.Admission,
            request: AriaV2Dream.Request
        ) async -> Result<AriaV2Dream.SourceOutcome, AriaV2Dream.Failure> {
            capturedNow = admission.now
            return .success(.completed(.init(
                candidatesConsidered: 0, proposalsEmitted: [],
                suppressedDuplicates: 0, belowThreshold: 0,
                contradictionsProposed: 0, contradictionCandidatesBorderline: 0)))
        }
    }
}
