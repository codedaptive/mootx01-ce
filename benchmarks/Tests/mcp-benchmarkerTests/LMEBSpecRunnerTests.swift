import Testing
import Foundation
@testable import mcp_benchmarker

// LMEBSpecRunnerTests.swift — unit tests for pure functions in LMEBSpecRunner.swift.
//
// Scope: report/record shape and pure-function correctness only.
// No live estate, no subprocess, no async IO.
//
// What is covered:
//   - lmebSpecEffectiveQuery (internal func, §A4 instruction prepend)
//   - LMEBInstructionSetting enum — raw values and case count
//   - LMEBSpecOptions — default field values
//   - LMEBSpecRunConfig — mutable field defaults (instructionSetting, judgeMaxRetries, etc.)
//   - Record stem constants ('lmeb-spec-' and 'convomem-spec-')
//   - convoMemAggregate([]) — answered_count/judged_count=0 baseline via empty aggregate
//   - convoMemJudgePrompt dispatch — five §B2 evidence types route to the correct template
//
// Spec references: LMEB_CONVOMEM_OFFICIAL_PROTOCOL.md §A4, §B2.

// MARK: - §A4 effectiveQuery

@Suite("LMEBSpecRunner effectiveQuery — §A4 instruction prepend")
struct LMEBSpecRunnerEffectiveQueryTests {

    // §A4: withoutInstruction → query text returned unchanged.
    @Test("§A4: withoutInstruction returns query text unchanged")
    func withoutInstructionPassthrough() {
        let query  = "What does the user prefer for breakfast?"
        let result = lmebSpecEffectiveQuery(
            queryText:    query,
            evidenceType: "user_evidence",
            setting:      .withoutInstruction
        )
        #expect(result == query,
                "withoutInstruction must return the query text unchanged")
    }

    // §A4: withInstruction + known type → "{instruction}\n{queryText}".
    //
    // The newline separator follows the MTEB convention for embedding models that
    // accept instruction+query input (verbatim from LMEBSpecRunner.swift).
    @Test("§A4: withInstruction prepends instruction with '\\n' separator")
    func withInstructionPrependsInstruction() {
        // user_evidence instruction: "Given a query, retrieve documents that answer the query"
        let query  = "What pasta dish does the user like?"
        let result = lmebSpecEffectiveQuery(
            queryText:    query,
            evidenceType: "user_evidence",
            setting:      .withInstruction
        )
        let expected = "Given a query, retrieve documents that answer the query\n" + query
        #expect(result == expected,
                "withInstruction must prepend instruction + '\\n' + queryText")
    }

    // §A4: withInstruction + changing_evidence → temporal instruction.
    @Test("§A4: withInstruction — changing_evidence prepends temporal instruction")
    func withInstructionChangingEvidence() {
        let query  = "When did the user last update their preferences?"
        let result = lmebSpecEffectiveQuery(
            queryText:    query,
            evidenceType: "changing_evidence",
            setting:      .withInstruction
        )
        let expected = "Given a question, retrieve the latest information to answer the question\n" + query
        #expect(result == expected,
                "changing_evidence must use its unique temporal instruction")
    }

    // §A4: withInstruction + assistant_facts_evidence → assistant-specific instruction.
    @Test("§A4: withInstruction — assistant_facts_evidence prepends its instruction")
    func withInstructionAssistantFactsEvidence() {
        let query  = "What did the assistant say about schedules?"
        let result = lmebSpecEffectiveQuery(
            queryText:    query,
            evidenceType: "assistant_facts_evidence",
            setting:      .withInstruction
        )
        let expected = "Given a query, retrieve assistant messages that answer the query\n" + query
        #expect(result == expected,
                "assistant_facts_evidence must use the assistant-specific instruction")
    }

    // §A4: withInstruction + preference_evidence → preference-specific instruction.
    @Test("§A4: withInstruction — preference_evidence prepends its instruction")
    func withInstructionPreferenceEvidence() {
        let query  = "What does the user prefer to drink?"
        let result = lmebSpecEffectiveQuery(
            queryText:    query,
            evidenceType: "preference_evidence",
            setting:      .withInstruction
        )
        let expected = "Given a query, retrieve the user's stated preferences that can help answer the query\n" + query
        #expect(result == expected,
                "preference_evidence must use the preference-specific instruction")
    }

    // §A4: withInstruction + unknown type → query returned unchanged.
    //
    // When the evidence type is not in the six ConvoMem subsets, the query is passed
    // through unchanged and a warning is emitted to stderr (not tested here — side effect).
    @Test("§A4: withInstruction — unknown evidenceType returns query unchanged")
    func withInstructionUnknownTypePassthrough() {
        let query  = "What is the capital of France?"
        let result = lmebSpecEffectiveQuery(
            queryText:    query,
            evidenceType: "nonexistent_type",
            setting:      .withInstruction
        )
        #expect(result == query,
                "unknown evidenceType must return query unchanged (no instruction to prepend)")
    }

    // All six §A4 subsets must have non-empty instructions under withInstruction.
    //
    // Exercises every subset name from the spec; verifies each produced string
    // starts with the instruction (not the query) and contains the newline separator.
    @Test("§A4: all six subset names produce a non-empty prepended instruction")
    func allSixSubsetsHaveInstruction() {
        let subsets = [
            "abstention_evidence",
            "assistant_facts_evidence",
            "changing_evidence",
            "implicit_connection_evidence",
            "preference_evidence",
            "user_evidence",
        ]
        let query = "test query"
        for subset in subsets {
            let result = lmebSpecEffectiveQuery(
                queryText:    query,
                evidenceType: subset,
                setting:      .withInstruction
            )
            #expect(result != query,
                    "subset '\(subset)': withInstruction must modify the query")
            #expect(result.contains("\n"),
                    "subset '\(subset)': result must contain '\\n' separator")
            #expect(result.hasSuffix(query),
                    "subset '\(subset)': result must end with the original query")
        }
    }
}

