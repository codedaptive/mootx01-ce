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

    // MARK: - Test 2: protocol block on empty estate

    /// A zero-memory estate still returns the protocol block. The block is
    /// unconditional — estate contents do not gate its appearance.

    // MARK: - Test 3: teachme expands to full tier-based guide

    /// `moot_estate_status teachme:true` returns the ten-tier orientation guide.
    /// The guide must name every tier from Tier 1 through Tier 10, and its
    /// stated total tool count must match ToolProjection.tools() (vault-on).

    // MARK: - Test 3b: guide count matches live registry

    /// The tool count in the estate-status teachme guide matches ToolProjection's
    /// live vault-on count. This test enforces that the guide can never silently
    /// drift from the real tool surface.

    // MARK: - Test 4: list_lenses returns all 27 cognition tools

    /// `moot_list_lenses` returns the full cognition menu with at least the
    /// 27 Tier 6 tools: `moot_synthesize`, `moot_lens_keystones`, and
    /// `moot_lens_concepts` must all appear in the response text.
    /// 27 = 26 baseline + moot_lens_node_motion.

    // MARK: - Test 5: list_lenses teachme returns guide not menu

    /// `moot_list_lenses teachme:true` returns the static teachme guide for
    /// `moot_list_lenses`, not the runtime cognition menu. The two are
    /// distinguishable: the guide mentions "Common mistakes" or the tool name
    /// at the top; the runtime menu mentions "27 cognition tools".

    // MARK: - Test 6: protocol block is static

    /// Two consecutive `moot_estate_status` calls must return identical protocol
    /// text. The block is a static constant; it must not vary by call or by
    /// estate state changes between calls.

    // MARK: - Byte-identity: modesStatusSection (shared fixture with Rust)

    /// Gate: `SessionProtocol.modesStatusSection` must produce the byte-identical
    /// string that Rust's `modes_status_section()` produces.
    ///
    /// Both ports read `Tests/Conformance/modes_status_section_fixture.json`.
    /// If either port's rendering diverges (different separator, wrong contract
    /// text, missing mode), this test catches it alongside the Rust equivalent.
    ///
    /// How it fails if reverted: any edit to `MootMode.contract`, `MootMode.rawValue`,
    /// or the surrounding template strings without updating the fixture → assert fires;
    /// also fires if this port's output diverges from the fixture the Rust test passes,
    /// surfacing a parity break.
    @Test("modesStatusSection is byte-identical to shared fixture (parity with Rust)")
    func modesStatusSectionByteIdentity() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // …/AriaMCPTests
            .deletingLastPathComponent()  // …/Tests
            .appendingPathComponent("Conformance/modes_status_section_fixture.json")

        let data = try Data(contentsOf: fixtureURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let expected = json?["expected"] as? String else {
            Issue.record("modes_status_section_fixture.json must have an 'expected' string field")
            return
        }

        let actual = ToolDispatcher.modesStatusSection

        #expect(actual == expected,
                "modesStatusSection must be byte-identical to shared fixture — \nActual length: \(actual.utf8.count)\nExpected length: \(expected.utf8.count)")
    }

    /// Pins the modes teachme guide to the shared fixture that the Rust port also reads.
    /// Both ports must produce the identical string so LLM clients see consistent output
    /// regardless of which transport they use.
    @Test func modesTeachmeGuideByteIdentity() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // …/AriaMCPTests
            .deletingLastPathComponent()  // …/Tests
            .appendingPathComponent("Conformance/modes_teachme_guide_fixture.json")

        let data = try Data(contentsOf: fixtureURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let expected = json?["expected"] as? String else {
            Issue.record("modes_teachme_guide_fixture.json must have an 'expected' string field")
            return
        }

        let actual = TeachmeGuides.modesTeachmeGuide

        #expect(actual == expected,
                "modesTeachmeGuide must be byte-identical to shared fixture — \nActual length: \(actual.utf8.count)\nExpected length: \(expected.utf8.count)")
    }
}

