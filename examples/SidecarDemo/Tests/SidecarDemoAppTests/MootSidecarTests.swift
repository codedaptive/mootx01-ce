import Foundation
import Testing
import AriaMCP
@testable import SidecarDemoApp

/// Smoke coverage for `MootSidecar`. The sidecar is glue, so the tests
/// verify the glue: an in-memory attach succeeds, the dispatcher carries
/// a non-empty tool surface (proving the AriaLexicon verb-noun
/// projection wired through), and the dispatcher answers the MCP
/// `initialize` handshake with the identity the sidecar was constructed
/// with.
///
/// We do not re-test the dispatcher's protocol semantics — ARIA_MCP's
/// own tests own that. We only check that `MootSidecar` produces a
/// correctly-wired dispatcher.
@Suite("MootSidecar")
struct MootSidecarTests {

    @Test func attachInMemoryReturnsDispatcherWithToolSurface() async throws {
        let sidecar = try await MootSidecar.attachInMemory()

        // A non-empty tool surface proves AriaLexicon's verb-noun
        // matrix projected. The exact count is owned by AriaLexicon
        // and changes with the lexicon, so the test only asserts
        // non-emptiness.
        #expect(
            sidecar.dispatcher.tools.count > 0,
            "Sidecar dispatcher should expose the projected tool surface"
        )
    }

    @Test func attachInMemoryRespectsCustomIdentity() async throws {
        let identity = MootSidecar.Identity(
            name: "ExampleCorp-Notes-Sidecar",
            version: "9.9.9"
        )
        let sidecar = try await MootSidecar.attachInMemory(identity: identity)

        #expect(sidecar.identity.name == "ExampleCorp-Notes-Sidecar")
        #expect(sidecar.identity.version == "9.9.9")
        #expect(sidecar.dispatcher.info.name == "ExampleCorp-Notes-Sidecar")
        #expect(sidecar.dispatcher.info.version == "9.9.9")
    }

    @Test func initializeHandshakeAnnouncesSidecarIdentity() async throws {
        let identity = MootSidecar.Identity(
            name: "SidecarDemo-test",
            version: "0.0.1"
        )
        let sidecar = try await MootSidecar.attachInMemory(identity: identity)

        let request = JSONRPCRequest(
            id: .integer(1),
            method: "initialize",
            params: .object(["protocolVersion": .string("2024-11-05")])
        )
        let rawResponse = await sidecar.dispatcher.handle(request)
        let response = try #require(rawResponse)

        guard case .result(let result) = response.payload else {
            Issue.record("initialize returned error: \(response.payload)")
            return
        }
        let serverInfo = try #require(
            result.objectValue?["serverInfo"]?.objectValue
        )
        #expect(serverInfo["name"] == .string("SidecarDemo-test"))
        #expect(serverInfo["version"] == .string("0.0.1"))
    }
}