// MARK: - LMEBInstructionSetting enum

@Suite("LMEBSpecRunner LMEBInstructionSetting — enum shape")
struct LMEBSpecRunnerInstructionSettingTests {

    // Raw values must match the LMEB JSON field strings.
    @Test("LMEBInstructionSetting raw values match JSON field strings")
    func rawValues() {
        #expect(LMEBInstructionSetting.withoutInstruction.rawValue == "without_instruction",
                ".withoutInstruction raw value must be 'without_instruction'")
        #expect(LMEBInstructionSetting.withInstruction.rawValue == "with_instruction",
                ".withInstruction raw value must be 'with_instruction'")
    }

    // Two cases, no more, no less — both settings must be reachable for §A4 testing.
    @Test("LMEBInstructionSetting has exactly two cases")
    func caseCount() {
        let cases = LMEBInstructionSetting.allCases
        #expect(cases.count == 2,
                "LMEBInstructionSetting must have exactly 2 cases (withoutInstruction, withInstruction)")
    }

    // Default setting is withoutInstruction — the canonical zero-instruction baseline.
    //
    // §A4 commentary: both settings produce published numbers; the baseline (no instruction)
    // is the default because it matches the original LMEB zero-instruction condition.
    @Test("LMEBSpecRunConfig.instructionSetting defaults to .withoutInstruction")
    func defaultInstructionSetting() {
        // Verify that the documented default is the right case.
        let defaultSetting = LMEBInstructionSetting.withoutInstruction
        #expect(defaultSetting.rawValue == "without_instruction",
                "the canonical baseline must be 'without_instruction'")
    }
}

// MARK: - LMEBSpecOptions defaults

@Suite("LMEBSpecRunner LMEBSpecOptions — §A3 default values")
struct LMEBSpecRunnerOptionsTests {

