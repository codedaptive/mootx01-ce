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
// local MOOT) is real; the outbound MCP-client transport to the remote estate
// is not built (it shares the A2 HTTP gap). Convening proper — two MOOTs
// exchanging only what each authorized, then separating — is the ARIA access-
// surface capability (invariant I-13), elaborated at ARIA_MCP, not here.

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

    /// Fetch records from a remote estate. SHELL: no outbound transport in
    /// this branch (see HTTPTransportSeam / A2). Throws to name the gap rather
    /// than return fabricated data.
    public func fetch(from endpoint: URL, query: String) async throws -> [RemoteRecord] {
        throw MootEstateClientError.outboundTransportNotInThisBranch(endpoint: endpoint)
    }

    /// Fold remote records into the local MOOT via capture. This half IS real:
    /// once `fetch` is supplied, ingest works through the local tool surface,
    /// stamping the imported provenance the substrate already supports.
    public func foldIn(_ records: [RemoteRecord], using bridge: MootBridge) async throws -> Int {
        var filed = 0
        for record in records {
            let call = await bridge.callTool("moot_file_memory", arguments: [
                "content": .string(record.content),
                "location": .string(record.location),
            ])
            if !call.isError { filed += 1 }
        }
        return filed
    }
}

public enum MootEstateClientError: Error, CustomStringConvertible {
    case outboundTransportNotInThisBranch(endpoint: URL)

    public var description: String {
        switch self {
        case .outboundTransportNotInThisBranch(let endpoint):
            return "Outbound MCP-client transport to \(endpoint) is not yet implemented (shares the A2 HTTP gap). The fold-in path via capture is real; supply fetch to complete A3."
        }
    }
}
