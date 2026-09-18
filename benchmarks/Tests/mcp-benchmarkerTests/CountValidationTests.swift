import Testing
import Foundation
@testable import mcp_benchmarker

// CountValidationTests.swift — the CLI boundary rejects out-of-range count
// options before any corpus generator sees them.
//
// The generators are allowed to trust their inputs (SupersessionCorpus indexes
// `chainValues[count - 1]`, JourneyCorpus divides by `membersPerCluster`), so
// validation happens once, here, at the boundary. These tests pin both halves
// of that contract: bad values are REJECTED with a message naming the option,
// and good values are passed through untouched.
//
// Rejected, never clamped. A benchmark run whose parameters were silently
// corrected reports numbers labelled with what the operator asked for and
// measured with something else.

@Suite("CLI count-option validation") struct CountValidationTests {

    // The minimums enforced at the two subcommand boundaries, each paired with
    // the generator code that would break below it. Kept as one table so a
    // future option added to either subcommand has an obvious place to land.
    private static let supersessionMinimums: [(option: String, def: Int, min: Int)] = [
        ("--entities",       40, 0),   // SupersessionCorpus `0..<entityCount`
        ("--versions",        3, 1),   // SupersessionCorpus `chainValues[count - 1]`
        ("--contradictions", 10, 0),   // SupersessionCorpus `0..<contradictionCount`
        ("--divergences",     5, 0),   // SupersessionCorpus `0..<divergenceCount` (MXE-CT3 P4)
        ("--decoys",          5, 0),   // SupersessionCorpus `0..<decoyCount` (MXE-CT3 P4)
        ("--k",              10, 1),   // SupersessionRunner stale-in-top-K cutoff
    ]
    private static let journeyMinimums: [(option: String, def: Int, min: Int)] = [
        ("--precise-miss-count", 20, 0),  // JourneyCorpus `0..<preciseMissCount`
        ("--cluster-count",      10, 0),  // JourneyCorpus `0..<clusterCount`
        ("--members-per-cluster", 6, 2),  // JourneyCorpus `rng % membersPerCluster`
    ]
    // lmeb subcommand count options. Previously --judge-hydration-depth used
    // `.flatMap(Int.init) ?? default` which silently accepted non-integers and
    // 0/-1 without error. Now routes through validatedCount (minimum: 1).
    private static let lmebMinimums: [(option: String, def: Int, min: Int)] = [
        ("--judge-hydration-depth", 10, 1),  // lmeDefaultJudgePayloadHydrationDepth; 0 means no payload
    ]

    private static var allMinimums: [(option: String, def: Int, min: Int)] {
        supersessionMinimums + journeyMinimums + lmebMinimums
    }

    // MARK: Rejection

