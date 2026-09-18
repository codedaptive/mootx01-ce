// AriaV2ChestDiversityTests.swift
//
// ADR-027 D3: `chest_diversity` is a per-call global modifier. The door
// strips it before the operation decodes, so a memory_search carrying it
// decodes cleanly, and the call-scoped value parses on/off and ignores any
// other spelling. Twin of the Rust `chest_diversity_tests`.

import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import Testing
@testable import AriaMCP

@Suite("ARIA v2 chest_diversity modifier")
struct AriaV2ChestDiversityTests {

    private func makeDispatcher() async throws -> ToolDispatcher {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "chest-diversity-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(
            storage: storage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        return ToolDispatcher(kit: kit, handle: handle)
    }

    @Test("the modifier is stripped at the door and the search decodes")
    func modifierIsStrippedBeforeDecode() async throws {
        let dispatcher = try await makeDispatcher()
        for value in ["on", "off", "sideways"] {
            let result = try await dispatcher.dispatch(
                name: "moot_memory_search",
                arguments: .object(["query": .string("anything at all"), "chest_diversity": .string(value)]))
            let isErrorFlag = result.objectValue?["isError"]?.boolValue ?? false
            #expect(!isErrorFlag, "chest_diversity=\(value) must not reach the decoder")
        }
    }

    @Test("the call value parses on and off and ignores any other spelling")
    func callValueParses() async throws {
        let call = AriaV2ChestDiversityCall()
        await call.configure(.string("on"))
        #expect(await call.value == true)
        await call.configure(.string("off"))
        #expect(await call.value == false)
        await call.configure(.string("sideways"))
        #expect(await call.value == nil, "an unrecognised value is ignored, not an error")
        await call.configure(nil)
        #expect(await call.value == nil)
    }
}
