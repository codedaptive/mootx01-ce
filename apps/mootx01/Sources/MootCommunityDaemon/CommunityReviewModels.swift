// CommunityReviewModels.swift
//
// Contract model types for the six review-family endpoints (Wave B1: CORE-05).
//
// Every type here is byte-shape-exact from contracts/community/1.1/contract.json.
// No field is added, removed, or renamed. JSON encoding uses camelCase field names
// exactly as the contract defines them.
//
// Wire discriminator field is "status" for ReviewMode and "state" for
// ReviewCompletionStatus; all others use "outcome".
//
// JSON encoding helpers follow the same mcpStructuredResult pattern as
// CommunityCaptureModels — a "content" text frame + "structuredContent" typed
// object, both carrying identical data.

import Foundation
import AriaMCP

// MARK: - ReviewKind

/// The three review session kinds defined by the contract.
///
/// Wire values are lowercase strings: "morning", "endOfDay", "weekly".
public enum ReviewKind: String, Sendable, Codable, CaseIterable {
    case morning    = "morning"
    case endOfDay   = "endOfDay"
    case weekly     = "weekly"
}

// MARK: - ReviewCompletionReceipt

/// Durable proof of session completion returned by review_complete.
///
/// sessionID must equal the request sessionID (round-trip invariant checked by tests).
/// summary is a nonempty human-readable description of what was completed.
public struct ReviewCompletionReceipt: Sendable, Equatable, Codable {
    /// The session that was completed. Equal to the request sessionID.
    public let sessionID: UUID
    /// ISO8601 timestamp of when the session was completed.
    public let completedAt: Date
    /// Non-empty summary of the completed session.
    public let summary: String

    public init(sessionID: UUID, completedAt: Date, summary: String) {
        self.sessionID = sessionID
        self.completedAt = completedAt
        self.summary = summary
    }
}

// MARK: - ReviewMode (discriminated union on "status")

/// Per-kind status for the dashboard response.
///
/// Discriminator: "status" (contract spec ReviewMode.discriminator).
/// Common field: "kind" (ReviewKind) — present on every variant.
public enum ReviewMode: Sendable, Equatable {
    /// The review is available but not yet due.
    case available(kind: ReviewKind)
    /// The review is due (should be performed soon).
    case due(kind: ReviewKind)
    /// A session is in progress; carries the session UUID.
    case inProgress(kind: ReviewKind, sessionID: UUID)
    /// The review was completed; carries the completion receipt.
    case completed(kind: ReviewKind, receipt: ReviewCompletionReceipt)
    /// Generation is blocked by a reason code.
    case blocked(kind: ReviewKind, reason: String)

    /// The review kind for this mode entry.
    var kind: ReviewKind {
        switch self {
        case .available(let k): return k
        case .due(let k): return k
        case .inProgress(let k, _): return k
        case .completed(let k, _): return k
        case .blocked(let k, _): return k
        }
    }
}

// MARK: - ReviewDashboard

/// Response for moot_community_review_dashboard.
///
/// Contains exactly one ReviewMode per ReviewKind (three modes total).
/// The order is: morning, endOfDay, weekly (matching ReviewKind.allCases).
public struct ReviewDashboard: Sendable, Equatable {
    /// One mode per review kind, in canonical order: morning, endOfDay, weekly.
    public let modes: [ReviewMode]

    public init(modes: [ReviewMode]) {
        self.modes = modes
    }
}

// MARK: - ReviewItem

/// A single content item in a review section.
///
/// Each item corresponds to one Drawer from the estate. The id is derived
/// deterministically from the drawer id. subject comes from the drawer's
/// subject field (or content preview). detail provides additional context.
public struct ReviewItem: Sendable, Equatable, Codable {
    /// Deterministic UUID derived from the source drawer id and session id.
    public let id: UUID
    /// Non-empty display subject for the item.
    public let subject: String
    /// Optional additional detail (may be empty string per contract).
    public let detail: String

    public init(id: UUID, subject: String, detail: String) {
        self.id = id
        self.subject = subject
        self.detail = detail
    }
}

// MARK: - ReviewSection

/// A named group of review items within a session.
///
/// Section IDs are derived deterministically from the session id + section title.
/// Item ordering within a section is deterministic (sorted by drawer filedAt asc,
/// then by drawer id for equal timestamps).
public struct ReviewSection: Sendable, Equatable, Codable {
    /// Deterministic UUID derived from session id + title.
    public let id: UUID
    /// Non-empty section title.
    public let title: String
    /// Items in this section, deterministically ordered.
    public let items: [ReviewItem]

