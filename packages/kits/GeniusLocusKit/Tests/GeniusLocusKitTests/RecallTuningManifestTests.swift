// RecallTuningManifestTests.swift
//
// Tests for the optimizer-owned "recall_tuning" manifest key and the
// RecallTuningManifest type. Covers:
//
//   (a) Spec defaults — .default fields match the hardcoded spec constants.
//   (b) Codable round-trip — encode + decode produces the same value.
//   (c) Absent key — provisionedRecallTuning(for:) returns .default when
//       no manifest key is present (byte-identical to today's behavior).
//   (d) Partial JSON — a JSON with only some keys fills absent keys with
//       spec defaults.
//   (e) Malformed JSON — fail-quiet: returns .default rather than throwing.
//   (f) Golden pin — provision a non-default tuning, read it back, verify
//       all four fields match. Uses k=80, λ=0.6, bm25=0.4, vector=0.6.
//   (g) provisionRecallTuning / provisionedRecallTuning verb round-trip on
//       a live (in-memory) estate.

import Testing
import Foundation
import PersistenceKit
import PersistenceKitInMemory
import LocusKit
@testable import GeniusLocusKit

// MARK: - RecallTuningManifest unit tests (no estate needed)

@Suite("RecallTuningManifest — type and coding")
struct RecallTuningManifestTypeTests {

    // MARK: (a) Spec defaults

    @Test("default rrfK is 60 (spec § 4.1)")
    func defaultRrfKIs60() {
        #expect(RecallTuningManifest.default.rrfK == 60)
    }

    @Test("default mmrLambda is 0.7 (spec § 4.1)")
    func defaultMmrLambdaIs07() {
        #expect(abs(RecallTuningManifest.default.mmrLambda - 0.7) < 1e-6)
    }

    @Test("default rrfBm25Weight is 0.3 (spec § 4.1)")
    func defaultRrfBm25WeightIs03() {
        #expect(abs(RecallTuningManifest.default.rrfBm25Weight - 0.3) < 1e-6)
    }

    @Test("default rrfVectorWeight is 0.7 (spec § 4.1)")
    func defaultRrfVectorWeightIs07() {
        #expect(abs(RecallTuningManifest.default.rrfVectorWeight - 0.7) < 1e-6)
    }

    @Test("two .default instances are equal")
    func defaultIsEqualToDefault() {
        #expect(RecallTuningManifest.default == RecallTuningManifest.default)
    }

    // MARK: (b) Codable round-trip

    @Test("encode + decode produces identical value")
    func codableRoundTrip() throws {
        let original = RecallTuningManifest(rrfK: 80, mmrLambda: 0.6, rrfBm25Weight: 0.4, rrfVectorWeight: 0.6)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(RecallTuningManifest.self, from: data)
        #expect(decoded == original)
    }

