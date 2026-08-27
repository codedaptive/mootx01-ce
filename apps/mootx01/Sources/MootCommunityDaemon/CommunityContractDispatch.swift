import AriaMCP
import Foundation

// Wave A1b — community-contract tool dispatch.
//
// `CommunityProviderState` carries the live instance and estate UUIDs that
// come from `DaemonProvider.activate()` and are embedded in every
// `moot_community_contract_identity` response. These values are NOT known at
// static init time; they require a real activation run.
//
// `CommunityContractDispatch` conforms to `CommunityToolHandler` (AriaMCP) so
// it can be injected into `ARIA_MCPDispatcher` without pulling GeniusLocusKit
// into MootCommunityDaemon. The dependency direction is:
//   MootCommunityDaemon → AriaMCP (CommunityToolHandler protocol)
//   AriaMCP does NOT import MootCommunityDaemon (no circular dep).
//
// Wave A2b: two capture-family tools added (CORE-04):
//   moot_community_capture_choices  — read current estate destinations + default policy
//   moot_community_capture          — validate + persist a capture record

// MARK: - Live provider state

/// The live instance and estate UUIDs produced by `DaemonProvider.activate()`.
///
/// These are carried into `CommunityContractDispatch` so every
/// `moot_community_contract_identity` response reflects the real, currently
/// active daemon identity — not a hard-coded sentinel.
public struct CommunityProviderState: Sendable {
    /// UUID of this daemon process's signed provider instance.
    /// Source: `ProviderActivation.descriptor.instanceIdentifier`.
    public let instanceIdentifier: UUID

    /// UUID of the estate this daemon is hosting.
    /// Source: `ProviderActivation.descriptor.estateIdentifier`.
    public let estateIdentifier: UUID

    /// Designated initializer.
    public init(instanceIdentifier: UUID, estateIdentifier: UUID) {
        self.instanceIdentifier = instanceIdentifier
        self.estateIdentifier = estateIdentifier
    }
}

// MARK: - CommunityToolHandler conformer

/// Dispatches all `moot_community_*` tool calls for the 1.1 contract.
///
/// This struct conforms to `CommunityToolHandler` and is injected into
/// `ARIA_MCPDispatcher(info:communityHandler:)`. It owns the community
/// tool schema and routes calls to their implementations. Unknown names
/// throw `methodNotFound`; unknown argument fields throw `invalidParams`
/// (fail-closed — the contract defines exact argument shapes per endpoint).
///
/// Wave A1b: `moot_community_contract_identity` (identity).
/// Wave A2a: Six estate-lifecycle tools (inspect / create / open / migrate /
///           recover / cancel), routed to `CommunityEstateLifecycleCoordinator`.
public struct CommunityContractDispatch: CommunityToolHandler {

    /// The live provider state, injected after `DaemonProvider.activate()`.
    public let state: CommunityProviderState

    /// Optional estate lifecycle coordinator.
    ///
    /// `nil` in legacy callers that use the single-argument init (Wave A1b
    /// production shell). Non-nil in Wave A2a deployments — the composition
    /// root injects it after constructing the coordinator over the daemon
    /// layout directory.
    ///
    /// When nil, the six estate-lifecycle tools return
    /// `blocked{reason: "daemon-blocked"}` instead of attempting to open or
    /// create an estate without a configured layout.
    public let lifecycle: CommunityEstateLifecycleCoordinator?

    /// Optional capture coordinator (Wave A2b: CORE-04).
    ///
    /// `nil` in callers that don't inject a capture coordinator. When nil,
    /// the capture tools return `failed{daemon-blocked}` instead of
    /// attempting estate access without a configured layout.
    public let capture: CommunityCaptureCoordinator?

    /// Optional review coordinator (Wave B1: CORE-05).
    ///
    /// `nil` in callers that don't inject a review coordinator. When nil,
    /// review tools return `blocked{daemon-blocked}` or `refused{daemon-blocked}`
    /// instead of attempting estate access without a configured layout.
    public let review: CommunityReviewCoordinator?

    /// Optional obsidian sync coordinator (Wave C1: CORE-06).
    ///
    /// `nil` in callers that don't inject an obsidian coordinator. When nil,
    /// obsidian tools return `blocked{daemon-blocked}` or `refused{daemon-blocked}`.
    public let obsidian: CommunityObsidianCoordinator?

    /// Optional transfer coordinator (Wave D1: CORE-07).
    ///
    /// `nil` in callers that don't inject a transfer coordinator. When nil,
    /// the nine transfer tools are absent from the tool list (B1-R16 gating
    /// pattern: tools only appear when coordinator is injected), and any
    /// direct dispatch call returns `failed{daemon-blocked}`.
    public let transfer: CommunityTransferCoordinator?

    /// Optional LAN serving coordinator (Wave D2: CORE-08).
    ///
    /// `nil` in callers that don't inject a LAN coordinator. When nil,
    /// the five LAN tools are absent from the tool list (B1-R16 gating pattern).
    /// Any direct dispatch call to LAN tools returns `failed{daemon-blocked}`.
    public let lan: CommunityLANCoordinator?

    /// Wave A1b designated initializer — no lifecycle, capture, or review coordinator.
    /// Exists so the existing production shell (`CommunityResidentMain`) does
    /// not require changes at this phase.
    public init(state: CommunityProviderState) {
        self.state = state
        self.lifecycle = nil
        self.capture = nil
        self.review = nil
        self.obsidian = nil
        self.transfer = nil
        self.lan = nil
    }

    /// Wave A2a designated initializer — with lifecycle coordinator, no capture or review.
    public init(state: CommunityProviderState, lifecycle: CommunityEstateLifecycleCoordinator) {
        self.state = state
        self.lifecycle = lifecycle
        self.capture = nil
        self.review = nil
        self.obsidian = nil
        self.transfer = nil
        self.lan = nil
    }

    /// Wave A2b designated initializer — with lifecycle and capture coordinators, no review.
    public init(
        state: CommunityProviderState,
        lifecycle: CommunityEstateLifecycleCoordinator?,
        capture: CommunityCaptureCoordinator
    ) {
        self.state = state
        self.lifecycle = lifecycle
        self.capture = capture
        self.review = nil
        self.obsidian = nil
        self.transfer = nil
        self.lan = nil
    }

    /// Wave B1 designated initializer — with lifecycle, capture, and review coordinators.
    public init(
        state: CommunityProviderState,
        lifecycle: CommunityEstateLifecycleCoordinator?,
        capture: CommunityCaptureCoordinator?,
        review: CommunityReviewCoordinator
    ) {
        self.state = state
        self.lifecycle = lifecycle
        self.capture = capture
        self.review = review
        self.obsidian = nil
        self.transfer = nil
        self.lan = nil
    }

    /// Wave C1 designated initializer — with all coordinators including obsidian.
    public init(
        state: CommunityProviderState,
        lifecycle: CommunityEstateLifecycleCoordinator?,
        capture: CommunityCaptureCoordinator?,
        review: CommunityReviewCoordinator?,
        obsidian: CommunityObsidianCoordinator
    ) {
        self.state = state
        self.lifecycle = lifecycle
        self.capture = capture
        self.review = review
        self.obsidian = obsidian
        self.transfer = nil
        self.lan = nil
    }

    /// Wave D1 designated initializer — with all coordinators including transfer.
    ///
    /// Transfer tools appear in the tool list ONLY when `transfer` is non-nil
    /// (B1-R16 gating pattern). Without a transfer coordinator the nine transfer
    /// endpoints are absent from the tool list and any dispatch call returns
    /// `failed{daemon-blocked}`.
    public init(
        state: CommunityProviderState,
        lifecycle: CommunityEstateLifecycleCoordinator?,
        capture: CommunityCaptureCoordinator?,
        review: CommunityReviewCoordinator?,
        obsidian: CommunityObsidianCoordinator?,
        transfer: CommunityTransferCoordinator
    ) {
        self.state = state
        self.lifecycle = lifecycle
        self.capture = capture
        self.review = review
        self.obsidian = obsidian
        self.transfer = transfer
        self.lan = nil
    }

