// MatrixCommand.swift — the storage matrix benchmark.
//
// Measures retrieval quality across storage configurations with the data held
// constant, so a difference between cells is attributable to storage rather
// than to content.
//
// The conversion is the product's own: `EstateEncryption` is the library the
// `mootx01 upgrade` path uses. Nothing here is grafted into the product, and
// the conversion itself is never timed — this benchmark measures retrieval,
// and the encryption cost in latency belongs to the timing benchmark.
//
// One database is resident at a time. Peak disk is a copy of the largest
// single database plus its converted twin, not a copy of the whole set.
//
// BOTH cells are served and probed. The encrypted cell is served from a key
// file the harness writes beside the converted database, which needs a harness
// build of both binaries (-Xswiftc -DMOOTX01_HARNESS_KEYFILE; `make
// swift-harness` sets it for the harness). Without that flag the encrypted
// cell throws rather than reporting a row no query ever touched: the server
// would generate its own key and could not open a database converted here.

import EstateEncryption
import Foundation

/// One database found on disk, ready to run through the matrix.
struct MatrixTarget: Sendable {
    /// The run-key directory name (the set this database belongs to).
    let runKey: String
    /// The unit directory holding `estate/` and its manifests.
    let entry: URL
    var label: String { "\(runKey)/\(entry.lastPathComponent)" }
}

/// One cell of the matrix: a storage configuration measured by one port.
struct MatrixCell: Sendable {
    let encryption: String
    let backend: String
    let port: String
}

/// Enumerates every prebuilt database under a store directory.
///
/// Layout is `<store>/<run-key>/<unit-id>/estate`. An entry without an
/// `estate` directory is skipped: the store root also holds the drift-gate
/// receipt, and a partial write leaves a directory with no estate in it.
func discoverMatrixTargets(storeDir: URL, runKeyFilter: String?) throws -> [MatrixTarget] {
    let fm = FileManager.default
    guard let runKeys = try? fm.contentsOfDirectory(
        at: storeDir, includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles])
    else { return [] }

    var targets: [MatrixTarget] = []
    for runKeyURL in runKeys.sorted(by: { $0.path < $1.path }) {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: runKeyURL.path, isDirectory: &isDir), isDir.boolValue
        else { continue }
        let runKey = runKeyURL.lastPathComponent
        if let filter = runKeyFilter, !runKey.contains(filter) { continue }

        let units = (try? fm.contentsOfDirectory(
            at: runKeyURL, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        for unit in units.sorted(by: { $0.path < $1.path }) {
            guard fm.fileExists(atPath: unit.appendingPathComponent("estate").path)
            else { continue }
            targets.append(MatrixTarget(runKey: runKey, entry: unit))
        }
    }
    return targets
}

/// The estate database file inside a restored working copy.
///
/// Named rather than searched: the store's layout is fixed by the artifact
/// writer, and a search would silently pick a sibling (`-wal`, a stale
/// `.encrypting`) if the expected file were ever absent.
func estateDatabaseURL(inScratch scratch: URL) -> URL {
    scratch.appendingPathComponent("estate.sqlite")
}

/// Converts every database in a scratch directory, not only the estate.
///
/// An estate directory holds more than one database — the estate itself and
/// the queue beside it — and the product opens both under the same posture.
/// Converting only `estate.sqlite` leaves a plaintext queue next to an
/// encrypted estate, which the server will not open.
///
/// Only the estate's row counts are returned. The queue is working state
/// rather than data under measurement, so it is verified by structure instead
/// of by the four gated counts, whose tables it does not have.
func convertScratchDirectoryToEncrypted(
    scratchDir: URL, key: Data
) throws -> EstateEncryptionMigrator.VerificationCounts {
    let fm = FileManager.default
    let contents = (try? fm.contentsOfDirectory(atPath: scratchDir.path)) ?? []
    // Main database files only: the -wal and -shm siblings belong to whichever
    // main file they sit beside and are folded in by the export's checkpoint.
    let databases = contents.filter { $0.hasSuffix(".sqlite") }.sorted()
    let estateName = estateDatabaseURL(inScratch: scratchDir).lastPathComponent
    var estateCounts: EstateEncryptionMigrator.VerificationCounts?

    for name in databases {
        let db = scratchDir.appendingPathComponent(name)
        guard EstateEncryptionMigrator.detectEstateFileState(at: db) == .plaintext else { continue }
        if name == estateName {
            estateCounts = try convertScratchToEncrypted(plaintextDB: db, key: key)
        } else {
            try convertAuxiliaryDatabase(plaintextDB: db, key: key)
        }
    }

    guard let estateCounts else {
        throw MCPError(description: "no plaintext estate database found in \(scratchDir.path)")
    }
    return estateCounts
}

