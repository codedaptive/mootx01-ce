import Foundation
import Network

// MARK: - LANDaemonDiscovery  (A2 — the client half of LAN discovery)
//
// Browses the local network for MOOT resident daemons advertising
// `_mootx01._tcp` and resolves each to an endpoint URL an HTTPTransport can
// take. This is deliberately ONLY the client half: Bonjour ADVERTISEMENT is
// a daemon-side feature, and the daemon is the Swift/Rust parity-bound
// engine — advertising lands there as its own engine-lane mission,
// mirrored in both languages. Until a daemon advertises, this browser
// honestly finds nothing; nothing here fabricates an endpoint.
//
// Privacy plumbing (project.yml, both app targets): NSBonjourServices lists
// `_mootx01._tcp` and NSLocalNetworkUsageDescription explains the browse —
// without both, the OS denies the browse outright on iOS and prompts
// without context on macOS.

/// One discovered daemon: its advertised service name and, once resolved,
/// the HTTP endpoint an `HTTPTransport` connects to.
public struct DiscoveredDaemon: Sendable, Equatable, Identifiable {
    /// The Bonjour service instance name (unique per daemon on the LAN).
    public let name: String
    /// The resolved `http://host:port` endpoint.
    public let endpoint: URL

    public var id: String { name }

    public init(name: String, endpoint: URL) {
        self.name = name
        self.endpoint = endpoint
    }
}

public enum LANDaemonDiscovery {

    /// The service type a MOOT resident daemon advertises.
    public static let serviceType = "_mootx01._tcp"

    /// Build the HTTP endpoint URL for a resolved host and port. IPv6
    /// literals get bracketed (and any interface scope percent-encoded) so
    /// URLSession parses them; loopback CE stays plain `http` — TLS and
    /// Enterprise OAuth compose above the transport in v2 (EE).
    public static func endpointURL(host: String, port: UInt16) -> URL? {
        guard !host.isEmpty, port > 0 else { return nil }
        let authority: String
        if host.contains(":") {
            // IPv6 literal. A link-local scope suffix ("%en0") must be
            // percent-encoded inside the brackets per RFC 6874.
            let escaped = host.replacingOccurrences(of: "%", with: "%25")
            authority = "[\(escaped)]"
        } else {
            authority = host
        }
        return URL(string: "http://\(authority):\(port)")
    }

    /// Map a Network-framework resolved endpoint onto a transport URL.
    /// Only `.hostPort` endpoints are mappable; service endpoints must be
    /// resolved through a connection first (see `LANDaemonBrowser.resolve`).
    public static func endpointURL(for endpoint: NWEndpoint) -> URL? {
        guard case .hostPort(let host, let port) = endpoint else { return nil }
        let hostString: String
        switch host {
        case .ipv4(let address):
            hostString = "\(address)"
        case .ipv6(let address):
            hostString = "\(address)"
        case .name(let name, _):
            hostString = name
        @unknown default:
            return nil
        }
        return endpointURL(host: hostString, port: port.rawValue)
    }
}

// MARK: - LANDaemonBrowser

/// Wraps NWBrowser: stream the set of advertised service names, and resolve
/// one service to a connectable endpoint URL. UI (the Engine tab) owns the
/// browser's lifetime; discovery stops when the stream's consumer cancels.
public final class LANDaemonBrowser: @unchecked Sendable {

    private let browser: NWBrowser
    private let queue = DispatchQueue(label: "com.codedaptive.mootx01.lan-browser")

    public init() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        browser = NWBrowser(
            for: .bonjour(type: LANDaemonDiscovery.serviceType, domain: nil),
            using: parameters)
    }

    /// Start browsing. Yields the full set of advertised service names on
    /// every change; finishes when the browser fails or is cancelled.
    public func serviceNames() -> AsyncStream<[String]> {
        AsyncStream { continuation in
            browser.browseResultsChangedHandler = { results, _ in
                let names = results.compactMap { result -> String? in
                    guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                    return name
                }
                continuation.yield(names.sorted())
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { continuation.finish() }
                if case .cancelled = state { continuation.finish() }
            }
            continuation.onTermination = { [browser] _ in
                browser.cancel()
            }
            browser.start(queue: queue)
        }
    }

    /// Resolve one advertised service to its host:port endpoint by opening a
    /// connection and reading the ready path's remote endpoint. The
    /// connection is torn down immediately — the caller then talks to the
    /// daemon through HTTPTransport, not this socket.
    public func resolve(serviceName: String, timeout: TimeInterval = 10) async throws -> URL {
        let endpoint = NWEndpoint.service(
            name: serviceName,
            type: LANDaemonDiscovery.serviceType,
            domain: "local.",
            interface: nil)
        let connection = NWConnection(to: endpoint, using: .tcp)

        return try await withCheckedThrowingContinuation { continuation in
            let finished = ResolveOnce()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let remote = connection.currentPath?.remoteEndpoint
                    connection.cancel()
                    if let remote, let url = LANDaemonDiscovery.endpointURL(for: remote) {
                        finished.resume { continuation.resume(returning: url) }
                    } else {
                        finished.resume {
                            continuation.resume(throwing: GatewayTransportError.malformedResponse(
                                "Resolved \(serviceName) but its endpoint has no host:port"))
                        }
                    }
                case .failed(let error):
                    connection.cancel()
                    finished.resume { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                connection.cancel()
                finished.resume {
                    continuation.resume(throwing: GatewayTransportError.timeout(
                        endpoint: URL(string: "bonjour://\(serviceName)")!, after: timeout))
                }
            }
            connection.start(queue: queue)
        }
    }
}

/// Guards a continuation against double-resume across the racing state
/// handler and timeout paths.
private final class ResolveOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resume(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        body()
    }
}
