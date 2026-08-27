// CommunityObsidianModels.swift
//
// Contract model types for the six obsidian-family endpoints (Wave C1: CORE-06).
//
// Every type here is byte-shape-exact from contracts/community/1.1/contract.json.
// No field is added, removed, or renamed. JSON encoding uses camelCase field names
// exactly as the contract defines them.
//
// STATUS INVARIANTS (from contract.json):
//   • checkpointAt and recordCount are common fields on ObsidianStatus.
//     They are BOTH present or BOTH absent — never one without the other.
//   • pendingCount and totalCount appear together; pendingCount <= totalCount.
//   • Error codes are from the contract's reasonCodes list — no ad-hoc strings.
//
// The mcpStructuredResult / jsonAnyFromValue helpers from CommunityCaptureModels
// live in that file (private file scope). ObsidianModels uses its own copies of
// those helpers so there is no cross-file private access.

import Foundation
import AriaMCP

// MARK: - ObsidianStatus (discriminated union on "state")

/// Status of the Obsidian continuous-sync service.
///
/// Discriminator: "state" (contract spec ObsidianStatus).
/// Common fields: checkpointAt? and recordCount? — BOTH present or BOTH absent.
public enum ObsidianStatus: Sendable {
    // Running variants
    case starting
    case scanning
    case synchronizing(pendingCount: Int?, totalCount: Int?,
                       checkpointAt: Date?, recordCount: Int?)
    case idle(checkpointAt: Date?, recordCount: Int?)
    case waiting(until: Date?, checkpointAt: Date?, recordCount: Int?)
    // Stopped variants
    case paused(checkpointAt: Date?, recordCount: Int?)
    // Error variants (always carry reason)
    case interrupted(reason: String, retryable: Bool,
                     checkpointAt: Date?, recordCount: Int?)
    case blocked(reason: String, checkpointAt: Date?, recordCount: Int?)
    case failed(reason: String, retryable: Bool,
                checkpointAt: Date?, recordCount: Int?)
}

// MARK: - ObsidianAuthorization (discriminated union on "state")

/// Authorization state for the Obsidian vault.
///
/// Discriminator: "state" (contract spec ObsidianAuthorization).
public enum ObsidianAuthorization: Sendable {
    /// No vault has been selected. The user must call obsidian_select_vault first.
    case missing
    /// Vault is selected and authorization is current.
    case valid(vaultURL: String, displayName: String)
    /// Vault was previously authorized but authorization needs renewal.
    case needsRenewal(vaultURL: String, displayName: String, reason: String)
}

// MARK: - VaultSelectionOutcome (discriminated union on "outcome")

/// Result of moot_community_obsidian_select_vault.
///
/// Discriminator: "outcome" (contract spec VaultSelectionOutcome).
public enum VaultSelectionOutcome: Sendable {
    /// Vault selected successfully. vaultURL is the resolved file URL.
    case selected(vaultURL: String, displayName: String)
    /// Vault could not be selected (bookmark invalid, not a directory, etc.).
    case denied(reason: String)
}

// MARK: - ObsidianEnableOutcome (discriminated union on "outcome")

/// Result of moot_community_obsidian_enable.
///
/// Discriminator: "outcome" (contract spec ObsidianEnableOutcome).
public enum ObsidianEnableOutcome: Sendable {
    /// Service was successfully enabled.
    case enabled
    /// Enable was refused (e.g. no authorization).
    case refused(reason: String)
    /// Enable failed with an unexpected error.
    case failed(reason: String)
}

// MARK: - ObsidianDisableOutcome (discriminated union on "outcome")

/// Result of moot_community_obsidian_disable.
///
/// Discriminator: "outcome" (contract spec ObsidianDisableOutcome).
/// disabledOnly: vault content preserved (the policy per disable-preserves-content).
/// disabledAndRemoved: vault content removed (reserved for explicit remove path).
public enum ObsidianDisableOutcome: Sendable {
    /// Service disabled; vault content preserved on disk.
    case disabledOnly
    /// Service disabled; vault content removed from disk.
    case disabledAndRemoved
    /// Disable failed with an unexpected error.
    case failed(reason: String)
}

