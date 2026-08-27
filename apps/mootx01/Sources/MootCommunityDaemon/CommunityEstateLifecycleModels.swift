// CommunityEstateLifecycleModels.swift
//
// Supporting types and JSONValue builders for the six estate-lifecycle endpoints
// (Wave A2a: CORE-03). All wire shapes are derived byte-exact from
// contracts/community/1.1/contract.json — never from this comment block.
//
// Responsibilities:
//   - Codable structs for the two sidecar files the coordinator persists:
//       estate-metadata.json   (name, schemaVersion, receiptID)
//       operation-state.json   (in-progress or cancelled lifecycle operation)
//   - Plain data structs for carrying estate/plan/progress summary data
//     across actor boundaries without importing JSONValue.
//   - `LifecycleStateBuilder` — a private enum of static factory methods
//     that emit the correct `[String: JSONValue]` shape for each
//     EstateLifecycleState variant in the contract.
//   - `LifecycleMCPResponse` — wraps a state dict in the MCP
//     content/structuredContent envelope expected by the ARIA_MCPDispatcher.
//
// CORE-03: raw Keychain keys, SQL text, file handles, and unbounded exception
// strings NEVER cross these builders. Diagnosis strings are bounded and
// produced from classified Swift error types, not from raw error.localizedDescription.

import Foundation
import AriaMCP

// MARK: - Persisted sidecar: estate-metadata.json

/// Persisted alongside the estate file to carry user-visible metadata the
/// LocusKit manifest does not surface directly on the contract wire.
///
/// Written at `estate_create` time; read by every subsequent inspect.
/// Fields are chosen so the file is always a subset of what the contract
/// requires for `EstateSummary` — nothing extra (no paths, no keys).
public struct EstateMetadata: Codable, Sendable {
    /// The user-provided estate name, as supplied to `estate_create`.
    public var name: String

    /// The contract-level schema version string (e.g. "1.1") recorded when
    /// the estate was created. Not the raw integer from LocusKit — the
    /// contract wire uses string version labels.
    public var schemaVersion: String

    /// A stable UUID string for this estate's `EstateReceipt.receiptID`.
    /// Minted once at create time; never changes across opens.
    public var receiptID: String

    public init(name: String, schemaVersion: String, receiptID: String) {
        self.name = name
        self.schemaVersion = schemaVersion
        self.receiptID = receiptID
    }
}

// MARK: - Persisted sidecar: operation-state.json

/// Durable record of an in-progress or recently-completed lifecycle operation.
///
/// Written by `estate_migrate`/`estate_recover`/`estate_cancel` so that the
/// operation state survives a daemon restart (CORE-03: queryable after
/// reconnect). A new coordinator instance reads this file to reconstruct the
/// in-progress state without re-opening or re-verifying the estate.
///
/// Design: one file, one active operation at a time. A committed operation
/// state (ready) clears the file; an interrupted one retains it.
public struct PersistedOperationState: Codable, Sendable {

    /// Lifecycle operation kinds the coordinator persists.
    public enum Kind: String, Codable, Sendable {
        /// A migration is in progress.
        case migrating
        /// The operation was cancelled; the `resumable` field says whether
        /// it may be restarted with the same planID/choiceID.
        case cancelled
    }

    public var kind: Kind

    /// The stable UUID for this operation instance.
    /// Returned as `MigrationProgress.operationID` or `OperationIDArguments.operationID`.
    public var operationID: String

    /// The migration plan UUID (set for `.migrating` and its `.cancelled` form).
    public var planID: String

    /// Units completed so far (0-based; increases as migration advances).
    public var completedUnits: Int

    /// Total expected units (fixed at operation creation; bounded).
    public var totalUnits: Int

    /// Estate UUID, carried so inspect can return a full EstateSummary without
    /// needing to re-open the estate.
    public var estateID: String

    /// Estate name (from metadata file at operation-start time).
    public var estateName: String

    /// Source schema version string (e.g. "1.0").
    public var sourceVersion: String

    /// Target schema version string (e.g. "1.1").
    public var targetVersion: String

    /// For `.cancelled` kind: whether the operation may be restarted.
    /// Always `true` for an interrupted migration (plan is still valid);
    /// `false` once the migration has committed.
    public var resumable: Bool

