import Testing
@testable import VaultKit

@Test("unsupported stdio platform error has a stable code")
func unsupportedPlatformErrorHasStableCode() {
    let error = MCPClientError.unsupportedPlatform
    #expect(error.code == .unsupportedPlatform)
    #expect(error.description == "MCP stdio transport is unavailable on this platform")
}

#if !os(macOS)
@Test("stdio connect fails explicitly on platforms without subprocesses")
func connectFailsExplicitlyWithoutSubprocesses() async {
    let client = MCPStdioClient(program: "unavailable")
    do {
        try await client.connect()
        Issue.record("connect unexpectedly succeeded")
    } catch let error as MCPClientError {
        #expect(error.code == .unsupportedPlatform)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}
#endif