    public init(id: UUID, title: String, items: [ReviewItem]) {
        self.id = id
        self.title = title
        self.items = items
    }
}

// MARK: - ReviewAction

/// A proposed action the caller may apply or reverse during a review session.
///
/// Actions have stable identities: the id is derived deterministically from
/// the session id + the drawer id the action targets. This means the same
/// drawer in the same session always produces the same action id.
///
/// reversalAvailable is dynamic — it is true only when the action has been
/// applied (in durable state) and not yet reversed. At initial session
/// generation time it is false for new actions.
public struct ReviewAction: Sendable, Equatable, Codable {
    /// Stable UUID derived from session id + target drawer id.
    public let id: UUID
    /// Non-empty description of what applying this action will do.
    public let expectedEffect: String
    /// True if this action type supports reversal in principle.
    public let isReversible: Bool
    /// True only when the action has been applied and can currently be reversed.
    /// Updated dynamically from durable state when the session is retrieved.
    public let reversalAvailable: Bool

    public init(id: UUID, expectedEffect: String, isReversible: Bool, reversalAvailable: Bool) {
        self.id = id
        self.expectedEffect = expectedEffect
        self.isReversible = isReversible
        self.reversalAvailable = reversalAvailable
    }
}

// MARK: - DuplicateResolutionChoice

/// A daemon-owned resolution choice for a duplicate group.
///
/// Only choices the daemon can execute are listed here — choices requiring
/// external coordination (e.g., "ask the user") are not included. The id
/// is derived deterministically from the group id + description.
public struct DuplicateResolutionChoice: Sendable, Equatable, Codable {
    /// Deterministic UUID derived from group id + description.
    public let id: UUID
    /// Non-empty description of what this choice does.
    public let description: String

    public init(id: UUID, description: String) {
        self.id = id
        self.description = description
    }
}

// MARK: - DuplicateGroup

/// A set of drawers identified as potential duplicates.
///
/// reason explains why these records are considered related (same subject,
/// identical content hash, etc.). recordIDs lists the drawer ids that were
/// identified as duplicates. choices lists only valid daemon-owned
/// resolution options.
public struct DuplicateGroup: Sendable, Equatable, Codable {
    /// Deterministic UUID derived from session id + sorted recordIDs.
    public let id: UUID
    /// Non-empty explanation of why these records are related.
    public let reason: String
    /// Drawer ids that are considered duplicates (two or more).
    public let recordIDs: [UUID]
    /// Daemon-owned resolution choices for this group.
    public let choices: [DuplicateResolutionChoice]

    public init(id: UUID, reason: String, recordIDs: [UUID], choices: [DuplicateResolutionChoice]) {
        self.id = id
        self.reason = reason
        self.recordIDs = recordIDs
        self.choices = choices
    }
}

// MARK: - ReviewCompletionStatus (discriminated union on "state")

/// Current completion status of a review session.
///
/// Discriminator: "state".
public enum ReviewCompletionStatus: Sendable, Equatable {
    /// Session exists but review has not started (no actions applied yet).
    case notStarted
    /// Review is underway (at least one action applied or session retrieved).
    case inProgress
    /// Review is complete; carries the durable receipt.
    case completed(receipt: ReviewCompletionReceipt)
}

// MARK: - ReviewSession

/// A complete review session including sections, actions, and duplicate groups.
///
/// The session is generated deterministically from the estate state and now.
/// Equivalent estate input + equivalent now → byte-identical canonical session.
///
/// sourceEstateState is a fingerprint of the active drawers at session generation
/// time. It is used for staleness detection: if the estate changes after generation,
/// applying actions returns staleSession.
public struct ReviewSession: Sendable, Equatable {
    /// Deterministic UUID derived from kind + generatedAt + sourceEstateState.
    public let id: UUID
    /// The review kind that produced this session.
    public let kind: ReviewKind
    /// When this session was generated (the "now" value passed to the engine).
    public let generatedAt: Date
    /// Fingerprint of the active estate drawers at generation time.
    /// Format: "sha256:{16hexbytes}:{activeDrawerCount}". Used for staleness detection.
    public let sourceEstateState: String
    /// Review sections, each containing ordered items.
    public let sections: [ReviewSection]
    /// Proposed actions the caller may apply or reverse.
    public let actions: [ReviewAction]
    /// Groups of drawers identified as potential duplicates.
    public let duplicateGroups: [DuplicateGroup]
    /// Current completion status (updated dynamically from durable state).
    public let completionStatus: ReviewCompletionStatus

