// ShapeValidator.swift
//
// Swift port of verify_contract.py's ShapeValidator + semantic_checks.
//
// Validates that a JSON value conforms to the type definition from contract.json.
// Types are: primitive scalars (string, nonempty-string, boolean, integer,
// nonnegative-integer, uuid, date-time, url, base64, reason-code, contract-id,
// contract-version, sha256-algorithm, sha256), records (object with named
// fields, some optional), enums (string, one of a fixed set), and unions
// (tagged discriminator, where the discriminator selects additional fields).
//
// Array types are spelled "T[]" for an array of elements each of type T.
//
// Unknown fields are rejected (strict shape parsing) — an unknown field in
// the daemon's response indicates a contract violation.
//
// This validator does NOT check exact instance values such as UUIDs or
// timestamps — those are generated fresh by the daemon and cannot be compared
// against the fixture's example result. It checks structure only.

import Foundation
import CoreFoundation

// MARK: - ShapeValidationError

enum ShapeValidationError: Error, CustomStringConvertible {
    case typeMismatch(path: String, expected: String, found: String)
    case missingFields(path: String, fields: [String])
    case unknownFields(path: String, fields: [String])
    case invalidEnumValue(path: String, value: String, allowed: [String])
    case unknownDiscriminator(path: String, tag: String?)
    case unknownShape(path: String, shape: String)
    case invalidPrimitive(path: String, detail: String)

    var description: String {
        switch self {
        case .typeMismatch(let p, let e, let f):
            return "\(p): expected \(e), found \(f)"
        case .missingFields(let p, let fs):
            return "\(p): missing fields \(fs)"
        case .unknownFields(let p, let fs):
            return "\(p): unknown fields \(fs)"
        case .invalidEnumValue(let p, let v, let a):
            return "\(p): '\(v)' not in \(a)"
        case .unknownDiscriminator(let p, let t):
            return "\(p): unknown discriminator \(t ?? "nil")"
        case .unknownShape(let p, let s):
            return "\(p): unknown shape '\(s)'"
        case .invalidPrimitive(let p, let d):
            return "\(p): \(d)"
        }
    }
}

// MARK: - ShapeValidator

/// Validates JSON values against contract type definitions.
///
/// Constructed from the parsed `contract.json` object and the fixture-bundle
/// digest (for `@fixture-bundle.sha256` placeholder resolution).
struct ShapeValidator {

    /// The `types` dictionary from contract.json.
    let types: [String: Any]

    /// The `reasonCodes` array from contract.json (sorted set for O(1) lookup).
    let reasonCodes: Set<String>

    /// The `contractID` from contract.json.
    let contractID: String

    /// The `contractVersion` from contract.json.
    let contractVersion: String

    /// The computed fixture-bundle SHA-256 digest.
    let digest: String

    init(contract: [String: Any], digest: String) {
        self.types = contract["types"] as? [String: Any] ?? [:]
        self.contractID = contract["contractID"] as? String ?? ""
        self.contractVersion = contract["contractVersion"] as? String ?? ""
        self.digest = digest
        let codes = contract["reasonCodes"] as? [String] ?? []
        self.reasonCodes = Set(codes)
    }

    // MARK: - Entry point

    /// Validate `value` against type `shape` at `path`.
    ///
    /// - Throws: `ShapeValidationError` if validation fails.
    func validate(_ value: Any, shape: String, path: String) throws {
        // Array type: shape ends with "[]"
        if shape.hasSuffix("[]") {
            let elementShape = String(shape.dropLast(2))
            guard let array = value as? [Any] else {
                throw ShapeValidationError.typeMismatch(
                    path: path, expected: "array", found: typeName(value)
                )
            }
            for (index, item) in array.enumerated() {
                try validate(item, shape: elementShape, path: "\(path)[\(index)]")
            }
            return
        }

        // Primitive shapes
        let primitiveKey = shape.replacingOccurrences(of: "-", with: "_")
        switch primitiveKey {
        case "string":           try validateString(value, path: path, allowEmpty: true)
        case "nonempty_string":  try validateString(value, path: path, allowEmpty: false)
        case "boolean":          try validateBoolean(value, path: path)
        case "integer":          try validateInteger(value, path: path, nonNegative: false)
        case "nonnegative_integer": try validateInteger(value, path: path, nonNegative: true)
        case "uuid":             try validateUUID(value, path: path)
        case "date_time":        try validateDateTime(value, path: path)
        case "url":              try validateURL(value, path: path)
        case "base64":           try validateBase64(value, path: path)
        case "reason_code":      try validateReasonCode(value, path: path)
        case "contract_id":      try validateContractID(value, path: path)
        case "contract_version": try validateContractVersion(value, path: path)
        case "sha256_algorithm": try validateSHA256Algorithm(value, path: path)
        case "sha256":           try validateSHA256(value, path: path)
        default:
            // Named type from contract.json
            guard let definition = types[shape] as? [String: Any] else {
                throw ShapeValidationError.unknownShape(path: path, shape: shape)
            }
            let kind = definition["kind"] as? String ?? ""
            switch kind {
            case "enum":
                try validateEnum(value, definition: definition, path: path)
            case "record":
                try validateRecord(value, definition: definition, path: path)
            case "union":
                try validateUnion(value, definition: definition, path: path)
            default:
                throw ShapeValidationError.unknownShape(path: path, shape: "kind=\(kind)")
            }
        }
    }

