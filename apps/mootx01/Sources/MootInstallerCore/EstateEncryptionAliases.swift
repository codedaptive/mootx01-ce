// EstateEncryptionAliases.swift
//
// Type aliases and production seam extensions for estate encryption.
//
// `EstateEncryptionMigrator` is the namespace from the EstateEncryption
// library (shared with the benchmark harness); the app's commands use it
// under this name. The launchd production seam lives here because only
// MootInstallerCore knows how to call LaunchAgent — the library itself
// stays harness-portable and knows nothing about launchctl.

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
