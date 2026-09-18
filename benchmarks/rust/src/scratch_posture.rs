// scratch_posture.rs — at-rest posture of benchmark scratch estates, and the
// one place the harness spells the product's estate-selection grammar.
//
// Twin of Swift `ScratchPosture.swift`.
//
// THE GRAMMAR (contract with the product, both ports):
//   <binary> serve --db <scratch_dir> [--in-memory]
//
// `--db <dir>` attaches a TRANSIENT catalog record at that directory for one
// process: the estate file is `<scratch_dir>/estate.sqlite`, the record is
// never written to any catalog file, its identity key lives in memory, and it
// is PLAINTEXT by rule — a transient record never touches a keychain. No
// marker file and no environment value select the posture any more: the
// record kind carries it. `--in-memory` serves the estate from the InMemory
// backend (the RAM accuracy shape).
//
// The encrypted cell (--estate-mode encrypted) is the one place a key exists:
// a harness build of the product opens a transient record whose file is
// ciphertext when the harness key file sits beside it, which is how the
// storage matrix serves databases the harness converted. The file dies with
// the scratch directory.
//
// The chosen posture is recorded in every report JSON as the run-level
// "estate_encryption" key.

use std::path::Path;

// MARK: - Errors

/// Errors returned by `moot_serve_command` for precondition-equivalent failures.
///
/// These represent invalid path inputs to the serve-command builder. Production
/// callers propagate the `Result` to the CLI entry, which prints the message
/// once on stderr and exits 1, the twin of the Swift `throws` path. Tests assert
/// `is_err()` / `unwrap_err()` to verify each guard without `#[should_panic]`.
///
/// Twin of Swift `ScratchPostureError`.
#[derive(Debug, PartialEq, Eq)]
pub enum ScratchPostureError {
    /// The scratch-dir path (or binary) contains Unicode whitespace. The stdio
    /// launcher splits on whitespace; an embedded space or tab corrupts the
    /// `--db` token or redirects which program `env` execs.
    WhitespaceInPath(String),
    /// The scratch-dir resolves to a path under the product configuration
    /// directory. Serving a registered estate as a benchmark target would
    /// corrupt the live record.
    RegisteredEstatePath(String),
}

impl std::fmt::Display for ScratchPostureError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ScratchPostureError::WhitespaceInPath(msg) => write!(f, "{}", msg),
            ScratchPostureError::RegisteredEstatePath(msg) => write!(f, "{}", msg),
        }
    }
}

impl std::error::Error for ScratchPostureError {}

// MARK: - Lane-level typed error

/// Discriminates configuration-level refusals (the binary or path fails a guard
/// before any estate or unit is touched) from per-unit runtime errors (an
/// individual MCP call fails after the endpoint is up).
///
/// Lanes that carry `LaneError` end to end: `lmeb` and `lmeb-s3` (lmeb_runner),
/// `longmemeval` (longmemeval_runner), `lme-spec` (lme_spec_runner), `lmeb-spec`
/// and `convomem-spec` (lmeb_spec_runner). A `LaneError::Config` from the
/// endpoint builder reaches `main()` and becomes one stderr line plus
/// `ExitCode::FAILURE`; a `LaneError::Unit` is written to a guard-excluded stub
/// and the lane continues with the remaining units.
///
/// The other `moot_serve_command` callers (locomo, locomo-spec, membench,
/// membench-spec, gauntlet, capturespread, artifact-recall, timing,
/// posture-equivalence, payload-economics) surface the builder refusal through
/// their own `String` / `MCPError` results. Most reach `main()` through `?`;
/// locomo, locomo-spec and membench use an error slot filled before their
/// thread scope and checked after it. One lane can absorb: the
/// posture-equivalence loop inside `timing_lane_runner.rs` catches its `Err`,
/// logs it and returns `Ok`; it is reachable only after `timing_endpoint_config`
/// has already passed the same binary through the same guard, so the refusal
/// cannot arrive there first.
///
/// The `From<MCPError>` impl defaults every unit-runner error to `Unit` so
/// existing `?` operators on `MCPError`-returning callers convert automatically.
/// `Config` is set only at the endpoint-config `map_err` call site in each lane.
#[derive(Debug, Clone)]
pub enum LaneError {
    /// The endpoint or path configuration is invalid. The lane aborts immediately.
    Config(String),
    /// A single unit failed. The lane records a guard-excluded stub and continues.
    Unit(String),
}