    /// Wave D2 designated initializer — with all coordinators including LAN.
    ///
    /// LAN tools appear in the tool list ONLY when `lan` is non-nil (B1-R16
    /// gating pattern). Without a LAN coordinator the five LAN endpoints are
    /// absent from the tool list and any dispatch call returns `failed{daemon-blocked}`.
    public init(
        state: CommunityProviderState,
        lifecycle: CommunityEstateLifecycleCoordinator?,
        capture: CommunityCaptureCoordinator?,
        review: CommunityReviewCoordinator?,
        obsidian: CommunityObsidianCoordinator?,
        transfer: CommunityTransferCoordinator?,
        lan: CommunityLANCoordinator
    ) {
        self.state = state
        self.lifecycle = lifecycle
        self.capture = capture
        self.review = review
        self.obsidian = obsidian
        self.transfer = transfer
        self.lan = lan
    }

    // MARK: CommunityToolHandler

    /// True for any tool name prefixed with `moot_community_`.
    ///
    /// This prefix is owned by the community-contract tool namespace.
    /// No other tool names in the ARIA_MCP surface use this prefix.
    public func isCommunityTool(_ name: String) -> Bool {
        name.hasPrefix("moot_community_")
    }

    /// The `ProjectedTool` entries for the tools/list response.
    ///
    /// Wave A1b: identity tool.
    /// Wave A2a: six estate-lifecycle tools added.
    /// Wave A2b: two capture-family tools added.
    /// Wave B1: six review-family tools added.
    /// Wave C1: six obsidian-family tools added (only when coordinator is present).
    /// Wave D1: nine transfer-family tools added (only when coordinator is present).
    /// Wave D2: five LAN-family tools added (only when coordinator is present).
    ///
    /// The obsidian, transfer, and LAN tool families are gated on their coordinator
    /// being injected at daemon init (B1-R16 gating pattern). When a coordinator
    /// is nil, the tools are absent from the list and any dispatch call to them
    /// returns a `failed{daemon-blocked}` fallback. Tool counts by variant:
    ///   base (identity+estate+capture+review) → 15 total
    ///   + obsidian only  → 21 total
    ///   + transfer only  → 24 total (base + 9)
    ///   + lan only       → 20 total (base + 5)
    ///   + all three      → 35 total
    public var communityToolList: [ProjectedTool] {
        [identityTool] + estateTools + captureTools + reviewTools
            + (obsidian != nil ? obsidianTools : [])
            + (transfer != nil ? transferTools : [])
            + (lan != nil ? lanTools : [])
    }

