// SessionProtocolTests.swift
//
// Tests for the MCP-INT-03 session orientation protocol:
//   - estate_status always includes the static protocol block
//   - estate_status teachme:true returns the full nine-tier orientation guide
//   - moot_list_lenses returns the full cognition menu (27 tools)
//   - moot_list_lenses teachme:true returns the teachme guide, not the menu
//   - protocol block is identical across consecutive calls (static invariant)

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// `.serialized`: every test opens a live in-memory estate and issues
/// real dispatch calls. Preserve sequential execution for isolation.
@Suite("Session protocol", .serialized)
struct SessionProtocolTests {

    // MARK: - Harness

    private func makeDispatcher(ownerID: String = "sp-tests") async throws -> ToolDispatcher {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: ownerID)
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
        return ToolDispatcher(kit: kit, handle: handle)
    }

    private func text(of result: JSONValue) -> String {
        result.objectValue?["content"]?.arrayValue?
            .first?.objectValue?["text"]?.stringValue ?? ""
    }

    private func isErrorResult(_ result: JSONValue) -> Bool {
        result.objectValue?["isError"]?.boolValue ?? false
    }

    // MARK: - Test 1: protocol block present in estate_status

    /// `moot_estate_status` always appends the static protocol block.
    /// The block must contain the literal "protocol:" section header and
    /// reference `moot_file_memory` as one of the surface's entry tools.
    @Test func protocolBlockPresentInEstateStatus() async throws {
        let dispatcher = try await makeDispatcher(ownerID: "sp-1")
        // File one memory so the estate is non-empty.
        _ = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("session protocol test memory"),
                "location": .string("sp-tests"),
            ]))

        let result = try await dispatcher.dispatch(
            name: "moot_estate_status",
            arguments: .object([:]))

        #expect(!isErrorResult(result))
        let t = text(of: result)
        #expect(t.contains("protocol:"),
                "estate_status response must contain the protocol: section header")
        #expect(t.contains("moot_file_memory"),
                "protocol block must reference moot_file_memory as a surface entry tool")
    }

    // MARK: - Test 2: protocol block on empty estate

    /// A zero-memory estate still returns the protocol block. The block is
    /// unconditional — estate contents do not gate its appearance.
    @Test func protocolBlockOnEmptyEstate() async throws {
        let dispatcher = try await makeDispatcher(ownerID: "sp-2")

        let result = try await dispatcher.dispatch(
            name: "moot_estate_status",
            arguments: .object([:]))

        #expect(!isErrorResult(result))
        let t = text(of: result)
        // Empty estate response includes "0 active" or similar, plus the block.
        #expect(t.contains("protocol:"),
                "empty estate must still receive the protocol block")
        #expect(t.contains("moot_memory_search"),
                "protocol block must reference moot_memory_search even on empty estate")
    }

    // MARK: - Test 3: teachme expands to full tier-based guide

    /// `moot_estate_status teachme:true` returns the nine-tier orientation guide.
    /// The guide must name every tier from Tier 1 through Tier 9, and its
    /// stated total tool count must match ToolProjection.tools() (vault-on).
    @Test func teachmeExpandsToTierBasedGuide() async throws {
        let dispatcher = try await makeDispatcher(ownerID: "sp-3")

        let result = try await dispatcher.dispatch(
            name: "moot_estate_status",
            arguments: .object(["teachme": .bool(true)]))

        #expect(!isErrorResult(result))
        let t = text(of: result)
        #expect(t.contains("Tier 1"), "guide must mention Tier 1")
        #expect(t.contains("Tier 9"), "guide must mention Tier 9")
        // Guide total is computed at runtime from ToolProjection.tools().
        // Verify it contains the live vault-on count so it never goes stale.
        let expectedVaultOnCount = ToolProjection.tools(environment: [:]).count
        #expect(t.contains("\(expectedVaultOnCount) tools"),
                "guide must state the live vault-on tool count (\(expectedVaultOnCount)); got: \(t)")
    }

    // MARK: - Test 3b: guide count matches live registry

    /// The tool count in the estate-status teachme guide matches ToolProjection's
    /// live vault-on count. This test enforces that the guide can never silently
    /// drift from the real tool surface.
    @Test func teachmeGuideCountMatchesRegistry() async throws {
        let dispatcher = try await makeDispatcher(ownerID: "sp-3b")

        let result = try await dispatcher.dispatch(
            name: "moot_estate_status",
            arguments: .object(["teachme": .bool(true)]))

        #expect(!isErrorResult(result))
        let t = text(of: result)

        // Both the vault-on and vault-off counts must appear in the guide text.
        // The guide is computed from ToolProjection.tools() so these must match.
        let vaultOn  = ToolProjection.tools(environment: [:]).count
        let vaultOff = ToolProjection.tools(environment: ["MOOTX01_VAULT": "0"]).count

        #expect(t.contains("\(vaultOn)"),
                "guide must contain vault-on count \(vaultOn); got guide excerpt: \(t.prefix(500))")
        #expect(t.contains("\(vaultOff)"),
                "guide must contain vault-off count \(vaultOff); got guide excerpt: \(t.prefix(500))")
    }

    // MARK: - Test 4: list_lenses returns all 27 cognition tools

    /// `moot_list_lenses` returns the full cognition menu with at least the
    /// 27 Tier 6 tools: `moot_synthesize`, `moot_lens_keystones`, and
    /// `moot_lens_concepts` must all appear in the response text.
    /// 27 = 26 baseline + moot_lens_node_motion.
    @Test func listLensesReturnsAllCognitionTools() async throws {
        let dispatcher = try await makeDispatcher(ownerID: "sp-4")

        let result = try await dispatcher.dispatch(
            name: "moot_list_lenses",
            arguments: .object([:]))

        #expect(!isErrorResult(result))
        let t = text(of: result)
        #expect(t.contains("moot_synthesize"),
                "moot_list_lenses must include moot_synthesize in the cognition menu")
        #expect(t.contains("moot_lens_keystones"),
                "moot_list_lenses must include moot_lens_keystones")
        #expect(t.contains("moot_lens_concepts"),
                "moot_list_lenses must include moot_lens_concepts")
        #expect(t.contains("27 cognition tools"),
                "moot_list_lenses must report 27 cognition tools")
    }

    // MARK: - Test 5: list_lenses teachme returns guide not menu

    /// `moot_list_lenses teachme:true` returns the static teachme guide for
    /// `moot_list_lenses`, not the runtime cognition menu. The two are
    /// distinguishable: the guide mentions "Common mistakes" or the tool name
    /// at the top; the runtime menu mentions "27 cognition tools".
    @Test func listLensesTeachmeReturnsGuideNotMenu() async throws {
        let dispatcher = try await makeDispatcher(ownerID: "sp-5")

        let teachmeResult = try await dispatcher.dispatch(
            name: "moot_list_lenses",
            arguments: .object(["teachme": .bool(true)]))
        let normalResult = try await dispatcher.dispatch(
            name: "moot_list_lenses",
            arguments: .object([:]))

        #expect(!isErrorResult(teachmeResult))
        #expect(!isErrorResult(normalResult))

        let teachmeText = text(of: teachmeResult)
        let normalText = text(of: normalResult)

        // The teachme guide must NOT be the runtime menu.
        #expect(!teachmeText.contains("27 cognition tools"),
                "teachme:true must return the guide, not the runtime menu")
        // The runtime menu must still contain the tool count.
        #expect(normalText.contains("27 cognition tools"),
                "normal call must return the cognition menu with tool count")
    }

    // MARK: - Test 6: protocol block is static

    /// Two consecutive `moot_estate_status` calls must return identical protocol
    /// text. The block is a static constant; it must not vary by call or by
    /// estate state changes between calls.
    @Test func protocolBlockIsStatic() async throws {
        let dispatcher = try await makeDispatcher(ownerID: "sp-6")

        let first = try await dispatcher.dispatch(
            name: "moot_estate_status",
            arguments: .object([:]))
        // File a memory to change estate state between the two calls.
        _ = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("state-change between calls"),
                "location": .string("sp-tests"),
            ]))
        let second = try await dispatcher.dispatch(
            name: "moot_estate_status",
            arguments: .object([:]))

        #expect(!isErrorResult(first))
        #expect(!isErrorResult(second))

        // Extract only the protocol block (everything from "protocol:" onward).
        func protocolSection(_ t: String) -> String {
            guard let range = t.range(of: "protocol:") else { return "" }
            return String(t[range.lowerBound...])
        }

        let firstProtocol = protocolSection(text(of: first))
        let secondProtocol = protocolSection(text(of: second))

        #expect(!firstProtocol.isEmpty, "first call must include protocol block")
        #expect(firstProtocol == secondProtocol,
                "protocol block must be identical across consecutive calls")
    }
}