impl LaneError {
    /// The message string, regardless of variant.
    pub fn description(&self) -> &str {
        match self {
            LaneError::Config(s) | LaneError::Unit(s) => s.as_str(),
        }
    }
}

impl From<crate::mcp_client::MCPError> for LaneError {
    /// Per-unit MCP errors convert to `Unit` so callers can use `?` on `MCPError`
    /// results without an explicit wrapper. `Config` is set only by the
    /// endpoint-config `map_err` at each lane's serve-command call site.
    fn from(e: crate::mcp_client::MCPError) -> LaneError {
        LaneError::Unit(e.description)
    }
}

// MARK: - Registered-path guard

/// Shared logic: returns `true` when `path` falls under `config_dir`.
///
/// The `"."` path (the product-identity fallback when HOME is absent) is
/// treated as "not determined" and returns `false`, matching the caller's
/// contract. Twin of Swift `mootServeDirUnderConfig(_:configDir:)`.
fn serve_dir_under_config(path: &Path, config_dir: &Path) -> bool {
    // The "." fallback means the platform cannot determine the data dir; no
    // path can be a real estate root in that case.
    if config_dir == Path::new(".") { return false; }
    // Resolve both sides (follow symlinks, collapse `..`) so a symlink into
    // the configuration directory cannot evade the check.
    let candidate = std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    let config = std::fs::canonicalize(config_dir).unwrap_or_else(|_| config_dir.to_path_buf());
    // Ensure the config path ends with '/' so a path like ".../com.mootx01.ce-evil"
    // does not falsely match a shorter prefix.
    let mut config_prefix = config.to_string_lossy().into_owned();
    if !config_prefix.ends_with('/') { config_prefix.push('/'); }
    let candidate_str = candidate.to_string_lossy();
    let config_str = config.to_string_lossy();
    candidate_str == config_str || candidate_str.starts_with(config_prefix.as_str())
}

/// Returns `true` when `path`, resolved to its canonical form, falls under
/// the product's configuration directory for the current platform.
///
/// The directory is obtained from `moot_product_identity::storage::configuration_directory()`
/// — the same rule the product binary uses — so the guard fires on the real
/// registered-estate path on every supported platform:
///
/// - Unix (Linux in production, macOS developer runs): the Rust product uses
///   `${XDG_DATA_HOME:-<home>/.local/share}/mootx01`. The Rust product never
///   shares a directory with the Swift product; the Swift product uses
///   `~/Library/Application Support/com.mootx01.ce` (resolved by
///   `ScratchPosture.swift` via `MootProductIdentity.Storage.configurationDirectory`).
/// - Windows: `%LOCALAPPDATA%\com.mootx01.ce` (i.e.
///   `<home>\AppData\Local\com.mootx01.ce` when `LOCALAPPDATA` is unset).
///
/// Returns `false` when the product configuration directory resolves to the bare
/// fallback `"."` (hermetic CI with no HOME/USERPROFILE set).
///
/// Exported for testing. Twin of Swift `mootServeDirUnderProductConfig(_:)`.
pub fn moot_serve_dir_under_product_config(path: &Path) -> bool {
    serve_dir_under_config(path, &moot_product_identity::storage::configuration_directory())
}

/// At-rest posture for a benchmark scratch estate.
/// Recorded as the "estate_encryption" key in every report JSON.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum ScratchEstatePosture {
    /// Default. The scratch estate is a transient catalog record, created
    /// plaintext by the product's rule for transient records; it never touches
    /// a keychain.
    PlaintextTransient,
    /// Encrypted run mode (--estate-mode encrypted): the estate is
    /// SQLCipher-encrypted under the harness key file beside it (harness builds
    /// only); no key is ever persisted to a keychain.
    EncryptedEphemeral,
}

/// The flag that selects a scratch estate in a serve command.
pub const MOOT_SERVE_DATABASE_FLAG: &str = "--db";

/// The flag that serves the selected estate from the in-memory backend.
pub const MOOT_SERVE_IN_MEMORY_FLAG: &str = "--in-memory";

