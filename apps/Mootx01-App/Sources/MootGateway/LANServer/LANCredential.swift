import Foundation
import CryptoKit
import MootIntentKit   // ShareInboxSpool.appGroupID + SpoolError (shared app-group plumbing)

// MARK: - LANCredential  (the "credentialed connection" secret)
//
// A bearer token a LAN MCP client must present. The token is a 256-bit
// CSPRNG value, base64url-encoded, persisted per estate in the app-group
// container so the same secret survives relaunch and both app targets agree.
// Comparison is constant-time (SHA-256 of both sides, then a fixed-time
// digest equality) so a remote attacker cannot time-probe the token.
//
// This is transport credentialing for the app's own listener, not estate
// encryption (that stays SQLCipher, engine-side). Regenerating invalidates
// every prior client — the UI offers it as an explicit action.

public struct LANCredential: Sendable, Equatable {
    /// The bearer token string the client sends in `Authorization: Bearer <token>`.
    public let token: String

    public init(token: String) { self.token = token }

    /// Mint a fresh 256-bit token, base64url without padding.
    public static func generate() -> LANCredential {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        return LANCredential(token: Data(bytes).base64URLEncodedString())
    }

    /// Constant-time check of a presented token against this credential.
    /// Hashing both sides first makes the comparison independent of token
    /// length and content, closing the timing side channel.
    public func matches(presented: String) -> Bool {
        let a = SHA256.hash(data: Data(token.utf8))
        let b = SHA256.hash(data: Data(presented.utf8))
        // Digest is fixed 32 bytes; compare byte-by-byte with no early exit.
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }

    /// Extract a bearer token from an HTTP Authorization header value.
    /// Returns nil for any non-Bearer or malformed header.
    public static func bearerToken(fromAuthorizationHeader header: String?) -> String? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        let prefix = "Bearer "
        guard trimmed.count > prefix.count,
              trimmed.prefix(prefix.count).caseInsensitiveCompare(prefix) == .orderedSame else {
            return nil
        }
        let token = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }
}

// MARK: - Persistence

/// Loads/stores/rotates the LAN credential in the app-group container.
public struct LANCredentialStore: Sendable {

    public let fileURL: URL

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("lan-credential.token")
    }

    public static func groupStore() throws -> LANCredentialStore {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ShareInboxSpool.appGroupID) else {
            throw ShareInboxSpool.SpoolError.groupContainerUnavailable(ShareInboxSpool.appGroupID)
        }
        return try LANCredentialStore(
            directory: container.appendingPathComponent("LANServer", isDirectory: true))
    }

    /// Load the persisted credential, minting and persisting one on first use.
    public func loadOrCreate() -> LANCredential {
        if let token = try? String(contentsOf: fileURL, encoding: .utf8),
           !token.isEmpty {
            return LANCredential(token: token)
        }
        let credential = LANCredential.generate()
        try? credential.token.write(to: fileURL, atomically: true, encoding: .utf8)
        return credential
    }

    /// Replace the credential with a fresh one, invalidating all prior clients.
    @discardableResult
    public func regenerate() -> LANCredential {
        let credential = LANCredential.generate()
        try? credential.token.write(to: fileURL, atomically: true, encoding: .utf8)
        return credential
    }
}

extension Data {
    /// base64url without padding (RFC 4648 §5) — safe in headers and URLs.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
