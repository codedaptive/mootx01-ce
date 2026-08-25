// CommunityTransferModels.swift
//
// Contract model types for the nine transfer-family endpoints (Wave D1: CORE-07).
//
// Every type is byte-shape-exact from contracts/community/1.1/contract.json.
// No field is added, removed, or renamed. JSON discriminators match contract
// field names exactly (e.g. "state", "outcome", "stage").
//
// TRANSFER PLAN INVARIANT (from contract.json):
//   estimatedTransferCount + policyExclusionCount <= candidateCount
//
// CANCELLATION STAGE VARIANTS:
//   beforeCommit       — cancelled before any write; zero committed records
//   duringCommit{counts} — cancelled mid-write; counts shows what committed
//   afterCommit{counts}  — completed writes, then cancelled; all counts show

import Foundation
import AriaMCP

// MARK: - TransferFormat

/// Wire format description. Discriminator: none — pure record.
///
/// Contract: { name: nonempty-string, recognized: boolean }
public struct TransferFormat: Sendable {
    public let name: String
    public let recognized: Bool

    public init(name: String, recognized: Bool) {
        self.name = name
        self.recognized = recognized
    }
}

extension TransferFormat {
    func toJSONValue() -> JSONValue {
        .object([
            "name": .string(name),
            "recognized": .bool(recognized),
        ])
    }
}

// MARK: - TransferCounts

/// Terminal-state counts. Discriminator: none — pure record.
///
/// Contract: { transferred, skipped, conflicted, excluded, failed: nonneg-int }
public struct TransferCounts: Sendable, Equatable {
    public var transferred: Int
    public var skipped: Int
    public var conflicted: Int
    public var excluded: Int
    public var failed: Int

    public init(transferred: Int = 0, skipped: Int = 0,
                conflicted: Int = 0, excluded: Int = 0, failed: Int = 0) {
        self.transferred = transferred
        self.skipped = skipped
        self.conflicted = conflicted
        self.excluded = excluded
        self.failed = failed
    }
}

extension TransferCounts {
    func toJSONValue() -> JSONValue {
        .object([
            "transferred": .integer(Int64(transferred)),
            "skipped":     .integer(Int64(skipped)),
            "conflicted":  .integer(Int64(conflicted)),
            "excluded":    .integer(Int64(excluded)),
            "failed":      .integer(Int64(failed)),
        ])
    }
}

// MARK: - TransferPlan

/// Planning result. Discriminator: none — pure record.
///
/// Contract: TransferPlan fields.
/// Invariant: estimatedTransferCount + policyExclusionCount <= candidateCount.
public struct TransferPlan: Sendable {
    public let format: TransferFormat
    public let candidateCount: Int
    public let conflictCount: Int
    public let invalidCount: Int
    public let policyExclusionCount: Int
    public let estimatedTransferCount: Int
    public let executionPermitted: Bool
    /// Opaque token that binds this plan to the estate state at plan time.
    /// Encode format: "<uuid>:<fingerprint>" — the UUID part is the sidecar
    /// key; the fingerprint is the SHA-256 hex of sorted occupied lineage IDs
    /// at plan time, used to detect stale plans on execute.
    public let planToken: String
}

extension TransferPlan {
    func toJSONValue() -> JSONValue {
        .object([
            "format": format.toJSONValue(),
            "candidateCount":        .integer(Int64(candidateCount)),
            "conflictCount":         .integer(Int64(conflictCount)),
            "invalidCount":          .integer(Int64(invalidCount)),
            "policyExclusionCount":  .integer(Int64(policyExclusionCount)),
            "estimatedTransferCount":.integer(Int64(estimatedTransferCount)),
            "executionPermitted":    .bool(executionPermitted),
            "planToken":             .string(planToken),
        ])
    }
}

// MARK: - CancellationStage (discriminated union on "stage")

/// Contract: CancellationStage — discriminator "stage".
///
/// Variants:
///   beforeCommit — no extra fields.
///   duringCommit{counts: TransferCounts}
///   afterCommit{counts: TransferCounts}
public enum CancellationStage: Sendable, Equatable {
    case beforeCommit
    case duringCommit(counts: TransferCounts)
    case afterCommit(counts: TransferCounts)
}

extension CancellationStage {
    func toJSONValue() -> JSONValue {
        switch self {
        case .beforeCommit:
            return .object(["stage": .string("beforeCommit")])
        case .duringCommit(let c):
            return .object([
                "stage":  .string("duringCommit"),
                "counts": c.toJSONValue(),
            ])
        case .afterCommit(let c):
            return .object([
                "stage":  .string("afterCommit"),
                "counts": c.toJSONValue(),
            ])
        }
    }
}