    /// Dispatch one community tool call.
    ///
    /// Fail-closed routing:
    ///   - Unknown tool name → `methodNotFound`.
    ///   - Known tool with unexpected argument fields → `invalidParams`.
    ///   - Estate tools without a lifecycle coordinator → `blocked{daemon-blocked}`.
    ///   - Review tools without a review coordinator → `blocked{daemon-blocked}`.
    public func dispatch(name: String, arguments: JSONValue) async throws -> JSONValue {
        switch name {
        case "moot_community_contract_identity":
            // Fail-closed: any field in the arguments object is unknown.
            // The contract specifies Empty arguments; extra fields fail closed.
            if case .object(let fields) = arguments, !fields.isEmpty {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "moot_community_contract_identity takes no arguments"
                )
            }
            return contractIdentityResponse()

        case "moot_community_estate_inspect":
            try validateEmpty(arguments, tool: "moot_community_estate_inspect")
            return await estateInspect()

        case "moot_community_estate_create":
            let name = try parseName(arguments, tool: "moot_community_estate_create")
            return await estateCreate(name: name)

        case "moot_community_estate_open":
            let estateID = try parseEstateID(arguments, tool: "moot_community_estate_open")
            return await estateOpen(estateID: estateID)

        case "moot_community_estate_migrate":
            let planID = try parsePlanID(arguments, tool: "moot_community_estate_migrate")
            return await estateMigrate(planID: planID)

        case "moot_community_estate_recover":
            let choiceID = try parseChoiceID(arguments, tool: "moot_community_estate_recover")
            return await estateRecover(choiceID: choiceID)

        case "moot_community_estate_cancel":
            let operationID = try parseOperationID(arguments, tool: "moot_community_estate_cancel")
            return await estateCancel(operationID: operationID)

        case "moot_community_capture_choices":
            // Empty arguments — any field is unknown.
            try validateEmpty(arguments, tool: "moot_community_capture_choices")
            return await captureChoices()

        case "moot_community_capture":
            let captureArgs = try parseCaptureArguments(arguments)
            return await captureRecord(arguments: captureArgs)

        // ── Review-family (Wave B1: CORE-05) ─────────────────────────────────
        case "moot_community_review_dashboard":
            try validateEmpty(arguments, tool: "moot_community_review_dashboard")
            return await reviewDashboard()

        case "moot_community_review_session":
            let kind = try parseReviewKind(arguments, tool: "moot_community_review_session")
            return await reviewSession(kind: kind)

        case "moot_community_review_apply":
            let (actionID, sessionID) = try parseReviewActionArguments(arguments, tool: "moot_community_review_apply")
            return await reviewApply(actionID: actionID, sessionID: sessionID)

        case "moot_community_review_reverse":
            let (actionID, sessionID) = try parseReviewActionArguments(arguments, tool: "moot_community_review_reverse")
            return await reviewReverse(actionID: actionID, sessionID: sessionID)

        case "moot_community_review_resolve_duplicate":
            let (groupID, choiceID, sessionID) = try parseDuplicateResolutionArguments(arguments)
            return await reviewResolveDuplicate(groupID: groupID, choiceID: choiceID, sessionID: sessionID)

        case "moot_community_review_complete":
            let sessionID = try parseSessionID(arguments, tool: "moot_community_review_complete")
            return await reviewComplete(sessionID: sessionID)

        // ── Obsidian-family (Wave C1: CORE-06) ───────────────────────────────
        case "moot_community_obsidian_status":
            try validateEmpty(arguments, tool: "moot_community_obsidian_status")
            return await obsidianStatus()

        case "moot_community_obsidian_authorization":
            try validateEmpty(arguments, tool: "moot_community_obsidian_authorization")
            return await obsidianAuthorization()

        case "moot_community_obsidian_select_vault":
            let (bookmark, displayName) = try parseVaultSelectionArguments(arguments)
            return await obsidianSelectVault(bookmark: bookmark, displayName: displayName)

        case "moot_community_obsidian_enable":
            try validateEmpty(arguments, tool: "moot_community_obsidian_enable")
            return await obsidianEnable()

        case "moot_community_obsidian_disable":
            try validateEmpty(arguments, tool: "moot_community_obsidian_disable")
            return await obsidianDisable()

        case "moot_community_obsidian_retry":
            try validateEmpty(arguments, tool: "moot_community_obsidian_retry")
            return await obsidianRetry()

        // ── Transfer-family (Wave D1: CORE-07) ───────────────────────────────

        case "moot_community_transfer_import_source":
            let (bookmark, displayName) = try parseTransferSourceArguments(arguments)
            return await transferImportSource(bookmark: bookmark, displayName: displayName)

        case "moot_community_transfer_import_plan":
            let bookmark = try parseTransferPlanArguments(arguments)
            return await transferImportPlan(bookmark: bookmark)

        case "moot_community_transfer_import_execute":
            let planToken = try parsePlanTokenArguments(arguments, tool: "moot_community_transfer_import_execute")
            return await transferImportExecute(planToken: planToken)

        case "moot_community_transfer_export_destination":
            let (bookmark, fileName) = try parseTransferDestinationArguments(arguments)
            return await transferExportDestination(bookmark: bookmark, fileName: fileName)

        case "moot_community_transfer_export_scopes":
            try validateEmpty(arguments, tool: "moot_community_transfer_export_scopes")
            return await transferExportScopes()

        case "moot_community_transfer_export_plan":
            let (bookmark, fileName, scopeToken) = try parseTransferExportPlanArguments(arguments)
            return await transferExportPlan(bookmark: bookmark, fileName: fileName, scopeToken: scopeToken)

        case "moot_community_transfer_export_execute":
            let planToken = try parsePlanTokenArguments(arguments, tool: "moot_community_transfer_export_execute")
            return await transferExportExecute(planToken: planToken)

        case "moot_community_transfer_job_status":
            let jobID = try parseJobIDArguments(arguments, tool: "moot_community_transfer_job_status")
            return await transferJobStatus(jobID: jobID)

        case "moot_community_transfer_job_cancel":
            let jobID = try parseJobIDArguments(arguments, tool: "moot_community_transfer_job_cancel")
            return await transferJobCancel(jobID: jobID)

        // ── LAN-family (Wave D2: CORE-08) ────────────────────────────────────

        case "moot_community_lan_status":
            try validateEmpty(arguments, tool: "moot_community_lan_status")
            return await lanStatus()

        case "moot_community_lan_policy":
            try validateEmpty(arguments, tool: "moot_community_lan_policy")
            return await lanPolicy()

        case "moot_community_lan_start":
            try validateEmpty(arguments, tool: "moot_community_lan_start")
            return await lanStart()

        case "moot_community_lan_stop":
            try validateEmpty(arguments, tool: "moot_community_lan_stop")
            return await lanStop()

        case "moot_community_lan_refresh_eligibility":
            try validateEmpty(arguments, tool: "moot_community_lan_refresh_eligibility")
            return await lanRefreshEligibility()

        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.methodNotFound,
                message: "Method not found: \(name)"
            )
        }
    }

    // MARK: - Review routing (Wave B1: CORE-05)

    /// Returns `blocked{daemon-blocked}` as ReviewSessionOutcome when no coordinator.
    private var reviewSessionUnavailable: JSONValue {
        ReviewSessionOutcome.blocked(reason: "daemon-blocked").toJSONValue()
    }

    /// Returns `refused{daemon-blocked}` as ReviewActionOutcome when no coordinator.
    private var reviewActionUnavailable: JSONValue {
        ReviewActionOutcome.refused(reason: "daemon-blocked").toJSONValue()
    }

    /// Returns `refused{daemon-blocked}` as ReviewCompleteOutcome when no coordinator.
    private var reviewCompleteUnavailable: JSONValue {
        ReviewCompleteOutcome.refused(reason: "daemon-blocked").toJSONValue()
    }

    private func reviewDashboard() async -> JSONValue {
        guard let rev = review else { return reviewSessionUnavailable }
        return await rev.dashboard()
    }

    private func reviewSession(kind: ReviewKind) async -> JSONValue {
        guard let rev = review else { return reviewSessionUnavailable }
        return await rev.reviewSession(kind: kind, now: Date())
    }

    private func reviewApply(actionID: UUID, sessionID: UUID) async -> JSONValue {
        guard let rev = review else { return reviewActionUnavailable }
        return await rev.applyAction(actionID: actionID, sessionID: sessionID, now: Date())
    }

    private func reviewReverse(actionID: UUID, sessionID: UUID) async -> JSONValue {
        guard let rev = review else { return reviewActionUnavailable }
        return await rev.reverseAction(actionID: actionID, sessionID: sessionID)
    }

    private func reviewResolveDuplicate(groupID: UUID, choiceID: UUID, sessionID: UUID) async -> JSONValue {
        guard let rev = review else { return reviewActionUnavailable }
        return await rev.resolveDuplicate(groupID: groupID, choiceID: choiceID, sessionID: sessionID, now: Date())
    }

    private func reviewComplete(sessionID: UUID) async -> JSONValue {
        guard let rev = review else { return reviewCompleteUnavailable }
        return await rev.completeSession(sessionID: sessionID, now: Date())
    }

    // MARK: - Review argument parsers (Wave B1)

    /// ReviewKindArguments: `{"kind": <ReviewKind>}`.
    private func parseReviewKind(_ arguments: JSONValue, tool: String) throws -> ReviewKind {
        guard case .object(let fields) = arguments else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "\(tool): arguments must be an object")
        }
        let known: Set<String> = ["kind"]
        for key in fields.keys where !known.contains(key) {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "\(tool): unknown argument field '\(key)'")
        }
        guard case .string(let kindRaw) = fields["kind"],
              let kind = ReviewKind(rawValue: kindRaw) else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "\(tool): 'kind' must be one of: morning, endOfDay, weekly")
        }
        return kind
    }

    /// ReviewActionArguments: `{"actionID": <uuid>, "sessionID": <uuid>}`.
    private func parseReviewActionArguments(_ arguments: JSONValue, tool: String) throws -> (UUID, UUID) {
        guard case .object(let fields) = arguments else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "\(tool): arguments must be an object")
        }
        let known: Set<String> = ["actionID", "sessionID"]
        for key in fields.keys where !known.contains(key) {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "\(tool): unknown argument field '\(key)'")
        }
        guard case .string(let actionIDRaw) = fields["actionID"],
              let actionID = UUID(uuidString: actionIDRaw) else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "\(tool): 'actionID' must be a valid UUID string")
        }
        guard case .string(let sessionIDRaw) = fields["sessionID"],
              let sessionID = UUID(uuidString: sessionIDRaw) else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "\(tool): 'sessionID' must be a valid UUID string")
        }
        return (actionID, sessionID)
    }

    /// DuplicateResolutionArguments: `{"groupID": <uuid>, "choiceID": <uuid>, "sessionID": <uuid>}`.
    private func parseDuplicateResolutionArguments(_ arguments: JSONValue) throws -> (UUID, UUID, UUID) {
        guard case .object(let fields) = arguments else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "moot_community_review_resolve_duplicate: arguments must be an object")
        }
        let known: Set<String> = ["groupID", "choiceID", "sessionID"]
        for key in fields.keys where !known.contains(key) {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "moot_community_review_resolve_duplicate: unknown argument field '\(key)'")
        }
        guard case .string(let groupIDRaw) = fields["groupID"],
              let groupID = UUID(uuidString: groupIDRaw) else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "moot_community_review_resolve_duplicate: 'groupID' must be a valid UUID string")
        }
        guard case .string(let choiceIDRaw) = fields["choiceID"],
              let choiceID = UUID(uuidString: choiceIDRaw) else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "moot_community_review_resolve_duplicate: 'choiceID' must be a valid UUID string")
        }
        guard case .string(let sessionIDRaw) = fields["sessionID"],
              let sessionID = UUID(uuidString: sessionIDRaw) else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "moot_community_review_resolve_duplicate: 'sessionID' must be a valid UUID string")
        }
        return (groupID, choiceID, sessionID)
    }

    /// SessionIDArguments: `{"sessionID": <uuid>}`.
    private func parseSessionID(_ arguments: JSONValue, tool: String) throws -> UUID {
        guard case .object(let fields) = arguments else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "\(tool): arguments must be an object")
        }
        let known: Set<String> = ["sessionID"]
        for key in fields.keys where !known.contains(key) {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "\(tool): unknown argument field '\(key)'")
        }
        guard case .string(let raw) = fields["sessionID"],
              let sessionID = UUID(uuidString: raw) else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "\(tool): 'sessionID' must be a valid UUID string")
        }
        return sessionID
    }

    // MARK: - Review tool schemas (Wave B1)

    private var reviewTools: [ProjectedTool] {
        [
            ProjectedTool(
                name: "moot_community_review_dashboard",
                description: "Returns the current review dashboard showing all three review kinds (morning, endOfDay, weekly) with their current status. Read-only — never mutates the estate.",
                inputSchema: emptySchema(),
                provenance: .community,
                outputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["modes": .object(["type": .string("array")])]),
                    "required": .array([.string("modes")]),
                ])
            ),
            ProjectedTool(
                name: "moot_community_review_session",
                description: "Returns or generates the current review session for the given kind. Read-only on the estate — persists only the session record to the sidecar.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["kind": .object(["type": .string("string")])]),
                    "required": .array([.string("kind")]),
                    "additionalProperties": .bool(false),
                ]),
                provenance: .community,
                outputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["outcome": .object(["type": .string("string")])]),
                    "required": .array([.string("outcome")]),
                ])
            ),
            ProjectedTool(
                name: "moot_community_review_apply",
                description: "Apply a review action. Exact actionID retry returns alreadyApplied (idempotent). Returns staleSession if the estate changed since the session was generated.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "actionID": .object(["type": .string("string")]),
                        "sessionID": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("actionID"), .string("sessionID")]),
                    "additionalProperties": .bool(false),
                ]),
                provenance: .community,
                outputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["outcome": .object(["type": .string("string")])]),
                    "required": .array([.string("outcome")]),
                ])
            ),
            ProjectedTool(
                name: "moot_community_review_reverse",
                description: "Reverse a previously applied review action. Refused if the action has not been applied or reversalAvailable is false.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "actionID": .object(["type": .string("string")]),
                        "sessionID": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("actionID"), .string("sessionID")]),
                    "additionalProperties": .bool(false),
                ]),
                provenance: .community,
                outputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["outcome": .object(["type": .string("string")])]),
                    "required": .array([.string("outcome")]),
                ])
            ),
            ProjectedTool(
                name: "moot_community_review_resolve_duplicate",
                description: "Resolve a duplicate group by applying a daemon-owned resolution choice. Idempotent for exact groupID + choiceID retry.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "groupID": .object(["type": .string("string")]),
                        "choiceID": .object(["type": .string("string")]),
                        "sessionID": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("groupID"), .string("choiceID"), .string("sessionID")]),
                    "additionalProperties": .bool(false),
                ]),
                provenance: .community,
                outputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["outcome": .object(["type": .string("string")])]),
                    "required": .array([.string("outcome")]),
                ])
            ),
            ProjectedTool(
                name: "moot_community_review_complete",
                description: "Complete a review session and return a durable completion receipt. The receipt.sessionID equals the request sessionID. Durable across daemon restarts.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "sessionID": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("sessionID")]),
                    "additionalProperties": .bool(false),
                ]),
                provenance: .community,
                outputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "outcome": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("outcome")]),
                ])
            ),
        ]
    }

    // MARK: - Capture routing (Wave A2b)

    /// Returns `failed{daemon-blocked}` when no capture coordinator is configured.
    private var captureUnavailable: JSONValue {
        CaptureOutcome.failed(reason: "daemon-blocked").toJSONValue()
    }

    private func captureChoices() async -> JSONValue {
        guard let cap = capture else { return captureUnavailable }
        return await cap.captureChoices()
    }

    private func captureRecord(arguments: CaptureArguments) async -> JSONValue {
        guard let cap = capture else { return captureUnavailable }
        return await cap.capture(arguments: arguments)
    }

    // MARK: - Capture argument parser (Wave A2b)

    /// CaptureArguments: fail-closed parser.
    ///
    /// Known fields: requestID, subject, content, destinationID, sensitivity,
    /// exportEligible, lanEligible. Unknown fields → invalidParams.
    ///
    /// All fields are required; missing or wrong-type fields → invalidParams.
    /// `sensitivity` must be one of the four contract values; unknown → invalidParams.
    /// `exportEligible` and `lanEligible` must be JSON booleans (not numbers or strings).
    private func parseCaptureArguments(_ arguments: JSONValue) throws -> CaptureArguments {
        guard case .object(let fields) = arguments else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "moot_community_capture: arguments must be an object")
        }
        // Fail-closed: reject any field not in the known set.
        let known: Set<String> = ["requestID", "subject", "content", "destinationID",
                                  "sensitivity", "exportEligible", "lanEligible"]
        for key in fields.keys where !known.contains(key) {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "moot_community_capture: unknown argument field '\(key)'")
        }
        // requestID: UUID string.
        guard case .string(let requestIDRaw) = fields["requestID"],
              let requestID = UUID(uuidString: requestIDRaw) else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "moot_community_capture: 'requestID' must be a valid UUID string")
        }
        // subject: string (may be empty per contract — not a nonempty-string type).
        guard case .string(let subject) = fields["subject"] else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "moot_community_capture: 'subject' must be a string")
        }
        // content: nonempty-string (validated at the coordinator, not here — we
        // let the coordinator produce the correct error code rather than mapping
        // parse errors onto capture-content-invalid).
        guard case .string(let content) = fields["content"] else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "moot_community_capture: 'content' must be a string")
        }
        // destinationID: nonempty-string.
        guard case .string(let destinationID) = fields["destinationID"],
              !destinationID.isEmpty else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "moot_community_capture: 'destinationID' must be a non-empty string")
        }
        // sensitivity: one of the four contract enum values.
        guard case .string(let sensitivityRaw) = fields["sensitivity"],
              let sensitivity = CaptureSensitivity(rawValue: sensitivityRaw) else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "moot_community_capture: 'sensitivity' must be one of: normal, elevated, restricted, secret")
        }
        // exportEligible: boolean (not number, not string).
        guard case .bool(let exportEligible) = fields["exportEligible"] else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "moot_community_capture: 'exportEligible' must be a boolean")
        }
        // lanEligible: boolean (not number, not string).
        guard case .bool(let lanEligible) = fields["lanEligible"] else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "moot_community_capture: 'lanEligible' must be a boolean")
        }
        return CaptureArguments(
            requestID: requestID,
            subject: subject,
            content: content,
            destinationID: destinationID,
            sensitivity: sensitivity,
            exportEligible: exportEligible,
            lanEligible: lanEligible
        )
    }

    // MARK: - Estate lifecycle routing (Wave A2a)

    /// Returns `blocked{daemon-blocked}` when no lifecycle coordinator is configured.
    private var lifecycleUnavailable: JSONValue {
        LifecycleMCPResponse.wrap(LifecycleStateBuilder.blocked(reason: "daemon-blocked"))
    }

    private func estateInspect() async -> JSONValue {
        guard let lc = lifecycle else { return lifecycleUnavailable }
        return await lc.inspect()
    }

    private func estateCreate(name: String) async -> JSONValue {
        guard let lc = lifecycle else { return lifecycleUnavailable }
        return await lc.create(name: name)
    }

    private func estateOpen(estateID: UUID) async -> JSONValue {
        guard let lc = lifecycle else { return lifecycleUnavailable }
        return await lc.open(estateID: estateID)
    }

    private func estateMigrate(planID: UUID) async -> JSONValue {
        guard let lc = lifecycle else { return lifecycleUnavailable }
        return await lc.migrate(planID: planID)
    }

    private func estateRecover(choiceID: String) async -> JSONValue {
        guard let lc = lifecycle else { return lifecycleUnavailable }
        return await lc.recover(choiceID: choiceID)
    }

    private func estateCancel(operationID: UUID) async -> JSONValue {
        guard let lc = lifecycle else { return lifecycleUnavailable }
        return await lc.cancel(operationID: operationID)
    }

    // MARK: - Argument parsers (fail-closed)
    //
    // Each parser enforces:
    //   1. arguments is an object (.object case).
    //   2. No unexpected fields — unknown field → invalidParams.
    //   3. Required fields are present and valid.
    //
    // The contract type names (Empty, NameArguments, etc.) live in
    // contracts/community/1.1/contract.json; these parsers are the
    // Swift implementation of those shapes.

    /// Empty: `{}`. Rejects any field (including nulls).
    private func validateEmpty(_ arguments: JSONValue, tool: String) throws {
        guard case .object(let fields) = arguments else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "\(tool): arguments must be an empty object")
        }
        if !fields.isEmpty {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "\(tool): unexpected argument field(s): \(fields.keys.sorted().joined(separator: ", "))")
        }
    }

    /// NameArguments: `{"name": <nonempty-string>}`.
    private func parseName(_ arguments: JSONValue, tool: String) throws -> String {
        guard case .object(let fields) = arguments else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "\(tool): arguments must be an object")
        }
        let known: Set<String> = ["name"]
        for key in fields.keys where !known.contains(key) {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "\(tool): unknown argument field '\(key)'")
        }
        guard case .string(let name) = fields["name"], !name.isEmpty else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "\(tool): 'name' must be a non-empty string")
        }
        return name
    }

    /// EstateIDArguments: `{"estateID": <uuid-string>}`.
    private func parseEstateID(_ arguments: JSONValue, tool: String) throws -> UUID {
        guard case .object(let fields) = arguments else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "\(tool): arguments must be an object")
        }
        let known: Set<String> = ["estateID"]
        for key in fields.keys where !known.contains(key) {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "\(tool): unknown argument field '\(key)'")
        }
        guard case .string(let raw) = fields["estateID"],
              let uuid = UUID(uuidString: raw) else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "\(tool): 'estateID' must be a valid UUID string")
        }
        return uuid
    }

    /// PlanIDArguments: `{"planID": <uuid-string>}`.
    private func parsePlanID(_ arguments: JSONValue, tool: String) throws -> UUID {
        guard case .object(let fields) = arguments else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "\(tool): arguments must be an object")
        }
        let known: Set<String> = ["planID"]
        for key in fields.keys where !known.contains(key) {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "\(tool): unknown argument field '\(key)'")
        }
        guard case .string(let raw) = fields["planID"],
              let uuid = UUID(uuidString: raw) else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "\(tool): 'planID' must be a valid UUID string")
        }
        return uuid
    }

    /// ChoiceIDArguments: `{"choiceID": <nonempty-string>}`.
    private func parseChoiceID(_ arguments: JSONValue, tool: String) throws -> String {
        guard case .object(let fields) = arguments else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "\(tool): arguments must be an object")
        }
        let known: Set<String> = ["choiceID"]
        for key in fields.keys where !known.contains(key) {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "\(tool): unknown argument field '\(key)'")
        }
        guard case .string(let choiceID) = fields["choiceID"], !choiceID.isEmpty else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "\(tool): 'choiceID' must be a non-empty string")
        }
        return choiceID
    }

    /// OperationIDArguments: `{"operationID": <uuid-string>}`.
    private func parseOperationID(_ arguments: JSONValue, tool: String) throws -> UUID {
        guard case .object(let fields) = arguments else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "\(tool): arguments must be an object")
        }
        let known: Set<String> = ["operationID"]
        for key in fields.keys where !known.contains(key) {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "\(tool): unknown argument field '\(key)'")
        }
        guard case .string(let raw) = fields["operationID"],
              let uuid = UUID(uuidString: raw) else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "\(tool): 'operationID' must be a valid UUID string")
        }
        return uuid
    }

    // MARK: - Estate tool list (Wave A2a)

    private var estateTools: [ProjectedTool] {
        [
            makeEstateTool(
                name: "moot_community_estate_inspect",
                description: "Returns the current estate lifecycle state. Read-only — never mutates the estate.",
                inputSchema: emptySchema()
            ),
            makeEstateTool(
                name: "moot_community_estate_create",
                description: "Creates a new estate. Permitted only when inspect returns needsCreation.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["name": .object(["type": .string("string")])]),
                    "required": .array([.string("name")]),
                    "additionalProperties": .bool(false),
                ])
            ),
            makeEstateTool(
                name: "moot_community_estate_open",
                description: "Opens an existing estate by its UUID.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["estateID": .object(["type": .string("string")])]),
                    "required": .array([.string("estateID")]),
                    "additionalProperties": .bool(false),
                ])
            ),
            makeEstateTool(
                name: "moot_community_estate_migrate",
                description: "Starts or reports a migration operation for the given plan.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["planID": .object(["type": .string("string")])]),
                    "required": .array([.string("planID")]),
                    "additionalProperties": .bool(false),
                ])
            ),
            makeEstateTool(
                name: "moot_community_estate_recover",
                description: "Applies a recovery choice to an estate in a recoverable state.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["choiceID": .object(["type": .string("string")])]),
                    "required": .array([.string("choiceID")]),
                    "additionalProperties": .bool(false),
                ])
            ),
            makeEstateTool(
                name: "moot_community_estate_cancel",
                description: "Cancels the current lifecycle operation.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["operationID": .object(["type": .string("string")])]),
                    "required": .array([.string("operationID")]),
                    "additionalProperties": .bool(false),
                ])
            ),
        ]
    }

    private func makeEstateTool(name: String, description: String, inputSchema: JSONValue) -> ProjectedTool {
        ProjectedTool(
            name: name,
            description: description,
            inputSchema: inputSchema,
            provenance: .community,
            outputSchema: estateLifecycleStateOutputSchema()
        )
    }

    private func emptySchema() -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false),
        ])
    }

    /// Minimal output schema for EstateLifecycleState (the discriminated union
    /// shape from the contract). Clients use structuredContent for typed access;
    /// this schema documents the discriminator field.
    private func estateLifecycleStateOutputSchema() -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "state": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("state")]),
        ])
    }

    // MARK: - Capture tool schemas (Wave A2b)

    private var captureTools: [ProjectedTool] {
        [
            ProjectedTool(
                name: "moot_community_capture_choices",
                description:
                    "Returns the available capture destinations (real rooms from the current "
                    + "estate), the four sensitivity levels, and the private-leaning default "
                    + "policy. Read-only — never mutates the estate.",
                inputSchema: emptySchema(),
                provenance: .community,
                outputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "destinations": .object(["type": .string("array")]),
                        "sensitivities": .object(["type": .string("array")]),
                        "defaultPolicy": .object(["type": .string("object")]),
                    ]),
                    "required": .array([
                        .string("destinations"),
                        .string("sensitivities"),
                        .string("defaultPolicy"),
                    ]),
                ])
            ),
            ProjectedTool(
                name: "moot_community_capture",
                description:
                    "Validate and persist a capture record. Returns applied{recordID, effectivePolicy} "
                    + "on success, refused{field, reason} on validation failure, or failed{reason} "
                    + "on an unexpected error. Exact requestID retries return the original receipt "
                    + "(idempotent). Same requestID with different payload returns request-conflict.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "requestID":     .object(["type": .string("string")]),
                        "subject":       .object(["type": .string("string")]),
                        "content":       .object(["type": .string("string")]),
                        "destinationID": .object(["type": .string("string")]),
                        "sensitivity":   .object(["type": .string("string")]),
                        "exportEligible": .object(["type": .string("boolean")]),
                        "lanEligible":   .object(["type": .string("boolean")]),
                    ]),
                    "required": .array([
                        .string("requestID"), .string("subject"), .string("content"),
                        .string("destinationID"), .string("sensitivity"),
                        .string("exportEligible"), .string("lanEligible"),
                    ]),
                    "additionalProperties": .bool(false),
                ]),
                provenance: .community,
                outputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "outcome": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("outcome")]),
                ])
            ),
        ]
    }

    // MARK: - Obsidian routing (Wave C1: CORE-06)

    /// Returns `blocked{daemon-blocked}` as ObsidianStatus when no coordinator.
    private var obsidianUnavailableStatus: JSONValue {
        ObsidianStatus.blocked(
            reason: "daemon-blocked",
            checkpointAt: nil,
            recordCount: nil
        ).toJSONValue()
    }

    /// Returns `missing` as ObsidianAuthorization when no coordinator.
    private var obsidianUnavailableAuthorization: JSONValue {
        ObsidianAuthorization.missing.toJSONValue()
    }

    /// Returns `denied{daemon-blocked}` as VaultSelectionOutcome when no coordinator.
    private var obsidianUnavailableSelection: JSONValue {
        VaultSelectionOutcome.denied(reason: "daemon-blocked").toJSONValue()
    }

    /// Returns `refused{daemon-blocked}` as ObsidianEnableOutcome when no coordinator.
    private var obsidianUnavailableEnable: JSONValue {
        ObsidianEnableOutcome.refused(reason: "daemon-blocked").toJSONValue()
    }

    /// Returns `failed{daemon-blocked}` as ObsidianDisableOutcome when no coordinator.
    private var obsidianUnavailableDisable: JSONValue {
        ObsidianDisableOutcome.failed(reason: "daemon-blocked").toJSONValue()
    }

    /// Returns `refused{daemon-blocked}` as ObsidianRetryOutcome when no coordinator.
    private var obsidianUnavailableRetry: JSONValue {
        ObsidianRetryOutcome.refused(reason: "daemon-blocked").toJSONValue()
    }

    private func obsidianStatus() async -> JSONValue {
        guard let obs = obsidian else { return obsidianUnavailableStatus }
        return await obs.status()
    }

    private func obsidianAuthorization() async -> JSONValue {
        guard let obs = obsidian else { return obsidianUnavailableAuthorization }
        return await obs.authorization()
    }

    private func obsidianSelectVault(bookmark: Data, displayName: String) async -> JSONValue {
        guard let obs = obsidian else { return obsidianUnavailableSelection }
        return await obs.selectVault(bookmark: bookmark, displayName: displayName)
    }

    private func obsidianEnable() async -> JSONValue {
        guard let obs = obsidian else { return obsidianUnavailableEnable }
        return await obs.enable()
    }

    private func obsidianDisable() async -> JSONValue {
        guard let obs = obsidian else { return obsidianUnavailableDisable }
        return await obs.disable()
    }

    private func obsidianRetry() async -> JSONValue {
        guard let obs = obsidian else { return obsidianUnavailableRetry }
        return await obs.retry()
    }

    // MARK: - Obsidian argument parser (Wave C1)

    /// VaultSelectionArguments: `{"bookmark": <base64-string>, "displayName": <nonempty-string>}`.
    ///
    /// Fail-closed: unknown fields, wrong types, or empty strings → invalidParams.
    /// The `bookmark` field is a base64-encoded string; decode it to Data here
    /// so the coordinator receives the raw bytes (not the base64 string).
    private func parseVaultSelectionArguments(_ arguments: JSONValue) throws -> (Data, String) {
        guard case .object(let fields) = arguments else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "moot_community_obsidian_select_vault: arguments must be an object")
        }
        let known: Set<String> = ["bookmark", "displayName"]
        for key in fields.keys where !known.contains(key) {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "moot_community_obsidian_select_vault: unknown argument field '\(key)'")
        }
        // bookmark: nonempty base64-encoded string.
        guard case .string(let bookmarkBase64) = fields["bookmark"],
              !bookmarkBase64.isEmpty,
              let bookmarkData = Data(base64Encoded: bookmarkBase64) else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "moot_community_obsidian_select_vault: 'bookmark' must be a non-empty base64-encoded string")
        }
        // displayName: nonempty string.
        guard case .string(let displayName) = fields["displayName"],
              !displayName.isEmpty else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "moot_community_obsidian_select_vault: 'displayName' must be a non-empty string")
        }
        return (bookmarkData, displayName)
    }

    // MARK: - Obsidian tool schemas (Wave C1)

    private var obsidianTools: [ProjectedTool] {
        [
            ProjectedTool(
                name: "moot_community_obsidian_status",
                description: "Returns the current Obsidian continuous-sync service status. Read-only.",
                inputSchema: emptySchema(),
                provenance: .community,
                outputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["state": .object(["type": .string("string")])]),
                    "required": .array([.string("state")]),
                ])
            ),
            ProjectedTool(
                name: "moot_community_obsidian_authorization",
                description: "Returns the current Obsidian vault authorization state: missing, valid, or needsRenewal. Read-only.",
                inputSchema: emptySchema(),
                provenance: .community,
                outputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["state": .object(["type": .string("string")])]),
                    "required": .array([.string("state")]),
                ])
            ),
            ProjectedTool(
                name: "moot_community_obsidian_select_vault",
                description: "Select the Obsidian vault from a base64-encoded bookmark and a display name. Returns selected{vaultURL, displayName} on success or denied{reason} on failure.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "bookmark":    .object(["type": .string("string")]),
                        "displayName": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("bookmark"), .string("displayName")]),
                    "additionalProperties": .bool(false),
                ]),
                provenance: .community,
                outputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["outcome": .object(["type": .string("string")])]),
                    "required": .array([.string("outcome")]),
                ])
            ),
            ProjectedTool(
                name: "moot_community_obsidian_enable",
                description: "Enable the Obsidian continuous-sync service. Requires valid vault authorization. Returns enabled, refused{reason}, or failed{reason}.",
                inputSchema: emptySchema(),
                provenance: .community,
                outputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["outcome": .object(["type": .string("string")])]),
                    "required": .array([.string("outcome")]),
                ])
            ),
            ProjectedTool(
                name: "moot_community_obsidian_disable",
                description: "Disable the Obsidian continuous-sync service. Vault content is preserved on disk. Returns disabledOnly, disabledAndRemoved, or failed{reason}.",
                inputSchema: emptySchema(),
                provenance: .community,
                outputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["outcome": .object(["type": .string("string")])]),
                    "required": .array([.string("outcome")]),
                ])
            ),
            ProjectedTool(
                name: "moot_community_obsidian_retry",
                description: "Retry the sync service after a retryable interruption. Returns restarted, refused{sync-not-retryable}, or failed{reason}.",
                inputSchema: emptySchema(),
                provenance: .community,
                outputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["outcome": .object(["type": .string("string")])]),
                    "required": .array([.string("outcome")]),
                ])
            ),
        ]
    }

    // MARK: - Transfer routing (Wave D1: CORE-07)

    /// Returns `failed{daemon-blocked}` as TransferExecutionOutcome when no transfer coordinator.
    ///
    /// Used as the fallback for all nine transfer endpoints when the coordinator
    /// has not been injected. The tool list is already gated (transfer tools
    /// absent when coordinator is nil), but a direct dispatch call may still
    /// arrive (e.g. from a test or a misconfigured client).
    private var transferUnavailable: JSONValue {
        TransferExecutionOutcome.failed(reason: "daemon-blocked").toJSONValue()
    }

    private func transferImportSource(bookmark: Data, displayName: String) async -> JSONValue {
        guard let t = transfer else { return transferUnavailable }
        return await t.importSource(bookmark: bookmark, displayName: displayName)
    }

    private func transferImportPlan(bookmark: Data) async -> JSONValue {
        guard let t = transfer else { return transferUnavailable }
        return await t.importPlan(bookmark: bookmark)
    }

    private func transferImportExecute(planToken: String) async -> JSONValue {
        guard let t = transfer else { return transferUnavailable }
        return await t.importExecute(planToken: planToken)
    }

    private func transferExportDestination(bookmark: Data, fileName: String) async -> JSONValue {
        guard let t = transfer else { return transferUnavailable }
        return await t.exportDestination(bookmark: bookmark, fileName: fileName)
    }

    private func transferExportScopes() async -> JSONValue {
        guard let t = transfer else { return transferUnavailable }
        return await t.exportScopes()
    }

    private func transferExportPlan(bookmark: Data, fileName: String, scopeToken: String) async -> JSONValue {
        guard let t = transfer else { return transferUnavailable }
        return await t.exportPlan(bookmark: bookmark, fileName: fileName, scopeToken: scopeToken)
    }

    private func transferExportExecute(planToken: String) async -> JSONValue {
        guard let t = transfer else { return transferUnavailable }
        return await t.exportExecute(planToken: planToken)
    }

    private func transferJobStatus(jobID: String) async -> JSONValue {
        guard let t = transfer else { return transferUnavailable }
        return await t.jobStatus(jobID: jobID)
    }

    private func transferJobCancel(jobID: String) async -> JSONValue {
        guard let t = transfer else { return transferUnavailable }
        return await t.jobCancel(jobID: jobID)
    }

    // MARK: - Transfer argument parsers (Wave D1: CORE-07)

    /// ImportSourceArguments: `{"bookmark": <base64>, "displayName": <nonempty-string>}`.
    ///
    /// Fail-closed: unknown fields, wrong types, empty strings → invalidParams.
    /// The bookmark is decoded from base64 to Data (raw bytes) before routing.
    private func parseTransferSourceArguments(_ arguments: JSONValue) throws -> (Data, String) {
        guard case .object(let fields) = arguments else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "moot_community_transfer_import_source: arguments must be an object")
        }
        let known: Set<String> = ["bookmark", "displayName"]
        for key in fields.keys where !known.contains(key) {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "moot_community_transfer_import_source: unknown argument field '\(key)'")
        }
        guard case .string(let bookmarkBase64) = fields["bookmark"],
              !bookmarkBase64.isEmpty,
              let bookmarkData = Data(base64Encoded: bookmarkBase64) else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "moot_community_transfer_import_source: 'bookmark' must be a non-empty base64-encoded string")
        }
        guard case .string(let displayName) = fields["displayName"],
              !displayName.isEmpty else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "moot_community_transfer_import_source: 'displayName' must be a non-empty string")
        }
        return (bookmarkData, displayName)
    }

    /// ImportPlanArguments: `{"bookmark": <base64>}`.
    ///
    /// Fail-closed: unknown fields, wrong types → invalidParams.
    private func parseTransferPlanArguments(_ arguments: JSONValue) throws -> Data {
        guard case .object(let fields) = arguments else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "moot_community_transfer_import_plan: arguments must be an object")
        }
        let known: Set<String> = ["bookmark"]
        for key in fields.keys where !known.contains(key) {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "moot_community_transfer_import_plan: unknown argument field '\(key)'")
        }
        guard case .string(let bookmarkBase64) = fields["bookmark"],
              !bookmarkBase64.isEmpty,
              let bookmarkData = Data(base64Encoded: bookmarkBase64) else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "moot_community_transfer_import_plan: 'bookmark' must be a non-empty base64-encoded string")
        }
        return bookmarkData
    }

    /// PlanTokenArguments: `{"planToken": <nonempty-string>}`.
    ///
    /// Shared by importExecute and exportExecute.
    /// Fail-closed: unknown fields, wrong types → invalidParams.
    private func parsePlanTokenArguments(_ arguments: JSONValue, tool: String) throws -> String {
        guard case .object(let fields) = arguments else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "\(tool): arguments must be an object")
        }
        let known: Set<String> = ["planToken"]
        for key in fields.keys where !known.contains(key) {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "\(tool): unknown argument field '\(key)'")
        }
        guard case .string(let planToken) = fields["planToken"],
              !planToken.isEmpty else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "\(tool): 'planToken' must be a non-empty string")
        }
        return planToken
    }

    /// ExportDestinationArguments: `{"bookmark": <base64>, "fileName": <nonempty-string>}`.
    ///
    /// Fail-closed: unknown fields, wrong types, empty strings → invalidParams.
    private func parseTransferDestinationArguments(_ arguments: JSONValue) throws -> (Data, String) {
        guard case .object(let fields) = arguments else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "moot_community_transfer_export_destination: arguments must be an object")
        }
        let known: Set<String> = ["bookmark", "fileName"]
        for key in fields.keys where !known.contains(key) {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "moot_community_transfer_export_destination: unknown argument field '\(key)'")
        }
        guard case .string(let bookmarkBase64) = fields["bookmark"],
              !bookmarkBase64.isEmpty,
              let bookmarkData = Data(base64Encoded: bookmarkBase64) else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "moot_community_transfer_export_destination: 'bookmark' must be a non-empty base64-encoded string")
        }
        guard case .string(let fileName) = fields["fileName"],
              !fileName.isEmpty else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "moot_community_transfer_export_destination: 'fileName' must be a non-empty string")
        }
        return (bookmarkData, fileName)
    }

    /// ExportPlanArguments: `{"bookmark": <base64>, "fileName": <nonempty-string>, "scopeToken": <nonempty-string>}`.
    ///
    /// Fail-closed: unknown fields, wrong types, empty strings → invalidParams.
    private func parseTransferExportPlanArguments(_ arguments: JSONValue) throws -> (Data, String, String) {
        guard case .object(let fields) = arguments else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "moot_community_transfer_export_plan: arguments must be an object")
        }
        let known: Set<String> = ["bookmark", "fileName", "scopeToken"]
        for key in fields.keys where !known.contains(key) {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "moot_community_transfer_export_plan: unknown argument field '\(key)'")
        }
        guard case .string(let bookmarkBase64) = fields["bookmark"],
              !bookmarkBase64.isEmpty,
              let bookmarkData = Data(base64Encoded: bookmarkBase64) else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "moot_community_transfer_export_plan: 'bookmark' must be a non-empty base64-encoded string")
        }
        guard case .string(let fileName) = fields["fileName"],
              !fileName.isEmpty else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "moot_community_transfer_export_plan: 'fileName' must be a non-empty string")
        }
        guard case .string(let scopeToken) = fields["scopeToken"],
              !scopeToken.isEmpty else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "moot_community_transfer_export_plan: 'scopeToken' must be a non-empty string")
        }
        return (bookmarkData, fileName, scopeToken)
    }

    /// JobIDArguments: `{"jobID": <nonempty-string>}`.
    ///
    /// Shared by jobStatus and jobCancel.
    /// Fail-closed: unknown fields, wrong types → invalidParams.
    private func parseJobIDArguments(_ arguments: JSONValue, tool: String) throws -> String {
        guard case .object(let fields) = arguments else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "\(tool): arguments must be an object")
        }
        let known: Set<String> = ["jobID"]
        for key in fields.keys where !known.contains(key) {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "\(tool): unknown argument field '\(key)'")
        }
        guard case .string(let jobID) = fields["jobID"],
              !jobID.isEmpty else {
            throw JSONRPCError(code: JSONRPCErrorCode.invalidParams,
                               message: "\(tool): 'jobID' must be a non-empty string")
        }
        return jobID
    }

    // MARK: - Transfer tool schemas (Wave D1: CORE-07)

    /// The nine transfer-family tool schemas.
    ///
    /// Gated: this var is accessed only when `transfer != nil` (communityToolList
    /// gate). The schemas document the byte-exact argument shapes from contract.json.
    private var transferTools: [ProjectedTool] {
        let bookmarkAndDisplayName: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "bookmark":    .object(["type": .string("string")]),
                "displayName": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("bookmark"), .string("displayName")]),
            "additionalProperties": .bool(false),
        ])
        let bookmarkOnly: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "bookmark": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("bookmark")]),
            "additionalProperties": .bool(false),
        ])
        let planTokenOnly: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "planToken": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("planToken")]),
            "additionalProperties": .bool(false),
        ])
        let jobIDOnly: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "jobID": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("jobID")]),
            "additionalProperties": .bool(false),
        ])
        let bookmarkFileNameScope: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "bookmark":   .object(["type": .string("string")]),
                "fileName":   .object(["type": .string("string")]),
                "scopeToken": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("bookmark"), .string("fileName"), .string("scopeToken")]),
            "additionalProperties": .bool(false),
        ])
        let bookmarkFileName: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "bookmark": .object(["type": .string("string")]),
                "fileName": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("bookmark"), .string("fileName")]),
            "additionalProperties": .bool(false),
        ])
        let outcomeSchema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object(["outcome": .object(["type": .string("string")])]),
            "required": .array([.string("outcome")]),
        ])
        return [
            ProjectedTool(
                name: "moot_community_transfer_import_source",
                description: "Validate an import source file bookmark and detect its transfer format. Read-only. Returns selected{format} or denied{reason}.",
                inputSchema: bookmarkAndDisplayName,
                provenance: .community,
                outputSchema: outcomeSchema
            ),
            ProjectedTool(
                name: "moot_community_transfer_import_plan",
                description: "Plan an import without mutating the estate. Classifies records as recognized, duplicate, or invalid. Returns planned{plan} or failed{reason}.",
                inputSchema: bookmarkOnly,
                provenance: .community,
                outputSchema: outcomeSchema
            ),
            ProjectedTool(
                name: "moot_community_transfer_import_execute",
                description: "Execute an import job bound to a prior plan token. Exact planToken retry returns the existing jobID (idempotent). Returns submitted{jobID}, denied{reason}, or failed{reason}.",
                inputSchema: planTokenOnly,
                provenance: .community,
                outputSchema: outcomeSchema
            ),
            ProjectedTool(
                name: "moot_community_transfer_export_destination",
                description: "Validate an export destination bookmark. Returns selected or denied{reason}.",
                inputSchema: bookmarkFileName,
                provenance: .community,
                outputSchema: outcomeSchema
            ),
            ProjectedTool(
                name: "moot_community_transfer_export_scopes",
                description: "Return available export scopes with real candidate counts from the current estate. Read-only.",
                inputSchema: emptySchema(),
                provenance: .community,
                outputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["scopes": .object(["type": .string("array")])]),
                    "required": .array([.string("scopes")]),
                ])
            ),
            ProjectedTool(
                name: "moot_community_transfer_export_plan",
                description: "Plan an export without writing the final output file. Read-only — zero estate mutation. Returns planned{plan} or failed{reason}.",
                inputSchema: bookmarkFileNameScope,
                provenance: .community,
                outputSchema: outcomeSchema
            ),
            ProjectedTool(
                name: "moot_community_transfer_export_execute",
                description: "Execute an export job bound to a prior plan token. Exact planToken retry returns the existing jobID (idempotent). Returns submitted{jobID}, denied{reason}, or failed{reason}.",
                inputSchema: planTokenOnly,
                provenance: .community,
                outputSchema: outcomeSchema
            ),
            ProjectedTool(
                name: "moot_community_transfer_job_status",
                description: "Return the current state of a transfer job. jobID echo invariant: the jobID in the response equals the jobID in the request. States survive coordinator restarts.",
                inputSchema: jobIDOnly,
                provenance: .community,
                outputSchema: outcomeSchema
            ),
            ProjectedTool(
                name: "moot_community_transfer_job_cancel",
                description: "Cancel a transfer job. Returns cancelled{stage}, notFound, alreadyComplete, or failed{reason}.",
                inputSchema: jobIDOnly,
                provenance: .community,
                outputSchema: outcomeSchema
            ),
        ]
    }

    // MARK: - LAN routing (Wave D2: CORE-08)

    /// Returns `failed{daemon-blocked}` as LANStatus when no LAN coordinator is configured.
    private var lanUnavailableStatus: JSONValue {
        LANStatus.failed(reason: "daemon-blocked").toJSONValue()
    }

    /// Returns `failed{daemon-blocked}` as LANStartOutcome when no coordinator.
    private var lanUnavailableStart: JSONValue {
        LANStartOutcome.failed(reason: "daemon-blocked").toJSONValue()
    }

    /// Returns `failed{daemon-blocked}` as LANStopOutcome when no coordinator.
    private var lanUnavailableStop: JSONValue {
        LANStopOutcome.failed(reason: "daemon-blocked").toJSONValue()
    }

    /// Returns `failed{daemon-blocked}` as LANEligibilityOutcome when no coordinator.
    private var lanUnavailableEligibility: JSONValue {
        LANEligibilityOutcome.failed(reason: "daemon-blocked").toJSONValue()
    }

    private func lanStatus() async -> JSONValue {
        guard let l = lan else { return lanUnavailableStatus }
        return await l.status()
    }

    private func lanPolicy() async -> JSONValue {
        guard let l = lan else {
            // No coordinator — return zero counts (cannot compute without layout).
            return LANPolicy(
                eligibleCount: 0,
                ineligibleCount: 0,
                policyDescription: CommunityLANCoordinator.policyDescription
            ).toJSONValue()
        }
        return await l.policy()
    }

    private func lanStart() async -> JSONValue {
        guard let l = lan else { return lanUnavailableStart }
        return await l.start()
    }

    private func lanStop() async -> JSONValue {
        guard let l = lan else { return lanUnavailableStop }
        return await l.stop()
    }

    private func lanRefreshEligibility() async -> JSONValue {
        guard let l = lan else { return lanUnavailableEligibility }
        return await l.refreshEligibility()
    }

    // MARK: - LAN tool schemas (Wave D2: CORE-08)

    /// The five LAN-family tool schemas.
    ///
    /// Gated: accessed only when `lan != nil` (communityToolList gate).
    private var lanTools: [ProjectedTool] {
        let outcomeSchema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object(["outcome": .object(["type": .string("string")])]),
            "required": .array([.string("outcome")]),
        ])
        let stateSchema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object(["state": .object(["type": .string("string")])]),
            "required": .array([.string("state")]),
        ])
        return [
            ProjectedTool(
                name: "moot_community_lan_status",
                description: "Returns the current LAN serving state: stopped, starting, active{endpoint,authentication}, interrupted{reason}, blocked{reason}, or failed{reason}. Read-only.",
                inputSchema: emptySchema(),
                provenance: .community,
                outputSchema: stateSchema
            ),
            ProjectedTool(
                name: "moot_community_lan_policy",
                description: "Returns eligibility counts (eligible/ineligible) and the policy description. Counts are computed live from the capture ledger. Read-only.",
                inputSchema: emptySchema(),
                provenance: .community,
                outputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "eligibleCount":     .object(["type": .string("integer")]),
                        "ineligibleCount":   .object(["type": .string("integer")]),
                        "policyDescription": .object(["type": .string("string")]),
                    ]),
                    "required": .array([
                        .string("eligibleCount"),
                        .string("ineligibleCount"),
                        .string("policyDescription"),
                    ]),
                ])
            ),
            ProjectedTool(
                name: "moot_community_lan_start",
                description: "Start LAN serving. Returns started{endpoint,authentication} on success, denied{lan-authority-missing} when authority is absent, or failed{reason} on error.",
                inputSchema: emptySchema(),
                provenance: .community,
                outputSchema: outcomeSchema
            ),
            ProjectedTool(
                name: "moot_community_lan_stop",
                description: "Stop LAN serving and close the socket. Returns stopped when the endpoint is no longer serving, or failed{reason} on error.",
                inputSchema: emptySchema(),
                provenance: .community,
                outputSchema: outcomeSchema
            ),
            ProjectedTool(
                name: "moot_community_lan_refresh_eligibility",
                description: "Recompute LAN eligibility from the current capture ledger. Takes effect on the live server without restart. Returns updated{eligibleCount,ineligibleCount}, refused{reason}, or failed{reason}.",
                inputSchema: emptySchema(),
                provenance: .community,
                outputSchema: outcomeSchema
            ),
        ]
    }

    // MARK: - Private

    /// The `moot_community_contract_identity` tool definition.
    ///
    /// Input schema: empty object (no parameters). The tool is called
    /// with `{}` and returns the contract identity fields. The fixture
    /// "identity-exact-match" case specifies `"arguments": {}` and the
    /// result shape.
    private var identityTool: ProjectedTool {
        ProjectedTool(
            name: "moot_community_contract_identity",
            description:
                "Returns the identity of the running mootx01 community daemon: " +
                "the contract coordinates, fixture-bundle digest, and the live " +
                "instance and estate UUIDs.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false),
            ]),
            provenance: .community,
            outputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "contractID": .object(["type": .string("string")]),
                    "contractVersion": .object(["type": .string("string")]),
                    "fixtureDigestAlgorithm": .object(["type": .string("string")]),
                    "fixtureDigest": .object(["type": .string("string")]),
                    "daemonInstanceID": .object(["type": .string("string")]),
                    "estateID": .object(["type": .string("string")]),
                ]),
                "required": .array([
                    .string("contractID"), .string("contractVersion"),
                    .string("fixtureDigestAlgorithm"), .string("fixtureDigest"),
                    .string("daemonInstanceID"), .string("estateID"),
                ]),
                "additionalProperties": .bool(false),
            ])
        )
    }

    /// Build the `moot_community_contract_identity` response payload.
    ///
    /// UUIDs are wire-encoded as lowercase hyphenated strings (per the
    /// MOOTX01 UUID wire convention: `uuid.uuidString.lowercased()`).
    ///
    /// The `content` wrapper follows the MCP tools/call structured-result
    /// shape: `{"content": [{"type": "text", "text": "<json>"}]}`.
    /// The `structuredContent` field carries the typed result for clients
    /// that parse the outputSchema.
    private func contractIdentityResponse() -> JSONValue {
        let identity: [String: JSONValue] = [
            "contractID": .string(CommunityContractConstants.contractID),
            "contractVersion": .string(CommunityContractConstants.contractVersion),
            "fixtureDigestAlgorithm": .string(CommunityContractConstants.fixtureDigestAlgorithm),
            "fixtureDigest": .string(CommunityContractConstants.fixtureDigest),
            // UUIDs as lowercase hyphenated strings — the wire convention for
            // all UUID values in the MOOTX01 MCP surface.
            "daemonInstanceID": .string(state.instanceIdentifier.uuidString.lowercased()),
            "estateID": .string(state.estateIdentifier.uuidString.lowercased()),
        ]
        // Encode as the MCP structured-result shape: a "content" array with one
        // text frame (JSON-serialized identity) and a "structuredContent" field
        // carrying the typed object for schema-aware clients.
        guard let jsonData = try? JSONSerialization.data(
            withJSONObject: jsonObjectFrom(identity),
            options: [.sortedKeys]
        ) else {
            // Unreachable: all values are strings; serialisation cannot fail.
            return .object([:])
        }
        let jsonText = String(decoding: jsonData, as: UTF8.self)
        return .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(jsonText),
                ])
            ]),
            "structuredContent": .object(identity),
        ])
    }

    /// Convert `[String: JSONValue]` to the `[String: Any]` shape that
    /// JSONSerialization expects. Only string values are needed here.
    private func jsonObjectFrom(_ dict: [String: JSONValue]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (k, v) in dict {
            if case .string(let s) = v { result[k] = s }
        }
        return result
    }
}
