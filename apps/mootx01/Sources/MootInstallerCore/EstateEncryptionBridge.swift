// EstateEncryptionBridge.swift
//
// The two app-side pieces of estate encryption. The conversion itself lives in
// the EstateEncryption library (the benchmark harness consumes it too); the
// open posture and key custody live in GeniusLocusKit (`EstateOpenPosture`,
// beside the estate catalog). What stays here is what only the app knows:
// the launchd daemon seam, and the library's namespace under the name the
// app's commands use.

import EstateEncryption
import Foundation

/// The conversion namespace, as the app's commands name it.
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
