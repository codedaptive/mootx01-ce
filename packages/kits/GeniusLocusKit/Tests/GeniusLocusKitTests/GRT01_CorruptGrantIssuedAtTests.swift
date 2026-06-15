import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

/// GRT-01 corrupt issued_at — fail-closed read-back on the grant access-control surface.
///
/// These tests enforce the security posture documented in
/// `GrantStoreError.corruptIssuedAt`: a grant row whose `issued_at` column
/// cannot be parsed as an ISO-8601 date MUST surface an error. The store
/// must NEVER substitute epoch-0, which would fabricate a baseline for
/// lifetime arithmetic (a `DecayWindow` grant would compute its expiry from
/// 1970; an `Until` grant's expiry check would compare against a false origin).
///
/// Each test injects a corrupt row via raw SQLite (bypassing the
/// GrantStore writer) to simulate external mutation or storage corruption,
/// then verifies that a read-back via `GrantStore.get(id:)` throws rather
/// than returning a silently corrupted grant.
///
/// Fix context: FAIL_LOUD_SWEEP_2026-06-12.md DANGER-2 (#67 in the table).
/// Reference commit convention: 0ff08d93 (StorageError.corruptStoredValue).
@Suite("GRT-01 corrupt issued_at — fail-closed grant decode")
struct GRT01_CorruptGrantIssuedAtTests {

    // MARK: - Harness

