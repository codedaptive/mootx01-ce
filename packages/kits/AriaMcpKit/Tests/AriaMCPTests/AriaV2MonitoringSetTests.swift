import Testing
@testable import AriaMCP
import AriaMCPWire

private actor MonitoringSetControl: MonitoringControl {
    private var enabled: Bool?
    private let unreadableAfterWrite: Bool
    private let ignoreWrite: Bool
    private var reads = 0
    private var writes = 0

    init(enabled: Bool?, unreadableAfterWrite: Bool = false, ignoreWrite: Bool = false) {
        self.enabled = enabled
        self.unreadableAfterWrite = unreadableAfterWrite
        self.ignoreWrite = ignoreWrite
    }

    func read() async -> Bool? {
        reads += 1
        return unreadableAfterWrite && writes > 0 ? nil : enabled
    }

    func set(_ enabled: Bool) async {
        writes += 1
        if !ignoreWrite { self.enabled = enabled }
    }

    func counts() -> (reads: Int, writes: Int) {
        (reads, writes)
    }
}

@Suite("ARIA v2 monitoring set core")
struct AriaV2MonitoringSetTests {
    @Test("Decoder accepts exactly enabled as a boolean")
    func strictDecoder() throws {
        let request = try AriaV2MonitoringSet.Request(arguments: .object(["enabled": .bool(true)]))
        #expect(request.enabled)

        for arguments in [
            JSONValue.object([:]),
            .object(["enabled": .string("true")]),
            .object(["enabled": .bool(true), "extra": .bool(false)]),
        ] {
            do {
                _ = try AriaV2MonitoringSet.Request(arguments: arguments)
                Issue.record("monitoring_set accepted invalid arguments")
            } catch let error as JSONRPCError {
                #expect(error.code == JSONRPCErrorCode.invalidParams)
                #expect(error.data?.objectValue?["code"] == .string("invalid_argument"))
            }
        }
    }

    @Test("Confirmed write reports actual enabled state in a write envelope")
    func confirmedWrite() async throws {
        let control = MonitoringSetControl(enabled: false)
        let request = try AriaV2MonitoringSet.Request(arguments: .object(["enabled": .bool(true)]))
        let result = await AriaV2MonitoringSet.execute(request, monitoringControl: control)
        let rendered = AriaV2MonitoringSet.render(
            result,
            buildID: "test-build",
            capabilityDigest: "test-digest"
        )

        let structured = rendered.objectValue?["structuredContent"]?.objectValue
        #expect(structured?["data"]?.objectValue?["monitoring"] == .string("enabled"))
        #expect(structured?["meta"]?.objectValue?["effect"] == .string("write"))
        #expect(structured?["meta"]?.objectValue?["build_id"] == .string("test-build"))
        #expect(rendered.objectValue?["isError"] == .bool(false))
        let counts = await control.counts()
        #expect(counts.writes == 1)
        #expect(counts.reads == 1)
    }

    @Test("Unavailable control returns an operational refusal without a write")
    func unavailableControl() async throws {
        let request = try AriaV2MonitoringSet.Request(arguments: .object(["enabled": .bool(false)]))
        let result = await AriaV2MonitoringSet.execute(request, monitoringControl: nil)
        let rendered = AriaV2MonitoringSet.render(
            result,
            buildID: "test-build",
            capabilityDigest: "test-digest"
        )

        #expect(rendered.objectValue?["isError"] == .bool(true))
        #expect(
            rendered.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue?["code"]
                == .string("monitoring_unavailable")
        )
    }

    @Test("Unverified reread reports a status-check recovery and does not repeat the write")
    func unverifiedWrite() async throws {
        let control = MonitoringSetControl(enabled: false, unreadableAfterWrite: true)
        let request = try AriaV2MonitoringSet.Request(arguments: .object(["enabled": .bool(true)]))
        let result = await AriaV2MonitoringSet.execute(request, monitoringControl: control)
        let rendered = AriaV2MonitoringSet.render(
            result,
            buildID: "test-build",
            capabilityDigest: "test-digest"
        )

        let error = rendered.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue
        #expect(error?["code"] == .string("monitoring_unverified"))
        #expect(error?["recovery"]?.objectValue?["tool"] == .string("moot_monitoring_status"))
        #expect(error?["recovery"]?.objectValue?["arguments"] == .object([:]))
        let counts = await control.counts()
        #expect(counts.writes == 1)
        #expect(counts.reads == 1)
    }

    @Test("Mismatched reread is unverified rather than a false success")
    func mismatchedWrite() async throws {
        let control = MonitoringSetControl(enabled: false, ignoreWrite: true)
        let request = try AriaV2MonitoringSet.Request(arguments: .object(["enabled": .bool(true)]))
        let result = await AriaV2MonitoringSet.execute(request, monitoringControl: control)
        let rendered = AriaV2MonitoringSet.render(
            result,
            buildID: "test-build",
            capabilityDigest: "test-digest"
        )

        let error = rendered.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue
        #expect(error?["code"] == .string("monitoring_unverified"))
        #expect(error?["retryable"] == .bool(false))
        let counts = await control.counts()
        #expect(counts.writes == 1)
        #expect(counts.reads == 1)
    }
}
