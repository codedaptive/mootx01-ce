import Foundation

/// A grant is the unit of sharing in the federation model.
///
/// Per DECISION_FEDERATION_SHARING_MODEL_2026-05-21 §6, a grant is an
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

/// The four custody modes from Appendix B. Modes 1 and 2 are
/// production at v1.0; modes 3 and 4 are v1.5 gate / experimental and
/// raise `experimentalModeNotActivated` at issue time unless IP
/// clearance is confirmed. With clearance, mode 3 issues (ENC-02) while
/// mode 4 still raises `hardwareNotSupported`.
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
    /// Mode 4: physical SRAM decay. Not implemented in v1.0.
    case physicalDecay(experimentalIPClearanceConfirmed: Bool)

    /// The `custody_mode` column discriminant and signing token.
    var signingToken: String {
        switch self {
        case .mediated:        return "mediated"
        case .handedOver:      return "handedOver"
        case .decayDerived:    return "decayDerived"
        case .physicalDecay:   return "physicalDecay"
        }
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
    /// A custody mode 3 or 4 grant was issued without
    /// `experimentalIPClearanceConfirmed: true`.
    case experimentalModeNotActivated
    /// Custody mode 4's key mechanic (SRAM physical decay) is not
    /// implemented; a clearance-confirmed mode-4 grant raises this. Mode
    /// 3's Lagrange derivation is implemented (ENC-02) and no longer
    /// raises this error.
    case hardwareNotSupported
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
}
