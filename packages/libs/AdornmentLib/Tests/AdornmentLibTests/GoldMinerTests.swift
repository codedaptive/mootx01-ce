#if MOOTX01_MINERS
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

/// Rows-capable fake: witnesses that the miner reaches concrete
/// row-transport overrides through `any GoldMinerEngine`.
private final class RowsCapableFake: GoldMinerEngine {
    let identity = "test:rows-capable-fake"
    let maxConcurrentMints = 2
    var supportsRowBatching: Bool { true }
    func mint(prompt: String) async -> String? { "single" }
    func mintRows(_ rows: [String], maxLength: Int) async -> [String?] {
        rows.map { _ in "row" }
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

    @Test("miner reaches concrete row-transport overrides")
    func minerSeesConcreteRowSupport() async {
        // Regression (2026-08-30): supportsRowBatching/mintRows were
        // extension-only members, so calls through `any GoldMinerEngine`
        // statically dispatched to the defaults (false / nil) and the row
        // transport silently fell to singles on every drain. They are
        // protocol requirements now; this witnesses the dynamic dispatch
        // end-to-end through the miner actor.
        await GoldMiner.shared.install(engine: RowsCapableFake())
        let claims = await GoldMiner.shared.mintRows(["a", "b"], maxLength: 280)
        #expect(claims != nil)
        #expect(claims?.count == 2)
        #expect(claims?.allSatisfy { $0 == "row" } == true)
    }

    @Test("rows-incapable engine yields nil from the miner rows seam")
    func rowsIncapableYieldsNil() async {
        await GoldMiner.shared.install(engine: FakeEngine(identity: "fake-c"))
        let claims = await GoldMiner.shared.mintRows(["a"], maxLength: 280)
        #expect(claims == nil)
    }

    @Test("minter-scoped mint falls to the default engine when unrouted")
    func unroutedMinterFallsToDefault() async {
        await GoldMiner.shared.install(engine: FakeEngine(identity: "fake-default"))
        let out = await GoldMiner.shared.mintOne(prompt: "x", for: "some-minter-id")
        #expect(out == "fake-default:x")
    }

    #if MOOTX01_MULTI_MODEL
    @Test("multi-model registry routes minter ids to dedicated engines")
    func registryRoutesPerMinter() async {
        await GoldMiner.shared.install(engine: FakeEngine(identity: "fake-default"))
        await GoldMiner.shared.install(
            engine: FakeEngine(identity: "fake-arm"), for: "arm-1")
        let routed = await GoldMiner.shared.mintOne(prompt: "x", for: "arm-1")
        let unrouted = await GoldMiner.shared.mintOne(prompt: "x", for: "other")
        let plain = await GoldMiner.shared.mintOne(prompt: "x")
        #expect(routed == "fake-arm:x")
        #expect(unrouted == "fake-default:x")
        #expect(plain == "fake-default:x")
        await GoldMiner.shared.uninstallEngine(for: "arm-1")
        let afterRemoval = await GoldMiner.shared.mintOne(prompt: "x", for: "arm-1")
        #expect(afterRemoval == "fake-default:x")
    }
    #endif

}
#endif // MOOTX01_MINERS: the library compiles to nothing with the switch off, so do its tests.
