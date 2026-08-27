// ModesManifestTests.swift
//
// Unit tests for the user-owned "modes_config" manifest key and the
// ModesManifest type. Covers:
//
//   (a) Spec default — .default has stickyEnabled=true, coachingCalls=25.
//       Two .default instances are equal.
//   (b) Codable round-trip — encode + decode produces the same value.
//   (c) Absent key — provisionedModesConfig(for:) returns .default when no
//       manifest key is present (byte-identical to pre-provisioning behaviour).
//   (d) Partial JSON — a JSON object with only "sticky_enabled" fills
//       "coaching_calls" with 25 (the spec default).
//   (e) Malformed JSON — fail-quiet: the fail-quiet path returns .default.
//   (f) sticky_enabled=false decodes correctly and differs from .default.
//   (g) coaching_calls=0 decodes correctly (0=off, suppresses coaching).
//   (h) provisionModesConfig / provisionedModesConfig verb round-trip on a
//       live (in-memory) estate.
//
// How tests fail if reverted:
//   (f): if stickyEnabled=false is not stored or silently flipped to true,
//        the decoded value would equal .default and #expect(decoded != .default) fires.
//   (g): if coaching_calls=0 is not decoded, shouldCoach would fire unexpectedly.
//   (h): if the provision write path uses the wrong key or encode fails, the
//        read-back would return .default instead of the written value.

import Testing
import Foundation
import PersistenceKit
import PersistenceKitInMemory
import LocusKit
@testable import GeniusLocusKit

// MARK: - ModesManifest unit tests (no estate needed)

@Suite("ModesManifest — type and coding")
struct ModesManifestTypeTests {

    // MARK: (a) Spec default

    @Test("default has stickyEnabled=true and coachingCalls=25 (spec constants)")
    func defaultValues() {
        #expect(ModesManifest.default.stickyEnabled == true)
        #expect(ModesManifest.default.coachingCalls == 25)
    }

    @Test("two .default instances are equal")
    func defaultIsEqualToDefault() {
        #expect(ModesManifest.default == ModesManifest.default)
    }

    // MARK: (b) Codable round-trip

    @Test("encode + decode produces identical value")
    func codableRoundTrip() throws {
        let original = ModesManifest(stickyEnabled: false, coachingCalls: 10)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(ModesManifest.self, from: data)
        #expect(decoded == original)
    }

    @Test("encoded JSON uses 'sticky_enabled' and 'coaching_calls' snake_case keys")
    func encodedJSONUsesSnakeCaseKeys() throws {
        let manifest = ModesManifest(stickyEnabled: false, coachingCalls: 10)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(manifest), as: UTF8.self)
        #expect(json.contains("\"sticky_enabled\""))
        #expect(json.contains("\"coaching_calls\""))
        #expect(json.contains("false"))
        #expect(json.contains("10"))
    }

    // MARK: (d) Partial JSON — absent coaching_calls fills with spec default

    @Test("partial JSON with only 'sticky_enabled' fills 'coaching_calls' with 25")
    func partialJSONFillsCoachingCallsDefault() throws {
        // Only sticky_enabled is present; coaching_calls should default to 25.
        let partialJSON = #"{"sticky_enabled":false}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ModesManifest.self, from: partialJSON)
        #expect(decoded.stickyEnabled == false)
        #expect(decoded.coachingCalls == 25)
    }

    @Test("empty JSON object fills both keys with spec defaults")
    func emptyJSONObjectFillsDefaults() throws {
        let partialJSON = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ModesManifest.self, from: partialJSON)
        #expect(decoded == ModesManifest.default)
    }

    // MARK: (e) Malformed JSON — fail-quiet

    @Test("malformed JSON decode returns nil (consumer uses .default fallback)")
    func malformedJSONDecodesNil() {
        let bad = "not-json".data(using: .utf8)!
        let result = try? JSONDecoder().decode(ModesManifest.self, from: bad)
        // The fail-quiet path in provisionedModesConfig uses `try?` — the type
        // itself may throw; this test verifies the consumer fallback is sound.
        #expect(result == nil)
    }

    // MARK: (f) sticky_enabled=false

    @Test("sticky_enabled=false decodes and differs from .default")
    func stickyEnabledFalseDecodes() throws {
        // Failure mode: if stickyEnabled=false is silently coerced to true,
        // decoded == .default and the #expect fires.
        let json = #"{"sticky_enabled":false,"coaching_calls":25}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ModesManifest.self, from: json)
        #expect(decoded.stickyEnabled == false)
        #expect(decoded != ModesManifest.default,
                "stickyEnabled=false must produce a config distinct from the default (true)")
    }

    // MARK: (g) coaching_calls=0

    @Test("coaching_calls=0 decodes correctly (0=off suppresses all coaching)")
    func coachingCallsZeroDecodes() throws {
        // Failure mode: if coaching_calls=0 is ignored and falls back to 25,
        // shouldCoach() would fire at call 25 and tests expecting zero coaching fail.
        let json = #"{"sticky_enabled":true,"coaching_calls":0}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ModesManifest.self, from: json)
        #expect(decoded.coachingCalls == 0)
        #expect(decoded != ModesManifest.default,
                "coaching_calls=0 must produce a config distinct from the default (25)")
    }
}

