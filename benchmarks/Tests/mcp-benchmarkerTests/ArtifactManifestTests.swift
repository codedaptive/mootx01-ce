// ArtifactManifestTests.swift — unit tests for ArtifactManifest.swift.
//
// Covers:
//   - FIX_GATE: artifacts from an older format era are REFUSED by
//     mismatches(against:) after a format-version bump.
//   - GUARD: makeArtifactProvenance (the production factory) stamps format version 3;
//     the test calls the factory directly and asserts against the independent
//     literal 3 so it fails if the factory hard-codes a stale value, even when
//     the constant itself has not moved. Update the literal in both ports when
//     the format version is intentionally bumped.

import Foundation
import Testing
@testable import mcp_benchmarker

// MARK: - Fixture

/// Minimal valid provenance for testing. Mirrors the Rust `prov()` fixture so
/// cross-port comparisons are straightforward.
private func testProvenance() -> ArtifactProvenance {
    ArtifactProvenance(
        formatVersion: artifactFormatVersion,
        benchmark: "lme", variant: "s", seed: 7,
        encodeBarrier: "drain", estatePosture: "plaintext-optout",
        seedPath: "batch",
        corpusDigest: "deadbeef", embeddingModels: ["binary-default"],
        mootx01Version: "unknown", protocolVersion: "v0.1",
        markersPresent: true, estateSchemaVersion: currentEstateSchemaVersion)
}

// MARK: - FIX_GATE

/// FIX_GATE — an artifact from an older format era is REFUSED.
///
/// Format-version history: 1 = pre-settle snapshots; 2 = B4 settled-estate
/// protocol; 3 = the retired build axes were removed from the manifest. An
/// on-disk artifact carrying an older version was built under a different
/// regime; handing it back as a cache hit contaminates the run, so
/// mismatches(against:) must report format_version first.
@Test func olderFormatVersionRefused() {
    let expected = testProvenance()             // stamps current artifactFormatVersion
    var onDisk = testProvenance()
    onDisk = ArtifactProvenance(
        formatVersion: 1,                       // simulate a pre-settle artifact
        benchmark: onDisk.benchmark, variant: onDisk.variant, seed: onDisk.seed,
        encodeBarrier: onDisk.encodeBarrier, estatePosture: onDisk.estatePosture,
        seedPath: onDisk.seedPath,
        corpusDigest: onDisk.corpusDigest,
        embeddingModels: onDisk.embeddingModels, mootx01Version: onDisk.mootx01Version,
        protocolVersion: onDisk.protocolVersion, markersPresent: onDisk.markersPresent,
        estateSchemaVersion: onDisk.estateSchemaVersion)
    let m = onDisk.mismatches(against: expected)
    #expect(!m.isEmpty,
        "an older-format artifact (formatVersion=1) must be refused; got no mismatches")
    #expect(m.contains(where: { $0.hasPrefix("format_version:") }),
        "mismatch must name 'format_version' so the user knows why the cache was invalidated: \(m)")
}

// MARK: - GUARD

/// GUARD — makeArtifactProvenance stamps format version 3.
///
/// The production factory must write the current format version (3) into the
/// provenance struct. This test calls makeArtifactProvenance directly — NOT
/// testProvenance(), which builds ArtifactProvenance without going through the
/// factory and cannot detect a stale literal hard-coded inside the factory.
///
/// The expectation is the independent literal 3, not the artifactFormatVersion
/// symbol. If the symbol and the factory both carry the same value, asserting
/// p.formatVersion == artifactFormatVersion proves nothing: a factory that
/// hard-codes 3 and a constant that also equals 3 both pass. Writing the
/// expected value as a literal means the test fails the moment the factory
/// drifts, regardless of what the constant says.
///
/// When you intentionally bump artifactFormatVersion, update this literal in
/// BOTH ports (here and in artifact_manifest.rs:make_artifact_provenance_stamps_constant)
/// as a deliberate, coordinated act — that synchronisation is the point of the guard.
@Test func makeArtifactProvenanceStampsConstant() {
    // Call the production factory directly so a stale literal inside it is detectable.
    let p = makeArtifactProvenance(
        benchmark: "lme", variant: "s", seed: 7,
        encodeBarrier: .drain, posture: .plaintextTransient,
        seedPath: .batch, corpusDigest: "deadbeef",
        mootx01Version: "unknown")
    #expect(p.formatVersion == 3,
        "makeArtifactProvenance must stamp version 3; if you bumped artifactFormatVersion, update this literal in both ports")
}

// MARK: - Cross-port decode

/// CROSS-PORT GATE — Swift decodes a Rust-written artifact.json.
///
/// The fixture `artifact_rust_written.json` was PRODUCED BY THE RUST PORT's
/// `write_artifact_provenance` (serde_json pretty-printer, struct field
/// order) from fixed literal inputs. This test proves the Swift decoder
/// reads the Rust writer's bytes field-for-field, and that a decoded
/// artifact validates cleanly against an identically-configured Swift
/// expectation — the property cross-port cache sharing rests on. The Rust
/// twin (tests/cross_port_artifact.rs) decodes the Swift-written fixture.
@Test func decodesRustWrittenArtifact() throws {
    let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("artifact_rust_written.json")
    // loadArtifactProvenance expects the entry DIRECTORY containing artifact.json;
    // decode the fixture file directly with the same decoder instead.
    let data = try Data(contentsOf: fixture)
    let p = try JSONDecoder().decode(ArtifactProvenance.self, from: data)
    #expect(p.formatVersion == 3)
    #expect(p.benchmark == "crossport")
    #expect(p.variant == "s")
    #expect(p.seed == 424242)
    #expect(p.encodeBarrier == "drain")
    #expect(p.estatePosture == "plaintext-optout")
    #expect(p.seedPath == "batch")
    #expect(p.corpusDigest == "cafef00d")
    #expect(p.embeddingModels == ["binary-default"])
    #expect(p.mootx01Version == "unknown")
    #expect(p.protocolVersion == "test-protocol")
    #expect(p.markersPresent == true)
    #expect(p.estateSchemaVersion == "1.1")
    // A run expecting exactly this configuration must accept the artifact.
    let expected = ArtifactProvenance(
        formatVersion: 3, benchmark: "crossport", variant: "s", seed: 424242,
        encodeBarrier: "drain", estatePosture: "plaintext-optout",
        seedPath: "batch", corpusDigest: "cafef00d",
        embeddingModels: ["binary-default"], mootx01Version: "unknown",
        protocolVersion: "test-protocol", markersPresent: true,
        estateSchemaVersion: "1.1")
    #expect(p.mismatches(against: expected).isEmpty,
        "a Rust-written artifact must validate cleanly against the same run configuration")
}
