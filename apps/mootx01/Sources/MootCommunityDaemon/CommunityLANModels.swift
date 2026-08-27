// CommunityLANModels.swift
//
// Contract model types for the five LAN-family endpoints (Wave D2: CORE-08).
//
// Every type here is byte-shape-exact from contracts/community/1.1/contract.json
// and the lan.json fixture file. No field is added, removed, or renamed.
// JSON encoding uses camelCase field names exactly as the contract defines them.
//
// ELIGIBILITY INVARIANT (CORE-08)
// ────────────────────────────────────────────────────────────────────────────
// A record is LAN-addressable ONLY when ALL three conditions hold:
//   1. sensitivity ∈ {normal, elevated}  — "below restricted" per fixture fixture
//      lan-policy-mixed-eligibility policyDescription
//   2. exportEligible == true
//   3. lanEligible == true
//
// This is checked at serve time (not just at start time), so an eligibility
// change takes effect for all subsequent requests without restarting the server.
//
// AUTHENTICATION (CORE-08)
// ────────────────────────────────────────────────────────────────────────────
// A bearer token is minted at lan_start. The token is a UUIDv4 string.
// LANAuthentication states:
//   valid      — token exists and has not expired
//   expired    — token was minted but its validity window has passed
//   notObtained — no token has ever been minted (not started, or stopped before token)
//
// RESTART POLICY (frozen-policy: default-off)
// ────────────────────────────────────────────────────────────────────────────
// On coordinator init, serving state is always `stopped` regardless of the
// sidecar contents. This is the "frozen policy" reading: the default policy
// baked at build time is OFF; the sidecar encodes authority grants (which
// persist across restarts) but NOT the serving state. The acceptance criterion
// "Restart does not silently restore serving" is enforced structurally by
// initializing ServingState.stopped unconditionally at init time.

import Foundation
import AriaMCP

// MARK: - LANAuthentication

/// Authentication state of the active LAN credential.
///
/// Wire values are exact strings from the contract (valid, expired, notObtained).
public enum LANAuthentication: String, Sendable, Codable {
    /// Token exists and has not expired. Requests with this token are served.
    case valid       = "valid"
    /// Token was minted but the validity window has passed.
    /// Serving continues (socket still bound) but fetch requests are rejected
    /// with a distinguishable `lan-credential-expired` error code.
    case expired     = "expired"
    /// No token has ever been minted for this serving session.
    case notObtained = "notObtained"

    /// Serialize to JSONValue.
    public func toJSONValue() -> JSONValue { .string(rawValue) }
}

// MARK: - LANStatus (moot_community_lan_status result)

/// The discriminated-union result of moot_community_lan_status.
///
/// Fixture shapes (lan.json):
///   stopped           — serving is off (default on fresh coordinator or after stop)
///   starting          — bind in progress (transient; not emitted in tests but present
///                       in the contract for robustness against slow network attach)
///   active{endpoint,authentication} — socket bound and accepting connections
///   interrupted{reason} — socket was lost mid-run (e.g. network interface removed)
///   blocked{reason}   — cannot serve (e.g. authority refused; not merely stopped)
///   failed{reason}    — unrecoverable internal error during serving
///
/// The five LAN error codes from the contract:
///   lan-authority-missing, lan-credential-expired, lan-network-unavailable,
///   lan-policy-forbidden, unexpected-failure.
public enum LANStatus: Sendable {
    case stopped
    case starting
    case active(endpoint: String, authentication: LANAuthentication)
    case interrupted(reason: String)
    case blocked(reason: String)
    case failed(reason: String)

    /// Serialize to JSONValue following the contract's discriminator-first shape.
    public func toJSONValue() -> JSONValue {
        switch self {
        case .stopped:
            return .object(["state": .string("stopped")])
        case .starting:
            return .object(["state": .string("starting")])
        case let .active(endpoint, auth):
            return .object([
                "state":          .string("active"),
                "endpoint":       .string(endpoint),
                "authentication": .string(auth.rawValue),
            ])
        case let .interrupted(reason):
            return .object([
                "state":  .string("interrupted"),
                "reason": .string(reason),
            ])
        case let .blocked(reason):
            return .object([
                "state":  .string("blocked"),
                "reason": .string(reason),
            ])
        case let .failed(reason):
            return .object([
                "state":  .string("failed"),
                "reason": .string(reason),
            ])
        }
    }
}

