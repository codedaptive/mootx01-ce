import Testing
@testable import mcp_benchmarker

// TimingLaneParserTests — unit coverage for the C2 timing lane's pure
// helpers: timing-report text parsers, nearest-rank percentile math, and
// the deterministic synthetic corpus. Twin of the Rust module tests in
// `timing_lane_runner.rs` — same vectors, same expected values, so the
// two ports' parsing and math are pinned against each other.

@Suite("Timing lane parsers")
struct TimingLaneParserTests {

    @Test func watermarkParsesStandardReport() {
        let text = """
        timing report (audit-derived, since_ms=0):
          ingest_exact: n=2000, p50=1ms, p95=3ms
          watermark_ms: 98765
        """
        #expect(parseWatermarkMs(from: text) == 98765)
    }

    @Test func watermarkAbsentReturnsZero() {
        #expect(parseWatermarkMs(from: "no watermark here") == 0)
    }

    @Test func p50ParsersExtractPerPrefix() {
        let text = """
          ingest_exact: n=1, p50=4ms, p95=4ms
          cycle_vector: n=1, p50=12ms, p95=12ms
          watermark_ms: 100
        """
        #expect(parseIngestExactP50Ms(from: text) == 4.0)
        #expect(parseCycleP50Ms(linePrefix: "cycle_vector:", from: text) == 12.0)
        #expect(parseCycleP50Ms(linePrefix: "cycle_novel:", from: text) == nil)
    }

    @Test func statPairNearestRankBasic() throws {
        let pair = try #require(computeStatPair(samples: [10, 20, 30, 40, 50]))
        // p50 = ceil(0.5 * 5) = 3rd sample (1-indexed) = 30.
        #expect(pair.p50Ms == 30.0)
        // p95 = ceil(0.95 * 5) = 5th sample (1-indexed) = 50.
        #expect(pair.p95Ms == 50.0)
    }

    @Test func statPairSingleSample() throws {
        let pair = try #require(computeStatPair(samples: [42.0]))
        #expect(pair.p50Ms == 42.0)
        #expect(pair.p95Ms == 42.0)
    }

    /// Empty input yields nil, NOT (0, 0). A zeroed pair is indistinguishable
    /// from a real measurement of zero, which is how a run against a binary
    /// without moot_timing_report published four fabricated metrics beside
    /// four real ones. The report omits an absent metric instead.
    @Test func statPairEmptyIsNilNotZero() {
        #expect(computeStatPair(samples: []) == nil)
    }

    @Test func corpusIsDeterministicPerSeed() {
        let a = timingLaneRecords(from: 0, to: 3, seed: 42)
        let b = timingLaneRecords(from: 0, to: 3, seed: 42)
        #expect(a.count == 3)
        for (ra, rb) in zip(a, b) {
            #expect(ra.id == rb.id)
            #expect(ra.content == rb.content)
        }
        // Distinct seed → different ids.
        let c = timingLaneRecords(from: 0, to: 3, seed: 43)
        #expect(a[0].id != c[0].id)
        // Cross-port golden pin: the Rust twin asserts this same id for
        // seed 42 record 0, so the two corpus generators cannot silently
        // diverge (truncating casts, rng constants, uuid bit layout).
        #expect(a[0].id == "bdd73226-2feb-4e95-a8ef-e333b266f103")
    }

    @Test func corpusIDsAreUnique() {
        let records = timingLaneRecords(from: 0, to: 10, seed: 99)
        let ids = Set(records.map(\.id))
        #expect(ids.count == 10, "all IDs must be distinct")
    }
}
