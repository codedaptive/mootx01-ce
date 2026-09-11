import Foundation
import Testing
@testable import AriaMCP

@Suite("ARIA v2 typed estate diagnostics")
struct AriaV2EstateDiagnosticsTests {
    private let estateID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!

    @Test("All diagnostics accept only the shared optional estate_id")
    func strictRequests() async throws {
        let diagnostics = service(provider: FakeEstateDiagnosticsProvider(estateID: estateID))
        for operation in [
            diagnostics.ping, diagnostics.status, diagnostics.map,
            diagnostics.drainStatus, diagnostics.rebuildStatus, diagnostics.timingReport,
        ] {
            _ = try await operation(.object(["estate_id": .string(estateID.uuidString.uppercased())]))
            await #expect(throws: JSONRPCError.self) {
                _ = try await operation(.object(["unknown": .bool(true)]))
            }
            await #expect(throws: JSONRPCError.self) {
                _ = try await operation(.object(["estate_id": .string("not-a-uuid")]))
            }
        }
    }

    @Test("Each service projects its operation-specific typed data")
    func typedDataProjection() async throws {
        let provider = FakeEstateDiagnosticsProvider(estateID: estateID)
        let diagnostics = service(provider: provider)

        let ping = try await diagnostics.ping(arguments: .object([:]))
        let status = try await diagnostics.status(arguments: .object([:]))
        let map = try await diagnostics.map(arguments: .object([:]))
        let drains = try await diagnostics.drainStatus(arguments: .object([:]))
        let rebuild = try await diagnostics.rebuildStatus(arguments: .object([:]))
        let timing = try await diagnostics.timingReport(arguments: .object([:] ))

        #expect((data(ping).map { Set($0.keys) } ?? Set<String>()) == Set(["estate_id", "estate_name", "state", "build_serial"]))
        #expect(data(ping)?["state"] == .string("mounted"))
        #expect(data(ping)?["build_serial"] == .string("fixture-build"))
        // recall_trace_count is present because the fixture supplies a count;
        // shared_content_migration is absent because the fixture has no
        // migration record, which is the shape an estate that never ran
        // detection returns.
        #expect((data(status).map { Set($0.keys) } ?? Set<String>()) == Set([
            "estate_id", "estate_name", "memory_count", "fact_count", "drains",
            "fdc_recalculation", "recall_trace_count", "sync_state",
            "subjects_bearing", "subjects_eligible",
        ]))
        #expect(data(status)?["memory_count"] == .integer(2))
        #expect(data(map)?["wings"]?.arrayValue?.first?.objectValue?["rooms"]?.arrayValue?.count == 1)
        #expect((data(drains).map { Set($0.keys) } ?? Set<String>()) == Set(["drains"]))
        #expect((data(drains)?["drains"]?.arrayValue?.first?.objectValue.map { Set($0.keys) } ?? Set<String>()) == Set(["name", "state", "pending"]))
        #expect(data(drains)?["drains"]?.arrayValue?.first?.objectValue?["pending"] == .integer(3))
        #expect(data(rebuild)?["state"] == .string("running"))
        #expect((data(rebuild).map { Set($0.keys) } ?? Set<String>()) == Set(["state"]))
        #expect((data(timing).map { Set($0.keys) } ?? Set<String>()) == Set(["since_ms", "watermark_ms", "truncated"]))
        #expect(data(timing)?["since_ms"] == .integer(0))
        #expect(data(timing)?["watermark_ms"] == .integer(1_700_000_001_000))
        #expect(meta(status)?["effect"] == .string("read"))
        #expect(meta(status)?["session_id"] == .string("test-session"))
        #expect(meta(status)?["observed_at"] == .string("2023-11-14T22:13:20Z"))
        #expect(await provider.calls == [.estatePing, .estateStatus, .estateMap, .drainStatus, .rebuildStatus, .timingReport])
    }

    @Test("Access refusal prevents a lower provider call")
    func accessGateRunsBeforeProvider() async throws {
        let provider = FakeEstateDiagnosticsProvider(estateID: estateID)
        let refusal = AriaV2OperationalRefusal(
            code: "estate_access_denied", message: "Session may not inspect this estate.", retryable: false)
        let diagnostics = service(provider: provider, gate: RefusingGate(refusal: refusal))
        let response = try await diagnostics.status(arguments: .object([:]))

        #expect(response.objectValue?["isError"] == .bool(true))
        #expect(response.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue?["code"] == .string("estate_access_denied"))
        #expect(await provider.calls.isEmpty)
    }

    @Test("Unavailable ping is an operational refusal")
    func unavailablePingIsRefusal() async throws {
        let provider = FakeEstateDiagnosticsProvider(
            estateID: estateID,
            pingRefusal: .init(
                code: "estate_unavailable",
                message: "The selected estate is quiesced and not accepting new work.",
                retryable: false))
        let response = try await service(provider: provider).ping(arguments: .object([:]))
        #expect(response.objectValue?["isError"] == .bool(true))
        #expect(response.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue?["code"] == .string("estate_unavailable"))
    }

    @Test("A different selected estate fails before access or collection")
    func selectedEstateMustMatchContext() async throws {
        let provider = FakeEstateDiagnosticsProvider(estateID: estateID)
        let diagnostics = service(provider: provider)
        await #expect(throws: JSONRPCError.self) {
            _ = try await diagnostics.ping(arguments: .object([
                "estate_id": .string(UUID().uuidString),
            ]))
        }
        #expect(await provider.calls.isEmpty)
    }

    private func service(
        provider: FakeEstateDiagnosticsProvider,
        gate: any AriaV2EstateDiagnosticsAccessGate = AriaV2AllowEstateDiagnosticsAccess()
    ) -> AriaV2EstateDiagnostics {
        AriaV2EstateDiagnostics(
            provider: provider,
            context: .init(
                estateID: estateID,
                estateName: "Fixture Estate",
                callerID: "fixture-caller",
                serverIdentity: "fixture-server",
                sessionID: "test-session",
                buildSerial: "fixture-build",
                now: { Date(timeIntervalSince1970: 1_700_000_000) },
                accessGate: gate))
    }

    private func data(_ response: JSONValue) -> [String: JSONValue]? {
        response.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue
    }

    private func meta(_ response: JSONValue) -> [String: JSONValue]? {
        response.objectValue?["structuredContent"]?.objectValue?["meta"]?.objectValue
    }
}