    public init(
        id: UUID,
        kind: ReviewKind,
        generatedAt: Date,
        sourceEstateState: String,
        sections: [ReviewSection],
        actions: [ReviewAction],
        duplicateGroups: [DuplicateGroup],
        completionStatus: ReviewCompletionStatus
    ) {
        self.id = id
        self.kind = kind
        self.generatedAt = generatedAt
        self.sourceEstateState = sourceEstateState
        self.sections = sections
        self.actions = actions
        self.duplicateGroups = duplicateGroups
        self.completionStatus = completionStatus
    }
}

// MARK: - ReviewSessionOutcome (discriminated union on "outcome")

/// Result of moot_community_review_session.
public enum ReviewSessionOutcome: Sendable {
    /// A session was generated or retrieved successfully.
    case session(ReviewSession)
    /// Session generation is blocked by a reason code (e.g., daemon not ready).
    case blocked(reason: String)
}

// MARK: - ReviewActionOutcome (discriminated union on "outcome")

/// Result of review_apply, review_reverse, and review_resolve_duplicate.
public enum ReviewActionOutcome: Sendable {
    /// The action was applied (or reversed, or duplicate resolved) successfully.
    case applied
    /// This exact action was already applied (idempotent retry).
    case alreadyApplied
    /// The session is stale — the estate changed since the session was generated.
    case staleSession
    /// The action conflicts with the current estate or session state.
    case conflict(reason: String)
    /// The action was refused (e.g., reversal not available, action not found).
    case refused(reason: String)
    /// An unexpected internal failure prevented the action.
    case failed(reason: String)
}

// MARK: - ReviewCompleteOutcome (discriminated union on "outcome")

/// Result of moot_community_review_complete.
public enum ReviewCompleteOutcome: Sendable {
    /// Session was completed; carries the durable receipt.
    case completed(receipt: ReviewCompletionReceipt)
    /// Completion was refused (session not found, already completed, etc.).
    case refused(reason: String)
    /// An unexpected internal failure prevented completion.
    case failed(reason: String)
}

// MARK: - JSON encoding helpers

extension ReviewCompletionReceipt {
    /// Encode to a JSONValue object (not the MCP envelope — used as a nested value).
    func toJSONValue() -> JSONValue {
        .object([
            "sessionID": .string(sessionID.uuidString.lowercased()),
            "completedAt": .string(iso8601Encode(completedAt)),
            "summary": .string(summary),
        ])
    }
}

extension ReviewMode {
    func toJSONValue() -> JSONValue {
        switch self {
        case .available(let k):
            return .object([
                "kind": .string(k.rawValue),
                "status": .string("available"),
            ])
        case .due(let k):
            return .object([
                "kind": .string(k.rawValue),
                "status": .string("due"),
            ])
        case .inProgress(let k, let sessionID):
            return .object([
                "kind": .string(k.rawValue),
                "status": .string("inProgress"),
                "sessionID": .string(sessionID.uuidString.lowercased()),
            ])
        case .completed(let k, let receipt):
            return .object([
                "kind": .string(k.rawValue),
                "status": .string("completed"),
                "receipt": receipt.toJSONValue(),
            ])
        case .blocked(let k, let reason):
            return .object([
                "kind": .string(k.rawValue),
                "status": .string("blocked"),
                "reason": .string(reason),
            ])
        }
    }
}

extension ReviewDashboard {
    /// Encode to the MCP structured-result envelope.
    func toJSONValue() -> JSONValue {
        let modesArray = JSONValue.array(modes.map { $0.toJSONValue() })
        return reviewMCPResult(["modes": modesArray])
    }
}

extension ReviewItem {
    func toJSONValue() -> JSONValue {
        .object([
            "id": .string(id.uuidString.lowercased()),
            "subject": .string(subject),
            "detail": .string(detail),
        ])
    }
}

extension ReviewSection {
    func toJSONValue() -> JSONValue {
        .object([
            "id": .string(id.uuidString.lowercased()),
            "title": .string(title),
            "items": .array(items.map { $0.toJSONValue() }),
        ])
    }
}

extension ReviewAction {
    func toJSONValue() -> JSONValue {
        .object([
            "id": .string(id.uuidString.lowercased()),
            "expectedEffect": .string(expectedEffect),
            "isReversible": .bool(isReversible),
            "reversalAvailable": .bool(reversalAvailable),
        ])
    }
}

extension DuplicateResolutionChoice {
    func toJSONValue() -> JSONValue {
        .object([
            "id": .string(id.uuidString.lowercased()),
            "description": .string(description),
        ])
    }
}