// MARK: - ObsidianRetryOutcome (discriminated union on "outcome")

/// Result of moot_community_obsidian_retry.
///
/// Discriminator: "outcome" (contract spec ObsidianRetryOutcome).
public enum ObsidianRetryOutcome: Sendable {
    /// Service restarted successfully after a retryable interruption.
    case restarted
    /// Retry refused (e.g. the prior state was not retryable).
    case refused(reason: String)
    /// Retry failed with an unexpected error.
    case failed(reason: String)
}

// MARK: - JSON encoding: ObsidianStatus

extension ObsidianStatus {
    /// Encode to the MCP structured-result shape.
    ///
    /// Status invariants enforced here:
    ///   - checkpointAt and recordCount are encoded together or not at all.
    ///   - pendingCount and totalCount are encoded together or not at all.
    func toJSONValue() -> JSONValue {
        var dict: [String: JSONValue] = [:]
        switch self {
        case .starting:
            dict["state"] = .string("starting")
            // No checkpoint fields (starting = fresh, no prior sync).

        case .scanning:
            dict["state"] = .string("scanning")

        case let .synchronizing(pendingCount, totalCount, checkpointAt, recordCount):
            dict["state"] = .string("synchronizing")
            // pendingCount and totalCount appear together (both or neither).
            if let p = pendingCount, let t = totalCount {
                // Invariant: pendingCount <= totalCount (enforced by coordinator).
                dict["pendingCount"] = .integer(Int64(p))
                dict["totalCount"] = .integer(Int64(t))
            }
            // Common fields: both present or both absent.
            encodeCheckpoint(into: &dict, checkpointAt: checkpointAt, recordCount: recordCount)

        case let .idle(checkpointAt, recordCount):
            dict["state"] = .string("idle")
            encodeCheckpoint(into: &dict, checkpointAt: checkpointAt, recordCount: recordCount)

        case let .waiting(until, checkpointAt, recordCount):
            dict["state"] = .string("waiting")
            if let u = until { dict["until"] = .string(iso8601Encode(u)) }
            encodeCheckpoint(into: &dict, checkpointAt: checkpointAt, recordCount: recordCount)

        case let .paused(checkpointAt, recordCount):
            dict["state"] = .string("paused")
            encodeCheckpoint(into: &dict, checkpointAt: checkpointAt, recordCount: recordCount)

        case let .interrupted(reason, retryable, checkpointAt, recordCount):
            dict["state"] = .string("interrupted")
            dict["reason"] = .string(reason)
            dict["retryable"] = .bool(retryable)
            encodeCheckpoint(into: &dict, checkpointAt: checkpointAt, recordCount: recordCount)

        case let .blocked(reason, checkpointAt, recordCount):
            dict["state"] = .string("blocked")
            dict["reason"] = .string(reason)
            encodeCheckpoint(into: &dict, checkpointAt: checkpointAt, recordCount: recordCount)

        case let .failed(reason, retryable, checkpointAt, recordCount):
            dict["state"] = .string("failed")
            dict["reason"] = .string(reason)
            dict["retryable"] = .bool(retryable)
            encodeCheckpoint(into: &dict, checkpointAt: checkpointAt, recordCount: recordCount)
        }
        return obsidianMcpResult(dict)
    }

    /// Encode checkpointAt and recordCount together — both or neither.
    ///
    /// Contract invariant: these two common fields are BOTH present or BOTH absent.
    /// Encoding one without the other is a contract violation. When checkpointAt
    /// is non-nil but recordCount is nil (or vice versa), both are omitted and
    /// the coordinator logs a warning — the invariant is enforced here, not just
    /// documented.
    private func encodeCheckpoint(
        into dict: inout [String: JSONValue],
        checkpointAt: Date?,
        recordCount: Int?
    ) {
        // Invariant: both present or both absent.
        guard let ca = checkpointAt, let rc = recordCount else { return }
        dict["checkpointAt"] = .string(iso8601Encode(ca))
        dict["recordCount"] = .integer(Int64(rc))
    }
}

// MARK: - JSON encoding: ObsidianAuthorization

