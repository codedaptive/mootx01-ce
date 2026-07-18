// DeviceIdentityStore.swift
//
// Persists this device's (deviceUUID, slot, epoch) sync identity via
// PersistenceKit's side-table migration mechanism.
//
// WHY a side table and not a UserDefaults or a plist:
//   The identity must be stored inside the same PersistenceKit `Storage`
//   instance as the sync data so that a transaction can atomically update
//   the identity and the sync state without a cross-store ordering hazard.
//   PersistenceKit's `migrate(to:)` path creates the table without touching
//   the application schema (it is additive-only), matching the pattern
//   established by `SyncMetaStore.swift` for `_ck_sync_meta`.
//
// Schema invariants observed (rules/schema-invariants.md):
//   - NO Bool stored columns. Boolean state lives in Int64 bitmaps.
//   - All date columns are TEXT ISO8601, never REAL (unix float).
//
// kitID convention: "ConvergenceKit" (not "ConvergenceKitCloudKit").
//   Device identity is transport-agnostic; the slot registry protocol
//   would apply to any shared relay backend, not only CloudKit. Using
//   the core kitID keeps the table visible to any future backend.
//
// Consolidation note (adjudication A11, CVK-WB12 — DONE):
//   CKSideSchema (SideSchema.swift) now consolidates ALL _ck_* side tables,
//   including _ck_device_identity. The table declaration was moved to
//   CKSideSchema v9 (v8→v9 migration, additive — IF NOT EXISTS). This file
//   retains the read/write helpers and the ensureSchema(storage:) entry point
//   (which delegates to CKSideSchema.ensure) for call-site stability, matching
//   the pattern established by TokenStore.swift for _ck_change_token.

import Foundation
import PersistenceKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Stored value
// ─────────────────────────────────────────────────────────────────────────────

/// This device's persistent sync identity for a given estate.
///
/// Minted once on first `enable()` and persisted across process restarts.
/// The `deviceUUID` differentiates machines that share one iCloud account.
/// The `slot` is the device's HLC node-ID slot (1–15), confirmed via
/// CloudKit CAS against the shared slot registry (SlotClaimOperation).
public struct DeviceIdentity: Sendable, Equatable {

    /// Stable device UUID. Generated once per device/estate pair.
    /// Never changes for this device's relationship to this estate.
    public let deviceUUID: UUID

    /// The registry slot claimed by this device (1–15).
    ///
    /// Confirmed via CloudKit CAS by `SlotClaimOperation` and persisted here.
    /// A persisted slot is passed as `preferredSlot` to the claim operation on
    /// subsequent `enable()` calls, so the device reclaims the same slot if it
    /// is still free — reducing unnecessary slot changes and HLC outbox remints
    /// across process restarts.
    public let slot: Int

    /// Epoch counter matching the registry record for this slot.
    /// Bumped by the evicting device when it performs a CloudKit CAS
    /// to reclaim the slot. A mismatch between the stored epoch and the
    /// registry epoch signals that this device was evicted (reenrollRequired).
    public let epoch: Int64

    /// ISO8601 wall-clock timestamp when this slot was first claimed
    /// in its current epoch. Stored as a `Date` in the model; persisted
    /// as TEXT ISO8601 in the side table (schema invariant).
    public let claimedAt: Date

