// GoldMinerTests.swift — engine-plug contract tests for the resident
// gold miner (ADORNMENTLIB_SPEC 0.5.0 § Gold miner).
//
// A fake engine stands in for any model: the tests pin the OWNER's
// contract (routing, batch order, per-prompt failure passthrough,
// engine replacement) — the properties that must hold for every engine,
// which is what makes the engine a plug.

import Foundation
import Testing
@testable import AdornmentLib

/// Deterministic fake engine: answers "<identity>:<prompt>" and fails
/// (nil) on prompts containing its poison marker.
private final class FakeEngine: GoldMinerEngine {
    let identity: String
    let poison: String?
    init(identity: String, poison: String? = nil) {
        self.identity = identity
        self.poison = poison
    }
    func mint(prompt: String) async -> String? {
        if let poison, prompt.contains(poison) { return nil }
        return "\(identity):\(prompt)"
    }
}

@Suite("GoldMiner", .serialized)
struct GoldMinerTests {

    @Test("installed engine serves mintOne")
    func installedEngineServes() async {
        await GoldMiner.shared.install(engine: FakeEngine(identity: "fake-a"))
        let out = await GoldMiner.shared.mintOne(prompt: "hello")
        #expect(out == "fake-a:hello")
        #expect(await GoldMiner.shared.engineIdentity == "fake-a")
    }

    @Test("mintBatch preserves order and per-prompt failures")
    func batchOrderAndFailures() async {
        await GoldMiner.shared.install(engine: FakeEngine(identity: "fake-b", poison: "BAD"))
        let out = await GoldMiner.shared.mintBatch(prompts: ["one", "BAD apple", "three"])
        #expect(out.count == 3)
        #expect(out[0] == "fake-b:one")
        #expect(out[1] == nil)
        #expect(out[2] == "fake-b:three")
    }

    @Test("installing a new engine replaces the old one")
    func engineReplacement() async {
        await GoldMiner.shared.install(engine: FakeEngine(identity: "fake-old"))
        await GoldMiner.shared.install(engine: FakeEngine(identity: "fake-new"))
        let out = await GoldMiner.shared.mintOne(prompt: "x")
        #expect(out == "fake-new:x")
    }

}
