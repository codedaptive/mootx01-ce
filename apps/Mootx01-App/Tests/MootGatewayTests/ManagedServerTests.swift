import Testing
import Foundation
@testable import MootGateway

// Proves the macOS-only "app-managed daemon" path end-to-end: the app spawns
// the REAL, untouched aria-mcp binary as a child process and talks to it over
// stdio JSON-RPC. If the release binary hasn't been built, the test
// skips rather than failing — build it with:
//   swift build --package-path apps/aria-mcp-server -c release --product aria-mcp

#if os(macOS)
@Suite("Managed server (app-managed daemon)")
struct ManagedServerTests {

    /// Locate the prebuilt aria-mcp relative to this source file's repo root.
    private func ariaMCPBinary() -> URL? {
        // …/apps/Mootx01-App/Tests/MootGatewayTests/ManagedServerTests.swift → repo root is 5 up
        // (file → MootGatewayTests → Tests → Mootx01 → apps → repo root).
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { dir.deleteLastPathComponent() }
        let candidates = [
            dir.appendingPathComponent("apps/aria-mcp-server/.build/release/aria-mcp"),
            dir.appendingPathComponent("apps/aria-mcp-server/.build/debug/aria-mcp"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    @Test("spawns the real server and round-trips tools/list over stdio")
    func managedRoundTrip() async throws {
        guard let binary = ariaMCPBinary() else {
            // No binary built — skip without failing (documented above).
            return
        }
        let server = ManagedServerProcess(binaryURL: binary, databaseURL: nil)
        try await server.start()
        defer { Task { await server.stop() } }

        let response = try await server.send(method: "tools/list", params: nil)
        guard case .result(let value) = response.payload else {
            Issue.record("expected a result from tools/list over the managed server")
            return
        }
        let names = (value.objectValue?["tools"]?.arrayValue ?? [])
            .compactMap { $0.objectValue?["name"]?.stringValue }
        #expect(names.contains("moot_file_memory"))
        #expect(names.contains("moot_memory_search"))

        await server.stop()
    }
}
#endif
