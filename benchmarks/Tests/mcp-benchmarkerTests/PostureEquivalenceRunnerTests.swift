import Testing
import Foundation
@testable import mcp_benchmarker

// PostureEquivalenceRunnerTests — shape tests for PostureEquivalenceReport
// and IdentityEnvironment.
//
// These tests verify the artifact schema WITHOUT launching a live estate.
// They confirm:
//   1. PostureEquivalenceReport encodes all required accuracy-lane fields and
//      NONE of the prohibited timing-lane fields (run_mode, load_average_1m,
//      logical_cpus, hostname, chip_name, ram_bytes, etc.).
//   2. IdentityEnvironment encodes exactly the three identity fields
//      (mootx01_binary_sha256, mootx01_version, protocol_version) and nothing
//      else — no machine metrics, no run_mode.
//
// The doctrine source is the operator's 2026-08-18 ruling: accuracy reports contain NO
// timing columns; the environment block is IDENTITY ONLY.

@Suite("Posture-equivalence report shape")
struct PostureEquivalenceRunnerTests {

    // ── Fixture ───────────────────────────────────────────────────────────

    private func makeReport(divergent: Bool = false) -> PostureEquivalenceReport {
        let identity = IdentityEnvironment(
            mootx01BinarySha256: "aabbccdd",
            mootx01Version:      "1.1",
            protocolVersion:     "v0.1")

        let divergences: [PostureEquivDivergence]
        if divergent {
            divergences = [PostureEquivDivergence(
                probeIndex: 3,
                plaintextRanks: ["uuid-a", "uuid-b"],
                encryptedRanks: ["uuid-b", "uuid-a"])]
        } else {
            divergences = []
        }

        return PostureEquivalenceReport(
            runEnvironment: identity,
            seed: 20_260_813,
            rowsIngested: postureEquivDefaultRows,
            probesCompared: postureEquivDefaultProbes,
            identicalCount: postureEquivDefaultProbes - divergences.count,
            divergentCount: divergences.count,
            divergences: divergences)
    }

    // ── Identity field presence ───────────────────────────────────────────

