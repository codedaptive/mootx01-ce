import Foundation

// MARK: - CommunityDaemonReason  (MD-MOOT-CAPTURE-LANGUAGE, MI-MOOT-INTEGRATION-LANGUAGE)
//
// Human presentation for the resident daemon's machine reason codes.
//
// The Community 1.1 contract (apps/mootx01/Contracts/community-1.1/contract.json,
// `reasonCodes`) names refusal and failure causes as stable slugs
// ("privacy-escalation", "lan-authority-missing", …). Those slugs are wire
// vocabulary: the human-language acceptance law forbids showing them as the
// visible explanation. This type maps each code that can reach the capture,
// LAN, Obsidian sync, Transfer, estate-lifecycle/setup, shell-status, and
// review surfaces to a truthful human sentence derived from the daemon's
// implemented semantics
// (apps/mootx01/Sources/MootCommunityDaemon/CommunityCaptureCoordinator.swift,
// CommunityLANCoordinator.swift, CommunityObsidianCoordinator.swift,
// CommunityTransferCoordinator.swift, and CommunityEstateLifecycle.swift)
// and from the app-side wire adapters and models that synthesize their own
// codes (DaemonCommunityCaptureService, DaemonLANControlPort,
// DaemonCommunityFeaturePorts, CommunityAppModel).
//
// FAIL-HONEST rule: a code with no mapping gets an explicit "not recognized"
// sentence — never a fabricated meaning and never the bare slug as prose.
// The exact code always remains available through `technicalDetail` as a
// labeled, selectable secondary line so support requests and bug reports
// carry the daemon's precise word.

/// One daemon-supplied reason code with its human presentation.
public struct CommunityDaemonReason: Sendable, Equatable {

    /// The verbatim machine code from the daemon or wire adapter.
    public let code: String

    /// Wrap a daemon reason code for presentation.
    public init(code: String) {
        self.code = code
    }

    /// Whether the code maps to a contract-derived human explanation.
    public var isRecognized: Bool {
        Self.mappedExplanation(forCode: code) != nil
    }

    /// The human sentence shown wherever the daemon's reason is surfaced.
    /// Unrecognized codes get an honest "not recognized" sentence; the exact
    /// code is then carried by `technicalDetail`, never invented prose.
    public var explanation: String {
        Self.mappedExplanation(forCode: code)
            ?? String(localized: "The resident daemon reported a reason this app does not recognize.")
    }

    /// Labeled technical detail naming the exact machine code. Rendered as a
    /// secondary caption under the explanation so the precise daemon word
    /// stays available without being the primary display language.
    public var technicalDetail: String {
        String(localized: "Reason code: \(code)")
    }

