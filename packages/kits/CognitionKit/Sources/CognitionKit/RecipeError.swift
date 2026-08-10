// RecipeError.swift
//
// CognitionKit's single typed error enum (fleet convention: one error
// enum per owning module, never optionals-plus-logging). Reconciled
// from COGNITIONKIT_SPEC § 5 against shipped reality:
//
//   - `lowDivergenceScore` is DROPPED: it belonged only to ScenarioSkill,
//     which is out of scope (NeuronKit ships no `elicitFraming` to
//     produce a divergence score).
//   - `missingCapability` carries `NeuronKitCapability` (the real shipped
//     enum) rather than the spec's open-typed placeholder.
//   - `silentConceptLoss` carries the branch identity and the lost
//     concept ids — the MigrationBenchmark C-13 gate signal.
//
// All other cases match the spec's intent. Equatable so tests can assert
// the exact failure (e.g. promoting a disqualified branch throws
// `.silentConceptLoss`).

import Foundation
import GeniusLocusKit

/// Errors raised by CognitionKit recipes. The behavioural meaning of
/// each case lives in COGNITIONKIT_SPEC § 5; this is the shipped shape.
public enum RecipeError: Error, Sendable, Equatable, CustomStringConvertible {

    /// A required NeuronKit capability is not available in the host's
    /// capability set. Raised by `verifyCapabilities(...)` BEFORE any
    /// execution begins (spec § 2, B-5) — the recipe never partially
    /// executes.
    case missingCapability(NeuronKitCapability)

    /// A recipe that derives competing branches was given fewer inputs
    /// than it needs to run a meaningful comparison.
    case insufficientBranches(minimum: Int, provided: Int)

    /// Two or more plans share a name. Plan names key the branch map and
    /// the confirmation step, so a duplicate would silently collide and
    /// leak a derived branch; the recipe rejects it before deriving any.
    case duplicatePlanName(String)

    /// A migration plan's branch silently lost at least one origin
    /// concept (`BenchmarkReport.notFoundInBranch` was non-empty). The
    /// branch is disqualified from ranking; attempting to promote a
    /// disqualified branch raises this non-recoverable error (spec C-5).
    /// Carries the disqualified branch's id and the lost concept ids.
    case silentConceptLoss(branchID: BranchID, lostConcepts: [String])

    /// A tournament produced no rankable survivor (every branch was
    /// disqualified, or the input set was empty). Carries the count of
    /// disqualified branches for diagnosis.
    case tournamentNoWinner(disqualifiedCount: Int)

    /// A recipe reached a step requiring explicit human confirmation
    /// (branch promotion, multi-branch discard) and no confirmation was
    /// provided. Recipes never auto-confirm on the caller's behalf
    /// (spec B-3). `action` names the step that needs confirmation.
    case userConfirmationRequired(action: String)

    /// More migration plans than the recipe admits. Each plan derives a
    /// retained COW branch and runs concurrent heavy work, so an unbounded
    /// plan count is a resource-exhaustion vector. Refused before any
    /// branch is derived. Mirrors Rust `RecipeError::TooManyPlans`.
    case tooManyPlans(count: Int, maximum: Int)

    /// More origin entries than the recipe admits. Each entry is captured
    /// into every plan's branch, so an unbounded corpus is O(plans ×
    /// entries) work. Refused before any branch is derived. Mirrors Rust
    /// `RecipeError::TooManyOriginEntries`.
    case tooManyOriginEntries(count: Int, maximum: Int)

    /// A `cap` parameter was non-positive (zero or negative). `cap` is
    /// applied as `Array.prefix(cap)` — a negative value crashes the
    /// process (Swift range formation panic); zero produces an empty
    /// synthesis set, which is a vacuous result. Callers must pass
    /// `cap > 0` or omit it (nil = no cap). Mirrors Rust
    /// `RecipeError::InvalidCap`.
    case invalidCap(value: Int)

    public var description: String {
        switch self {
        case .missingCapability(let cap):
            return "RecipeError.missingCapability: NeuronKit capability '\(cap.rawValue)' is not available; recipe cannot run."
        case .insufficientBranches(let minimum, let provided):
            return "RecipeError.insufficientBranches: need at least \(minimum) branches, got \(provided)."
        case .duplicatePlanName(let name):
            return "RecipeError.duplicatePlanName: plan name '\(name)' appears more than once; plan names must be unique."
        case .silentConceptLoss(let branchID, let lostConcepts):
            return "RecipeError.silentConceptLoss: branch \(branchID) lost \(lostConcepts.count) concept(s): \(lostConcepts.joined(separator: ", "))."
        case .tournamentNoWinner(let disqualifiedCount):
            return "RecipeError.tournamentNoWinner: no rankable survivor (\(disqualifiedCount) branch(es) disqualified)."
        case .userConfirmationRequired(let action):
            return "RecipeError.userConfirmationRequired: '\(action)' requires explicit human confirmation."
        case .tooManyPlans(let count, let maximum):
            return "RecipeError.tooManyPlans: \(count) plans exceeds the maximum of \(maximum)."
        case .tooManyOriginEntries(let count, let maximum):
            return "RecipeError.tooManyOriginEntries: \(count) origin entries exceeds the maximum of \(maximum)."
        case .invalidCap(let value):
            return "RecipeError.invalidCap: cap must be > 0, got \(value); pass nil to synthesize without a cap."
        }
    }
}
