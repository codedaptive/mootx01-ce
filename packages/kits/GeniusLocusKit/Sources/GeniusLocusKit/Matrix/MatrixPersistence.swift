// MatrixPersistence.swift
//
// Mission GLK-06 — Selectable matrix-tier persistence.
//
// Per durable matrix snapshots, persistence is a
// per-estate mode chosen at instantiation:
//
//   .inMemory             — the matrix tier is held purely in memory and
//                           rebuilt from the unified audit log on every
//                           cold start. Suited to small / ephemeral
//                           estates.
//   .snapshotted(URL)     — the matrix tier is serialised to a file at
//                           an HLC watermark. On load the snapshot is
//                           restored and only the audit tail beyond the
//                           watermark is replayed. Suited to large /
//                           long-lived estates where full rebuild would
//                           breach the responsiveness target.
//
// The audit log remains the single source of truth (I-2, I-20). A
// snapshot is a rebuildable cache and can be discarded without loss.

import Foundation
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateTypes

// MARK: - Mode

/// Matrix-tier persistence mode. Chosen by the consumer at estate
/// instantiation per durable matrix snapshots.
public enum MatrixPersistenceMode: Sendable, Equatable {
    /// Hold the matrix tier purely in memory. Cold-start rebuilds from
    /// the full audit log.
    case inMemory

    /// Persist to a file URL at an HLC watermark; load and replay only
    /// the audit tail beyond the watermark.
    case snapshotted(file: URL)
}

// MARK: - Snapshot

/// One persisted snapshot of the matrix tier plus its companion
/// calibration registry. The HLC watermark records the highest HLC the
/// snapshot reflects; the rebuild path replays only entries strictly
/// after this point.
public struct MatrixSnapshot: Sendable, Equatable, Codable {
    public var schemaVersion: Int
    public var hlcWatermark: HLC
    public var tier: MatrixTier
    public var calibration: MatrixCalibrationRegistry

    public static let currentSchemaVersion: Int = 1

    public init(tier: MatrixTier,
                calibration: MatrixCalibrationRegistry,
                hlcWatermark: HLC) {
        self.schemaVersion = Self.currentSchemaVersion
        self.tier = tier
        self.calibration = calibration
        self.hlcWatermark = hlcWatermark
    }
}

// MARK: - Errors

public enum MatrixPersistenceError: Error, Equatable, Sendable {
    case snapshotDecodeFailed(reason: String)
    case snapshotEncodeFailed(reason: String)
    case schemaVersionMismatch(found: Int, expected: Int)
}

// MARK: - Backend

/// Persistence backend driving the matrix tier through its lifecycle.
/// One instance per estate; chosen by mode.
public struct MatrixPersistenceBackend: Sendable {
    public let mode: MatrixPersistenceMode

    public init(mode: MatrixPersistenceMode) {
        self.mode = mode
    }

    /// Load the matrix tier. In `.inMemory` this always returns an
    /// empty tier (the caller must rebuild). In `.snapshotted` this
    /// reads the snapshot file if it exists; absent file returns
    /// `nil` so the caller can fall back to a full rebuild.
    public func load() throws -> MatrixSnapshot? {
        switch mode {
        case .inMemory:
            return nil
        case .snapshotted(let url):
            guard FileManager.default.fileExists(atPath: url.path)
            else { return nil }
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw MatrixPersistenceError.snapshotDecodeFailed(
                    reason: "read failed: \(error)"
                )
            }
            do {
                let decoded = try JSONDecoder().decode(
                    MatrixSnapshot.self, from: data
                )
                if decoded.schemaVersion
                    != MatrixSnapshot.currentSchemaVersion {
                    throw MatrixPersistenceError.schemaVersionMismatch(
                        found: decoded.schemaVersion,
                        expected: MatrixSnapshot.currentSchemaVersion
                    )
                }
                return decoded
            } catch let e as MatrixPersistenceError {
                throw e
            } catch {
                throw MatrixPersistenceError.snapshotDecodeFailed(
                    reason: "\(error)"
                )
            }
        }
    }

    /// Save a snapshot. In `.inMemory` mode this is a deliberate
    /// no-op: the audit log is authoritative and the matrix tier is
    /// rebuildable cache. In `.snapshotted` mode the snapshot is
    /// written atomically (write-then-rename) so a crash mid-write
    /// cannot leave a half-encoded file at the canonical path.
    public func save(_ snapshot: MatrixSnapshot) throws {
        switch mode {
        case .inMemory:
            return
        case .snapshotted(let url):
            let data: Data
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                data = try encoder.encode(snapshot)
            } catch {
                throw MatrixPersistenceError.snapshotEncodeFailed(
                    reason: "\(error)"
                )
            }
            let tmp = url.appendingPathExtension("tmp")
            do {
                try data.write(to: tmp, options: .atomic)
                _ = try? FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: tmp, to: url)
            } catch {
                throw MatrixPersistenceError.snapshotEncodeFailed(
                    reason: "write failed: \(error)"
                )
            }
        }
    }

    // MARK: - Rebuild orchestration

    /// Rebuild the matrix tier from an audit log, applying the
    /// persistence mode's start-state. The returned snapshot is the
    /// post-rebuild state at the log's `lastHLC`; persisted modes
    /// also save it back through `save`.
    ///
    /// Both modes replay the full log. The audit log is
    /// content-addressed (G-Set) and the rebuild is associative, so a
    /// full replay is correct in both cases and simpler to reason
    /// about than a load-then-tail-replay path. The watermark is
    /// preserved in the saved snapshot for callers (e.g. the dreaming
    /// daemon, GLK-07) that want to observe progress.
    public func rebuild(
        from log: UnifiedAuditLog,
        calibration: MatrixCalibrationRegistry = MatrixCalibrationRegistry()
    ) throws -> MatrixSnapshot {
        let tier = MatrixTier.rebuild(from: log)
        let snap = MatrixSnapshot(
            tier: tier,
            calibration: calibration,
            hlcWatermark: tier.lastHLC
        )
        try save(snap)
        return snap
    }
}
