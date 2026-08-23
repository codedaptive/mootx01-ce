import AriaMCPWire
import Foundation
import MootCommunityGateway
@testable import MootCommunityUI
import Testing

@Suite("Community production feature adapters")
struct DaemonCommunityFeaturePortTests {
    @Test("estate lifecycle readiness is decoded from the daemon receipt")
    func estateLifecycleWire() async {
        let estateID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let receiptID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let caller = FeatureCallerFixture(responses: [
            "moot_community_estate_inspect": .object([
                "state": .string("ready"),
                "receipt": .object([
                    "receiptID": .string(receiptID.uuidString),
                    "estate": .object([
                        "id": .string(estateID.uuidString),
                        "name": .string("Home"),
                        "schemaVersion": .string("1.1"),
                    ]),
                ]),
            ]),
        ])
        let box = CommunityFeatureCallerBox()
        await box.attach(caller)

        let state = await DaemonCommunityEstateLifecycleService(callerBox: box).inspect()

        #expect(state == .ready(CommunityEstateReceipt(
            estate: CommunityEstateSummary(id: estateID, name: "Home", schemaVersion: "1.1"),
            receiptID: receiptID
        )))
    }

    @MainActor
    @Test("main content waits for a matching daemon lifecycle receipt")
    func estateReadinessRequiresReceipt() async {
        let estateID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let estate = CommunityEstateSummary(id: estateID, name: "Home", schemaVersion: "1.1")
        let receipt = CommunityEstateReceipt(
            estate: estate,
            receiptID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        )
        let caller = FeatureCallerFixture(responses: [:])
        let connector = ReadyConnectionFixture(caller: caller, estateID: estateID)
        let lifecycle = LifecycleFixture(states: [.needsCreation, .ready(receipt)])
        let model = CommunityAppModel(connector: connector, setupService: lifecycle)

        await model.start()
        #expect(!model.isEstateReady)
        #expect(model.setupModel.state == .needsCreation)

        await model.start()
        #expect(model.isEstateReady)
        #expect(model.setupModel.state == .ready(receipt))
    }

    @MainActor
    @Test("a lifecycle receipt for another estate is refused")
    func estateReceiptMustMatchDescriptor() async {
        let descriptorEstateID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let otherEstate = CommunityEstateSummary(
            id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
            name: "Other",
            schemaVersion: "1.1"
        )
        let receipt = CommunityEstateReceipt(
            estate: otherEstate,
            receiptID: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
        )
        let caller = FeatureCallerFixture(responses: [:])
        let model = CommunityAppModel(
            connector: ReadyConnectionFixture(caller: caller, estateID: descriptorEstateID),
            setupService: LifecycleFixture(states: [.ready(receipt)])
        )

        await model.start()

        #expect(model.connectionState == .blocked(reason: "estate-identity-mismatch"))
        #expect(model.estateIdentity == nil)
        #expect(!model.isEstateReady)
    }

    @MainActor
    @Test("reconnect restores canonical review session and running transfer job")
    func reconnectRestoresCanonicalFeatureState() async {
        let estateID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let receipt = CommunityEstateReceipt(
            estate: CommunityEstateSummary(id: estateID, name: "Home", schemaVersion: "1.1"),
            receiptID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        )
        let sessionID = UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC")!
        let initialSession = Fakes.session(
            id: sessionID,
            kind: .morning,
            sections: [Fakes.section(title: "Before restart")],
            status: .inProgress
        )
        let restoredSession = Fakes.session(
            id: sessionID,
            kind: .morning,
            sections: [Fakes.section(title: "After restart")],
            status: .inProgress
        )
        let reviewPort = FakeReviewPort(sessionResults: [.morning: .session(initialSession)])
        let transferPort = FakeTransferPort(jobStatusOutcome: .status(
            jobID: TransferFakes.primaryJobID,
            state: .running(progress: TransferProgress(processed: 3, total: 10))
        ))
        let caller = FeatureCallerFixture(responses: [:])
        let model = CommunityAppModel(
            connector: ReadyConnectionFixture(caller: caller, estateID: estateID),
            setupService: LifecycleFixture(states: [.ready(receipt), .ready(receipt)]),
            reviewPort: reviewPort,
            obsidianPort: FakeObsidianPort(),
            transferPort: transferPort,
            lanPort: FakeLANPort()
        )

        await model.start()
        await model.reviewCenterModel.loadSession(kind: .morning)
        await model.transferModel.selectImportSource()
        await model.transferModel.planImport()
        await model.transferModel.executeImport()
        #expect(model.reviewCenterModel.activeSession?.orderedSections.first?.title == "Before restart")
        #expect(model.transferModel.importJobState == .running(
            progress: TransferProgress(processed: 3, total: 10)
        ))

        await reviewPort.setSession(.session(restoredSession), for: .morning)
        let completedCounts = TransferFakes.successCounts(transferred: 10)
        await transferPort.setJobStatusOutcome(.status(
            jobID: TransferFakes.primaryJobID,
            state: .completed(counts: completedCounts, receipt: "receipt-after-restart")
        ))

        await model.start()

        #expect(model.reviewCenterModel.activeSession?.id == sessionID)
        #expect(model.reviewCenterModel.activeSession?.orderedSections.first?.title == "After restart")
        #expect(model.transferModel.importJobID == TransferFakes.primaryJobID)
        #expect(model.transferModel.importJobState == .completed(
            counts: completedCounts,
            receipt: "receipt-after-restart"
        ))
    }

    @Test("review dashboard is decoded from the authenticated daemon caller")
    func reviewDashboardWire() async {
        let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let caller = FeatureCallerFixture(responses: [
            "moot_community_review_dashboard": .object([
                "modes": .array([
                    .object(["kind": .string("morning"), "status": .string("due")]),
                    .object([
                        "kind": .string("endOfDay"),
                        "status": .string("inProgress"),
                        "sessionID": .string(sessionID.uuidString),
                    ]),
                    .object([
                        "kind": .string("weekly"),
                        "status": .string("blocked"),
                        "reason": .string("weekly-window-closed"),
                    ]),
                ]),
            ]),
        ])
        let box = CommunityFeatureCallerBox()
        await box.attach(caller)

        let dashboard = await DaemonReviewCenterPort(callerBox: box).loadDashboard()

        #expect(dashboard.modeStates[.morning] == .due)
        #expect(dashboard.modeStates[.endOfDay] == .inProgress(sessionID: sessionID))
        #expect(dashboard.modeStates[.weekly] == .blocked(reason: "weekly-window-closed"))
    }

    @Test("review adapter refuses a session returned for another requested mode")
    func reviewSessionKindMustMatchRequest() async {
        let caller = FeatureCallerFixture(responses: [
            "moot_community_review_session": .object([
                "outcome": .string("session"),
                "session": .object([
                    "id": .string("11111111-1111-4111-8111-111111111111"),
                    "kind": .string("weekly"),
                    "generatedAt": .string("2026-08-21T14:30:00Z"),
                    "sourceEstateState": .string("estate-state-1"),
                    "sections": .array([]),
                    "actions": .array([]),
                    "duplicateGroups": .array([]),
                    "completionStatus": .object(["state": .string("inProgress")]),
                ]),
            ]),
        ])
        let box = CommunityFeatureCallerBox()
        await box.attach(caller)

        let result = await DaemonReviewCenterPort(callerBox: box).loadSession(kind: .morning)

        #expect(result == .blocked(reason: "session-kind-mismatch"))
    }

    @Test("review adapter preserves the duplicate explanation from the frozen fixture")
    func reviewDuplicateExplanationMatchesFrozenFixture() async throws {
        let response = try frozenFixtureResult(
            family: "review",
            caseID: "review-session-ordered-with-duplicate"
        )
        let caller = FeatureCallerFixture(responses: [
            "moot_community_review_session": response,
        ])
        let box = CommunityFeatureCallerBox()
        await box.attach(caller)

        let result = await DaemonReviewCenterPort(callerBox: box).loadSession(kind: .morning)
        let session: ReviewSession
        switch result {
        case .session(let decoded):
            session = decoded
        case .blocked(let reason):
            Issue.record("frozen fixture was blocked: \(reason)")
            return
        }

        #expect(session.duplicateGroups.first?.reason ==
            "Both records have the same canonical source fingerprint.")
    }

    @Test("review adapter refuses a completion receipt for another session")
    func reviewCompletionReceiptMustMatchRequest() async {
        let requestedID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let caller = FeatureCallerFixture(responses: [
            "moot_community_review_complete": .object([
                "outcome": .string("completed"),
                "receipt": .object([
                    "sessionID": .string("22222222-2222-4222-8222-222222222222"),
                    "completedAt": .string("2026-08-21T14:30:00Z"),
                    "summary": .string("wrong session"),
                ]),
            ]),
        ])
        let box = CommunityFeatureCallerBox()
        await box.attach(caller)

        let result = await DaemonReviewCenterPort(callerBox: box).completeSession(requestedID)

        #expect(result == .failed("session-identity-mismatch"))
    }

    @Test("Obsidian and LAN states preserve daemon-supplied wire values")
    func settingsWire() async {
        let caller = FeatureCallerFixture(responses: [
            "moot_community_obsidian_status": .object([
                "state": .string("synchronizing"),
                "pendingCount": .integer(3),
                "totalCount": .integer(11),
                "checkpointAt": .string("2026-08-21T14:30:00Z"),
                "recordCount": .integer(47),
            ]),
            "moot_community_lan_status": .object([
                "state": .string("active"),
                "endpoint": .string("http://192.0.2.44:4242"),
                "authentication": .string("expired"),
            ]),
        ])
        let box = CommunityFeatureCallerBox()
        await box.attach(caller)

        let obsidianPort = DaemonObsidianSyncPort(callerBox: box)
        let obsidian = await obsidianPort.loadStatus()
        let checkpoint = await obsidianPort.loadLastCheckpoint()
        let lan = await DaemonLANControlPort(callerBox: box).loadServingStatus()

        #expect(obsidian == .synchronizing(
            progress: ObsidianSyncProgress(pendingCount: 3, totalCount: 11)
        ))
        #expect(checkpoint == ObsidianCheckpoint(
            timestamp: Date(timeIntervalSince1970: 1_787_322_600),
            recordCount: 47
        ))
        #expect(lan == .active(
            endpoint: "http://192.0.2.44:4242",
            authState: .expired
        ))
    }

    @Test("LAN policy read refuses unavailable, malformed, and negative counts")
    func lanPolicyReadFailsClosed() async {
        let unavailableBox = CommunityFeatureCallerBox()
        let unavailable = await DaemonLANControlPort(callerBox: unavailableBox).loadServingPolicy()
        #expect(unavailable == .blocked(reason: "daemon-unavailable"))

        let malformedCaller = FeatureCallerFixture(responses: [
            "moot_community_lan_policy": .object([
                "eligibleCount": .integer(-1),
                "ineligibleCount": .integer(4),
                "policyDescription": .string("invalid"),
            ]),
        ])
        let malformedBox = CommunityFeatureCallerBox()
        await malformedBox.attach(malformedCaller)
        let malformed = await DaemonLANControlPort(callerBox: malformedBox).loadServingPolicy()
        #expect(malformed == .failed(reason: "malformed-daemon-response"))
    }

    @Test("transfer job status preserves stable identity and terminal counts")
    func transferJobWire() async {
        let caller = FeatureCallerFixture(responses: [
            "moot_community_transfer_job_status": .object([
                "outcome": .string("status"),
                "jobID": .string("job-stable-1"),
                "jobState": .object([
                    "state": .string("completed"),
                    "counts": .object([
                        "transferred": .integer(8),
                        "skipped": .integer(1),
                        "conflicted": .integer(2),
                        "excluded": .integer(3),
                        "failed": .integer(4),
                    ]),
                    "receipt": .string("receipt-stable-1"),
                ]),
            ]),
        ])
        let box = CommunityFeatureCallerBox()
        await box.attach(caller)
        let jobID = TransferJobID(id: "job-stable-1")

        let outcome = await DaemonTransferPort(callerBox: box).loadJobStatus(jobID: jobID)

        #expect(outcome == .status(
            jobID: jobID,
            state: .completed(
                counts: TransferCounts(
                    transferred: 8,
                    skipped: 1,
                    conflicted: 2,
                    excluded: 3,
                    failed: 4
                ),
                receipt: "receipt-stable-1"
            )
        ))
    }

    @Test("detaching the authenticated caller makes every adapter fail closed")
    func detachFailsClosed() async {
        let caller = FeatureCallerFixture(responses: [:])
        let box = CommunityFeatureCallerBox()
        await box.attach(caller)
        await box.attach(nil)

        let review = await DaemonReviewCenterPort(callerBox: box).loadDashboard()
        let obsidian = await DaemonObsidianSyncPort(callerBox: box).loadStatus()
        let lan = await DaemonLANControlPort(callerBox: box).loadServingStatus()
        let lifecycle = await DaemonCommunityEstateLifecycleService(callerBox: box).inspect()
        let transfer = await DaemonTransferPort(callerBox: box).loadJobStatus(
            jobID: TransferJobID(id: "job-1")
        )

        #expect(review.modeStates.values.allSatisfy {
            if case .blocked = $0 { return true }
            return false
        })
        #expect(obsidian == .blocked(reason: "daemon-unavailable-or-malformed"))
        #expect(lan == .blocked(reason: "daemon-unavailable-or-malformed"))
        #expect(lifecycle == .blocked(reason: "daemon-unavailable-or-malformed"))
        #expect(transfer == .failed(reason: "daemon-unavailable-or-malformed"))
    }
}