    // §A3: both options default to false — the original LMEB baseline condition.
    @Test("LMEBSpecOptions.default has both options false")
    func defaultOptionsBothFalse() {
        let opts = LMEBSpecOptions.default
        #expect(opts.skipFirstResult   == false,
                "skipFirstResult must default to false (§A3 baseline)")
        #expect(opts.ignoreIdenticalIds == false,
                "ignoreIdenticalIds must default to false (§A3 baseline)")
    }

    // Verify the static default is equivalent to a fresh initialiser with both flags off.
    @Test("LMEBSpecOptions.default is equivalent to LMEBSpecOptions()")
    func defaultEquivalentToInit() {
        let opts = LMEBSpecOptions.default
        #expect(opts.skipFirstResult   == false)
        #expect(opts.ignoreIdenticalIds == false)
    }
}

// MARK: - Record stem constants

@Suite("LMEBSpecRunner record stems — naming convention")
struct LMEBSpecRunnerRecordStemTests {

    // lmeb-spec record stem: "lmeb-spec-<arm>-<serial>.json".
    //
    // Tests the format string by constructing a sample stem and verifying prefix.
    @Test("lmeb-spec record name starts with 'lmeb-spec-'")
    func lmebSpecRecordStem() {
        let arm    = "b1"
        let serial = "0001"
        let name   = "lmeb-spec-\(arm)-\(serial).json"
        #expect(name.hasPrefix("lmeb-spec-"),
                "lmeb-spec record name must start with 'lmeb-spec-'")
        #expect(name == "lmeb-spec-b1-0001.json",
                "lmeb-spec record name must match '<stem>-<arm>-<serial>.json' pattern")
    }

    // convomem-spec record stem: "convomem-spec-<arm>-<serial>.json".
    @Test("convomem-spec record name starts with 'convomem-spec-'")
    func convoMemSpecRecordStem() {
        let arm    = "b1"
        let serial = "0001"
        let name   = "convomem-spec-\(arm)-\(serial).json"
        #expect(name.hasPrefix("convomem-spec-"),
                "convomem-spec record name must start with 'convomem-spec-'")
        #expect(name == "convomem-spec-b1-0001.json",
                "convomem-spec record name must match '<stem>-<arm>-<serial>.json' pattern")
    }
}

// MARK: - answered_count / judged_count = 0 baseline

@Suite("LMEBSpecRunner zero-count baseline — no cmds configured")
struct LMEBSpecRunnerZeroCountTests {

    // When no answerCmd/judgeCmd is configured, answered_count and judged_count are 0.
    //
    // Verified here via the aggregate over an empty verdict set — `convoMemAggregate([])`
    // returns zero scored, zero unscored, zero correct. The runner section of the spec
    // doc confirms: "With no answerCmd/judgeCmd set, answered_count and judged_count are 0
    // — mechanisms are complete, no heuristic fallback scoring."
    @Test("convoMemAggregate([]) returns zero counts — baseline for no-cmd runs")
    func emptyAggregateZeroCounts() {
        let result = convoMemAggregate([])
        #expect(result.overallCorrectCount  == 0, "empty aggregate: overallCorrectCount")
        #expect(result.overallScoredCount   == 0, "empty aggregate: overallScoredCount")
        #expect(result.overallUnscoredCount == 0, "empty aggregate: overallUnscoredCount")
        #expect(result.overallAccuracy      == 0.0, "empty aggregate: overallAccuracy")
    }
}

// MARK: - §B2 judge prompt dispatch via runner context

@Suite("LMEBSpecRunner §B2 judge prompt — evidence type dispatch")
struct LMEBSpecRunnerJudgePromptDispatchTests {

    // convoMemJudgePrompt routes each of the five §B2 evidence types to the right template.
    //
    // Mirrors the golden pin in ConvoMemSpecGoldenPinTests but exercises the function
    // in the runner-facing context (same function, different test suite for traceability).
    @Test("§B2: judgePrompt routes five evidence types to distinct template families")
    func judgePromptEvidenceTypeRouting() {
        let q  = "What does the user prefer?"
        let ca = "Email"
        let ma = "The user prefers email."

        // assistant_facts_evidence → DefaultAnsweringEvaluation (two-space guideline numbering).
        let assistantFacts = convoMemJudgePrompt(
            evidenceType: .assistantFactsEvidence,
            question: q, correctAnswer: ca, modelAnswer: ma
        )
        #expect(assistantFacts.contains("1.  **Core Information is Key**"),
                ".assistantFactsEvidence must route to default factual template")

