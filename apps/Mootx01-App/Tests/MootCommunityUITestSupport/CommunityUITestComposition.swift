import AriaMCPWire
import Foundation
import MootCommunityGateway
import MootCommunityUI

/// Contract-compatible, storage-free composition for the nonshipping macOS
/// UI-acceptance host. Nothing in this target is linked by the release app.
public enum CommunityUITestModelFactory {
    @MainActor
    public static func makeReadyModel() -> CommunityAppModel {
        let estate = CommunityUITestEstate.summary
        return CommunityAppModel(
            connector: CommunityUITestConnector(estateID: estate.id),
            setupService: CommunityUITestSetupService(estate: estate),
            captureService: CommunityUITestCaptureService()
        )
    }
}

private enum CommunityUITestEstate {
    static let id = UUID(uuidString: "AAAAAAAA-1100-4000-8000-000000000001")!
    static let receiptID = UUID(uuidString: "AAAAAAAA-1100-4000-8000-000000000002")!
    static let recordID = UUID(uuidString: "AAAAAAAA-1100-4000-8000-000000000003")!
    static let summary = CommunityEstateSummary(
        id: id,
        name: "UI Acceptance Estate",
        schemaVersion: "community/1.1"
    )
}

private actor CommunityUITestConnector: CommunityDaemonConnecting {
    private let identity: EstateIdentity
    private let caller: CommunityUITestCaller

    init(estateID: UUID) {
        identity = .daemon(estate: estateID, service: "community-ui-test-daemon")
        caller = CommunityUITestCaller(identity: identity)
    }

    func connect() async -> CommunityDaemonConnection {
        CommunityDaemonConnection(state: .ready(identity), caller: caller)
    }
}

private actor CommunityUITestCaller: MootEstateCalling {
    nonisolated let serverName = "community-ui-test-daemon"
    nonisolated let estateIdentity: EstateIdentity

    init(identity: EstateIdentity) { estateIdentity = identity }

    func call(method: String, params: JSONValue?) async -> GatewayCall {
        GatewayCall(
            requestJSON: "{}",
            responseJSON: method == "ping" ? "{}" : "{\"error\":\"fixture-unavailable\"}",
            text: method == "ping" ? "ok" : "fixture-unavailable",
            structured: nil,
            isError: method != "ping"
        )
    }

    func callToolFull(_ name: String, arguments: [String: JSONValue]) async -> GatewayCall {
        await call(method: "tools/call:\(name)", params: .object(arguments))
    }

    func toolsList() async -> JSONValue { .object(["tools": .array([])]) }
    func handle(_ request: JSONRPCRequest) async -> JSONRPCResponse? { nil }
}

private actor CommunityUITestSetupService: CommunityEstateLifecycleServicing {
    private let ready: CommunityEstateLifecycleState

    init(estate: CommunityEstateSummary) {
        ready = .ready(
            CommunityEstateReceipt(
                estate: estate,
                receiptID: CommunityUITestEstate.receiptID
            )
        )
    }

    func inspect() async -> CommunityEstateLifecycleState { ready }
    func createEstate(named name: String) async -> CommunityEstateLifecycleState { ready }
    func openEstate(id: UUID) async -> CommunityEstateLifecycleState { ready }
    func beginMigration(planID: UUID) async -> CommunityEstateLifecycleState { ready }
    func recover(choiceID: String) async -> CommunityEstateLifecycleState { ready }
    func cancel(operationID: UUID) async -> CommunityEstateLifecycleState { ready }
}

private actor CommunityUITestCaptureService: CommunityCaptureServicing {
    private let primary = CommunityCaptureDestination(
        id: "destination.personal.capture",
        title: "Personal Capture",
        detail: "Filed by the resident daemon in the selected personal capture destination."
    )
    private let project = CommunityCaptureDestination(
        id: "destination.project",
        title: "Project Notes",
        detail: "Filed by the resident daemon in the selected project destination."
    )

    func choices() async -> Result<CommunityCaptureChoices, CommunityCaptureServiceError> {
        .success(
            CommunityCaptureChoices(
                destinations: [primary, project],
                sensitivities: [.normal, .elevated, .restricted, .secret],
                defaultPolicy: CommunityCapturePolicy(
                    destination: primary,
                    sensitivity: .restricted,
                    exportEligible: false,
                    lanEligible: false
                )
            )
        )
    }

    func capture(_ request: CommunityCaptureRequest) async -> CommunityCaptureOutcome {
        .applied(
            CommunityCaptureReceipt(
                recordID: CommunityUITestEstate.recordID,
                effectivePolicy: request.policy
            )
        )
    }
}
