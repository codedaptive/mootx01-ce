// RunEnvironment.swift
//
// Machine and mootx01 version metadata captured once per benchmark subcommand
// invocation and embedded in every report JSON as "run_environment". Enables
// attribution of benchmark results to a specific hardware configuration and
// binary version when reports arrive from satellite machines.

import Foundation
import Darwin
import CryptoKit

/// Version of the measurement protocol that governs runs produced by this
/// build of the harness.
///
/// Stamped into every report (C7) so a figure can be traced to the rules that
/// defined how it was measured. The value is declared here rather than read
/// from a document: a report has to carry its protocol version even when the
/// governing document is not distributed alongside the harness. Bump it in the
/// same change that changes the rules.
public let benchmarkProtocolVersion = "v0.1"

/// Machine profile and mootx01 version metadata for benchmark report provenance.
///
/// Embedded in every report JSON so results from satellite machines can be
/// attributed to the hardware and software that produced them without requiring
/// a re-run. All fields degrade gracefully: individual collection failures record
/// "unknown" or 0 rather than aborting the benchmark.
///
/// Declared public so it can be a property of the public GauntletRunReport struct.
public struct RunEnvironment: Codable, Sendable {
    /// DNS or NetBIOS hostname of the machine (ProcessInfo.hostName).
    public let hostname: String
    /// hw.model sysctl string identifying the machine model (e.g. "Mac16,11").
    public let modelIdentifier: String
    /// Marketing model name from system_profiler (e.g. "MacBook Air (M4, 2025)").
    /// Falls back to modelIdentifier when system_profiler is unavailable.
    public let modelName: String
    /// CPU or SoC brand string from sysctl (e.g. "Apple M4").
    public let chipName: String
    /// Physical RAM in bytes (ProcessInfo.physicalMemory).
    public let ramBytes: UInt64
    /// Boot-volume total capacity in bytes. 0 when FileManager query fails.
    public let diskBytes: UInt64
    /// Human-readable macOS version string from ProcessInfo.
    public let macosVersion: String
    /// Major.minor version string parsed from `mootx01 --version` (e.g. "1.1").
    /// Strips patch, prerelease suffix, and edition tag (CE/EE).
    /// "unknown" when binary path is nil or the call/parse fails.
    public let mootx01Version: String
    /// Build date parsed from `mootx01 --version` output (e.g. "2026-08-05").
    /// "unknown" when binary path is nil or the call/parse fails.
    public let mootx01BuildDate: String
    /// Short git SHA of the WORKING TREE at report time (`git rev-parse
    /// --short HEAD` beside the binary). ADVISORY ONLY — it has been observed
    /// to diverge from the commit the measured binary was built from (finding
    /// H9), so the field is NAMED for what it is; the citable binary identity
    /// is `mootx01BinarySha256`.
    public let mootx01WorkingTreeHead: String
    /// SHA-256 content digest of the measured mootx01 binary file (lowercase
    /// hex). Identifies the exact binary bytes measured — unlike the git head,
    /// it cannot drift when the working tree moves after the build (C7/H9).
    /// "unknown" when the binary path is nil or unreadable.
    public let mootx01BinarySha256: String
    /// Machine-quiet declaration for this run (`--run-mode quiet|contended`).
    /// "unspecified" when the flag was not passed. Recorded verbatim: a latency
    /// figure taken under contention is not comparable to a quiet-machine one.
    public let runMode: String
    /// Version of BENCHMARK_PROTOCOL.md governing this run (`benchmarkProtocolVersion`).
    public let protocolVersion: String
    /// 1-minute load average SAMPLED at collect time (getloadavg). MEASURED,
    /// not declared: H10's purpose is that a figure from a busy machine be
    /// distinguishable from a clean one, and a declared flag that defaults to
    /// "unspecified" would read "unspecified" on every real run. Interpret
    /// against `logicalCpus` (load/cores ≈ 1.0 is saturation). -1 when
    /// sampling failed.
    public let loadAverage1m: Double
    /// Logical CPU count (activeProcessorCount) — the denominator that makes
    /// `loadAverage1m` interpretable across machines.
    public let logicalCpus: Int
    // ── testname-arm-serial discipline ──────────────────────────────────────
    // These three fields embed the components that are ALSO encoded in the
    // record filename (`recordFilename(test:arm:serial:)`), so the row is
    // self-identifying without the filename. The writer sets them after collect().
    // nil = not yet set by the writer (absent from JSON, backward-compatible).