/// Converts a database that is not the estate.
///
/// Same physical clone and the same integrity and schema checks, but not the
/// four gated row counts: those name tables that exist only in the estate.
/// Skipping them is not skipping verification — the table-by-table comparison
/// covers whatever tables this database does have.
func convertAuxiliaryDatabase(plaintextDB: URL, key: Data) throws {
    let encrypted = plaintextDB.deletingLastPathComponent()
        .appendingPathComponent(plaintextDB.lastPathComponent + ".encrypted")
    EstateEncryptionMigrator.removeDatabase(at: encrypted)
    try EstateEncryptionMigrator.exportEncryptedCopy(from: plaintextDB, to: encrypted, key: key)

    let keyHex = EstateEncryptionMigrator.keyHex(key)
    do {
        try EstateEncryptionMigrator.assertIntegrity(atPath: encrypted.path, keyHex: keyHex)
        let sourceSchema = try EstateEncryptionMigrator.schemaObjects(atPath: plaintextDB.path)
        let copySchema = try EstateEncryptionMigrator.schemaObjects(
            atPath: encrypted.path, keyHex: keyHex)
        let sourceTables = try EstateEncryptionMigrator.allTableCounts(atPath: plaintextDB.path)
        let copyTables = try EstateEncryptionMigrator.allTableCounts(
            atPath: encrypted.path, keyHex: keyHex)
        guard sourceSchema == copySchema, sourceTables == copyTables else {
            throw MCPError(description:
                "auxiliary database \(plaintextDB.lastPathComponent) did not survive conversion")
        }
    } catch {
        EstateEncryptionMigrator.removeDatabase(at: encrypted)
        throw error
    }

    EstateEncryptionMigrator.removeDatabase(at: plaintextDB)
    try FileManager.default.moveItem(at: encrypted, to: plaintextDB)
}

/// Converts a restored working copy to an encrypted database in place.
///
/// The conversion is `EstateEncryption.exportEncryptedCopy` — the same
/// physical `sqlcipher_export()` clone the product performs — followed by the
/// same verification the product runs before it swaps: an integrity check, a
/// schema-complete table comparison, and the four headline counts.
///
/// A conversion that fails either check throws. The caller records the failure
/// for that database and takes no measurement from it, because a cell measured
/// on an unverified copy is not a measurement of the encrypted configuration.
func convertScratchToEncrypted(
    plaintextDB: URL, key: Data
) throws -> EstateEncryptionMigrator.VerificationCounts {
    let encrypted = plaintextDB.deletingLastPathComponent()
        .appendingPathComponent(plaintextDB.lastPathComponent + ".encrypted")
    EstateEncryptionMigrator.removeDatabase(at: encrypted)

    try EstateEncryptionMigrator.exportEncryptedCopy(
        from: plaintextDB, to: encrypted, key: key)
    let counts = try EstateEncryptionMigrator.verifyEncryptedCopy(
        original: plaintextDB, encryptedCopy: encrypted, key: key)

    // Replace the plaintext file with its verified encrypted twin so the
    // scratch directory is a working encrypted estate the server can serve.
    EstateEncryptionMigrator.removeDatabase(at: plaintextDB)
    try FileManager.default.moveItem(at: encrypted, to: plaintextDB)
    return counts
}

/// A deterministic 32-byte key for a matrix run.
///
/// Derived from the run seed rather than minted randomly, and never written to
/// a keychain: the encrypted cells exist for the length of one measurement and
/// are deleted with the working copy. Recording the seed in the report is
/// enough to recreate the key.
/// Hands the served estate the key a conversion used, or refuses.
///
/// The install key file is the Rust port's mechanism and exists only in a
/// harness build of the product (`MOOTX01_HARNESS_KEYFILE`); the Keychain is
/// never touched and the file dies with the scratch directory. Without a
/// harness build the server would generate its own key and could not open a
/// database converted here, so the lane refuses rather than publish an
/// encrypted row that no query ever touched. `lane` names the caller in the
/// refusal ("the encrypted cell", "the encrypted timing posture").
func writeHarnessInstallKey(_ key: Data, inDirectory directory: URL, lane: String) throws {
    #if MOOTX01_HARNESS_KEYFILE
    try EstateEncryptionMigrator.writeInstallKey(key, inDirectory: directory)
    #else
    throw MCPError(description: """
        \(lane) needs a harness build: rebuild the harness and the mootx01 \
        binary with -Xswiftc -DMOOTX01_HARNESS_KEYFILE (make matrix does \
        this), or the server cannot open the database this run converted
        """)
    #endif
}

