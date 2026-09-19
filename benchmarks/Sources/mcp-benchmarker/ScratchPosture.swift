import Foundation
import MootProductIdentity

// ScratchPosture.swift — at-rest posture of benchmark scratch estates, and the
// one place the harness spells the product's estate-selection grammar.
//
// THE GRAMMAR (contract with the product, both ports):
//   <binary> serve --db <scratchDir> [--in-memory]
//
// `--db <dir>` attaches a TRANSIENT catalog record at that directory for one
// process (GeniusLocusKit EstateCatalog, `open(selecting:)`): the estate file
// is `<scratchDir>/estate.sqlite`, the record is never written to any catalog
// file, its identity key lives in memory, and it is PLAINTEXT by rule — a
// transient record never touches the Keychain. That is exactly what a
// synthetic benchmark estate that is deleted minutes after creation needs, and
// it is why no marker file and no environment value select the posture any
// more: the record kind carries it. `--in-memory` serves the estate from the
// InMemory backend (the RAM accuracy shape); no filesystem in the path.
//
// The encrypted cell (--estate-mode encrypted) is the one place a key exists:
// a harness build of the product (`-DMOOTX01_HARNESS_KEYFILE`) opens a
// transient record whose file is ciphertext when the harness key file sits
// beside it (`EstateEncryptionMigrator.installKeyFileName`), which is how the
// storage matrix serves databases the harness converted. The file dies with
// the scratch directory.
//
// The chosen posture is recorded in every report JSON as the run-level
// "estate_encryption" key so results are self-describing about at-rest posture.

// MARK: - Posture

/// At-rest posture for a benchmark scratch estate.
/// Recorded as the "estate_encryption" key in every report JSON.
enum ScratchEstatePosture: String, Sendable, Codable, Equatable {
    /// Default. The scratch estate is a transient catalog record, created
    /// plaintext by the product's rule for transient records; it never touches
    /// the macOS keychain. The raw value is the retired marker
    /// file's name, kept because it
    /// is a cache-key component and the report vocabulary downstream analysis
    /// keys on; renaming it would invalidate every cached plaintext estate.
    case plaintextTransient = "plaintext-optout"
    /// Encrypted run mode (--estate-mode encrypted): the estate is
    /// SQLCipher-encrypted under the harness key file beside it (harness
    /// builds only); no key is ever persisted to the Keychain.
    case encryptedEphemeral = "encrypted-ephemeral"
}

// MARK: - Builder errors

/// Errors thrown by `mootServeCommand` when the caller passes a path the
/// harness cannot safely serve. Twin of Rust `ScratchPostureError`.
enum ScratchPostureError: Error, Equatable {
    /// The scratch-directory path contains Unicode whitespace. The MCPClient
    /// splits the stdio command on spaces; a spacey path would corrupt the
    /// `--db` token.
    case whitespaceInPath(String)
    /// The scratch-directory path resolves under the product's configuration
    /// directory (the registered-estate tree). Directing a benchmark lane at a
    /// live registered estate would corrupt real data.
    case registeredEstatePath(String)
}

// MARK: - Serve command

/// The flag that selects a scratch estate in a serve command. The gauntlet's
/// scratch requirement checks the token after it begins with `/tmp`.
let mootServeDatabaseFlag = "--db"

/// The flag that serves the selected estate from the in-memory backend.
let mootServeInMemoryFlag = "--in-memory"

/// Returns `true` when `path` contains Unicode whitespace. Used by
/// `mootServeCommand` to guard against paths that would be split by the
/// stdio launcher and corrupt the `--db` token. Exported for testing.
///
/// Uses `CharacterSet.whitespaces`, which covers space, tab, non-breaking space,
/// and Unicode space separators (U+00A0, U+2000–200A). Twin of Rust's
/// `char::is_whitespace` predicate in `moot_serve_command`.
func mootServePathContainsWhitespace(_ path: String) -> Bool {
    path.unicodeScalars.contains { CharacterSet.whitespaces.contains($0) }
}