    public init(
        kind: Kind,
        operationID: String,
        planID: String,
        completedUnits: Int,
        totalUnits: Int,
        estateID: String,
        estateName: String,
        sourceVersion: String,
        targetVersion: String,
        resumable: Bool
    ) {
        self.kind = kind
        self.operationID = operationID
        self.planID = planID
        self.completedUnits = completedUnits
        self.totalUnits = totalUnits
        self.estateID = estateID
        self.estateName = estateName
        self.sourceVersion = sourceVersion
        self.targetVersion = targetVersion
        self.resumable = resumable
    }
}

// MARK: - Plain data carriers (cross-actor, no JSONValue dependency)

/// Summary data for one estate — the fields of `EstateSummary` in the contract.
/// Carrying plain strings avoids JSONValue import in coordinator internals.
public struct EstateSummaryData: Sendable {
    public let id: String          // lowercase hyphenated UUID
    public let name: String        // user-visible name
    public let schemaVersion: String  // "1.0", "1.1", …

    public init(id: String, name: String, schemaVersion: String) {
        self.id = id; self.name = name; self.schemaVersion = schemaVersion
    }
}

/// Data for one recovery choice — maps to `RecoveryChoice` in the contract.
public struct RecoveryChoiceData: Sendable {
    public let id: String
    public let title: String
    public let consequence: String
    public let isDestructive: Bool

    public init(id: String, title: String, consequence: String, isDestructive: Bool) {
        self.id = id; self.title = title; self.consequence = consequence
        self.isDestructive = isDestructive
    }
}

/// Data for one migration plan — maps to `MigrationPlan` in the contract.
public struct MigrationPlanData: Sendable {
    public let id: String              // plan UUID
    public let estate: EstateSummaryData
    public let sourceVersion: String
    public let targetVersion: String
    public let expectedEffect: String

    public init(
        id: String, estate: EstateSummaryData, sourceVersion: String,
        targetVersion: String, expectedEffect: String
    ) {
        self.id = id; self.estate = estate; self.sourceVersion = sourceVersion
        self.targetVersion = targetVersion; self.expectedEffect = expectedEffect
    }
}

// MARK: - JSONValue builders for EstateLifecycleState variants

/// Factory methods that build `[String: JSONValue]` dicts for each variant of
/// `EstateLifecycleState` as defined in contracts/community/1.1/contract.json.
///
/// Every method is `internal` — callers are `CommunityEstateLifecycleCoordinator`
/// and the dispatch layer; contract consumers never build these dicts directly.
enum LifecycleStateBuilder {

    // ── Variants with no payload ───────────────────────────────────────────

    static func checking() -> [String: JSONValue] {
        ["state": .string("checking")]
    }

    static func needsCreation() -> [String: JSONValue] {
        ["state": .string("needsCreation")]
    }

    // ── ready ──────────────────────────────────────────────────────────────

    static func ready(estate: EstateSummaryData, receiptID: String) -> [String: JSONValue] {
        [
            "state": .string("ready"),
            "receipt": .object([
                "estate": encodeEstate(estate),
                "receiptID": .string(receiptID),
            ]),
        ]
    }

    // ── blocked ────────────────────────────────────────────────────────────

    /// reason must be one of the contract's bounded `reasonCodes`.
    /// Callers are responsible for only passing reason codes defined in the
    /// contract (estate-corrupt, estate-incompatible, estate-key-missing,
    /// estate-missing, authority-insufficient, migration-interrupted,
    /// migration-required, operation-cancelled, unexpected-failure).
    static func blocked(reason: String) -> [String: JSONValue] {
        ["state": .string("blocked"), "reason": .string(reason)]
    }

    // ── corrupt ────────────────────────────────────────────────────────────

    /// `diagnosis` must be a bounded classification string — NOT a raw SQL
    /// error, NOT a file path, NOT a key material substring. CORE-03.
    static func corrupt(
        estate: EstateSummaryData,
        diagnosis: String,
        choices: [RecoveryChoiceData]
    ) -> [String: JSONValue] {
        [
            "state": .string("corrupt"),
            "estate": encodeEstate(estate),
            "diagnosis": .string(diagnosis),
            "choices": .array(choices.map { encodeChoice($0) }),
        ]
    }