// MARK: - TransferJobState (discriminated union on "state")

/// Contract: TransferJobState — discriminator "state".
///
/// Variants (from contract.json):
///   queued
///   running{processed?: nonneg-int, total?: nonneg-int}
///   waiting{reason: reason-code}
///   completed{counts: TransferCounts, receipt: nonempty-string}
///   failed{reason: reason-code, partial?: TransferCounts}
///   cancelled{stage: CancellationStage}
///
/// Invariant: when running and both processed and total are present, processed <= total.
public enum TransferJobState: Sendable, Equatable {
    case queued
    case running(processed: Int?, total: Int?)
    case waiting(reason: String)
    case completed(counts: TransferCounts, receipt: String)
    case failed(reason: String, partial: TransferCounts?)
    case cancelled(stage: CancellationStage)
}

extension TransferJobState {
    func toJSONValue() -> JSONValue {
        switch self {
        case .queued:
            return .object(["state": .string("queued")])
        case .running(let processed, let total):
            var dict: [String: JSONValue] = ["state": .string("running")]
            if let p = processed { dict["processed"] = .integer(Int64(p)) }
            if let t = total     { dict["total"]     = .integer(Int64(t)) }
            return .object(dict)
        case .waiting(let reason):
            return .object(["state": .string("waiting"), "reason": .string(reason)])
        case .completed(let counts, let receipt):
            return .object([
                "state":   .string("completed"),
                "counts":  counts.toJSONValue(),
                "receipt": .string(receipt),
            ])
        case .failed(let reason, let partial):
            var dict: [String: JSONValue] = [
                "state":  .string("failed"),
                "reason": .string(reason),
            ]
            if let p = partial { dict["partial"] = p.toJSONValue() }
            return .object(dict)
        case .cancelled(let stage):
            return .object([
                "state": .string("cancelled"),
                "stage": stage.toJSONValue(),
            ])
        }
    }
}

// MARK: - TransferPlanOutcome (discriminated union on "outcome")

/// Contract: TransferPlanOutcome.
/// Variants: planned{plan: TransferPlan} | denied{reason: reason-code} | failed{reason: reason-code}
public enum TransferPlanOutcome: Sendable {
    case planned(plan: TransferPlan)
    /// Denied at the plan stage: caller-supplied input is invalid or policy forbids it.
    /// Distinct from `failed` (unexpected server error) — `denied` means the request
    /// is well-understood and rejected by policy or validation.
    case denied(reason: String)
    case failed(reason: String)
}

extension TransferPlanOutcome {
    func toJSONValue() -> JSONValue {
        switch self {
        case .planned(let plan):
            return transferMcpResult([
                "outcome": .string("planned"),
                "plan":    plan.toJSONValue(),
            ])
        case .denied(let reason):
            return transferMcpResult([
                "outcome": .string("denied"),
                "reason":  .string(reason),
            ])
        case .failed(let reason):
            return transferMcpResult([
                "outcome": .string("failed"),
                "reason":  .string(reason),
            ])
        }
    }
}

// MARK: - SourceSelectionOutcome (discriminated union on "outcome")

/// Contract: SourceSelectionOutcome.
/// Variants: selected{format: TransferFormat} | denied{reason: reason-code}
public enum SourceSelectionOutcome: Sendable {
    case selected(format: TransferFormat)
    case denied(reason: String)
}

extension SourceSelectionOutcome {
    func toJSONValue() -> JSONValue {
        switch self {
        case .selected(let fmt):
            return transferMcpResult([
                "outcome": .string("selected"),
                "format":  fmt.toJSONValue(),
            ])
        case .denied(let reason):
            return transferMcpResult([
                "outcome": .string("denied"),
                "reason":  .string(reason),
            ])
        }
    }
}

// MARK: - ExportDestinationOutcome (discriminated union on "outcome")

/// Contract: ExportDestinationOutcome.
/// Variants: selected | denied{reason: reason-code}
public enum ExportDestinationOutcome: Sendable {
    case selected
    case denied(reason: String)
}

extension ExportDestinationOutcome {
    func toJSONValue() -> JSONValue {
        switch self {
        case .selected:
            return transferMcpResult(["outcome": .string("selected")])
        case .denied(let reason):
            return transferMcpResult([
                "outcome": .string("denied"),
                "reason":  .string(reason),
            ])
        }
    }
}

// MARK: - ExportScope

/// Contract: ExportScope — pure record.
/// { scopeToken: nonempty-string, candidateCount: nonneg-int, description: nonempty-string }
public struct ExportScope: Sendable {
    public let scopeToken: String
    public let candidateCount: Int
    public let description: String
}