    // MARK: - Named types

    private func validateEnum(_ value: Any, definition: [String: Any], path: String) throws {
        guard let str = value as? String else {
            throw ShapeValidationError.typeMismatch(
                path: path, expected: "enum-string", found: typeName(value)
            )
        }
        let allowed = definition["values"] as? [String] ?? []
        guard allowed.contains(str) else {
            throw ShapeValidationError.invalidEnumValue(path: path, value: str, allowed: allowed)
        }
    }

    private func validateRecord(_ value: Any, definition: [String: Any], path: String) throws {
        guard let obj = value as? [String: Any] else {
            throw ShapeValidationError.typeMismatch(
                path: path, expected: "object", found: typeName(value)
            )
        }
        let rawFields = definition["fields"] as? [String: String] ?? [:]
        try validateFields(obj, rawFields: rawFields, path: path)
    }

    private func validateUnion(_ value: Any, definition: [String: Any], path: String) throws {
        guard let obj = value as? [String: Any] else {
            throw ShapeValidationError.typeMismatch(
                path: path, expected: "union-object", found: typeName(value)
            )
        }
        let discriminator = definition["discriminator"] as? String ?? "state"
        let tag = obj[discriminator] as? String
        let variants = definition["variants"] as? [String: [String: String]] ?? [:]
        guard let variantFields = variants[tag ?? ""] else {
            throw ShapeValidationError.unknownDiscriminator(path: path, tag: tag)
        }
        // Common fields apply to all variants
        var allRawFields: [String: String] = definition["commonFields"] as? [String: String] ?? [:]
        // The discriminator itself is always a string field
        allRawFields[discriminator] = "string"
        // Variant-specific fields
        for (k, v) in variantFields { allRawFields[k] = v }
        try validateFields(obj, rawFields: allRawFields, path: path)
    }

    private func validateFields(_ obj: [String: Any], rawFields: [String: String], path: String) throws {
        // Parse field names (optional fields end with "?")
        var required = Set<String>()
        var allowed  = Set<String>()
        var shapes   = [String: String]()
        for (rawName, shape) in rawFields {
            let isOptional = rawName.hasSuffix("?")
            let name = isOptional ? String(rawName.dropLast()) : rawName
            allowed.insert(name)
            shapes[name] = shape
            if !isOptional { required.insert(name) }
        }
        let presentKeys = Set(obj.keys)
        let missing  = required.subtracting(presentKeys)
        let unknown  = presentKeys.subtracting(allowed)
        if !missing.isEmpty {
            throw ShapeValidationError.missingFields(path: path, fields: missing.sorted())
        }
        if !unknown.isEmpty {
            throw ShapeValidationError.unknownFields(path: path, fields: unknown.sorted())
        }
        for (name, value) in obj {
            if let shape = shapes[name] {
                try validate(value, shape: shape, path: "\(path).\(name)")
            }
        }
    }

    // MARK: - Primitives

    private func validateString(_ value: Any, path: String, allowEmpty: Bool) throws {
        guard let str = value as? String else {
            throw ShapeValidationError.typeMismatch(
                path: path, expected: "string", found: typeName(value)
            )
        }
        if !allowEmpty && str.isEmpty {
            throw ShapeValidationError.invalidPrimitive(path: path, detail: "expected non-empty string")
        }
    }

