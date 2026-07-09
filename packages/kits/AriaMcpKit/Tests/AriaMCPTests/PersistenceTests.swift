import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite

/// Persistence behaviour tests for the ARIA_MCP SQLite backend.
///
/// Covers the two config-behaviour branches (absent env var → in-memory;
/// present env var → SQLite) at the storage-construction level, and
/// exercises the full GLK-layer round-trip over a real SQLite file:
///
///   1. Open a SQLiteStorage at a temp path, seed a GeniusLocusKit estate.
///   2. Capture a drawer through the GLK verb surface.
///   3. Close the kit; discard the handle.
///   4. Open a FRESH kit and a FRESH storage against the SAME path.
///   5. Verify the drawer is still present via recall.
///
/// This mirrors the Rust v2a-server's persistence_tests pattern:
/// `moot_file_memory` → teardown → fresh server same path →
/// estate recall finds the drawer.
///
/// Seam note: the ToolDispatcher / ARIA_MCPDispatcher construction seam
/// prevents a full dispatcher-layer round-trip without refactoring beyond
/// mission scope (the dispatcher takes a pre-opened handle; there is no
/// "open a new dispatcher from a path" helper in the library). The round-
/// trip is therefore at the GLK layer, which is the actual persistence
/// seam. The dispatcher is exercised for config-behaviour tests and for
/// the existing ServerTests suite. See the SEAM_GAP discovery in the
/// mission completion report.
///
/// `.serialized`: tests interact with the filesystem; keep them sequential
/// to avoid temp-file collisions and to preserve sqlite WAL state.
@Suite("Persistence", .serialized)
struct PersistenceTests {

    // MARK: - Helpers