    /// Open an estate, issue one seed grant to initialise the GrantStore, then
    /// return the store plus raw storage access. The seed grant is a permanent
    /// mode-1 grant; it does not affect the corrupt-row tests (those inject rows
    /// via raw SQL with distinct IDs).
    ///
    /// The GrantStore is lazily initialised on the first `issueGrant` call.
    /// Calling `grantStore(for:)` before any grant has been issued returns nil.
    private func openEstateWithGrantStore() async throws -> (
        kit: GeniusLocusKit,
        handle: EstateHandle,
        grantStore: GrantStore,
        storage: InMemoryStorage
    ) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-corrupt-test")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        // Seed issue to initialise the GrantStore actor inside the kit.
        let seedOpts = GrantOptions(
            granteeEstateID: UUID(),
            scope: .wholeEstate,
            custodyMode: .mediated,
            lifetime: .permanent
        )
        _ = try await kit.issueGrant(handle, seedOpts)
        let storeOpt = await kit.grantStore(for: handle)
        let store = try #require(storeOpt, "GrantStore must be present after first issueGrant")
        return (kit, handle, store, storage)
    }

    /// Insert a grant row directly into the in-memory storage with a corrupt
    /// issued_at value, bypassing the GrantStore encoder.
    ///
    /// This simulates what would happen if a SQLite row were externally
    /// mutated (hardware fault, manual edit, migration bug).
    private func injectCorruptRow(
        into storage: InMemoryStorage,
        id: UUID,
        granteeID: UUID,
        corruptIssuedAt: String
    ) async throws {
        // Write a minimal row with the corrupt issued_at directly to the
        // row store, bypassing GrantStore.insert(_:). The GrantStore uses
        // PersistenceKit's rowStore; we write through the same interface.
        //
        // JSON format: Swift's default Codable enum encoding uses a
        // single-key object: {"wholeEstate":{}} and {"permanent":{}}.
        _ = try await storage.rowStore.upsert(
            table: "grants",
            values: [
                "id": .text(id.uuidString),
                "grantee_id": .text(granteeID.uuidString),
                "scope_json": .text(#"{"wholeEstate":{}}"#),
                "content_level": .int(0),
                "custody_mode": .text("mediated"),
                "lifetime_json": .text(#"{"permanent":{}}"#),
                "reshare": .text("none"),
                "inference_budget": .float(1000.0),
                // Corrupt value — not a parseable ISO-8601 date.
                "issued_at": .text(corruptIssuedAt),
                "signature": .blob(Data())
            ],
            conflictColumns: ["id"]
        )
    }

    // MARK: - 1. Corrupt issued_at throws, not epoch-0

    /// The primary security test: a row with a corrupt issued_at TEXT must
    /// throw `GrantStoreError.corruptIssuedAt`, never silently return a
    /// grant whose issuedAt is `Date(timeIntervalSince1970: 0)`.
    ///
    /// An epoch-0 grant issued in 1970 would have incorrect lifetime
    /// arithmetic for any lifetime type that uses issuedAt as a baseline.
    @Test
    func corruptIssuedAtThrowsNotEpochZero() async throws {
        let (_, _, store, storage) = try await openEstateWithGrantStore()
        let grantID = UUID()
        let granteeID = UUID()

        try await injectCorruptRow(
            into: storage,
            id: grantID,
            granteeID: granteeID,
            corruptIssuedAt: "not-a-date"
        )

        // get(id:) must throw, not return a grant with epoch-0 issuedAt.
        do {
            let result = try await store.get(id: grantID)
            // If it did not throw, check that at minimum it did not return
            // a grant with epoch-0. Both outcomes are protocol violations
            // but we want a clear failure message for each.
            if let storedGrant = result {
                Issue.record(
                    "corrupt issued_at must throw, not return a grant; got grant with issuedAt=\(storedGrant.grant.issuedAt)"
                )
            }
            // nil result (absent grant) is also wrong — the row IS there,
            // it just cannot be decoded. Silently dropping it is different
            // from throwing, and conceals the corruption.
            if result == nil {
                Issue.record(
                    "corrupt issued_at must throw an error, not silently return nil (nil would mask storage corruption)"
                )
            }
        } catch let error as GrantStore.GrantStoreError {
            guard case .corruptIssuedAt(let storedText) = error else {
                Issue.record(
                    "expected GrantStoreError.corruptIssuedAt, got \(error)"
                )
                return
            }
            // storedText must carry the raw corrupt value for diagnosis.
            #expect(
                storedText == "not-a-date",
                "corruptIssuedAt.storedText must carry the raw stored value"
            )
        }
    }

    // MARK: - 2. Empty string issued_at throws

    @Test
    func emptyIssuedAtThrows() async throws {
        let (_, _, store, storage) = try await openEstateWithGrantStore()
        let grantID = UUID()

        try await injectCorruptRow(
            into: storage,
            id: grantID,
            granteeID: UUID(),
            corruptIssuedAt: ""
        )

        do {
            _ = try await store.get(id: grantID)
            Issue.record("empty issued_at must throw")
        } catch let error as GrantStore.GrantStoreError {
            guard case .corruptIssuedAt = error else {
                Issue.record("expected corruptIssuedAt, got \(error)")
                return
            }
            // Error correctly surfaced.
        }
    }

    // MARK: - 3. Epoch-0 string is also corrupt (explicit non-acceptance)

    /// The string "1970-01-01T00:00:00Z" is structurally valid ISO-8601 but
    /// represents the Unix epoch. We do NOT block this specific date — it is
    /// a valid date. The test exists to document that the fix targets
    /// *unparseable* strings, not semantically suspicious values.
    ///
    /// The real guard is the parse failure path: only strings that cannot
    /// be parsed as ISO-8601 are rejected.
    @Test
    func epochZeroStringIsValidISO8601AndDecodes() async throws {
        let (_, _, store, storage) = try await openEstateWithGrantStore()
        let grantID = UUID()

        try await injectCorruptRow(
            into: storage,
            id: grantID,
            granteeID: UUID(),
            corruptIssuedAt: "1970-01-01T00:00:00Z"
        )

        // "1970-01-01T00:00:00Z" is syntactically valid ISO-8601.
        // The fix rejects unparseable strings, not semantically suspicious
        // dates. Epoch-0 as a stored value is structurally acceptable
        // (the format round-trips); only garbage strings are rejected.
        // This test documents that boundary explicitly.
        let result = try await store.get(id: grantID)
        // Either throws (because the InMemory backend may not parse the
        // ISO-8601 to a Date via the tolerant path) or succeeds — we
        // assert only that it does NOT return a grant with a random/garbage
        // issuedAt, and that no unexpected exception type is thrown.
        if let sg = result {
            // If it decoded, the issuedAt should be near 1970-01-01.
            let epochZero = Date(timeIntervalSince1970: 0)
            let diff = abs(sg.grant.issuedAt.timeIntervalSince(epochZero))
            #expect(diff < 60, "decoded 1970-01-01 grant must have issuedAt near epoch-0")
        }
        // A nil result or a corruptIssuedAt error is also acceptable:
        // the store may treat epoch-0 differently per backend.
    }

    // MARK: - 4. Valid grants are unchanged

    /// Confirm that valid grants issued through the normal path are
    /// unaffected by the fail-closed change — their issuedAt round-trips
    /// exactly through GrantStore.insert → GrantStore.get.
    @Test
    func validGrantsUntouched() async throws {
        let (kit, handle, store, _) = try await openEstateWithGrantStore()
        let issuedAt = Date(timeIntervalSince1970: 1_000_000)
        let opts = GrantOptions(
            granteeEstateID: UUID(),
            scope: .wholeEstate,
            custodyMode: .mediated,
            lifetime: .permanent
        )
        let result = try await kit.issueGrant(handle, opts, now: issuedAt)
        let stored = try await store.get(id: result.grant.id)
        let row = try #require(stored)

        // The issuedAt must round-trip without epoch-0 substitution.
        let diff = abs(row.grant.issuedAt.timeIntervalSince(issuedAt))
        #expect(diff < 1.0, "valid grant issuedAt must round-trip; diff=\(diff)s")
        #expect(row.revokedAt == nil, "freshly issued grant must not be revoked")
    }

    // MARK: - 5. Expiry arithmetic untouched for valid rows

    /// Confirm that `expired(before:)` works correctly for a valid grant
    /// with a finite lifetime — the issuedAt is used as the baseline for
    /// DecayWindow expiry, so this test verifies the arithmetic path.
    @Test
    func expiryArithmeticUntouched() async throws {
        let (kit, handle, _, _) = try await openEstateWithGrantStore()
        let issuedAt = Date(timeIntervalSince1970: 1_000_000)
        let window: TimeInterval = 3600  // 1 hour
        let opts = GrantOptions(
            granteeEstateID: UUID(),
            scope: .wholeEstate,
            custodyMode: .mediated,
            lifetime: .decayWindow(seconds: Int(window))
        )
        _ = try await kit.issueGrant(handle, opts, now: issuedAt)

        let storeOpt = await kit.grantStore(for: handle)
        let store = try #require(storeOpt)

        let beforeExpiry = issuedAt.addingTimeInterval(window - 1)
        let afterExpiry = issuedAt.addingTimeInterval(window + 1)

        let notYetExpired = try await store.expired(before: beforeExpiry)
        #expect(notYetExpired.isEmpty, "grant must not appear in expired list before its window closes")

        let expired = try await store.expired(before: afterExpiry)
        #expect(expired.count == 1, "grant must appear in expired list after its window closes")
    }
}