func matrixKey(seed: UInt64) -> Data {
    var bytes = [UInt8]()
    var state = seed &+ 0x9E37_79B9_7F4A_7C15
    while bytes.count < 32 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        withUnsafeBytes(of: state.bigEndian) { bytes.append(contentsOf: $0) }
    }
    return Data(bytes.prefix(32))
}

// MARK: - The run

/// One measured cell's result row.
struct MatrixRow: Sendable, Codable {
    let database: String
    let encryption: String
    let backend: String
    let port: String
    /// Row counts verified for this cell. Present for encrypted cells, where
    /// the conversion is verified before measurement.
    let verifiedDrawers: Int?
    /// Rows probed by the query pass.
    let probes: Int?
    /// Fraction of probes whose own row returned at any scored depth.
    let selfRecall: Double?
    /// Fraction of probes whose own row returned first.
    let selfRecallAtOne: Double?
    /// Probes whose ranked result list differs from the plaintext cell's.
    /// Zero on the plaintext cell itself, which is the comparison basis.
    let divergenceFromPlaintext: Int?
    /// Absent on success. Present when the cell was not measured.
    let failure: String?

    // Wire keys are snake_case, as in every other report this suite writes.
    // This lane emitted camelCase until 2026-08-16, so a reader parsing the
    // suite had to special-case one file.
    enum CodingKeys: String, CodingKey {
        case database
        case encryption
        case backend
        case port
        case verifiedDrawers          = "verified_drawers"
        case probes
        case selfRecall               = "self_recall"
        case selfRecallAtOne          = "self_recall_at_one"
        case divergenceFromPlaintext  = "divergence_from_plaintext"
        case failure
    }
}

/// The matrix report: provenance envelope plus the measured rows.
///
/// The rows alone were written until 2026-08-16, which made this the only lane
/// whose figures could not be traced to a binary, a machine state, or the
/// protocol version that governed them — the seven fields BENCHMARK_METHOD.md
/// §6 requires of every report. `RunEnvironment` carries all of them and is
/// what every other lane already emits.
struct MatrixReport: Sendable, Codable {
    /// The estate schema the harness was built against, stamped into every
    /// report so the results record can carry the column without anyone typing
    /// it (BENCHMARK_PROTOCOL §9). Constant rather than a parameter: a report
    /// describes the run that produced it, and that run's artifacts were
    /// validated against this exact value on open, so a mismatch fails the run
    /// rather than reaching a report.
    ///
    /// Declared with its value, so it is always encoded and never decoded: an
    /// older report that predates the field still reads.
    let estateSchemaVersion: String = currentEstateSchemaVersion

    let benchmarkProtocolVersion: String
    let runEnvironment: RunEnvironment
    /// Seed governing probe selection and the conversion key.
    let seed: UInt64
    /// Rows probed per cell.
    let probes: Int
    /// Scored depth for the probe pass.
    let k: Int
    /// Which set was measured, or all sets when no lane filter was given.
    let lane: String?
    /// Databases the run covered, and how many carried no measurement.
    let databases: Int
    let failures: Int
    let rows: [MatrixRow]

    enum CodingKeys: String, CodingKey {
        case estateSchemaVersion     = "estate_schema_version"
        case benchmarkProtocolVersion = "benchmark_protocol_version"
        case runEnvironment           = "run_environment"
        case seed
        case probes
        case k
        case lane
        case databases
        case failures
        case rows
    }
}