/// Environment variable name for the benchmark deterministic clock seam.
///
/// When set to an ISO8601 instant before `mootx01 serve`, the server pins
/// its clock to `base_instant + call_index * 1s` for every tool dispatch,
/// making temporal scores and `filedAt` stamps identical across replay runs
/// with the same seed. Absent or empty → wall-clock (production default).
/// Twin of Swift `mootBenchEpochNowEnvKey`.
pub const MOOT_BENCH_EPOCH_NOW_ENV_KEY: &str = "MOOT_BENCH_EPOCH_NOW";

/// Standard environment tokens prepended to every scratch-estate serve command
/// in the 4 main runners. Centralised here so all runners stay in sync.
///
/// - `MOOTX01_VAULT=1`: enables the vault-gated batch import tool.
/// - `MOOTX01_SUBJECT_RIDER=0`: suppresses cross-estate subject propagation
///   so benchmark contexts stay isolated; prevents subject-expansion riders
///   from leaking query terms across run boundaries.
///
/// Twin of Swift `scratchServeEnvironment`.
pub const SCRATCH_SERVE_ENV: &[&str] = &["MOOTX01_VAULT=1", "MOOTX01_SUBJECT_RIDER=0"];

/// Returns a fixed ISO8601 instant deterministically derived from `seed`.
///
/// Used as the `MOOT_BENCH_EPOCH_NOW` value in replay runs so that the same
/// seed always produces the same `filedAt` timestamps and temporal scores,
/// making a DETERMINISTIC verdict achievable rather than probabilistic.
///
/// Derivation: Unix base `2026-01-01T00:00:00Z` (1 767 225 600 s) plus
/// `seed % 86400` seconds, wrapping within the first day. The offset introduces
/// per-seed variation while keeping the epoch human-readable and within a
/// predictable range.
///
/// The base is deliberately after the supersession corpus's fiction timeline
/// (epoch 2020-01-26 + ~4 years of chains/decoys) so the server's pinned clock
/// reads as "present" relative to the corpus's planted event times.
///
/// Twin of Swift `benchClockEpochISO(for:)` in `ScratchPosture.swift`. Both
/// ports must produce the same string for the same seed; see the golden test below.
pub fn bench_clock_epoch_iso(seed: u64) -> String {
    // Fixed base: 2026-01-01T00:00:00Z in Unix seconds.
    const BASE: i64 = 1_767_225_600;
    let offset = (seed % 86400) as i64;
    let ts = BASE + offset;
    // Format as ISO8601 UTC. The Swift port uses ISO8601DateFormatter with
    // .withInternetDateTime and UTC timezone, which produces "2026-01-01T00:00:00Z".
    // We replicate that format exactly: YYYY-MM-DDTHH:MM:SSZ with no sub-seconds.
    let secs_per_min = 60i64;
    let secs_per_hour = 3600i64;
    let secs_per_day = 86400i64;
    // Days since Unix epoch (1970-01-01).
    let day_index = ts / secs_per_day;
    let time_of_day = ts % secs_per_day;
    let hour = time_of_day / secs_per_hour;
    let minute = (time_of_day % secs_per_hour) / secs_per_min;
    let second = time_of_day % secs_per_min;
    // Convert day_index to calendar date using the proleptic Gregorian algorithm.
    // Based on Henry F. Fliegel & Thomas C. Van Flandern (1968), adapted for Unix.
    let z = day_index + 719468; // shift epoch to 0000-03-01
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = z - era * 146097;               // day of era [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // year of era [0, 399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // day of year [0, 365]
    let mp = (5 * doy + 2) / 153;             // month prime [0, 11]
    let d = doy - (153 * mp + 2) / 5 + 1;    // day [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 }; // month [1, 12]
    let y = if m <= 2 { y + 1 } else { y };
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        y, m, d, hour, minute, second
    )
}

