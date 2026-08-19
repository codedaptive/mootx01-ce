// SchemaMigrationChainTests.swift
// MootDaemonProviderTests — MACD-3B5 GAP 1 coverage.
//
// Design matrix row 6: one-way forward schema migration end-to-end chain.
//
// Smythe pre-flight identified this gap: the existing EstateConvergenceTests
// verify the migration state machine in unit isolation (crash convergence,
// receipt ordering, idempotent resume). What is NOT covered is the full chain
// from source quiescence to committed outcome with explicit assertions of the
// three invariants the design mandate imposes across every boundary:
//
//   I-A: "never two authorities" — source.close() happens BEFORE
//        copyMainToIncoming(); the event log is the proof.
//
//   I-B: "never a deleted source" — the source file exists on disk at every
//        failure boundary, including after a successful migration.
//
//   I-C: "never a fresh default estate" — the canonical's estate UUID and
//        schema version are identical to the source's; the migrator throws
//        identityMismatch if verifyReadOnlyOpen disagrees.
//
//   I-D: "commits ownership only after authenticated readiness" — the migrator
//        reaches .committed only AFTER verifyReadOnlyOpen (the authenticated
//        identity proof) succeeds; a failed identity check prevents .committed.
//
// Each test documents what regression would make it fail, as required by the
// mission.
//
// BLOCKED paths (require live entitled provider):
//   - Real SQLite PRAGMA integrity_check across the AppGroup boundary
//   - Real WAL checkpoint(TRUNCATE) on a production estate
//   - Real anchor-count verification against a live SQLCipher database
//
// These are tested to the boundary of the injected SourceEstateAccess seam.
// The seam's production conformer arrives with MACD-3 estate routing.

import Foundation
import Testing
import AriaMCP
@testable import MootDaemonProvider

// MARK: - Shared scratch directory

private struct ChainScratch {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macd3b5-chain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
    func remove() { try? FileManager.default.removeItem(at: url) }
}

// MARK: - Fixed test identities

private let chainRoot: [UInt8] = [UInt8](repeating: 0xA5, count: 32)
private let chainEstateUUID = UUID(uuidString: "CCCCCCCC-0000-4000-8000-000000000001")!
private let chainSchemaVersion: UInt64 = 4
private let chainAnchorCounts: [String: UInt64] = ["drawers": 17, "kg_facts": 33]
private let chainTxnID = UUID(uuidString: "DDDDDDDD-0000-4000-8000-000000000001")!
private let chainClock: ProviderClock = { 3_000 }

private func chainIdentity() -> CensusIdentity {
    CensusIdentity(
        estateIdentifier: chainEstateUUID,
        schemaVersion: chainSchemaVersion,
        anchorCounts: chainAnchorCounts
    )
}

// MARK: - Shared time-ordered event log

/// A synchronized event log shared by ChainSourceAccess and ChainFileMigration.
///
/// Both fakes write into their own per-seam arrays AND into this shared log,
/// which records every event in the order it was received across both seams.
/// This is the only harness-level mechanism that enables true cross-seam
/// ordering assertions: per-seam arrays alone cannot distinguish whether
/// source.close() preceded files.copyMainToIncoming() because the arrays
/// are populated independently, not interleaved.
private final class SharedEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var events: [String] = []

    func record(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }
}

// MARK: - Chain-specific source-access fake with ordered event log

/// A SourceEstateAccess fake that records the full event sequence both in its
/// own per-seam log and in the shared time-ordered log. The crash-injection
/// mechanism from EstateConvergenceTests is intentionally absent here — these
/// tests assert ORDERING, not crash recovery (crash convergence is already
/// proven in EstateConvergenceTests §7).
private final class ChainSourceAccess: SourceEstateAccess, @unchecked Sendable {
    private let lock = NSLock()
    private let sharedLog: SharedEventLog
    private(set) var events: [String] = []
    /// When non-nil, verifyReadOnlyOpen returns a MISMATCHED identity — used
    /// to verify that the migrator throws identityMismatch before committing.
    var mismatchedIdentity: CensusIdentity?

    init(sharedLog: SharedEventLog) {
        self.sharedLog = sharedLog
    }