/// `mcp-benchmarker matrix --cache-dir <dir> --mootx01-binary <path>`
///
/// Processes one prebuilt database at a time: restore a working copy, measure
/// the plaintext cell, convert a second copy and measure the encrypted cell,
/// then delete both before the next database begins.
///
/// The conversion is the product's, through the shared EstateEncryption
/// library. It is verified before any measurement and is never timed.
func runMatrix(_ args: [String]) async throws {
    guard let storeRaw = optionValue("--cache-dir", in: args) else {
        throw MCPError(description: "matrix requires --cache-dir")
    }
    guard let mootBinary = optionValue("--mootx01-binary", in: args) else {
        throw MCPError(description: "matrix requires --mootx01-binary")
    }
    let storeDir = URL(fileURLWithPath: storeRaw)
    let lane = optionValue("--lane", in: args)
    // Declared machine state, recorded in the report exactly as the other
    // measured lanes record it. "unspecified" when the caller did not say.
    let runMode = optionValue("--run-mode", in: args) ?? "unspecified"
    let limit = try parseLimitOption(in: args)
    let seed = optionValue("--seed", in: args).flatMap(UInt64.init) ?? 20_260_816
    // Rows probed per cell. The probe is a fixed cost per database, and the
    // matrix runs over thousands of them, so it is bounded rather than full.
    let probeCount = optionValue("--probes", in: args).flatMap(Int.init) ?? 25
    let topK = optionValue("--k", in: args).flatMap(Int.init) ?? 10
    let outDir = try resolvedOutputDirectory(in: args)
    // Serial shared with this run's params sidecar, so a report and the
    // parameters that produced it are one pair by name.
    let runSerial = resolveRunSerial(args)
    // The arm names the measured scope. An unfiltered run measures every set
    // in the store, which is a different scope from any single set, so it is
    // named `allsets` rather than borrowing a set's name.
    let arm = lane ?? "allsets"

    var targets = try discoverMatrixTargets(storeDir: storeDir, runKeyFilter: lane)
    guard !targets.isEmpty else {
        throw MCPError(description:
            "matrix found no prebuilt databases under \(storeDir.path)"
            + (lane.map { " matching lane '\($0)'" } ?? "")
            + ". Build a set first (make artifacts).")
    }
    if let limit, limit < targets.count { targets = Array(targets.prefix(limit)) }

    let key = matrixKey(seed: seed)
    let sets = Set(targets.map(\.runKey)).sorted()
    FileHandle.standardError.write(Data("""
        [matrix] \(targets.count) databases across \(sets.count) set(s)
        \(sets.map { "[matrix]   \($0)" }.joined(separator: "\n"))

        """.utf8))

    var rows: [MatrixRow] = []
    var failures = 0

    for (index, target) in targets.enumerated() {
        let scratch = URL(fileURLWithPath:
            "/tmp/matrix-bench-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))")
        // The working copy goes only when the cell finished. Nothing
        // irreplaceable lives here — the stored artifact is the durable copy
        // and this is a clone of it — but a failed cell's estate is the
        // evidence for diagnosing why, and deleting evidence on the error path
        // is the habit that cost us a landscape on 2026-08-17.
        var cellCompleted = false
        defer {
            if cellCompleted { try? FileManager.default.removeItem(at: scratch) }
            else { keepScratchEstateOnFailure(scratch, lane: "matrix") }
        }

        do {
            // The plaintext working copy. The stored database is never served.
            try cloneOrCopyItem(
                at: target.entry.appendingPathComponent("estate"), to: scratch)

            // The probe set comes from the database's own manifest, so the
            // pass needs no corpus and is identical across every set.
            let probeIDs = matrixProbeIDs(
                manifestUUIDs: matrixManifestUUIDs(entry: target.entry),
                sampleSize: probeCount)

            // Plaintext cell.
            let plainResult = try await matrixServeAndProbe(
                scratchDir: scratch, mootBinary: mootBinary,
                posture: .plaintextTransient, probeIDs: probeIDs, k: topK)
            rows.append(MatrixRow(
                database: target.label, encryption: "unencrypted", backend: "disk",
                port: "swift", verifiedDrawers: nil,
                probes: plainResult.probes, selfRecall: plainResult.selfRecall,
                selfRecallAtOne: plainResult.selfRecallAtOne,
                divergenceFromPlaintext: 0, failure: nil))

            // Encrypted cell: convert a second copy, verify, then probe it the
            // same way. The conversion is not timed; only retrieval is compared.
            let encryptedScratch = URL(fileURLWithPath: scratch.path + "-encrypted")
            // Same rule as the plaintext copy: kept when the cell fails, so
            // the converted estate is available to diagnose the failure.
            //
            // Its OWN flag, not the loop body's. This defer runs when the `do`
            // block ends, which is BEFORE `cellCompleted` is set at the end of
            // the iteration, so reading that flag here reported every healthy
            // cell as a failure and kept its copy — 6.8 MB leaked per database,
            // across 5,867 of them, with a false notice for each.
            var encryptedCellCompleted = false
            defer {
                if encryptedCellCompleted {
                    try? FileManager.default.removeItem(at: encryptedScratch)
                } else {
                    keepScratchEstateOnFailure(encryptedScratch, lane: "matrix-encrypted")
                }
            }
            try cloneOrCopyItem(at: scratch, to: encryptedScratch)
            // Every database in the directory is converted, not just the
            // estate: the product opens the queue beside it under the same
            // posture, and a plaintext queue next to an encrypted estate is
            // not openable.
            let counts = try convertScratchDirectoryToEncrypted(
                scratchDir: encryptedScratch, key: key)

            // Hand the server the key this conversion used, or refuse (see
            // writeHarnessInstallKey for why a non-harness build cannot serve it).
            try writeHarnessInstallKey(key, inDirectory: encryptedScratch, lane: "the encrypted cell")

            let encryptedResult = try await matrixServeAndProbe(
                scratchDir: encryptedScratch, mootBinary: mootBinary,
                posture: .encryptedEphemeral, probeIDs: probeIDs, k: topK)
            rows.append(MatrixRow(
                database: target.label, encryption: "encrypted", backend: "disk",
                port: "swift", verifiedDrawers: counts.drawers,
                probes: encryptedResult.probes,
                selfRecall: encryptedResult.selfRecall,
                selfRecallAtOne: encryptedResult.selfRecallAtOne,
                divergenceFromPlaintext: matrixCellDivergence(plainResult, encryptedResult),
                failure: nil))
            encryptedCellCompleted = true
        } catch {
            failures += 1
            rows.append(MatrixRow(
                database: target.label, encryption: "encrypted", backend: "disk",
                port: "swift", verifiedDrawers: nil, probes: nil, selfRecall: nil,
                selfRecallAtOne: nil, divergenceFromPlaintext: nil,
                failure: "\(error)"))
            FileHandle.standardError.write(Data(
                "[matrix] FAILED \(target.label): \(error)\n".utf8))
        }

        if (index + 1) % 25 == 0 || index + 1 == targets.count {
            FileHandle.standardError.write(Data(
                "[matrix] \(index + 1)/\(targets.count) databases\n".utf8))
        }
        cellCompleted = true
    }

    if let outDir {
        var matrixRunEnv = RunEnvironment.collect(
            mootx01BinaryPath: mootBinary, runMode: runMode)
        stampTestIdentity(&matrixRunEnv, test: "matrix", arm: arm, serial: runSerial)
        let report = MatrixReport(
            benchmarkProtocolVersion: benchmarkProtocolVersion,
            runEnvironment: matrixRunEnv,
            seed: seed,
            probes: probeCount,
            k: topK,
            lane: lane,
            databases: targets.count,
            failures: failures,
            rows: rows)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // `<test>-<arm>-<serial>`: the arm is the matrix set. Before 2026-08-17
        // every arm wrote `matrix-report-seed<seed>.json` — one path for all
        // four — so the last arm of a pass silently replaced the others, and
        // the field identifying the arm lived inside the replaced file.
        let recordName = recordFilename(test: "matrix", arm: arm, serial: runSerial)
        try writeRecordNeverOverwrite(
            encoder.encode(report),
            to: outDir.appendingPathComponent(recordName))
        try appendToLedger(
            "matrix\t\(arm)\t\(recordName)\tdatabases=\(targets.count)\tfailures=\(failures)",
            at: outDir.appendingPathComponent("records.tsv"))
    }

    FileHandle.standardError.write(Data("""

        [matrix] complete
          databases: \(targets.count)
          rows:      \(rows.count)
          failures:  \(failures)

        """.utf8))

    if failures > 0 {
        // A partially measured set is mixed-provenance: some cells carry a
        // verified conversion and some carry none. Exit non-zero so make stops.
        throw MCPError(description:
            "matrix left \(failures) database(s) unmeasured; the set is mixed-provenance "
            + "and must not be reported until they succeed")
    }
}