    private func validateBoolean(_ value: Any, path: String) throws {
        // Use CFGetTypeID to avoid false-negative on NSNumber(value: 0) which
        // satisfies `is Bool` even though it is an integer.
        guard let ns = value as? NSNumber,
              CFGetTypeID(ns as CFTypeRef) == CFBooleanGetTypeID() else {
            throw ShapeValidationError.typeMismatch(
                path: path, expected: "boolean", found: typeName(value)
            )
        }
    }

    private func validateInteger(_ value: Any, path: String, nonNegative: Bool) throws {
        // `value is Bool` is unreliable for NSNumber values from JSONSerialization:
        // on Darwin, `__NSCFNumber(0)` satisfies `is Bool` even though it is an
        // integer.  Use CFGetTypeID to correctly distinguish __NSCFBoolean from
        // __NSCFNumber (the only reliable Foundation distinction for JSON-decoded
        // values on this platform).
        if let ns = value as? NSNumber, CFGetTypeID(ns as CFTypeRef) == CFBooleanGetTypeID() {
            throw ShapeValidationError.typeMismatch(
                path: path, expected: "integer", found: "boolean"
            )
        }
        guard let n = value as? Int else {
            throw ShapeValidationError.typeMismatch(
                path: path, expected: "integer", found: typeName(value)
            )
        }
        if nonNegative && n < 0 {
            throw ShapeValidationError.invalidPrimitive(path: path, detail: "expected non-negative integer")
        }
    }

    private func validateUUID(_ value: Any, path: String) throws {
        guard let str = value as? String, let parsed = UUID(uuidString: str) else {
            throw ShapeValidationError.invalidPrimitive(path: path, detail: "expected canonical UUID string")
        }
        // Canonical form: lowercase with hyphens
        guard str == parsed.uuidString.lowercased() else {
            throw ShapeValidationError.invalidPrimitive(path: path, detail: "UUID must be in canonical lowercase form")
        }
    }

    private func validateDateTime(_ value: Any, path: String) throws {
        guard let str = value as? String, str.hasSuffix("Z") else {
            throw ShapeValidationError.invalidPrimitive(
                path: path, detail: "expected UTC RFC 3339 date-time ending in Z"
            )
        }
        let iso = str.dropLast() + "+00:00"
        // Try without fractional seconds first, then with — the daemon may emit
        // sub-second precision (e.g. "2026-08-25T00:25:26.104Z") which is valid
        // per RFC 3339 but requires .withFractionalSeconds in the formatter.
        let formatterNoFrac = ISO8601DateFormatter()
        formatterNoFrac.formatOptions = [.withInternetDateTime]
        let formatterFrac = ISO8601DateFormatter()
        formatterFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard formatterNoFrac.date(from: String(iso)) != nil
            || formatterFrac.date(from: String(iso)) != nil
        else {
            throw ShapeValidationError.invalidPrimitive(path: path, detail: "invalid date-time '\(str)'")
        }
    }

    private func validateURL(_ value: Any, path: String) throws {
        guard let str = value as? String, let url = URL(string: str) else {
            throw ShapeValidationError.invalidPrimitive(path: path, detail: "expected URL string")
        }
        guard url.scheme != nil else {
            throw ShapeValidationError.invalidPrimitive(path: path, detail: "URL must have a scheme")
        }
    }

    private func validateBase64(_ value: Any, path: String) throws {
        guard let str = value as? String, !str.isEmpty else {
            throw ShapeValidationError.invalidPrimitive(
                path: path, detail: "expected non-empty base64 string"
            )
        }
        // Standard base64 (NOT url-safe) with optional padding
        let padded = str + String(repeating: "=", count: (4 - str.count % 4) % 4)
        guard Data(base64Encoded: padded) != nil else {
            throw ShapeValidationError.invalidPrimitive(path: path, detail: "invalid base64 string")
        }
    }

    private func validateReasonCode(_ value: Any, path: String) throws {
        guard let str = value as? String else {
            throw ShapeValidationError.typeMismatch(
                path: path, expected: "reason-code string", found: typeName(value)
            )
        }
        guard reasonCodes.contains(str) else {
            throw ShapeValidationError.invalidPrimitive(
                path: path, detail: "unbounded reason code '\(str)'"
            )
        }
    }