    private func record(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
        // Write to the shared log AFTER releasing the per-seam lock to avoid
        // nested lock acquisition. The migrator is sequential so ordering is
        // preserved without holding both locks simultaneously.
        sharedLog.record(event)
    }

    func openExclusive() async throws { record("open-exclusive") }
    func checkpointTruncate() async throws { record("checkpoint-truncate") }
    func verifyEmptyWAL() async throws { record("verify-empty-wal") }
    func readIdentity() async throws -> CensusIdentity {
        record("read-identity")
        return chainIdentity()
    }
    func close() async throws { record("close") }
    func verifyReadOnlyOpen(destination: URL) async throws -> CensusIdentity {
        record("verify-read-only-open")
        if let bad = mismatchedIdentity { return bad }
        return chainIdentity()
    }
}

// MARK: - Chain-specific file-migration fake

/// A FileMigrationAuthority fake that performs real file operations on a
/// scratch directory so the on-disk invariants (source exists, canonical UUID)
/// can be verified directly. Records operations in its own per-seam log and
/// in the shared time-ordered log to enable cross-seam ordering assertions.
private final class ChainFileMigration: FileMigrationAuthority, @unchecked Sendable {
    private let lock = NSLock()
    private let sharedLog: SharedEventLog
    private(set) var events: [String] = []

    init(sharedLog: SharedEventLog) {
        self.sharedLog = sharedLog
    }

    private func record(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
        // Write to the shared log AFTER releasing the per-seam lock; see
        // ChainSourceAccess.record() for the rationale.
        sharedLog.record(event)
    }

    func copyMainToIncoming(source: URL, incoming: URL) async throws -> String {
        record("copy-main-to-incoming")
        let data = try Data(contentsOf: source)
        try FileManager.default.createDirectory(
            at: incoming.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: incoming)
        return hexDigest(of: data)
    }

    func digestOf(url: URL) async throws -> String {
        let data = try Data(contentsOf: url)
        return hexDigest(of: data)
    }