    @Test("a value below the minimum is rejected, naming the option and the value")
    func belowMinimumIsRejected() throws {
        for entry in Self.allMinimums {
            let bad = entry.min - 1
            #expect(throws: MCPError.self) {
                _ = try validatedCount(entry.option,
                                       in: [entry.option, String(bad)],
                                       default: entry.def,
                                       minimum: entry.min)
            }
            // The message must carry enough to act on: which option, what was
            // supplied, and what the constraint is.
            do {
                _ = try validatedCount(entry.option,
                                       in: [entry.option, String(bad)],
                                       default: entry.def,
                                       minimum: entry.min)
                Issue.record("\(entry.option) \(bad) should not have been accepted")
            } catch let error as MCPError {
                let text = error.description
                #expect(text.contains(entry.option))
                #expect(text.contains(String(bad)))
                #expect(text.contains(String(entry.min)))
            }
        }
    }

    @Test("a negative value is rejected for every count option")
    func negativeIsRejected() {
        for entry in Self.allMinimums {
            #expect(throws: MCPError.self) {
                _ = try validatedCount(entry.option,
                                       in: [entry.option, "-1"],
                                       default: entry.def,
                                       minimum: entry.min)
            }
        }
    }

    @Test("a non-integer value is rejected rather than silently defaulted")
    func nonIntegerIsRejected() {
        // The pre-fix parse was `Int(optionValue(...) ?? "") ?? default`, which
        // turned a typo into the default and reported the run as configured.
        for entry in Self.allMinimums {
            #expect(throws: MCPError.self) {
                _ = try validatedCount(entry.option,
                                       in: [entry.option, "eight"],
                                       default: entry.def,
                                       minimum: entry.min)
            }
        }
    }

    @Test("--versions 0 is rejected — the supersession chain index would trap")
    func versionsZeroIsRejected() {
        #expect(throws: MCPError.self) {
            _ = try validatedCount("--versions", in: ["--versions", "0"],
                                   default: 3, minimum: 1)
        }
    }

    @Test("--members-per-cluster 0 is rejected — the cluster picker divides by it")
    func membersPerClusterZeroIsRejected() {
        #expect(throws: MCPError.self) {
            _ = try validatedCount("--members-per-cluster",
                                   in: ["--members-per-cluster", "0"],
                                   default: 6, minimum: 2)
        }
    }

    @Test("--members-per-cluster 1 is rejected — a one-member cluster narrows nothing")
    func membersPerClusterOneIsRejected() {
        #expect(throws: MCPError.self) {
            _ = try validatedCount("--members-per-cluster",
                                   in: ["--members-per-cluster", "1"],
                                   default: 6, minimum: 2)
        }
    }

    // MARK: Acceptance

    @Test("an absent option yields its default")
    func absentYieldsDefault() throws {
        for entry in Self.allMinimums {
            let value = try validatedCount(entry.option, in: [],
                                           default: entry.def, minimum: entry.min)
            #expect(value == entry.def)
        }
    }

    @Test("the minimum itself is accepted, and so is the default")
    func boundaryAndDefaultAreAccepted() throws {
        for entry in Self.allMinimums {
            let atMinimum = try validatedCount(entry.option,
                                               in: [entry.option, String(entry.min)],
                                               default: entry.def,
                                               minimum: entry.min)
            #expect(atMinimum == entry.min)

            let atDefault = try validatedCount(entry.option,
                                               in: [entry.option, String(entry.def)],
                                               default: entry.def,
                                               minimum: entry.min)
            #expect(atDefault == entry.def)
        }
    }

    @Test("a valid value is passed through unchanged, never clamped")
    func validValueIsUnchanged() throws {
        let value = try validatedCount("--entities", in: ["--entities", "7"],
                                       default: 40, minimum: 0)
        #expect(value == 7)
    }

    // MARK: Corpus generation is unchanged for valid counts

    // MARK: E1 — lmeb --judge-hydration-depth validation (previously silently defaulted)

    @Test("--judge-hydration-depth -1 is rejected with a structured MCPError")
    func judgeHydrationDepthMinusOneRejected() {
        #expect(throws: MCPError.self) {
            _ = try validatedCount("--judge-hydration-depth",
                                   in: ["--judge-hydration-depth", "-1"],
                                   default: 10, minimum: 1)
        }
    }

    @Test("--judge-hydration-depth 0 is rejected — a zero-depth payload has no content")
    func judgeHydrationDepthZeroRejected() {
        #expect(throws: MCPError.self) {
            _ = try validatedCount("--judge-hydration-depth",
                                   in: ["--judge-hydration-depth", "0"],
                                   default: 10, minimum: 1)
        }
    }

    @Test("--judge-hydration-depth with non-integer input is rejected, not silently defaulted")
    func judgeHydrationDepthGarbageRejected() {
        // The pre-E1 parse was `.flatMap(Int.init) ?? default`, which turned
        // a typo into the default (10) and reported the run as if configured.
        #expect(throws: MCPError.self) {
            _ = try validatedCount("--judge-hydration-depth",
                                   in: ["--judge-hydration-depth", "ten"],
                                   default: 10, minimum: 1)
        }
        #expect(throws: MCPError.self) {
            _ = try validatedCount("--judge-hydration-depth",
                                   in: ["--judge-hydration-depth", "1.5"],
                                   default: 10, minimum: 1)
        }
    }

    @Test("--judge-hydration-depth absent yields the default (10)")
    func judgeHydrationDepthAbsentYieldsDefault() throws {
        let depth = try validatedCount("--judge-hydration-depth",
                                       in: [], default: 10, minimum: 1)
        #expect(depth == 10)
    }

    @Test("--judge-hydration-depth 1 is accepted — minimum boundary")
    func judgeHydrationDepthOneAccepted() throws {
        let depth = try validatedCount("--judge-hydration-depth",
                                       in: ["--judge-hydration-depth", "1"],
                                       default: 10, minimum: 1)
        #expect(depth == 1)
    }

    // MARK: Corpus generation is unchanged for valid counts

    @Test("valid counts still produce the same supersession corpus as before")
    func supersessionCorpusUnchangedForValidCounts() {
        // Guards against the validation pass having perturbed the generators:
        // same seed and same counts must still yield the same shape.
        let corpus = generateSupersessionCorpus(
            seed: 20260725, entityCount: 4, versionsPerChain: 3,
            contradictionCount: 2)
        #expect(corpus.queries.count == 4)
        #expect(corpus.contradictions.count == 2)
        // Three versions per chain across four entities, plus two records per
        // contradiction pair.
        #expect(corpus.records.count == 4 * 3 + 2 * 2)
    }

    @Test("valid counts still produce the same journey corpus as before")
    func journeyCorpusUnchangedForValidCounts() {
        let corpus = generateJourneyCorpus(
            seed: 20260725, preciseMissCount: 3, clusterCount: 2,
            membersPerCluster: 4)
        #expect(corpus.preciseMiss.scenarios.count == 3)
        #expect(corpus.vagueNarrow.clusters.count == 2)
        #expect(corpus.vagueNarrow.records.count == 2 * 4)
    }
}

