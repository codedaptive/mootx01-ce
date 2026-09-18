import Foundation
import Testing
@testable import mcp_benchmarker

// SupersessionEstateDeltaTests — pure unit tests for computeSupersessionEstateDelta.
//
// Delta computation is a pure function over two SupersessionScores; no estate,
// no binary, no network. These tests pin the arithmetic contract so a refactor
// of the scorecard printing path cannot silently break the delta values.

// MARK: - Helpers

private func makeScores(
    queryCount: Int = 10,
    currentWinRate: Double,
    currentFoundRate: Double,
    meanStaleInTopK: Double,
    meanCurrentRank: Double,
    p50LatencySeconds: Double
) -> SupersessionScores {
    SupersessionScores(
        queryCount: queryCount,
        currentWinRate: currentWinRate,
        currentFoundRate: currentFoundRate,
        meanStaleInTopK: meanStaleInTopK,
        meanCurrentRank: meanCurrentRank,
        p50LatencySeconds: p50LatencySeconds)
}

// MARK: - Tests

@Suite("SupersessionEstateDelta computation")
struct SupersessionEstateDeltaTests {

    @Test("delta is encrypted minus unencrypted for all rate fields")
    func basicSubtraction() {
        let unenc = makeScores(currentWinRate: 0.80, currentFoundRate: 0.90,
                               meanStaleInTopK: 1.5, meanCurrentRank: 2.0,
                               p50LatencySeconds: 0.050)
        let enc   = makeScores(currentWinRate: 0.75, currentFoundRate: 0.85,
                               meanStaleInTopK: 1.8, meanCurrentRank: 2.3,
                               p50LatencySeconds: 0.060)
        let delta = computeSupersessionEstateDelta(unencrypted: unenc, encrypted: enc)
        #expect(abs(delta.currentWinRateDiff   - (-0.05)) < 1e-9)
        #expect(abs(delta.currentFoundRateDiff - (-0.05)) < 1e-9)
        #expect(abs(delta.meanStaleInTopKDiff  - 0.30) < 1e-9)
        #expect(abs(delta.meanCurrentRankDiff  - 0.30) < 1e-9)
    }

    @Test("p50 diff is expressed in milliseconds, not seconds")
    func p50DiffIsMilliseconds() {
        let unenc = makeScores(currentWinRate: 1.0, currentFoundRate: 1.0,
                               meanStaleInTopK: 0, meanCurrentRank: 1,
                               p50LatencySeconds: 0.100)   // 100 ms
        let enc   = makeScores(currentWinRate: 1.0, currentFoundRate: 1.0,
                               meanStaleInTopK: 0, meanCurrentRank: 1,
                               p50LatencySeconds: 0.115)   // 115 ms
        let delta = computeSupersessionEstateDelta(unencrypted: unenc, encrypted: enc)
        #expect(abs(delta.queryP50DiffMs - 15.0) < 1e-6,
                "expected 15.0 ms overhead, got \(delta.queryP50DiffMs)")
    }

    @Test("p50 percent diff is relative to unencrypted p50")
    func p50PercentDiff() throws {
        let unenc = makeScores(currentWinRate: 1.0, currentFoundRate: 1.0,
                               meanStaleInTopK: 0, meanCurrentRank: 1,
                               p50LatencySeconds: 0.100)   // 100 ms
        let enc   = makeScores(currentWinRate: 1.0, currentFoundRate: 1.0,
                               meanStaleInTopK: 0, meanCurrentRank: 1,
                               p50LatencySeconds: 0.120)   // 120 ms (+20%)
        let delta = computeSupersessionEstateDelta(unencrypted: unenc, encrypted: enc)
        let pct = try #require(delta.queryP50PercentDiff,
                               "percent diff must be non-nil when unencrypted p50 > 0")
        #expect(abs(pct - 20.0) < 1e-6, "expected +20%, got \(pct)")
    }

    @Test("p50 percent diff is nil when unencrypted p50 is zero")
    func p50PercentDiffNilWhenUnencryptedZero() {
        let unenc = makeScores(currentWinRate: 1.0, currentFoundRate: 1.0,
                               meanStaleInTopK: 0, meanCurrentRank: 1,
                               p50LatencySeconds: 0.0)   // zero — division undefined
        let enc   = makeScores(currentWinRate: 1.0, currentFoundRate: 1.0,
                               meanStaleInTopK: 0, meanCurrentRank: 1,
                               p50LatencySeconds: 0.050)
        let delta = computeSupersessionEstateDelta(unencrypted: unenc, encrypted: enc)
        #expect(delta.queryP50PercentDiff == nil,
                "percent diff must be nil when unencrypted p50 is zero")
    }

    @Test("identical runs produce an all-zero delta")
    func identicalRunsProduceZeroDelta() throws {
        let scores = makeScores(currentWinRate: 0.95, currentFoundRate: 1.0,
                                meanStaleInTopK: 0.2, meanCurrentRank: 1.1,
                                p50LatencySeconds: 0.080)
        let delta = computeSupersessionEstateDelta(unencrypted: scores, encrypted: scores)
        #expect(delta.currentWinRateDiff   == 0)
        #expect(delta.currentFoundRateDiff == 0)
        #expect(delta.meanStaleInTopKDiff  == 0)
        #expect(delta.meanCurrentRankDiff  == 0)
        #expect(delta.queryP50DiffMs       == 0)
        let pct = try #require(delta.queryP50PercentDiff)
        #expect(pct == 0)
    }

    @Test("argument order is fixed: unencrypted first, encrypted second")
    func argumentOrderIsFixed() {
        // Swapping the arguments must produce the sign-negated delta. This pins
        // that the function is not symmetric — the caller knows which run is
        // which and the result's sign is load-bearing for display.
        let unenc = makeScores(currentWinRate: 0.80, currentFoundRate: 0.90,
                               meanStaleInTopK: 1.0, meanCurrentRank: 2.0,
                               p50LatencySeconds: 0.050)
        let enc   = makeScores(currentWinRate: 0.85, currentFoundRate: 0.95,
                               meanStaleInTopK: 0.8, meanCurrentRank: 1.8,
                               p50LatencySeconds: 0.055)
        let forward  = computeSupersessionEstateDelta(unencrypted: unenc, encrypted: enc)
        let backward = computeSupersessionEstateDelta(unencrypted: enc,  encrypted: unenc)
        #expect(abs(forward.currentWinRateDiff + backward.currentWinRateDiff) < 1e-9,
                "forward and backward deltas must be sign-negated")
        #expect(abs(forward.queryP50DiffMs + backward.queryP50DiffMs) < 1e-6)
    }

    @Test("negative delta is possible: encrypted may score better or be faster")
    func negativeDeltaIsValid() throws {
        // Encrypted run is actually faster — plausible on a warm cache or a
        // run where the plaintext run had a competing load. The delta should
        // be negative, not clamped.
        let unenc = makeScores(currentWinRate: 1.0, currentFoundRate: 1.0,
                               meanStaleInTopK: 0, meanCurrentRank: 1,
                               p50LatencySeconds: 0.200)
        let enc   = makeScores(currentWinRate: 1.0, currentFoundRate: 1.0,
                               meanStaleInTopK: 0, meanCurrentRank: 1,
                               p50LatencySeconds: 0.150)
        let delta = computeSupersessionEstateDelta(unencrypted: unenc, encrypted: enc)
        #expect(delta.queryP50DiffMs < 0, "negative overhead must be preserved")
        let pct = try #require(delta.queryP50PercentDiff)
        #expect(pct < 0, "negative percent overhead must be preserved")
    }
}