    /// Test name component of this record (e.g. "gauntlet"). Mirrors the
    /// `test` parameter passed to `recordFilename(test:arm:serial:)`.
    /// Wire key: benchmark_test_name. Set by the writer, not collect().
    public var benchmarkTestName: String? = nil
    /// Active benchmark arm name for this record (e.g. "product-default",
    /// "no-encoder", or a mining arm label). Resolved via `resolveActiveArmName()`
    /// and mirrors the `arm` component of the record filename.
    /// Wire key: benchmark_arm. Set by the writer, not collect().
    public var benchmarkArm: String? = nil
    /// Run serial component of this record (e.g. "001"). Mirrors the `serial`
    /// parameter passed to `recordFilename(test:arm:serial:)`.
    /// Wire key: benchmark_run_serial. Set by the writer, not collect().
    public var benchmarkRunSerial: String? = nil
    /// Product-configuration arm for this record. Resolved by collect() via
    /// `resolveActiveArmName()` and records WHICH PRODUCT CONFIGURATION ran.
    /// Orthogonal to `benchmarkArm` (lane arm, set by the writer), which
    /// records WHICH CORPUS SLICE ran. A row carries both so the two dimensions
    /// are independently readable.
    /// Wire key: benchmark_register_arm. Set by collect(), not the writer.
    public var benchmarkRegisterArm: String? = nil

    // ── converter identity ───────────────────────────────────────────────────
    /// ContextDistillLib recall converter identity reported by the product
    /// binary's `--version` output for this run. Defaults to "unknown" only
    /// when no binary was supplied or an older binary omits the recall line.
    /// Wire key: converter_id. Set by collect().
    /// Example values: "complete-form@complete-form-visible-v6",
    ///                 "intent-span-v23-attributed@intent-span-v23.2-attributed-prose".
    public var converterID: String? = nil
    /// ContextDistillLib recall converter version corresponding to `converterID`,
    /// reported by the product binary's `--version` output. Defaults to
    /// "unknown" under the same conditions as `converterID`.
    /// Wire key: converter_version. Set by collect().
    /// Example value: "distill-plus-v1".
    public var converterVersion: String? = nil

    // ── hosting mode ────────────────────────────────────────────────────────
    /// How the mootx01 server was hosted during this run. MEASURED from the
    /// actual launch path — not a declared flag — following the same principle
    /// as `loadAverage1m` (H10).
    ///
    /// Values per TOPOLOGY.md §1.2.0:
    ///   "resident-daemon"       — server ran in the harness process (in-process).
    ///   "separately-launched-stdio" — harness spawned a separate mootx01 process
    ///                            and spoke JSON-RPC over its stdio.
    ///   "unknown"               — binary path was nil; no server was launched.
    ///
    /// Wire key: hosting_mode. Set by collect() from mootx01BinaryPath.
    public var hostingMode: String? = nil

    // ── Community Edition SHA ────────────────────────────────────────────────
    /// Community Edition commit SHA for the binary under test. ADVISORY: set
    /// from the MOOT_BENCH_CE_SHA environment variable, which is operator-
    /// supplied and can drift if the operator forgets to update it after a
    /// rebuild — the same drift hazard documented on `mootx01WorkingTreeHead`
    /// (finding H9). The citable binary identity remains `mootx01BinarySha256`.
    /// nil when MOOT_BENCH_CE_SHA is unset (omitted from JSON).
    /// Wire key: ce_sha. Set by collect().
    public var ceSha: String? = nil