    // ── incompatible ───────────────────────────────────────────────────────

    static func incompatible(estate: EstateSummaryData, reason: String) -> [String: JSONValue] {
        [
            "state": .string("incompatible"),
            "estate": encodeEstate(estate),
            "reason": .string(reason),
        ]
    }

    // ── missingKey ─────────────────────────────────────────────────────────

    static func missingKey(estate: EstateSummaryData, choices: [RecoveryChoiceData]) -> [String: JSONValue] {
        [
            "state": .string("missingKey"),
            "estate": encodeEstate(estate),
            "choices": .array(choices.map { encodeChoice($0) }),
        ]
    }

    // ── chooseExisting ─────────────────────────────────────────────────────

    static func chooseExisting(estates: [EstateSummaryData]) -> [String: JSONValue] {
        ["state": .string("chooseExisting"), "estates": .array(estates.map { encodeEstate($0) })]
    }

    // ── migrationRequired ──────────────────────────────────────────────────

    static func migrationRequired(plan: MigrationPlanData) -> [String: JSONValue] {
        ["state": .string("migrationRequired"), "plan": encodePlan(plan)]
    }

    // ── migrating ──────────────────────────────────────────────────────────

    static func migrating(
        operationID: String,
        plan: MigrationPlanData,
        completedUnits: Int,
        totalUnits: Int
    ) -> [String: JSONValue] {
        [
            "state": .string("migrating"),
            "progress": .object([
                "operationID": .string(operationID),
                "plan": encodePlan(plan),
                "completedUnits": .integer(Int64(completedUnits)),
                "totalUnits": .integer(Int64(totalUnits)),
            ]),
        ]
    }

    // ── cancelled ──────────────────────────────────────────────────────────

    static func cancelled(resumable: Bool) -> [String: JSONValue] {
        ["state": .string("cancelled"), "resumable": .bool(resumable)]
    }

    // MARK: - Private encoders

    static func encodeEstate(_ e: EstateSummaryData) -> JSONValue {
        .object([
            "id": .string(e.id),
            "name": .string(e.name),
            "schemaVersion": .string(e.schemaVersion),
        ])
    }

    static func encodeChoice(_ c: RecoveryChoiceData) -> JSONValue {
        .object([
            "id": .string(c.id),
            "title": .string(c.title),
            "consequence": .string(c.consequence),
            "isDestructive": .bool(c.isDestructive),
        ])
    }

    static func encodePlan(_ p: MigrationPlanData) -> JSONValue {
        .object([
            "id": .string(p.id),
            "estate": encodeEstate(p.estate),
            "sourceVersion": .string(p.sourceVersion),
            "targetVersion": .string(p.targetVersion),
            "expectedEffect": .string(p.expectedEffect),
        ])
    }
}

// MARK: - MCP response envelope

/// Wraps an `EstateLifecycleState` dict in the MCP tools/call result shape:
/// `{ "content": [{"type":"text","text":"<json>"}], "structuredContent": {...} }`.
///
/// The `content` text frame is JSON-serialised with sorted keys so that
/// shape-validation tests and digest checks get a deterministic byte order.
/// The `structuredContent` object carries the typed result for schema-aware
/// clients.
enum LifecycleMCPResponse {

    /// Build the MCP envelope for the given state dict.
    /// Returns `.object([:])` on the (unreachable) JSON serialisation failure.
    static func wrap(_ state: [String: JSONValue]) -> JSONValue {
        // Build a Foundation dict for JSONSerialization.
        let jsonText: String
        if let data = try? JSONSerialization.data(
            withJSONObject: state.mapValues { $0.foundationObject },
            options: [.sortedKeys]
        ) {
            jsonText = String(decoding: data, as: UTF8.self)
        } else {
            // Unreachable: all leaf values are strings/bools/integers.
            jsonText = "{}"
        }
        return .object([
            "content": .array([
                .object(["type": .string("text"), "text": .string(jsonText)])
            ]),
            "structuredContent": .object(state),
        ])
    }
}