    private func validateContractID(_ value: Any, path: String) throws {
        guard let str = value as? String, str == contractID else {
            throw ShapeValidationError.invalidPrimitive(
                path: path,
                detail: "expected contractID '\(contractID)', got '\(value)'"
            )
        }
    }

    private func validateContractVersion(_ value: Any, path: String) throws {
        guard let str = value as? String, str == contractVersion else {
            throw ShapeValidationError.invalidPrimitive(
                path: path,
                detail: "expected contractVersion '\(contractVersion)', got '\(value)'"
            )
        }
    }

    private func validateSHA256Algorithm(_ value: Any, path: String) throws {
        guard let str = value as? String, str == "sha256" else {
            throw ShapeValidationError.invalidPrimitive(path: path, detail: "expected 'sha256'")
        }
    }

    private func validateSHA256(_ value: Any, path: String) throws {
        guard let str = value as? String,
              str.count == 64,
              str.allSatisfy({ $0.isHexDigit && $0.isLowercase || $0.isNumber }) else {
            throw ShapeValidationError.invalidPrimitive(
                path: path, detail: "expected lowercase 64-char SHA-256 hex digest"
            )
        }
    }

    // MARK: - Helpers

    private func typeName(_ value: Any) -> String {
        // Use CFGetTypeID to distinguish __NSCFBoolean from __NSCFNumber —
        // `is Bool` alone is unreliable for Darwin-side JSON-decoded NSNumber values.
        if let ns = value as? NSNumber {
            return CFGetTypeID(ns as CFTypeRef) == CFBooleanGetTypeID() ? "boolean" : "integer"
        }
        switch value {
        case is Double: return "number"
        case is String: return "string"
        case is [Any]:  return "array"
        case is [String: Any]: return "object"
        default: return "\(type(of: value))"
        }
    }
}

// MARK: - Semantic checks (port of verify_contract.py:semantic_checks)