    public enum CodingKeys: String, CodingKey {
        case hostname
        case modelIdentifier  = "model_identifier"
        case modelName        = "model_name"
        case chipName         = "chip_name"
        case ramBytes         = "ram_bytes"
        case diskBytes        = "disk_bytes"
        case macosVersion     = "macos_version"
        case mootx01Version   = "mootx01_version"
        case mootx01BuildDate = "mootx01_build_date"
        case mootx01WorkingTreeHead = "mootx01_working_tree_head"
        case mootx01BinarySha256 = "mootx01_binary_sha256"
        case runMode          = "run_mode"
        case protocolVersion  = "protocol_version"
        case loadAverage1m    = "load_average_1m"
        case logicalCpus      = "logical_cpus"
        case benchmarkTestName   = "benchmark_test_name"
        case benchmarkArm        = "benchmark_arm"
        case benchmarkRunSerial  = "benchmark_run_serial"
        case benchmarkRegisterArm = "benchmark_register_arm"
        case converterID         = "converter_id"
        case converterVersion    = "converter_version"
        case hostingMode         = "hosting_mode"
        case ceSha               = "ce_sha"
    }

    /// Collects machine and mootx01 metadata synchronously.
    ///
    /// All subprocess calls carry a 5-second wall-clock timeout. Failure in any
    /// individual field records "unknown" or 0 and does not abort collection.
    ///
    /// - Parameters:
    ///   - mootx01BinaryPath: Absolute path to the mootx01 CLI binary.
    ///     Pass nil when the path is unavailable; all mootx01 fields are "unknown".
    ///   - runMode: Machine-quiet declaration from `--run-mode` ("quiet" or
    ///     "contended"); defaults to "unspecified" when the flag was not passed.
    public static func collect(
        mootx01BinaryPath: String?,
        runMode: String = "unspecified",
        registerArm: String? = nil
    ) -> RunEnvironment {
        // D2 guard: refuse the run when MOOT_BENCH_NO_ENCODER=1 is set but the
        // no-encoder ablation is not yet implemented. A silently proceeding run
        // would measure product-default and label it no-encoder — a mislabeled
        // cell. The guard fires here (collect time) so no record is ever written.
        // See noEncoderActivationSeamMessage() in ArmRegister.swift for the full
        // rationale. Remove this guard when the ablation is wired.
        if let msg = noEncoderActivationSeamMessage() {
            FileHandle.standardError.write(Data((msg + "\n").utf8))
            exit(1)
        }
        let versionInfo: MootVersionInfo
        let gitHead: String
        let binarySha256: String
        if let binaryPath = mootx01BinaryPath {
            versionInfo = parseMootVersion(binaryPath: binaryPath)
            let dir = URL(fileURLWithPath: binaryPath).deletingLastPathComponent().path
            gitHead = gitShortSHA(inDirectory: dir)
            binarySha256 = fileSha256Hex(path: binaryPath) ?? "unknown"
        } else {
            versionInfo = MootVersionInfo()
            gitHead = "unknown"
            binarySha256 = "unknown"
        }
        // MEASURED hosting mode: "separately-launched-stdio" when the harness
        // spawns a separate mootx01 process (the only current launch path when a
        // binary is provided), "unknown" when no binary is present. A future
        // resident-daemon path would set "resident-daemon" instead.
        // See TOPOLOGY.md §1.2.0 for the canonical value set.
        let hosting = mootx01BinaryPath != nil ? "separately-launched-stdio" : "unknown"

        // CE SHA: advisory, operator-supplied via MOOT_BENCH_CE_SHA.
        // Can drift from the actual binary if the operator forgets to update it.
        // See the mootx01WorkingTreeHead advisory comment (finding H9).
        let ceShaDerived = ProcessInfo.processInfo.environment["MOOT_BENCH_CE_SHA"]
            .flatMap { $0.isEmpty ? nil : $0 }

        var env = RunEnvironment(
            hostname:         ProcessInfo.processInfo.hostName,
            modelIdentifier:  sysctlString("hw.model"),
            modelName:        systemProfilerModelName() ?? sysctlString("hw.model"),
            chipName:         sysctlString("machdep.cpu.brand_string"),
            ramBytes:         ProcessInfo.processInfo.physicalMemory,
            diskBytes:        bootVolumeDiskBytes(),
            macosVersion:     ProcessInfo.processInfo.operatingSystemVersionString,
            mootx01Version:   versionInfo.version,
            mootx01BuildDate: versionInfo.buildDate,
            mootx01WorkingTreeHead: gitHead,
            mootx01BinarySha256: binarySha256,
            runMode:          runMode,
            protocolVersion:  benchmarkProtocolVersion,
            loadAverage1m:    sampledLoadAverage1m(),
            logicalCpus:      ProcessInfo.processInfo.activeProcessorCount
        )
        // Collect-time fields stamped after struct construction (var properties
        // with nil defaults; writer sets the testname-arm-serial triple separately).
        env.hostingMode       = hosting
        env.converterID       = versionInfo.recallConverterID
        env.converterVersion  = versionInfo.recallConverterVersion
        env.ceSha             = ceShaDerived
        // Register arm: WHICH PRODUCT CONFIGURATION this run used. Orthogonal to
        // the lane arm (benchmarkArm), which records WHICH CORPUS SLICE ran.
        // Resolved at collect time so no writer site can omit it.
        // The registerArm seam allows tests to inject a specific arm without
        // mutating the process environment (mirrors resolveActiveArmName(env:)).
        env.benchmarkRegisterArm = registerArm ?? resolveActiveArmName()
        return env
    }
}

