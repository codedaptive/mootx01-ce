// GroundedSynthesisTests.swift
//
// End-to-end test of the GroundedSynthesis recipe against a real
// GeniusLocusKit estate over in-memory storage — no mocks. Proves the
// full through-line: GLK capture/recall → NeuronKit hybridRecall +
// ContextSynthesizer → CognitionKit recipe output.
//
// ISOLATION: all tests that call GroundedSynthesis.run() acquire the
// process-wide cognitionTestMutex (CognitionTestLock.swift). After the
// cp-cognitionkit-report telemetry addition, recipe-run functions emit
// to the Intellectus global singleton. A concurrent telemetry test that
// holds the singleton enabled would otherwise receive this test's
// emissions into its capturing sink and corrupt exact-count assertions.
// This is the same discipline NeuronKit applies to BradleyTerry/Dreaming/
// HybridRecall tests (IntellectusTestLock.swift).
//
// Tests that do NOT call run() (metadata-only) do not need the lock.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import PersistenceKit
import PersistenceKitInMemory
@testable import CognitionKit

@Suite("GroundedSynthesisTests")
struct GroundedSynthesisTests {

    /// Open a fresh in-memory estate and capture the supplied contents
    /// into a single room. Returns the kit and its handle.
    private func makeEstate(
        capturing contents: [String]
    ) async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(
                estateID: UUID(), backend: .inMemory))
        let handle = try await kit.open(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "grounded-synth-test"))
        for text in contents {
            let frame = CaptureFrame(
                content: text,
                channel: .typed,
                room: "lab",
                latticeAnchor: .udc("540"),
                addedBy: "tester",
                embeddingModelID: "test-v1")
            _ = try await kit.capture(handle, frame)
        }
        return (kit, handle)
    }

    @Test("synthesizes over recalled drawers")
    func synthesizesOverRecalledDrawers() async throws {
        // Acquire the process-wide lock: GroundedSynthesis.run emits
        // cognitionkit.recipe.run to Intellectus; a concurrent telemetry
        // test holding the singleton enabled would count this test's
        // emissions in its capturing sink. See file-level comment.
        try await withCognitionLock {
            let (kit, handle) = try await makeEstate(capturing: [
                "the organic chemistry of carbon compounds",
                "carbon based life and biochemistry",
                "introduction to quantum mechanics",
            ])

            // Recall the freshly-captured (unconfirmed) drawers. The recall
            // evaluator defaults the confirmation axis to userConfirmed when
            // unconstrained, so .unconfirmed is required to see them.
            let input = GroundedSynthesis.Input(
                frame: LocusKit.RecallFrame(filterChain: [.unconfirmed]))
            let out = try await GroundedSynthesis().run(
                input: input, estate: handle, kit: kit)

            #expect(out.drawerCount == 3)
            #expect(!out.context.summary.isEmpty,
                    "summary should be populated for a non-empty recall")
            // The summary names the dominant parentNodeId (a UUID).
            #expect(out.context.summary.contains("dominant node"),
                    "summary should reference the dominant node")
            // "carbon" appears in two drawers → a dominant pattern.
            #expect(out.context.patterns.contains("carbon"),
                    "repeated token should surface as a pattern")
        }
    }

    @Test("empty recall yields empty context")
    func emptyRecallYieldsEmptyContext() async throws {
        // Acquire the lock: GroundedSynthesis.run emits to Intellectus.
        // See file-level comment.
        try await withCognitionLock {
            let (kit, handle) = try await makeEstate(capturing: [])

            let input = GroundedSynthesis.Input(
                frame: LocusKit.RecallFrame(filterChain: [.unconfirmed]))
            let out = try await GroundedSynthesis().run(
                input: input, estate: handle, kit: kit)

            #expect(out.drawerCount == 0)
            #expect(out.context.summary.isEmpty)
            #expect(out.context.patterns.isEmpty)
        }
    }

    @Test("capability metadata is declared")
    func capabilityMetadataIsDeclared() {
        let recipe = GroundedSynthesis()
        #expect(recipe.name == "grounded_synthesis")
        #expect(Set(recipe.requiredCapabilities) == [.hybridRecall, .synthesize])
    }

    /// Cap truncates post-rank: the reranker runs first, then cap keeps only
    /// the top-N scored drawers. The cue-relevant drawer is deliberately the
    /// OLDEST — the exact configuration the mission exists for (recency-only
    /// ordering evicts it; measured as the trial-2 failure). With cap=1 it
    /// must still be the sole survivor: with a cue present the recipe's
    /// lane weighting is lexical-dominant, recency strictly a tie-break.
    /// Twin of Rust `gs4_cap_truncates_after_rerank` (identical fixture).
    @Test("cap truncates after rerank — most relevant survives not most recent")
    func capTruncatesAfterRerank() async throws {
        try await withCognitionLock {
            // d1 (filed FIRST, oldest): matches all three cue terms.
            // d2, d3 (newer): match none. Recency alone would pick d3.
            let (kit, handle) = try await makeEstate(capturing: [
                "daguerreotype vintage cameras photography collection",  // index 0 — oldest, 3 distinct matches
                "modern digital exhibition display",                     // index 1 — newer, 0 matches
                "contemporary art installation space",                   // index 2 — newest, 0 matches
            ])

            let input = GroundedSynthesis.Input(
                frame: LocusKit.RecallFrame(filterChain: [.unconfirmed]),
                cueTerms: ["daguerreotype", "vintage", "cameras"],
                cap: 1
            )
            let out = try await GroundedSynthesis().run(
                input: input, estate: handle, kit: kit)

            // cap: 1 → exactly one drawer feeds synthesis.
            #expect(out.drawerCount == 1,
                    "cap 1 must truncate the ranked result to exactly 1 drawer")
            // That one drawer is the cue-matched one; its content appears in
            // keyInsights (makeKeyInsights picks the first row in stream order).
            #expect(out.context.keyInsights.first?.contains("daguerreotype") == true,
                    "the cue-relevant drawer must be the one that survives the cap")
        }
    }

    /// Provenance-restricted rows are silently removed from the synthesis
    /// pool when `excludeProvenanceSensitive: true`. The gate operates on
    /// provenance bits 30–35 (`Drawer.sensitivity`), which the recall-frame
    /// adjective filter does not cover. A restricted row must not appear in
    /// `keyInsights`; a normal row in a mixed estate must survive.
    /// Twin of Rust `gs6_provenance_gate_excludes_restricted_rows`.
    @Test("provenance-restricted rows absent when excludeProvenanceSensitive enabled")
    func provenanceRestrictedRowAbsentWhenGateEnabled() async throws {
        try await withCognitionLock {
            let kit = GeniusLocusKit()
            let storage = InMemoryStorage(
                configuration: EstateConfiguration(
                    estateID: UUID(), backend: .inMemory))
            let handle = try await kit.open(
                storage: storage,
                owner: OwnerCredentials(ownerIdentifier: "gs-prov-gate"))

            // Capture a normal row — must survive the gate.
            let normalFrame = CaptureFrame(
                content: "classified aardvark synthesis normaltoken",
                channel: .typed,
                room: "lab",
                latticeAnchor: .udc("540"),
                addedBy: "tester",
                embeddingModelID: "test-v1",
                provenanceSensitivity: .normal)
            _ = try await kit.capture(handle, normalFrame)

            // Capture a provenance-restricted row — must be excluded.
            let restrictedFrame = CaptureFrame(
                content: "classified aardvark synthesis restrictedtoken",
                channel: .typed,
                room: "lab",
                latticeAnchor: .udc("540"),
                addedBy: "tester",
                embeddingModelID: "test-v1",
                provenanceSensitivity: .restricted)
            _ = try await kit.capture(handle, restrictedFrame)

            let input = GroundedSynthesis.Input(
                frame: LocusKit.RecallFrame(filterChain: [.unconfirmed]),
                excludeProvenanceSensitive: true)
            let out = try await GroundedSynthesis().run(
                input: input, estate: handle, kit: kit)

            // Only the normal row feeds synthesis; restricted is silently removed.
            #expect(out.drawerCount == 1,
                    "restricted row must be removed; only 1 normal row survives")
            let allInsights = out.context.keyInsights.joined(separator: " ")
            #expect(allInsights.contains("normaltoken"),
                    "normal row content must appear in keyInsights")
            #expect(!allInsights.contains("restrictedtoken"),
                    "restricted row content must not appear in keyInsights")
        }
    }

    /// The scoring-evidence gate — the DEGRADED contract. When lane-B hits
    /// carry no scoring evidence (BM25 / Hamming / dense cosine), the gate
    /// drops them: their order is recency, not relevance, and admitting it
    /// would resurrect the recency-dominance failure. Hybrid grounding then
    /// behaves EXACTLY like lexical-only grounding — same pool, term match
    /// leading. The LIVE-lane reach guarantee (non-term rows admitted below
    /// term matches) is exercised where scoring providers exist: the live
    /// product (benchmark trial 5). Twin of Rust
    /// `gs5_scored_lane_degraded_contract_equals_lexical_only`; whether this
    /// estate's scored lane is live is environment-dependent, so the pinned
    /// invariants are the ones that hold in BOTH conditions: the term match
    /// leads, and the pool never SHRINKS below the lexical reach.
    @Test("scored lane never shrinks the pool; term match leads")
    func scoredLaneNeverShrinksPoolAndTermMatchLeads() async throws {
        try await withCognitionLock {
            let (kit, handle) = try await makeEstate(capturing: [
                "daguerreotype vintage cameras photography collection",  // matches cue terms
                "modern digital exhibition display",                     // 0 term matches
                "contemporary art installation space",                   // 0 term matches
            ])
            let cueTerms = ["daguerreotype", "vintage", "cameras"]

            let lexicalOnly = try await GroundedSynthesis().run(
                input: .init(
                    frame: LocusKit.RecallFrame(filterChain: [.unconfirmed]),
                    cueTerms: cueTerms,
                    cap: 20),
                estate: handle, kit: kit)
            #expect(lexicalOnly.drawerCount == 1,
                    "lexical-only grounding reaches only the term match")

            let hybrid = try await GroundedSynthesis().run(
                input: .init(
                    frame: LocusKit.RecallFrame(filterChain: [.unconfirmed]),
                    cueTerms: cueTerms,
                    cap: 20,
                    query: "daguerreotype vintage cameras"),
                estate: handle, kit: kit)
            #expect(hybrid.drawerCount >= lexicalOnly.drawerCount,
                    "the scored lane must never shrink the pool below lexical reach")
            #expect(hybrid.context.keyInsights.first?.contains("daguerreotype") == true,
                    "the term match must lead the hybrid ranking")
        }
    }

    // MARK: - C2: negative/zero cap validation

    /// C2 — negative cap throws `RecipeError.invalidCap(value:)`.
    ///
    /// Swift's `Array.prefix(_ maxLength: Int)` panics when `maxLength < 0`
    /// (standard library precondition). Before this fix, a direct-API caller
    /// passing `cap: -1` would crash the process. The guard added after
    /// `verifyCapabilities` catches the invalid value and raises a structured
    /// error. Parity: Rust `gs6_zero_cap_returns_invalid_cap_error` (usize
    /// prevents negative, so only cap=0 is tested there).
    @Test("negative cap throws RecipeError.invalidCap")
    func testNegativeCapThrowsInvalidCap() async throws {
        try await withCognitionLock {
            let (kit, handle) = try await makeEstate(capturing: [
                "negative cap test content",
            ])
            let input = GroundedSynthesis.Input(
                frame: LocusKit.RecallFrame(filterChain: [.unconfirmed]),
                cap: -1  // invalid — must be rejected, not crash
            )
            do {
                _ = try await GroundedSynthesis().run(
                    input: input, estate: handle, kit: kit)
                Issue.record("negative cap must throw RecipeError.invalidCap, not succeed")
            } catch let e as RecipeError {
                #expect(e == .invalidCap(value: -1),
                        "negative cap must throw .invalidCap(value: -1); got: \(e)")
            } catch {
                Issue.record("negative cap must throw RecipeError, not \(type(of: error)): \(error)")
            }
        }
    }

    /// C2 — zero cap throws `RecipeError.invalidCap(value:)`.
    ///
    /// A cap of zero would silently produce an empty synthesis set (0 drawers
    /// fed to the synthesizer yields a vacuous context). Treated as a caller
    /// error — consistent with the guard pattern in `tooManyPlans` and
    /// `tooManyOriginEntries` (reject before work begins). Parity: Rust
    /// `gs6_zero_cap_returns_invalid_cap_error`.
    @Test("zero cap throws RecipeError.invalidCap")
    func testZeroCapThrowsInvalidCap() async throws {
        try await withCognitionLock {
            let (kit, handle) = try await makeEstate(capturing: [
                "zero cap test content alpha",
                "zero cap test content beta",
            ])
            let input = GroundedSynthesis.Input(
                frame: LocusKit.RecallFrame(filterChain: [.unconfirmed]),
                cap: 0  // invalid — must be rejected
            )
            do {
                _ = try await GroundedSynthesis().run(
                    input: input, estate: handle, kit: kit)
                Issue.record("zero cap must throw RecipeError.invalidCap, not succeed")
            } catch let e as RecipeError {
                #expect(e == .invalidCap(value: 0),
                        "zero cap must throw .invalidCap(value: 0); got: \(e)")
            } catch {
                Issue.record("zero cap must throw RecipeError, not \(type(of: error)): \(error)")
            }
        }
    }

    /// C2 — huge cap (`Int.max`) does not crash.
    ///
    /// Swift's `Array.prefix(_ maxLength: Int)` only panics on negative values;
    /// very large positive values are safe (prefix returns however many elements
    /// exist). This test ensures the guard does not reject valid extreme values
    /// and that the recipe completes normally. Parity: Rust
    /// `gs7_huge_cap_does_not_crash`.
    @Test("huge cap (Int.max) completes without crash")
    func testHugeCapDoesNotCrash() async throws {
        try await withCognitionLock {
            let (kit, handle) = try await makeEstate(capturing: [
                "huge cap test row alpha",
                "huge cap test row beta",
            ])
            let input = GroundedSynthesis.Input(
                frame: LocusKit.RecallFrame(filterChain: [.unconfirmed]),
                cap: Int.max  // enormous — must not crash or be rejected
            )
            let out = try await GroundedSynthesis().run(
                input: input, estate: handle, kit: kit)
            // All recalled rows feed synthesis — Int.max does not truncate a 2-row pool.
            #expect(out.drawerCount == 2,
                    "Int.max cap must not truncate a 2-row pool; got \(out.drawerCount)")
        }
    }
}