// MARK: - Cross-port conformance entry point

/// `mcp-benchmarker convert --source <db> --dest <db> --key-hex <hex>`
///
/// One-shot conversion, for cross-port conformance runs: the Rust crate's
/// `examples/convert.rs` takes the same three arguments and performs the same
/// conversion, so both ports can be driven over one input and their outputs
/// compared.
///
/// It converts and reports the verified counts. It does nothing else, and it
/// is not part of any benchmark.
func runConvert(_ args: [String]) async throws {
    guard let source = optionValue("--source", in: args),
          let keyHex = optionValue("--key-hex", in: args)
    else {
        throw MCPError(description: "convert requires --source and --key-hex")
    }
    let dest = optionValue("--dest", in: args) ?? ""
    if !flagPresent("--verify", in: args), dest.isEmpty {
        throw MCPError(description: "convert requires --dest unless --verify is passed")
    }
    var key = Data()
    var idx = keyHex.startIndex
    while idx < keyHex.endIndex {
        let next = keyHex.index(idx, offsetBy: 2, limitedBy: keyHex.endIndex) ?? keyHex.endIndex
        guard let byte = UInt8(keyHex[idx..<next], radix: 16) else {
            throw MCPError(description: "--key-hex is not hexadecimal")
        }
        key.append(byte)
        idx = next
    }

    let sourceURL = URL(fileURLWithPath: source)
    let destURL = URL(fileURLWithPath: dest)

    // --verify reads an already-encrypted database and reports its counts,
    // without converting anything. It is how this port is shown reading the
    // other port's output in a conformance run.
    if flagPresent("--verify", in: args) {
        let counts = try EstateEncryptionMigrator.verificationCounts(
            atPath: sourceURL.path, keyHex: EstateEncryptionMigrator.keyHex(key))
        try EstateEncryptionMigrator.assertIntegrity(
            atPath: sourceURL.path, keyHex: EstateEncryptionMigrator.keyHex(key))
        print("\(counts)")
        return
    }

    EstateEncryptionMigrator.removeDatabase(at: destURL)
    try EstateEncryptionMigrator.exportEncryptedCopy(from: sourceURL, to: destURL, key: key)
    let counts = try EstateEncryptionMigrator.verificationCounts(
        atPath: destURL.path, keyHex: EstateEncryptionMigrator.keyHex(key))
    print("\(counts)")
}

