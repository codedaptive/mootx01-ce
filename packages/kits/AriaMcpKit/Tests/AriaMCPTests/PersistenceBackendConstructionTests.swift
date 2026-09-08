import Testing
import Foundation
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite
import PersistenceKitPostgreSQL

/// Backend construction tests for the three PersistenceKit backends aria-mcp
/// opens (SQLite, PostgreSQL, in-memory). None require a live PostgreSQL
/// server: they verify that each `BackendConfiguration` case carries the
/// expected fields and defaults, and that `PostgreSQLStorage` can be
/// constructed from a connection string without throwing (lazy pool — no TCP
/// connection at init time), which is what lets aria-mcp fail at
/// `Estate.create` for an unreachable server rather than at construction.
///
/// Which backend a run uses is decided by the estate catalog record, not
/// here: `EstateBackend` and its decoding are pinned by GeniusLocusKit's
/// `EstateCatalogTests`.
///
/// Live round-trips: skipped without PERSISTENCEKIT_PG_URL (see
/// InMemorySemanticRecallTests part D). Construction tests run unconditionally.
///
/// `.serialized`: serialized to match PersistenceTests convention; these
/// tests are cheap (no filesystem I/O) so ordering is not critical.
@Suite("Persistence backend construction", .serialized)
struct PersistenceBackendConstructionTests {

    // MARK: - BackendConfiguration construction

    /// A PostgreSQL record's connection string becomes a .postgresql backend
    /// configuration with PersistenceKit's pool defaults, as AriaMCPMain's
    /// PostgreSQL branch builds it.
    @Test func testPostgresBackendConfigurationUsesURL() {
        let url = "postgresql://localhost:5432/testdb"
        let configuration = EstateConfiguration(
            estateID: UUID(),
            backend: .postgresql(connectionString: url)
        )

        // Verify the backend case is .postgresql with the expected fields.
        guard case let .postgresql(connStr, poolSize, connectionTimeout, idleTimeout) = configuration.backend else {
            Issue.record("Expected .postgresql backend, got something else")
            return
        }
        #expect(connStr == url)
        // Verify defaults match PersistenceKit's BackendConfiguration.postgresql defaults:
        // poolSize: 10, connectionTimeout: 5.0s, idleTimeout: 300.0s
        #expect(poolSize == 10, "default poolSize must be 10 (PersistenceKit default)")
        #expect(connectionTimeout == 5.0, "default connectionTimeout must be 5.0s (PersistenceKit default)")
        #expect(idleTimeout == 300.0, "default idleTimeout must be 300.0s (PersistenceKit default)")
    }

    /// PostgreSQLStorage.init is non-throwing (lazy pool).
    ///
    /// Construction from a syntactically valid connection string must succeed
    /// without opening a TCP connection. No live server required.
    @Test func testPostgreSQLStorageConstructionIsNonThrowing() {
        let configuration = EstateConfiguration(
            estateID: UUID(),
            backend: .postgresql(connectionString: "postgresql://localhost:5432/aria_mcp_test")
        )
        // PostgreSQLStorage.init is non-throwing by design — the pool is lazy.
        // If this test fails to compile, the init signature changed.
        let storage = PostgreSQLStorage(configuration: configuration)
        // Verify the configuration round-trips correctly through the storage.
        if case let .postgresql(connStr, _, _, _) = storage.configuration.backend {
            #expect(connStr == "postgresql://localhost:5432/aria_mcp_test")
        } else {
            Issue.record("PostgreSQLStorage.configuration.backend must be .postgresql")
        }
    }

    // MARK: - Storage type verification (construction-layer)

    /// In-memory backend construction (`--in-memory`).
    @Test func testInMemoryBackendConfiguration() {
        let configuration = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        if case .inMemory = configuration.backend {
            // Expected — no additional verification needed.
        } else {
            Issue.record("Expected .inMemory backend")
        }
    }

    /// SQLite backend construction from a record's database URL.
    @Test func testSQLiteBackendConfigurationUsesPath() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PgPrecedenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let configuration = EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: dbURL, busyTimeout: 5.0)
        )
        if case let .sqlite(url, busyTimeout) = configuration.backend {
            #expect(url == dbURL)
            #expect(busyTimeout == 5.0)
        } else {
            Issue.record("Expected .sqlite backend")
        }
    }
}