// MARK: - Registered-path guard

/// Returns `true` when `path`, resolved to its canonical form, falls under
/// `configDir`.
///
/// Shared logic for `mootServeDirUnderProductConfig` and the injectable
/// version used in tests. The `.` path is treated as "not determined" and
/// returns `false` (same rule as the product-identity fallback).
///
/// Exported for testing. Twin of Rust `serve_dir_under_config`.
func mootServeDirUnderConfig(_ path: URL, configDir: URL) -> Bool {
    // When the platform cannot determine Application Support, configDir.path
    // is ".". That path can never be a real product estate root; return false.
    guard configDir.path != "." else { return false }
    // Resolve both sides so symlinks and relative components cannot evade the check.
    let candidate = path.resolvingSymlinksInPath().path
    let config = configDir.resolvingSymlinksInPath().path
    // Ensure the config path ends with "/" so "/com.mootx01.ce-evil" is not a match.
    let configPrefix = config.hasSuffix("/") ? config : config + "/"
    return candidate == config || candidate.hasPrefix(configPrefix)
}

/// Returns `true` when `path`, resolved to its canonical form, falls under
/// the product's configuration directory for the current platform.
///
/// The directory is obtained from `MootProductIdentity.Storage.configurationDirectory` —
/// the same source the product binary uses — so the guard fires on the
/// real registered-estate path:
/// - macOS: `~/Library/Application Support/com.mootx01.ce`
///
/// Returns `false` when `MootProductIdentity.Storage.configurationDirectory` cannot be determined
/// (rare: Application Support not available).
/// Exported for testing. Twin of Rust `moot_serve_dir_under_product_config`.
func mootServeDirUnderProductConfig(_ path: URL) -> Bool {
    mootServeDirUnderConfig(path, configDir: MootProductIdentity.Storage.configurationDirectory)
}

/// A stdio serve command for a scratch estate: leading `KEY=VALUE` environment
/// tokens (the stdio launcher runs commands through `env`), the binary, the
/// explicit `serve` subcommand (the Rust CLI prints usage on a bare
/// invocation), `--db <scratchDir>`, and `--in-memory` for the RAM shape.
///
/// Throws `ScratchPostureError` when the path is invalid:
/// - `.whitespaceInPath`: `scratchDir.path` contains Unicode whitespace (the
///   MCPClient splits the stdio command on spaces; a spacey path corrupts the
///   `--db` token).
/// - `.registeredEstatePath`: `scratchDir` resolves under the product
///   Application Support directory (registered, potentially live estates;
///   directing a benchmark lane at one would corrupt real data).
///
/// Twin of the Rust `moot_serve_command` which returns
/// `Result<String, ScratchPostureError>`.
///
/// - Parameter productConfigDir: Override for the product configuration
///   directory used by guard 2. When `nil` (the default), the guard consults
///   `MootProductIdentity.Storage.configurationDirectory`. Pass a non-nil
///   value in tests to exercise guard 2 against a scratch temp directory
///   without whitespace, so the two guards are independently discriminable.
func mootServeCommand(
    binary: String,
    scratchDir: URL,
    inMemory: Bool = false,
    environment: [String] = [],
    productConfigDir: URL? = nil
) throws(ScratchPostureError) -> String {
    // Guard 1: whitespace in the path splits the --db token.
    guard !mootServePathContainsWhitespace(scratchDir.path) else {
        throw ScratchPostureError.whitespaceInPath(
            "mootServeCommand: scratchDir.path contains whitespace — the stdio "
            + "launcher splits on spaces; a spacey path corrupts --db. path=\(scratchDir.path)"
        )
    }
    // Guard 2: refuse a path that resolves to a registered product estate.
    // Handing a live estate to a benchmark lane that calls mootx01 serve --db
    // on it could corrupt the record. Scratch and artifact estates always live
    // outside Application Support.
    // When productConfigDir is provided, use it instead of the product identity
    // library so tests can exercise this guard with a no-whitespace temp directory.
    let configDir = productConfigDir ?? MootProductIdentity.Storage.configurationDirectory
    guard !mootServeDirUnderConfig(scratchDir, configDir: configDir) else {
        throw ScratchPostureError.registeredEstatePath(
            "mootServeCommand: scratchDir resolves to a registered product estate "
            + "under Application Support — refusing to serve a live estate as a "
            + "benchmark target. path=\(scratchDir.path)"
        )
    }
    var tokens = environment
    tokens += [binary, "serve", mootServeDatabaseFlag, scratchDir.path]
    if inMemory { tokens.append(mootServeInMemoryFlag) }
    return tokens.joined(separator: " ")
}