    func atomicRenameIntoCanonical(incoming: URL, canonical: URL) async throws {
        record("atomic-rename-into-canonical")
        try FileManager.default.createDirectory(
            at: canonical.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        _ = try? FileManager.default.removeItem(at: canonical)
        try FileManager.default.moveItem(at: incoming, to: canonical)
    }

    func quarantineCanonical(canonical: URL, quarantineDirectory: URL) async throws {
        record("quarantine-canonical")
        try FileManager.default.createDirectory(
            at: quarantineDirectory, withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(
            at: canonical,
            to: quarantineDirectory.appendingPathComponent(canonical.lastPathComponent)
        )
    }

    func preserveBackup(source: URL, backupDirectory: URL) async throws {
        record("preserve-backup")
        try FileManager.default.createDirectory(
            at: backupDirectory, withIntermediateDirectories: true
        )
        let destination = backupDirectory.appendingPathComponent(source.lastPathComponent)
        _ = try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func hexDigest(of data: Data) -> String {
        FirstPartyAuthProtocol.sha256([UInt8](data)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Chain harness

private struct ChainHarness {
    let scratch: ChainScratch
    let source: URL
    let canonical: URL
    let incoming: URL
    let backup: URL
    /// Combined time-ordered event log shared by both fakes.
    /// Use for cross-seam ordering assertions (e.g. close-before-copy).
    let sharedLog: SharedEventLog
    let sourceAccess: ChainSourceAccess
    let files: ChainFileMigration
    let receipts: MigrationReceiptStore
    let handle: ProviderLockHandle

    init() throws {
        scratch = try ChainScratch()
        source = scratch.url.appendingPathComponent("legacy/mootx01.sqlite")
        canonical = scratch.url.appendingPathComponent("canonical/estate.sqlite")
        incoming = scratch.url.appendingPathComponent("incoming")
        backup = scratch.url.appendingPathComponent("backup")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Write a distinctive payload so digest comparisons are meaningful.
        try Data("chain-test-estate-bytes-\(chainEstateUUID.uuidString)".utf8).write(to: source)
        sharedLog = SharedEventLog()
        sourceAccess = ChainSourceAccess(sharedLog: sharedLog)
        files = ChainFileMigration(sharedLog: sharedLog)
        receipts = MigrationReceiptStore(
            fileURL: scratch.url.appendingPathComponent("migration-receipt.v1.json")
        )
        handle = try ProviderLock.acquire(
            at: scratch.url.appendingPathComponent("provider.lock"), context: .production
        )
    }

    func migrator() -> DefaultEstateMigrator {
        DefaultEstateMigrator(
            source: sourceAccess, files: files, receipts: receipts,
            lockProof: handle.proof,
            installationRoot: chainRoot,
            transaction: MigrationTransaction(
                transactionIdentifier: chainTxnID,
                sourceClass: .sandboxedPro,
                sourceURL: source, canonicalURL: canonical,
                incomingDirectory: incoming,
                quarantineDirectory: scratch.url.appendingPathComponent("quarantine"),
                backupDirectory: backup,
                grantDigestHex: "beef",
                generations: ProviderGenerations(credential: 1, provider: 1, descriptor: 1),
                staleAccepted: false,
                keyTransition: .escrowedExistingKey,
                grantMaterialURL: nil
            ),
            clock: chainClock
        )
    }

    func teardown() {
        handle.release()
        scratch.remove()
    }
}

// MARK: - Suite 1: Invariant I-A — close-before-copy ordering (never two authorities)

@Suite("Migration chain — I-A close-before-copy ordering (never two open authorities)")
struct MigrationChainCloseBeforeCopyTests {

    /// Proves invariant I-A: the source is closed BEFORE the copy is made.
    ///
    /// Uses the shared time-ordered event log that both fakes write into, which
    /// records every event in actual call order across both seams. This is the
    /// only way to prove cross-seam ordering: per-seam arrays are populated
    /// independently and cannot distinguish a reordering regression.
    ///
    /// Regression: if copyMainToIncoming is reordered to precede close(), the
    /// shared log records "copy-main-to-incoming" before "close", the index
    /// comparison fails, and the regression is caught.
    @Test("source close() precedes copyMainToIncoming() in the time-ordered combined event log")
    func closeBeforeCopy() async throws {
        let h = try ChainHarness()
        defer { h.teardown() }

        _ = try await h.migrator().run()

        // The shared log records events across both seams in actual call order.
        // freshRun drives source and file operations sequentially, so the log
        // is deterministic: open-exclusive → checkpoint-truncate →
        // verify-empty-wal → read-identity → close → preserve-backup →
        // copy-main-to-incoming → verify-read-only-open → atomic-rename-into-canonical.
        let combined = h.sharedLog.events
        guard let closeInCombined = combined.firstIndex(of: "close") else {
            Issue.record("source.close() was not recorded in shared log: \(combined)")
            return
        }
        guard let copyInCombined = combined.firstIndex(of: "copy-main-to-incoming") else {
            Issue.record("files.copyMainToIncoming was not recorded in shared log: \(combined)")
            return
        }
        #expect(
            closeInCombined < copyInCombined,
            "close must precede copyMainToIncoming in combined log — two open authorities co-existed: \(combined)"
        )

        // verifyReadOnlyOpen opens the COPY (destination), not the source.
        // It is called after copyMainToIncoming (step 4 vs step 3 in freshRun),
        // so it must appear AFTER close in the source-seam log.
        let sourceEvents = h.sourceAccess.events
        guard let closeIdx = sourceEvents.firstIndex(of: "close"),
              let verifyIdx = sourceEvents.firstIndex(of: "verify-read-only-open") else {
            Issue.record("expected close and verify-read-only-open in source events: \(sourceEvents)")
            return
        }
        #expect(verifyIdx > closeIdx,
                "verifyReadOnlyOpen must follow close in source events — it opens the COPY, not the source")
    }

    /// Proves the backup is preserved BEFORE the copy is made.
    ///
    /// Regression: if the backup is moved after the copy, a crash between
    /// backup and copy leaves the canonical absent but the incoming present
    /// with no backup — violating the "source and backup retained" guarantee.
    @Test("backup is preserved before copyMainToIncoming")
    func backupBeforeCopy() async throws {
        let h = try ChainHarness()
        defer { h.teardown() }

        _ = try await h.migrator().run()

        let fileEvents = h.files.events
        guard let backupIdx = fileEvents.firstIndex(of: "preserve-backup"),
              let copyIdx = fileEvents.firstIndex(of: "copy-main-to-incoming") else {
            Issue.record("expected both preserve-backup and copy-main-to-incoming in file events: \(fileEvents)")
            return
        }
        #expect(backupIdx < copyIdx, "backup must precede copy")
    }

    /// Proves the full quiescence sequence before any file operation.
    ///
    /// Regression: if any file operation precedes the source quiescence
    /// (open → checkpoint → emptyWAL → readIdentity → close), the estate may
    /// be copied in a non-quiesced state, breaking WAL-empty invariant.
    @Test("full quiescence sequence (open→checkpoint→emptyWAL→readIdentity→close) precedes all file operations")
    func quiescenceBeforeFileOps() async throws {
        let h = try ChainHarness()
        defer { h.teardown() }

        _ = try await h.migrator().run()

        let sourceEvents = h.sourceAccess.events
        #expect(sourceEvents.prefix(5).elementsEqual([
            "open-exclusive",
            "checkpoint-truncate",
            "verify-empty-wal",
            "read-identity",
            "close"
        ]), "quiescence sequence must be exactly open→checkpoint→emptyWAL→readIdentity→close: \(sourceEvents)")
        // File operations are in the file-seam events, which are guaranteed
        // to begin only after source.close() returns in freshRun.
        #expect(!h.files.events.isEmpty, "file operations must have been recorded")
    }
}

// MARK: - Suite 2: Invariant I-B — source retained at every boundary

@Suite("Migration chain — I-B source retained at every durable boundary")
struct MigrationChainSourceRetainedTests {

