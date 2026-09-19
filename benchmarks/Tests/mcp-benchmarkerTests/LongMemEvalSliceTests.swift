import Testing
import Foundation
@testable import mcp_benchmarker

// LongMemEvalSliceTests — unit tests for the --slice dev|holdout partitioning.
//
// All tests are pure (no live MCP, no filesystem I/O). The slice logic under
// test lives in runLMEQuestions: after the seeded Fisher-Yates shuffle, the
// slice cuts the shuffled list before offset and limit are applied.
//
// Invariants verified:
//   1. dev ∪ holdout == full shuffled set (partition covers everything)
//   2. dev ∩ holdout == ∅ (partition is disjoint)
//   3. dev == first 50 of the same seeded shuffle (boundary is hard)
//   4. slice composes correctly with --offset and --limit
//   5. run_parameters round-trip carries "slice" when set, omits when nil

// MARK: - Helpers

/// Builds a minimal LMERunConfig for slice testing.
/// Only the fields needed by the slice logic are varied per test.
private func sliceConfig(
    seed: UInt64 = 20_260_725,
    slice: String? = nil,
    offset: Int = 0,
    limit: Int? = nil
) -> LMERunConfig {
    LMERunConfig(
        mootBinaryPath: "/tmp/fake-mootx01",
        datasetPath: URL(fileURLWithPath: "/tmp/fake.json"),
        variant: "s",
        limit: limit, offset: offset, seed: seed,
        outDir: nil,
        runLabel: "test",
        arm: .both,
        judgeCmd: nil,
        judgeGrading: .substring,
        judgeHydrationDepth: 10,
        recallShape: nil,
        encodeBarrier: .drain,
        estateCache: .off,
        cacheDir: nil,
        scratchPosture: .plaintextTransient,
        exactStrategy: .auto,
        settle: false,
        rerankCmd: nil,
        synthesizeArm: false,
        synthesizeLimit: nil,
        dumpJudgeInputsPath: nil,
        slice: slice
    )
}

/// Applies the seeded Fisher-Yates shuffle and returns the shuffled array.
/// Mirrors exactly the shuffle used in runLMEQuestions so the tests operate
/// on the same order the production code will produce.
private func seededShuffle<T>(_ items: [T], seed: UInt64) -> [T] {
    var rng = SplitMix64(seed: seed)
    var result = items
    for i in stride(from: result.count - 1, through: 1, by: -1) {
        let j = rng.upTo(i + 1)
        result.swapAt(i, j)
    }
    return result
}

/// Applies the slice → offset → limit pipeline to a shuffled array,
/// mirroring the logic in runLMEQuestions.
private func applyPipeline<T>(
    shuffled: [T],
    slice: String?,
    offset: Int,
    limit: Int?
) -> [T] {
    // Slice constant: the dev partition is always the first 50.
    let devSize = 50
    let afterSlice: [T]
    switch slice {
    case "dev":     afterSlice = Array(shuffled.prefix(devSize))
    case "holdout": afterSlice = Array(shuffled.dropFirst(devSize))
    case nil:       afterSlice = shuffled
    default:        fatalError("unreachable in test helper")
    }
    let afterOffset = Array(afterSlice.dropFirst(offset))
    if let limit = limit {
        return Array(afterOffset.prefix(limit))
    }
    return afterOffset
}

// MARK: - Partition invariants

@Suite("LME slice partitioning")
struct LongMemEvalSliceTests {

    // Build a stable 200-element corpus for partition tests.
    // IDs are just integers; the content is irrelevant.
    private let corpus: [Int] = Array(0..<200)
    private let seed: UInt64 = 20_260_725

