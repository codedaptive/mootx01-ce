// RecordWriter.swift — record naming and no-clobber record writes.
//
// Two mandates live here, both from 2026-08-17, both paid for in lost
// measurement time.
//
// NAMING. Every record is `<test>-<arm>-<serial>.<ext>`, and a report and its
// params sidecar share one serial. The arm and the serial belong in the NAME,
// not only in the payload: on 2026-08-17 the four matrix arms all resolved to
// `matrix-report-seed20260816.json`, and the field that distinguished them
// (`coverage.lane`) lived inside the file being replaced. A collision that
// overwrites its own evidence cannot be detected by reading the survivor.
// Cost: 4h19m of matrix measurement (lmeb 253 min, locomo 6 min), and a
// MemBench report that would have lost its ThirdAgent arm to FirstAgent on the
// next run.
//
// NO OVERWRITE. A record write refuses to replace an existing file. It is
// created with O_EXCL and a collision raises rather than clobbers, because a
// benchmark record is measurement, not cache: the only correct response to
// "this path is taken" is to stop and be told. This deliberately removes
// `options: .atomic`, which replaced the file in place — the mechanism by
// which the loss above was silent.

import Foundation

// MARK: - Serial

/// Resolves the run serial that ties a report to its params sidecar.
///
/// The Makefile passes `--run-id <serial>` so that every record of one pass
/// carries the pass's serial, matching the output directory name. A hand
/// invocation with no flag gets a UTC timestamp, so a record is never written
/// without a serial at all.
///
/// - Parameter args: The command's raw argument list.
/// - Returns: The serial to embed in every record name this run writes.
public func resolveRunSerial(_ args: [String]) -> String {
    if let explicit = optionValue("--run-id", in: args), !explicit.isEmpty {
        return explicit
    }
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    fmt.timeZone = TimeZone(identifier: "UTC")
    fmt.locale = Locale(identifier: "en_US_POSIX")
    return fmt.string(from: Date())
}

// MARK: - Naming

/// Builds a record filename in the mandated `<test>-<arm>-<serial>` shape.
///
/// The arm is the value that distinguishes two runs of the same lane inside
/// one pass — the matrix set, the MemBench agent, the LongMemEval variant.
/// A lane with a single arm still names it (LoCoMo's `all10`, LMEB's `all6`)
/// so that a record's scope is readable without opening the file, and so that
/// narrowing the scope later cannot silently reuse a wider scope's name.
///
/// - Parameters:
///   - test: Lane name, e.g. `matrix`, `lmeb`.
///   - arm: The lane's discriminator, e.g. `lme-s`, `ThirdAgent`, `all6`.
///   - serial: The run serial from `resolveRunSerial`.
///   - suffix: Optional trailing tag, e.g. `params`. Empty for the report.
///   - ext: File extension without the dot. Defaults to `json`.
/// - Returns: The filename, with any path separators in `arm` flattened —
///   matrix arms carry set names that may contain `/`, which would otherwise
///   silently write into a subdirectory that does not exist.
public func recordFilename(test: String,
                           arm: String,
                           serial: String,
                           suffix: String = "",
                           ext: String = "json") -> String {
    let safeArm = arm.replacingOccurrences(of: "/", with: "_")
    var name = "\(test)-\(safeArm)-\(serial)"
    if !suffix.isEmpty { name += "-\(suffix)" }
    return "\(name).\(ext)"
}

// MARK: - Testname-arm-serial stamping

/// Stamps the testname-arm-serial triple onto a timing-lane RunEnvironment.
///
/// Call AFTER `collect()`, BEFORE building the report or encoding the record.
/// The three values must match the corresponding components passed to
/// `recordFilename(test:arm:serial:)` for the same record; this is the
/// discipline that makes every record self-identifying without its filename.
///
/// - Parameters:
///   - env: The RunEnvironment to stamp. Modified in place.
///   - test: The `test` component of the record filename (e.g. "matrix", "timing").
///   - arm: The `arm` component of the record filename (e.g. "allsets", "disk").
///   - serial: The `serial` component of the record filename from `resolveRunSerial`.
public func stampTestIdentity(
    _ env: inout RunEnvironment,
    test: String,
    arm: String,
    serial: String
) {
    env.benchmarkTestName  = test
    env.benchmarkArm       = arm
    env.benchmarkRunSerial = serial
}

