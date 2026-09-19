import Testing
import Foundation
@testable import mcp_benchmarker

// ReportSchemaStampTests — every lane report carries the estate schema version.
//
// BENCHMARK_PROTOCOL §9 requires the schema version in every report so the
// results record can carry that column without anyone typing it. Only the
// gauntlet report did. On 2026-08-17 the register's Schema column could not be
// filled for nine rows because the field was absent from every other lane's
// record, and the register's own rule forbids typing it by hand.
//
// The failure mode these tests guard is specific: every one of these structs
// declares an explicit CodingKeys enum, and a property missing from that enum
// is silently dropped at encode time. The struct compiles, the field exists in
// memory, and the JSON simply does not have it — which is exactly the state the
// records were in. So these assert against ENCODED BYTES, not the property.

@Suite("Report schema stamp")
struct ReportSchemaStampTests {

    /// The encoded key every report must carry.
    private let key = "\"estate_schema_version\""

    private func encoded<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    @Test("The stamped value is the harness constant")
    func stampIsTheConstant() {
        // 1.1 since 2026-08-17: the string now names the shape the product
        // actually builds (shared-content layout, vector generations).
        #expect(currentEstateSchemaVersion == "1.1")
    }

    @Test("Matrix report encodes the schema version")
    func matrixReportCarriesIt() throws {
        let report = MatrixReport(
            benchmarkProtocolVersion: "v0.1",
            runEnvironment: RunEnvironment.collect(mootx01BinaryPath: nil, runMode: "quiet"),
            seed: 20260816, probes: 8, k: 10, lane: "locomo",
            databases: 10, failures: 0, rows: [])
        let json = try encoded(report)
        #expect(json.contains(key))
        #expect(json.contains("\"\(currentEstateSchemaVersion)\""))
    }

    @Test("Timing report encodes the schema version")
    func timingReportCarriesIt() throws {
        let report = TimingLaneReport(
            benchmarkProtocolVersion: "v0.1",
            runEnvironment: RunEnvironment.collect(mootx01BinaryPath: nil, runMode: "quiet"),
            seed: 20260813, repeats: 5, shape: "disk",
            estateEncryption: "plaintext-optout",
            landscape: TimingLandscapeRecipe.corpus(
                .longmemeval, variant: "s", rows: 100_000, seed: 20260813),
            results: [])
        let json = try encoded(report)
        #expect(json.contains(key))
    }
}
