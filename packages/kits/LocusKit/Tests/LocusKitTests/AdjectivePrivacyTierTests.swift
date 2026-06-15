import Foundation
import Testing
@testable import LocusKit

/// Privacy-tier predicate coverage for `AdjectiveSensitivity` — ADR-007 Decision 2.
///
/// ADR-007 Decision 2 defines three privacy tiers that map onto the existing
/// four-value sensitivity axis without adding new bits or schema changes:
///
///   Normal tier  → `.normal` (raw 0) + `.elevated` (raw 16) — free bulk export
///   Private tier → `.restricted` (raw 32)                   — bulk requires owner-held key (v1.0 gold)
///   Secret tier  → `.secret` (raw 48)                       — never rides bulk channels
///
/// This suite covers:
///   1. The exact truth table for all four values × all three predicates.
///   2. Exhaustiveness: every case maps to exactly one tier (mutually exclusive,
///      collectively exhaustive — exactly one of the three predicates is true per value).
@Suite("AdjectivePrivacyTierTests")
struct AdjectivePrivacyTierTests {

    // MARK: - isBulkExportable (Normal tier — ADR-007 Decision 2)

    @Test("isBulkExportable is true for .normal — ADR-007 Decision 2 Normal tier")
    func isBulkExportableNormal() {
        #expect(AdjectiveSensitivity.normal.isBulkExportable)
    }

    @Test("isBulkExportable is true for .elevated — ADR-007 Decision 2 Normal tier")
    func isBulkExportableElevated() {
        #expect(AdjectiveSensitivity.elevated.isBulkExportable)
    }

    @Test("isBulkExportable is false for .restricted — ADR-007 Decision 2 Private tier")
    func isBulkExportableNotRestricted() {
        #expect(!AdjectiveSensitivity.restricted.isBulkExportable)
    }

    @Test("isBulkExportable is false for .secret — ADR-007 Decision 2 Secret tier")
    func isBulkExportableNotSecret() {
        #expect(!AdjectiveSensitivity.secret.isBulkExportable)
    }

    // MARK: - requiresOwnerKeyForBulk (Private tier — ADR-007 Decision 2)

    @Test("requiresOwnerKeyForBulk is false for .normal — ADR-007 Decision 2 Normal tier")
    func requiresOwnerKeyNormal() {
        #expect(!AdjectiveSensitivity.normal.requiresOwnerKeyForBulk)
    }

    @Test("requiresOwnerKeyForBulk is false for .elevated — ADR-007 Decision 2 Normal tier")
    func requiresOwnerKeyElevated() {
        #expect(!AdjectiveSensitivity.elevated.requiresOwnerKeyForBulk)
    }

    @Test("requiresOwnerKeyForBulk is true for .restricted — ADR-007 Decision 2 Private tier")
    func requiresOwnerKeyRestricted() {
        #expect(AdjectiveSensitivity.restricted.requiresOwnerKeyForBulk)
    }

    @Test("requiresOwnerKeyForBulk is false for .secret — ADR-007 Decision 2 Secret tier")
    func requiresOwnerKeySecret() {
        #expect(!AdjectiveSensitivity.secret.requiresOwnerKeyForBulk)
    }

    // MARK: - isExcludedFromBulk (Secret tier — ADR-007 Decision 2)

    @Test("isExcludedFromBulk is false for .normal — ADR-007 Decision 2 Normal tier")
    func isExcludedFromBulkNormal() {
        #expect(!AdjectiveSensitivity.normal.isExcludedFromBulk)
    }

    @Test("isExcludedFromBulk is false for .elevated — ADR-007 Decision 2 Normal tier")
    func isExcludedFromBulkElevated() {
        #expect(!AdjectiveSensitivity.elevated.isExcludedFromBulk)
    }

    @Test("isExcludedFromBulk is false for .restricted — ADR-007 Decision 2 Private tier")
    func isExcludedFromBulkRestricted() {
        #expect(!AdjectiveSensitivity.restricted.isExcludedFromBulk)
    }

    @Test("isExcludedFromBulk is true for .secret — ADR-007 Decision 2 Secret tier")
    func isExcludedFromBulkSecret() {
        #expect(AdjectiveSensitivity.secret.isExcludedFromBulk)
    }

    // MARK: - Exhaustiveness: exactly one tier predicate is true per value

    /// ADR-007 Decision 2 maps the four sensitivity values to three tiers.
    /// The three predicates must be mutually exclusive and collectively
    /// exhaustive: every case satisfies exactly one predicate.
    @Test("Each sensitivity value maps to exactly one privacy tier — ADR-007 Decision 2 exhaustiveness")
    func exhaustivenessEachValueMapsToExactlyOneTier() {
        let allCases: [AdjectiveSensitivity] = [.normal, .elevated, .restricted, .secret]
        for value in allCases {
            let trueCount = [
                value.isBulkExportable,
                value.requiresOwnerKeyForBulk,
                value.isExcludedFromBulk
            ].filter { $0 }.count
            #expect(trueCount == 1, "Expected exactly 1 true predicate for \(value) but got \(trueCount)")
        }
    }
}