    /// A fresh temp-dir path for each test. The directory is created;
    /// the database file itself is created by SQLiteStorage on first open.
    private func tempDBURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistenceTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("test.sqlite")
    }

    /// Open a SQLiteStorage-backed GLK estate at `url`. Returns the kit and
    /// handle. Follows the same create-then-open pattern as AriaMCPMain so
    /// the test exercises exactly the production code path.
    private func openSQLiteEstate(url: URL) async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "persistence-tests")
        let configuration = EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: url, busyTimeout: 5.0)
        )
        // SQLiteStorage init is throwing; an unusable path surfaces here.
        let storage = try SQLiteStorage(configuration: configuration)
        // Estate.create opens the schema idempotently (upserts on the
        // manifest table) and stamps the owner identifier. Safe to call
        // on a fresh file and on an existing file.
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
        return (kit, handle)
    }

    // MARK: - Config behaviour: in-memory (env var absent / empty)

    /// Absent env var → InMemoryStorage opens and accepts a drawer.
    /// This is the pre-persistence code path; verify it remains intact.
    @Test func testInMemoryEstateAcceptsCapture() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "persistence-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())

        let frame = CaptureFrame(
            content: "in-memory config behaviour test",
            channel: .typed,
            room: "persistence-tests",
            latticeAnchor: .udc("000"),
            addedBy: "persistence-tests",
            embeddingModelID: "test-model-v1"
        )
        let drawer = try await kit.capture(handle, frame)
        #expect(drawer.content == "in-memory config behaviour test")
    }

    // MARK: - Config behaviour: SQLite storage construction

    /// Present env var → SQLiteStorage can be constructed at a valid path.
    /// This verifies the storage-constructor leg without a full round-trip.
    @Test func testSQLiteStorageConstructsAtValidPath() throws {
        let url = try tempDBURL()
        let configuration = EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: url, busyTimeout: 5.0)
        )
        // If the path is valid, construction succeeds without throwing.
        #expect(throws: Never.self) {
            _ = try SQLiteStorage(configuration: configuration)
        }
        // The SQLite file is created on first schema open, which happens
        // in Estate.create/open. Construction alone does not necessarily
        // create the file — that is SQLiteStorage's documented behaviour.
        // No assertion on file existence here; the round-trip test covers
        // actual persistence.
    }

    // MARK: - Persistence round-trip (the key test)

    /// Full GLK-layer round-trip over SQLite:
    ///   open → capture → close → reopen → recall finds drawer.
    ///
    /// This is the Swift counterpart of the Rust v2a-server's
    /// persistence_tests.rs round-trip test.
    @Test func testSQLiteEstateRoundTrip() async throws {
        let dbURL = try tempDBURL()
        let capturedContent = "persistence-round-trip-\(UUID().uuidString)"

        // ── Phase 1: open, capture, close ──────────────────────────────────

        do {
            let (kit, handle) = try await openSQLiteEstate(url: dbURL)

            let frame = CaptureFrame(
                content: capturedContent,
                channel: .typed,
                room: "persistence-tests",
                latticeAnchor: .udc("000"),
                addedBy: "persistence-tests",
                embeddingModelID: "test-model-v1"
            )
            let drawer = try await kit.capture(handle, frame)
            // Verify the drawer was captured before teardown.
            #expect(drawer.content == capturedContent)
            let names = try await kit.resolveNodeNames(handle, parentNodeIds: [drawer.parentNodeId])
            #expect(names[drawer.parentNodeId]?.room == "persistence-tests")

            // Close the estate through the kit; the storage backend is
            // dropped when `kit` and `handle` go out of scope at end of
            // this `do` block. SQLite WAL frames are flushed on
            // SQLiteConnection.close(), which SQLiteBackend.close() calls.
            try await kit.close(handle)
        }

        // ── Phase 2: fresh kit, same path, recall finds the drawer ─────────

        do {
            let (kit2, handle2) = try await openSQLiteEstate(url: dbURL)

            // .full hydration is required to read the content blob — .structured
            // returns only bitmap + structured fields (no blob reads), so content
            // would be empty and the assertion would fail. This is the correct
            // hydration level for a round-trip content verification test.
            let recallFrame = RecallFrame(
                filterChain: [.unconfirmed],
                hydrationLevel: .full,
                limit: nil,
                ordering: .byCaptureTimeDesc
            )
            let drawers = try await kit2.recall(handle2, recallFrame)

            // The captured drawer must survive across the lifecycle boundary.
            let found = drawers.first(where: { $0.content == capturedContent })
            #expect(found != nil, "drawer written in phase 1 not found after reopen")
            if let found {
                let names2 = try await kit2.resolveNodeNames(handle2, parentNodeIds: [found.parentNodeId])
                #expect(names2[found.parentNodeId]?.room == "persistence-tests")
            }

            try await kit2.close(handle2)
        }
    }

    // MARK: - Parent directory auto-creation

    /// SQLiteStorage succeeds when parent directories do not yet exist,
    /// provided the caller has created them (as AriaMCPMain does via
    /// FileManager.createDirectory). This test validates the creation
    /// helper pattern the production startup uses.
    @Test func testParentDirectoryCreationPattern() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistenceTests-mkdir-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("nested", isDirectory: true)
        let dbURL = base.appendingPathComponent("estate.sqlite")

        // Simulate what AriaMCPMain does: create parent dirs, then
        // construct SQLiteStorage.
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let configuration = EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: dbURL, busyTimeout: 5.0)
        )
        #expect(throws: Never.self) {
            _ = try SQLiteStorage(configuration: configuration)
        }
    }

    // MARK: - Bare-filename edge case (Rust parity)

    /// A bare filename (no directory component) needs no parent-directory
    /// creation — the startup guard skips createDirectory entirely, exact
    /// parity with the Rust server's empty-parent guard. SQLiteStorage must
    /// open such a path directly. Serialized: resolves against the process
    /// working directory.
    @Test func testBareFilenameNeedsNoParentCreation() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistenceTests-bare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let saved = FileManager.default.currentDirectoryPath
        defer { _ = FileManager.default.changeCurrentDirectoryPath(saved) }
        #expect(FileManager.default.changeCurrentDirectoryPath(dir.path))

        // Mirror the startup guard: a bare name contains no "/", so no
        // directory is created — the storage opens against the cwd.
        let bareName = "estate.sqlite"
        #expect(!bareName.contains("/"))
        let configuration = EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: URL(fileURLWithPath: bareName), busyTimeout: 5.0)
        )
        #expect(throws: Never.self) {
            _ = try SQLiteStorage(configuration: configuration)
        }
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(bareName).path))
    }
}
