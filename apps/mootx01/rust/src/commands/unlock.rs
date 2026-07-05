//! commands/unlock.rs — `mootx01 unlock <private|secret>` and `mootx01 lock`
//! (Rust/Linux/Windows vertical, ADR-025 §2).
//!
//! ## unlock
//!
//! Reads the sensitivity-hashes sidecar (`<dataDir>/sensitivity_hashes.json`),
//! prompts the user for the tier-specific password with echo disabled, verifies
//! via PBKDF2-HMAC-SHA256, and on success POSTs a grant request to the daemon's
//! `/api/control/unlock` endpoint. The daemon issues the in-RAM grant with the
//! TTL defined by ADR-025 §1 (restricted: next local midnight; secret: 30 min).
//!
//! ## lock
//!
//! POSTs to the daemon's `/api/control/lock` endpoint to clear all grants
//! immediately. No identity verification is required (ADR-025 §1: "locking
//! reduces the user's own access and is always permitted").
//!
//! ## Platform note
//!
//! On Swift/macOS, authentication uses LocalAuthentication (LAContext). This
//! Rust vertical runs on Linux and Windows and uses password-based PBKDF2.
//! The HTTP call to the daemon is identical in both cases.

use crate::core::unlock_authority;
use aria_mcp::sensitivity_grant_ledger::SensitivityTier;
use std::path::Path;

// --- Public entry points ---

/// Run `mootx01 unlock private|secret`.
///
/// `tier_str` must be one of: `"private"`, `"restricted"` (internal alias),
/// or `"secret"`. Any other value is a programming error; the parser (cli.rs)
/// rejects unrecognised tier names before this function is called.
///
/// `data_dir` is the mootx01 data directory used to locate both the
/// sensitivity-hashes sidecar and the daemon port file.
///
/// Returns the exit code: 0 on success, non-zero on failure.
pub fn run_unlock(tier_str: &str, data_dir: &Path) -> i32 {
    let tier = match tier_str {
        "private" | "restricted" => SensitivityTier::Restricted,
        "secret" => SensitivityTier::Secret,
        _ => {
            // Belt-and-suspenders: the parser already validated this.
            eprintln!("mootx01 unlock: unknown tier '{}'. Use 'private' or 'secret'.", tier_str);
            return 64; // EX_USAGE
        }
    };

    match unlock_authority::authenticate_and_grant(tier, data_dir) {
        unlock_authority::UnlockOutcome::Granted { expires_at_iso } => {
            let label = if tier_str == "secret" { "secret" } else { "private (restricted)" };
            println!("mootx01 unlock: {} tier granted, expires {}.", label, expires_at_iso);
            0
        }
        unlock_authority::UnlockOutcome::WrongPassword => {
            eprintln!("mootx01 unlock: incorrect password.");
            1
        }
        unlock_authority::UnlockOutcome::NotConfigured => {
            eprintln!(
                "mootx01 unlock: sensitivity passwords have not been configured for this estate.\n\
                 Run `mootx01 db setup-sensitivity` (or the equivalent setup command) to initialise\n\
                 the per-tier passwords."
            );
            1
        }
        unlock_authority::UnlockOutcome::DaemonError(msg) => {
            eprintln!("mootx01 unlock: daemon error — {}.", msg);
            eprintln!("Ensure `mootx01 serve --http auto` is running before using unlock.");
            1
        }
        unlock_authority::UnlockOutcome::IoError(msg) => {
            eprintln!("mootx01 unlock: I/O error — {}.", msg);
            1
        }
    }
}

/// Run `mootx01 lock`.
///
/// Clears all sensitivity grants immediately. No authentication is required.
///
/// Returns the exit code: 0 on success, non-zero on failure.
pub fn run_lock() -> i32 {
    match unlock_authority::lock_all() {
        unlock_authority::LockOutcome::Locked => {
            println!("mootx01 lock: all sensitivity grants revoked.");
            0
        }
        unlock_authority::LockOutcome::DaemonError(msg) => {
            eprintln!("mootx01 lock: daemon error — {}.", msg);
            eprintln!("Ensure `mootx01 serve --http auto` is running.");
            1
        }
        unlock_authority::LockOutcome::IoError(msg) => {
            eprintln!("mootx01 lock: I/O error — {}.", msg);
            1
        }
    }
}
