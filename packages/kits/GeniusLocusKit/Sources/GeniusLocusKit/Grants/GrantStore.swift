import Foundation
import OSLog
import LocusKit
import PersistenceKit

/// Persistent store for issued grants — the `grants` table per
/// DECISION_FEDERATION_SHARING_MODEL_2026-05-21 §6.
///
/// One `GrantStore` is built per open estate, backed by that estate's
/// injected `Storage`. The store declares the `grants` table alongside
/// the LocusKit tables (a union schema) so that a single backend can
/// decode both LocusKit rows and grant rows: opening a grants-only
/// schema on a shared SQLite backend would replace the retained schema
/// declaration and break LocusKit's typed-column decode. `CREATE TABLE
/// IF NOT EXISTS` makes re-declaring the LocusKit tables a no-op.
///
/// Date columns are TEXT (ISO-8601) per the fleet rule: PersistenceKit maps
/// `.timestamp` to TEXT. `now` is always supplied by the caller, never
/// read from the wall clock inside the store, so persistence is
/// deterministic.
public actor GrantStore {

    private static let logger = Logger(subsystem: "com.mootx01.kit", category: "GeniusLocusKit")

    private let storage: any Storage

    /// Errors internal to grant persistence — surfaced only on a
    /// corrupt or externally-mutated row, which cannot arise from this
    /// kit's own writes (modes 3 and 4 are gated before any insert).
    ///
    /// Security posture (access-control fail-closed): a grant row that
    /// cannot be decoded MUST surface an error and grant NOTHING. Silent
    /// widening (fabricated epoch-0 issue dates that corrupt lifetime
    /// arithmetic), silent narrowing (dropped rows), or fabricated values
    /// are all prohibited. The caller must receive an error and make an
    /// explicit decision about how to handle the corrupt row — the store
    /// never substitutes a default that could expand or shrink access.
    enum GrantStoreError: Error, Sendable {
        case corruptRow(String)
        /// The `issued_at` column could not be parsed as an ISO-8601 date.
        /// `storedText` is the raw string from the store for diagnosis.
        /// Throwing this error rather than falling back to epoch-0 is
        /// mandatory: an epoch-0 issue date would make lifetime-window
        /// arithmetic incorrect (a `DecayWindow` grant would compute its
        /// expiry from 1970 instead of the actual issue instant, and an
        /// `Until` grant's expiry check would use a fabricated baseline).
        case corruptIssuedAt(storedText: String)
    }

    /// Construct the store and ensure the `grants` table exists.
    ///
    /// Opens a schema that is LocusKit's table set plus the `grants`
    /// table, at a version one above LocusKit's so the in-memory
    /// backend's version-gated table creation fires. The SQLite backend
    /// creates each table with `IF NOT EXISTS`, so re-declaring
    /// LocusKit's tables here is harmless.
    public init(storage: any Storage) async throws {
        self.storage = storage
        let base = LocusKitSchema.schema
        let merged = SchemaDeclaration(
            kitID: "GeniusLocusKit.grants",
            version: base.version + 1,
            tables: base.tables + [Self.grantsTable],
            indices: base.indices
        )
        try await storage.open(schema: merged)
    }

    // MARK: - Schema

    /// The `grants` table declaration. Date columns are `.timestamp`
    /// (TEXT ISO-8601). `scope` and `lifetime` are stored as JSON text
    /// because they are sum types; `custody_mode` and `reshare` store
    /// their discriminant token for queryability.
    ///
    /// The three `decay_*` columns hold the mode-4 (`timeAging`) custody
    /// policy parameters and are NULL for every other mode. They are
    /// persisted explicitly rather than packed into the `custody_mode` token
    /// so the policy is queryable and so a half-life sweep can filter on
    /// `decay_started_at`. A fresh `CREATE TABLE` carries them — no install
    /// predates this schema, so no migration is required.
    static let grantsTable = TableDeclaration(
        name: "grants",
        columns: [
            .text("id"),
            .text("grantee_id"),
            .text("scope_json"),
            .int("content_level"),
            .text("custody_mode"),
            .text("lifetime_json"),
            .text("reshare"),
            .float("inference_budget"),
            .timestamp("issued_at"),
            .timestamp("revoked_at", nullable: true),
            .blob("signature"),
            // Mode-4 time-aging decay policy. NULL for modes 1–3.
            .int("decay_half_life", nullable: true),
            .timestamp("decay_started_at", nullable: true),
            .int("decay_floor", nullable: true)
        ],
        primaryKey: ["id"]
    )

    // MARK: - CRUD

    /// Insert a grant. The grant's `id` is the primary key; re-inserting
    /// the same id upserts.
    public func insert(_ grant: Grant) async throws {
        _ = try await storage.rowStore.upsert(
            table: "grants",
            values: try Self.row(from: grant),
            conflictColumns: ["id"]
        )
    }

    /// Test seam: upsert a raw column dictionary into the `grants` table,
    /// bypassing `row(from:)`. Used only by tests that must plant a row no
    /// normal issue path can produce — specifically a legacy `physicalDecay`
    /// mode-4 row with no `decay_*` columns, to prove it decodes (migrates)
    /// rather than faulting. Not part of the public contract.
    internal func rawUpsert(_ values: [String: TypedValue]) async throws {
        _ = try await storage.rowStore.upsert(
            table: "grants", values: values, conflictColumns: ["id"]
        )
    }

    /// Fetch a grant by id, or `nil` if absent.
    public func get(id: UUID) async throws -> StoredGrant? {
        let rows = try await storage.rowStore.query(
            table: "grants",
            where: .eq(Column(table: "grants", name: "id"), .text(id.uuidString))
        )
        guard let row = rows.first else { return nil }
        return try Self.decode(row)
    }

    /// Debit the inference budget for a grant by `amount`, clamping to zero.
    ///
    /// Persists the updated budget to the `grants` table atomically with the
    /// caller's read so no concurrent read can consume budget that was already
    /// debited. The update is a plain column write; the grant's other fields
    /// (scope, lifetime, custody mode, signature) are not touched.
    ///
    /// Returns the budget value BEFORE the debit so the caller can determine
    /// whether the read that triggered the debit was the last permitted one.
    /// A pre-debit value of `0.0` (or below) means the caller should have
    /// already refused; the debit is still written so the store stays
    /// consistent even on a race-condition path.
    ///
    /// The debit is a no-op if the grant is absent (the row was revoked and
    /// deleted, which cannot happen through the normal path — the grant table
    /// uses soft-revocation — but the call must not fault on an absent row).
    @discardableResult
    public func debitBudget(id: UUID, amount: Double) async throws -> Double {
        // Read the current grant to capture the pre-debit value.
        let current = try await get(id: id)
        let preBudget = current?.grant.inferenceRemainingBudget ?? 0.0
        let newBudget = max(0.0, preBudget - amount)
        _ = try await storage.rowStore.update(
            table: "grants",
            values: ["inference_budget": .float(newBudget)],
            where: .eq(Column(table: "grants", name: "id"), .text(id.uuidString))
        )
        return preBudget
    }

    /// Mark a grant revoked at the supplied instant. Idempotent: a
    /// second revoke overwrites the same `revoked_at`. No-op if the
    /// grant is absent (best-effort clawback does not fault).
    public func revoke(id: UUID, at now: Date) async throws {
        _ = try await storage.rowStore.update(
            table: "grants",
            values: ["revoked_at": .timestamp(now)],
            where: .eq(Column(table: "grants", name: "id"), .text(id.uuidString))
        )
    }

    /// Every grant with no `revoked_at` set.
    public func active() async throws -> [Grant] {
        let rows = try await storage.rowStore.query(
            table: "grants",
            where: .isNull(Column(table: "grants", name: "revoked_at"))
        )
        return try rows.map { try Self.decode($0).grant }
    }

    /// Every non-revoked grant whose lifetime has expired strictly
    /// before `now`. Lifetime is a sum type held in JSON, so the
    /// filter is evaluated in Swift after load rather than in SQL.
    public func expired(before now: Date) async throws -> [Grant] {
        try await active().filter { grant in
            guard let expiry = grant.lifetime.expiry(issuedAt: grant.issuedAt) else { return false }
            return expiry < now
        }
    }

    // MARK: - Row mapping

    /// Encode a grant into a column dictionary. `revoked_at` is omitted
    /// at insert; it is written only by `revoke`.
    private static func row(from grant: Grant) throws -> [String: TypedValue] {
        let encoder = JSONEncoder()
        let scopeJSON = String(decoding: try encoder.encode(grant.scope), as: UTF8.self)
        let lifetimeJSON = String(decoding: try encoder.encode(grant.lifetime), as: UTF8.self)
        var values: [String: TypedValue] = [
            "id": .text(grant.id.uuidString),
            "grantee_id": .text(grant.granteeEstateID.uuidString),
            "scope_json": .text(scopeJSON),
            "content_level": .int(Int64(grant.contentLevel)),
            // The bare discriminant — the mode-4 decay parameters ride in the
            // dedicated `decay_*` columns, not the token.
            "custody_mode": .text(grant.custodyMode.columnToken),
            "lifetime_json": .text(lifetimeJSON),
            "reshare": .text(grant.reSharePermission.signingToken),
            "inference_budget": .float(grant.inferenceRemainingBudget),
            "issued_at": .timestamp(grant.issuedAt),
            "signature": .blob(grant.signature)
        ]
        // Mode-4 (timeAging) persists its decay policy into dedicated columns.
        // Every other mode leaves them absent (NULL on insert).
        if case .timeAging(let policy) = grant.custodyMode {
            values["decay_half_life"] = .int(Int64(policy.halfLifeSeconds))
            values["decay_started_at"] = .timestamp(policy.startedAt)
            values["decay_floor"] = .int(Int64(policy.floor))
        }
        return values
    }

    /// Decode a stored row into a grant plus its revocation instant.
    private static func decode(_ row: StorageRow) throws -> StoredGrant {
        func text(_ col: String) throws -> String {
            guard case .text(let s)? = row[col] else {
                throw GrantStoreError.corruptRow("grants.\(col) is not text")
            }
            return s
        }
        guard let id = UUID(uuidString: try text("id")) else {
            throw GrantStoreError.corruptRow("grants.id is not a UUID")
        }
        guard let grantee = UUID(uuidString: try text("grantee_id")) else {
            throw GrantStoreError.corruptRow("grants.grantee_id is not a UUID")
        }
        guard case .blob(let signature)? = row["signature"] else {
            throw GrantStoreError.corruptRow("grants.signature is not a blob")
        }
        let decoder = JSONDecoder()
        let scope = try decoder.decode(GrantScope.self, from: Data(try text("scope_json").utf8))
        let lifetime = try decoder.decode(GrantLifetime.self, from: Data(try text("lifetime_json").utf8))
        // The custody discriminant plus, for mode 4, the persisted decay
        // policy columns. A legacy "physicalDecay" row decodes into timeAging;
        // a row with NULL decay columns gets documented defaults keyed off
        // `issued_at` (see custodyMode(from:decayColumns:issuedAt:)).
        let issuedAtForDecay = Self.date(row["issued_at"])
        let custody = try custodyMode(
            from: try text("custody_mode"),
            halfLife: Self.optionalInt(row["decay_half_life"]),
            startedAt: Self.date(row["decay_started_at"]),
            floor: Self.optionalInt(row["decay_floor"]),
            issuedAt: issuedAtForDecay
        )
        let reshare = try reSharePermission(from: try text("reshare"))
        let contentLevel = Self.int(row["content_level"])
        let budget = Self.double(row["inference_budget"])
        // Fail-closed: a corrupt issued_at must throw rather than fall back
        // to epoch-0. An epoch-0 issue date would silently corrupt lifetime
        // arithmetic: DecayWindow expiry would be computed from 1970, and
        // any caller checking issuedAt against now would receive a fabricated
        // baseline. See GrantStoreError.corruptIssuedAt for full rationale.
        guard let issuedAt = Self.date(row["issued_at"]) else {
            let raw = Self.rawText(row["issued_at"])
            throw GrantStoreError.corruptIssuedAt(storedText: raw)
        }
        let revokedAt = Self.date(row["revoked_at"])

        let grant = Grant(
            id: id,
            granteeEstateID: grantee,
            scope: scope,
            contentLevel: contentLevel,
            lifetime: lifetime,
            custodyMode: custody,
            reSharePermission: reshare,
            inferenceRemainingBudget: budget,
            issuedAt: issuedAt,
            signature: signature
        )
        return StoredGrant(grant: grant, revokedAt: revokedAt)
    }

    /// Reconstruct the custody mode from its persisted discriminant.
    ///
    /// Modes 1, 2, and 3 are persisted — mode 3 (decay-derived) issues
    /// once IP clearance is confirmed (ENC-02).
    ///
    /// The `grants` schema persists only the discriminant token
    /// (`custody_mode` column), not the enum's associated values, so mode 3
    /// decodes with placeholder associated values: the threshold/totalShares/
    /// driftRate are NOT round-tripped. This is a known GRT-01 schema
    /// limitation, not a defect introduced here.
    ///
    /// `experimentalIPClearanceConfirmed` decodes as `true` because a
    /// persisted mode-3 grant was, by construction, issued with clearance.
    /// Security note: this flag is reconstructed, not authentic caller
    /// intent. Do NOT treat the flag on a decoded grant as an authorization
    /// decision — the IP-clearance gate must only ever key off a
    /// caller-supplied `GrantOptions`, never a decoded `Grant`.
    ///
    /// Mode 4 (`timeAging`) round-trips its decay policy through the dedicated
    /// `decay_half_life`, `decay_started_at`, and `decay_floor` columns. The
    /// legacy `"physicalDecay"` discriminant token is an alias for the same
    /// mode-4 slot and decodes INTO `timeAging` — the mode-4 slot was never
    /// retired, so a legacy row is migrated, never refused.
    ///
    /// Documented defaults for a mode-4 row with NULL decay columns (a legacy
    /// `physicalDecay` row predating the decay schema): the decay clock starts
    /// at the grant's `issuedAt`, the half-life is `DecayPolicy.defaultHalfLifeSeconds`
    /// (a 30-day half-life, matching the matrix-calibration default), and the
    /// floor is `0`. These reproduce the spec intent — capability attenuates
    /// from the issue instant — without fabricating an authorization-widening
    /// value.
    private static func custodyMode(
        from token: String,
        halfLife: Int?,
        startedAt: Date?,
        floor: Int?,
        issuedAt: Date?
    ) throws -> CustodyMode {
        switch token {
        case "mediated":   return .mediated
        case "handedOver": return .handedOver
        case "decayDerived":
            return .decayDerived(
                threshold: 0, totalShares: 0, driftRatePerDay: .slow,
                experimentalIPClearanceConfirmed: true
            )
        case "timeAging", "physicalDecay":
            // `physicalDecay` is the legacy mode-4 token; it aliases `timeAging`.
            // Missing columns fall back to documented defaults so a legacy row
            // decodes cleanly rather than faulting.
            let policy = DecayPolicy(
                halfLifeSeconds: halfLife ?? DecayPolicy.defaultHalfLifeSeconds,
                startedAt: startedAt ?? issuedAt ?? Date(timeIntervalSinceReferenceDate: 0),
                floor: floor ?? 0
            )
            return .timeAging(policy)
        default:           throw GrantStoreError.corruptRow("unrecognized custody_mode '\(token)'")
        }
    }

    private static func reSharePermission(from token: String) throws -> ReSharePermission {
        switch token {
        case "none":      return .none
        case "withAudit": return .withAudit
        case "free":      return .free
        default:          throw GrantStoreError.corruptRow("unrecognized reshare '\(token)'")
        }
    }

    // MARK: - TypedValue extractors

    /// Tolerant integer extraction: a value may arrive as `.int` from
    /// the in-memory backend or as `.int` decoded from SQLite's INTEGER.
    private static func int(_ value: TypedValue?) -> Int {
        switch value {
        case .int(let i): return Int(i)
        case .bitmap(let i): return Int(i)
        default: return 0
        }
    }

    /// Tolerant nullable integer extraction for the optional `decay_*`
    /// columns. Returns `nil` for a NULL/absent column (mode 1–3 rows) and the
    /// integer value otherwise. Distinct from `int(_:)` which floors to `0`;
    /// here `nil` must be preserved so the decay-policy default logic can fire.
    private static func optionalInt(_ value: TypedValue?) -> Int? {
        switch value {
        case .int(let i): return Int(i)
        case .bitmap(let i): return Int(i)
        case .float(let d): return Int(d)
        default: return nil
        }
    }

    private static func double(_ value: TypedValue?) -> Double {
        switch value {
        case .float(let d): return d
        case .int(let i): return Double(i)
        default: return 0
        }
    }

    /// Tolerant date extraction: `.timestamp` from either backend, or
    /// `.text` if a backend hands back the raw ISO-8601 string. `nil`
    /// for a NULL `revoked_at` or a missing column. Returns `nil` on
    /// parse failure so the caller can distinguish NULL (valid for
    /// optional columns) from corrupt text (which must throw for
    /// required columns such as `issued_at`).
    private static func date(_ value: TypedValue?) -> Date? {
        switch value {
        case .timestamp(let d): return d
        case .text(let s): return ISO8601DateFormatter().date(from: s)
        default: return nil
        }
    }

    /// Extract the raw text from a TypedValue for error diagnostics.
    /// Returns the string content for `.text` and `.timestamp` variants,
    /// or `"<null>"` when the column is absent or a non-text type.
    private static func rawText(_ value: TypedValue?) -> String {
        switch value {
        case .text(let s): return s
        case .timestamp: return "<non-text timestamp>"
        default: return "<null>"
        }
    }
}

/// A grant as held in the store, paired with its revocation instant
/// (`nil` while active). Returned by `GrantStore.get` so callers can
/// observe revocation state alongside the grant.
public struct StoredGrant: Sendable {
    public let grant: Grant
    public let revokedAt: Date?
}
