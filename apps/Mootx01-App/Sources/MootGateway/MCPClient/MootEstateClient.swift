import Foundation
import AriaMCP   // JSONValue

// MARK: - MootEstateClient  (A3 — consume other estates)
//
// The convene-ingest leg: MOOTx01 reading *another* estate (a calendar's
// MOOT, a colleague's exported wing) and folding what it's allowed to see
// back in via capture/learn. This is deliberately a SEPARATE component, not
// ARIA_MCP wearing a client hat — ARIA_MCP_SPEC §5 is explicit: "ARIA is
// always the MCP server; it never acts as a client of another MCP server."
// So the client lives here, outside the server surface.
//
// SHELL: the ingest shape is defined and the fold-in path (capture into the
// local MOOT) is real; the outbound MCP-client transport to a remote estate
// is not built here. The A2 loopback transport (HTTPTransport) is live and
// connects this app to its own resident daemon — but outbound federation
// (MOOT-to-MOOT, two estates exchanging only what each authorized) is the
// ARIA access-surface capability (invariant I-13), elaborated at ARIA_MCP.
// That is a v1.1 surface by ruling — not an A2 gap but a deliberate deferral.

public struct MootEstateClient: Sendable {

    public init() {}

    /// A record fetched from a remote estate, normalized for fold-in.
    public struct RemoteRecord: Sendable {
        public let content: String
        public let location: String
        public init(content: String, location: String) {
            self.content = content
            self.location = location
        }
    }

    /// Fetch records from a remote estate. SHELL: outbound federation to another
    /// estate is v1.1 by ruling — not an A2 gap. Throws to name the deferral
    /// rather than return fabricated data. The A2 loopback transport is live
    /// (see HTTPTransport); this is a separate, deliberate v1.1 surface.
    public func fetch(from endpoint: URL, query: String) async throws -> [RemoteRecord] {
        throw MootEstateClientError.outboundFederationNotInThisVersion(endpoint: endpoint)
    }

    /// Fold remote records into the local MOOT via capture. This half IS real:
    /// once `fetch` is supplied, ingest works through the local tool surface,
    /// stamping the imported provenance the substrate already supports.
    public func foldIn(_ records: [RemoteRecord], using bridge: MootBridge) async throws -> Int {
        var filed = 0
        for record in records {
            let call = await bridge.callToolFull("moot_file_memory", arguments: [
                "content": .string(record.content),
                "location": .string(record.location),
            ])
            if !call.isError { filed += 1 }
        }
        return filed
    }
}

public enum MootEstateClientError: Error, CustomStringConvertible {
    case outboundFederationNotInThisVersion(endpoint: URL)

    public var description: String {
        switch self {
        case .outboundFederationNotInThisVersion(let endpoint):
            return "Outbound federation to \(endpoint) is a v1.1 surface by ruling. The fold-in path via capture is real; supply fetch to complete A3 in v1.1."
        }
    }
}
