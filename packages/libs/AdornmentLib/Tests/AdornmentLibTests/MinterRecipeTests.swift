#if MOOTX01_MINERS
// MinterRecipeTests.swift — recipe identity, digest, and normalizer
// contract tests (ADORNMENTLIB_SPEC 0.6.0 § Minter recipes).
//
// The digest golden pins and the normalizer fixtures are TWINNED with
// `minter_recipe.rs` tests: the same literal inputs and expected outputs
// are asserted in both ports. A divergence means the ports would
// register mismatched master rows (digests) or render different claim
// lines (normalizer) for the same recipe.

import Foundation
import Testing
@testable import AdornmentLib

@Suite("MinterRecipe")
struct MinterRecipeTests {

    @Test("FNV-1a-64 golden pins match the Rust port")
    func digestGoldenPins() {
        #expect(fnv1a64Hex("") == "cbf29ce484222325")
        #expect(fnv1a64Hex("abc") == "e71fa2190541574b")
        #expect(fnv1a64Hex("gold miner recipe digest test vector é中") == "e25b307539822f8e")
    }

    @Test("composed ID and descriptor carry the recipe contract")
    func composedIDAndDescriptor() {
        let recipe = MinterRecipe.apple
        #expect(recipe.id == "apple-fm-p1-s1")
        let d = recipe.descriptor(id: "row-3", isActive: true)
        #expect(d.name == "apple-fm-p1-s1")
        #expect(d.modelID == "apple-fm")
        #expect(d.modelVersion == "p1-s1")
        #expect(d.family == "apple")
        #expect(d.promptDigest == recipe.promptDigest)
        #expect(d.parameters["settings_digest"] == recipe.parametersDigest)
        #expect(d.parameters["sampling"] == "greedy")
        #expect(d.isActive)
    }

    @Test("engine identity is the recipe's composed ID")
    func engineIdentityIsRecipeID() {
        // The Apple engine's identity must be the cross-device minter
        // identity, never a port- or framework-local name. On hosts
        // without the Apple model (pre-26 OS, CI) ifAvailable() is nil
        // and the fallback arm makes this vacuously true — real coverage
        // fires wherever the engine is available.
        #expect(AppleFoundationEngine.ifAvailable()?.identity ?? MinterRecipe.apple.id == MinterRecipe.apple.id)
    }

    @Test("Core AI NuExtract B1 Q8 recipe pins model geometry and budget")
    func nuextractB1Q8Recipe() {
        let recipe = MinterRecipe.nuextractTinyV15B1Q8
        #expect(recipe.id == "nuextract-tiny-v1.5-b1-q8-p1-s1")
        #expect(recipe.output == .json)
        #expect(recipe.parameters["batch_width"] == "1")
        #expect(recipe.parameters["max_new_tokens"] == "256")
        #expect(recipe.parameters["style"] == "nuextract")
        #expect(recipe.chatTemplate.contains("<|input|>"))
        #expect(recipe.chatTemplate.contains("{input}"))
        #expect(recipe.chatTemplate.contains("<|output|>"))
    }

    @Test("normalizer text fixtures (twinned with Rust)")
    func normalizerTextFixtures() {
        #expect(normalizeMintOutput("```\n- the claim<|im_end|>\n```", kind: .text) == "the claim")
        #expect(normalizeMintOutput("\n\n  * spaced claim  \n rest", kind: .text) == "spaced claim")
        #expect(normalizeMintOutput("", kind: .text) == "")
    }

    @Test("normalizer JSON fixtures (twinned with Rust)")
    func normalizerJSONFixtures() {
        // Object: lexical key order; nested array values recurse in order.
        #expect(
            normalizeMintOutput(
                #"{"entities": ["Alice", "straw"], "claim": "planted 12 saplings", "date": "2026-08-26"}"#,
                kind: .json
            ) == "planted 12 saplings; 2026-08-26; Alice; straw"
        )
        // Fenced JSON parses; numbers/bools canonical; null + empty skipped.
        #expect(
            normalizeMintOutput(
                "```json\n{\"b_count\": 12, \"a_flag\": true, \"c_null\": null, \"d\": \"\"}\n```",
                kind: .json
            ) == "true; 12"
        )
        // Non-JSON emission under a Json recipe: deterministic text salvage.
        #expect(normalizeMintOutput("- fallback prose line\n", kind: .json) == "fallback prose line")
        // Integer beyond Double's 53-bit mantissa must render exactly
        // (int64-first path both ports): 2^53 + 1.
        #expect(normalizeMintOutput(#"{"n": 9007199254740993}"#, kind: .json) == "9007199254740993")
    }

    @Test("JSON structural stop ignores quoted and nested braces")
    func jsonStructuralStop() {
        #expect(topLevelJSONObjectPrefix(
            #" {"claim":"literal } and \"quoted\"","nested":{"n":1}} trailing"#)
            == #"{"claim":"literal } and \"quoted\"","nested":{"n":1}}"#)
        #expect(topLevelJSONObjectPrefix(
            #"{"claim":"still open","nested":{"n":1}"#) == nil)
        #expect(topLevelJSONObjectPrefix(
            #"prose before {"n":1}"#) == nil)
        #expect(topLevelJSONObjectPrefix(#"{"claim":"x",}"#) == nil)
        #expect(topLevelJSONObjectPrefix(#"{"a":[1}"#) == nil)
    }

    @Test("JSON same-token suffixes retain and normalize only the object prefix")
    func jsonSameTokenSuffixes() {
        let expectedPrefix = #"{"claim":"kept","nested":[{"literal":"} { \"quoted\""}]}"#
        let expectedClaim = "kept; } { \"quoted\""
        for suffix in [".", ",", ");\n"] {
            let raw = " \(expectedPrefix)\(suffix)"
            #expect(topLevelJSONObjectPrefix(raw) == expectedPrefix)
            #expect(normalizeMintOutput(raw, kind: .json) == expectedClaim)
        }
    }
}
#endif // MOOTX01_MINERS: the library compiles to nothing with the switch off, so do its tests.
