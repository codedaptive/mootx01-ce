// UtilityTierTests.swift
//
// PR-04 verification: the estate-status subject-debt counter on a mixed
// fixture, and the terse/verbose catalogue tiers.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

@Suite("Utility tier — subject-debt counter + catalogue tiers", .serialized)
struct UtilityTierTests {

    private func text(of result: JSONValue) -> String {
        guard case let .object(obj) = result,
              case let .array(content)? = obj["content"],
              case let .object(first)? = content.first,
              case let .string(s)? = first["text"]
        else { return "" }
        return s
    }

    @Test func estateStatusShowsSubjectDebtOnMixedFixture() async throws {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(
            storage: storage, owner: OwnerCredentials(ownerIdentifier: "debt-counter"))
        let handle = try await kit.open(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "debt-counter"),
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // Two subject-bearing rows through the boundary…
        for i in 1...2 {
            _ = try await dispatcher.dispatch(
                name: "moot_file_memory",
                arguments: .object([
                    "content": .string("Fixture row \(i) with a subject."),
                    "subject": .string("Fixture row \(i): has a subject."),
                    "location": .string("debt-tests"),
                ]))
        }
        // …and one subject-less row through the direct seam (intake shape).
        let frame = CaptureFrame(
            content: "Imported fixture row without a subject.",
            channel: .actuator,
            room: "debt-tests",
            latticeAnchor: LatticeAnchor(udcCode: "000"),
            addedBy: "utility-tier-tests",
            embeddingModelID: "default",
            wing: LocusKit.defaultWingName)
        _ = try await kit.capture(handle, frame, mode: .regular)

        let status = try await dispatcher.dispatch(
            name: "moot_estate_status", arguments: .object([:]))
        let body = text(of: status)
        // 2 subject-bearing / 3 eligible (1 missing). The bare estate here
        // has no seeded charter hints (Estate.create path), so the counts
        // are exactly the fixture's.
        #expect(body.contains("subjects: 2/3 (1 missing)"),
                "debt counter must reflect the mixed fixture; got: \(body)")
        // Over-filtering control (MXE-XU): every row here is normal
        // sensitivity, so the sensitivity ceiling removes nothing and the
        // counts are identical to what they were before the ceiling was
        // applied to them. An estate with no restricted rows must read the
        // same after the fix as before it.
        #expect(body.contains("memories: 3 active (3 total)"),
                "ceiling must not drop rows on an estate with no restricted rows; got: \(body)")
    }

    /// MXE-XU — every drawer-derived aggregate on this surface reads the
    /// sensitivity-filtered set, not the raw cluster-A set.
    ///
    /// The fixture holds one visible subject-bearing row plus two restricted
    /// rows — one carrying a subject, one not — filed into a wing of their
    /// own. Before the fix this reported `memories: 3 active (3 total)` and
    /// `subjects: 2/3 (1 missing)`: an ungranted caller learned that live rows
    /// were hidden from it, how many, and how many of those carried a subject.
    /// `wings:` was already filtered; it is the control that proves the fix
    /// closes the leak without over-reaching.
    @Test func estateStatusAggregatesExcludeRestrictedRows() async throws {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(
            storage: storage, owner: OwnerCredentials(ownerIdentifier: "xu-ceiling"))
        let handle = try await kit.open(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "xu-ceiling"),
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        let hiddenWing = "Ceiling Hidden Wing"

        // One normal-sensitivity, subject-bearing row in the default wing.
        _ = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("Visible row with a subject."),
                "subject": .string("Visible row: carries a subject."),
                "location": .string("ceiling-tests"),
            ]))

        // One restricted row WITH a subject, in a wing of its own.
        _ = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("Restricted row with a subject."),
                "subject": .string("Restricted row: carries a subject."),
                "location": .string("ceiling-hidden"),
                "wing": .string(hiddenWing),
                "sensitivity": .string("restricted"),
            ]))

        // …and one restricted row WITHOUT a subject. The ARIA boundary
        // requires a subject, so subject debt is seeded through the direct
        // capture seam, as the mixed-fixture test above does.
        let frame = CaptureFrame(
            content: "Restricted row without a subject.",
            channel: .actuator,
            room: "ceiling-hidden",
            latticeAnchor: LatticeAnchor(udcCode: "000"),
            addedBy: "utility-tier-tests",
            embeddingModelID: "default",
            sensitivity: .restricted,
            wing: hiddenWing)
        _ = try await kit.capture(handle, frame, mode: .regular)

        let status = try await dispatcher.dispatch(
            name: "moot_estate_status", arguments: .object([:]))
        let body = text(of: status)

        // The subject counter sees one eligible row, and it bears a subject.
        #expect(body.contains("subjects: 1/1 (0 missing)"),
                "subject counter must count only sensitivity-visible rows; got: \(body)")
        // The memories counts move with the same set — a count that tracks
        // the restricted population is the same leak in scalar form.
        #expect(body.contains("memories: 1 active (1 total)"),
                "memory counts must exclude restricted rows; got: \(body)")
        // Already-correct neighbour: the restricted rows' wing must not be
        // named, and the default wing must still be.
        #expect(!body.contains(hiddenWing),
                "wing listing must not name a wing known only from restricted rows; got: \(body)")
        #expect(body.contains("wings: \(LocusKit.defaultWingName)"),
                "the visible row's wing must still be listed; got: \(body)")
    }

    @Test func listLensesTerseDefaultAndVerbose() async throws {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(
            storage: storage, owner: OwnerCredentials(ownerIdentifier: "catalogue"))
        let handle = try await kit.open(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "catalogue"),
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        let terse = text(of: try await dispatcher.dispatch(
            name: "moot_list_lenses", arguments: .object([:])))
        #expect(terse.contains("cognition tools"))
        #expect(terse.contains("(terse — pass verbose:true"))
        #expect(!terse.contains("Required: "),
                "terse mode must not include the required-args blocks")

        let verbose = text(of: try await dispatcher.dispatch(
            name: "moot_list_lenses", arguments: .object(["verbose": .bool(true)])))
        #expect(verbose.contains("Required: "))
        #expect(verbose.count > terse.count,
                "verbose must be larger than terse (terse \(terse.count) vs verbose \(verbose.count))")

        let terseRecipes = text(of: try await dispatcher.dispatch(
            name: "moot_list_recipes", arguments: .object([:])))
        #expect(terseRecipes.contains("recipe(s)"))
        #expect(terseRecipes.contains("(terse — pass verbose:true"))
        let verboseRecipes = text(of: try await dispatcher.dispatch(
            name: "moot_list_recipes", arguments: .object(["verbose": .bool(true)])))
        #expect(verboseRecipes.contains("requires: "))
    }
}