    @Test("IdentityEnvironment encodes exactly three identity fields")
    func identityEnvironmentFieldSet() throws {
        let identity = IdentityEnvironment(
            mootx01BinarySha256: "sha",
            mootx01Version:      "1.1",
            protocolVersion:     "v0.1")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(identity)
        let json = try #require(String(data: data, encoding: .utf8))

        // Required fields.
        #expect(json.contains("\"mootx01_binary_sha256\""))
        #expect(json.contains("\"mootx01_version\""))
        #expect(json.contains("\"protocol_version\""))

        // Machine metrics must be absent — these are the timing-lane fields
        // that the 2026-08-18 doctrine prohibits from accuracy artifacts.
        #expect(!json.contains("\"run_mode\""),
            "run_mode must not appear in IdentityEnvironment")
        #expect(!json.contains("\"load_average_1m\""),
            "load_average_1m must not appear in IdentityEnvironment")
        #expect(!json.contains("\"logical_cpus\""),
            "logical_cpus must not appear in IdentityEnvironment")
        #expect(!json.contains("\"hostname\""),
            "hostname must not appear in IdentityEnvironment")
        #expect(!json.contains("\"chip_name\""),
            "chip_name must not appear in IdentityEnvironment")
        #expect(!json.contains("\"ram_bytes\""),
            "ram_bytes must not appear in IdentityEnvironment")
        #expect(!json.contains("\"disk_bytes\""),
            "disk_bytes must not appear in IdentityEnvironment")
        #expect(!json.contains("\"macos_version\""),
            "macos_version must not appear in IdentityEnvironment")
        #expect(!json.contains("\"model_name\""),
            "model_name must not appear in IdentityEnvironment")
    }

    // ── Report field presence ─────────────────────────────────────────────

    @Test("PostureEquivalenceReport encodes all required accuracy fields")
    func reportRequiredFields() throws {
        let report = makeReport()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(report)
        let json = try #require(String(data: data, encoding: .utf8))

        // All required top-level fields.
        #expect(json.contains("\"run_environment\""))
        #expect(json.contains("\"seed\""))
        #expect(json.contains("\"rows_ingested\""))
        #expect(json.contains("\"probes_compared\""))
        #expect(json.contains("\"identical_count\""))
        #expect(json.contains("\"divergent_count\""))
        #expect(json.contains("\"divergences\""))

        // Identity sub-fields embedded under run_environment.
        #expect(json.contains("\"mootx01_binary_sha256\""))
        #expect(json.contains("\"mootx01_version\""))
        #expect(json.contains("\"protocol_version\""))
    }

    @Test("PostureEquivalenceReport contains no timing-lane fields")
    func reportNoTimingFields() throws {
        let report = makeReport()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(report)
        let json = try #require(String(data: data, encoding: .utf8))

        // Timing-lane fields are prohibited by the 2026-08-18 doctrine.
        // run_mode: declares machine quietness — belongs only in RunEnvironment.
        #expect(!json.contains("\"run_mode\""),
            "run_mode must not appear in a posture-equivalence artifact")
        // load_average_1m / logical_cpus: measured machine load — timing lane only.
        #expect(!json.contains("\"load_average_1m\""),
            "load_average_1m must not appear in a posture-equivalence artifact")
        #expect(!json.contains("\"logical_cpus\""),
            "logical_cpus must not appear in a posture-equivalence artifact")
        // Full machine profile fields — identity block only in accuracy artifacts.
        #expect(!json.contains("\"hostname\""),
            "hostname must not appear in a posture-equivalence artifact")
        #expect(!json.contains("\"chip_name\""),
            "chip_name must not appear in a posture-equivalence artifact")
        #expect(!json.contains("\"ram_bytes\""),
            "ram_bytes must not appear in a posture-equivalence artifact")
        #expect(!json.contains("\"disk_bytes\""),
            "disk_bytes must not appear in a posture-equivalence artifact")
        #expect(!json.contains("\"macos_version\""),
            "macos_version must not appear in a posture-equivalence artifact")
        // Timing metrics — these live only in TimingLaneReport.
        #expect(!json.contains("\"accept_ms\""),
            "accept_ms must not appear in a posture-equivalence artifact")
        #expect(!json.contains("\"ingest_ms\""),
            "ingest_ms must not appear in a posture-equivalence artifact")
        #expect(!json.contains("\"cycle_vector_ms\""),
            "cycle_vector_ms must not appear in a posture-equivalence artifact")
        #expect(!json.contains("\"read_ms\""),
            "read_ms must not appear in a posture-equivalence artifact")
    }

    // ── Divergence encoding ───────────────────────────────────────────────

    @Test("PostureEquivDivergence encodes probe_index and both rank lists")
    func divergenceFieldShape() throws {
        let divergence = PostureEquivDivergence(
            probeIndex: 7,
            plaintextRanks: ["uuid-1", "uuid-2", "uuid-3"],
            encryptedRanks: ["uuid-2", "uuid-1", "uuid-3"])
        let data = try JSONEncoder().encode(divergence)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"probe_index\""))
        #expect(json.contains("\"plaintext_ranks\""))
        #expect(json.contains("\"encrypted_ranks\""))
        #expect(json.contains("\"uuid-1\""))
        #expect(json.contains("\"uuid-2\""))
    }

    @Test("Empty divergences list encodes as empty array")
    func emptyDivergences() throws {
        let report = makeReport(divergent: false)
        let data = try JSONEncoder().encode(report)
        let json = try #require(String(data: data, encoding: .utf8))
        // All probes agreed: identical_count == probesCompared, divergent_count == 0.
        // Accept both encoder formattings (pretty-printed and compact).
        #expect(json.contains("\"divergences\" : [") || json.contains("\"divergences\":["))
    }

    @Test("Non-empty divergences list encodes per-probe detail")
    func nonEmptyDivergences() throws {
        let report = makeReport(divergent: true)
        let data = try JSONEncoder().encode(report)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"probe_index\""))
        #expect(json.contains("\"plaintext_ranks\""))
        #expect(json.contains("\"encrypted_ranks\""))
        #expect(json.contains("\"divergent_count\" : 1") || json.contains("\"divergent_count\":1"))
    }

    // ── Constants ─────────────────────────────────────────────────────────

    @Test("Default row and probe counts match documented values")
    func defaultConstants() {
        // These values are the documented defaults from the mission spec.
        // A change here is a protocol change — update the comment block in
        // PostureEquivalenceRunner.swift as well.
        #expect(postureEquivDefaultRows == 200)
        #expect(postureEquivDefaultProbes == 50)
    }
}
