import Foundation
import AriaMCP
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import OSLog

// MARK: - Agent-readable wiring notes
//
// This file is the sidecar attachment in ~50 lines. An agent that reads
// this file alone can wire a MOOT into any existing macOS application
// without consulting the rest of the repository.
//
// The pattern is three steps, in order:
//
//   1. Choose a backend. A backend is anything that conforms to
//      `PersistenceKit.Storage`. For the launch demo we use
//      `InMemoryStorage`; a production sidecar would swap in the
//      SQLite-backed storage from PersistenceKit. The choice does not
//      affect the rest of the wiring.
//
//   2. Initialize the estate, then open the GeniusLocusKit coordinator
//      on top. The two-step is load-bearing: `LocusKit.Estate.create`
//      installs the substrate schema on the backend, and
//      `GeniusLocusKit.open` returns the coordinator handle that drives
//      every verb call. Calling `open` without first calling `create`
//      leaves the backend without a schema and the open will fail.
//
//   3. Construct the ARIA_MCP tool dispatcher and wrap it in
//      `ARIA_MCPDispatcher`. The dispatcher carries the projected verb-noun
//      tool surface from AriaLexicon. Any MCP client that reaches the
//      stdio server can list these tools and call them.
//
// An existing application does not lose anything by adopting this
// pattern. The MOOT lives beside the app's own state, in its own
// backend, and the ARIA_MCP server is a single struct the app can
// host wherever it pleases — its own stdio loop, a child process, or
// an SSE endpoint built on the same dispatcher.

/// `MootSidecar` is the attachment object the sidecar demonstration ships.
///
/// A host application creates one `MootSidecar` per estate it wants to
/// attach. The sidecar owns the storage backend, the estate's
/// `GeniusLocusKit` handle, and a fully constructed
/// `ARIA_MCPDispatcher` ready to serve MCP requests. The host reads
/// `dispatcher` back out to drive an MCP transport (stdio, SSE, in-process
/// tests) and reads `handle` to call verbs from inside its own code.
///
/// The sidecar does not own a transport. The executable target in this
/// package wires the dispatcher to `StdioServer`, but a host could just
/// as well attach the same dispatcher to a different transport, or call
/// it directly from a unit test.
public final class MootSidecar: Sendable {

    /// Server identity surfaced to MCP clients in the `initialize`
    /// response. The host app may override this to differentiate its
    /// sidecar from a vanilla `aria-mcp` instance — a name like
    /// "ExampleCorp-Notes-Sidecar" tells the client which app's MOOT
    /// it is talking to.
    public struct Identity: Sendable {
        public let name: String
        public let version: String

        public init(name: String, version: String) {
            self.name = name
            self.version = version
        }

        /// Default identity for the bundled `sidecar-demo` executable.
        public static let demoDefault = Identity(
            name: "Sidecar_Demo_macOS",
            version: "0.1.0"
        )
    }

    public let identity: Identity
    public let kit: GeniusLocusKit
    public let handle: EstateHandle
    public let dispatcher: ARIA_MCPDispatcher

    private init(
        identity: Identity,
        kit: GeniusLocusKit,
        handle: EstateHandle,
        dispatcher: ARIA_MCPDispatcher
    ) {
        self.identity = identity
        self.kit = kit
        self.handle = handle
        self.dispatcher = dispatcher
    }

    /// Attach a fresh in-memory MOOT and return the wired sidecar.
    ///
    /// Convenience entry point used by the bundled `sidecar-demo`
    /// executable and the smoke test. Production sidecars wanting a
    /// durable estate should call `attach(storage:owner:identity:)`
    /// with a SQLite-backed backend.
    public static func attachInMemory(
        identity: Identity = .demoDefault,
        ownerIdentifier: String = "sidecar-demo-owner"
    ) async throws -> MootSidecar {
        let owner = OwnerCredentials(ownerIdentifier: ownerIdentifier)
        let configuration = EstateConfiguration(
            estateID: UUID(),
            backend: .inMemory
        )
        let storage = InMemoryStorage(configuration: configuration)
        return try await attach(
            storage: storage,
            owner: owner,
            identity: identity
        )
    }

    /// Attach a MOOT on `storage` for `owner` and project it over the
    /// ARIA_MCP tool surface.
    ///
    /// Step 1 of the wiring lives in the caller: pick a backend that
    /// conforms to `PersistenceKit.Storage`. Step 2 (estate-then-coordinator)
    /// and step 3 (dispatcher) are inside this method.
    public static func attach(
        storage: some Storage,
        owner: OwnerCredentials,
        identity: Identity = .demoDefault
    ) async throws -> MootSidecar {
        let kit = GeniusLocusKit()

        // Step 2: substrate schema first, then the coordinator on top.
        // The `_ =` is intentional — Estate.create returns the freshly
        // created estate, but the sidecar only needs the handle from
        // `open`. The schema side-effect on the backend is what we are
        // here for.
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)

        // Step 3: ARIA_MCP dispatcher. ToolDispatcher carries the
        // verb-noun execution; ARIA_MCPDispatcher carries the JSON-RPC
        // method routing (initialize, tools/list, tools/call). The
        // tool surface comes from AriaLexicon's verb-noun acceptance
        // matrix; it is the same surface every other ARIA_MCP server
        // projects, because every server projects the same lexicon.
        let info = ARIA_MCPDispatcher.ServerInfo(
            name: identity.name,
            version: identity.version
        )
        let tooling = ToolDispatcher(kit: kit, handle: handle)
        let dispatcher = ARIA_MCPDispatcher(info: info, tooling: tooling)

        return MootSidecar(
            identity: identity,
            kit: kit,
            handle: handle,
            dispatcher: dispatcher
        )
    }
}