extension ExportScope {
    func toJSONValue() -> JSONValue {
        .object([
            "scopeToken":     .string(scopeToken),
            "candidateCount": .integer(Int64(candidateCount)),
            "description":    .string(description),
        ])
    }
}

// MARK: - ExportScopesResult

/// Contract: ExportScopes — pure record.
/// { scopes: ExportScope[] }
public struct ExportScopesResult: Sendable {
    public let scopes: [ExportScope]
}

extension ExportScopesResult {
    func toJSONValue() -> JSONValue {
        transferMcpResult([
            "scopes": .array(scopes.map { $0.toJSONValue() }),
        ])
    }
}

// MARK: - TransferExecutionOutcome (discriminated union on "outcome")

/// Contract: TransferExecutionOutcome.
/// Variants: submitted{jobID} | denied{reason} | failed{reason}
public enum TransferExecutionOutcome: Sendable {
    case submitted(jobID: String)
    case denied(reason: String)
    case failed(reason: String)
}

extension TransferExecutionOutcome {
    func toJSONValue() -> JSONValue {
        switch self {
        case .submitted(let jobID):
            return transferMcpResult([
                "outcome": .string("submitted"),
                "jobID":   .string(jobID),
            ])
        case .denied(let reason):
            return transferMcpResult([
                "outcome": .string("denied"),
                "reason":  .string(reason),
            ])
        case .failed(let reason):
            return transferMcpResult([
                "outcome": .string("failed"),
                "reason":  .string(reason),
            ])
        }
    }
}

// MARK: - JobStatusOutcome (discriminated union on "outcome")

/// Contract: JobStatusOutcome.
/// Variants: status{jobID, jobState} | notFound | failed{reason}
///
/// Invariant: jobID in result equals jobID in request (echo invariant).
/// Invariant: when state=running, processed <= total (when both present).
public enum JobStatusOutcome: Sendable {
    case status(jobID: String, jobState: TransferJobState)
    case notFound
    case failed(reason: String)
}

extension JobStatusOutcome {
    func toJSONValue() -> JSONValue {
        switch self {
        case .status(let jobID, let jobState):
            return transferMcpResult([
                "outcome":  .string("status"),
                "jobID":    .string(jobID),
                "jobState": jobState.toJSONValue(),
            ])
        case .notFound:
            return transferMcpResult(["outcome": .string("notFound")])
        case .failed(let reason):
            return transferMcpResult([
                "outcome": .string("failed"),
                "reason":  .string(reason),
            ])
        }
    }
}

// MARK: - JobCancelOutcome (discriminated union on "outcome")

/// Contract: JobCancelOutcome.
/// Variants: cancelled{stage} | notFound | alreadyComplete | failed{reason}
public enum JobCancelOutcome: Sendable {
    case cancelled(stage: CancellationStage)
    case notFound
    case alreadyComplete
    case failed(reason: String)
}

extension JobCancelOutcome {
    func toJSONValue() -> JSONValue {
        switch self {
        case .cancelled(let stage):
            return transferMcpResult([
                "outcome": .string("cancelled"),
                "stage":   stage.toJSONValue(),
            ])
        case .notFound:
            return transferMcpResult(["outcome": .string("notFound")])
        case .alreadyComplete:
            return transferMcpResult(["outcome": .string("alreadyComplete")])
        case .failed(let reason):
            return transferMcpResult([
                "outcome": .string("failed"),
                "reason":  .string(reason),
            ])
        }
    }
}

// MARK: - Private MCP encoding helpers (file-scope)

/// Wrap a typed result dictionary in the MCP tools/call structured-result shape.
///
/// Both the text frame and structuredContent carry identical data.
/// Mirrors the obsidianMcpResult helper pattern from CommunityObsidianModels.
func transferMcpResult(_ dict: [String: JSONValue]) -> JSONValue {
    let anyDict = transferJsonAny(.object(dict))
    guard let data = try? JSONSerialization.data(
        withJSONObject: anyDict as Any,
        options: [.sortedKeys]
    ) else {
        // Unreachable: values are strings, booleans, integers, and nested
        // objects of those types — JSONSerialization cannot fail on these.
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
private func transferJsonAny(_ value: JSONValue) -> Any {
    switch value {
    case .null:            return NSNull()
    case .bool(let b):     return b
    case .integer(let i):  return Int(i)
    case .double(let d):   return d
    case .string(let s):   return s
    case .array(let a):    return a.map { transferJsonAny($0) }
    case .object(let o):
        var dict: [String: Any] = [:]
        for (k, v) in o { dict[k] = transferJsonAny(v) }
        return dict
    }
}