/// Stamps the testname-arm-serial triple onto an accuracy-lane IdentityEnvironment.
///
/// Call AFTER `collect()`, BEFORE building the report or encoding the record.
/// The three values must match the corresponding components passed to
/// `recordFilename(test:arm:serial:)` for the same record.
///
/// - Parameters:
///   - env: The IdentityEnvironment to stamp. Modified in place.
///   - test: The `test` component of the record filename (e.g. "lmeb", "locomo").
///   - arm: The `arm` component of the record filename (e.g. "all6", "all10").
///   - serial: The `serial` component of the record filename from `resolveRunSerial`.
public func stampTestIdentity(
    _ env: inout IdentityEnvironment,
    test: String,
    arm: String,
    serial: String
) {
    env.benchmarkTestName  = test
    env.benchmarkArm       = arm
    env.benchmarkRunSerial = serial
}

/// Optional overload: stamps the triple when the environment is stored as `IdentityEnvironment?`.
///
/// No-ops when `env` is nil. Use this at the CLI config layer where `runEnvironment`
/// is `IdentityEnvironment?` — the collect call always produces a non-nil value, so the
/// no-op path is never reached in practice; the overload exists to avoid requiring a
/// force-unwrap at every config-level stamp site.
public func stampTestIdentity(
    _ env: inout IdentityEnvironment?,
    test: String,
    arm: String,
    serial: String
) {
    env?.benchmarkTestName  = test
    env?.benchmarkArm       = arm
    env?.benchmarkRunSerial = serial
}

// MARK: - No-clobber write

/// Writes a record, refusing to replace an existing file.
///
/// Uses `O_CREAT | O_EXCL` so the create-or-fail decision is the kernel's and
/// not a check-then-write race. On collision it throws with the path named, so
/// the operator learns which record was about to be destroyed rather than
/// discovering later that it was.
///
/// - Parameters:
///   - data: The encoded record.
///   - url: Destination path. The parent directory is created when absent.
/// - Throws: `MCPError` when the path is taken, or when the write fails.
public func writeRecordNeverOverwrite(
    _ data: Data,
    to url: URL,
    permissions: mode_t = 0o644
) throws {
    // Create the parent directory tree before attempting the O_EXCL open.
    // `withIntermediateDirectories: true` is idempotent — no error when it
    // already exists.  Separating parent creation from file creation preserves
    // the never-overwrite guarantee: the O_CREAT|O_EXCL open still fails if
    // the file is already there.
    let parent = url.deletingLastPathComponent()
    do {
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true)
    } catch {
        throw MCPError(description:
            "cannot create parent directory for \(url.path): \(error.localizedDescription)")
    }
    let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, permissions)
    if fd < 0 {
        let err = errno
        if err == EEXIST {
            throw MCPError(description:
                "record already exists and records are never overwritten: \(url.path) "
                + "— a second run of this arm in one pass must carry its own serial")
        }
        throw MCPError(description:
            "cannot create record \(url.path): \(String(cString: strerror(err)))")
    }
    defer { close(fd) }

    // Write the whole buffer. `write(2)` may return a short count on a large
    // report (the MemBench report is ~53 MB), so the loop is required, not
    // defensive decoration.
    try data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                throw MCPError(description:
                    "write failed for \(url.path): \(String(cString: strerror(errno)))")
            }
            offset += written
        }
    }
}

/// Appends one line to a run-scoped ledger, creating it when absent.
///
/// The append path is separate from the report path on purpose. A report is
/// written once and never replaced; a ledger accumulates one line per record
/// so a pass leaves a readable index of what it produced, which is what makes
/// a smoke pass checkable in one read rather than a directory listing.
///
/// - Parameters:
///   - line: The line to append. A newline is added when absent.
///   - url: Ledger path. Created with 0644 when it does not exist.
/// - Throws: `MCPError` when the ledger cannot be opened or written.
public func appendToLedger(_ line: String, at url: URL) throws {
    let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    if fd < 0 {
        throw MCPError(description:
            "cannot open ledger \(url.path): \(String(cString: strerror(errno)))")
    }
    defer { close(fd) }
    let payload = line.hasSuffix("\n") ? line : line + "\n"
    let bytes = Array(payload.utf8)
    var offset = 0
    while offset < bytes.count {
        let written = bytes.withUnsafeBytes {
            write(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset)
        }
        if written < 0 {
            if errno == EINTR { continue }
            throw MCPError(description:
                "ledger append failed for \(url.path): \(String(cString: strerror(errno)))")
        }
        offset += written
    }
}
