// DbCommand.swift
//
// Named estate lifecycle: create, list, open (set active), delete.
// Estates live at ~/Library/Application Support/MOOTx01/databases/<name>/.
// The active estate pointer is stored in config.json.

import ArgumentParser
import Foundation
import MootInstallerCore

struct DbCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "db",
        abstract: "Manage named estate databases.",
        subcommands: [
            DbCreateCommand.self,
            DbListCommand.self,
            DbOpenCommand.self,
            DbDeleteCommand.self,
        ]
    )
}

// MARK: - db create <name>

struct DbCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new named estate."
    )

    @Argument(help: "Name for the new estate.")
    var name: String

    func run() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        let dataDir = MootPaths.resolveDataDirectory(environment: env, homeDirectory: home)

        try DatabaseManager.createEstate(name: name, in: dataDir)
        print("Created estate '\(name)'.")
        print("Run `mootx01 db open \(name)` to make it the active estate.")
    }
}

// MARK: - db list

struct DbListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all known estates."
    )

    func run() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        let dataDir = MootPaths.resolveDataDirectory(environment: env, homeDirectory: home)

        let estates = DatabaseManager.listEstates(in: dataDir)
        let active = (try? DatabaseManager.activeEstateName(in: dataDir)) ?? "default"

        if estates.isEmpty {
            print("No estates found. Run `mootx01 serve` to create the default estate.")
            return
        }

        print("Estates:")
        for name in estates {
            let marker = name == active ? " (active)" : ""
            print("  \(name)\(marker)")
        }
    }
}

// MARK: - db open <name>

struct DbOpenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Set the active estate (used by serve and status)."
    )

    @Argument(help: "Estate name to activate.")
    var name: String

    func run() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        let dataDir = MootPaths.resolveDataDirectory(environment: env, homeDirectory: home)

        let estateURL = DatabaseManager.estateURL(for: name, in: dataDir)
        guard FileManager.default.fileExists(atPath: estateURL.path) else {
            print("Estate '\(name)' not found. Run `mootx01 db list` to see available estates.")
            throw ExitCode.failure
        }

        try DatabaseManager.setActiveEstate(name, in: dataDir)
        print("Active estate set to '\(name)'.")
    }
}

// MARK: - db delete <name>

struct DbDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a named estate and its database files."
    )

    @Argument(help: "Estate name to delete. Cannot delete 'default' (use uninstall --purge).")
    var name: String

    @Flag(name: .shortAndLong, help: "Skip confirmation prompt.")
    var yes: Bool = false

    func run() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        let dataDir = MootPaths.resolveDataDirectory(environment: env, homeDirectory: home)

        if !yes {
            print("Delete estate '\(name)' and all its data? This is irreversible.")
            print("Type 'yes' to confirm: ", terminator: "")
            guard readLine()?.trimmingCharacters(in: .whitespaces).lowercased() == "yes" else {
                print("Aborted.")
                return
            }
        }

        try DatabaseManager.deleteEstate(name: name, in: dataDir)
        print("Estate '\(name)' deleted.")
    }
}
