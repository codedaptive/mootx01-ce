// TwentyRowEstateFixture.swift
//
// A disposable twenty-drawer PLAINTEXT estate for tests that need a real
// on-disk estate: the at-rest encryption work (CE-1.0.35-05/06/07/08) and the
// provenance-gate parity tests (CE-1.0.35-03).
//
// WHY THIS EXISTS
// Bob's standing ruling: never test against the production estate. That file
// holds roughly 98,000 memories and is irreplaceable, and the encryption
// missions specifically exercise migration, atomic swap, and Trash paths — the
// exact operations whose bugs cost someone their memories. Twenty generated
// rows carry every property those tests assert on, at a size that makes a full
// count comparison cheap.
//
// WHY THE ROW COUNT IS SMALL BUT THE SHAPE IS NOT
// Consumers assert on structure, not volume: one drawer at each of the four
// sensitivity tiers (so a gate can be proven to admit and refuse), facts with
// provenance back to specific drawers (so a migration can be shown to preserve
// the KG), and tunnels (so edge preservation is checkable). Sixteen filler rows
// spread across wings and rooms give the node tree something real to resolve.
//
// DETERMINISM CONTRACT
// Drawer ids are derived from stable labels, not random UUIDs, so a consumer can
// name a row across runs. Content strings are fixed. Timestamps are NOT part of
// the determinism contract: capture stamps wall time, and asserting on it would
// make the fixture flaky. Assert against the returned `Manifest` instead of
// hardcoded numbers, which is why the manifest carries the counts and the ids by
// tier rather than leaving callers to recount.

import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitSQLite

/// Generator for the twenty-row plaintext estate fixture.
public enum TwentyRowEstateFixture {

    // MARK: - Manifest

    /// What `generate(at:)` produced. Consumers assert against these values
    /// rather than hardcoding 20/6/2, so changing the fixture's size does not
    /// silently invalidate a test that meant "all of them".
    public struct Manifest: Sendable, Equatable {
        /// Where the estate file was written.
        public let estateURL: URL
        /// Total drawers captured.
        public let drawerCount: Int
        /// Knowledge-graph facts captured, each with a `sourceDrawerID`.
        public let factCount: Int
        /// Tunnels captured.
        public let tunnelCount: Int
        /// Distinct wing display names used.
        public let wings: [String]
        /// Distinct room display names used.
        public let rooms: [String]
        /// Drawer id at each PROVENANCE sensitivity tier. Exactly one entry per
        /// tier, which is what lets a gate test pick "the restricted one"
        /// without scanning.
        public let drawerIDsByProvenanceTier: [Sensitivity: String]
        /// Every drawer id, in capture order.
        public let drawerIDs: [String]
        /// Fact ids, in capture order.
        public let factIDs: [String]
        /// Tunnel ids, in capture order.
        public let tunnelIDs: [String]
        /// The id of the tunnel carrying the `precedes` label.
        public let precedesTunnelID: String
    }

    /// Raised when the generator refuses to run.
    public enum FixtureError: Error, CustomStringConvertible {
        /// The target path resolves inside the real data directory. This is a
        /// refusal, not a failure: see `assertNotProductionPath`.
        case refusesProductionPath(target: URL, dataDirectory: URL)
        /// A tier that must exist in the manifest was not produced.
        case incompleteManifest(String)

        public var description: String {
            switch self {
            case let .refusesProductionPath(target, dataDirectory):
                return """
                    TwentyRowEstateFixture refuses to write inside the real data \
                    directory. target=\(target.path) dataDirectory=\(dataDirectory.path). \
                    Generate into a caller-supplied temp directory instead.
                    """
            case let .incompleteManifest(detail):
                return "TwentyRowEstateFixture produced an incomplete manifest: \(detail)"
            }
        }
    }

    // MARK: - Production-path guard

    /// The env var that overrides the resolved data directory, mirroring
    /// `MootPaths.dataDirEnvVar`. Duplicated as a literal rather than imported
    /// because LocusKit sits below the installer module that owns `MootPaths`,
    /// and a test-support target must not drag an app module into the kit graph.
    /// If the app-side name ever changes, this guard must change with it.
    public static let dataDirEnvVar = "MOOTX01_DATA_DIR"

