// ObservationStatus.swift
//
// Per QUEUEKIT_SPEC §7. Owned by QueueKit; AgentHarness imports it
// from here. Raw string values match the signal file `status` field
// exactly (spec §6).

import Foundation

public enum ObservationStatus: String, Sendable, Codable {
    case running          = "running"
    case done             = "done"
    case doneWithConcerns = "done_with_concerns"
    case needsContext     = "needs_context"
    case blocked          = "blocked"

    public var isTerminal: Bool {
        switch self {
        case .running: return false
        case .done, .doneWithConcerns, .needsContext, .blocked: return true
        }
    }
}