// MARK: - The query pass

/// One cell's retrieval measurement.
///
/// The matrix asks whether storage changes retrieval, so the measurement is
/// deliberately corpus-free: it probes the database with its own rows. That
/// keeps one comparison valid across every set — a MemBench database and a
/// LoCoMo database are measured the same way — and it needs no scorer, no
/// question file, and no evidence labels.
///
/// For a deterministic sample of stored ids:
///   1. fetch the row by id, which yields its stored text
///   2. query with that text
///   3. record whether the row's own id came back, and at which rank
///
/// Self-recall is not a quality claim about the product. It is a fixed probe
/// applied identically to both cells, so a difference between the cells is
/// attributable to storage. Two cells agreeing is the expected result; the
/// figure exists so that disagreement is visible rather than assumed absent.
struct MatrixQueryResult: Sendable, Codable {
    /// Rows probed.
    let probes: Int
    /// Probes whose own id returned at any scored depth.
    let found: Int
    /// Probes whose own id returned first.
    let foundAtOne: Int
    /// Ordered result ids per probe, in probe order. This is what makes two
    /// cells comparable beyond a scalar: identical ranked lists mean storage
    /// changed nothing, and a scalar match alone would not show reordering.
    let resultIDs: [[String]]

    var selfRecall: Double { probes == 0 ? 0 : Double(found) / Double(probes) }
    var selfRecallAtOne: Double { probes == 0 ? 0 : Double(foundAtOne) / Double(probes) }
}

/// Picks a deterministic sample of stored ids from a database's manifest.
///
/// Sampled by stride rather than by a random draw so the same database always
/// yields the same probes, on both ports, with no RNG to keep in step. The
/// stride spreads the sample across ingest order instead of taking a prefix,
/// which would probe only the oldest rows.
func matrixProbeIDs(manifestUUIDs: [String], sampleSize: Int) -> [String] {
    guard !manifestUUIDs.isEmpty, sampleSize > 0 else { return [] }
    if manifestUUIDs.count <= sampleSize { return manifestUUIDs }
    let stride = Double(manifestUUIDs.count) / Double(sampleSize)
    var picked: [String] = []
    picked.reserveCapacity(sampleSize)
    for i in 0..<sampleSize {
        let index = min(Int(Double(i) * stride), manifestUUIDs.count - 1)
        picked.append(manifestUUIDs[index])
    }
    return picked
}

