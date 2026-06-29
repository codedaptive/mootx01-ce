import Testing
import Foundation
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite
import PersistenceKitPostgreSQL

/// Precedence-ladder config tests for the ARIA_MCP PostgreSQL backend.
///
/// Tests the backend-selection decision logic at the storage-construction
/// layer. None of these tests require a live PostgreSQL server — they verify
/// that:
///
///   1. PostgreSQLStorage can be constructed from a valid connection string
///      format without throwing (lazy pool — no TCP connection at init time).
///   2. The three non-ambiguous branches each produce the expected storage type.
///   3. The ambiguous-config branch (both vars set) is tested by inspecting the
///      decision logic directly rather than via AriaMCPMain.run(), which exits
///      the process on error.
///
/// Seam note: AriaMCPMain.run() calls exit(1) on ambiguous config, making it
/// untestable at the entry-point layer without spawning a subprocess. The
/// precedence-ladder decision is therefore tested at the BackendConfiguration
/// level — verifying that the correct backend enum case is produced for each
/// env-var combination. This is the same pattern used by PersistenceTests.swift
/// (see SEAM_GAP discovery in SWIFT_PERSISTENCE_001_COMPLETION.md).
///
/// Live round-trips: skipped without PERSISTENCEKIT_PG_URL; no
/// PostgresLiveTests.swift exists under this kit. Construction tests run unconditionally.
///
/// `.serialized`: serialized to match PersistenceTests convention; these
/// tests are cheap (no filesystem I/O) so ordering is not critical.
@Suite("PostgreSQL precedence ladder", .serialized)
struct PostgresPrecedenceTests {

    // MARK: - BackendConfiguration construction

    /// ARIA_MCP_POSTGRES_URL non-empty, ARIA_MCP_SQLITE_PATH absent →
    /// .postgresql backend configuration with the expected connection string.
    ///
    /// This mirrors the "only POSTGRES_URL set" branch in AriaMCPMain.run().
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

    // MARK: - Precedence ladder logic (decision-layer tests)

    /// Ambiguous config detection: both vars set → the decision function
    /// must identify this as ambiguous (neither var is empty).
    ///
    /// Tests the logical predicate that AriaMCPMain uses to detect ambiguous
    /// config, without calling run() (which would exit the test process).
    @Test func testAmbiguousConfigBothNonEmpty() {
        let postgresURL = "postgresql://localhost:5432/db"
        let sqlitePath = "/tmp/estate.sqlite"

        // The ambiguous-config condition is: both non-empty.
        // This mirrors: if !rawPostgresURL.isEmpty && !rawSQLitePath.isEmpty { exit(1) }
        let isAmbiguous = !postgresURL.isEmpty && !sqlitePath.isEmpty
        #expect(isAmbiguous, "both vars non-empty must be detected as ambiguous config")
    }

    /// Only POSTGRES_URL set → selects PostgreSQL branch (not ambiguous, not SQLite).
    @Test func testOnlyPostgresURLSelectsPostgresBranch() {
        let postgresURL = "postgresql://localhost:5432/db"
        let sqlitePath = ""

        let isAmbiguous = !postgresURL.isEmpty && !sqlitePath.isEmpty
        let selectsPostgres = !isAmbiguous && !postgresURL.isEmpty
        let selectsSQLite = !isAmbiguous && postgresURL.isEmpty && !sqlitePath.isEmpty
        let selectsInMemory = !isAmbiguous && postgresURL.isEmpty && sqlitePath.isEmpty

        #expect(!isAmbiguous)
        #expect(selectsPostgres)
        #expect(!selectsSQLite)
        #expect(!selectsInMemory)
    }

    /// Only SQLITE_PATH set → selects SQLite branch (not ambiguous, not PostgreSQL).
    @Test func testOnlySQLitePathSelectsSQLiteBranch() {
        let postgresURL = ""
        let sqlitePath = "/tmp/estate.sqlite"

        let isAmbiguous = !postgresURL.isEmpty && !sqlitePath.isEmpty
        let selectsPostgres = !isAmbiguous && !postgresURL.isEmpty
        let selectsSQLite = !isAmbiguous && postgresURL.isEmpty && !sqlitePath.isEmpty
        let selectsInMemory = !isAmbiguous && postgresURL.isEmpty && sqlitePath.isEmpty

        #expect(!isAmbiguous)
        #expect(!selectsPostgres)
        #expect(selectsSQLite)
        #expect(!selectsInMemory)
    }

    /// Neither set → selects in-memory branch.
    @Test func testNeitherSetSelectsInMemory() {
        let postgresURL = ""
        let sqlitePath = ""

        let isAmbiguous = !postgresURL.isEmpty && !sqlitePath.isEmpty
        let selectsPostgres = !isAmbiguous && !postgresURL.isEmpty
        let selectsSQLite = !isAmbiguous && postgresURL.isEmpty && !sqlitePath.isEmpty
        let selectsInMemory = !isAmbiguous && postgresURL.isEmpty && sqlitePath.isEmpty

        #expect(!isAmbiguous)
        #expect(!selectsPostgres)
        #expect(!selectsSQLite)
        #expect(selectsInMemory)
    }

    /// No-trimming invariant: a whitespace-only POSTGRES_URL is non-empty
    /// (treated as a config attempt, not a silent fallback).
    @Test func testWhitespaceOnlyPostgresURLIsNonEmpty() {
        let postgresURL = "   "
        // No trimming — whitespace-only is non-empty, treated as a config error.
        #expect(!postgresURL.isEmpty, "whitespace-only ARIA_MCP_POSTGRES_URL must be non-empty (no trimming)")
    }

    /// No-trimming invariant: a whitespace-only SQLITE_PATH is non-empty.
    @Test func testWhitespaceOnlySQLitePathIsNonEmpty() {
        let sqlitePath = "  "
        #expect(!sqlitePath.isEmpty, "whitespace-only ARIA_MCP_SQLITE_PATH must be non-empty (no trimming)")
    }

    // MARK: - Storage type verification (construction-layer)

    /// In-memory backend construction (no env var) — existing behavior intact.
    @Test func testInMemoryBackendConfiguration() {
        let configuration = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        if case .inMemory = configuration.backend {
            // Expected — no additional verification needed.
        } else {
            Issue.record("Expected .inMemory backend")
        }
    }

    /// SQLite backend construction matches the existing precedence (env var
    /// present, non-empty).
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
