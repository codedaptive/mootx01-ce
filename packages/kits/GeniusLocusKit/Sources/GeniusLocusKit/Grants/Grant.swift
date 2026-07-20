import Foundation

/// A grant is the unit of sharing in the federation model.
///
/// Per federation disclosure controls, a grant is an
/// explicit, signed, audited row naming the grantee, the scope
/// granularity, the content level, the lifetime, the custody mode, the
/// re-share permission, and the remaining inference budget. The row is
/// signed by the issuing estate's Ed25519 identity key (§8 of the
/// ConvergenceKit design decision) so a recipient can verify provenance
/// without contacting the issuer.
public struct Grant: Sendable, Codable, Equatable {

    /// Stable identifier for this grant.
    public let id: UUID

    /// The paired estate this grant is issued to.
    public let granteeEstateID: UUID

    /// What the grant exposes — whole estate down to a single row.
    public let scope: GrantScope

    /// Content-axis position the grant exposes, per §4.1. A plain Int
    /// rather than a typed enum because the content axis is an open
    /// ordinal the federation layer does not interpret here.
    public let contentLevel: Int

    /// How long the grant lives. See `GrantLifetime`.
    public let lifetime: GrantLifetime

    /// Which custody mode governs the scope key. Modes 1 and 2 are
    /// production at v1.0; 3 and 4 are gated.
    public let custodyMode: CustodyMode

    /// Whether the grantee may re-share, and under what audit.
    public let reSharePermission: ReSharePermission

    /// Remaining inference budget for the grantee, per §6. A fraction
    /// in [0, 1]; the federation layer debits it as inference is spent.
    public let inferenceRemainingBudget: Double

    /// When the grant was issued. Passed in from the verb's `now`
    /// parameter so issuance is deterministic and testable.
    public let issuedAt: Date

    /// Ed25519 signature over `signingPayload`, produced by the issuing
    /// estate's identity key.
    public let signature: Data

    public init(
        id: UUID,
        granteeEstateID: UUID,
        scope: GrantScope,
        contentLevel: Int,
        lifetime: GrantLifetime,
        custodyMode: CustodyMode,
        reSharePermission: ReSharePermission,
        inferenceRemainingBudget: Double,
        issuedAt: Date,
        signature: Data
    ) {
        self.id = id
        self.granteeEstateID = granteeEstateID
        self.scope = scope
        self.contentLevel = contentLevel
        self.lifetime = lifetime
        self.custodyMode = custodyMode
        self.reSharePermission = reSharePermission
        self.inferenceRemainingBudget = inferenceRemainingBudget
        self.issuedAt = issuedAt
        self.signature = signature
    }

    /// The exact bytes the issuing estate signs and a recipient
    /// verifies. Built deterministically from every grant field except
    /// the signature itself, so the same grant always produces the same
    /// payload on any platform. A pipe-delimited canonical string
    /// (UTF-8) is used rather than `JSONEncoder` so the encoding is
    /// non-throwing and free of key-ordering ambiguity; the signature
    /// covers identity, grantee, scope, content level, lifetime,
    /// custody mode, re-share permission, budget, and issue time.
    public var signingPayload: Data {
        Self.canonicalPayload(
            id: id,
            granteeEstateID: granteeEstateID,
            scope: scope,
            contentLevel: contentLevel,
            lifetime: lifetime,
            custodyMode: custodyMode,
            reSharePermission: reSharePermission,
            inferenceRemainingBudget: inferenceRemainingBudget,
            issuedAt: issuedAt
        )
    }

    /// Canonical signing bytes for the supplied field set. Shared by the
    /// `signingPayload` accessor and the issue path so issuance and
    /// verification encode identically.
    static func canonicalPayload(
        id: UUID,
        granteeEstateID: UUID,
        scope: GrantScope,
        contentLevel: Int,
        lifetime: GrantLifetime,
        custodyMode: CustodyMode,
        reSharePermission: ReSharePermission,
        inferenceRemainingBudget: Double,
        issuedAt: Date
    ) -> Data {
        // `issuedAt` is rendered as fractional seconds since the
        // reference date: a fixed numeric form independent of locale,
        // calendar, and time zone, so the bytes are identical wherever
        // they are produced or verified.
        let fields: [String] = [
            "grant-v1",
            id.uuidString,
            granteeEstateID.uuidString,
            scope.signingToken,
            String(contentLevel),
            lifetime.signingToken,
            custodyMode.signingToken,
            reSharePermission.signingToken,
            String(inferenceRemainingBudget),
            String(issuedAt.timeIntervalSinceReferenceDate)
        ]
        return Data(fields.joined(separator: "|").utf8)
    }
}

