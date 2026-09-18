import AriaMCP
import AriaMCPWire
import Foundation

/// Fail-closed automatic replay policy for an authenticated daemon lease.
///
/// Re-admission happens after every transport failure, but only operations
/// whose contract declares them read-only are sent again. A mutation whose
/// response was lost may already be committed, so replaying it could apply the
/// user's request twice.
public enum DaemonOperationReplayPolicy {
    public static let ambiguousOutcomeReason = "daemon-result-ambiguous"
    public static let ambiguousOutcomeMessage =
        "The daemon connection ended before the operation result was received. "
        + "The operation may have been applied and was not replayed."

    private static let stableReadTools = Set(
        FirstPartyProviderCatalog.descriptors.lazy
            .filter { $0.effect == .read }
            .map(\.publicName)
    )

    /// Read endpoints from the frozen Community 1.1 contract. This explicit
    /// set keeps a newly added endpoint non-replayable until its effect has
    /// been reviewed in the client as well as in the daemon contract.
    private static let communityReadTools: Set<String> = [
        "moot_community_contract_identity",
        "moot_community_estate_inspect",
        "moot_community_capture_choices",
        "moot_community_review_dashboard",
        "moot_community_review_session",
        "moot_community_obsidian_status",
        "moot_community_obsidian_authorization",
        "moot_community_transfer_import_source",
        "moot_community_transfer_import_plan",
        "moot_community_transfer_export_destination",
        "moot_community_transfer_export_scopes",
        "moot_community_transfer_export_plan",
        "moot_community_transfer_job_status",
        "moot_community_lan_status",
        "moot_community_lan_policy",
    ]

    public static func permitsAutomaticReplay(
        method: String,
        params: JSONValue?
    ) -> Bool {
        switch method {
        case "initialize", "ping", "tools/list":
            return true
        case "tools/call":
            guard let name = params?.objectValue?["name"]?.stringValue else {
                return false
            }
            return permitsAutomaticReplay(tool: name)
        default:
            return false
        }
    }

    public static func permitsAutomaticReplay(tool name: String) -> Bool {
        stableReadTools.contains(name) || communityReadTools.contains(name)
    }

    public static func ambiguousCall(
        preserving first: GatewayCall,
        operation: String
    ) -> GatewayCall {
        GatewayCall(
            requestJSON: first.requestJSON,
            responseJSON: "(ambiguous transport outcome for \(operation))",
            text: ambiguousOutcomeMessage,
            structured: .object([
                "failure": .string(ambiguousOutcomeReason),
                "operation": .string(operation),
                "outcome": .string("failed"),
                "state": .string("blocked"),
                "reason": .string(ambiguousOutcomeReason),
            ]),
            isError: true,
            failureDisposition: .ambiguous
        )
    }

    public static func ambiguousResponse(id: JSONValue) -> JSONRPCResponse {
        .failure(
            id,
            JSONRPCError(
                code: JSONRPCErrorCode.internalError,
                message: ambiguousOutcomeMessage,
                data: .object(["failure": .string(ambiguousOutcomeReason)])
            )
        )
    }
}