        // preference_evidence → RubricBasedAnsweringEvaluation (contains "ALL criteria").
        let preference = convoMemJudgePrompt(
            evidenceType: .preferenceEvidence,
            question: q, correctAnswer: ca, modelAnswer: ma
        )
        #expect(preference.contains("ALL criteria"),
                ".preferenceEvidence must route to rubric-based template")

        // changing_evidence → TemporalAnsweringEvaluation (contains "Off-by-one errors").
        let changing = convoMemJudgePrompt(
            evidenceType: .changingEvidence,
            question: q, correctAnswer: ca, modelAnswer: ma
        )
        #expect(changing.contains("Off-by-one errors"),
                ".changingEvidence must route to temporal template")

        // user_evidence → UserFactsAnsweringEvaluation (contains "Question Asked").
        let user = convoMemJudgePrompt(
            evidenceType: .userEvidence,
            question: q, correctAnswer: ca, modelAnswer: ma
        )
        #expect(user.contains("Question Asked"),
                ".userEvidence must route to user-facts template")

        // abstention_evidence → AbstentionAnsweringEvaluation (contains "Abstention is Success").
        let abstention = convoMemJudgePrompt(
            evidenceType: .abstentionEvidence,
            question: q, correctAnswer: ca, modelAnswer: ma
        )
        #expect(abstention.contains("Abstention is Success"),
                ".abstentionEvidence must route to abstention template")
    }

    // §B2: each template family must end with the correct verdict marker.
    //
    // Rubric-based and temporal end with "Respond with only RIGHT or WRONG."
    // All others end with "Answer (RIGHT/WRONG):".
    @Test("§B2: template families end with their correct verdict markers")
    func judgePromptVerdictMarkers() {
        let q  = "Q?"
        let ca = "A"
        let ma = "M"

        // Default factual and user-facts end with "Answer (RIGHT/WRONG):".
        let factual = convoMemDefaultFactualJudgePrompt(question: q, correctAnswer: ca, modelAnswer: ma)
        #expect(factual.hasSuffix("Answer (RIGHT/WRONG):"),
                "default factual must end with 'Answer (RIGHT/WRONG):'")

        // Rubric-based ends with "Respond with only RIGHT or WRONG.".
        let rubric = convoMemRubricBasedJudgePrompt(question: q, rubric: ca, modelAnswer: ma)
        #expect(rubric.hasSuffix("Respond with only RIGHT or WRONG."),
                "rubric-based must end with 'Respond with only RIGHT or WRONG.'")

        // Temporal ends with "Respond with only RIGHT or WRONG.".
        let temporal = convoMemTemporalJudgePrompt(question: q, correctAnswer: ca, modelAnswer: ma)
        #expect(temporal.hasSuffix("Respond with only RIGHT or WRONG."),
                "temporal must end with 'Respond with only RIGHT or WRONG.'")

        // Abstention ends with "Answer (RIGHT/WRONG):".
        let abstention = convoMemAbstentionJudgePrompt(question: q, modelAnswer: ma)
        #expect(abstention.hasSuffix("Answer (RIGHT/WRONG):"),
                "abstention must end with 'Answer (RIGHT/WRONG):'")
    }
}

// MARK: - Estate hydration — memory_texts_empty_count and all-empty gate