/// The granularity a grant exposes, per §6 scope axis.
public enum GrantScope: Sendable, Codable, Equatable {
    case wholeEstate
    case wing(String)
    case room(String)
    case latticeSubtree(udcCode: String)
    case singleRow(UUID)

    /// Deterministic token for the signing payload and the
    /// `scope_json` column's discriminant.
    var signingToken: String {
        switch self {
        case .wholeEstate:                 return "estate"
        case .wing(let name):              return "wing:\(name)"
        case .room(let name):              return "room:\(name)"
        case .latticeSubtree(let code):    return "lattice:\(code)"
        case .singleRow(let id):           return "row:\(id.uuidString)"
        }
    }
}

/// How long a grant lives, per §7.
public enum GrantLifetime: Sendable, Codable, Equatable {
    case permanent
    case until(Date)
    /// Decay window in seconds for custody modes 3/4; unused in v1.0.
    case decayWindow(seconds: Int)

    /// Deterministic token for the signing payload.
    var signingToken: String {
        switch self {
        case .permanent:               return "permanent"
        case .until(let date):         return "until:\(date.timeIntervalSinceReferenceDate)"
        case .decayWindow(let seconds): return "decay:\(seconds)"
        }
    }

    /// The instant this lifetime expires relative to `issuedAt`, or
    /// `nil` if it never expires. `decayWindow` is measured from
    /// `issuedAt`; `until` is absolute and ignores `issuedAt`.
    func expiry(issuedAt: Date) -> Date? {
        switch self {
        case .permanent:                return nil
        case .until(let date):          return date
        case .decayWindow(let seconds): return issuedAt.addingTimeInterval(TimeInterval(seconds))
        }
    }
}

/// The four custody modes (Appendix B). Modes 1 and 2 are production;
/// mode 3 is experimental gated behind `experimentalIPClearanceConfirmed`;
/// mode 4 is the time-aging decay policy.
///
/// Mode 4 — time-aging decay (`timeAging`). The original Appendix B mode 4
/// modelled physical SRAM decay: an estate handed a grant whose effective
/// capability *attenuates over time* the way data retention in an unpowered
/// SRAM cell decays (the TARDIS technique, USENIX 2012). SRAM hardware is
/// not available on any beta surface, so the shipped policy is a
/// deterministic SOFTWARE time-aging model with the same semantics:
/// the grant's effective content level decays as a half-life function of the
/// elapsed time since `decayStartedAt`, floored at `decayFloor`. The
/// attenuation is computed against an injected `now` (no wall-clock read), so
/// it is reproducible and bit-comparable across ports. See
/// `Grant.effectiveContentLevel(now:)` for the policy.
///
/// The legacy `"physicalDecay"` discriminant token decodes INTO this mode:
/// the mode-4 slot was never removed from the schema, and a legacy row with
/// no decay fields receives documented defaults (see `GrantStore`).
public enum CustodyMode: Sendable, Codable, Equatable {
    /// Mode 1: the scope key never leaves custody; every read is a live
    /// request; clawback is cryptographic.
    case mediated
    /// Mode 2: the scope key is derived once and handed to the
    /// recipient; offline access in window; clawback is best-effort.
    case handedOver
    /// Mode 3: decay-derived (Lagrange threshold over GF(p); "Shamir" is
    /// the same math, a naming synonym). Implemented experimentally
    /// (ENC-02), gated behind `experimentalIPClearanceConfirmed`.
    case decayDerived(threshold: Int, totalShares: Int,
                      driftRatePerDay: DriftRate,
                      experimentalIPClearanceConfirmed: Bool)
    /// Mode 4: time-aging decay. The grant's effective content level
    /// attenuates as a half-life function of elapsed time, floored at
    /// `floor`. Software analogue of the original SRAM physical-decay
    /// model (TARDIS); decay is deterministic in injected `now`. See
    /// `DecayPolicy` for the field semantics.
    case timeAging(DecayPolicy)