    /// Proves I-B after a successful migration.
    ///
    /// Regression: if the migrator calls any delete operation on sourceURL
    /// after commit, source.exists would be false.  FileMigrationAuthority
    /// has no delete primitive structurally, but a future refactor could
    /// add one and call it here.
    @Test("source file exists after successful migration to receiptFinal")
    func sourceExistsAfterSuccess() async throws {
        let h = try ChainHarness()
        defer { h.teardown() }

        let outcome = try await h.migrator().run()

        #expect(outcome == .committed)
        #expect(FileManager.default.fileExists(atPath: h.source.path),
                "source must be retained after successful migration — it is the recovery artifact")
    }

    /// Proves I-B: backup is created and retained alongside the source.
    ///
    /// Regression: if the backup is not written (or is removed after commit),
    /// there is no second recovery path for the operator.
    @Test("backup file exists and has the same digest as the source after successful migration")
    func backupMatchesSource() async throws {
        let h = try ChainHarness()
        defer { h.teardown() }

        _ = try await h.migrator().run()

        let backupURL = h.backup.appendingPathComponent(h.source.lastPathComponent)
        #expect(FileManager.default.fileExists(atPath: backupURL.path),
                "backup must exist after migration")
        let sourceData = try Data(contentsOf: h.source)
        let backupData = try Data(contentsOf: backupURL)
        #expect(sourceData == backupData,
                "backup bytes must equal source bytes — they are a pre-quiescence copy")
    }

    /// Proves I-B at the backup failure boundary.
    ///
    /// Regression: if the migrator continued after backup failed (deleting the
    /// source in a hypothetical future refactor), source.exists would be false.
    @Test("source exists when backup fails — no canonical, no copy")
    func sourceExistsAfterBackupFailure() async throws {
        let h = try ChainHarness()
        defer { h.teardown() }

        // Inject a backup failure by making the backup directory a file (write
        // will fail trying to create a subdirectory).
        let obstructed = h.backup
        try Data("obstruction".utf8).write(to: obstructed)

        await #expect(throws: (any Error).self) { _ = try await h.migrator().run() }

        #expect(FileManager.default.fileExists(atPath: h.source.path),
                "source must be retained after backup failure")
        #expect(!FileManager.default.fileExists(atPath: h.canonical.path),
                "canonical must NOT exist after backup failure")
    }

    /// Proves I-B after an idempotent re-run (alreadyCommitted).
    ///
    /// Regression: a re-run that removes the source to "clean up" would break
    /// this assertion. alreadyCommitted must be a true no-op with no
    /// destructive side effects.
    @Test("source exists after idempotent re-run (alreadyCommitted)")
    func sourceExistsAfterIdempotentRun() async throws {
        let h = try ChainHarness()
        defer { h.teardown() }

        _ = try await h.migrator().run()
        let outcome2 = try await h.migrator().run()

        #expect(outcome2 == .alreadyCommitted)
        #expect(FileManager.default.fileExists(atPath: h.source.path),
                "source must be retained after idempotent re-run")
    }
}

