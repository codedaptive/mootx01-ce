// ServeFrozenGateTests.swift — source-shape guard for the frozen serve posture.
//
// `ServeCommand` lives in the executable target, which a test target cannot
// import, so the gate is checked on the source text: every detached-worker
// spawn in ServeCommand.swift must sit under a `backgroundWorkerPermitted`
// guard, and the periodic dreamer must be created only for a live posture.
// A new spawn site added without the guard fails here, not in a benchmark.

import Testing
import Foundation

@Suite("ServeCommand frozen gate (source shape)")
struct ServeFrozenGateTests {

    private func serveCommandSource() throws -> [String] {
        let here = URL(fileURLWithPath: #filePath)
        let source = here
            .deletingLastPathComponent()   // strip the file name
            .deletingLastPathComponent()   // MootInstallerCoreTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Sources/mootx01/Commands/ServeCommand.swift")
        return try String(contentsOf: source, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    @Test func everyDetachedWorkerSpawnIsGuarded() throws {
        let lines = try serveCommandSource()
        var spawnSites = 0
        for (index, line) in lines.enumerated()
        where line.contains("Self.spawnDetachedDream(") || line.contains("Self.spawnDetachedDrain(") {
            spawnSites += 1
            // The periodic dreamer's spawn sits inside a Task that is only
            // created when the posture is live; its guard is the `posture ==
            // .live ? Task` construction rather than a call-site check.
            let window = lines[max(0, index - 40)..<index].joined(separator: "\n")
            let guarded = window.contains("backgroundWorkerPermitted(posture")
                || window.contains("posture == .live ? Task")
            #expect(guarded, "spawn at ServeCommand.swift:\(index + 1) is not under the frozen gate")
        }
        // Startup dreamer, periodic dreamer, exit drainer, exit dreamer.
        #expect(spawnSites == 4, "expected 4 spawn sites, found \(spawnSites)")
    }

    @Test func frozenRefusesHTTPAndForwarding() throws {
        let source = try serveCommandSource().joined(separator: "\n")
        #expect(source.contains("EstatePosture.resolve(frozenFlag: frozen, environment: environment)"))
        #expect(source.contains("cannot be combined with --http"))
        #expect(source.contains("a frozen serve cannot forward to a live daemon"))
        #expect(source.contains("posture: posture\n"), "the dispatcher must receive the resolved posture")
    }
}