/// A stdio serve command for a scratch estate: leading `KEY=VALUE` environment
/// tokens (the stdio launcher runs commands through `env`), the binary, the
/// explicit `serve` subcommand, `--db <scratch_dir>`, and `--in-memory` for the
/// RAM shape.
///
/// # Errors
/// Returns `Err(ScratchPostureError::WhitespaceInPath)` when `scratch_dir` or
/// `binary` contains Unicode whitespace (the stdio launcher splits on whitespace;
/// an embedded space or tab corrupts the `--db` token or redirects the exec).
/// Returns `Err(ScratchPostureError::RegisteredEstatePath)` when `scratch_dir`
/// resolves to a path under the product configuration directory (that directory
/// holds registered, potentially live, estates; serving one as a benchmark target
/// would corrupt real data).
///
/// # Parameters
/// `product_config_dir` — override for the product configuration directory used
/// by guard 2. Pass `None` (production default) to use
/// `moot_product_identity::storage::configuration_directory()`. Pass `Some(dir)`
/// in tests to exercise guard 2 against a no-whitespace temp directory, so the
/// two guards are independently discriminable.
///
/// In production call sites propagate the `Result` with `?` (or `.map_err`) so
/// the CLI entry (`main()`) handles the message rather than a panic. In tests,
/// assert `result.is_err()` or `result.unwrap_err()` to verify the guard.
///
/// Twin of Swift `mootServeCommand` (which throws `ScratchPostureError`).
pub fn moot_serve_command(
    binary: &str,
    scratch_dir: &Path,
    in_memory: bool,
    environment: &[&str],
    product_config_dir: Option<&Path>,
) -> Result<String, ScratchPostureError> {
    // Guard 1: whitespace in the path splits the --db token.
    // MCPClient.swift:545 confirms whitespace-split: guard here rather than at the consumer.
    // Uses char::is_whitespace (Unicode) to match Swift's CharacterSet.whitespaces,
    // which covers space, tab, non-breaking space, and Unicode space separators.
    if scratch_dir.to_string_lossy().chars().any(char::is_whitespace) {
        return Err(ScratchPostureError::WhitespaceInPath(format!(
            "scratch_dir contains whitespace — the stdio launcher splits on whitespace; \
             a path with a space or tab corrupts the --db token. path={:?}",
            scratch_dir
        )));
    }
    if binary.chars().any(char::is_whitespace) {
        return Err(ScratchPostureError::WhitespaceInPath(format!(
            "binary path contains whitespace — the stdio launcher splits on whitespace. binary={:?}",
            binary
        )));
    }
    // Guard 2: refuse a path that resolves to a registered product estate.
    // Handing a live estate to a benchmark lane that calls mootx01 serve --db
    // on it could corrupt the record. Scratch and artifact estates always live
    // outside the product data directory.
    // When product_config_dir is Some, use the injected dir so tests can exercise
    // this guard with a no-whitespace temp directory.
    let registered = match product_config_dir {
        Some(config) => serve_dir_under_config(scratch_dir, config),
        None => moot_serve_dir_under_product_config(scratch_dir),
    };
    if registered {
        return Err(ScratchPostureError::RegisteredEstatePath(format!(
            "scratch_dir resolves to a registered product estate under the product \
             data directory — refusing to serve a live estate as a benchmark target. \
             path={:?}",
            scratch_dir
        )));
    }
    let mut tokens: Vec<String> = environment.iter().map(|t| t.to_string()).collect();
    tokens.push(binary.to_string());
    tokens.push("serve".to_string());
    tokens.push(MOOT_SERVE_DATABASE_FLAG.to_string());
    tokens.push(scratch_dir.display().to_string());
    if in_memory {
        tokens.push(MOOT_SERVE_IN_MEMORY_FLAG.to_string());
    }
    Ok(tokens.join(" "))
}

impl ScratchEstatePosture {
    /// The raw string value written to report JSON ("estate_encryption") and
    /// used as the cache-key component. Matches the Swift rawValues. The
    /// plaintext value is the retired marker file's name, kept because renaming
    /// it would invalidate every cached plaintext estate and every downstream key.
    pub fn as_str(&self) -> &'static str {
        match self {
            ScratchEstatePosture::PlaintextTransient => "plaintext-optout",
            ScratchEstatePosture::EncryptedEphemeral => "encrypted-ephemeral",
        }
    }
}