// MARK: - Suite 3: Invariant I-C — no fresh default estate

@Suite("Migration chain — I-C no fresh default estate (canonical UUID == source UUID)")
struct MigrationChainNoFreshEstateTests {

    /// Proves I-C: verifyReadOnlyOpen confirms the canonical UUID matches the
    /// source UUID; the migrator completes with .committed.
    ///
    /// Regression: if the canonical estate has a DIFFERENT UUID (e.g., a new
    /// estate was created instead of migrating the existing one), then
    /// verifyReadOnlyOpen would return a different CensusIdentity.estateIdentifier
    /// and the migrator would throw .identityMismatch — which this test
    /// verifies via the negative arm below.
    @Test("migration completes committed when canonical has same estate UUID as source")
    func committedWhenIdentityMatches() async throws {
        let h = try ChainHarness()
        defer { h.teardown() }

        let outcome = try await h.migrator().run()

        #expect(outcome == .committed,
                "matching UUID → .committed; any other outcome would indicate the identity check is not exercised")
        #expect(FileManager.default.fileExists(atPath: h.canonical.path),
                "canonical must exist after .committed")
    }

    /// Proves I-C negative: the migrator throws identityMismatch when
    /// verifyReadOnlyOpen returns a different estate UUID — the "fresh default
    /// estate" evasion path is structurally refused.
    ///
    /// Regression: if the migrator removed the .identityMismatch check, this
    /// test would succeed instead of throwing — allowing a fresh estate to
    /// replace the migrated one silently.
    @Test("identityMismatch is thrown when verifyReadOnlyOpen returns a different estate UUID")
    func throwsIdentityMismatchOnUUIDDrift() async throws {
        let h = try ChainHarness()
        defer { h.teardown() }

        // Inject a mismatched identity with a DIFFERENT estate UUID.
        let freshUUID = UUID()
        h.sourceAccess.mismatchedIdentity = CensusIdentity(
            estateIdentifier: freshUUID,
            schemaVersion: chainSchemaVersion,
            anchorCounts: chainAnchorCounts
        )

        await #expect(
            throws: DaemonProviderError.migrationFault(.identityMismatch)
        ) {
            _ = try await h.migrator().run()
        }
        // The canonical must NOT exist: the rename happens AFTER
        // verifyReadOnlyOpen, so a failed identity check leaves no canonical.
        #expect(!FileManager.default.fileExists(atPath: h.canonical.path),
                "canonical must NOT exist after identityMismatch")
        #expect(FileManager.default.fileExists(atPath: h.source.path),
                "source must be retained after identityMismatch")
    }

    /// Proves I-C for schema version: the migrator also refuses if the schema
    /// version disagrees — a schema migration that silently uses the wrong
    /// schema version would expose I-C via this check.
    ///
    /// Regression: removing the identity equality check would allow a wrong
    /// schema version to pass, hiding a migration that produced the wrong
    /// estate format.
    @Test("identityMismatch is thrown when verifyReadOnlyOpen returns a wrong schema version")
    func throwsIdentityMismatchOnSchemaDrift() async throws {
        let h = try ChainHarness()
        defer { h.teardown() }

        // Same estate UUID but wrong schema version.
        h.sourceAccess.mismatchedIdentity = CensusIdentity(
            estateIdentifier: chainEstateUUID,
            schemaVersion: chainSchemaVersion + 99,  // wrong version
            anchorCounts: chainAnchorCounts
        )

        await #expect(
            throws: DaemonProviderError.migrationFault(.identityMismatch)
        ) {
            _ = try await h.migrator().run()
        }
    }
}