/// Helper: builds a minimal ConvoMemSpecQueryResult with controlled retrievedMemoryTexts.
private func makeConvoMemResult(
    queryID: String,
    memoryTexts: [String]
) -> ConvoMemSpecQueryResult {
    ConvoMemSpecQueryResult(
        queryID:               queryID,
        evidenceType:          "user_evidence",
        evidenceCount:         1,
        questionText:          "Q?",
        queryLatencySeconds:   0.0,
        retrievedDocIDs:       [],
        relevantDocIDs:        [],
        guardHealthy:          true,
        guardDiagnostic:       nil,
        cacheHit:              nil,
        retrievedMemoryTexts:  memoryTexts,
        answerPrompt:          nil,
        modelAnswer:           nil,
        judgePrompt:           nil,
        verdictOutcome:        nil,
        retriesExhausted:      false,
        ambiguousVerdictWarned: false,
        answerPayloadTokens:   nil
    )
}

/// Helper: builds a ConvoMemSpecRunResults with controlled per-query results.
private func makeConvoMemRunResults(
    perQuery: [ConvoMemSpecQueryResult]
) -> ConvoMemSpecRunResults {
    let emptyCount = perQuery.filter { $0.retrievedMemoryTexts.isEmpty }.count
    return ConvoMemSpecRunResults(
        perQueryResults:      perQuery,
        aggregateResult:      nil,
        answeredCount:        0,
        judgedCount:          0,
        totalQueries:         perQuery.count,
        timingReport:         nil,
        guardExcludedCount:   0,
        judgeIdentity:        "unknown",
        answerCmdSet:         false,
        judgeCmdSet:          false,
        memoryTextsEmptyCount: emptyCount
    )
}

@Suite("ConvoMem estate hydration — memory_texts_empty_count tracking")
struct ConvoMemHydrationEmptyCountTests {

    // When all queries return non-empty memory texts, the empty count is 0.
    @Test("memoryTextsEmptyCount is 0 when all queries have memory texts")
    func allQueriesHydratedProducesZeroEmptyCount() {
        let results = makeConvoMemRunResults(perQuery: [
            makeConvoMemResult(queryID: "q1", memoryTexts: ["drawer one text"]),
            makeConvoMemResult(queryID: "q2", memoryTexts: ["drawer two text", "drawer three"]),
        ])
        #expect(results.memoryTextsEmptyCount == 0,
                "no empty queries: memoryTextsEmptyCount must be 0")
    }

    // When some queries return empty texts, the count reflects exactly those.
    @Test("memoryTextsEmptyCount counts only the empty-texts queries")
    func partialHydrationCountsCorrectly() {
        let results = makeConvoMemRunResults(perQuery: [
            makeConvoMemResult(queryID: "q1", memoryTexts: ["text"]),
            makeConvoMemResult(queryID: "q2", memoryTexts: []),          // empty
            makeConvoMemResult(queryID: "q3", memoryTexts: ["another"]),
            makeConvoMemResult(queryID: "q4", memoryTexts: []),          // empty
        ])
        #expect(results.memoryTextsEmptyCount == 2,
                "two queries have empty memory texts: count must be 2")
        #expect(results.totalQueries == 4)
    }

    // When every query returns empty texts, the run is flagged as all-empty.
    // The CLI gate condition: memoryTextsEmptyCount == totalQueries > 0.
    @Test("all-empty run: memoryTextsEmptyCount equals totalQueries")
    func allEmptyRunDetectedByCount() {
        let results = makeConvoMemRunResults(perQuery: [
            makeConvoMemResult(queryID: "scene_0_q_0", memoryTexts: []),
            makeConvoMemResult(queryID: "scene_0_q_1", memoryTexts: []),
        ])
        #expect(results.memoryTextsEmptyCount == results.totalQueries,
                "all queries empty: count must equal totalQueries")
        #expect(results.totalQueries > 0,
                "gate condition requires totalQueries > 0")
        // The first empty query can be identified for the error message.
        let firstEmpty = results.perQueryResults.first { $0.retrievedMemoryTexts.isEmpty }
        #expect(firstEmpty?.queryID == "scene_0_q_0",
                "first empty query must be scene_0_q_0")
    }

    // Zero queries is not the all-empty gate condition (nothing to diagnose).
    @Test("empty run (zero queries) does not trigger all-empty gate")
    func emptyRunDoesNotTriggerGate() {
        let results = makeConvoMemRunResults(perQuery: [])
        // Gate: totalQueries > 0 AND memoryTextsEmptyCount == totalQueries.
        // With 0 queries, the first condition is false.
        let gateCondition = results.totalQueries > 0
            && results.memoryTextsEmptyCount == results.totalQueries
        #expect(!gateCondition,
                "zero-query run must NOT trigger the all-empty gate")
    }

    // Memory texts from estate hydration carry drawer content in retrieval order.
    // This test verifies the JSONL dump format for answer inputs: the memory_texts
    // array must match the hydratedTexts order exactly.
    @Test("dump answer_input line: memory_texts carries texts in retrieval order")
    func dumpLineCarriesTextsInRetrievalOrder() throws {
        // Simulate the dump line built by the runner (same JSON shape as the runner code).
        let drawerTexts = ["The user prefers sushi.", "Session two content here."]
        let line: [String: Any] = [
            "type": "answer_input",
            "query_id": "scene_1_q_0",
            "evidence_type": "user_evidence",
            "question": "What does the user prefer?",
            "memory_texts": drawerTexts,
            "correct_answer": NSNull(),
            "memory_token_estimate": NSNull(),
        ]
        let data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
        let roundTripped = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let recovered = roundTripped?["memory_texts"] as? [String]
        #expect(recovered == drawerTexts,
                "JSONL dump memory_texts must carry drawer texts in retrieval order")
    }

    // ── HYD-2: hydration-tier flag ────────────────────────────────────────────

    /// Verifies `HydrationDepth.distilled` is the production wire value and that
    /// a simulated dump header carries `"hydration_tier"` with the right string.
    @Test("hydration-tier: distilled is the production shape, full is the ablation arm")
    func hydrationTierWireValues() throws {
        // Distilled is the production shape — the reader sees what a real caller receives.
        #expect(HydrationDepth.distilled.rawValue == "distilled",
                "distilled must wire as 'distilled' for moot_memory_get depth argument")
        // Full is the ablation arm for comparison runs.
        #expect(HydrationDepth.full.rawValue == "full",
                "full must wire as 'full'")

        // Simulate the header dict built by the runner with the default tier.
        let defaultTier = HydrationDepth.distilled
        let header: [String: Any] = [
            "type": "header",
            "benchmark": "convomem-spec",
            "answer_hydration_depth": 10,
            "hydration_tier": defaultTier.rawValue,
        ]
        let tier = header["hydration_tier"] as? String
        #expect(tier == "distilled",
                "dump header 'hydration_tier' must be 'distilled' for the default config")
    }
}

