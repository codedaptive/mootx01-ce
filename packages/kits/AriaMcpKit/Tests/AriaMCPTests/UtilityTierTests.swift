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