    /// The real estate directory this fixture must never touch. Mirrors
    /// `MootPaths.resolveDataDirectory`: the env override wins when set and
    /// non-empty, otherwise the macOS Application Support location.
    public static func productionDataDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let override = environment[dataDirEnvVar], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        return homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("com.mootx01.ce", isDirectory: true)
            .standardizedFileURL
    }

    /// Throws if `target` resolves inside the real data directory.
    ///
    /// This is the hard constraint from CE-1.0.35-04 and it is enforced HERE, in
    /// the generator, rather than left to each caller to remember. Comparison is
    /// on standardized paths with a trailing separator, so `/…/com.mootx01.ce2`
    /// is not treated as inside `/…/com.mootx01.ce`. Symlinks are resolved first
    /// so a link into the data directory cannot smuggle a write past the check.
    public static func assertNotProductionPath(
        _ target: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        let dataDirectory = productionDataDirectory(
            environment: environment, homeDirectory: homeDirectory)

        // resolvingSymlinksInPath() on a not-yet-existing file still resolves
        // the existing parent components, which is the part that matters: a
        // symlinked parent directory is the realistic way to land inside the
        // real data directory without naming it.
        let resolvedTarget = target.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedDataDir = dataDirectory.resolvingSymlinksInPath()

        for candidateDir in Set([dataDirectory.path, resolvedDataDir.path]) {
            let dirWithSeparator = candidateDir.hasSuffix("/") ? candidateDir : candidateDir + "/"
            for candidateTarget in Set([target.standardizedFileURL.path, resolvedTarget.path]) {
                if candidateTarget == candidateDir || candidateTarget.hasPrefix(dirWithSeparator) {
                    throw FixtureError.refusesProductionPath(
                        target: target, dataDirectory: dataDirectory)
                }
            }
        }
    }

    // MARK: - Plaintext header detection

    /// The plaintext SQLite file magic: ASCII "SQLite format 3" plus the
    /// terminating zero byte. A SQLCipher database encrypts page 1 including
    /// this header, so its first 16 bytes are ciphertext and never match.
    public static let plaintextSQLiteMagic: [UInt8] =
        Array("SQLite format 3".utf8) + [0x00]

    /// True when the first 16 bytes of `url` are the plaintext SQLite magic.
    /// Reads bytes directly and never opens a SQLite connection, so it is safe
    /// to call on a file the caller has no key for.
    public static func hasPlaintextSQLiteHeader(at url: URL) throws -> Bool {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return false }
        defer { try? handle.close() }
        let head = try handle.read(upToCount: plaintextSQLiteMagic.count) ?? Data()
        return Array(head) == plaintextSQLiteMagic
    }

    // MARK: - Shape

    /// Wing display names. Three, per the fixture contract.
    public static let wings = ["fixture-alpha", "fixture-beta", "fixture-gamma"]

    /// Room display names. Five, which satisfies "at least 4".
    public static let rooms = [
        "notes", "decisions", "sensitive", "archive", "scratch",
    ]

    /// The twenty drawers, declared as data so the shape is auditable at a
    /// glance and stays stable across runs.
    ///
    /// The four provenance tiers are pinned to specific labels
    /// (`row-normal-tier`, `row-elevated-tier`, `row-restricted-tier`,
    /// `row-secret-tier`) so the manifest can report one id per tier. The other
    /// sixteen are normal or elevated only, never restricted or secret, so a
    /// consumer counting "rows a default recall gate admits" gets a stable
    /// answer.
    struct RowSpec {
        let label: String
        let wing: String
        let room: String
        let content: String
        let provenance: Sensitivity
    }

    static let rowSpecs: [RowSpec] = {
        var specs: [RowSpec] = [
            // The four tier anchors. One per tier, exactly as the manifest promises.
            RowSpec(label: "row-normal-tier", wing: wings[0], room: rooms[0],
                    content: "fixture row at provenance normal tier", provenance: .normal),
            RowSpec(label: "row-elevated-tier", wing: wings[0], room: rooms[1],
                    content: "fixture row at provenance elevated tier", provenance: .elevated),
            RowSpec(label: "row-restricted-tier", wing: wings[1], room: rooms[2],
                    content: "fixture row at provenance restricted tier", provenance: .restricted),
            RowSpec(label: "row-secret-tier", wing: wings[1], room: rooms[2],
                    content: "fixture row at provenance secret tier", provenance: .secret),
        ]
        // Sixteen filler rows, round-robin across wings and rooms so the node
        // tree has real breadth. Alternating normal/elevated keeps every filler
        // row below the redaction boundary.
        for index in 0..<16 {
            specs.append(RowSpec(
                label: "row-filler-\(String(format: "%02d", index))",
                wing: wings[index % wings.count],
                room: rooms[index % rooms.count],
                content: "fixture filler row \(String(format: "%02d", index))",
                provenance: index.isMultiple(of: 2) ? .normal : .elevated
            ))
        }
        return specs
    }()

    /// The six knowledge-graph facts, each anchored to a specific drawer label
    /// so provenance is real rather than dangling.
    struct FactSpec {
        let label: String
        let subject: String
        let predicate: String
        let object: String
        /// Label of the drawer this fact was derived from.
        let sourceRowLabel: String
    }

    static let factSpecs: [FactSpec] = [
        FactSpec(label: "fact-01", subject: "fixture", predicate: "hasTier",
                 object: "normal", sourceRowLabel: "row-normal-tier"),
        FactSpec(label: "fact-02", subject: "fixture", predicate: "hasTier",
                 object: "elevated", sourceRowLabel: "row-elevated-tier"),
        FactSpec(label: "fact-03", subject: "fixture", predicate: "hasTier",
                 object: "restricted", sourceRowLabel: "row-restricted-tier"),
        FactSpec(label: "fact-04", subject: "fixture", predicate: "hasTier",
                 object: "secret", sourceRowLabel: "row-secret-tier"),
        FactSpec(label: "fact-05", subject: "fixture", predicate: "wingCount",
                 object: "three", sourceRowLabel: "row-filler-00"),
        FactSpec(label: "fact-06", subject: "fixture", predicate: "roomCount",
                 object: "five", sourceRowLabel: "row-filler-01"),
    ]

    // MARK: - Deterministic identity

    /// Stable UUID-shaped id from a readable label, so a consumer can name a
    /// fixture row across runs. Same mixing construction as
    /// `LocusKitTests.TestStorage.tid`: FNV-1a as a mixing primitive with byte
    /// scattering across all 16 output bytes, then the v4 version and variant
    /// nibbles forced so the result parses as a UUID. Capture requires a UUID
    /// row identity, so a bare label will not do.
    public static func stableID(_ label: String) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        var h: UInt64 = 0xcbf29ce484222325
        for (index, byte) in Array(label.utf8).enumerated() {
            h ^= UInt64(byte); h = h &* 0x100000001b3
            bytes[index % 16] ^= UInt8(h & 0xff)
            bytes[(index + 7) % 16] ^= UInt8((h >> 32) & 0xff)
        }
        for index in 0..<16 {
            h ^= UInt64(bytes[index]); h = h &* 0x100000001b3
            bytes[index] = bytes[index] &+ UInt8(h & 0xff)
        }
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let a = hex.prefix(8)
        let b = hex.dropFirst(8).prefix(4)
        let c = hex.dropFirst(12).prefix(4)
        let d = hex.dropFirst(16).prefix(4)
        let e = hex.dropFirst(20).prefix(12)
        return "\(a)-\(b)-\(c)-\(d)-\(e)"
    }

    /// Fixed instant used for every fact's `filedAt`, so fact rows carry no
    /// run-dependent value. 2026-01-01T00:00:00Z.
    static let fixedFactInstant = Date(timeIntervalSince1970: 1_767_225_600)

    // MARK: - Generation

    /// Create the twenty-row plaintext estate at `estateURL`.
    ///
    /// - Parameter estateURL: Absolute file URL inside a caller-supplied temp
    ///   directory. MUST NOT be inside the real data directory; the guard runs
    ///   first and throws before any file is created.
    /// - Returns: The manifest describing exactly what was written.
    @discardableResult
    public static func generate(
        at estateURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) async throws -> Manifest {
        // Step zero, before any filesystem write.
        try assertNotProductionPath(
            estateURL, environment: environment, homeDirectory: homeDirectory)

        try FileManager.default.createDirectory(
            at: estateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        var drawerIDs: [String] = []
        var tierIDs: [Sensitivity: String] = [:]
        var tunnelIDs: [String] = []
        var precedesTunnelID = ""
        var labelToDrawerID: [String: String] = [:]

        // Scope the Estate so its SQLite connection is released before the
        // fact-writing store opens over the same file. Sequential, never
        // concurrent, so two connections never contend for the same WAL.
        do {
            let configuration = EstateConfiguration(
                estateID: UUID(), backend: .sqlite(url: estateURL))
            let storage = try SQLiteStorage(configuration: configuration)
            let estate = try await Estate.open(
                storage: storage,
                owner: OwnerCredentials(ownerIdentifier: "twenty-row-fixture"))

            for spec in rowSpecs {
                let frame = CaptureFrame(
                    content: spec.content,
                    channel: .typed,
                    room: spec.room,
                    latticeAnchor: .udc("004"),
                    addedBy: "twenty-row-fixture",
                    embeddingModelID: "fixture-model-v1",
                    provenanceSensitivity: spec.provenance,
                    wing: spec.wing
                )
                let drawer = try await estate.capture(frame)
                drawerIDs.append(drawer.id)
                labelToDrawerID[spec.label] = drawer.id
                // Only the four anchors claim a tier slot; fillers are normal or
                // elevated and must not overwrite the anchors' ids.
                if spec.label.hasSuffix("-tier") {
                    tierIDs[spec.provenance] = drawer.id
                }
            }

            // Exactly two tunnels. `precedes` has no LocusKit TunnelKind case —
            // the MCP surface maps the kind string "precedes" onto
            // TunnelKind.blocks (see ToolDispatch's link-kind mapping), so the
            // substrate shape of a precedes edge is .blocks carrying the
            // "precedes" label. Matching that here means a consumer reading this
            // fixture sees the same rows moot_link_memories would have written.
            let precedes = TunnelCaptureFrame(
                sourceWing: wings[0], sourceRoom: rooms[0],
                targetWing: wings[0], targetRoom: rooms[1],
                label: "precedes",
                addedBy: "twenty-row-fixture",
                sourceDrawerId: labelToDrawerID["row-normal-tier"],
                targetDrawerId: labelToDrawerID["row-elevated-tier"],
                kind: .blocks
            )
            let precedesTunnel = try await estate.capture(precedes)
            precedesTunnelID = precedesTunnel.id
            tunnelIDs.append(precedesTunnel.id)

            let references = TunnelCaptureFrame(
                sourceWing: wings[0], sourceRoom: rooms[0],
                targetWing: wings[2], targetRoom: rooms[3],
                label: "references",
                addedBy: "twenty-row-fixture",
                sourceDrawerId: labelToDrawerID["row-filler-00"],
                targetDrawerId: labelToDrawerID["row-filler-03"],
                kind: .references
            )
            let referencesTunnel = try await estate.capture(references)
            tunnelIDs.append(referencesTunnel.id)
        }

        // Facts go in through DrawerStore: KG-fact writes are a store-level verb
        // with no Estate wrapper, same as LocusKit's own KGFact tests use.
        var factIDs: [String] = []
        do {
            let configuration = EstateConfiguration(
                estateID: UUID(), backend: .sqlite(url: estateURL))
            let storage = try SQLiteStorage(configuration: configuration)
            let store = try await DrawerStore(storage: storage)

            for spec in factSpecs {
                guard let sourceDrawerID = labelToDrawerID[spec.sourceRowLabel] else {
                    throw FixtureError.incompleteManifest(
                        "fact \(spec.label) references unknown row \(spec.sourceRowLabel)")
                }
                let fact = KGFact(
                    id: stableID(spec.label),
                    subject: spec.subject,
                    predicate: spec.predicate,
                    object: spec.object,
                    sourceDrawerID: sourceDrawerID,
                    filedAt: fixedFactInstant
                )
                try await store.addKGFact(fact)
                factIDs.append(fact.id)
            }
        }

        // Every tier the manifest promises must actually be present, or a
        // consumer's force-unwrap on a tier id would fail far from the cause.
        for tier: Sensitivity in [.normal, .elevated, .restricted, .secret] {
            guard tierIDs[tier] != nil else {
                throw FixtureError.incompleteManifest("no drawer at provenance tier \(tier)")
            }
        }

        return Manifest(
            estateURL: estateURL,
            drawerCount: drawerIDs.count,
            factCount: factIDs.count,
            tunnelCount: tunnelIDs.count,
            wings: wings,
            rooms: rooms,
            drawerIDsByProvenanceTier: tierIDs,
            drawerIDs: drawerIDs,
            factIDs: factIDs,
            tunnelIDs: tunnelIDs,
            precedesTunnelID: precedesTunnelID
        )
    }

    /// Convenience: generate into a fresh temp directory and return the manifest.
    /// The caller owns cleanup via `cleanup(_:)`.
    @discardableResult
    public static func generateInTemporaryDirectory() async throws -> Manifest {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("twenty-row-fixture-\(UUID().uuidString)", isDirectory: true)
        return try await generate(at: directory.appendingPathComponent("estate.sqlite"))
    }

    /// Open an estate through a caller-supplied configuration and count its
    /// drawers.
    ///
    /// Exists so consumers can prove a posture decision actually OPENS the file
    /// rather than merely describing it: a wrong SQLCipher key surfaces here as a
    /// thrown error instead of a count. Takes a full `EstateConfiguration` so the
    /// caller supplies its own encryption config, which is the part under test.
    public static func drawerCount(of configuration: EstateConfiguration) async throws -> Int {
        let storage = try SQLiteStorage(configuration: configuration)
        let store = try await DrawerStore(storage: storage)
        return try await store.allDrawers().count
    }

    /// Remove a generated estate and its WAL/SHM siblings.
    public static func cleanup(_ manifest: Manifest) {
        cleanup(manifest.estateURL)
    }

    /// Remove an estate file and its WAL/SHM siblings.
    public static func cleanup(_ estateURL: URL) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: estateURL)
        for suffix in ["-wal", "-shm"] {
            let sibling = estateURL.deletingLastPathComponent()
                .appendingPathComponent(estateURL.lastPathComponent + suffix)
            try? fileManager.removeItem(at: sibling)
        }
    }
}
