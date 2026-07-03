// PostgreSQLPool.swift
//
// Per-estate PostgreSQL connection pool. PersistenceKit-owned, fixed
// size, configured via EstateConfiguration per Q6.

import Foundation
import PersistenceKit
@preconcurrency import PostgresNIO
import NIOPosix
import NIOSSL

actor PostgreSQLPool {
    private let connectionString: String
    private let poolSize: Int
    private let connectionTimeout: TimeInterval
    private let idleTimeout: TimeInterval
    private let searchPath: String?
    private let eventLoopGroup: any EventLoopGroup

    private var available: [PostgresConnection] = []
    private var inUse: Int = 0
    private var waiters: [CheckedContinuation<PostgresConnection, Error>] = []
    private var isClosed = false

    init(connectionString: String,
         poolSize: Int,
         connectionTimeout: TimeInterval,
         idleTimeout: TimeInterval,
         searchPath: String? = nil) {
        self.connectionString = connectionString
        self.poolSize = poolSize
        self.connectionTimeout = connectionTimeout
        self.idleTimeout = idleTimeout
        self.searchPath = searchPath
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    func acquire() async throws -> PostgresConnection {
        if isClosed {
            throw StorageError.backendUnavailable(reason: "pool closed")
        }
        if let conn = available.popLast() {
            inUse += 1
            return conn
        }
        if inUse < poolSize {
            inUse += 1
            do {
                return try await openConnection()
            } catch {
                inUse -= 1
                throw error
            }
        }
        // Wait for a connection to free up.
        return try await withCheckedThrowingContinuation { cont in
            waiters.append(cont)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(self?.connectionTimeout ?? 5.0) * 1_000_000_000)
                await self?.timeoutWaiter(cont)
            }
        }
    }

    func release(_ connection: PostgresConnection) {
        if isClosed {
            Task { try? await connection.close() }
            inUse -= 1
            return
        }
        if !waiters.isEmpty {
            let w = waiters.removeFirst()
            w.resume(returning: connection)
            return
        }
        available.append(connection)
        inUse -= 1
    }

    func close() async {
        isClosed = true
        for w in waiters {
            w.resume(throwing: StorageError.backendUnavailable(reason: "pool closing"))
        }
        waiters.removeAll()
        for conn in available {
            try? await conn.close()
        }
        available.removeAll()
        try? await eventLoopGroup.shutdownGracefully()
    }

    private func timeoutWaiter(_ cont: CheckedContinuation<PostgresConnection, Error>) {
        if let idx = waiters.firstIndex(where: { withUnsafePointer(to: $0) { p1 in
            withUnsafePointer(to: cont) { p2 in p1 == p2 } } }) {
            waiters.remove(at: idx)
            cont.resume(throwing: StorageError.poolExhausted(timeout: connectionTimeout))
        }
    }

    private func openConnection() async throws -> PostgresConnection {
        let config = try parseConnectionString(connectionString)
        do {
            let conn = try await PostgresConnection.connect(
                on: eventLoopGroup.next(),
                configuration: config,
                id: Int.random(in: 0..<Int.max),
                logger: Logger(label: "storagekit.postgres")
            )
            // Pin this connection to the estate's schema (idempotent create),
            // keeping `public` on the path for shared extensions.
            if let sp = searchPath {
                // Extended-protocol query (executeSimple) takes one statement
                // at a time, so issue the two separately; close on failure so
                // a half-set-up connection never deinits unclosed.
                let lg = Logger(label: "storagekit.postgres")
                do {
                    try await conn.executeSimple("CREATE SCHEMA IF NOT EXISTS \"\(sp)\"", logger: lg)
                    try await conn.executeSimple("SET search_path TO \"\(sp)\", public", logger: lg)
                } catch {
                    try? await conn.close()
                    throw error
                }
            }
            return conn
        } catch {
            throw StorageError.backendError(underlying: "PostgreSQL connect failed: \(error)")
        }
    }

    private func parseConnectionString(_ s: String) throws -> PostgresConnection.Configuration {
        // Accepts standard postgres:// URLs.
        guard let url = URL(string: s),
              url.scheme == "postgres" || url.scheme == "postgresql" else {
            throw StorageError.invalidQuery(detail: "invalid connection string: \(s)")
        }
        let host = url.host ?? "localhost"
        let port = url.port ?? 5432
        let user = url.user ?? "postgres"
        let password = url.password
        let database = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let dsnSSLMode = Self.sslMode(from: url)
        let tls = try parseTLSMode(host: host, dsnSSLMode: dsnSSLMode)
        return PostgresConnection.Configuration(
            host: host,
            port: port,
            username: user,
            password: password,
            database: database.isEmpty ? "postgres" : database,
            tls: tls
        )
    }

    /// Resolve the TLS mode for a PostgreSQL connection from BOTH the DSN's
    /// `sslmode=` query parameter AND the `ARIA_MCP_POSTGRES_TLS` environment
    /// variable (SECFIX-C-PG-SWIFT-TLS-SSLMODE; parity with the Rust
    /// `postgres_tls::effective_sslmode` module).
    ///
    /// The effective mode is the STRONGER (`max`) of the two sources — the env
    /// var may RAISE security above the DSN but must never lower what the
    /// operator's DSN explicitly requested. Previously the DSN `sslmode` was
    /// ignored entirely, so `?sslmode=require` / `verify-ca` / `verify-full`
    /// could still open a plaintext connection — credential + estate-data
    /// disclosure over the wire. Mapping to PostgresNIO's three TLS cases
    /// (`.disable` / `.prefer` / `.require`; certificate/hostname verification
    /// lives in the NIOSSLContext, so verify-ca/verify-full both map to
    /// `.require`):
    ///
    /// | effective sslmode        | PostgresNIO TLS        |
    /// |---|---|
    /// | `disable`                | `.disable` (plaintext) |
    /// | `allow` / `prefer`       | `.prefer`              |
    /// | `require` / `verify-ca` / `verify-full` / unknown | `.require` (fail closed) |
    ///
    /// An UNKNOWN DSN sslmode is treated as require-TLS (fail closed), never as
    /// disable — a typo must not silently drop to plaintext. An absent DSN
    /// sslmode + absent env var defaults to `.prefer` (the libpq default).
    private func parseTLSMode(host: String, dsnSSLMode: String?) throws
        -> PostgresConnection.Configuration.TLS
    {
        _ = host // reserved for future hostname-specific TLS policy
        let envValue = ProcessInfo.processInfo.environment["ARIA_MCP_POSTGRES_TLS"]?
            .trimmingCharacters(in: .whitespaces)
        switch Self.effectiveTLSDecision(dsnSSLMode: dsnSSLMode, envValue: envValue) {
        case .disable:
            return .disable
        case .prefer:
            return .prefer(try makeTLSContext())
        case .require:
            return .require(try makeTLSContext())
        }
    }

    /// The three PostgresNIO TLS outcomes. Extracted so the security decision
    /// (max-of-DSN-and-env, fail-closed on unknown) is unit-testable without a
    /// live server or a NIOSSLContext.
    enum TLSDecision: Equatable { case disable, prefer, require }

    /// Pure security decision: the stronger of the DSN `sslmode` and the
    /// `ARIA_MCP_POSTGRES_TLS` env value, mapped to a PostgresNIO outcome.
    /// The env may RAISE but never LOWER the DSN's requirement; an unknown DSN
    /// value fails closed to `.require`. Rust twin: `postgres_tls::effective_sslmode`.
    static func effectiveTLSDecision(dsnSSLMode: String?, envValue: String?) -> TLSDecision {
        let envMode = TLSModeRank(envValue) ?? .prefer
        let effective: TLSModeRank
        if let dsnSSLMode {
            effective = max(TLSModeRank(dsnSSLMode) ?? .unknownRequireTLS, envMode)
        } else {
            effective = envMode
        }
        switch effective {
        case .disable: return .disable
        case .allow, .prefer: return .prefer
        case .require, .verifyCA, .verifyFull, .unknownRequireTLS: return .require
        }
    }

    /// Extract the `sslmode=` value from a `postgres://` URL's query, if present.
    private static func sslMode(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name.lowercased() == "sslmode" }?
            .value?
            .trimmingCharacters(in: .whitespaces)
    }

    /// Security ranking for libpq `sslmode` values (weakest → strongest),
    /// matching the Rust `SslModeRank`. `unknownRequireTLS` is the conservative
    /// bucket for an unrecognised DSN value — ranked above the real modes so a
    /// typo fails closed to require-TLS.
    private enum TLSModeRank: Int, Comparable {
        case disable = 0
        case allow = 1
        case prefer = 2
        case require = 3
        case verifyCA = 4
        case verifyFull = 5
        case unknownRequireTLS = 6

        init?(_ raw: String?) {
            guard let raw = raw?.lowercased(), !raw.isEmpty else { return nil }
            switch raw {
            case "disable": self = .disable
            case "allow": self = .allow
            case "prefer": self = .prefer
            case "require": self = .require
            case "verify-ca": self = .verifyCA
            case "verify-full": self = .verifyFull
            default: return nil
            }
        }

        static func < (lhs: TLSModeRank, rhs: TLSModeRank) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Build a default TLS context for outgoing PostgreSQL connections.
    ///
    /// Uses `TLSConfiguration.makeClientConfiguration()` — verifies the
    /// server certificate against the platform trust store (Security.framework
    /// on macOS/iOS, OpenSSL on Linux). For environments with custom CAs, the
    /// caller can extend this by adding trust roots to the `TLSConfiguration`
    /// before constructing the context.
    private func makeTLSContext() throws -> NIOSSLContext {
        let tlsConfig = TLSConfiguration.makeClientConfiguration()
        return try NIOSSLContext(configuration: tlsConfig)
    }
}


import Logging