// MARK: parseLimitOption — the --limit variant used by corpus runners

extension CountValidationTests {

    // parseLimitOption is the shared validator for the optional --limit flag
    // (no default, absence = unlimited). A negative value is a CLI error: the
    // caller labelled the run with what was asked and measured with something
    // else. Tests below pin the three-way contract: absent → nil, zero/positive
    // → value, negative → thrown MCPError. Previously-missed callers (runLMEB,
    // runArtifactRecall) now route through this helper; these tests lock down
    // the validation they gained.

    @Test("parseLimitOption absent returns nil")
    func parseLimitOptionAbsentReturnsNil() throws {
        let result = try parseLimitOption(in: [])
        #expect(result == nil)
    }

    @Test("parseLimitOption zero is accepted — no lower bound on optional limit")
    func parseLimitOptionZeroAccepted() throws {
        let result = try parseLimitOption(in: ["--limit", "0"])
        #expect(result == 0)
    }

    @Test("parseLimitOption positive value passes through")
    func parseLimitOptionPositivePasses() throws {
        let result = try parseLimitOption(in: ["--limit", "100"])
        #expect(result == 100)
    }

    @Test("parseLimitOption negative value throws — runLMEB and runArtifactRecall callers")
    func parseLimitOptionNegativeThrows() throws {
        // Previously-missed callers used optionValue("--limit",...).flatMap(Int.init)
        // which silently treated --limit -3 as "no limit". The migration to
        // parseLimitOption means both callers now reject negatives at the CLI gate.
        #expect(throws: MCPError.self) {
            _ = try parseLimitOption(in: ["--limit", "-1"])
        }
        #expect(throws: MCPError.self) {
            _ = try parseLimitOption(in: ["--limit", "-100"])
        }
    }

    @Test("parseLimitOption non-integer value throws")
    func parseLimitOptionNonIntegerThrows() throws {
        #expect(throws: MCPError.self) {
            _ = try parseLimitOption(in: ["--limit", "abc"])
        }
    }
}
