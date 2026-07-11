import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP
// @testable (not plain `import`) so ADR-025 §4 audit-emission tests below
// can read `kit.auditLog(for:)` — internal API, exposed to this test
// target the same way SensitivityAuditVerbsTests.swift (GeniusLocusKit's
// own test target) reads it.
@testable import GeniusLocusKit

/// ADR-025 sensitivity unlock — end-to-end integration through the real
/// dispatch path (`moot_memory_search` / `moot_memory_get`), driving the
/// grant ledger directly (the CLI/UnlockAuthority approval surface is a
/// separate, out-of-band channel per ADR §3 — these tests exercise the
/// POLICY the ceiling seam enforces once a grant exists, independent of
/// how that grant was approved).
///
/// Covers the ADR's own Verification section: grant → visible; expiry
/// (midnight / 30 min) → redacted again; restart → locked; tier
/// independence.
@Suite("ADR-025 sensitivity unlock — ceiling seam integration", .serialized)
struct SensitivityUnlockIntegrationTests {

    private func openEstate(
        in kit: GeniusLocusKit,
        owner: OwnerCredentials
    ) async throws -> EstateHandle {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory
        ))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        return try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
    }

    @discardableResult
    private func seed(
        _ content: String,
        room: String = "unlock-tests",
        sensitivity: AdjectiveSensitivity,
        in handle: EstateHandle,
        kit: GeniusLocusKit
    ) async throws -> Drawer {
        let frame = CaptureFrame(
            content: content, channel: .typed, room: room,
            latticeAnchor: .udc("004"), addedBy: "aria-mcp-tests",
            embeddingModelID: "test-model-v1", sensitivity: sensitivity
        )
        return try await kit.capture(handle, frame)
    }

    private func text(of result: JSONValue) -> String {
        guard case let .object(obj) = result,
              case let .array(content)? = obj["content"],
              case let .object(first)? = content.first,
              case let .string(s)? = first["text"]
        else { return "" }
        return s
    }

    private func isError(_ result: JSONValue) -> Bool {
        if case let .object(obj) = result, case let .bool(b)? = obj["isError"] { return b }
        return false
    }

    private var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    // MARK: - Grant → visible (moot_memory_search)

    @Test("a restricted drawer is invisible to search without a grant, visible with one")
    func restrictedDrawerGrantMakesItVisibleInSearch() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "unlock-owner")
        let handle = try await openEstate(in: kit, owner: owner)
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        try await seed("unlock-marker-restricted classified briefing", sensitivity: .restricted, in: handle, kit: kit)

        let before = try await dispatcher.runMemorySearch(["query": .string("unlock-marker-restricted")])
        #expect(text(of: before).contains("found 0 memory(s)"),
                "without a grant the restricted drawer must not appear at all")

        let now = Date()
        await dispatcher.sensitivityUnlockLedger.grantRestricted(now: now, calendar: utcCalendar)

        let after = try await dispatcher.runMemorySearch(["query": .string("unlock-marker-restricted")])
        #expect(text(of: after).contains("classified briefing"),
                "with a live restricted grant the drawer's content must be visible")
    }

    // MARK: - Grant → visible (moot_memory_get)

    @Test("a restricted drawer is not-found via moot_memory_get without a grant, found with one")
    func restrictedDrawerGrantMakesItFoundByID() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "unlock-owner")
        let handle = try await openEstate(in: kit, owner: owner)
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let drawer = try await seed("unlock-get-marker restricted content body", sensitivity: .restricted, in: handle, kit: kit)

        // moot_memory_get THROWS JSONRPCError.invalidParams for a not-found
        // row (it never returns an {isError:true} JSON payload for this
        // case) — see runMemoryGet's own "Memory not found" throw.
        await #expect(throws: JSONRPCError.self,
                      "without a grant, moot_memory_get must report not-found for a restricted drawer") {
            _ = try await dispatcher.runMemoryGet(["id": .string(drawer.id)])
        }

        await dispatcher.sensitivityUnlockLedger.grantRestricted(now: Date(), calendar: utcCalendar)

        let after = try await dispatcher.runMemoryGet(["id": .string(drawer.id)])
        #expect(!isError(after), "with a live restricted grant, moot_memory_get must find the drawer")
        #expect(text(of: after).contains("restricted content body"))
    }

    // MARK: - Secret tier

    @Test("a secret drawer requires the secret grant specifically — a restricted grant alone is not enough")
    func secretDrawerRequiresSecretGrantSpecifically() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "unlock-owner")
        let handle = try await openEstate(in: kit, owner: owner)
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        try await seed("unlock-secret-marker top secret payload", sensitivity: .secret, in: handle, kit: kit)

        await dispatcher.sensitivityUnlockLedger.grantRestricted(now: Date(), calendar: utcCalendar)
        let stillHidden = try await dispatcher.runMemorySearch(["query": .string("unlock-secret-marker")])
        #expect(text(of: stillHidden).contains("found 0 memory(s)"),
                "a restricted-only grant must not reveal secret-tier content")

        await dispatcher.sensitivityUnlockLedger.grantSecret(now: Date())
        let nowVisible = try await dispatcher.runMemorySearch(["query": .string("unlock-secret-marker")])
        #expect(text(of: nowVisible).contains("top secret payload"),
                "a live secret grant must reveal secret-tier content")
    }

    // MARK: - Expiry → redacted again

    @Test("expiry of a secret grant makes the drawer invisible again")
    func secretGrantExpiryRedactsAgain() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "unlock-owner")
        let handle = try await openEstate(in: kit, owner: owner)
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        try await seed("unlock-expiry-marker secret content", sensitivity: .secret, in: handle, kit: kit)

        // Grant "in the past" relative to the search call below by granting
        // at an already-past `now`, then searching — runMemorySearch reads
        // wall-clock Date() internally, so to prove expiry deterministically
        // we instead verify directly against the ledger's own now-parameterized
        // API (the seam runMemorySearch delegates to), matching the ledger
        // unit tests' style, and cross-check the dispatch-level effect at a
        // live grant vs. a grant we know has expired.
        let grantedAt = Date().addingTimeInterval(-31 * 60) // 31 minutes ago
        await dispatcher.sensitivityUnlockLedger.grantSecret(now: grantedAt)
        #expect(!(await dispatcher.sensitivityUnlockLedger.isSecretGranted(now: Date())),
                "a grant issued 31 minutes ago must have expired under the fixed 30-minute window")

        let result = try await dispatcher.runMemorySearch(["query": .string("unlock-expiry-marker")])
        #expect(text(of: result).contains("found 0 memory(s)"),
                "an expired secret grant must not reveal secret-tier content")
    }

    // MARK: - Restart → locked

    @Test("a new ToolDispatcher (simulating a daemon restart) starts fully locked")
    func newDispatcherSimulatesRestartLocked() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "unlock-owner")
        let handle = try await openEstate(in: kit, owner: owner)
        defer { Task { try? await kit.close(handle) } }

        let dispatcher1 = ToolDispatcher(kit: kit, handle: handle)
        await dispatcher1.sensitivityUnlockLedger.grantSecret(now: Date())
        #expect(await dispatcher1.sensitivityUnlockLedger.isSecretGranted(now: Date()))

        // A fresh ToolDispatcher construction — exactly what `mootx01 serve`
        // does on daemon restart — carries a brand-new, fully-locked ledger.
        let dispatcher2 = ToolDispatcher(kit: kit, handle: handle)
        #expect(!(await dispatcher2.sensitivityUnlockLedger.isSecretGranted(now: Date())),
                "a fresh dispatcher (simulating restart) must never inherit a prior grant")
    }

    // MARK: - `lock` drops visibility immediately

    @Test("locking mid-session immediately re-hides granted content")
    func lockingMidSessionReHidesContent() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "unlock-owner")
        let handle = try await openEstate(in: kit, owner: owner)
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        try await seed("unlock-lock-marker sensitive detail", sensitivity: .restricted, in: handle, kit: kit)
        await dispatcher.sensitivityUnlockLedger.grantRestricted(now: Date(), calendar: utcCalendar)
        let visible = try await dispatcher.runMemorySearch(["query": .string("unlock-lock-marker")])
        #expect(text(of: visible).contains("sensitive detail"))

        await dispatcher.sensitivityUnlockLedger.lock()
        let hiddenAgain = try await dispatcher.runMemorySearch(["query": .string("unlock-lock-marker")])
        #expect(text(of: hiddenAgain).contains("found 0 memory(s)"))
    }

    // MARK: - ADR-025 §4: read-under-grant audit emission

    @Test("reading a restricted drawer under a live grant emits a sensitivityReadUnderGrant audit entry, via search")
    func restrictedReadUnderGrantEmitsAuditEntryViaSearch() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "unlock-owner")
        let handle = try await openEstate(in: kit, owner: owner)
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let drawer = try await seed("audit-search-marker restricted content", sensitivity: .restricted, in: handle, kit: kit)
        await dispatcher.sensitivityUnlockLedger.grantRestricted(now: Date(), calendar: utcCalendar)
        _ = try await dispatcher.runMemorySearch(["query": .string("audit-search-marker")])

        let log = try await kit.auditLog(for: handle)
        let entries = log.orderedEntries.filter { $0.verb == .sensitivityReadUnderGrant }
        #expect(entries.count == 1)
        #expect(entries.first?.rowID == UUID(uuidString: drawer.id))
        #expect(entries.first?.fieldPath == "restricted")
    }

    @Test("reading a restricted drawer under a live grant emits a sensitivityReadUnderGrant audit entry, via get")
    func restrictedReadUnderGrantEmitsAuditEntryViaGet() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "unlock-owner")
        let handle = try await openEstate(in: kit, owner: owner)
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let drawer = try await seed("audit-get-marker restricted content", sensitivity: .restricted, in: handle, kit: kit)
        await dispatcher.sensitivityUnlockLedger.grantRestricted(now: Date(), calendar: utcCalendar)
        _ = try await dispatcher.runMemoryGet(["id": .string(drawer.id)])

        let log = try await kit.auditLog(for: handle)
        let entries = log.orderedEntries.filter { $0.verb == .sensitivityReadUnderGrant }
        #expect(entries.count == 1)
        #expect(entries.first?.rowID == UUID(uuidString: drawer.id))
    }

    @Test("a normal-sensitivity drawer read alongside a live grant does NOT emit a read-under-grant entry")
    func normalDrawerReadDuringLiveGrantDoesNotEmitAuditEntry() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "unlock-owner")
        let handle = try await openEstate(in: kit, owner: owner)
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        try await seed("audit-normal-marker ordinary content", sensitivity: .normal, in: handle, kit: kit)
        await dispatcher.sensitivityUnlockLedger.grantRestricted(now: Date(), calendar: utcCalendar)
        _ = try await dispatcher.runMemorySearch(["query": .string("audit-normal-marker")])

        let log = try await kit.auditLog(for: handle)
        #expect(log.orderedEntries.filter { $0.verb == .sensitivityReadUnderGrant }.isEmpty,
                "a row that would be admitted regardless of any grant must not be recorded as read-under-grant")
    }

    @Test("a restricted drawer read WITHOUT a live grant does not emit a read-under-grant entry (there is nothing to read)")
    func restrictedDrawerReadWithoutGrantDoesNotEmitAuditEntry() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "unlock-owner")
        let handle = try await openEstate(in: kit, owner: owner)
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        try await seed("audit-nogrant-marker restricted content", sensitivity: .restricted, in: handle, kit: kit)
        _ = try await dispatcher.runMemorySearch(["query": .string("audit-nogrant-marker")])

        let log = try await kit.auditLog(for: handle)
        #expect(log.orderedEntries.filter { $0.verb == .sensitivityReadUnderGrant }.isEmpty)
    }

    // MARK: - isSensitivityFilter classifier (the grant-injection suppression check)

    /// Direct unit coverage of `ToolDispatcher.isSensitivityFilter`, the
    /// classifier that decides whether the grant ceiling should be
    /// injected at all. NOTE: today's `decodeFilterChain` only accepts a
    /// small closed vocabulary ("unconfirmed", "userConfirmed",
    /// "exportable", "contained") for the `filter` MCP argument — none of
    /// which produce a `.sensitivity`/`.sensitivityAtMost` case, so this
    /// suppression path is not reachable through the current tool surface.
    /// It is still real, defensive code (protects a future filter-argument
    /// extension from getting silently AND-ed against a grant ceiling) —
    /// this test exercises the classifier directly rather than through a
    /// currently-nonexistent MCP argument shape.
    @Test("isSensitivityFilter recognizes direct, nested, and negated sensitivity constraints")
    func isSensitivityFilterClassifier() {
        #expect(ToolDispatcher.isSensitivityFilter(.sensitivity(.normal)))
        #expect(ToolDispatcher.isSensitivityFilter(.sensitivityAtMost(.elevated)))
        #expect(ToolDispatcher.isSensitivityFilter(.all([.currentlyBelieve, .sensitivityAtMost(.restricted)])))
        #expect(ToolDispatcher.isSensitivityFilter(.any([.exportable, .sensitivity(.secret)])))
        #expect(ToolDispatcher.isSensitivityFilter(.not(.sensitivityAtMost(.normal))))
        #expect(!ToolDispatcher.isSensitivityFilter(.currentlyBelieve))
        #expect(!ToolDispatcher.isSensitivityFilter(.trustworthy))
        #expect(!ToolDispatcher.isSensitivityFilter(.all([.currentlyBelieve, .trustworthy])))
    }
}