/// Slim identity block for accuracy-lane reports.
///
/// Accuracy files record only the three fields required to identify the binary
/// and the protocol version — not machine profile or load state, which belong
/// exclusively to the timing lane. Embed this under the "run_environment" key
/// wherever a legacy `RunEnvironment` was emitted for an accuracy subcommand.
public struct IdentityEnvironment: Codable, Sendable {
    /// SHA-256 content digest of the measured mootx01 binary (lowercase hex).
    public let mootx01BinarySha256: String
    /// Major.minor version string parsed from `mootx01 --version` (e.g. "1.1").
    public let mootx01Version: String
    /// Version of BENCHMARK_PROTOCOL.md governing this run.
    public let protocolVersion: String
    /// Payload-economics shape-variant arm ("v0"…"v5") when `--payload-arm`
    /// / MOOT_BENCH_PAYLOAD_ARM was set for this run, nil otherwise
    /// (omitted from JSON). "v4" IS recorded when explicitly selected — a
    /// deliberate full-row control cell is labeled, an arm-free run is not.
    /// See PayloadArm.swift.
    public let payloadArm: String?

    // ── testname-arm-serial (accuracy-lane twin of RunEnvironment fields) ────
    /// Test name component of this accuracy record. Set by the writer.
    /// Wire key: benchmark_test_name.
    public var benchmarkTestName: String? = nil
    /// Active benchmark arm name for this accuracy record. Set by the writer.
    /// Wire key: benchmark_arm.
    public var benchmarkArm: String? = nil
    /// Run serial component of this accuracy record. Set by the writer.
    /// Wire key: benchmark_run_serial.
    public var benchmarkRunSerial: String? = nil
    /// Product-configuration arm for this accuracy record. Resolved by
    /// collect() via `resolveActiveArmName()`. Orthogonal to `benchmarkArm`.
    /// Wire key: benchmark_register_arm. Set by collect(), not the writer.
    public var benchmarkRegisterArm: String? = nil

    // ── converter identity (accuracy-lane twin) ──────────────────────────────
    /// ContextDistillLib recall converter identity reported by the product
    /// binary's `--version` output. Defaults to "unknown" only when no binary
    /// was supplied or an older binary omits the recall line.
    /// Wire key: converter_id. Set by collect().
    public var converterID: String? = nil
    /// ContextDistillLib recall converter version reported by the product
    /// binary's `--version` output. Defaults to "unknown" under the same
    /// conditions as `converterID`.
    /// Wire key: converter_version. Set by collect().
    public var converterVersion: String? = nil