extension DuplicateGroup {
    func toJSONValue() -> JSONValue {
        .object([
            "id": .string(id.uuidString.lowercased()),
            "reason": .string(reason),
            "recordIDs": .array(recordIDs.map { .string($0.uuidString.lowercased()) }),
            "choices": .array(choices.map { $0.toJSONValue() }),
        ])
    }
}

extension ReviewCompletionStatus {
    func toJSONValue() -> JSONValue {
        switch self {
        case .notStarted:
            return .object(["state": .string("notStarted")])
        case .inProgress:
            return .object(["state": .string("inProgress")])
        case .completed(let receipt):
            return .object([
                "state": .string("completed"),
                "receipt": receipt.toJSONValue(),
            ])
        }
    }
}

extension ReviewSession {
    func toJSONValue() -> JSONValue {
        .object([
            "id": .string(id.uuidString.lowercased()),
            "kind": .string(kind.rawValue),
            "generatedAt": .string(iso8601Encode(generatedAt)),
            "sourceEstateState": .string(sourceEstateState),
            "sections": .array(sections.map { $0.toJSONValue() }),
            "actions": .array(actions.map { $0.toJSONValue() }),
            "duplicateGroups": .array(duplicateGroups.map { $0.toJSONValue() }),
            "completionStatus": completionStatus.toJSONValue(),
        ])
    }
}

extension ReviewSessionOutcome {
    /// Encode to the MCP structured-result envelope.
    func toJSONValue() -> JSONValue {
        switch self {
        case .session(let session):
            return reviewMCPResult(["outcome": .string("session"), "session": session.toJSONValue()])
        case .blocked(let reason):
            return reviewMCPResult(["outcome": .string("blocked"), "reason": .string(reason)])
        }
    }
}

extension ReviewActionOutcome {
    /// Encode to the MCP structured-result envelope.
    func toJSONValue() -> JSONValue {
        switch self {
        case .applied:
            return reviewMCPResult(["outcome": .string("applied")])
        case .alreadyApplied:
            return reviewMCPResult(["outcome": .string("alreadyApplied")])
        case .staleSession:
            return reviewMCPResult(["outcome": .string("staleSession")])
        case .conflict(let reason):
            return reviewMCPResult(["outcome": .string("conflict"), "reason": .string(reason)])
        case .refused(let reason):
            return reviewMCPResult(["outcome": .string("refused"), "reason": .string(reason)])
        case .failed(let reason):
            return reviewMCPResult(["outcome": .string("failed"), "reason": .string(reason)])
        }
    }
}

extension ReviewCompleteOutcome {
    /// Encode to the MCP structured-result envelope.
    func toJSONValue() -> JSONValue {
        switch self {
        case .completed(let receipt):
            return reviewMCPResult([
                "outcome": .string("completed"),
                "receipt": receipt.toJSONValue(),
            ])
        case .refused(let reason):
            return reviewMCPResult(["outcome": .string("refused"), "reason": .string(reason)])
        case .failed(let reason):
            return reviewMCPResult(["outcome": .string("failed"), "reason": .string(reason)])
        }
    }
}

// MARK: - Private MCP encoding helpers (review-family)

/// Wrap a typed result dictionary in the MCP tools/call structured-result shape.
///
/// Mirrors the `mcpStructuredResult` helper in CommunityCaptureModels, scoped
/// to the review family so the two families don't share a private function.
func reviewMCPResult(_ dict: [String: JSONValue]) -> JSONValue {
    let anyDict = reviewJSONAny(.object(dict))
    guard let data = try? JSONSerialization.data(
        withJSONObject: anyDict as Any,
        options: [.sortedKeys]
    ) else {
        // Unreachable: the value tree only contains strings, booleans, arrays, objects.
        return .object([:])
    }
    let text = String(decoding: data, as: UTF8.self)
    return .object([
        "content": .array([
            .object(["type": .string("text"), "text": .string(text)])
        ]),
        "structuredContent": .object(dict),
    ])
}

/// Recursively convert a JSONValue tree to Any for JSONSerialization.
private func reviewJSONAny(_ value: JSONValue) -> Any {
    switch value {
    case .null:             return NSNull()
    case .bool(let b):      return b
    case .integer(let i):   return i
    case .double(let d):    return d
    case .string(let s):    return s
    case .array(let a):     return a.map { reviewJSONAny($0) }
    case .object(let o):
        var dict: [String: Any] = [:]
        for (k, v) in o { dict[k] = reviewJSONAny(v) }
        return dict
    }
}

/// ISO8601 encoder shared by all review types.
///
/// Uses fractional-seconds format to match the contract's "date-time" type.
/// Stable output for the same Date input — does not depend on locale or TZ.
func iso8601Encode(_ date: Date) -> String {
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fmt.string(from: date)
}
