import AriaMCPWire
import Foundation
import GeniusLocusKit
import LocusKit

/// The daemon-installed implementation of the fixed first-party contract.
///
/// This actor is intentionally independent of `ToolDispatcher`: public-v2
/// selection, public capability flags, and the selected-public caller binding
/// never enter this route.  One actor lives for the resident process and keeps
/// cursor and recall-ledger state per authenticated transport session.
public actor FirstPartyProviderExecutor: FirstPartyProvider, FirstPartyProviderExecutorContextConsumer {
    private struct SessionState {
        let instanceID: UUID
        let estateID: UUID
        let recallLedger = SurfacedRecallLedger()
        let cursorSession = AriaV2MemoryListCursorSession()
    }

    private struct UsageLedger: AriaV2MemoryUsageLedger {
        let surfaced: SurfacedRecallLedger

        func recordSurfaced(_ memoryIDs: [UUID], estateID: UUID, callerID: String, at: Date) async {
            _ = (estateID, callerID)
            await surfaced.recordSurfaced(memoryIDs.map(AriaV2ArgumentDecoder.canonicalUUID), at: at)
        }

        func recordDereferenced(_ memoryIDs: [UUID], estateID: UUID, callerID: String, at: Date) async {
            _ = (memoryIDs, estateID, callerID, at)
        }
    }

    private struct ListAuthority: AriaV2MemoryListAuthorizationAuthority {
        let state: AriaV2MemoryListAuthorizationState

        func authorizeMemoryList(estateID: UUID, authorization: AriaV2MemoryListAuthorization) async throws -> AriaV2MemoryListAuthorizationState {
            guard estateID == state.estateID,
                  authorization.callerID == state.callerID,
                  authorization.contextID == state.contextID,
                  authorization.policyVersion == state.policyVersion else {
                throw AriaV2MemoryListProductionSnapshotError.authorizationMismatch
            }
            return state
        }
    }

    private var executorContext: (any FirstPartyProviderExecutorContext)?
    private var sessions: [String: SessionState] = [:]

    public init() {}

    public func installFirstPartyProviderExecutorContext(_ context: any FirstPartyProviderExecutorContext) async {
        executorContext = context
        // A new daemon host is a new authority boundary.  Never carry cursors
        // or surfaced-memory state across it.
        sessions.removeAll(keepingCapacity: false)
    }

    public func isFirstPartyProviderTool(_ name: String) async -> Bool {
        FirstPartyProviderCatalog.registry.operation(named: name) != nil
    }

    public var firstPartyProviderToolList: [ProjectedTool] {
        get async { FirstPartyProviderCatalog.projectedTools }
    }

    public func dispatchFirstPartyProviderTool(
        name: String,
        arguments: JSONValue,
        context call: FirstPartyProviderCallContext
    ) async throws -> JSONValue {
        guard FirstPartyProviderCatalog.registry.operation(named: name) != nil else {
            throw JSONRPCError(code: JSONRPCErrorCode.methodNotFound, message: "Method not found: \(name)")
        }
        guard let arguments = arguments.objectValue else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams, message: "tools/call arguments must be an object")
        }
        try FirstPartyProviderCatalog.validateArguments(name: name, arguments: arguments)
        guard let executorContext else {
            return refusal(name, code: "provider_unavailable", message: "The authenticated provider is not attached to a resident estate.")
        }

        let estateSession: FirstPartyProviderEstateSession
        do {
            estateSession = try await executorContext.currentEstateSession()
        } catch {
            return refusal(name, code: "estate_unavailable", message: "The selected estate is not available to this caller.")
        }
        guard estateSession.handle.estateUUID == call.estateIdentifier,
              await estateSession.kit.mountState(for: estateSession.handle) == .mounted else {
            return refusal(name, code: "estate_unavailable", message: "The selected estate is not available to this caller.")
        }

        let sessionKey = call.sessionIdentifier.map { String(format: "%02x", $0) }.joined()
        let state: SessionState
        if let existing = sessions[sessionKey] {
            guard existing.instanceID == call.instanceIdentifier,
                  existing.estateID == call.estateIdentifier else {
                return refusal(name, code: "caller_mismatch", message: "The authenticated caller context no longer matches this session.")
            }
            state = existing
        } else {
            let fresh = SessionState(instanceID: call.instanceIdentifier, estateID: call.estateIdentifier)
            sessions[sessionKey] = fresh
            state = fresh
        }

        let now = Date()
        let callerID = "first-party:\(sessionKey)"
        let callerRequestsExportable = arguments["filter"]?.stringValue == "exportable"
            && (name == "moot_memory_search" || name == "moot_recall_precise")
        let exportableOnly = call.recallPolicy.exportability == .exportableOnly
            || callerRequestsExportable
        var loweredArguments = arguments
        if callerRequestsExportable { loweredArguments.removeValue(forKey: "filter") }
        // The target v2 recall adapter takes this policy from its typed request
        // grammar; it cannot be widened by a caller-supplied filter.
        if exportableOnly, name == "moot_recall_precise" {
            loweredArguments["filter"] = .string("exportable")
        }
        let memoryContext = AriaV2MemoryOperationContext(
            estateID: call.estateIdentifier,
            callerID: callerID,
            serverIdentity: FirstPartyProviderCatalog.providerName,
            now: { now },
            maximumSensitivity: call.recallPolicy.maximumSensitivity,
            exportableOnly: exportableOnly,
            recallOrigin: .external,
            usageLedger: UsageLedger(surfaced: state.recallLedger))

        // Every read whose present lower adapter cannot prove both policy axes
        // is closed under a restrictive policy.  This is deliberately a refusal
        // rather than a best-effort redaction: callers must not discover that a
        // sensitive/exportability-filtered row exists through facts, journals,
        // lenses, or aggregate diagnostics.
        if restrictive(call.recallPolicy), [
            "moot_memory_list", "moot_fact_search", "moot_read_journal",
            "moot_list_lenses", "moot_lens_keystones", "moot_lens_theme_weather",
            "moot_lens_cohesion", "moot_lens_contradiction", "moot_lens_drift",
            "moot_estate_status", "moot_drain_status", "moot_rebuild_status", "moot_timing_report",
            "moot_file_fact", "moot_retire_fact", "moot_review_tunnel",
        ].contains(name) {
            return refusal(name, code: "recall_policy_restricted", message: "The active recall policy does not permit this aggregate read.")
        }

        let memoryBackend = AriaV2GeniusLocusMemoryBackend(kit: estateSession.kit, handle: estateSession.handle)
        let memory = AriaV2MemoryOperations(backend: memoryBackend, context: memoryContext)
        let mutations = AriaV2MemoryMutations(kit: estateSession.kit, handle: estateSession.handle, context: memoryContext)
        let journal = AriaV2KnowledgeJournalService(
            backend: AriaV2GeniusLocusKnowledgeJournalBackend(kit: estateSession.kit, handle: estateSession.handle),
            context: memoryContext)
        let diagnostics = AriaV2EstateDiagnostics(
            provider: AriaV2GeniusLocusEstateDiagnosticsProvider(kit: estateSession.kit, handle: estateSession.handle),
            context: .init(estateID: call.estateIdentifier, estateName: estateSession.handle.estateName,
                           callerID: callerID, serverIdentity: FirstPartyProviderCatalog.providerName,
                           sessionID: sessionKey, buildSerial: FirstPartyProviderCatalog.contractVersion, now: { now }))

        do {
            switch name {
            case "moot_file_memory": return try await memory.file(arguments: .object(arguments))
            case "moot_memory_get": return try await memory.get(arguments: .object(arguments))
            case "moot_memory_search": return try await memory.search(arguments: .object(loweredArguments))
            case "moot_memory_list":
                let auth = listAuthorization(estateID: call.estateIdentifier, callerID: callerID, policy: call.recallPolicy)
                let service = AriaV2MemoryListService(
                    provider: AriaV2MemoryListProductionSnapshotProvider(kit: estateSession.kit, handle: estateSession.handle, authorizationAuthority: ListAuthority(state: auth)),
                    cursorSession: state.cursorSession, defaultEstateID: call.estateIdentifier,
                    authorization: .init(callerID: auth.callerID, contextID: auth.contextID, policyVersion: auth.policyVersion), now: { now })
                return try await service.list(arguments: .object(arguments))
            case "moot_update_memory": return try await mutations.update(arguments: .object(normalizeMutationArguments(name: name, arguments)))
            case "moot_withdraw_memory": return try await mutations.withdraw(arguments: .object(normalizeMutationArguments(name: name, arguments)))
            case "moot_erase_memory": return try await mutations.erase(arguments: .object(normalizeMutationArguments(name: name, arguments)))
            case "moot_confirm_memory": return try await mutations.confirm(arguments: .object(normalizeMutationArguments(name: name, arguments)))
            case "moot_move_memory":
                var normalized = normalizeMutationArguments(name: name, arguments)
                if normalized["wing"] == nil {
                    guard let rawID = normalized["memory_id"]?.stringValue,
                          let memoryID = UUID(uuidString: rawID),
                          let current = try await memoryBackend.get(
                            .init(memoryIDs: [memoryID], depth: .full, estateID: nil),
                            context: memoryContext).first(where: { $0.isAuthorized }) else {
                        return refusal(name, code: "mutation_unavailable", message: "The requested mutation is unavailable in the selected estate.")
                    }
                    normalized["wing"] = .string(current.wing)
                }
                return try await mutations.move(arguments: .object(normalized))
            case "moot_link_memories": return try await mutations.link(arguments: .object(arguments))
            case "moot_review_tunnel": return try await mutations.review(arguments: .object(normalizeMutationArguments(name: name, arguments)))
            case "moot_file_fact": return try await journal.fileFact(arguments: .object(arguments))
            case "moot_fact_search":
                // Exact selectors are a fixed-provider capability. Remove them
                // before entering the selected-public decoder so this does not
                // widen the public v2 grammar or its Swift/Rust parity.
                var publicArguments = arguments
                let sourceIDExact = publicArguments.removeValue(forKey: "source_id_exact")?.stringValue
                let subjectExact = publicArguments.removeValue(forKey: "subject_exact")?.stringValue
                return try await journal.factSearch(
                    arguments: .object(publicArguments),
                    sourceIDExact: sourceIDExact,
                    subjectExact: subjectExact?.isEmpty == true ? nil : subjectExact
                )
            case "moot_retire_fact": return try await journal.retireFact(arguments: .object(normalizeMutationArguments(name: name, arguments)))
            case "moot_read_journal": return try await journal.readJournal(arguments: .object(arguments))
            case "moot_recall_precise", "moot_lens_keystones", "moot_lens_theme_weather", "moot_lens_cohesion", "moot_lens_contradiction", "moot_lens_drift":
                let request = try AriaV2RecallLensRequest(tool: name, arguments: .object(loweredArguments))
                var lensFilters: [Filter] = [.sensitivityAtMost(call.recallPolicy.maximumSensitivity)]
                if exportableOnly { lensFilters.append(.exportable) }
                let lower = AriaV2LensLowerService(
                    authority: AriaV2GeniusLocusLensLowerAuthority(kit: estateSession.kit, handle: estateSession.handle),
                    context: .init(
                        estateID: call.estateIdentifier, now: now,
                        authorizationFrame: .init(filterChain: lensFilters, hydrationLevel: .bitmapOnly),
                        maximumSensitivity: call.recallPolicy.maximumSensitivity,
                        exportableOnly: exportableOnly))
                if AriaV2LensLower.supported.contains(request.operation) { return try await lower.execute(request) }
                let recall = AriaV2RecallLensService(
                    authority: AriaV2GeniusLocusRecallLensAuthority(
                        kit: estateSession.kit,
                        handle: estateSession.handle,
                        authorizationFilter: .all(lensFilters)
                    )
                )
                return try await recall.execute(tool: name, arguments: .object(loweredArguments))
            case "moot_list_lenses":
                let request = try AriaV2CognitionCatalogRequest(arguments: .object(arguments))
                return try AriaV2CognitionCatalogService(estateID: call.estateIdentifier,
                    callableToolNames: Set(FirstPartyProviderCatalog.registry.operations.map(\.publicName)),
                    buildID: FirstPartyProviderCatalog.contractVersion,
                    capabilityDigest: FirstPartyProviderCatalog.capabilityDigest,
                    projectedTools: FirstPartyProviderCatalog.projectedTools).lenses(request)
            case "moot_estate_status": return try await diagnostics.status(arguments: .object(arguments))
            case "moot_drain_status": return try await diagnostics.drainStatus(arguments: .object(arguments))
            case "moot_rebuild_status": return try await diagnostics.rebuildStatus(arguments: .object(arguments))
            case "moot_timing_report": return try await diagnostics.timingReport(arguments: .object(arguments))
            default: throw JSONRPCError(code: JSONRPCErrorCode.methodNotFound, message: "Method not found: \(name)")
            }
        } catch let error as JSONRPCError {
            return refusal(name, code: "operation_failed", message: error.message)
        } catch {
            return refusal(name, code: "operation_failed", message: String(describing: error))
        }
    }

    private func restrictive(_ policy: FirstPartyRecallPolicy) -> Bool {
        policy.maximumSensitivity != .elevated || policy.exportability != .any
    }

    /// The native app's established names are the 1.1 caller grammar. The
    /// lower v2 services retain their typed internal names, so translation is
    /// performed once at this authenticated provider boundary.
    private func normalizeMutationArguments(
        name: String,
        _ arguments: [String: JSONValue]
    ) -> [String: JSONValue] {
        var normalized = arguments
        func rename(_ source: String, _ destination: String) {
            if let value = normalized.removeValue(forKey: source) {
                normalized[destination] = value
            }
        }
        switch name {
        case "moot_update_memory", "moot_withdraw_memory", "moot_confirm_memory":
            rename("id", "memory_id")
        case "moot_erase_memory":
            rename("id", "memory_id")
            rename("confirmed", "confirmation")
        case "moot_move_memory":
            rename("id", "memory_id")
            rename("location", "room")
        case "moot_review_tunnel":
            rename("verdict", "decision")
        case "moot_retire_fact":
            rename("id", "fact_id")
        default:
            break
        }
        return normalized
    }

    private func listAuthorization(estateID: UUID, callerID: String, policy: FirstPartyRecallPolicy) -> AriaV2MemoryListAuthorizationState {
        let policyVersion = "first-party-v1:\(policy.maximumSensitivity):\(policy.exportability)"
        return .init(estateID: estateID, callerID: callerID, contextID: "first-party-provider",
                     policyVersion: policyVersion, generation: "\(estateID.uuidString.lowercased()):\(callerID):\(policyVersion)")
    }

    private func refusal(_ tool: String, code: String, message: String) -> JSONValue {
        AriaV2Envelope.refusal(tool: tool, error: .init(code: code, message: message, retryable: false))
    }
}
