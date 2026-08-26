// CommunityCaptureModels.swift
//
// Contract model types for the two capture-family endpoints (Wave A2b: CORE-04).
//
// Every type here is byte-shape-exact from contracts/community/1.1/contract.json.
// No field is added, removed, or renamed. JSON encoding uses the field names
// exactly as the contract defines them (snake_case is NOT used — the contract
// specifies camelCase).
//
// CaptureSensitivity maps onto LocusKit's AdjectiveSensitivity:
//   "normal"     → AdjectiveSensitivity.normal     (raw 0)
//   "elevated"   → AdjectiveSensitivity.elevated   (raw 16)
//   "restricted" → AdjectiveSensitivity.restricted (raw 32)
//   "secret"     → AdjectiveSensitivity.secret     (raw 48)
//
// exportEligible maps onto AdjectiveExportability:
//   true  → AdjectiveExportability.public_  (raw 32)
//   false → AdjectiveExportability.private_ (raw 0)
//
// lanEligible has no LocusKit bitmap equivalent at this phase; it is
// persisted in the capture ledger (capture-ledger.json) alongside the
// recordID so the effective policy is reconstructable on retry.

import Foundation
import AriaMCP
import LocusKit

// MARK: - CaptureSensitivity

/// Sensitivity tier for a captured record — contract enum.
///
/// Wire values (string) map one-to-one onto LocusKit's `AdjectiveSensitivity`.
/// Unknown wire values fail closed at parse time (see `CaptureArguments`).
public enum CaptureSensitivity: String, Sendable, Codable, CaseIterable {
    case normal       = "normal"
    case elevated     = "elevated"
    case restricted   = "restricted"
    case secret       = "secret"

    /// Map to the LocusKit adjective sensitivity for storage in the drawer bitmap.
    var adjectiveSensitivity: AdjectiveSensitivity {
        switch self {
        case .normal:       return .normal
        case .elevated:     return .elevated
        case .restricted:   return .restricted
        case .secret:       return .secret
        }
    }

    /// Initialise from a LocusKit adjective sensitivity.
    /// Only the four mapped cases exist; unrecognised raw values never appear
    /// because CaptureSensitivity is always round-tripped through the ledger.
    init?(_ adjective: AdjectiveSensitivity) {
        switch adjective {
        case .normal:       self = .normal
        case .elevated:     self = .elevated
        case .restricted:   self = .restricted
        case .secret:       self = .secret
        }
    }
}

// MARK: - CaptureDestination

/// A valid filing destination — a wing/room pair in the estate.
///
/// id = "wing/room" (using the normalized lookup names, lowercase).
/// title = wing display name + space + room display name (title-cased).
/// detail = wing display name (provides context for the room).
public struct CaptureDestination: Sendable, Equatable, Codable {
    /// Wire id: "wing/room" using normalized lookup names.
    public let id: String
    /// Human-readable title, e.g. "personal capture".
    public let title: String
    /// Human-readable detail (typically the wing name), e.g. "personal".
    public let detail: String

    public init(id: String, title: String, detail: String) {
        self.id = id
        self.title = title
        self.detail = detail
    }
}

// MARK: - CapturePolicy

/// The resolved effective policy for a capture record.
/// Returned as part of `CaptureOutcome.applied`.
public struct CapturePolicy: Sendable, Equatable, Codable {
    public let destination: CaptureDestination
    public let sensitivity: CaptureSensitivity
    public let exportEligible: Bool
    public let lanEligible: Bool

    public init(
        destination: CaptureDestination,
        sensitivity: CaptureSensitivity,
        exportEligible: Bool,
        lanEligible: Bool
    ) {
        self.destination = destination
        self.sensitivity = sensitivity
        self.exportEligible = exportEligible
        self.lanEligible = lanEligible
    }
}

// MARK: - CaptureDefaultPolicy

/// The default policy applied when the caller does not override.
/// Carries only destinationID (not the full destination record) to keep the
/// choices response compact; the full destination is in the destinations array.
public struct CaptureDefaultPolicy: Sendable, Equatable, Codable {
    public let destinationID: String
    public let sensitivity: CaptureSensitivity
    public let exportEligible: Bool
    public let lanEligible: Bool

    public init(
        destinationID: String,
        sensitivity: CaptureSensitivity,
        exportEligible: Bool,
        lanEligible: Bool
    ) {
        self.destinationID = destinationID
        self.sensitivity = sensitivity
        self.exportEligible = exportEligible
        self.lanEligible = lanEligible
    }
}

// MARK: - CaptureChoices

/// The response for `moot_community_capture_choices`.
///
/// Destinations are enumerated from the CURRENT canonical estate state —
/// every non-tombstoned room across all wings. Sensitivities are the four
/// contract-defined levels. The defaultPolicy carries the private-leaning
/// default: restricted sensitivity, no export, no LAN, first destination
/// (alphabetical by id) as the target.
public struct CaptureChoices: Sendable, Equatable, Codable {
    public let destinations: [CaptureDestination]
    public let sensitivities: [CaptureSensitivity]
    public let defaultPolicy: CaptureDefaultPolicy

    public init(
        destinations: [CaptureDestination],
        sensitivities: [CaptureSensitivity],
        defaultPolicy: CaptureDefaultPolicy
    ) {
        self.destinations = destinations
        self.sensitivities = sensitivities
        self.defaultPolicy = defaultPolicy
    }
}

// MARK: - CaptureArguments

