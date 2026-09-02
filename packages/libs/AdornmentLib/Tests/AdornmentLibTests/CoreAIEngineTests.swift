// CoreAIEngineTests.swift — asset-free checks on the Core AI engine.
//
// The engine itself needs a converted .aimodel to construct, so the
// generation-budget rule is exercised through its pure static helper.
// Compiled only where the Core AI runtime is importable (macOS 27+ SDK).

#if canImport(CoreAI)
import Testing
@testable import AdornmentLib

@Suite("CoreAIEngine generation budget")
struct CoreAIEngineBudgetTests {

    @Test("a budget equal to the cache length is rejected")
    func budgetAtCacheLengthThrows() throws {
        guard #available(macOS 27.0, *) else { return }
        #expect(throws: (any Error).self) {
            try CoreAIEngine.validateGenerationBudget(maxNewTokens: 2560, maxCache: 2560)
        }
    }

    @Test("a budget one below the cache length still leaves no prompt room")
    func budgetAtCacheMinusOneThrows() throws {
        guard #available(macOS 27.0, *) else { return }
        #expect(throws: (any Error).self) {
            try CoreAIEngine.validateGenerationBudget(maxNewTokens: 2559, maxCache: 2560)
        }
    }

    @Test("a budget two below the cache length leaves exactly one prompt token")
    func budgetAtCacheMinusTwoPasses() throws {
        guard #available(macOS 27.0, *) else { return }
        try CoreAIEngine.validateGenerationBudget(maxNewTokens: 2558, maxCache: 2560)
    }

    @Test("the default 96-token budget passes against the standard cache")
    func defaultBudgetPasses() throws {
        guard #available(macOS 27.0, *) else { return }
        try CoreAIEngine.validateGenerationBudget(maxNewTokens: 96, maxCache: 2560)
    }

    @Test("the rejection names both numbers")
    func rejectionNamesBothNumbers() throws {
        guard #available(macOS 27.0, *) else { return }
        do {
            try CoreAIEngine.validateGenerationBudget(maxNewTokens: 2560, maxCache: 2560)
            Issue.record("expected a throw")
        } catch {
            let text = "\(error)"
            #expect(text.contains("2560"))
            #expect(text.contains("budget"))
        }
    }
}
#endif

#if canImport(CoreAI)
/// Asset-free checks on the tokenizer input bound `generate` applies
/// before encoding (Codex finding 3cf82eb4): the bound is a pure
/// function of the prompt cap, and the cut keeps exactly that many
/// leading Characters.
@Suite("CoreAIEngine tokenizer input bound")
struct CoreAIEngineTokenizerBoundTests {

    @Test("the bound is four characters per prompt token")
    func boundIsFourPerToken() {
        guard #available(macOS 27.0, *) else { return }
        // 2560-token cache, 96-token budget: cap 2463 → 9852 characters.
        #expect(CoreAIEngine.tokenizerInputBound(promptCap: 2463) == 9852)
        #expect(CoreAIEngine.tokenizerInputBound(promptCap: 1) == 4)
    }

    @Test("a prompt within the bound is returned unchanged")
    func withinBoundUnchanged() {
        guard #available(macOS 27.0, *) else { return }
        let prompt = String(repeating: "a", count: 40)
        #expect(CoreAIEngine.boundTokenizerInput(prompt, promptCap: 10) == prompt)
        // Exactly at the bound is within it.
        let exact = String(repeating: "b", count: 12)
        #expect(CoreAIEngine.boundTokenizerInput(exact, promptCap: 3) == exact)
    }

    @Test("a prompt over the bound is cut to its leading bound characters")
    func overBoundIsCut() {
        guard #available(macOS 27.0, *) else { return }
        let prompt = String(repeating: "x", count: 4_000) + "TAIL"
        let cut = CoreAIEngine.boundTokenizerInput(prompt, promptCap: 5)
        #expect(cut == String(repeating: "x", count: 20))
    }

    @Test("the cut counts Characters, so a multi-byte prefix keeps all of them")
    func cutCountsCharacters() {
        guard #available(macOS 27.0, *) else { return }
        // 8 four-byte emoji (32 UTF-8 bytes) trip the UTF-8 pre-check
        // for an 8-Character bound yet fit it; the cut keeps every
        // emoji, and one more Character crosses the bound.
        let eight = String(repeating: "🌱", count: 8)
        #expect(CoreAIEngine.boundTokenizerInput(eight, promptCap: 2) == eight)
        #expect(CoreAIEngine.boundTokenizerInput(eight + "z", promptCap: 2) == eight)
    }
}
#endif