/// Reads the stored row ids out of a prebuilt database's manifest.
///
/// The manifest is lane-shaped, so the uuid field is read generically rather
/// than through a lane's own type. A manifest whose entries carry no uuid
/// yields no probes, and the cell records zero rather than failing the run:
/// the conversion result is still valid and still worth recording.
func matrixManifestUUIDs(entry: URL) -> [String] {
    let url = entry.appendingPathComponent("manifest.json")
    guard let data = try? Data(contentsOf: url),
          let parsed = try? JSONSerialization.jsonObject(with: data),
          let rows = parsed as? [[String: Any]]
    else { return [] }
    return rows.compactMap { $0["uuid"] as? String }
}

/// Runs the query pass against one served database.
func matrixQueryPass(
    client: MCPClient, verbMap: EndpointConfig.VerbMap, probeIDs: [String], k: Int
) async -> MatrixQueryResult {
    var found = 0
    var foundAtOne = 0
    var resultIDs: [[String]] = []

    for id in probeIDs {
        // 1. The row's own stored text, hydrated by id. moot_memory_get is
        //    used directly rather than verbMap.fetch, which the moot verb maps
        //    leave nil: the lanes never needed a by-id fetch, so nothing filled
        //    it in, and relying on it made this loop exit before its first
        //    probe.
        let fetched = try? await client.callTool(
            AriaV2Surface.memoryGet,
            arguments: batchHydrateArgs(ids: [id], depth: .full),
            format: .mootV2,
            deadline: MCPDeadline.interactive)
        let text = fetched?.textBlocks.joined(separator: " ") ?? ""
        guard !text.isEmpty else { resultIDs.append([]); continue }

        // 2. Query with that text. The probe is the row itself, so a store
        //    that can find its own rows returns this id.
        let args = AriaV2Surface.memorySearchArgs(verbMap: verbMap, query: String(text.prefix(512)))
        let queried = try? await client.callTool(
            verbMap.query, arguments: args, format: .mootV2,
            deadline: MCPDeadline.interactive)
        let ids = Array((queried?.orderedIDs ?? []).prefix(k))
        resultIDs.append(ids)

        if let rank = ids.firstIndex(of: id) {
            found += 1
            if rank == 0 { foundAtOne += 1 }
        }
    }

    return MatrixQueryResult(
        probes: probeIDs.count, found: found, foundAtOne: foundAtOne, resultIDs: resultIDs)
}

/// Compares two cells' ranked result lists.
///
/// Returns the number of probes whose ranked list differs. Zero means storage
/// changed nothing observable about retrieval for this database; any other
/// number names how many probes diverged, which a scalar recall comparison
/// would hide when two cells lose and gain the same count.
func matrixCellDivergence(_ a: MatrixQueryResult, _ b: MatrixQueryResult) -> Int {
    guard a.resultIDs.count == b.resultIDs.count else {
        return max(a.resultIDs.count, b.resultIDs.count)
    }
    return zip(a.resultIDs, b.resultIDs).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
}

/// Serves one scratch database and runs the query pass against it.
///
/// The server is started and stopped per cell. Two cells are never served at
/// once: they would contend, and the point of the comparison is that only
/// storage differs between them.
func matrixServeAndProbe(
    scratchDir: URL, mootBinary: String, posture: ScratchEstatePosture,
    probeIDs: [String], k: Int
) async throws -> MatrixQueryResult {
    guard !probeIDs.isEmpty else {
        return MatrixQueryResult(probes: 0, found: 0, foundAtOne: 0, resultIDs: [])
    }
    let endpoint = try lmebEndpointConfig(
        scratchDir: scratchDir, mootBinaryPath: mootBinary, posture: posture)
    let client = MCPClient(endpoint: endpoint)
    try await client.connect()
    defer { Task { await client.disconnect() } }
    return await matrixQueryPass(
        client: client, verbMap: endpoint.verbMap, probeIDs: probeIDs, k: k)
}