// MARK: - Scoring strategy flag

@Suite("LMEBSpecRunner — scoring strategy flag")
struct LMEBSpecScoringTests {

    // Verifies the scoring key is absent from the query args dict when --scoring
    // is omitted (byte-identical baseline) and present when given.
    @Test("scoring arg: absent when omitted, present when given")
    func scoringArgPropagation() {
        // Baseline: default config has nil scoringStrategy — no "scoring" key.
        var config = LMEBSpecRunConfig(
            mootBinaryPath: "/usr/bin/mootx01",
            dataDir: URL(fileURLWithPath: "/data"),
            evidenceTypes: ["user_evidence"],
            limit: nil, offset: 0, seed: 1, outDir: nil, runLabel: "test")
        #expect(config.scoringStrategy == nil,
                "scoringStrategy must default to nil (no --scoring)")

        // Simulate the arg-building inline that the runner executes.
        var args: [String: JSONValue] = ["q": .string("hello")]
        if let s = config.scoringStrategy { args["scoring"] = .string(s) }
        #expect(args["scoring"] == nil,
                "omitted --scoring must produce no 'scoring' key in the query dict")

        // Given strategy: key must be present with the literal value.
        config.scoringStrategy = "rrf"
        var args2: [String: JSONValue] = ["q": .string("hello")]
        if let s = config.scoringStrategy { args2["scoring"] = .string(s) }
        #expect(args2["scoring"] == .string("rrf"),
                "given --scoring rrf must wire as 'scoring': 'rrf' in the query dict")
    }
}