    // ── hosting mode (accuracy-lane twin) ───────────────────────────────────
    /// How mootx01 was hosted. MEASURED from the actual launch path.
    /// Values: "resident-daemon", "separately-launched-stdio", "unknown".
    /// Wire key: hosting_mode. Set by collect().
    public var hostingMode: String? = nil

    // ── CE SHA (accuracy-lane twin) ──────────────────────────────────────────
    /// Community Edition commit SHA. ADVISORY — operator-supplied via
    /// MOOT_BENCH_CE_SHA; subject to the same drift hazard as
    /// mootx01WorkingTreeHead (finding H9).
    /// Wire key: ce_sha. Set by collect().
    public var ceSha: String? = nil

    public enum CodingKeys: String, CodingKey {
        case mootx01BinarySha256 = "mootx01_binary_sha256"
        case mootx01Version      = "mootx01_version"
        case protocolVersion     = "protocol_version"
        case payloadArm          = "payload_arm"
        case benchmarkTestName   = "benchmark_test_name"
        case benchmarkArm        = "benchmark_arm"
        case benchmarkRunSerial  = "benchmark_run_serial"
        case benchmarkRegisterArm = "benchmark_register_arm"
        case converterID         = "converter_id"
        case converterVersion    = "converter_version"
        case hostingMode         = "hosting_mode"
        case ceSha               = "ce_sha"
    }

    /// Explicit init so `payloadArm` defaults to nil: identity blocks built
    /// outside the arm-capable lanes (timing sidecar, throughput, tests)
    /// carry no arm and need no source change. New var fields have nil defaults
    /// (SE-0242) and need not be passed by existing call sites.
    public init(mootx01BinarySha256: String, mootx01Version: String,
                protocolVersion: String, payloadArm: String? = nil) {
        self.mootx01BinarySha256 = mootx01BinarySha256
        self.mootx01Version = mootx01Version
        self.protocolVersion = protocolVersion
        self.payloadArm = payloadArm
        // var fields use their declared nil defaults; collect() stamps them.
    }

    /// Collects binary identity and protocol version from the given binary path.
    ///
    /// - Parameters:
    ///   - mootx01BinaryPath: Absolute path to the mootx01 CLI binary.
    ///     Pass nil when unavailable; all fields will be "unknown".
    ///   - payloadArm: The payload-economics arm selected for this run, when
    ///     any. Defaulted so identity collection outside the arm-capable
    ///     lanes is unchanged.
    public static func collect(
        mootx01BinaryPath: String?,
        payloadArm: PayloadArm? = nil,
        registerArm: String? = nil
    ) -> IdentityEnvironment {
        // D2 guard: same no-encoder refusal as RunEnvironment.collect().
        // Accuracy records must not be mislabeled either.
        if let msg = noEncoderActivationSeamMessage() {
            FileHandle.standardError.write(Data((msg + "\n").utf8))
            exit(1)
        }
        let binarySha256 = mootx01BinaryPath.flatMap { fileSha256Hex(path: $0) } ?? "unknown"
        let versionInfo: MootVersionInfo
        if let path = mootx01BinaryPath {
            versionInfo = parseMootVersion(binaryPath: path)
        } else {
            versionInfo = MootVersionInfo()
        }
        let hosting = mootx01BinaryPath != nil ? "separately-launched-stdio" : "unknown"
        let ceShaDerived = ProcessInfo.processInfo.environment["MOOT_BENCH_CE_SHA"]
            .flatMap { $0.isEmpty ? nil : $0 }
        var ident = IdentityEnvironment(
            mootx01BinarySha256: binarySha256,
            mootx01Version:      versionInfo.version,
            protocolVersion:     benchmarkProtocolVersion,
            payloadArm:          payloadArm?.rawValue
        )
        ident.hostingMode       = hosting
        ident.converterID       = versionInfo.recallConverterID
        ident.converterVersion  = versionInfo.recallConverterVersion
        ident.ceSha             = ceShaDerived
        // Register arm: same orthogonal-dimension discipline as RunEnvironment.
        // The registerArm seam allows tests to inject a specific arm without
        // mutating the process environment.
        ident.benchmarkRegisterArm = registerArm ?? resolveActiveArmName()
        return ident
    }
}