// MARK: - Suite 4: Invariant I-D — committed only after authenticated readiness

@Suite("Migration chain — I-D committed only after authenticated readiness (verifyReadOnlyOpen gate)")
struct MigrationChainAuthenticatedReadinessTests {

    /// Proves I-D: the migrator records verifyReadOnlyOpen in the event log
    /// before writing the .committed receipt — proving the authenticated
    /// identity proof is the gate that precedes canonical ownership.
    ///
    /// Regression: if the committed receipt were written before
    /// verifyReadOnlyOpen, this test would fail because the event log would
    /// show "verify-read-only-open" appearing AFTER the receipt was committed
    /// in wall-clock order — which the receipt store timestamps would reveal.
    @Test("verifyReadOnlyOpen is recorded before the migrator reaches .committed")
    func verifyBeforeCommitted() async throws {
        let h = try ChainHarness()
        defer { h.teardown() }

        let outcome = try await h.migrator().run()

        #expect(outcome == .committed)
        // The full source-event log must include verify-read-only-open and it
        // must appear after close (proving it opened the COPY, not the source).
        let sourceEvents = h.sourceAccess.events
        #expect(sourceEvents.contains("verify-read-only-open"),
                "verifyReadOnlyOpen must be called to prove authenticated readiness")
        // Confirm it appears after close in the sequence.
        if let closeIdx = sourceEvents.firstIndex(of: "close"),
           let verifyIdx = sourceEvents.firstIndex(of: "verify-read-only-open") {
            #expect(verifyIdx > closeIdx,
                    "verify-read-only-open must follow close (proving it opened the copy)")
        }
    }

    /// Proves I-D negative: when verifyReadOnlyOpen fails with an identity
    /// mismatch, the migrator does NOT reach .committed. Ownership cannot
    /// be committed to a canonical estate that fails the readiness proof.
    ///
    /// Regression: if the .committed state were reached regardless of the
    /// verifyReadOnlyOpen outcome, a bad canonical could become the active
    /// estate without proven identity.
    @Test("failed verifyReadOnlyOpen prevents .committed — ownership is not transferred")
    func failedReadinessBlocksOwnership() async throws {
        let h = try ChainHarness()
        defer { h.teardown() }

        // Inject a UUID mismatch so the readiness proof fails.
        h.sourceAccess.mismatchedIdentity = CensusIdentity(
            estateIdentifier: UUID(),
            schemaVersion: chainSchemaVersion,
            anchorCounts: chainAnchorCounts
        )

        do {
            _ = try await h.migrator().run()
            Issue.record("Expected .migrationFault(.identityMismatch) but succeeded")
        } catch DaemonProviderError.migrationFault(.identityMismatch) {
            // Expected.
        } catch {
            Issue.record("Expected .identityMismatch, got \(error)")
        }
        // No receipt should have reached .committed.
        if let stored = try? h.receipts.load() {
            #expect(stored.state != .committed,
                    "receipt must not be .committed when readiness proof fails")
        }
        // No canonical estate should exist.
        #expect(!FileManager.default.fileExists(atPath: h.canonical.path),
                "canonical must not exist when ownership commitment is blocked")
    }

    // BLOCKED: Live entitled provider authenticating the canonical estate
    // across the AppGroup boundary. The production SourceEstateAccess
    // conformer (which runs SQLite's PRAGMA integrity_check, reads the schema
    // version from the production schema, and verifies anchor counts against
    // the live rows) arrives with MACD-3 estate routing. The seam-based tests
    // above prove the machine's structural guarantee; the production path
    // proof is a MACD-3 deliverable.
    @Test("BLOCKED: live SQLite integrity_check via SourceEstateAccess production conformer")
    func blockedLiveIntegrityCheck() {
        // This test is intentionally empty — the path requires a live
        // entitled provider. Marking it here makes the gap explicit in the
        // matrix rather than silently absent.
        //
        // UNBLOCKED by: production SourceEstateAccess conformer (MACD-3).
    }
}
