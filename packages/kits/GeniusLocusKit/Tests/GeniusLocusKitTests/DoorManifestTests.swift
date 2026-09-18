// DoorManifestTests.swift
//
// Unit tests for the optimizer-owned "door_config" manifest key and the
// DoorManifest type. Covers:
//
//   (a) Spec default — .default scoring is .matrixAware (the pre-front-door
//       constant). Two .default instances are equal.
//   (b) Codable round-trip — encode + decode produces the same value.
//   (c) Absent key — provisionedDoorConfig(for:) returns .default when no
//       manifest key is present (byte-identical to pre-front-door behaviour).
//   (d) Partial JSON — a JSON object with no "scoring" key fills with the
//       spec default (.matrixAware).
//   (e) Malformed JSON — fail-quiet: returns nil from the fail-quiet decode
//       path (provisionedDoorConfig uses `try?`).
//   (f) Unknown scoring string — falls back to .matrixAware rather than
//       throwing. A future kit version may emit a scoring string this port
//       does not recognise; the call must degrade gracefully.
//   (g) Golden pin — provision DoorManifest(scoring: .rrf), read it back,
//       verify it round-trips exactly and differs from .default.
//   (h) provisionDoorConfig / provisionedDoorConfig verb round-trip on a
//       live (in-memory) estate. Mirrors RecallTuningManifestTests.

import Testing
import Foundation
import PersistenceKit
import PersistenceKitInMemory
import LocusKit
@testable import GeniusLocusKit

// MARK: - DoorManifest unit tests (no estate needed)

@Suite("DoorManifest — type and coding")
struct DoorManifestTypeTests {

    // MARK: (a) Spec default

    @Test("default scoring is .matrixAware (the pre-front-door constant)")
    func defaultScoringIsMatrixAware() {
        #expect(DoorManifest.default.scoring == .matrixAware)
    }

    @Test("two .default instances are equal")
    func defaultIsEqualToDefault() {
        #expect(DoorManifest.default == DoorManifest.default)
    }

    // MARK: (b) Codable round-trip

    @Test("encode + decode produces identical value")
    func codableRoundTrip() throws {
        let original = DoorManifest(scoring: .rrf)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(DoorManifest.self, from: data)
        #expect(decoded == original)
    }

    @Test("encoded JSON uses 'scoring' key")
    func encodedJSONUsesScoringKey() throws {
        let manifest = DoorManifest(scoring: .rrf)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(manifest), as: UTF8.self)
        #expect(json.contains("\"scoring\""))
        // Wire value is the GLKRecallScoring rawValue "rrf"
        #expect(json.contains("\"rrf\""))
    }

    // MARK: (d) Partial JSON — absent scoring key fills with spec default

    @Test("partial JSON with no 'scoring' key fills with spec default (.matrixAware)")
    func partialJSONFillsDefault() throws {
        // An empty JSON object has no "scoring" key — should fall back to .matrixAware.
        let partialJSON = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DoorManifest.self, from: partialJSON)
        #expect(decoded.scoring == .matrixAware)
        #expect(decoded == DoorManifest.default)
    }

    // MARK: (e) Malformed JSON — fail-quiet

    @Test("malformed JSON decode returns nil (not a throw in the fail-quiet path)")
    func malformedJSONDecodesNil() {
        let bad = "not-json".data(using: .utf8)!
        let result = try? JSONDecoder().decode(DoorManifest.self, from: bad)
        // The fail-quiet path in provisionedDoorConfig uses `try?` — the type
        // itself may throw; this test verifies the consumer fallback is sound.
        #expect(result == nil)
    }

    // MARK: (f) Unknown scoring string — falls back to .matrixAware

    @Test("unknown scoring string in JSON falls back to .matrixAware (fail-quiet)")
    func unknownScoringStringFallsBackToMatrixAware() throws {
        // "thorough" is a reserved future scoring name not yet implemented.
        // The decode must not throw — it must return .matrixAware instead.
        let json = #"{"scoring":"thorough"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DoorManifest.self, from: json)
        #expect(decoded.scoring == .matrixAware)
        #expect(decoded == DoorManifest.default)
    }

    // MARK: (g) Golden pin — rrf round-trips exactly

    @Test("golden pin: scoring=rrf round-trips exactly and differs from .default")
    func goldenPinRrfRoundTrips() throws {
        // The optimizer emits {"scoring":"rrf"} for corpus arms where RRF outperforms
        // matrixAware. Pin: encoding and decoding this must produce scoring==.rrf.
        let pinJSON = #"{"scoring":"rrf"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DoorManifest.self, from: pinJSON)
        #expect(decoded.scoring == .rrf)
        #expect(decoded != DoorManifest.default)
    }
}

// MARK: - Estate verb round-trip tests (in-memory estate)

@Suite("DoorManifest — estate verb round-trip", .serialized)
struct DoorManifestEstateTests {

    private func openEmptyEstate(owner ownerID: String = "door-manifest-test") async throws
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

    @Test("absent door_config key returns spec-default config (.matrixAware)")
    func absentKeyReturnsDefault() async throws {
        let (kit, handle) = try await openEmptyEstate(owner: "door-absent-key-test")
        let config = try await kit.provisionedDoorConfig(for: handle)
        #expect(config == DoorManifest.default)
        #expect(config.scoring == .matrixAware)
    }

    // MARK: (h) Provision + read-back

    @Test("provisioned DoorManifest(scoring:.rrf) reads back unchanged")
    func provisionedDoorConfigReadsBack() async throws {
        let (kit, handle) = try await openEmptyEstate(owner: "door-provision-readback-test")
        let written = DoorManifest(scoring: .rrf)
        try await kit.provisionDoorConfig(written, for: handle)
        let read = try await kit.provisionedDoorConfig(for: handle)
        #expect(read == written)
        #expect(read.scoring == .rrf)
    }

    @Test("provisioned door config overwrite is reflected on next read")
    func provisionedDoorConfigOverwrite() async throws {
        let (kit, handle) = try await openEmptyEstate(owner: "door-overwrite-test")
        let first = DoorManifest(scoring: .rrf)
        try await kit.provisionDoorConfig(first, for: handle)
        let second = DoorManifest(scoring: .matrixAware)
        try await kit.provisionDoorConfig(second, for: handle)
        let read = try await kit.provisionedDoorConfig(for: handle)
        #expect(read == second)
        #expect(read != first)
    }

    @Test("provisioning .default reads back as .default (.matrixAware)")
    func provisioningDefaultReadsBack() async throws {
        let (kit, handle) = try await openEmptyEstate(owner: "door-default-provision-test")
        try await kit.provisionDoorConfig(.default, for: handle)
        let read = try await kit.provisionedDoorConfig(for: handle)
        #expect(read == DoorManifest.default)
    }
}
