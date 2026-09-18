// DoorManifest.swift
//
// The OPTIMIZER-OWNED door-selection config stored as a JSON object under
// the "door_config" manifest key per estate. The quality optimizer emits
// it via `GeniusLocusKit.provisionDoorConfig(_:for:)`; the product reads
// it at recall time with this precedence chain:
//
//   explicit door arg > explicit scoring arg > provisioned estate default > matrixAware spec default
//
// An absent or malformed manifest key falls back to `.matrixAware` (the
// current spec constant) — no estate migration required. Partial JSON fills
// absent keys with spec defaults at decode time.
//
// Wire format: {"scoring":"rrf"} (snake_case; the quality optimizer's
// door-recommend output format).

import Foundation

// MARK: - DoorManifest

/// Optimizer-owned per-estate door-selection config stored under the
/// `"door_config"` manifest key as a JSON object.
///
/// The quality optimizer emits this value via
/// `GeniusLocusKit.provisionDoorConfig(_:for:)` after a full-coverage arm
/// comparison. The product reads it on every `moot_memory_search` call when
/// no explicit `door` or `scoring` argument is supplied (the A1 per-corpus
/// static config tier of the front-door family).
///
/// An estate with no `"door_config"` key behaves exactly as before
/// (defaults to `matrixAware`). The optimizer emits this value after a
/// full-coverage arm comparison; without a config the estate runs on the
/// spec-constant default.
///
/// JSON wire keys are snake_case so the manifest is readable without a code
/// reference. Any key absent from the stored JSON is filled with the spec
/// default at decode time — a partial JSON object is safe.
public struct DoorManifest: Sendable, Equatable, Codable {

    // MARK: - Fields

    /// Scoring strategy to apply when no explicit `door` or `scoring` argument
    /// is supplied by the caller. Defaults to `.matrixAware` (the current
    /// spec constant) when absent from the stored JSON.
    ///
    /// The optimizer selects the value that won in the registered arm comparison
    /// for this corpus (e.g. `.rrf` on every full-coverage lane measured in
    /// P1a/P2e). The product only reads this value — the benchmarker/optimizer
    /// split means the product never computes or overrides the selection.
    public let scoring: GLKRecallScoring

    // MARK: - Default

    /// Spec-default config singleton. Scoring = `.matrixAware`, matching
    /// today's hardcoded default. An estate with no `"door_config"` manifest
    /// key resolves to this value — byte-identical to the pre-front-door
    /// behaviour.
    public static let `default` = DoorManifest(scoring: .matrixAware)

    // MARK: - Init

    /// Build a door config. Scoring defaults to `.matrixAware` so partial
    /// construction is safe.
    ///
    /// - Parameter scoring: the scoring strategy the optimizer selected as
    ///   the winner for this corpus.
    public init(scoring: GLKRecallScoring = .matrixAware) {
        self.scoring = scoring
    }

    // MARK: - Coding keys

    /// Snake_case JSON keys so the manifest is human-readable and matches
    /// the quality-optimizer's emitted format.
    enum CodingKeys: String, CodingKey {
        case scoring = "scoring"
    }

    // MARK: - Decode (fail-quiet partial JSON)

    /// Decode from JSON, filling any absent key with its spec default.
    /// An unknown `scoring` string (e.g. from a future kit version) falls
    /// back to `.matrixAware` — a bad provision must degrade to today's
    /// nominal default rather than breaking recall. Mirrors the fail-quiet
    /// contract on `RecallTuningManifest` and `lane_weights`.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let rawScoring = try c.decodeIfPresent(String.self, forKey: .scoring),
           let parsed = GLKRecallScoring(rawValue: rawScoring) {
            scoring = parsed
        } else {
            scoring = .matrixAware
        }
    }
}
