// ModesManifest.swift
//
// The USER-OWNED modes-preference config stored as a JSON object under
// the "modes_config" manifest key per estate. The user (or a configuration
// tool) emits it via `GeniusLocusKit.provisionModesConfig(_:for:)`;
// AriaMcpKit reads it at session start with this precedence:
//
//   provisioned estate value > spec default (stickyEnabled=true, coachingCalls=25)
//
// An absent or malformed manifest key falls back to `ModesManifest.default`
// — no estate migration required. Partial JSON fills absent keys with spec
// defaults at decode time.
//
// Wire format: {"sticky_enabled": true, "coaching_calls": 25}  (snake_case).
// The value for sticky_enabled is a plain JSON bool stored as a config value,
// not a bitmap — this is a non-persisted config struct, not a database entity.

import Foundation

// MARK: - ModesManifest

/// User-owned per-estate modes-preference config stored under the
/// `"modes_config"` manifest key as a JSON object.
///
/// Two preferences are supported:
///
/// - `stickyEnabled` (`modes.sticky_enabled`, default `true`): when `false`,
///   mode declarations are accepted and may return a hint, but the sticky state
///   is never updated — advisory-only mode, same code path as absent sticky state.
///
/// - `coachingCalls` (`modes.coaching_calls`, default `25`, `0 = off`): how
///   many moot tool calls between periodic coaching blocks. The estate manifest
///   equivalent of a per-session counter override; `0` disables coaching entirely.
///
/// An estate with no `"modes_config"` key behaves exactly as before
/// (defaults: `stickyEnabled = true`, `coachingCalls = 25`). The provisioned
/// value is read by AriaMcpKit at session start via
/// `GeniusLocusKit.provisionedModesConfig(for:)`.
///
/// JSON wire keys are snake_case so the manifest is human-readable without a
/// code reference. Any key absent from the stored JSON is filled with the spec
/// default at decode time — a partial JSON object is safe.
public struct ModesManifest: Sendable, Equatable, Codable {

    // MARK: - Fields

    /// Whether sticky mode declarations persist across calls in a session.
    ///
    /// Default `true`. When `false`, every mode declaration is advisory-only:
    /// the hint is returned but the sticky state is never updated. The same
    /// code path as absent sticky state — one code path, two reasons.
    ///
    /// The estate manifest key is `modes.sticky_enabled`.
    public let stickyEnabled: Bool

    /// How many moot tool calls between periodic coaching blocks. `0` = off.
    ///
    /// Default `25`. The dispatch layer renders a deterministic coaching block
    /// from `CoachingSnapshot` every `coachingCalls` calls. Setting `0` suppresses
    /// all coaching blocks regardless of call count.
    ///
    /// The estate manifest key is `modes.coaching_calls`.
    public let coachingCalls: Int

    // MARK: - Default

    /// Spec-default config singleton. `stickyEnabled = true`, `coachingCalls = 25`.
    ///
    /// An estate with no `"modes_config"` manifest key resolves to this value —
    /// byte-identical to the pre-provisioning behaviour.
    public static let `default` = ModesManifest(stickyEnabled: true, coachingCalls: 25)

    // MARK: - Init

    /// Build a modes config. Both fields default to the spec constant so partial
    /// construction is safe.
    ///
    /// - Parameters:
    ///   - stickyEnabled: whether sticky mode declarations persist. Default `true`.
    ///   - coachingCalls: calls between coaching blocks. `0` = off. Default `25`.
    public init(stickyEnabled: Bool = true, coachingCalls: Int = 25) {
        self.stickyEnabled = stickyEnabled
        self.coachingCalls = coachingCalls
    }

    // MARK: - Coding keys

    /// Snake_case JSON keys so the manifest is human-readable and consistent
    /// with the other provisioned manifests (`door_config`, `recall_tuning`).
    enum CodingKeys: String, CodingKey {
        case stickyEnabled = "sticky_enabled"
        case coachingCalls = "coaching_calls"
    }

    // MARK: - Decode (fail-quiet partial JSON)

    /// Decode from JSON, filling any absent key with its spec default.
    ///
    /// A missing `sticky_enabled` key fills `true`; a missing `coaching_calls`
    /// key fills `25`. A negative `coaching_calls` is accepted as-is (the caller
    /// that writes it is responsible for meaning; the dispatch layer treats any
    /// value ≤ 0 as off). Mirrors the fail-quiet contract on `DoorManifest` and
    /// `RecallTuningManifest`.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stickyEnabled = (try c.decodeIfPresent(Bool.self, forKey: .stickyEnabled)) ?? true
        coachingCalls = (try c.decodeIfPresent(Int.self, forKey: .coachingCalls)) ?? 25
    }
}