/// 1-minute load average via getloadavg(3). -1 when the call fails —
/// a sampling failure must be visible, never read as an idle machine.
func sampledLoadAverage1m() -> Double {
    var loads = [Double](repeating: 0, count: 3)
    let n = getloadavg(&loads, 3)
    return n >= 1 ? loads[0] : -1
}

/// SHA-256 of a UTF-8 string as lowercase hex. Companion to `fileSha256Hex`
/// for digests over synthesized values (e.g. B2's combined multi-file corpus
/// digest). Same known-answer vectors pin both.
func sha256HexOfString(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// SHA-256 content digest of a file as lowercase hex, streamed in 1 MiB chunks
/// so a large binary never loads fully into memory. Returns nil when the file
/// cannot be opened or read.
///
/// Internal (not private) so the digest used in reports is pinned by tests
/// against known SHA-256 vectors — the Rust twin (`file_sha256_hex`) is pinned
/// against the same vectors, which is what keeps the two ports' report fields
/// byte-comparable for the same binary.
func fileSha256Hex(path: String) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    var hasher = SHA256()
    do {
        while true {
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
    } catch {
        // A read error must not silently produce the digest of a partial file.
        return nil
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

// MARK: - Private collection helpers

/// Parsed fields extracted from `mootx01 --version` output.
private struct MootVersionInfo {
    /// Major.minor only ("1.1.0-beta-19" → "1.1"). Used for grouping runs.
    var version: String   = "unknown"
    /// The version token verbatim ("1.1.0-beta-19"). Artifact provenance needs
    /// this: major.minor cannot distinguish a binary that carries a tool from
    /// one that does not, which is the distinction a stale-binary build turns on.
    var fullVersion: String = "unknown"
    var buildDate: String = "unknown"
    /// Recall-path converter pair from `converter recall <id> <version>`.
    /// Older binaries that do not report it remain explicitly unknown.
    var recallConverterID: String = "unknown"
    var recallConverterVersion: String = "unknown"
}

/// Reads a NUL-terminated C string value from sysctl by name.
/// Returns "unknown" when the key is absent or the read fails.
private func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return "unknown" }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "unknown" }
    // Use baseAddress to get an unambiguous UnsafePointer<CChar> for String init.
    return buf.withUnsafeBufferPointer { ptr in
        guard let base = ptr.baseAddress else { return "unknown" }
        return String(cString: base)
    }
}

/// Returns the boot-volume total capacity in bytes via FileManager.
/// Returns 0 when the query fails (sandbox restriction, network root, etc.).
private func bootVolumeDiskBytes() -> UInt64 {
    guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
          let sizeVal = attrs[.systemSize]
    else { return 0 }
    if let n = sizeVal as? Int   { return n >= 0 ? UInt64(n) : 0 }
    if let n = sizeVal as? Int64 { return n >= 0 ? UInt64(n) : 0 }
    return 0
}

/// Queries system_profiler for the marketing model name.
/// Returns nil when system_profiler is absent or returns unexpected JSON shape.
private func systemProfilerModelName() -> String? {
    guard let output = runQuickSubprocess(
        ["/usr/sbin/system_profiler", "SPHardwareDataType", "-json"])
    else { return nil }
    guard let data = output.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let hardware = (json["SPHardwareDataType"] as? [[String: Any]])?.first,
          let name = hardware["machine_name"] as? String
    else { return nil }
    return name
}

/// Parses version and build date from `mootx01 --version` stdout.
///
/// Expected first-line format: "1.1.0-beta-14 EE (2026-08-05)"
/// Version is stripped to major.minor only; edition tag and prerelease are removed.
/// Build date is the ISO date inside the parentheses.
/// The product binary's reported version string, or "unknown" when the binary
/// cannot be run. Used by the artifact builder to stamp provenance so an
/// artifact records which binary produced it.
func mootBinaryVersion(binaryPath: String?) -> String {
    guard let binaryPath else { return "unknown" }
    return parseMootVersion(binaryPath: binaryPath).fullVersion
}

