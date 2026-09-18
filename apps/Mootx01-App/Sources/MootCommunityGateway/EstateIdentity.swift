import Foundation

// MARK: - Estate identity
//
// What the app may say about "which estate am I talking to".
//
// Today the UI answers that question with a filesystem path, because the app
// opens the estate itself and the path is the only name it has. A daemon client
// has no such path, and must not: a client that knows the estate file's
// location is one refactor away from opening it, and the single-writer
// invariant is what stands between that and a corrupted estate.
//
// So identity becomes a value with two real forms rather than an optional
// string. The embedded form names a file this process opened. The daemon form
// names an estate by the identifier its owner published in the descriptor —
// which is also the identifier readiness already checks the daemon's own MCP
// handshake against, so it is a name that has been proved rather than claimed.
//
// The ephemeral case is not a failure case. An in-memory estate genuinely has
// no durable identity, and saying so is more honest than an empty path.
//
// This type carries no file URL for the daemon form on purpose. There is
// nowhere in a client that should be able to reach one.

/// Which estate a surface is attached to, in terms that surface may know.
public enum EstateIdentity: Sendable, Equatable {

    /// This process opened the estate file at this path and is its writer.
    case embedded(path: String)

    /// A resident daemon owns the estate. Named by the identifiers it
    /// published, never by a location on disk.
    case daemon(estate: UUID, service: String)

    /// An in-memory estate with no durable identity.
    case ephemeral

    /// A short label for display.
    ///
    /// Callers localize their own surrounding chrome; this returns only the
    /// identifying token itself, which is a path or an identifier in every case
    /// and so is not translated.
    public var displayToken: String {
        switch self {
        case .embedded(let path):
            return path
        case .daemon(let estate, let service):
            // Service first: it is the stable, human-recognizable half, and the
            // estate UUID is what distinguishes two estates under one service.
            return "\(service) · \(estate.uuidString)"
        case .ephemeral:
            return "in-memory"
        }
    }

    /// Whether this process opened storage to reach the estate.
    ///
    /// The cutover's load-bearing claim is that a macOS GUI never does. This is
    /// the property a test asserts against.
    public var opensLocalStorage: Bool {
        switch self {
        case .embedded:
            return true
        case .daemon, .ephemeral:
            return false
        }
    }
}
