// ServeFrozenGateTests.swift — source-shape guard for the frozen serve posture.
//
// `ServeCommand` lives in the executable target, which a test target cannot
// import, so the gates are checked on the source text: a stdio serve spawns
// no background worker at all (§ DUTY_LIFECYCLE), and a frozen serve refuses
// HTTP and forwarding.

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

    /// A stdio serve spawns no background process (GENIUSLOCUSKIT_SPEC
    /// § DUTY_LIFECYCLE): no dreamer, no drainer, no periodic timer.
    @Test func stdioServeSpawnsNoBackgroundWorker() throws {
        let lines = try serveCommandSource()
        let spawnSites = lines.filter {
            $0.contains("spawnDetached") || $0.contains("periodicDream")
                || $0.contains("backgroundWorkerPermitted")
        }
        #expect(spawnSites.isEmpty, "serve must not spawn or schedule a background worker: \(spawnSites)")
    }

    @Test func frozenRefusesHTTPAndForwarding() throws {
        let source = try serveCommandSource().joined(separator: "\n")
        #expect(source.contains("EstatePosture.resolve(frozenFlag: frozen, environment: environment)"))
        #expect(source.contains("cannot be combined with --http"))
        #expect(source.contains("a frozen serve cannot forward to a live daemon"))
        #expect(source.contains("posture: posture\n"), "the dispatcher must receive the resolved posture")
    }
}