impl Default for ScratchEstatePosture {
    fn default() -> Self {
        ScratchEstatePosture::PlaintextTransient
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mcp_client::MCPError;
    use std::path::PathBuf;

    // ── LaneError discrimination ──────────────────────────────────────────────
    //
    // A Config error must discriminate from a Unit error so lane workers can
    // abort on config refusals and continue on per-unit failures. The
    // From<MCPError> impl must yield Unit, not Config, for every MCPError.

    #[test]
    fn lane_error_config_discriminates_from_unit() {
        // Config variant identifies a path/endpoint-configuration refusal.
        let config_err = LaneError::Config("whitespace in scratch path".to_string());
        assert!(matches!(config_err, LaneError::Config(_)), "Config must match Config arm");
        assert!(!matches!(config_err, LaneError::Unit(_)), "Config must not match Unit arm");
        // Unit variant identifies a per-unit MCP failure.
        let unit_err = LaneError::Unit("connect: connection refused".to_string());
        assert!(matches!(unit_err, LaneError::Unit(_)), "Unit must match Unit arm");
        assert!(!matches!(unit_err, LaneError::Config(_)), "Unit must not match Config arm");
        // From<MCPError> always yields Unit, never Config. A lane worker matching on
        // LaneError::Config to abort the run must not fire on ordinary MCPErrors.
        let from_mcp: LaneError = MCPError { description: "connect failed".to_string() }.into();
        assert!(matches!(from_mcp, LaneError::Unit(_)),
            "From<MCPError> must yield Unit so ordinary errors are skipped, not fatal");
        assert!(!matches!(from_mcp, LaneError::Config(_)),
            "From<MCPError> must never yield Config");
    }

    // ── serve command builder guards ──────────────────────────────────────────
    //
    // These tests assert `Err(...)` rather than using `#[should_panic]`, so a
    // mutation (delete the guard) makes the assertion fail rather than making
    // the test pass-without-panic. Twin of Swift XCTAssertThrowsError approach.

    #[test]
    fn serve_command_refuses_space_in_path() {
        // A space in the scratch path corrupts the --db token.
        // Mutation: delete the whitespace guard → `is_err()` fails (returns Ok).
        let result = moot_serve_command("/tmp/mootx01", &PathBuf::from("/tmp/lme bench x"), false, &[], None);
        assert!(result.is_err(), "builder must refuse a scratch_dir with spaces");
        let msg = result.unwrap_err().to_string();
        assert!(msg.contains("scratch_dir contains whitespace"), "error must identify the guard: {}", msg);
    }

    #[test]
    fn serve_command_refuses_tab_in_path() {
        // A tab is Unicode whitespace and must be refused the same as a space.
        // Swift's CharacterSet.whitespaces includes tab; this test pins parity.
        // Mutation: delete the whitespace guard → `is_err()` fails (returns Ok).
        let result = moot_serve_command("/tmp/mootx01", &PathBuf::from("/tmp/lme\tbench"), false, &[], None);
        assert!(result.is_err(), "builder must refuse a scratch_dir with tab");
        let msg = result.unwrap_err().to_string();
        assert!(msg.contains("scratch_dir contains whitespace"), "error must identify the guard: {}", msg);
    }

    #[test]
    fn serve_command_refuses_whitespace_in_binary_path() {
        // A space in the binary path corrupts the command token.
        // Rust guards binary too; Swift guards only scratchDir (asymmetry is
        // documented). This test pins the Rust guard.
        // Mutation: delete the binary-whitespace guard → `is_err()` fails.
        let result = moot_serve_command("/tmp/moot x01", &PathBuf::from("/tmp/lme-bench-x"), false, &[], None);
        assert!(result.is_err(), "builder must refuse a binary path with spaces");
        let msg = result.unwrap_err().to_string();
        assert!(msg.contains("binary path contains whitespace"), "error must identify the guard: {}", msg);
    }

    // ── Per-guard discriminated refusal tests (W1 fix) ───────────────────────
    //
    // Each test exercises exactly one guard. The injectable `product_config_dir`
    // parameter is the seam: the whitespace test passes a no-whitespace config
    // dir so only guard 1 fires; the registered-path test passes a no-whitespace
    // scratch path under an injected config dir so only guard 2 fires.
    //
    // Mutation contract (verified by running with each guard deleted):
    //   delete guard 1 → serve_command_refuses_whitespace_in_path FAILS,
    //                     serve_command_refuses_registered_estate_path stays green
    //   delete guard 2 → serve_command_refuses_registered_estate_path FAILS,
    //                     serve_command_refuses_whitespace_in_path stays green

    #[test]
    fn serve_command_refuses_whitespace_in_path() {
        // Guard 1 (WhitespaceInPath) — must fire exactly, guard 2 must not run.
        // scratchDir: a path with a space. product_config_dir: a no-whitespace
        // temp dir that the spacey path does NOT lie under, so only guard 1 fires.
        let no_space_config = PathBuf::from("/tmp/bench-config-nosp");
        let result = moot_serve_command(
            "/tmp/mootx01", &PathBuf::from("/tmp/lme bench x"), false, &[],
            Some(no_space_config.as_path()));
        assert!(result.is_err(), "guard 1 must fire for a path with whitespace");
        match result.unwrap_err() {
            ScratchPostureError::WhitespaceInPath(_) => {} // expected
            ScratchPostureError::RegisteredEstatePath(msg) => {
                panic!("guard 2 must not fire when scratchDir has whitespace and is not under config: {}", msg);
            }
        }
    }

    #[test]
    fn serve_command_refuses_registered_estate_path() {
        // Guard 2 (RegisteredEstatePath) — must fire exactly, guard 1 must not run.
        // product_config_dir: a no-whitespace temp dir. scratchDir: a path under
        // that temp dir, also without whitespace. Guard 1 passes, guard 2 fires.
        let tmp_config = PathBuf::from("/tmp/bench-registered-guard2");
        let under_config = tmp_config.join("estates").join("bench-test");
        let result = moot_serve_command(
            "/tmp/mootx01", &under_config, false, &[],
            Some(tmp_config.as_path()));
        assert!(result.is_err(), "guard 2 must fire for a path under the injected config dir");
        match result.unwrap_err() {
            ScratchPostureError::RegisteredEstatePath(msg) => {
                assert!(msg.contains("registered product estate"), "error must mention the estate: {}", msg);
            }
            ScratchPostureError::WhitespaceInPath(msg) => {
                panic!("guard 1 must not fire: scratchDir has no whitespace. Got: {}", msg);
            }
        }
    }

    #[test]
    fn serve_command_refuses_registered_product_path() {
        // Pins guard 2 against the real moot_product_identity path (no injection).
        // When HOME/USERPROFILE is absent the guard is a no-op.
        let config_dir = moot_product_identity::storage::configuration_directory();
        if config_dir == PathBuf::from(".") {
            // HOME/USERPROFILE absent — the guard short-circuits to false for
            // every path. The builder must succeed for an arbitrary /tmp path.
            let result = moot_serve_command(
                "/tmp/mootx01", &PathBuf::from("/tmp/lme-bench-x"), false, &[], None);
            assert!(result.is_ok(),
                "without HOME the guard is inoperative; builder must succeed: {:?}", result.err());
            return;
        }
        let under_config = config_dir.join("estates").join("default");
        // The builder must refuse before assembling the command.
        let result = moot_serve_command("/tmp/mootx01", &under_config, false, &[], None);
        assert!(result.is_err(),
            "builder must refuse a path under the product configuration directory");
        let msg = result.unwrap_err().to_string();
        assert!(msg.contains("registered product estate"),
            "error must mention the estate: {}", msg);
    }

    #[test]
    fn serve_command_selects_the_scratch_record() {
        let command = moot_serve_command(
            "/tmp/mootx01", &PathBuf::from("/tmp/lme-bench-x"), false, &["MOOTX01_VAULT=1"], None)
            .expect("valid inputs must succeed");
        assert_eq!(command, "MOOTX01_VAULT=1 /tmp/mootx01 serve --db /tmp/lme-bench-x");
    }

    #[test]
    fn serve_command_appends_in_memory_for_the_ram_shape() {
        let command = moot_serve_command("/tmp/mootx01", &PathBuf::from("/tmp/lme-bench-x"), true, &[], None)
            .expect("valid inputs must succeed");
        assert_eq!(command, "/tmp/mootx01 serve --db /tmp/lme-bench-x --in-memory");
    }

    #[test]
    fn scratch_serve_env_golden_string() {
        // Both MOOTX01_VAULT=1 and MOOTX01_SUBJECT_RIDER=0 must appear in
        // every main-runner serve command; this test is the canonical golden
        // string that documents and guards the pair.
        let command = moot_serve_command(
            "/tmp/mootx01", &PathBuf::from("/tmp/lme-bench-x"), false, SCRATCH_SERVE_ENV, None)
            .expect("valid inputs must succeed");
        assert_eq!(
            command,
            "MOOTX01_VAULT=1 MOOTX01_SUBJECT_RIDER=0 /tmp/mootx01 serve --db /tmp/lme-bench-x"
        );
    }

    // ── bench_clock_epoch_iso ─────────────────────────────────────────────────

    #[test]
    fn bench_clock_epoch_iso_seed_zero_matches_swift() {
        // Golden string: seed 0 → offset 0 → base 2026-01-01T00:00:00Z.
        // The Swift twin `benchClockEpochISO(for: 0)` produces the same string
        // (verified in ScratchPostureTests.swift bench_clock_epoch_iso_golden_string).
        // Both ports must agree for the replay determinism claim to hold.
        assert_eq!(bench_clock_epoch_iso(0), "2026-01-01T00:00:00Z");
    }

    #[test]
    fn bench_clock_epoch_iso_seed_variation() {
        // seed 1 → offset 1s → 2026-01-01T00:00:01Z.
        assert_eq!(bench_clock_epoch_iso(1), "2026-01-01T00:00:01Z");
        // seed 3600 → offset 3600s → 2026-01-01T01:00:00Z.
        assert_eq!(bench_clock_epoch_iso(3600), "2026-01-01T01:00:00Z");
        // seed 86400 → offset wraps to 0 → same as seed 0.
        assert_eq!(bench_clock_epoch_iso(86400), bench_clock_epoch_iso(0));
    }

    #[test]
    fn bench_clock_epoch_token_prepended_in_replay_command() {
        // MOOT_BENCH_EPOCH_NOW token, when present, travels as a leading
        // KEY=VALUE token before the standard env so /usr/bin/env sees it.
        // Uses bench_clock_epoch_iso rather than a hand-coded literal so this
        // test catches any drift between the function and the golden value.
        let epoch = bench_clock_epoch_iso(0);
        let epoch_token = format!("{}={}", MOOT_BENCH_EPOCH_NOW_ENV_KEY, epoch);
        let mut env: Vec<&str> = vec![epoch_token.as_str()];
        env.extend_from_slice(SCRATCH_SERVE_ENV);
        let command = moot_serve_command("/tmp/mootx01", &PathBuf::from("/tmp/lme-bench-x"), false, &env, None)
            .expect("valid inputs must succeed");
        assert_eq!(
            command,
            "MOOT_BENCH_EPOCH_NOW=2026-01-01T00:00:00Z MOOTX01_VAULT=1 MOOTX01_SUBJECT_RIDER=0 /tmp/mootx01 serve --db /tmp/lme-bench-x"
        );
    }

    // ── moot_serve_dir_under_product_config ───────────────────────────────────

    #[test]
    fn moot_serve_dir_under_product_config_pins_against_product_identity() {
        // Pins the predicate against moot_product_identity::storage::configuration_directory()
        // — the same source the builder guard consults. If the product renames its
        // directory, this test catches the drift before it ships.
        let config_dir = moot_product_identity::storage::configuration_directory();
        if config_dir == PathBuf::from(".") {
            // HOME/USERPROFILE absent; guard is a no-op. Skip.
            return;
        }
        // A path inside the product config dir must be detected.
        let under_config = config_dir.join("estates").join("default");
        assert!(
            moot_serve_dir_under_product_config(&under_config),
            "path under product data dir must be detected: {:?}", under_config
        );
        // The config dir itself is also refused.
        assert!(
            moot_serve_dir_under_product_config(&config_dir),
            "the product data dir itself must be detected"
        );
        // Evil-twin: same parent, longer name — must NOT match.
        let parent = config_dir.parent().unwrap_or(Path::new("/"));
        let evil_suffix = config_dir.file_name()
            .map(|n| { let mut s = n.to_string_lossy().into_owned(); s.push_str("-evil"); s })
            .unwrap_or_else(|| "evil".to_string());
        let evil_twin = parent.join(evil_suffix);
        assert!(
            !moot_serve_dir_under_product_config(&evil_twin),
            "evil-twin path must not match: {:?}", evil_twin
        );
        // Scratch paths under /tmp are allowed.
        assert!(
            !moot_serve_dir_under_product_config(Path::new("/tmp/lme-bench-x")),
            "/tmp scratch path must not be detected as product config"
        );
    }

    #[test]
    fn raw_values_are_the_report_vocabulary() {
        assert_eq!(ScratchEstatePosture::PlaintextTransient.as_str(), "plaintext-optout");
        assert_eq!(ScratchEstatePosture::EncryptedEphemeral.as_str(), "encrypted-ephemeral");
    }

    #[test]
    fn default_is_plaintext() {
        assert_eq!(ScratchEstatePosture::default(), ScratchEstatePosture::PlaintextTransient);
    }
}