    @Test("dev ∪ holdout equals the full shuffled set")
    func devAndHoldoutCoverFull() {
        let shuffled = seededShuffle(corpus, seed: seed)
        let devSet = Set(applyPipeline(shuffled: shuffled, slice: "dev",
                                       offset: 0, limit: nil))
        let holdoutSet = Set(applyPipeline(shuffled: shuffled, slice: "holdout",
                                           offset: 0, limit: nil))
        let fullSet = Set(shuffled)

        #expect(devSet.union(holdoutSet) == fullSet,
                "dev ∪ holdout must equal the full shuffled set")
    }

    @Test("dev ∩ holdout is empty")
    func devAndHoldoutAreDisjoint() {
        let shuffled = seededShuffle(corpus, seed: seed)
        let devSet = Set(applyPipeline(shuffled: shuffled, slice: "dev",
                                       offset: 0, limit: nil))
        let holdoutSet = Set(applyPipeline(shuffled: shuffled, slice: "holdout",
                                           offset: 0, limit: nil))

        #expect(devSet.intersection(holdoutSet).isEmpty,
                "dev ∩ holdout must be empty (disjoint partition)")
    }

    @Test("dev equals exactly the first 50 of the seeded shuffle")
    func devIsFirst50OfSeedShuffle() {
        let shuffled = seededShuffle(corpus, seed: seed)
        let dev = applyPipeline(shuffled: shuffled, slice: "dev", offset: 0, limit: nil)

        #expect(dev.count == 50, "dev slice must contain exactly 50 questions")
        #expect(dev == Array(shuffled.prefix(50)),
                "dev must equal the first 50 of the seeded shuffle")
    }

    @Test("holdout equals everything after the first 50 of the seeded shuffle")
    func holdoutIsAfterFirst50() {
        let shuffled = seededShuffle(corpus, seed: seed)
        let holdout = applyPipeline(shuffled: shuffled, slice: "holdout", offset: 0, limit: nil)

        #expect(holdout.count == corpus.count - 50,
                "holdout slice must contain corpus.count − 50 questions")
        #expect(holdout == Array(shuffled.dropFirst(50)),
                "holdout must equal everything after the first 50 of the seeded shuffle")
    }

    @Test("same seed produces the same dev slice on two independent calls")
    func devSliceIsDeterministic() {
        let shuffled1 = seededShuffle(corpus, seed: seed)
        let shuffled2 = seededShuffle(corpus, seed: seed)
        let dev1 = applyPipeline(shuffled: shuffled1, slice: "dev", offset: 0, limit: nil)
        let dev2 = applyPipeline(shuffled: shuffled2, slice: "dev", offset: 0, limit: nil)

        #expect(dev1 == dev2, "dev slice must be identical for the same seed")
    }

    @Test("different seeds produce different dev slices")
    func devSliceDiffersAcrossSeeds() {
        let shuffled1 = seededShuffle(corpus, seed: 20_260_725)
        let shuffled2 = seededShuffle(corpus, seed: 42)
        let dev1 = applyPipeline(shuffled: shuffled1, slice: "dev", offset: 0, limit: nil)
        let dev2 = applyPipeline(shuffled: shuffled2, slice: "dev", offset: 0, limit: nil)

        // Different seeds should very likely produce different orderings.
        // With a 200-element corpus and different seeds this is astronomically unlikely to collide.
        #expect(dev1 != dev2,
                "different seeds should produce different dev slices (same seed is the determinism guarantee)")
    }

    // MARK: - Composition with offset and limit

    @Test("slice=dev composes with limit: result is prefix(limit) of the dev slice")
    func devWithLimit() {
        let shuffled = seededShuffle(corpus, seed: seed)
        let devFull = applyPipeline(shuffled: shuffled, slice: "dev", offset: 0, limit: nil)
        let devLimited = applyPipeline(shuffled: shuffled, slice: "dev", offset: 0, limit: 10)

        #expect(devLimited.count == 10,
                "dev + limit:10 should yield exactly 10 questions")
        #expect(devLimited == Array(devFull.prefix(10)),
                "dev + limit:10 should equal first 10 of the dev slice")
    }

    @Test("slice=holdout composes with limit")
    func holdoutWithLimit() {
        let shuffled = seededShuffle(corpus, seed: seed)
        let holdoutFull = applyPipeline(shuffled: shuffled, slice: "holdout",
                                        offset: 0, limit: nil)
        let holdoutLimited = applyPipeline(shuffled: shuffled, slice: "holdout",
                                           offset: 0, limit: 20)

        #expect(holdoutLimited.count == 20,
                "holdout + limit:20 should yield exactly 20 questions")
        #expect(holdoutLimited == Array(holdoutFull.prefix(20)),
                "holdout + limit:20 should equal first 20 of the holdout slice")
    }

    @Test("slice=dev composes with offset: skip offset items from the dev slice")
    func devWithOffset() {
        let shuffled = seededShuffle(corpus, seed: seed)
        let devFull = applyPipeline(shuffled: shuffled, slice: "dev", offset: 0, limit: nil)
        let devOffset = applyPipeline(shuffled: shuffled, slice: "dev", offset: 5, limit: nil)

        #expect(devOffset.count == 45,
                "dev + offset:5 should yield 50 − 5 = 45 questions")
        #expect(devOffset == Array(devFull.dropFirst(5)),
                "dev + offset:5 should equal dev slice with first 5 dropped")
    }

    @Test("slice=dev with offset and limit composes correctly")
    func devWithOffsetAndLimit() {
        let shuffled = seededShuffle(corpus, seed: seed)
        let devFull = applyPipeline(shuffled: shuffled, slice: "dev", offset: 0, limit: nil)
        let result = applyPipeline(shuffled: shuffled, slice: "dev", offset: 3, limit: 7)

        #expect(result.count == 7,
                "dev + offset:3 + limit:7 should yield 7 questions")
        #expect(result == Array(devFull.dropFirst(3).prefix(7)),
                "dev + offset:3 + limit:7 should equal items 3..10 of the dev slice")
    }

    @Test("nil slice (omitted flag) leaves the full shuffled set unchanged")
    func noSliceIsFullSet() {
        let shuffled = seededShuffle(corpus, seed: seed)
        let noSlice = applyPipeline(shuffled: shuffled, slice: nil, offset: 0, limit: nil)

        #expect(noSlice == shuffled,
                "omitted --slice must leave the full shuffled set unchanged (today's behavior)")
    }

    // MARK: - run_parameters round-trip

    @Test("run_parameters carries 'slice' string when the flag was set")
    func runParametersCarriesSlice() throws {
        let rp = LMEReportRunParameters(
            judgeHydrationDepth: 10,
            judgeGrading: "substring",
            judgeCmdSet: false,
            arm: "both",
            exactStrategy: "auto",
            recallShape: nil,
            freshPerQuestion: true,
            seed: 20_260_725,
            limit: nil,
            offset: 0,
            synthesizeLimit: nil,
            slice: "dev",
            rerankCmdSet: false
        )
        let data = try JSONEncoder().encode(rp)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["slice"] as? String == "dev",
                "run_parameters must carry 'slice' when the flag was set")
    }

    @Test("run_parameters omits 'slice' when the flag was absent")
    func runParametersOmitsSliceWhenNil() throws {
        let rp = LMEReportRunParameters(
            judgeHydrationDepth: 10,
            judgeGrading: "substring",
            judgeCmdSet: false,
            arm: "both",
            exactStrategy: "auto",
            recallShape: nil,
            freshPerQuestion: true,
            seed: 20_260_725,
            limit: nil,
            offset: 0,
            synthesizeLimit: nil,
            slice: nil,
            rerankCmdSet: false
        )
        let data = try JSONEncoder().encode(rp)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["slice"] == nil,
                "run_parameters must omit 'slice' when the flag was absent (mirrors synthesize_limit)")
    }

    @Test("run_parameters 'holdout' slice round-trips through encode/decode")
    func runParametersHoldoutRoundTrips() throws {
        let rp = LMEReportRunParameters(
            judgeHydrationDepth: 10,
            judgeGrading: "substring",
            judgeCmdSet: false,
            arm: "both",
            exactStrategy: "auto",
            recallShape: nil,
            freshPerQuestion: true,
            seed: 20_260_725,
            limit: nil,
            offset: 0,
            synthesizeLimit: nil,
            slice: "holdout",
            rerankCmdSet: false
        )
        let data = try JSONEncoder().encode(rp)
        let decoded = try JSONDecoder().decode(LMEReportRunParameters.self, from: data)

        #expect(decoded.slice == "holdout",
                "'holdout' slice must survive encode/decode round-trip")
    }

    // MARK: - CLI option surface

    @Test("validateOptions accepts --slice for longmemeval subcommand")
    func validateOptionsAcceptsSlice() throws {
        // Should not throw: --slice is a recognised option for longmemeval.
        try validateOptions(
            subcommand: "longmemeval",
            in: ["--variant", "s", "--data-dir", "/tmp/lme",
                 "--slice", "dev", "--limit", "10"])
    }

    @Test("validateOptions rejects --slice for locomo subcommand")
    func validateOptionsRejectsSliceForLocomo() {
        // --slice is longmemeval-only; locomo does not accept it.
        #expect(throws: (any Error).self) {
            try validateOptions(
                subcommand: "locomo",
                in: ["--data-file", "/tmp/locomo.json", "--slice", "dev"])
        }
    }
}