    /// The signing token: identity, grantee, scope, and all custody
    /// parameters the signature must cover. For `timeAging` the decay policy
    /// fields ride in the token so a tampered half-life, start instant, or
    /// floor breaks signature verification.
    var signingToken: String {
        switch self {
        case .mediated:     return "mediated"
        case .handedOver:   return "handedOver"
        case .decayDerived: return "decayDerived"
        case .timeAging(let policy): return "timeAging|\(policy.signingToken)"
        }
    }

    /// The bare `custody_mode` column discriminant — the persisted token
    /// without associated values. Mode 3's and mode 4's parameters live in
    /// dedicated columns (mode 3: GRT-01 known non-persistence; mode 4: the
    /// `decay_*` columns), so the column stores only the discriminant.
    var columnToken: String {
        switch self {
        case .mediated:     return "mediated"
        case .handedOver:   return "handedOver"
        case .decayDerived: return "decayDerived"
        case .timeAging:    return "timeAging"
        }
    }
}

/// Parameters of the mode-4 time-aging custody policy.
///
/// A grant under `CustodyMode.timeAging` exposes a content level that
/// attenuates over time. The effective level at instant `now` is
///
///     effective = max(floor, round(baseLevel * 0.5^(elapsed / halfLifeSeconds)))
///
/// where `elapsed = max(0, now - startedAt)` and `baseLevel` is the grant's
/// persisted `contentLevel`. The half-life form mirrors the matrix-calibration
/// decay (math treatise §8): the multiplicative factor `0.5^(elapsed/halfLife)`
/// halves the surviving capability every `halfLifeSeconds`. The fraction is
/// computed in `Double` but the result is rounded to an integer content level
/// so both ports produce identical discrete values from identical fixtures.
///
/// `floor` is the minimum content level the grant decays toward — the residual
/// capability that never ages away. A grant whose effective level reaches `0`
/// (only possible when `floor == 0`) is treated as fully decayed and refused on
/// the recall path. A positive `floor` keeps the grant usable indefinitely at
/// the floor level.
public struct DecayPolicy: Sendable, Codable, Equatable {
    /// Default half-life for a legacy mode-4 row with no persisted decay
    /// fields: 30 days in seconds. Chosen to match the matrix-calibration
    /// decay default (math treatise §8, `halfLifeDays = 30.0`) so the one
    /// decay constant the substrate documents is reused rather than invented.
    public static let defaultHalfLifeSeconds = 30 * 24 * 60 * 60

    /// Half-life of the capability in whole seconds. Every `halfLifeSeconds`
    /// of elapsed time halves the surviving (above-floor) content level.
    /// Must be positive; a non-positive value is clamped to 1 second by the
    /// effective-level math so the formula never divides by zero.
    public let halfLifeSeconds: Int

    /// The instant decay is measured from. Persisted explicitly so the decay
    /// clock is independent of the grant's `issuedAt`; a legacy row with no
    /// decay fields documents `startedAt = issuedAt` (see `GrantStore`).
    public let startedAt: Date

    /// The minimum content level the grant decays toward. `0` means the grant
    /// can decay to no access (and is refused once it reaches the floor); a
    /// positive value is a permanent residual capability.
    public let floor: Int

    public init(halfLifeSeconds: Int, startedAt: Date, floor: Int) {
        self.halfLifeSeconds = halfLifeSeconds
        self.startedAt = startedAt
        self.floor = floor
    }

    /// Deterministic token fragment for the signing payload. The instant is
    /// rendered as fractional seconds since the reference date — the same
    /// locale/calendar/timezone-independent numeric form the grant uses for
    /// `issuedAt`, so the bytes are identical on every platform.
    var signingToken: String {
        "halfLife:\(halfLifeSeconds)|start:\(startedAt.timeIntervalSinceReferenceDate)|floor:\(floor)"
    }