/// Apply cross-field invariants to a LIVE daemon response.
///
/// `method` is the endpoint name; `args` is what was sent; `response` is what
/// the daemon returned (already shape-validated). `digest` is the
/// fixture-bundle digest used for identity checks.
///
/// - Throws: `ShapeValidationError.invalidPrimitive` when an invariant fails.
func semanticChecks(
    method: String,
    args: [String: Any],
    response: [String: Any],
    digest: String
) throws {
    switch method {

    case "moot_community_contract_identity":
        // Exact values required: contractID, contractVersion, fixtureDigest.
        guard
            (response["contractID"] as? String) == "com.simple-machines.mootx01.community",
            (response["contractVersion"] as? String) == "1.1.0",
            (response["fixtureDigest"] as? String) == digest
        else {
            throw ShapeValidationError.invalidPrimitive(
                path: "identity",
                detail: "contractID/contractVersion/fixtureDigest mismatch"
            )
        }

    case "moot_community_capture_choices":
        guard
            let destinations = response["destinations"] as? [[String: Any]],
            let sensitivities = response["sensitivities"] as? [String],
            let defaultPolicy = response["defaultPolicy"] as? [String: Any],
            let defaultDest = defaultPolicy["destinationID"] as? String,
            let defaultSens = defaultPolicy["sensitivity"] as? String
        else { break }
        let destIDs = Set(destinations.compactMap { $0["id"] as? String })
        guard destIDs.contains(defaultDest) else {
            throw ShapeValidationError.invalidPrimitive(
                path: "captureChoices.defaultPolicy.destinationID",
                detail: "default destination is not in the offered destinations"
            )
        }
        guard sensitivities.contains(defaultSens) else {
            throw ShapeValidationError.invalidPrimitive(
                path: "captureChoices.defaultPolicy.sensitivity",
                detail: "default sensitivity is not in offered sensitivities"
            )
        }
        if let lanEligible = defaultPolicy["lanEligible"] as? Bool,
           let exportEligible = defaultPolicy["exportEligible"] as? Bool,
           lanEligible && !exportEligible {
            throw ShapeValidationError.invalidPrimitive(
                path: "captureChoices.defaultPolicy",
                detail: "LAN eligibility cannot widen export-ineligible default"
            )
        }

    case "moot_community_capture":
        if let outcome = response["outcome"] as? String, outcome == "applied",
           let effective = response["effectivePolicy"] as? [String: Any],
           let lanEligible = effective["lanEligible"] as? Bool,
           let exportEligible = effective["exportEligible"] as? Bool,
           lanEligible && !exportEligible {
            throw ShapeValidationError.invalidPrimitive(
                path: "captureOutcome.effectivePolicy",
                detail: "effective LAN eligibility cannot widen export-ineligible material"
            )
        }

    case "moot_community_review_dashboard":
        guard let modes = response["modes"] as? [[String: Any]] else { break }
        let kinds = modes.compactMap { $0["kind"] as? String }.sorted()
        guard kinds == ["endOfDay", "morning", "weekly"] else {
            throw ShapeValidationError.invalidPrimitive(
                path: "reviewDashboard.modes",
                detail: "dashboard must contain every mode exactly once: got \(kinds)"
            )
        }

    case "moot_community_review_session":
        if let outcome = response["outcome"] as? String, outcome == "session",
           let session = response["session"] as? [String: Any],
           let sessionKind = session["kind"] as? String,
           let requestKind = args["kind"] as? String,
           sessionKind != requestKind {
            throw ShapeValidationError.invalidPrimitive(
                path: "reviewSession.session.kind",
                detail: "session kind '\(sessionKind)' differs from request kind '\(requestKind)'"
            )
        }

    case "moot_community_review_complete":
        if let outcome = response["outcome"] as? String, outcome == "completed",
           let receipt = response["receipt"] as? [String: Any],
           let receiptSession = receipt["sessionID"] as? String,
           let requestSession = args["sessionID"] as? String,
           receiptSession != requestSession {
            throw ShapeValidationError.invalidPrimitive(
                path: "reviewComplete.receipt.sessionID",
                detail: "receipt sessionID differs from request"
            )
        }

    case "moot_community_obsidian_status":
        let hasCheckpoint = response["checkpointAt"] != nil
        let hasRecordCount = response["recordCount"] != nil
        guard hasCheckpoint == hasRecordCount else {
            throw ShapeValidationError.invalidPrimitive(
                path: "obsidianStatus",
                detail: "checkpointAt and recordCount must appear together"
            )
        }
        if let state = response["state"] as? String, state == "synchronizing" {
            let hasPending = response["pendingCount"] != nil
            let hasTotal   = response["totalCount"] != nil
            guard hasPending == hasTotal else {
                throw ShapeValidationError.invalidPrimitive(
                    path: "obsidianStatus.synchronizing",
                    detail: "pendingCount and totalCount must appear together"
                )
            }
            if let pending = response["pendingCount"] as? Int,
               let total   = response["totalCount"] as? Int,
               pending > total {
                throw ShapeValidationError.invalidPrimitive(
                    path: "obsidianStatus.synchronizing",
                    detail: "pendingCount \(pending) exceeds totalCount \(total)"
                )
            }
        }

    case "moot_community_transfer_job_status":
        if let outcome = response["outcome"] as? String, outcome == "status",
           let jobID = response["jobID"] as? String,
           let requestJobID = args["jobID"] as? String,
           jobID != requestJobID {
            throw ShapeValidationError.invalidPrimitive(
                path: "jobStatus.jobID",
                detail: "returned job identity differs from query"
            )
        }
        if let outcome = response["outcome"] as? String, outcome == "status",
           let jobState = response["jobState"] as? [String: Any],
           let state = jobState["state"] as? String, state == "running",
           let processed = jobState["processed"] as? Int,
           let total = jobState["total"] as? Int,
           processed > total {
            throw ShapeValidationError.invalidPrimitive(
                path: "jobStatus.jobState",
                detail: "processed \(processed) exceeds total \(total)"
            )
        }

    default:
        // No semantic checks for this method.
        break
    }

    // Transfer plan invariant: applies to any response that contains a "plan" dict.
    if let plan = response["plan"] as? [String: Any],
       let candidateCount = plan["candidateCount"] as? Int,
       let estimatedCount = plan["estimatedTransferCount"] as? Int,
       let exclusionCount = plan["policyExclusionCount"] as? Int {
        guard estimatedCount + exclusionCount <= candidateCount else {
            throw ShapeValidationError.invalidPrimitive(
                path: "plan",
                detail: "estimatedTransferCount + policyExclusionCount > candidateCount"
            )
        }
    }
}