/// Arguments for `moot_community_capture`.
///
/// Parsed fail-closed from the JSONValue arguments object — unknown fields throw
/// `invalidParams`. All fields required; boolean fields must be JSON booleans
/// (not numbers or strings). `sensitivity` must be one of the four known values.
public struct CaptureArguments: Sendable {
    public let requestID: UUID
    public let subject: String
    public let content: String
    public let destinationID: String
    public let sensitivity: CaptureSensitivity
    public let exportEligible: Bool
    public let lanEligible: Bool

    public init(
        requestID: UUID,
        subject: String,
        content: String,
        destinationID: String,
        sensitivity: CaptureSensitivity,
        exportEligible: Bool,
        lanEligible: Bool
    ) {
        self.requestID = requestID
        self.subject = subject
        self.content = content
        self.destinationID = destinationID
        self.sensitivity = sensitivity
        self.exportEligible = exportEligible
        self.lanEligible = lanEligible
    }
}

// MARK: - CaptureRefusedField

/// The field that caused a capture refusal.
///
/// Wire values are the contract enum values — not Swift enum names.
/// Any unrecognised field in a response received by a client fails closed.
public enum CaptureRefusedField: String, Sendable, Codable {
    case destination    = "destination"
    case sensitivity    = "sensitivity"
    case exportEligibility = "export-eligibility"
    case lanEligibility    = "lan-eligibility"
    case content        = "content"
    case daemon         = "daemon"
}

// MARK: - CaptureOutcome (discriminated union)

/// Result of `moot_community_capture`. Discriminated by the "outcome" field.
///
/// applied:  capture succeeded; carries recordID and effectivePolicy.
/// refused:  validation rejected the request; carries field + reason code.
/// failed:   unexpected internal failure; carries reason code.
public enum CaptureOutcome: Sendable {
    case applied(recordID: UUID, effectivePolicy: CapturePolicy)
    case refused(field: CaptureRefusedField, reason: String)
    case failed(reason: String)
}

// MARK: - JSON encoding helpers

extension CaptureChoices {
    /// Encode to the MCP structured-result shape.
    func toJSONValue() -> JSONValue {
        let destArray = JSONValue.array(destinations.map { $0.toJSONValue() })
        let sensArray = JSONValue.array(sensitivities.map { .string($0.rawValue) })
        let policy = defaultPolicy.toJSONValue()
        let result: [String: JSONValue] = [
            "destinations": destArray,
            "sensitivities": sensArray,
            "defaultPolicy": policy,
        ]
        return mcpStructuredResult(result)
    }
}

extension CaptureDestination {
    func toJSONValue() -> JSONValue {
        .object(["id": .string(id), "title": .string(title), "detail": .string(detail)])
    }
}

extension CaptureDefaultPolicy {
    func toJSONValue() -> JSONValue {
        .object([
            "destinationID": .string(destinationID),
            "sensitivity": .string(sensitivity.rawValue),
            "exportEligible": .bool(exportEligible),
            "lanEligible": .bool(lanEligible),
        ])
    }
}

extension CapturePolicy {
    func toJSONValue() -> JSONValue {
        .object([
            "destination": destination.toJSONValue(),
            "sensitivity": .string(sensitivity.rawValue),
            "exportEligible": .bool(exportEligible),
            "lanEligible": .bool(lanEligible),
        ])
    }
}

extension CaptureOutcome {
    /// Encode to the MCP structured-result shape.
    func toJSONValue() -> JSONValue {
        switch self {
        case let .applied(recordID, effectivePolicy):
            let result: [String: JSONValue] = [
                "outcome": .string("applied"),
                "recordID": .string(recordID.uuidString.lowercased()),
                "effectivePolicy": effectivePolicy.toJSONValue(),
            ]
            return mcpStructuredResult(result)
        case let .refused(field, reason):
            let result: [String: JSONValue] = [
                "outcome": .string("refused"),
                "field": .string(field.rawValue),
                "reason": .string(reason),
            ]
            return mcpStructuredResult(result)
        case let .failed(reason):
            let result: [String: JSONValue] = [
                "outcome": .string("failed"),
                "reason": .string(reason),
            ]
            return mcpStructuredResult(result)
        }
    }
}

// MARK: - Private MCP encoding helpers

/// Wrap a typed result dictionary in the MCP tools/call structured-result shape.
///
/// The MCP result shape is:
///   { "content": [{"type": "text", "text": "<json>"}], "structuredContent": {...} }
///
/// Both the text frame and structuredContent carry the same data so clients
/// that parse either surface receive identical values.
private func mcpStructuredResult(_ dict: [String: JSONValue]) -> JSONValue {
    // Serialise to the text frame using JSONSerialization for a stable wire format.
    // sortedKeys ensures deterministic ordering for downstream diffing.
    let anyDict = jsonAnyFromValue(.object(dict))
    guard let data = try? JSONSerialization.data(
        withJSONObject: anyDict as Any,
        options: [.sortedKeys]
    ) else {
        // Unreachable: the value tree only contains strings, booleans, arrays, and
        // objects — no types that JSONSerialization cannot handle.
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

/// Recursively convert a `JSONValue` tree to `Any` for JSONSerialization.
private func jsonAnyFromValue(_ value: JSONValue) -> Any {
    switch value {
    case .null:              return NSNull()
    case .bool(let b):       return b
    case .integer(let i):    return i
    case .double(let d):     return d
    case .string(let s):     return s
    case .array(let a):      return a.map { jsonAnyFromValue($0) }
    case .object(let o):
        var dict: [String: Any] = [:]
        for (k, v) in o { dict[k] = jsonAnyFromValue(v) }
        return dict
    }
}