extension ObsidianAuthorization {
    func toJSONValue() -> JSONValue {
        var dict: [String: JSONValue] = [:]
        switch self {
        case .missing:
            dict["state"] = .string("missing")
        case let .valid(vaultURL, displayName):
            dict["state"] = .string("valid")
            dict["vaultURL"] = .string(vaultURL)
            dict["displayName"] = .string(displayName)
        case let .needsRenewal(vaultURL, displayName, reason):
            dict["state"] = .string("needsRenewal")
            dict["vaultURL"] = .string(vaultURL)
            dict["displayName"] = .string(displayName)
            dict["reason"] = .string(reason)
        }
        return obsidianMcpResult(dict)
    }
}

// MARK: - JSON encoding: VaultSelectionOutcome

extension VaultSelectionOutcome {
    func toJSONValue() -> JSONValue {
        var dict: [String: JSONValue] = [:]
        switch self {
        case let .selected(vaultURL, displayName):
            dict["outcome"] = .string("selected")
            dict["vaultURL"] = .string(vaultURL)
            dict["displayName"] = .string(displayName)
        case let .denied(reason):
            dict["outcome"] = .string("denied")
            dict["reason"] = .string(reason)
        }
        return obsidianMcpResult(dict)
    }
}

// MARK: - JSON encoding: ObsidianEnableOutcome

extension ObsidianEnableOutcome {
    func toJSONValue() -> JSONValue {
        var dict: [String: JSONValue] = [:]
        switch self {
        case .enabled:
            dict["outcome"] = .string("enabled")
        case let .refused(reason):
            dict["outcome"] = .string("refused")
            dict["reason"] = .string(reason)
        case let .failed(reason):
            dict["outcome"] = .string("failed")
            dict["reason"] = .string(reason)
        }
        return obsidianMcpResult(dict)
    }
}

// MARK: - JSON encoding: ObsidianDisableOutcome

extension ObsidianDisableOutcome {
    func toJSONValue() -> JSONValue {
        var dict: [String: JSONValue] = [:]
        switch self {
        case .disabledOnly:
            dict["outcome"] = .string("disabledOnly")
        case .disabledAndRemoved:
            dict["outcome"] = .string("disabledAndRemoved")
        case let .failed(reason):
            dict["outcome"] = .string("failed")
            dict["reason"] = .string(reason)
        }
        return obsidianMcpResult(dict)
    }
}

// MARK: - JSON encoding: ObsidianRetryOutcome

extension ObsidianRetryOutcome {
    func toJSONValue() -> JSONValue {
        var dict: [String: JSONValue] = [:]
        switch self {
        case .restarted:
            dict["outcome"] = .string("restarted")
        case let .refused(reason):
            dict["outcome"] = .string("refused")
            dict["reason"] = .string(reason)
        case let .failed(reason):
            dict["outcome"] = .string("failed")
            dict["reason"] = .string(reason)
        }
        return obsidianMcpResult(dict)
    }
}

// MARK: - Private MCP encoding helpers (file-scope, mirrors CommunityCaptureModels pattern)

/// Wrap a typed result dictionary in the MCP tools/call structured-result shape.
///
/// Both the text frame and structuredContent carry the same data — clients
/// that parse either surface receive identical values.
func obsidianMcpResult(_ dict: [String: JSONValue]) -> JSONValue {
    let anyDict = obsidianJsonAny(.object(dict))
    guard let data = try? JSONSerialization.data(
        withJSONObject: anyDict as Any,
        options: [.sortedKeys]
    ) else {
        // Unreachable: all values are strings, booleans, integers — no types
        // JSONSerialization cannot handle.
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
private func obsidianJsonAny(_ value: JSONValue) -> Any {
    switch value {
    case .null:             return NSNull()
    case .bool(let b):      return b
    case .integer(let i):   return i
    case .double(let d):    return d
    case .string(let s):    return s
    case .array(let a):     return a.map { obsidianJsonAny($0) }
    case .object(let o):
        var dict: [String: Any] = [:]
        for (k, v) in o { dict[k] = obsidianJsonAny(v) }
        return dict
    }
}

// iso8601Encode is declared in CommunityReviewModels.swift (module-level, same module).
// No redeclaration needed here.