private func frozenFixtureResult(family: String, caseID: String) throws -> JSONValue {
    var repositoryRoot = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 { repositoryRoot.deleteLastPathComponent() }
    let fixtureURL = repositoryRoot
        .appendingPathComponent("contracts/community/1.1/fixtures", isDirectory: true)
        .appendingPathComponent("\(family).json")
    let fixture = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any]
    )
    let cases = try #require(fixture["cases"] as? [[String: Any]])
    let selected = try #require(cases.first { $0["id"] as? String == caseID })
    return try JSONValue.from(try #require(selected["result"]))
}

private actor ReadyConnectionFixture: CommunityDaemonConnecting {
    private let caller: any MootEstateCalling
    private let estateID: UUID

    init(caller: any MootEstateCalling, estateID: UUID) {
        self.caller = caller
        self.estateID = estateID
    }

    func connect() async -> CommunityDaemonConnection {
        let identity = EstateIdentity.daemon(estate: estateID, service: "com.mootx01.daemon")
        return CommunityDaemonConnection(state: .ready(identity), caller: caller)
    }
}

private actor LifecycleFixture: CommunityEstateLifecycleServicing {
    private var states: [CommunityEstateLifecycleState]

    init(states: [CommunityEstateLifecycleState]) {
        self.states = states
    }

    private func next() -> CommunityEstateLifecycleState {
        states.isEmpty ? .blocked(reason: "fixture-exhausted") : states.removeFirst()
    }

    func inspect() async -> CommunityEstateLifecycleState { next() }
    func createEstate(named name: String) async -> CommunityEstateLifecycleState { next() }
    func openEstate(id: UUID) async -> CommunityEstateLifecycleState { next() }
    func beginMigration(planID: UUID) async -> CommunityEstateLifecycleState { next() }
    func recover(choiceID: String) async -> CommunityEstateLifecycleState { next() }
    func cancel(operationID: UUID) async -> CommunityEstateLifecycleState { next() }
}

private actor FeatureCallerFixture: MootEstateCalling {
    nonisolated let serverName = "ARIA_MCP"
    nonisolated let estateIdentity = EstateIdentity.daemon(
        estate: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
        service: "com.mootx01.daemon"
    )

    private let responses: [String: JSONValue]

    init(responses: [String: JSONValue]) {
        self.responses = responses
    }

    func call(method: String, params: JSONValue?) async -> GatewayCall {
        failure("unsupported-call")
    }

    func callToolFull(_ name: String, arguments: [String: JSONValue]) async -> GatewayCall {
        guard let response = responses[name] else { return failure("missing-fixture") }
        return GatewayCall(
            requestJSON: "{}",
            responseJSON: "{}",
            text: "",
            structured: response,
            isError: false
        )
    }

    func toolsList() async -> JSONValue { .object(["tools": .array([])]) }

    func handle(_ request: JSONRPCRequest) async -> JSONRPCResponse? { nil }

    private func failure(_ reason: String) -> GatewayCall {
        GatewayCall(
            requestJSON: "{}",
            responseJSON: "{}",
            text: reason,
            structured: nil,
            isError: true
        )
    }
}
