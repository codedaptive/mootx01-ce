// EstateEncryptionBridge.swift
//
// The app-side seams of the estate encryption conversion. The conversion
// itself lives in the EstateEncryption library, which the benchmark harness
// also consumes; only the two pieces that need app-layer types stay here.
//
// Nothing in this file changes behaviour. It re-exports the library's
// namespace under the name the app already used, adds the launchd daemon
// seam (LaunchAgent lives in this module), and forwards the file-state
// detection that six call sites reach through EstateKeyProvider.

import EstateEncryption
import Foundation

/// The conversion namespace, unchanged for every existing call site.
public typealias EstateEncryptionMigrator = EstateEncryption.EstateEncryptionMigrator

extension EstateEncryptionMigrator.DaemonControl {
    /// The production seam: launchctl via LaunchAgent.
    public static func launchd(homeDirectory: URL) -> EstateEncryptionMigrator.DaemonControl {
        EstateEncryptionMigrator.DaemonControl(
            isRunning: { LaunchAgent.isDaemonRunning() },
            stop: { LaunchAgent.stopDaemon() },
            start: { LaunchAgent.startDaemon(homeDirectory: homeDirectory) })
    }
}

extension EstateKeyProvider {
    /// What a file at a given path is. The library owns the definition; this
    /// alias keeps the app's spelling of it.
    public typealias EstateFileState = EstateEncryptionMigrator.EstateFileState

    /// The plaintext SQLite file magic, 16 bytes.
    public static var plaintextSQLiteMagic: [UInt8] {
        EstateEncryptionMigrator.plaintextSQLiteMagic
    }

    /// Classify the estate file at `url`. Forwards to the library so the app
    /// and the harness classify identically.
    public static func detectEstateFileState(at url: URL) -> EstateFileState {
        EstateEncryptionMigrator.detectEstateFileState(at: url)
    }
}