// MARK: - LANPolicy (moot_community_lan_policy result)

/// The eligibility counts and human-readable policy description.
///
/// eligibleCount and ineligibleCount are computed LIVE from the capture
/// ledger at call time (not cached). Counts reflect the current effective
/// policy even when the server is stopped.
///
/// policyDescription is the fixed contract string from the fixture:
///   "Only explicitly LAN-eligible and export-eligible records below
///    restricted sensitivity are served."
public struct LANPolicy: Sendable {
    /// Records currently meeting all three LAN eligibility criteria.
    public let eligibleCount: Int
    /// Records present in the ledger but failing at least one criterion.
    public let ineligibleCount: Int
    /// Human-readable policy description (fixed string per contract fixture).
    public let policyDescription: String

    public init(eligibleCount: Int, ineligibleCount: Int, policyDescription: String) {
        self.eligibleCount = eligibleCount
        self.ineligibleCount = ineligibleCount
        self.policyDescription = policyDescription
    }

    public func toJSONValue() -> JSONValue {
        .object([
            "eligibleCount":    .integer(Int64(eligibleCount)),
            "ineligibleCount":  .integer(Int64(ineligibleCount)),
            "policyDescription": .string(policyDescription),
        ])
    }
}

// MARK: - LANStartOutcome (moot_community_lan_start result)

/// Result of a lan_start call.
///
/// started{endpoint, authentication}: socket bound, token minted, serving active.
/// denied{reason}: refused before binding — e.g. lan-authority-missing.
/// failed{reason}: unexpected error during bind or token mint.
public enum LANStartOutcome: Sendable {
    case started(endpoint: String, authentication: LANAuthentication)
    case denied(reason: String)
    case failed(reason: String)

    public func toJSONValue() -> JSONValue {
        switch self {
        case let .started(endpoint, auth):
            return .object([
                "outcome":        .string("started"),
                "endpoint":       .string(endpoint),
                "authentication": .string(auth.rawValue),
            ])
        case let .denied(reason):
            return .object([
                "outcome": .string("denied"),
                "reason":  .string(reason),
            ])
        case let .failed(reason):
            return .object([
                "outcome": .string("failed"),
                "reason":  .string(reason),
            ])
        }
    }
}

// MARK: - LANStopOutcome (moot_community_lan_stop result)

/// Result of a lan_stop call.
///
/// stopped: socket closed, endpoint is no longer serving.
/// failed{reason}: stop encountered an unexpected error (socket close failed).
public enum LANStopOutcome: Sendable {
    case stopped
    case failed(reason: String)

    public func toJSONValue() -> JSONValue {
        switch self {
        case .stopped:
            return .object(["outcome": .string("stopped")])
        case let .failed(reason):
            return .object([
                "outcome": .string("failed"),
                "reason":  .string(reason),
            ])
        }
    }
}

// MARK: - LANEligibilityOutcome (moot_community_lan_refresh_eligibility result)

/// Result of a lan_refresh_eligibility call.
///
/// updated{eligibleCount, ineligibleCount}: live counts recomputed from the
///   capture ledger; the LIVE server (if active) now filters with the new counts.
/// refused{reason}: policy forbids a refresh (e.g. lan-policy-forbidden).
/// failed{reason}: unexpected error recomputing eligibility.
public enum LANEligibilityOutcome: Sendable {
    case updated(eligibleCount: Int, ineligibleCount: Int)
    case refused(reason: String)
    case failed(reason: String)

    public func toJSONValue() -> JSONValue {
        switch self {
        case let .updated(eligible, ineligible):
            return .object([
                "outcome":         .string("updated"),
                "eligibleCount":   .integer(Int64(eligible)),
                "ineligibleCount": .integer(Int64(ineligible)),
            ])
        case let .refused(reason):
            return .object([
                "outcome": .string("refused"),
                "reason":  .string(reason),
            ])
        case let .failed(reason):
            return .object([
                "outcome": .string("failed"),
                "reason":  .string(reason),
            ])
        }
    }
}