private actor FakeEstateDiagnosticsProvider: AriaV2EstateDiagnosticsProvider {
    let estateID: UUID
    let pingRefusal: AriaV2OperationalRefusal?
    private(set) var calls: [AriaV2EstateDiagnosticOperation] = []

    init(estateID: UUID, pingRefusal: AriaV2OperationalRefusal? = nil) {
        self.estateID = estateID
        self.pingRefusal = pingRefusal
    }

    func ping(context: AriaV2EstateDiagnosticsContext) async throws -> AriaV2EstatePingResult {
        calls.append(.estatePing)
        if let pingRefusal { return .refusal(pingRefusal) }
        return .mounted(.init(
            estateID: estateID,
            estateName: context.estateName,
            state: "mounted",
            buildSerial: context.buildSerial))
    }

    func status(context: AriaV2EstateDiagnosticsContext) async throws -> AriaV2EstateStatusData {
        calls.append(.estateStatus)
        return .init(
            estateID: estateID,
            estateName: context.estateName,
            memoryCount: 2,
            factCount: 4,
            drains: [.init(name: "corpus_encode", state: "draining", pending: 3)],
            fdcRecalculation: "missing",
            recallTraceCount: 7,
            syncState: "local-only",
            subjectsBearing: 1,
            subjectsEligible: 2,
            sharedContentMigration: nil)
    }

    func map(context: AriaV2EstateDiagnosticsContext) async throws -> AriaV2EstateMapData {
        _ = context
        calls.append(.estateMap)
        return .init(estateID: estateID, wings: [.init(name: "Memory", rooms: [.init(name: "Planning", memoryCount: 3)])])
    }

    func drains(context: AriaV2EstateDiagnosticsContext) async throws -> AriaV2DrainStatusData {
        _ = context
        calls.append(.drainStatus)
        return .init(drains: [.init(name: "corpus_encode", state: "draining", pending: 3)])
    }

    func rebuild(context: AriaV2EstateDiagnosticsContext) async throws -> AriaV2RebuildStatusData {
        _ = context
        calls.append(.rebuildStatus)
        return .init(state: "running")
    }

    func timing(context: AriaV2EstateDiagnosticsContext) async throws -> AriaV2TimingReportData {
        _ = context
        calls.append(.timingReport)
        return .init(sinceMilliseconds: 0, watermarkMilliseconds: 1_700_000_001_000, truncated: false)
    }
}

private struct RefusingGate: AriaV2EstateDiagnosticsAccessGate {
    let refusal: AriaV2OperationalRefusal

    func admit(
        _ operation: AriaV2EstateDiagnosticOperation,
        context: AriaV2EstateDiagnosticsContext
    ) async -> AriaV2OperationalRefusal? {
        _ = operation
        _ = context
        return refusal
    }
}