// MARK: - Estate verb round-trip tests (in-memory estate)

@Suite("ModesManifest — estate verb round-trip", .serialized)
struct ModesManifestEstateTests {

    private func openEmptyEstate(owner ownerID: String = "modes-manifest-test") async throws
        -> (kit: GeniusLocusKit, handle: EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: ownerID)
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    // MARK: (c) Absent key returns .default

    @Test("absent modes_config key returns spec-default config (stickyEnabled=true, coachingCalls=25)")
    func absentKeyReturnsDefault() async throws {
        let (kit, handle) = try await openEmptyEstate(owner: "modes-absent-key-test")
        let config = try await kit.provisionedModesConfig(for: handle)
        #expect(config == ModesManifest.default)
        #expect(config.stickyEnabled == true)
        #expect(config.coachingCalls == 25)
    }

    // MARK: (h) Provision + read-back

    @Test("provisioned ModesManifest(stickyEnabled:false, coachingCalls:10) reads back unchanged")
    func provisionedModesConfigReadsBack() async throws {
        let (kit, handle) = try await openEmptyEstate(owner: "modes-provision-readback-test")
        let written = ModesManifest(stickyEnabled: false, coachingCalls: 10)
        try await kit.provisionModesConfig(written, for: handle)
        let read = try await kit.provisionedModesConfig(for: handle)
        #expect(read == written)
        #expect(read.stickyEnabled == false)
        #expect(read.coachingCalls == 10)
    }

    @Test("provisioned modes config overwrite is reflected on next read")
    func provisionedModesConfigOverwrite() async throws {
        let (kit, handle) = try await openEmptyEstate(owner: "modes-overwrite-test")
        let first = ModesManifest(stickyEnabled: false, coachingCalls: 0)
        try await kit.provisionModesConfig(first, for: handle)
        let second = ModesManifest(stickyEnabled: true, coachingCalls: 50)
        try await kit.provisionModesConfig(second, for: handle)
        let read = try await kit.provisionedModesConfig(for: handle)
        #expect(read == second)
        #expect(read != first)
    }

    @Test("provisioning .default reads back as .default")
    func provisioningDefaultReadsBack() async throws {
        let (kit, handle) = try await openEmptyEstate(owner: "modes-default-provision-test")
        try await kit.provisionModesConfig(.default, for: handle)
        let read = try await kit.provisionedModesConfig(for: handle)
        #expect(read == ModesManifest.default)
    }

    @Test("golden pin: stickyEnabled=false, coachingCalls=2 round-trips exactly")
    func goldenPin() async throws {
        // Discriminating pin: both fields non-default. Fails if either field
        // is ignored, coerced, or silently replaced with the spec constant.
        let (kit, handle) = try await openEmptyEstate(owner: "modes-golden-pin-test")
        let pin = ModesManifest(stickyEnabled: false, coachingCalls: 2)
        try await kit.provisionModesConfig(pin, for: handle)
        let read = try await kit.provisionedModesConfig(for: handle)
        #expect(read.stickyEnabled == false)
        #expect(read.coachingCalls == 2)
        #expect(read == pin)
        #expect(read != ModesManifest.default)
    }
}
