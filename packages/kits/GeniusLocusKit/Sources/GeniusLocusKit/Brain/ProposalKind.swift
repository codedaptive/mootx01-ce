import Foundation

// MARK: - ProposalKind

/// Typed vocabulary for the `kind` field on `ProposalFrame` and
/// `ProposeFrame`. Replaces the prior `String` field on both structs,
/// eliminating the stringly-typed surface and giving callers
/// exhaustive pattern matching over the Brain layer's proposal
/// taxonomy.
///
/// ## Case decisions (NK-1b Known Ambiguity 1)
///
/// Production labels — each maps to a stable raw string the Brain
/// layer's signal bodies use:
///   - `byReferenceDrift`     ↔ "by_reference_drift"
///   - `tournamentUpdate`     ↔ "tournament_update"
///   - `miningPattern`        ↔ "mining_pattern"
///   - `disciplineViolation`  ↔ "discipline_violation"
///   - `mutateCandidate`      ↔ "mutate_candidate"  (routed through propose per §11.1)
///
/// Test labels promoted to real cases (they appear at construction
/// sites and defeat the promotion if left as bare strings):
///   - `amend`                ↔ "amend"   — used twice in test files;
///                              looks like a real lifecycle label so
///                              it joins the public taxonomy.
///   - `testPropose`          ↔ "test_propose" — two test sites
///                              (StandingSignalSchedulerTests,
///                              scheduler_parity.rs); promoted to a
///                              named case so the tests compile against
///                              the typed enum without an unsafe
///                              string escape.
///
/// Stub placeholder:
///   - "k" appears once in scheduler_parity.rs as a single-character
///     placeholder inside class_tag_per_emission_matches_swift_strings.
///     It is not a production label and not a meaningful test label;
///     it is rendered via `.other("k")` at the Rust call site.
///
/// `other(String)` is the escape hatch for callers that carry a
/// raw kind label not enumerated above — for example, labels
/// emitted by a future Brain layer sub-mission before the vocabulary
/// enum is updated.  Round-trips cleanly through Codable: the wire
/// value is the wrapped string verbatim.
public enum ProposalKind: Sendable, Hashable, Codable {

    // MARK: Production labels

    /// Reference drift detected during the weekly byReference
    /// validation pass. Architecture spec §10 row 7 / §11.2.
    case byReferenceDrift

    /// Bradley-Terry weight update from the daily tournament.
    /// Architecture spec §6.5 / §6.7.
    case tournamentUpdate

    /// Mining-pattern candidate from the weekly NMF / dreaming run.
    /// Cookbook §15.1 rule 8.
    case miningPattern

    /// Forbidden-combination violation: sensitivity=secret AND
    /// exportability=public. Spec invariant I-3.
    case disciplineViolation

    /// Decay or state-transition candidate routed through propose for
    /// confirmation. Architecture spec §11.1: "mutate-candidate routed
    /// through `propose` for confirmation."
    case mutateCandidate

    /// Enrichment / Q-ID-assignment proposal. Filed by the maintenance
    /// daemon when deterministic re-inference cannot resolve a drawer's
    /// Wikidata Q-ID (cookbook §2.5; Q-ID-completion terminal workflow).
    /// Carries the drawer target and the resolved MDCC code as candidate
    /// context in the justification. Acceptance writes the human/agent-
    /// supplied Q-ID into the drawer's anchor and flips the enrichment
    /// status to `qidCompleted`.
    case enrichment

    // MARK: Test / lifecycle labels (public taxonomy)

    /// Amend proposal — used in verb-surface tests as a lifecycle label
    /// that covers the propose/amend path at the GLK boundary.
    case amend

    /// Test-propose — used in scheduler conformance tests to exercise
    /// the propose routing path. Named rather than left as a bare string
    /// so tests compile against the typed enum.
    case testPropose

    // MARK: Escape hatch

    /// Any label not enumerated above. Carries the raw string verbatim
    /// so it round-trips through SQLite and JSON without data loss.
    /// Use this for stub placeholders and labels emitted by future
    /// Brain layer sub-missions before they are added to the enum.
    case other(String)

    // MARK: Wire representation

    /// The stable string written to SQLite and used as the JSON
    /// encoding. Matches the prior bare-string values exactly so
    /// existing rows and conformance vectors round-trip without change.
    public var rawValue: String {
        switch self {
        case .byReferenceDrift:   return "by_reference_drift"
        case .tournamentUpdate:   return "tournament_update"
        case .miningPattern:      return "mining_pattern"
        case .disciplineViolation: return "discipline_violation"
        case .mutateCandidate:    return "mutate_candidate"
        case .enrichment:         return "enrichment"
        case .amend:              return "amend"
        case .testPropose:        return "test_propose"
        case .other(let s):       return s
        }
    }

    /// Decode from the stable raw string. All unrecognised strings
    /// are mapped to `.other(rawValue)` so decoding is total.
    public init(rawValue: String) {
        switch rawValue {
        case "by_reference_drift":   self = .byReferenceDrift
        case "tournament_update":    self = .tournamentUpdate
        case "mining_pattern":       self = .miningPattern
        case "discipline_violation": self = .disciplineViolation
        case "mutate_candidate":     self = .mutateCandidate
        case "enrichment":           self = .enrichment
        case "amend":                self = .amend
        case "test_propose":         self = .testPropose
        default:                     self = .other(rawValue)
        }
    }

    // MARK: Codable — single-value string so JSON / SQLite round-trip is the rawValue

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self.init(rawValue: raw)
    }
}