    /// The closed slug-to-sentence mapping. Every sentence states what the
    /// condition MEANS for the user, grounded in the daemon implementation —
    /// nothing here speculates beyond what the contract enforces.
    private static func mappedExplanation(forCode code: String) -> String? {
        switch code {
        // Capture refusals (contract reasonCodes; semantics per
        // CommunityCaptureCoordinator's validation order).
        case "capture-content-invalid":
            String(localized: "The capture's content or privacy settings are not valid, so nothing was saved.")
        case "destination-stale":
            String(localized: "The chosen destination is no longer available in your estate. Choose another destination.")
        case "destination-forbidden":
            String(localized: "The chosen destination is not one the resident daemon offers.")
        case "privacy-escalation":
            String(localized: "The requested sharing eligibility would expose this capture more widely than its sensitivity allows.")
        case "request-conflict":
            String(localized: "A different capture already used this request's identity, so this one was refused to prevent a duplicate.")
        // LAN serving (semantics per CommunityLANCoordinator).
        case "lan-authority-missing":
            String(localized: "LAN sharing requires an authorization the resident daemon does not currently hold.")
        case "lan-network-unavailable":
            String(localized: "No usable network connection is available for LAN sharing.")
        case "lan-policy-forbidden":
            String(localized: "The estate's sharing policy does not allow this LAN operation.")
        case "lan-credential-expired":
            String(localized: "The LAN sharing credential has expired and must be renewed before serving continues.")
        // Obsidian synchronization (semantics per CommunityObsidianCoordinator:
        // vault selection/enable refuse without persisted authorization, access
        // revocation marks renewal-needed and interrupts sync, and retry is
        // refused when the current state is not retryable).
        case "vault-authorization-missing":
            String(localized: "No Obsidian vault is currently authorized. Select a vault to grant access.")
        case "vault-access-revoked":
            String(localized: "Access to the Obsidian vault has been revoked. Authorize the vault again to continue.")
        case "sync-not-retryable":
            String(localized: "The current synchronization state does not allow a retry.")
        // Transfer (semantics per CommunityTransferCoordinator: source and
        // destination selections are denied when scoped file access is no
        // longer held, execution is denied when the plan token no longer
        // matches the current plan, and policy refusals come from the
        // estate's sharing policy).
        case "permission-revoked":
            String(localized: "Permission to use the selected file or folder is no longer held. Choose it again to renew access.")
        case "plan-stale":
            String(localized: "The transfer plan no longer matches the current data. Create a new plan before executing.")
        case "policy-refused":
            String(localized: "The estate's sharing policy does not allow this transfer operation.")
        // App-side adapter conditions for the Obsidian and Transfer surfaces
        // (DaemonCommunityFeaturePorts: scoped-bookmark creation failed, the
        // system file picker is unavailable on this platform, or a job-status
        // response did not match the job it was requested for).
        case "vault-authorization-unavailable":
            String(localized: "This app could not keep authorized access to the selected vault. Select it again.")
        case "vault-selection-unavailable":
            String(localized: "Selecting a vault is not available on this device.")
        case "source-authorization-unavailable":
            String(localized: "This app could not keep authorized access to the selected import source. Choose it again.")
        case "source-selection-unavailable":
            String(localized: "Choosing an import source is not available on this device.")
        case "destination-authorization-unavailable":
            String(localized: "This app could not keep authorized access to the selected export destination. Choose it again.")
        case "destination-selection-unavailable":
            String(localized: "Choosing an export destination is not available on this device.")
        case "job-identity-or-payload-mismatch":
            String(localized: "The resident daemon's answer did not match this transfer job, so the result was not trusted.")
        // Estate lifecycle (contract reasonCodes; semantics per
        // CommunityEstateLifecycle's endpoint guards and the blocked-reason
        // vocabulary enumerated on LifecycleStateBuilder.blocked).
        case "estate-missing":
            String(localized: "No estate exists where the resident daemon expected one.")
        case "estate-corrupt":
            String(localized: "The estate's data failed an integrity check and needs recovery before it can open.")
        case "estate-incompatible":
            String(localized: "The estate's version is not compatible with this app.")
        case "estate-key-missing":
            String(localized: "The estate's encryption key is missing, so the estate cannot be opened.")
        case "migration-required":
            String(localized: "The estate must be migrated before it can open.")
        case "migration-interrupted":
            String(localized: "The estate migration was interrupted and cannot continue right now.")
        case "operation-cancelled":
            String(localized: "The operation was cancelled before it finished.")
        case "authority-insufficient":
            String(localized: "This operation requires an authority the resident daemon does not currently hold.")
        case "action-refused":
            String(localized: "The resident daemon refused this request because it is not valid for the estate's current state.")
        // App-synthesized condition: the setup receipt names a different
        // estate than the authenticated daemon connection
        // (CommunityAppModel.start's identity check).
        case "estate-identity-mismatch":
            String(localized: "This app and the resident daemon are showing different estates. Reconnect to verify the estate again.")
        // App-side review wire-adapter conditions (DaemonReviewCenterPort:
        // a structurally valid response missing required fields, or a
        // session for a different review kind than requested).
        case "incomplete-daemon-response":
            String(localized: "The resident daemon's response was missing required information.")
        case "session-kind-mismatch":
            String(localized: "The resident daemon returned a different review session than the one requested.")
        // Cross-surface daemon conditions.
        case "unexpected-failure":
            String(localized: "The resident daemon encountered an unexpected internal failure.")
        case "daemon-blocked":
            String(localized: "The resident daemon is blocked and cannot complete this operation.")
        case "daemon-refused":
            String(localized: "The resident daemon refused the request without giving a specific reason.")
        case "daemon-result-ambiguous":
            String(localized: "The connection ended before the app received the result. The operation may already be complete; check your estate before trying again.")
        // App-side wire-adapter conditions (unreachable daemon or a response
        // that failed strict parsing — the adapters never guess a cause).
        case "daemon-unavailable", "daemon-unavailable-or-malformed",
             "daemon-call-failed", "malformed-daemon-response":
            String(localized: "The resident daemon could not be reached, or its response could not be understood.")
        default:
            nil
        }
    }
}
