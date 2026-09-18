import AriaMCPWire
import Foundation

/// Turns one admitted Community connection into a runtime-backed caller.
///
/// The caller installed in `CommunityAppModel`, capture, and feature adapters
/// remains stable as an object, while its authenticated daemon lease is
/// replaced after a transport failure. Re-admission always passes through the
/// original connector, so discovery, provider compatibility, authentication,
/// and estate binding run again. Read-only calls then retry once. Mutations
/// return an ambiguous outcome because their response may have been lost after
/// commit; the replacement is retained for the next user action.
public actor RecoveringCommunityDaemonConnector: CommunityDaemonConnecting {
    private let connector: any CommunityDaemonConnecting

    public init(connector: any CommunityDaemonConnecting) {
        self.connector = connector
    }

    public func connect() async -> CommunityDaemonConnection {
        let connection = await connector.connect()
        guard case .ready(let identity) = connection.state,
              let caller = connection.caller else {
            return connection
        }
        guard caller.estateIdentity == identity else {
            return CommunityDaemonConnection(state: .handshakeFailed)
        }

        let runtime = RecoveringCommunityDaemonCaller(
            connector: connector,
            serverName: caller.serverName,
            estateIdentity: identity
        )
        await runtime.installInitial(caller)
        return CommunityDaemonConnection(state: .ready(identity), caller: runtime)
    }
}

/// A stable Community call handle whose underlying authenticated daemon caller
/// can be replaced. Only `MootCaller` transport invalidation opens the retry
/// path; an ordinary provider refusal is returned unchanged.
private actor RecoveringCommunityDaemonCaller: MootEstateCalling {
    nonisolated let serverName: String
    nonisolated let estateIdentity: EstateIdentity

    private struct Admission: Sendable {
        let id: UUID
        let caller: any MootEstateCalling
    }

    private struct Reconnect: Sendable {
        let id: UUID
        let task: Task<Admission?, Never>
    }

    private let connector: any CommunityDaemonConnecting
    private var admitted: Admission?
    private var reconnect: Reconnect?

    init(
        connector: any CommunityDaemonConnecting,
        serverName: String,
        estateIdentity: EstateIdentity
    ) {
        self.connector = connector
        self.serverName = serverName
        self.estateIdentity = estateIdentity
    }

    func installInitial(_ caller: any MootEstateCalling) async {
        admitted = await preparedAdmission(caller)
    }

    func call(method: String, params: JSONValue?) async -> GatewayCall {
        guard let admission = await admission() else {
            return Self.unavailableCall(method: method)
        }
        let first = await admission.caller.call(method: method, params: params)
        guard first.failureDisposition == .transport,
              shouldRetry(admission) else { return first }
        let replacement = await replacementCaller()
        guard DaemonOperationReplayPolicy.permitsAutomaticReplay(
            method: method,
            params: params
        ) else {
            return DaemonOperationReplayPolicy.ambiguousCall(
                preserving: first,
                operation: Self.operationName(method: method, params: params)
            )
        }
        guard let replacement else { return first }
        return await replacement.call(method: method, params: params)
    }

    func callToolFull(_ name: String, arguments: [String: JSONValue]) async -> GatewayCall {
        guard let admission = await admission() else {
            return Self.unavailableCall(method: name)
        }
        let first = await admission.caller.callToolFull(name, arguments: arguments)
        guard first.failureDisposition == .transport,
              shouldRetry(admission) else { return first }
        let replacement = await replacementCaller()
        guard DaemonOperationReplayPolicy.permitsAutomaticReplay(tool: name) else {
            return DaemonOperationReplayPolicy.ambiguousCall(
                preserving: first,
                operation: name
            )
        }
        guard let replacement else { return first }
        return await replacement.callToolFull(name, arguments: arguments)
    }

    func toolsList() async -> JSONValue {
        let empty: JSONValue = .object(["tools": .array([])])
        guard let admission = await admission() else { return empty }
        let first = await admission.caller.toolsList()
        guard shouldRetry(admission) else { return first }
        guard let replacement = await replacementCaller() else { return first }
        return await replacement.toolsList()
    }

    func handle(_ request: JSONRPCRequest) async -> JSONRPCResponse? {
        guard let admission = await admission() else {
            return request.id.map(Self.forwardingFailure)
        }
        let first = await admission.caller.handle(request)
        guard shouldRetry(admission) else { return first }
        let replacement = await replacementCaller()
        guard DaemonOperationReplayPolicy.permitsAutomaticReplay(
            method: request.method,
            params: request.params
        ) else {
            return request.id.map(DaemonOperationReplayPolicy.ambiguousResponse)
        }
        guard let replacement else { return first }
        return await replacement.handle(request)
    }

    private func admission() async -> Admission? {
        if let admitted { return admitted }
        _ = await replacementCaller()
        return admitted
    }

    private func shouldRetry(_ admission: Admission) -> Bool {
        admitted?.id != admission.id
    }

    private func replacementCaller() async -> (any MootEstateCalling)? {
        if let admitted { return admitted.caller }

        let attempt: Reconnect
        if let reconnect {
            attempt = reconnect
        } else {
            let connector = self.connector
            let expectedEstateIdentity = estateIdentity
            let expectedServerName = serverName
            let runtime = self
            attempt = Reconnect(
                id: UUID(),
                task: Task { [connector, expectedEstateIdentity, expectedServerName, weak runtime] in
                    let connection = await connector.connect()
                    guard case .ready(let identity) = connection.state,
                          identity == expectedEstateIdentity,
                          let caller = connection.caller,
                          caller.estateIdentity == expectedEstateIdentity,
                          caller.serverName == expectedServerName else {
                        return nil
                    }
                    let admissionID = UUID()
                    if let remote = caller as? MootCaller {
                        await remote.setTransportFailureObserver { [weak runtime] in
                            await runtime?.invalidate(admissionID)
                        }
                    }
                    return Admission(id: admissionID, caller: caller)
                }
            )
            reconnect = attempt
        }

        let replacement = await attempt.task.value
        guard reconnect?.id == attempt.id else { return admitted?.caller }
        reconnect = nil
        guard let replacement else { return nil }
        admitted = replacement
        return admitted?.caller
    }

    private func preparedAdmission(_ caller: any MootEstateCalling) async -> Admission {
        let admissionID = UUID()
        if let remote = caller as? MootCaller {
            await remote.setTransportFailureObserver { [weak self] in
                await self?.invalidate(admissionID)
            }
        }
        return Admission(id: admissionID, caller: caller)
    }

    private func invalidate(_ admissionID: UUID) {
        guard admitted?.id == admissionID else { return }
        admitted = nil
    }

    private static func unavailableCall(method: String) -> GatewayCall {
        GatewayCall(
            requestJSON: "",
            responseJSON: "",
            text: "The authenticated daemon is unavailable for \(method)",
            structured: nil,
            isError: true
        )
    }

    private static func forwardingFailure(_ id: JSONValue) -> JSONRPCResponse {
        .failure(
            id,
            JSONRPCError(
                code: JSONRPCErrorCode.internalError,
                message: "The estate is not reachable"
            )
        )
    }

    private static func operationName(method: String, params: JSONValue?) -> String {
        guard method == "tools/call" else { return method }
        return params?.objectValue?["name"]?.stringValue ?? method
    }
}