    /// The effective content level of a `baseLevel` capability at `now`.
    ///
    /// Deterministic in `now`: `elapsed` is clamped to a non-negative value so a
    /// `now` before `startedAt` yields the undecayed `baseLevel`, and a
    /// non-positive `halfLifeSeconds` is clamped to 1 so the exponent is always
    /// finite. The surviving level is `baseLevel * 0.5^(elapsed/halfLife)`,
    /// rounded to the nearest integer (`.toNearestOrAwayFromZero`, matching the
    /// Rust `round()` so both ports agree on the discrete value), then floored
    /// at `floor`.
    ///
    /// The result is additionally capped at `baseLevel` so a persisted `floor`
    /// that exceeds the original grant level (e.g., a corrupt row or a tampered
    /// policy) cannot raise effective access above what was granted. Decay is
    /// strictly attenuating — `effectiveLevel` never returns more than `baseLevel`.
    func effectiveLevel(baseLevel: Int, now: Date) -> Int {
        let elapsed = max(0.0, now.timeIntervalSince(startedAt))
        let halfLife = Double(max(1, halfLifeSeconds))
        let surviving = Double(baseLevel) * pow(0.5, elapsed / halfLife)
        let rounded = Int(surviving.rounded(.toNearestOrAwayFromZero))
        // Cap at baseLevel: time-aging is strictly attenuating — floor must not
        // raise access above the original grant's content level even if the
        // persisted decay_floor column contains a value that exceeds contentLevel.
        return min(baseLevel, max(floor, rounded))
    }
}

/// Whether and how a grantee may re-share, per §6.
public enum ReSharePermission: Sendable, Codable, Equatable {
    case none
    case withAudit
    case free

    var signingToken: String {
        switch self {
        case .none:      return "none"
        case .withAudit: return "withAudit"
        case .free:      return "free"
        }
    }
}

/// Drift rate for custody mode 3's decay schedule — how fast the xi
/// shares corrupt, which sets the (probabilistic) key lifetime. Consumed
/// by the share provider's decay schedule (ENC-02).
public enum DriftRate: Sendable, Codable, Equatable {
    case slow, moderate, fast
}

/// Options for issuing a grant.
///
/// Note: `granteeEstateID` is part of the options because the verb
/// surface (`issueGrant(_:_:)`) takes only the issuing estate's handle
/// and these options; the grantee is the one party not otherwise
/// derivable at the call site.
public struct GrantOptions: Sendable {
    public let granteeEstateID: UUID
    public let scope: GrantScope
    public let custodyMode: CustodyMode
    public let lifetime: GrantLifetime
    public let contentLevel: Int
    public let reSharePermission: ReSharePermission

    public init(
        granteeEstateID: UUID,
        scope: GrantScope,
        custodyMode: CustodyMode = .mediated,
        lifetime: GrantLifetime = .permanent,
        contentLevel: Int = 0,
        reSharePermission: ReSharePermission = .none
    ) {
        self.granteeEstateID = granteeEstateID
        self.scope = scope
        self.custodyMode = custodyMode
        self.lifetime = lifetime
        self.contentLevel = contentLevel
        self.reSharePermission = reSharePermission
    }
}

/// Errors raised by the grant surface.
public enum GrantError: Error, Sendable, Equatable {
    /// The grant was revoked; the scope key is no longer available.
    case grantRevoked(id: UUID)
    /// The grant's lifetime has elapsed.
    case grantExpired(id: UUID)
    /// A mode-3 (decay-derived) grant was issued without
    /// `experimentalIPClearanceConfirmed: true`.
    case experimentalModeNotActivated
    /// No grant with the given id is on record.
    case grantNotFound(id: UUID)
    /// Mode 1: the originating estate is offline so the live key
    /// request cannot be served.
    case scopeKeyUnavailable(id: UUID)
    /// Custody mode 3: the xi shares drifted past threshold K, so the
    /// decay-derived scope key is permanently unrecoverable — no partial
    /// recovery is attempted (Appendix B.7). Distinct from
    /// `UnifiedAuditVerb.keyDecayed`, which is the audit event, not an
    /// error: this case is a different symbol in a different type.
    case keyDecayed
    /// A mode-3 (decay-derived) grant was issued with degenerate custody
    /// parameters: `threshold` must be > 0, `totalShares` must be ≥
    /// `threshold`, and `totalShares` must not exceed `maxDecayShares`
    /// (255). A zero threshold or a totalShares < threshold causes
    /// LagrangeDecayKey.reconstruct to interpolate an empty point set,
    /// producing DecayFieldElement.zero — a constant anyone can precompute
    /// (planned security hardening — B1, finding #2).
    case invalidCustodyParameters
}