// MARK: - Standard serve environment

/// Standard environment tokens prepended to every scratch-estate serve command
/// in the 4 main runners. Centralised here so all runners stay in sync.
///
/// - `MOOTX01_VAULT=1`: enables the vault-gated batch import tool.
/// - `MOOTX01_SUBJECT_RIDER=0`: suppresses cross-estate subject propagation
///   so benchmark contexts stay isolated; prevents subject-expansion riders
///   from leaking query terms across run boundaries.
///
/// Twin of Rust `SCRATCH_SERVE_ENV`.
let scratchServeEnvironment: [String] = ["MOOTX01_VAULT=1", "MOOTX01_SUBJECT_RIDER=0"]

// MARK: - Bench-clock epoch derivation

/// Environment variable name for the benchmark deterministic clock seam.
///
/// When set to an ISO8601 instant before `mootx01 serve`, the server pins its
/// clock to `base_instant + call_index * 1s` for every tool dispatch, making
/// temporal scores and `filedAt` stamps identical across replay runs with the
/// same seed. Absent or empty: wall-clock (production default).
///
/// Env-only seam: not exposed on the MCP surface (no tool arg, no schema text).
let mootBenchEpochNowEnvKey = "MOOT_BENCH_EPOCH_NOW"

/// Returns a fixed ISO8601 instant deterministically derived from `seed`.
///
/// Used as `MOOT_BENCH_EPOCH_NOW` in replay runs so that same seed → same
/// `filedAt` timestamps and query-time temporal scores on every run.
///
/// Derivation: Unix base `2026-01-01T00:00:00Z` (1 767 225 600 s) plus
/// `seed % 86400` seconds (wraps within the first day so the epoch is always
/// human-readable and within a predictable range). The offset introduces
/// seed-variation while keeping the value stable between runs.
func benchClockEpochISO(for seed: UInt64) -> String {
    // Fixed base: 2026-01-01T00:00:00Z in Unix seconds. Deliberately AFTER
    // the supersession corpus's fiction timeline (epoch 2020-01-26 + ~4
    // years of chains/decoys): the corpus files records with capture_date
    // instants from that timeline, and the json_import future-skew gate
    // (codex 2026-08-26) rejects capture dates beyond the import now + 24h.
    // A pre-timeline pinned clock made every legitimate corpus date read as
    // "future" and refused the seed. Still pinned per seed — determinism
    // unchanged; only the fiction's "present" moved past its own history.
    let base: Int64 = 1_767_225_600
    // Offset by seed modulo one day so different seeds produce different epochs
    // (defensive: avoids any implicit correlation with the seed's corpus dates).
    let offset = Int64(seed % 86400)
    let ts = Double(base + offset)
    let date = Date(timeIntervalSince1970: ts)
    let fmt = ISO8601DateFormatter()
    // Force Z (UTC) suffix for maximum parser compat across Swift/Rust.
    fmt.formatOptions = [.withInternetDateTime]
    fmt.timeZone = TimeZone(identifier: "UTC")
    return fmt.string(from: date)
}