    @Test("encoded JSON uses snake_case keys")
    func encodedJSONUsesSnakeCaseKeys() throws {
        let tuning = RecallTuningManifest(rrfK: 80, mmrLambda: 0.6, rrfBm25Weight: 0.4, rrfVectorWeight: 0.6)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(tuning), as: UTF8.self)
        // Verify the four wire keys appear in the output.
        #expect(json.contains("\"mmr_lambda\""))
        #expect(json.contains("\"rrf_bm25_weight\""))
        #expect(json.contains("\"rrf_k\""))
        #expect(json.contains("\"rrf_vector_weight\""))
    }

    // MARK: (d) Partial JSON

    @Test("partial JSON fills absent keys with spec defaults")
    func partialJSONFillsDefaults() throws {
        // Only rrf_k is present; the other three should resolve to spec defaults.
        let partialJSON = """
        {"rrf_k": 80}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RecallTuningManifest.self, from: partialJSON)
        #expect(decoded.rrfK == 80)
        #expect(abs(decoded.mmrLambda - 0.7) < 1e-6)
        #expect(abs(decoded.rrfBm25Weight - 0.3) < 1e-6)
        #expect(abs(decoded.rrfVectorWeight - 0.7) < 1e-6)
    }

    // MARK: (e) Malformed JSON

    @Test("malformed JSON decode returns nil (not a throw in the fail-quiet path)")
    func malformedJSONDecodesNil() {
        let bad = "not-json".data(using: .utf8)!
        let result = try? JSONDecoder().decode(RecallTuningManifest.self, from: bad)
        // The fail-quiet path in provisionedRecallTuning uses `try?` — the type
        // itself may throw; this test verifies the consumer fallback is sound.
        #expect(result == nil)
    }

    // MARK: (f) Golden pin — non-default tuning

    @Test("golden pin: k=80 λ=0.6 bm25=0.4 vector=0.6 round-trips exactly")
    func goldenPinNonDefaultTuning() throws {
        // The optimizer would emit this tuning to a well-tuned estate.
        // Pin: k=80, λ=0.6, bm25=0.4, vector=0.6 — all differ from spec.
        let pinJSON = """
        {"mmr_lambda":0.6,"rrf_bm25_weight":0.4,"rrf_k":80,"rrf_vector_weight":0.6}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RecallTuningManifest.self, from: pinJSON)
        #expect(decoded.rrfK == 80)
        #expect(abs(decoded.mmrLambda - 0.6) < 1e-6)
        #expect(abs(decoded.rrfBm25Weight - 0.4) < 1e-6)
        #expect(abs(decoded.rrfVectorWeight - 0.6) < 1e-6)
        #expect(decoded != RecallTuningManifest.default)
    }
}

// MARK: - Estate verb round-trip tests (in-memory estate)

@Suite("RecallTuningManifest — estate verb round-trip", .serialized)
struct RecallTuningManifestEstateTests {

    private func openEmptyEstate(owner ownerID: String = "tuning-test") async throws
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

    @Test("absent recall_tuning key returns spec-default tuning")
    func absentKeyReturnsDefault() async throws {
        let (kit, handle) = try await openEmptyEstate(owner: "absent-key-test")
        let tuning = try await kit.provisionedRecallTuning(for: handle)
        #expect(tuning == RecallTuningManifest.default)
    }

    // MARK: (g) Provision + read-back

    @Test("provisioned tuning reads back unchanged")
    func provisionedTuningReadsBack() async throws {
        let (kit, handle) = try await openEmptyEstate(owner: "provision-readback-test")
        let written = RecallTuningManifest(rrfK: 80, mmrLambda: 0.6, rrfBm25Weight: 0.4, rrfVectorWeight: 0.6)
        try await kit.provisionRecallTuning(written, for: handle)
        let read = try await kit.provisionedRecallTuning(for: handle)
        #expect(read == written)
    }

    @Test("provisioned tuning overwrite is reflected on next read")
    func provisionedTuningOverwrite() async throws {
        let (kit, handle) = try await openEmptyEstate(owner: "overwrite-test")
        let first = RecallTuningManifest(rrfK: 80, mmrLambda: 0.6, rrfBm25Weight: 0.4, rrfVectorWeight: 0.6)
        try await kit.provisionRecallTuning(first, for: handle)
        let second = RecallTuningManifest(rrfK: 100, mmrLambda: 0.5, rrfBm25Weight: 0.5, rrfVectorWeight: 0.5)
        try await kit.provisionRecallTuning(second, for: handle)
        let read = try await kit.provisionedRecallTuning(for: handle)
        #expect(read == second)
        #expect(read != first)
    }

    @Test("provisioning default tuning reads back as default")
    func provisioningDefaultTuning() async throws {
        let (kit, handle) = try await openEmptyEstate(owner: "default-provision-test")
        try await kit.provisionRecallTuning(.default, for: handle)
        let read = try await kit.provisionedRecallTuning(for: handle)
        #expect(read == RecallTuningManifest.default)
    }
}