private func parseMootVersion(binaryPath: String) -> MootVersionInfo {
    guard let output = runQuickSubprocess([binaryPath, "--version"]) else {
        return MootVersionInfo()
    }
    // The first line remains the stable product version. Later lines may
    // expose converter identities without breaking older first-line readers.
    let lines = output.components(separatedBy: .newlines)
    let line = lines.first ?? output
    var info = MootVersionInfo()

    // Build date: first "(YYYY-MM-DD)" substring.
    if let open  = line.firstIndex(of: "("),
       let close = line[line.index(after: open)...].firstIndex(of: ")") {
        let candidate = String(line[line.index(after: open)..<close])
        // Validate ISO date shape: 10 chars with hyphens at positions 4 and 7.
        let chars = Array(candidate)
        if chars.count == 10 && chars[4] == "-" && chars[7] == "-" {
            info.buildDate = candidate
        }
    }

    // Version: first space-delimited token, truncated to major.minor.
    // E.g. "1.1.0-beta-14" → parts ["1", "1", "0-beta-14"] → "1.1"
    let versionToken = line.components(separatedBy: " ").first ?? ""
    if !versionToken.isEmpty { info.fullVersion = versionToken }
    let parts = versionToken.components(separatedBy: ".")
    if parts.count >= 2, !parts[0].isEmpty {
        // Strip any prerelease suffix from the minor component.
        let minor = parts[1].components(separatedBy: "-").first ?? parts[1]
        if !minor.isEmpty {
            info.version = "\(parts[0]).\(minor)"
        }
    }

    // Product binaries report one converter per line as
    // `converter <role> <id> <version>`. Record the declared `recall`
    // converter separately from the distinct hydration converter.
    for line in lines {
        let fields = line.split(whereSeparator: { $0.isWhitespace })
        guard fields.count == 4,
              fields[0] == "converter",
              fields[1] == "recall"
        else { continue }
        info.recallConverterID = String(fields[2])
        info.recallConverterVersion = String(fields[3])
        break
    }

    return info
}

/// Runs `git -C <dir> rev-parse --short HEAD`.
/// Git walks up from the given directory to find the repo root automatically.
/// Returns "unknown" when git is absent, the path is not in a repo, or the call times out.
private func gitShortSHA(inDirectory dir: String) -> String {
    runQuickSubprocess(["/usr/bin/git", "-C", dir, "rev-parse", "--short", "HEAD"])
        ?? "unknown"
}

/// Synchronous subprocess runner with a 5-second wall-clock timeout.
///
/// Runs `args[0]` with `args[1...]` as arguments and no stdin. Intended for
/// read-only probes (system_profiler, git, mootx01 --version). Drains both
/// stdout and stderr on background queues to prevent pipe-buffer deadlock.
/// Returns trimmed stdout on success, or nil on launch failure, timeout, or non-zero exit.
private func runQuickSubprocess(_ args: [String]) -> String? {
    guard !args.isEmpty else { return nil }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: args[0])
    task.arguments     = Array(args.dropFirst())
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    task.standardOutput = stdoutPipe
    task.standardError  = stderrPipe

    let exited = DispatchSemaphore(value: 0)
    task.terminationHandler = { _ in exited.signal() }

    do { try task.run() } catch { return nil }

    // Drain stdout on a background queue — a child that writes more than the
    // ~64 KB pipe buffer blocks on its write while we wait for exit (deadlock).
    nonisolated(unsafe) var capturedData = Data()
    let drained = DispatchSemaphore(value: 0)
    DispatchQueue(label: "moot-bench.run-env.stdout").async {
        capturedData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        drained.signal()
    }
    // Drain stderr to prevent the child from blocking on a full stderr pipe.
    DispatchQueue(label: "moot-bench.run-env.stderr").async {
        _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    }

    if exited.wait(timeout: .now() + 5.0) == .timedOut {
        task.terminate()
        return nil
    }
    guard task.terminationStatus == 0 else { return nil }
    if drained.wait(timeout: .now() + 5.0) == .timedOut { return nil }
    return String(data: capturedData, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
