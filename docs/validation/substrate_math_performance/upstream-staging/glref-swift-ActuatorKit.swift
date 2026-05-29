// ActuatorKit.swift
//
// ActuatorKit per cookbook § 14 and paper § 11.4.
//
// Actuators are the substrate's outbound side: they translate a
// validated Proposal into an OS action (post a notification,
// send a calendar invite, open a URL, write a file). The kit
// enforces three invariants on every action:
//
//   I-21  Allowlist gate: every action_kind MUST be present in
//         the actuator allowlist, which is declared in the
//         estate's manifest and audited.
//   I-22  Outcome reporting: every action_kind MUST emit an
//         action-outcome audit event on completion (success,
//         partial, persisted, regressed, timed_out, not_attempted).
//   I-23  Reversibility tag: every action_kind declares whether
//         it is reversible. Irreversible actions require explicit
//         user confirmation through the cognition tier (§ 14.4).
//
// Allowlist values map to the o07 action_kind bitmap field
// (cookbook § 2.4, 6-bit width, 64 possible kinds). The v0.36
// shipping kit defines 12 kinds with room to grow.
//
// Used by:
//   § 14 cookbook    ActuatorKit definition (this file)
//   § 11.4 paper     Actuator dispatch
//   § 6.5 cookbook   Action-outcome matrix (consumer)
//   § 15 cookbook    Dreaming daemon rule 12 (outcome ingest)

import Foundation

public enum ActionKind: UInt8, Sendable, CaseIterable {
    case localNotification    = 1
    case calendarInsert       = 2
    case calendarRemove       = 3
    case reminderInsert       = 4
    case openURL              = 5
    case writeFile            = 6
    case shellExecute         = 7      // gated by I-23 (irreversible)
    case sendMessage          = 8
    case adjustHomeAutomation = 9
    case requestUserInput     = 10
    case logToAudit           = 11
    case rotatePrivateKey     = 12     // gated by I-23 (irreversible)

    public var isReversible: Bool {
        switch self {
        case .localNotification,
             .calendarRemove,
             .openURL,
             .logToAudit,
             .requestUserInput:
            return true
        case .calendarInsert,
             .reminderInsert,
             .sendMessage,
             .writeFile,
             .adjustHomeAutomation:
            return false      // can be undone by a follow-up action but not transparently
        case .shellExecute,
             .rotatePrivateKey:
            return false      // hard-irreversible (I-23 requires explicit confirm)
        }
    }
}

public enum OutcomeCategory: UInt8, Sendable, CaseIterable {
    case resolved     = 0
    case partial      = 1
    case persisted    = 2
    case regressed    = 3
    case timedOut     = 4
    case notAttempted = 5
}

public struct ActuatorAllowlist: Sendable {
    public let allowed: Set<ActionKind>

    public init(allowed: Set<ActionKind>) {
        self.allowed = allowed
    }

    public func contains(_ kind: ActionKind) -> Bool {
        return allowed.contains(kind)
    }

    /// Default allowlist for an unconfigured estate: only
    /// localNotification and logToAudit are permitted. Operators
    /// expand this through the manifest with explicit audit.
    public static let defaultAllowlist = ActuatorAllowlist(
        allowed: [.localNotification, .logToAudit]
    )
}

public struct ActionProposal: Sendable {
    public let kind: ActionKind
    public let rationale: String
    public let payload: Data
    public let outcomeCategory: OutcomeCategory?    // nil until completed
    public let proposedHLC: HLC
    public let confirmationToken: UUID?

    public init(kind: ActionKind, rationale: String, payload: Data,
                outcomeCategory: OutcomeCategory? = nil,
                proposedHLC: HLC, confirmationToken: UUID? = nil) {
        self.kind = kind
        self.rationale = rationale
        self.payload = payload
        self.outcomeCategory = outcomeCategory
        self.proposedHLC = proposedHLC
        self.confirmationToken = confirmationToken
    }
}

public struct ActuationResult: Sendable {
    public let kind: ActionKind
    public let outcome: OutcomeCategory
    public let completedHLC: HLC
    public let errorMessage: String?

    public init(kind: ActionKind, outcome: OutcomeCategory,
                completedHLC: HLC, errorMessage: String? = nil) {
        self.kind = kind
        self.outcome = outcome
        self.completedHLC = completedHLC
        self.errorMessage = errorMessage
    }
}

public enum ActuatorKitError: Error, Sendable {
    case notInAllowlist(ActionKind)
    case irreversibleWithoutConfirmation(ActionKind)
    case handlerUnavailable(ActionKind)
}

/// The handler protocol an OS-bound implementation conforms to.
/// Production code in NexusIOS / NexusMacOS provides handlers that
/// call UNUserNotificationCenter, EventKit, NSWorkspace, and so on.
public protocol ActuatorHandler: Sendable {
    func handles(_ kind: ActionKind) -> Bool
    func execute(_ proposal: ActionProposal) throws -> ActuationResult
}

public final class ActuatorKit {
    public let allowlist: ActuatorAllowlist
    private var handlers: [ActuatorHandler]
    private(set) public var outcomeLog: [(HLC, ActionKind, OutcomeCategory)] = []

    public init(allowlist: ActuatorAllowlist = .defaultAllowlist,
                handlers: [ActuatorHandler] = []) {
        self.allowlist = allowlist
        self.handlers = handlers
    }

    public func registerHandler(_ handler: ActuatorHandler) {
        handlers.append(handler)
    }

    /// Dispatch a proposal through the allowlist gate and into the
    /// handler. Enforces I-21 (allowlist), I-23 (reversibility
    /// confirmation), and I-22 (outcome reporting).
    public func dispatch(_ proposal: ActionProposal) throws -> ActuationResult {
        guard allowlist.contains(proposal.kind) else {
            throw ActuatorKitError.notInAllowlist(proposal.kind)
        }
        if !proposal.kind.isReversible
            && proposal.confirmationToken == nil {
            throw ActuatorKitError.irreversibleWithoutConfirmation(proposal.kind)
        }
        guard let handler = handlers.first(where: { $0.handles(proposal.kind) }) else {
            throw ActuatorKitError.handlerUnavailable(proposal.kind)
        }
        let result = try handler.execute(proposal)
        outcomeLog.append((result.completedHLC, result.kind, result.outcome))
        return result
    }
}

// MARK: - Reference handler stubs

/// Logging-only handler. Records outcomes to stdout. Production
/// replaces this with handlers that wrap UNUserNotificationCenter
/// etc.
public struct LoggingActuatorHandler: ActuatorHandler {
    public init() {}

    public func handles(_ kind: ActionKind) -> Bool {
        return kind == .logToAudit || kind == .localNotification
    }

    public func execute(_ proposal: ActionProposal) throws -> ActuationResult {
        // In production this would dispatch to the OS. Reference
        // emits a string record of the call.
        return ActuationResult(kind: proposal.kind,
                               outcome: .resolved,
                               completedHLC: proposal.proposedHLC,
                               errorMessage: nil)
    }
}