    /// Public memberwise initializer.
    /// Swift synthesises an `internal` memberwise init for public structs;
    /// an explicit `public init` is required for cross-module construction.
    public init(deviceUUID: UUID, slot: Int, epoch: Int64, claimedAt: Date) {
        self.deviceUUID = deviceUUID
        self.slot = slot
        self.epoch = epoch
        self.claimedAt = claimedAt
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - DeviceIdentityStore
// ─────────────────────────────────────────────────────────────────────────────

/// Side-table manager for `_ck_device_identity`.
///
/// Usage (from `CloudKitStateActor.enable()`):
/// ```swift
/// try await DeviceIdentityStore.ensureSchema(storage: storage)
/// let store = DeviceIdentityStore(storage: storage)
/// let identity = try await store.loadOrMint(now: { Date() })
/// ```
///
/// All methods are `async throws` — they issue PersistenceKit I/O and
/// must be awaited in an async context.
public struct DeviceIdentityStore: Sendable {

    // Side table name — references the CKSideSchema constant so the single
    // source of truth for the table name lives in SideSchema.swift.
    // (cf. TokenStore.tableName = CKSideSchema.changeTokenTable)
    private static let tableName = CKSideSchema.deviceIdentityTable

    // Fixed primary key for the single-row table. This device has exactly
    // one identity per estate; a sentinel constant avoids needing a ROWID
    // or a surrogate counter.
    private static let selfRowID = "self"

    // ISO 8601 formatter shared across all encode/decode calls in this type.
    // ISO8601DateFormatter is documented as thread-safe once configured; the
    // `nonisolated(unsafe)` annotation satisfies Swift 6 strict concurrency
    // without disabling the thread-safety guarantee. The formatter is created
    // once at first access and then only read (never mutated) after that.
    nonisolated(unsafe) private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        // .withInternetDateTime produces "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
        // which is human-readable, string-sortable, and unambiguous.
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private let storage: any Storage

    public init(storage: any Storage) {
        self.storage = storage
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Schema
    // ─────────────────────────────────────────────────────────────────────────

    /// Ensure the `_ck_device_identity` side table exists on `storage`.
    ///
    /// Delegates to `CKSideSchema.ensure(storage:)`, which owns the
    /// consolidated `SchemaDeclaration` for all ConvergenceKit side tables
    /// (kitID "ConvergenceKit", version 9 as of CVK-WB12). Kept as a function
    /// so existing callers compile without modification; CloudKitStateActor
    /// no longer needs to call it separately because CKSideSchema.ensure is
    /// already called earlier in the enable path.
    ///
    /// Calling it multiple times is safe — `Storage.migrate(to:)` is
    /// additive-only: it creates missing tables without touching existing ones
    /// or the application's active schema.
    public static func ensureSchema(storage: any Storage) async throws {
        try await CKSideSchema.ensure(storage: storage)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Read / write
    // ─────────────────────────────────────────────────────────────────────────

    /// Load the persisted identity for this device, or `nil` if none exists.
    public func load() async throws -> DeviceIdentity? {
        let rows = try await storage.rowStore.query(
            table: Self.tableName,
            where: .eq(
                Column(table: Self.tableName, name: "id"),
                .text(Self.selfRowID)
            )
        )
        guard let row = rows.first else { return nil }
        return try Self.decode(row: row.values)
    }

    /// Persist `identity`, replacing any existing row.
    public func save(_ identity: DeviceIdentity) async throws {
        _ = try await storage.rowStore.upsert(
            table: Self.tableName,
            values: [
                "id":          .text(Self.selfRowID),
                "device_uuid": .text(identity.deviceUUID.uuidString),
                "slot":        .int(Int64(identity.slot)),
                "epoch":       .int(identity.epoch),
                // ISO8601 text — DATE STORAGE INVARIANT enforced here
                "claimed_at":  .text(Self.iso8601.string(from: identity.claimedAt)),
            ],
            conflictColumns: ["id"]
        )
    }

    /// Load the existing identity, or mint and persist a fresh one.
    ///
    /// **Fresh mint:** generates a new stable `deviceUUID`, picks a random
    /// provisional slot (1–15), sets epoch to 1, and persists to the side
    /// table before returning. Subsequent calls return the same stored identity.
    ///
    /// **Idempotency:** if an identity already exists it is returned as-is.
    /// The `now` clock is only used for the `claimedAt` timestamp on a fresh
    /// mint; it is never called on subsequent loads.
    ///
    /// - Parameter now: Injected clock. Never call `Date()` inside this method
    ///   — tests supply a fixed clock for reproducibility.
    public func loadOrMint(now: @Sendable () -> Date) async throws -> DeviceIdentity {
        if let existing = try await load() {
            return existing
        }
        // No persisted identity — mint a new one.
        //
        // Slot is a randomly chosen initial value. Per-launch random re-roll
        // would have collision probability ≈1/15 per session pair. A stable
        // persisted slot only collides when another device independently picked
        // the same number — but CloudKit CAS arbitration in SlotClaimOperation
        // (called immediately after loadOrMint) confirms or reassigns it.
        let provisional = DeviceIdentity(
            deviceUUID: UUID(),
            slot: Int.random(in: 1...15),
            epoch: 1,
            claimedAt: now()
        )
        try await save(provisional)
        return provisional
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Private helpers
    // ─────────────────────────────────────────────────────────────────────────

    private static func decode(row: [String: TypedValue]) throws -> DeviceIdentity {
        guard
            case .text(let uuidStr) = row["device_uuid"],
            let deviceUUID = UUID(uuidString: uuidStr),
            case .int(let slotRaw) = row["slot"],
            case .int(let epoch) = row["epoch"],
            case .text(let claimedAtStr) = row["claimed_at"],
            let claimedAt = iso8601.date(from: claimedAtStr)
        else {
            throw SyncError.decodingFailure(
                detail: "_ck_device_identity row has unexpected column shape"
            )
        }
        return DeviceIdentity(
            deviceUUID: deviceUUID,
            slot: Int(slotRaw),
            epoch: epoch,
            claimedAt: claimedAt
        )
    }
}
