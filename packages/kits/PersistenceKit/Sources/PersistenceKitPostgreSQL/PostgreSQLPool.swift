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
        let tls = try parseTLSMode(host: host)
        return PostgresConnection.Configuration(
            host: host,
            port: port,
            username: user,
            password: password,
            database: database.isEmpty ? "postgres" : database,
            tls: tls
        )
    }

    /// Resolve the TLS mode for a PostgreSQL connection from the
    /// `ARIA_MCP_POSTGRES_TLS` environment variable (SECFIX-WS2-PK F3 — CAND-029).
    ///
    /// | Value      | Behaviour                                                      |
    /// |---|---|
    /// | `disable`  | No TLS. Safe only for loopback / Unix-socket connections.      |
    /// | `require`  | TLS mandatory; refuse if the server does not offer it.         |
    /// | `prefer`   | TLS if offered; fall back to plaintext (default).              |
    /// | *(absent)* | Defaults to `prefer`.                                          |
    /// | *(unknown)*| Defaults to `prefer` (unknown ≠ `disable`; safe default).     |
    ///
    /// Loopback check: when the resolved host is `127.0.0.1`, `::1`, or
    /// `localhost` and the env var is absent, we still default to `prefer`
    /// (not `disable`). Callers that want plaintext on loopback must set
    /// `ARIA_MCP_POSTGRES_TLS=disable` explicitly.
    private func parseTLSMode(host: String) throws -> PostgresConnection.Configuration.TLS {
        let raw = ProcessInfo.processInfo.environment["ARIA_MCP_POSTGRES_TLS"]?
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        switch raw {
        case "disable":
            return .disable
        case "require":
            let context = try makeTLSContext()
            return .require(context)
        default:
            // "prefer" or absent or unrecognised → safe default (prefer).
            let context = try makeTLSContext()
            return .prefer(context)
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
