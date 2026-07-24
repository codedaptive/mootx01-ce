import Foundation
import LocusKit

// ResidentReconcilePolicy.swift
//
// Outcome types for VaultResidentService's bidirectional reconcile cycle.
// The policy is estate-is-authority: when the vault and estate both changed
// the same note since the last sync, the estate version overwrites the vault
// (never the reverse). Blocked items and conflicts are surfaced in
// ResidentConflict records — never auto-resolved.
//
// Privacy fence: non-exportable content never crosses to the vault.
// The fence is enforced by using VaultExportScope.exportable on every
// estate→vault direction call. This bit of policy is embedded at the
// VaultBridge call site (VaultResidentService), not here — these types
// only model the outcomes.

/// The result of a single reconcile direction (estate→vault or vault→estate).
public struct ReconcileReport: Sendable {
    /// Notes/drawers successfully synced in this direction.
    public var syncCount: Int
    /// Conflicts detected (estate won; vault file overwritten with estate content).
    public var conflictsResolved: Int
    /// Vault deletion events reported but NOT applied to the estate.
    public var vaultDeletionsBlocked: Int

    public init(syncCount: Int = 0, conflictsResolved: Int = 0, vaultDeletionsBlocked: Int = 0) {
        self.syncCount = syncCount
        self.conflictsResolved = conflictsResolved
        self.vaultDeletionsBlocked = vaultDeletionsBlocked
    }
}

/// A conflict record: a vault-side change was detected but the estate version
/// is authoritative and has been written back to the vault. The caller surfaces
/// this to the operator; VaultResidentService never discards it silently.
public struct ResidentConflict: Sendable, Identifiable {
    public var id: UUID { lineageID }
    /// The estate drawer lineage whose content won the conflict.
    public let lineageID: UUID
    /// Vault-relative path of the contested note (e.g. "Projects/Sprint.md").
    public let vaultPath: String
    /// The estate content that was written back to the vault.
    public let estateContent: String
    /// When the conflict was detected.
    public let detectedAt: Date

    public init(lineageID: UUID, vaultPath: String, estateContent: String, detectedAt: Date) {
        self.lineageID = lineageID
        self.vaultPath = vaultPath
        self.estateContent = estateContent
        self.detectedAt = detectedAt
    }
}

/// A vault deletion that was detected but not applied to the estate.
/// The resident service reports these rather than auto-erasing estate content
/// (vault deletions are never authoritative over the estate per policy).
public struct BlockedVaultDeletion: Sendable {
    /// Vault-relative path that was removed from the vault.
    public let vaultPath: String
    /// When the deletion was detected.
    public let detectedAt: Date

    public init(vaultPath: String, detectedAt: Date) {
        self.vaultPath = vaultPath
        self.detectedAt = detectedAt
    }
}

/// Predicate: true iff the given exportability value blocks the drawer from
/// crossing to the vault. Matches the VaultExportScope.exportable fence:
/// only drawers with exportability == .public_ are eligible.
///
/// The fence is enforced at the VaultBridge export call (scope: .exportable).
/// This function is the readable statement of the same rule, used in tests
/// and in service logging to make the policy explicit.
///
/// - Parameter exportability: The drawer's AdjectiveExportability value.
/// - Returns: true iff the drawer is blocked from vault export.
public func isVaultFenced(exportability: AdjectiveExportability) -> Bool {
    exportability != .public_
}