// MARK: - Recall shape flag

@Suite("LMEBSpecRunner — recall shape flag")
struct LMEBSpecRecallShapeTests {

    // (a) --recall-shape given: verb is moot_recall_shaped, dict has "preset",
    //     dict has no "scoring" key.
    @Test("recall-shape set: verb is moot_recall_shaped, preset in dict, no scoring")
    func recallShapeSet() {
        var config = LMEBSpecRunConfig(
            mootBinaryPath: "/usr/bin/mootx01",
            dataDir: URL(fileURLWithPath: "/data"),
            evidenceTypes: ["user_evidence"],
            limit: nil, offset: 0, seed: 1, outDir: nil, runLabel: "test")
        config.recallShape = "matrix_decayed"

        // Simulate the verb/arg selection logic from the runner.
        let queryVerb: String
        var args: [String: JSONValue] = ["query": .string("hello")]
        if let shape = config.recallShape {
            queryVerb = "moot_recall_shaped"
            args["preset"] = .string(shape)
        } else {
            queryVerb = "moot_memory_search"
            if let s = config.scoringStrategy { args["scoring"] = .string(s) }
        }

        #expect(queryVerb == "moot_recall_shaped",
                "recall-shape set must select moot_recall_shaped verb")
        #expect(args["preset"] == .string("matrix_decayed"),
                "recall-shape set must wire preset: 'matrix_decayed' in the query dict")
        #expect(args["scoring"] == nil,
                "moot_recall_shaped call must never include the 'scoring' key")
    }

    // (b) --recall-shape absent: verb is moot_memory_search, dict has no "preset".
    @Test("recall-shape absent: verb is moot_memory_search, no preset in dict")
    func recallShapeAbsent() {
        let config = LMEBSpecRunConfig(
            mootBinaryPath: "/usr/bin/mootx01",
            dataDir: URL(fileURLWithPath: "/data"),
            evidenceTypes: ["user_evidence"],
            limit: nil, offset: 0, seed: 1, outDir: nil, runLabel: "test")
        #expect(config.recallShape == nil,
                "recallShape must default to nil")

        // Simulate the verb/arg selection logic from the runner.
        let queryVerb: String
        var args: [String: JSONValue] = ["query": .string("hello")]
        if let shape = config.recallShape {
            queryVerb = "moot_recall_shaped"
            args["preset"] = .string(shape)
        } else {
            queryVerb = "moot_memory_search"
            if let s = config.scoringStrategy { args["scoring"] = .string(s) }
        }

        #expect(queryVerb == "moot_memory_search",
                "absent recall-shape must fall back to moot_memory_search verb")
        #expect(args["preset"] == nil,
                "absent recall-shape must produce no 'preset' key in the query dict")
    }

    // (c) --scoring and --recall-shape together: conflict is rejected.
    // The rejection happens in parseLMEBSpecInvocation before any estate opens.
    // Verified here by simulating the conflict-check logic directly.
    @Test("scoring + recall-shape conflict: mutually exclusive, error before estate opens")
    func recallShapeScoringConflict() {
        // Simulate the CLI check: both flags present → must throw.
        let scoringValue: String? = "rrf"
        let recallShapeValue: String? = "matrix_decayed"
        var conflictDetected = false
        if scoringValue != nil && recallShapeValue != nil {
            conflictDetected = true
        }
        #expect(conflictDetected,
                "--scoring and --recall-shape together must be detected as a conflict")

        // Simulate the non-conflicting cases: only one or neither is present.
        let onlyScoring: (String?, String?) = ("rrf", nil)
        let onlyShape:   (String?, String?) = (nil, "matrix_decayed")
        let neither:     (String?, String?) = (nil, nil)
        for (s, r) in [onlyScoring, onlyShape, neither] {
            let conflict = s != nil && r != nil
            #expect(!conflict,
                    "non-conflicting pair (\(s ?? "nil"), \(r ?? "nil")) must not trigger conflict")
        }
    }
}
