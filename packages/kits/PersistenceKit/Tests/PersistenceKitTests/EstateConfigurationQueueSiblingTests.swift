// EstateConfigurationQueueSiblingTests.swift
//
// Tests for EstateConfiguration.queueSibling(filename:) — ADR-021 T3.
//
// Coverage:
//   1. SQLite estate: sibling is at <estate-dir>/<estate-stem>.<filename>,
//      same busyTimeout, encryptionConfig carried over (mode, keyIdentifier),
//      sibling estateID differs from parent, two calls produce equal configs
//      (determinism).
//   2. Cross-estate isolation: two distinct estate DB files in the SAME
//      directory produce DIFFERENT sibling paths.
//   3. InMemory estate: sibling is InMemory, deterministic sibling ID.
//   4. PostgreSQL estate: sibling throws StorageError.featureGated (deferred path),
//      never returns a silent wrong config.
//   5. Determinism: repeated calls on the same input return equal configs.

import Testing
import Foundation
import PersistenceKit

struct EstateConfigurationQueueSiblingTests {

    // ──────────────────────────────────────────────────────────────────────
    // SQLite backend
    // ──────────────────────────────────────────────────────────────────────

    /// SQLite sibling lands in the same directory as the estate DB, with the
    /// sibling filename derived from the estate's own file stem + the requested
    /// filename (`<stem>.<filename>`). This isolates estates sharing a directory.
    @Test func sqliteSiblingPathIsInSameDirectory() throws {
        let dir = URL(fileURLWithPath: "/tmp/estates")
        let estateURL = dir.appendingPathComponent("estate.sqlite")
        let config = EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: estateURL)
        )

        let sibling = try config.queueSibling(filename: "queue.sqlite")

        guard case let .sqlite(url, _) = sibling.backend else {
            Issue.record("Expected .sqlite backend on sibling, got \(sibling.backend)")
            return
        }
        // Same directory as the estate. Compare standardised paths so trailing-
        // slash differences between URL construction paths don't cause spurious
        // failures (URL(fileURLWithPath:) vs deletingLastPathComponent differ on
        // trailing slash on macOS).
        let siblingDir = url.deletingLastPathComponent().standardizedFileURL.path
        let expectedDir = dir.standardizedFileURL.path
        #expect(siblingDir == expectedDir)
        // Sibling filename is <estate-stem>.<filename> — NOT the bare filename.
        // Estate stem "estate" + filename "queue.sqlite" → "estate.queue.sqlite".
        #expect(url.lastPathComponent == "estate.queue.sqlite")
    }

    /// Two distinct estate DB files in the SAME directory produce DIFFERENT
    /// sibling paths — the core ADR-021 Decision 7 isolation invariant.
    /// Before this fix both derived the same `<dir>/queue.sqlite`, enabling
    /// cross-estate corpus disclosure. After the fix each estate's queue is
    /// at `<dir>/<estate-stem>.queue.sqlite`, which is unique per estate.
    @Test func twoEstatesInSameDirectoryGetDifferentSiblingPaths() throws {
        let dir = URL(fileURLWithPath: "/tmp/shared-estates")
        let uuidA = UUID()
        let uuidB = UUID()
        let estateA = EstateConfiguration(
            estateID: uuidA,
            backend: .sqlite(url: dir.appendingPathComponent("\(uuidA.uuidString).sqlite"))
        )
        let estateB = EstateConfiguration(
            estateID: uuidB,
            backend: .sqlite(url: dir.appendingPathComponent("\(uuidB.uuidString).sqlite"))
        )

        let siblingA = try estateA.queueSibling(filename: "queue.sqlite")
        let siblingB = try estateB.queueSibling(filename: "queue.sqlite")

        guard case let .sqlite(urlA, _) = siblingA.backend,
              case let .sqlite(urlB, _) = siblingB.backend else {
            Issue.record("Expected .sqlite backend on both siblings")
            return
        }
        // Sibling paths must differ — different estates, same directory.
        #expect(urlA != urlB, "Two estates in the same dir must produce different queue sibling paths")
        // Both siblings must still be IN the same parent directory.
        let dirA = urlA.deletingLastPathComponent().standardizedFileURL.path
        let dirB = urlB.deletingLastPathComponent().standardizedFileURL.path
        let expectedDir = dir.standardizedFileURL.path
        #expect(dirA == expectedDir)
        #expect(dirB == expectedDir)
    }

    /// The same estate DB produces the same sibling path across repeated calls
    /// (all processes that open the same estate share one queue file).
    @Test func sameEstateSameSiblingPath() throws {
        let estateURL = URL(fileURLWithPath: "/tmp/estates/shared-estate.sqlite")
        let estateID = UUID()
        let config = EstateConfiguration(estateID: estateID, backend: .sqlite(url: estateURL))

        let first  = try config.queueSibling(filename: "queue.sqlite")
        let second = try config.queueSibling(filename: "queue.sqlite")

        guard case let .sqlite(url1, _) = first.backend,
              case let .sqlite(url2, _) = second.backend else {
            Issue.record("Expected .sqlite backends")
            return
        }
        #expect(url1 == url2, "Same estate must produce identical sibling paths across calls")
    }

    /// `busyTimeout` from the estate config is preserved on the sibling.
    @Test func sqliteSiblingPreservesBusyTimeout() throws {
        let estateURL = URL(fileURLWithPath: "/tmp/estates/estate.sqlite")
        let config = EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: estateURL, busyTimeout: 12.5)
        )

        let sibling = try config.queueSibling(filename: "queue.sqlite")

        guard case let .sqlite(_, busyTimeout) = sibling.backend else {
            Issue.record("Expected .sqlite backend on sibling")
            return
        }
        #expect(busyTimeout == 12.5)
    }

    /// Encryption config is carried over verbatim to the sibling — mode,
    /// key identifier, and (package-visible) key bytes are the same object.
    ///
    /// This is the core ADR-021 Decision 7 invariant: the queue DB uses the
    /// same cipher key as the estate so QueueKit can open it without
    /// additional key distribution.
    @Test func sqliteSiblingCarriesEncryptionConfig() throws {
        let estateURL = URL(fileURLWithPath: "/tmp/estates/estate.sqlite")
        // Construct an estate with row-encryption (non-plaintext, so we can
        // verify the key and identifier are carried over, not regenerated).
        let encryption = EstateEncryptionConfig(.rowEncryption)
        let config = EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: estateURL),
            encryptionConfig: encryption
        )

        let sibling = try config.queueSibling(filename: "queue.sqlite")

        // Mode must match.
        #expect(sibling.encryptionConfig.mode == .rowEncryption)
        // Key identifier must be the same string (same key, not a re-mint).
        #expect(sibling.encryptionConfig.keyIdentifier == encryption.keyIdentifier)
        // The package-scoped key bytes must be the same object reference, which
        // proves no new key was generated — the config was copied, not rebuilt.
        #expect(sibling.encryptionConfig.key == encryption.key)
    }

    /// The sibling's estateID is distinct from the parent's estateID.
    @Test func sqliteSiblingEstateIDDiffersFromParent() throws {
        let parentID = UUID()
        let config = EstateConfiguration(
            estateID: parentID,
            backend: .sqlite(url: URL(fileURLWithPath: "/tmp/e/estate.sqlite"))
        )
        let sibling = try config.queueSibling(filename: "queue.sqlite")
        #expect(sibling.estateID != parentID)
    }

    /// Two calls with the same input produce equal sibling configurations
    /// (deterministic estate-id and path, no UUID() random minting).
    @Test func sqliteSiblingIsDeterministic() throws {
        let parentID = UUID()
        let config = EstateConfiguration(
            estateID: parentID,
            backend: .sqlite(url: URL(fileURLWithPath: "/tmp/e/estate.sqlite"))
        )
        let first  = try config.queueSibling(filename: "queue.sqlite")
        let second = try config.queueSibling(filename: "queue.sqlite")

        #expect(first.estateID == second.estateID)
        guard case let .sqlite(url1, bt1) = first.backend,
              case let .sqlite(url2, bt2) = second.backend else {
            Issue.record("Expected .sqlite on both calls")
            return
        }
        #expect(url1 == url2)
        #expect(bt1 == bt2)
    }

    // ──────────────────────────────────────────────────────────────────────
    // InMemory backend
    // ──────────────────────────────────────────────────────────────────────

    /// An InMemory estate produces an InMemory sibling (ephemeral alongside
    /// the ephemeral estate, correct for tests and transient sessions).
    @Test func inMemorySiblingIsInMemory() throws {
        let config = EstateConfiguration(
            estateID: UUID(),
            backend: .inMemory
        )
        let sibling = try config.queueSibling(filename: "queue.sqlite")
        guard case .inMemory = sibling.backend else {
            Issue.record("Expected .inMemory backend on sibling, got \(sibling.backend)")
            return
        }
    }

    /// InMemory sibling estateID is distinct from the parent's estateID.
    @Test func inMemorySiblingEstateIDDiffersFromParent() throws {
        let parentID = UUID()
        let config = EstateConfiguration(estateID: parentID, backend: .inMemory)
        let sibling = try config.queueSibling(filename: "queue.sqlite")
        #expect(sibling.estateID != parentID)
    }

    /// InMemory sibling is deterministic across two calls.
    @Test func inMemorySiblingIsDeterministic() throws {
        let parentID = UUID()
        let config = EstateConfiguration(estateID: parentID, backend: .inMemory)
        let first  = try config.queueSibling(filename: "queue.sqlite")
        let second = try config.queueSibling(filename: "queue.sqlite")
        #expect(first.estateID == second.estateID)
    }

    // ──────────────────────────────────────────────────────────────────────
    // PostgreSQL backend — deferred, must fail loud
    // ──────────────────────────────────────────────────────────────────────

    /// The PostgreSQL branch is deferred per ADR-021 SQLite-first sequencing.
    /// Calling `queueSibling` on a PostgreSQL estate must throw
    /// `StorageError.featureGated`, never silently return a wrong config.
    @Test func postgresqlSiblingThrowsFeatureGated() throws {
        let config = EstateConfiguration(
            estateID: UUID(),
            backend: .postgresql(connectionString: "postgresql://localhost/test")
        )
        #expect(throws: StorageError.self) {
            _ = try config.queueSibling(filename: "queue.sqlite")
        }
        // Narrower check: verify it is specifically featureGated.
        do {
            _ = try config.queueSibling(filename: "queue.sqlite")
            Issue.record("Expected StorageError.featureGated to be thrown")
        } catch StorageError.featureGated {
            // Correct — the deferred branch fails loud.
        } catch {
            Issue.record("Expected featureGated, got \(error)")
        }
    }

    // ──────────────────────────────────────────────────────────────────────
    // Determinism: different filenames produce different sibling IDs
    // ──────────────────────────────────────────────────────────────────────

    /// Two different filenames applied to the same parent produce different
    /// sibling estate IDs, ensuring each named sibling is distinct.
    @Test func differentFilenamesProduceDifferentIDs() throws {
        let parentID = UUID()
        let config = EstateConfiguration(
            estateID: parentID,
            backend: .sqlite(url: URL(fileURLWithPath: "/tmp/e/estate.sqlite"))
        )
        let q = try config.queueSibling(filename: "queue.sqlite")
        let d = try config.queueSibling(filename: "drain.sqlite")
        #expect(q.estateID != d.estateID)
    }
}
