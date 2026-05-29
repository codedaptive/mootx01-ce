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
    enum GrantStoreError: Error, Sendable {
        case corruptRow(String)
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
            .blob("signature")
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

    /// Fetch a grant by id, or `nil` if absent.
    public func get(id: UUID) async throws -> StoredGrant? {
        let rows = try await storage.rowStore.query(
            table: "grants",
            where: .eq(Column(table: "grants", name: "id"), .text(id.uuidString))
        )
        guard let row = rows.first else { return nil }
        return try Self.decode(row)
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
        return [
            "id": .text(grant.id.uuidString),
            "grantee_id": .text(grant.granteeEstateID.uuidString),
            "scope_json": .text(scopeJSON),
            "content_level": .int(Int64(grant.contentLevel)),
            "custody_mode": .text(grant.custodyMode.signingToken),
            "lifetime_json": .text(lifetimeJSON),
            "reshare": .text(grant.reSharePermission.signingToken),
            "inference_budget": .float(grant.inferenceRemainingBudget),
            "issued_at": .timestamp(grant.issuedAt),
            "signature": .blob(grant.signature)
        ]
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
        let custody = try custodyMode(from: try text("custody_mode"))
        let reshare = try reSharePermission(from: try text("reshare"))
        let contentLevel = Self.int(row["content_level"])
        let budget = Self.double(row["inference_budget"])
        let issuedAt = Self.date(row["issued_at"]) ?? Date(timeIntervalSince1970: 0)
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
    /// once IP clearance is confirmed (ENC-02). Mode 4 remains gated at
    /// issue time before any row is written. The `grants` schema persists
    /// only the discriminant token (`custody_mode` column), not the enum's
    /// associated values, so mode 3 decodes with placeholder associated
    /// values: the threshold/totalShares/driftRate are NOT round-tripped.
    /// This is a known GRT-01 schema limitation, not a defect introduced
    /// here; a decoded mode-3 grant is faithful in its discriminant only.
    /// `experimentalIPClearanceConfirmed` decodes as `true` because a
    /// persisted mode-3 grant was, by construction, issued with clearance.
    /// Security note (Perkins A-1): this flag is reconstructed, not
    /// authentic caller intent. Do NOT treat the flag on a decoded grant
    /// as an authorization decision — the IP-clearance gate must only ever
    /// key off a caller-supplied `GrantOptions`, never a decoded `Grant`.
    private static func custodyMode(from token: String) throws -> CustodyMode {
        switch token {
        case "mediated":   return .mediated
        case "handedOver": return .handedOver
        case "decayDerived":
            return .decayDerived(
                threshold: 0, totalShares: 0, driftRatePerDay: .slow,
                experimentalIPClearanceConfirmed: true
            )
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

    private static func double(_ value: TypedValue?) -> Double {
        switch value {
        case .float(let d): return d
        case .int(let i): return Double(i)
        default: return 0
        }
    }

    /// Tolerant date extraction: `.timestamp` from either backend, or
    /// `.text` if a backend hands back the raw ISO-8601 string. `nil`
    /// for a NULL `revoked_at`.
    private static func date(_ value: TypedValue?) -> Date? {
        switch value {
        case .timestamp(let d): return d
        case .text(let s): return ISO8601DateFormatter().date(from: s)
        default: return nil
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
