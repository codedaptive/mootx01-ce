import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP
import GeniusLocusKit

/// `moot_file_memory` under a live sensitivity grant: the write side shares
/// the read side's ceiling. An omitted `sensitivity` files at the grant's
/// tier, an explicit lower tier is refused with the ceiling named, an
/// explicit higher tier is kept, and with no grant nothing changes. Drives
/// the grant ledger directly, as `SensitivityUnlockIntegrationTests` does.
/// Rust twin: `file_memory_*_grant_*` in dispatch_tests.rs.
@Suite("moot_file_memory files at the live grant ceiling", .serialized)
struct FileMemorySensitivityCeilingTests {

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

    private var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
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

    /// The id on the reply's first line, `filed memory <uuid>`.
    private func filedID(_ result: JSONValue) -> String {
        let first = text(of: result).split(separator: "\n").first.map(String.init) ?? ""
        return first.replacingOccurrences(of: "filed memory ", with: "")
    }

    /// Read the filed drawer back through an explicit sensitivity filter,
    /// which suppresses the default `.elevated` ceiling that would hide a
    /// restricted or secret row.
    private func drawer(
        _ id: String, sensitivity: AdjectiveSensitivity,
        in handle: EstateHandle, kit: GeniusLocusKit
    ) async throws -> Drawer {
        let drawers = try await kit.recall(
            handle,
            RecallFrame(filterChain: [.sensitivity(sensitivity)], hydrationLevel: .full, limit: 50))
        return try #require(drawers.first { $0.id == id },
                            "the filed drawer must be readable at sensitivity \(sensitivity)")
    }

    private func fileArgs(_ marker: String, sensitivity: String? = nil) -> [String: JSONValue] {
        var args: [String: JSONValue] = [
            "content": .string("\(marker) checkpoint body"),
            "subject": .string("\(marker) checkpoint"),
            "location": .string("session/ceiling-tests/checkpoint-30"),
        ]
        if let sensitivity { args["sensitivity"] = .string(sensitivity) }
        return args
    }

    @Test("omitted sensitivity under a restricted grant files restricted and the reply says so")
    func omittedUnderRestrictedGrantFilesRestricted() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "ceiling-owner")
        let handle = try await openEstate(in: kit, owner: owner)
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let now = Date()
        await dispatcher.sensitivityUnlockLedger.grantRestricted(now: now, calendar: utcCalendar)

        let result = try await dispatcher.runFileMemory(fileArgs("ceiling-restricted-omitted"), now: now)
        #expect(!isError(result), "filing under a grant must succeed: \(text(of: result))")
        #expect(text(of: result).contains("sensitivity: restricted"),
                "the reply must name the tier the server applied")

        let filed = try await drawer(filedID(result), sensitivity: .restricted, in: handle, kit: kit)
        #expect(filed.adjectiveSensitivity == .restricted)
    }

    @Test("omitted sensitivity under a secret grant files secret")
    func omittedUnderSecretGrantFilesSecret() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "ceiling-owner")
        let handle = try await openEstate(in: kit, owner: owner)
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let now = Date()
        await dispatcher.sensitivityUnlockLedger.grantSecret(now: now)

        let result = try await dispatcher.runFileMemory(fileArgs("ceiling-secret-omitted"), now: now)
        #expect(!isError(result), "filing under a grant must succeed: \(text(of: result))")
        #expect(text(of: result).contains("sensitivity: secret"))

        let filed = try await drawer(filedID(result), sensitivity: .secret, in: handle, kit: kit)
        #expect(filed.adjectiveSensitivity == .secret)
    }

    @Test("an explicit lower sensitivity under a live grant is refused naming the ceiling")
    func explicitLowerUnderGrantIsRefused() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "ceiling-owner")
        let handle = try await openEstate(in: kit, owner: owner)
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let now = Date()
        await dispatcher.sensitivityUnlockLedger.grantSecret(now: now)

        let result = try await dispatcher.runFileMemory(
            fileArgs("ceiling-secret-lowered", sensitivity: "restricted"), now: now)
        #expect(isError(result), "a tier below the ceiling must be refused, not filed")
        #expect(text(of: result) == ToolDispatcher.sensitivityBelowCeilingMessage(
            requested: .restricted, ceiling: .secret))
        #expect(text(of: result).contains("below the live grant ceiling secret"))

        // Nothing landed: the refused body is absent at every tier.
        let all = try await kit.recall(
            handle, RecallFrame(filterChain: [.sensitivityAtMost(.secret)], hydrationLevel: .full, limit: 50))
        #expect(!all.contains { $0.content.contains("ceiling-secret-lowered") },
                "a refused filing must not write a drawer")
    }

    @Test("an explicit normal under a restricted grant is refused; the message is the Rust port's")
    func explicitNormalUnderRestrictedGrantIsRefused() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "ceiling-owner")
        let handle = try await openEstate(in: kit, owner: owner)
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let now = Date()
        await dispatcher.sensitivityUnlockLedger.grantRestricted(now: now, calendar: utcCalendar)

        let result = try await dispatcher.runFileMemory(
            fileArgs("ceiling-restricted-normal", sensitivity: "normal"), now: now)
        #expect(isError(result))
        #expect(text(of: result) ==
            "sensitivity normal is below the live grant ceiling restricted: while a restricted "
            + "grant is live a memory files at restricted or higher. Omit sensitivity to file "
            + "at the ceiling.")
    }

    @Test("an explicit higher sensitivity under a restricted grant is kept")
    func explicitHigherUnderGrantIsKept() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "ceiling-owner")
        let handle = try await openEstate(in: kit, owner: owner)
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let now = Date()
        await dispatcher.sensitivityUnlockLedger.grantRestricted(now: now, calendar: utcCalendar)

        let result = try await dispatcher.runFileMemory(
            fileArgs("ceiling-restricted-raised", sensitivity: "secret"), now: now)
        #expect(!isError(result))
        #expect(text(of: result).contains("sensitivity: secret"))
        let filed = try await drawer(filedID(result), sensitivity: .secret, in: handle, kit: kit)
        #expect(filed.adjectiveSensitivity == .secret)
    }

    @Test("with no live grant an omitted sensitivity files normal and the reply keeps its shape")
    func noGrantIsUnchanged() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "ceiling-owner")
        let handle = try await openEstate(in: kit, owner: owner)
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let result = try await dispatcher.runFileMemory(fileArgs("ceiling-no-grant"), now: Date())
        #expect(!isError(result))
        let lines = text(of: result).split(separator: "\n").map(String.init)
        #expect(lines.count == 3, "no grant: filed memory / room / lineage only; got \(lines)")
        #expect(!text(of: result).contains("sensitivity:"))
        let filed = try await drawer(filedID(result), sensitivity: .normal, in: handle, kit: kit)
        #expect(filed.adjectiveSensitivity == .normal)

        // An explicit lower-than-secret tier is fine with no grant live.
        let explicit = try await dispatcher.runFileMemory(
            fileArgs("ceiling-no-grant-explicit", sensitivity: "normal"), now: Date())
        #expect(!isError(explicit))
    }

    @Test("an expired grant no longer floors the filing")
    func expiredGrantDoesNotFloor() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "ceiling-owner")
        let handle = try await openEstate(in: kit, owner: owner)
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let granted = Date()
        await dispatcher.sensitivityUnlockLedger.grantSecret(now: granted)

        // Thirty minutes plus one second later the fixed secret window is over.
        let later = granted.addingTimeInterval(30 * 60 + 1)
        let result = try await dispatcher.runFileMemory(fileArgs("ceiling-secret-expired"), now: later)
        #expect(!isError(result))
        #expect(!text(of: result).contains("sensitivity:"))
        let filed = try await drawer(filedID(result), sensitivity: .normal, in: handle, kit: kit)
        #expect(filed.adjectiveSensitivity == .normal)
    }
}
