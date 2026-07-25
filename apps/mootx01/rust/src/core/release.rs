//! core/release.rs — GitHub release download / verify / place for `upgrade`.
//!
//! ⚠️ EDITION-DIVERGENT — DO NOT let an EE→CE sync overwrite this file.
//! CE ships the minisign Ed25519 signature-verification path (CAND-004) wired
//! into this module; EE's copy differs. The push-script / moot-packager sync
//! MUST exclude `apps/mootx01/rust/src/core/release.rs` (and `distribution/minisign.pub`)
//! from byte-identical replacement, or CE's minisign trust root is silently lost.
//! If you are reconciling editions, port changes by hand — never bulk-copy.
//!
//! Mirrors the bash `install.sh` semantics: resolve the latest tag
//! via the GitHub releases API, download
//! `mootx01-{ver}-{os}-{arch}.tar.gz` + `checksums.txt` from the release,
//! verify SHA-256, verify the minisign Ed25519 signature of checksums.txt,
//! validate archive members (zip-slip prevention), extract, place.
//! std Rust ships no TLS, so the two network legs shell out to `curl`
//! (present on macOS, Linux, and Windows 10+);
//! checksum verification runs in-process (sha2), extraction via `tar`
//! (bsdtar on Windows handles .tar.gz).
//!
//! Binary placement (spec §1): `<home>/.mootx01/bin/mootx01` with a
//! `<home>/.local/bin/mootx01` symlink on Unix;
//! `%LOCALAPPDATA%\Programs\mootx01\mootx01.exe` on Windows (running-exe
//! replacement via the rename-old trick).

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use sha2::{Digest, Sha256};

// Minisign Ed25519 public key for release signature verification, bundled at
// compile time from distribution/minisign.pub in the repository root. The installer
// shell script uses the same file at runtime (same trust source, different
// distribution path). If the key contains the PLACEHOLDER sentinel, verification
// fails closed — the operator must commit a real keypair to distribution/minisign.pub.
const MINISIGN_PUBLIC_KEY: &str = include_str!("../../../../../distribution/minisign.pub");

pub const REPO: &str = "codedaptive/mootx01-ce";

#[derive(Debug)]
pub enum ReleaseError {
    Network(String),
    Checksum(String),
    Io(std::io::Error),
}

impl std::fmt::Display for ReleaseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ReleaseError::Network(m) => write!(f, "{m}"),
            ReleaseError::Checksum(m) => write!(f, "{m}"),
            ReleaseError::Io(e) => write!(f, "{e}"),
        }
    }
}
impl From<std::io::Error> for ReleaseError {
    fn from(e: std::io::Error) -> Self {
        ReleaseError::Io(e)
    }
}

/// Latest release version (leading `v` stripped) from the GitHub API.
pub fn latest_version() -> Result<String, ReleaseError> {
    latest_version_within(None)
}

/// `latest_version` with a hard cap on the whole transfer (curl
/// `--max-time`). The resident daemon's update advisory calls this from
/// inside a tool dispatch (behind the dispatcher mutex), so an
/// unreachable-but-not-refusing feed host must fail at the deadline
/// instead of holding tool dispatch for curl's own default (which can
/// run to minutes). `None` preserves the interactive `upgrade`
/// command's unbounded behavior unchanged.
pub fn latest_version_within(timeout_secs: Option<u64>) -> Result<String, ReleaseError> {
    let url = format!("https://api.github.com/repos/{REPO}/releases/latest");
    let out = curl_stdout_within(&url, timeout_secs)?;
    let v: serde_json::Value = serde_json::from_slice(&out)
        .map_err(|e| ReleaseError::Network(format!("GitHub API returned non-JSON: {e}")))?;
    let tag = v
        .get("tag_name")
        .and_then(|t| t.as_str())
        .ok_or_else(|| ReleaseError::Network("GitHub API response has no tag_name".into()))?;
    Ok(tag.trim_start_matches('v').to_string())
}

/// SemVer comparison: Some(true) when `candidate` is newer than `current`.
/// Stable versions sort after pre-releases with the same numeric core.
/// None when either value fails to parse.
pub fn is_newer(candidate: &str, current: &str) -> Option<bool> {
    Some(compare_semver(&parse_semver(candidate)?, &parse_semver(current)?).is_gt())
}

#[derive(Debug, Eq, PartialEq)]
struct ParsedSemver {
    core: [u64; 3],
    prerelease: Option<Vec<PrereleaseIdentifier>>,
}

#[derive(Debug, Eq, PartialEq)]
enum PrereleaseIdentifier {
    Numeric(u64),
    Text(String),
}

fn parse_semver(s: &str) -> Option<ParsedSemver> {
    // Tolerant of historical one- and two-component tags; missing numeric
    // components default to zero. Pre-release precedence follows SemVer 2.0.
    let raw = s.trim().strip_prefix('v').unwrap_or(s.trim());
    let (core_text, prerelease_text) = match raw.split_once('-') {
        Some((core, pre)) if !pre.is_empty() => (core, Some(pre)),
        Some(_) => return None,
        None => (raw, None),
    };
    let core_parts: Vec<&str> = core_text.split('.').collect();
    if core_parts.is_empty() || core_parts.len() > 3 {
        return None;
    }
    let mut core = [0_u64; 3];
    for (index, part) in core_parts.iter().enumerate() {
        if part.is_empty() || !part.chars().all(|c| c.is_ascii_digit()) {
            return None;
        }
        core[index] = part.parse().ok()?;
    }
    let prerelease = match prerelease_text {
        Some(pre) => Some(
            pre.split('.')
                .map(|part| {
                    if part.is_empty()
                        || !part
                            .chars()
                            .all(|c| c.is_ascii_alphanumeric() || c == '-')
                    {
                        return None;
                    }
                    match part.parse::<u64>() {
                        Ok(value) => Some(PrereleaseIdentifier::Numeric(value)),
                        Err(_) => Some(PrereleaseIdentifier::Text(part.to_owned())),
                    }
                })
                .collect::<Option<Vec<_>>>()?,
        ),
        None => None,
    };
    Some(ParsedSemver { core, prerelease })
}

fn compare_semver(a: &ParsedSemver, b: &ParsedSemver) -> std::cmp::Ordering {
    use std::cmp::Ordering;

    let core = a.core.cmp(&b.core);
    if core != Ordering::Equal {
        return core;
    }
    match (&a.prerelease, &b.prerelease) {
        (None, None) => Ordering::Equal,
        (None, Some(_)) => Ordering::Greater,
        (Some(_), None) => Ordering::Less,
        (Some(a_ids), Some(b_ids)) => {
            for (a_id, b_id) in a_ids.iter().zip(b_ids.iter()) {
                let order = match (a_id, b_id) {
                    (
                        PrereleaseIdentifier::Numeric(a_value),
                        PrereleaseIdentifier::Numeric(b_value),
                    ) => a_value.cmp(b_value),
                    (PrereleaseIdentifier::Numeric(_), PrereleaseIdentifier::Text(_)) => {
                        Ordering::Less
                    }
                    (PrereleaseIdentifier::Text(_), PrereleaseIdentifier::Numeric(_)) => {
                        Ordering::Greater
                    }
                    (
                        PrereleaseIdentifier::Text(a_value),
                        PrereleaseIdentifier::Text(b_value),
                    ) => a_value.cmp(b_value),
                };
                if order != Ordering::Equal {
                    return order;
                }
            }
            a_ids.len().cmp(&b_ids.len())
        }
    }
}

/// `(os, arch)` for the asset name, matching the release matrix.
pub fn platform() -> (&'static str, &'static str) {
    let os = if cfg!(target_os = "macos") {
        "macos"
    } else if cfg!(target_os = "windows") {
        "windows"
    } else {
        "linux"
    };
    let arch = if cfg!(target_arch = "aarch64") { "arm64" } else { "x86_64" };
    (os, arch)
}

/// Download the release asset + checksums into a temp dir, verify SHA-256,
/// verify the minisign Ed25519 signature of checksums.txt, validate archive
/// members (zip-slip prevention), extract, and return the path to the extracted
/// `mootx01` binary. The temp dir is returned alongside so the caller controls
/// its lifetime.
///
/// Verification order (fail-closed at each step):
/// 1. SHA-256 checksum — verifies asset integrity against checksums.txt.
/// 2. minisign Ed25519 signature — verifies checksums.txt against the bundled
///    public key (independent trust root beyond TLS transport).
/// 3. Archive member containment — zip-slip prevention before extraction.
/// 4. Extraction.
pub fn download_and_verify(version: &str) -> Result<(PathBuf, PathBuf), ReleaseError> {
    let (os, arch) = platform();
    let asset = format!("mootx01-{version}-{os}-{arch}.tar.gz");
    let base = format!("https://github.com/{REPO}/releases/download/v{version}");

    let tmp = secure_upgrade_temp_dir()?;
    let tarball = tmp.join(&asset);
    let checks = tmp.join("checksums.txt");

    curl_to_file(&format!("{base}/{asset}"), &tarball)?;
    curl_to_file(&format!("{base}/checksums.txt"), &checks)?;

    // Verify step 1: find the asset's line in checksums.txt, compare SHA-256.
    let expected = std::fs::read_to_string(&checks)?
        .lines()
        .find(|l| l.contains(&asset))
        .and_then(|l| l.split_whitespace().next().map(String::from))
        .ok_or_else(|| {
            ReleaseError::Checksum(format!("no checksum for {asset} in checksums.txt"))
        })?;
    let actual = sha256_hex(&tarball)?;
    if !actual.eq_ignore_ascii_case(&expected) {
        return Err(ReleaseError::Checksum(format!(
            "checksum mismatch for {asset}: expected {expected}, got {actual}. Aborting."
        )));
    }

    // Verify step 2: minisign Ed25519 signature of checksums.txt.
    // Provides an independent trust root beyond the TLS transport (same role as
    // macOS Developer ID / Windows Authenticode on those platforms).
    // Fail-closed: if the public key is a PLACEHOLDER or minisign is absent, abort.
    // The .minisig file is downloaded from the same release location as all assets.
    let checksums_sig = tmp.join("checksums.txt.minisig");
    curl_to_file(&format!("{base}/checksums.txt.minisig"), &checksums_sig)?;
    verify_minisign_signature(&checks, &checksums_sig)?;

    // Verify step 3: validate all archive members before extraction to prevent
    // zip-slip: an archive containing absolute paths or `..` components could
    // escape the temp directory and overwrite arbitrary files.
    validate_tarball_members(&tarball)?;

    // Extract. tar is present on macOS/Linux; Windows 10+ ships bsdtar.
    let status = Command::new("tar")
        .args(["-xzf", &tarball.display().to_string(), "-C", &tmp.display().to_string()])
        .status()
        .map_err(|e| ReleaseError::Network(format!("cannot run tar: {e}")))?;
    if !status.success() {
        return Err(ReleaseError::Network(format!("tar extraction failed for {asset}")));
    }

    let bin_name = if cfg!(target_os = "windows") { "mootx01.exe" } else { "mootx01" };
    let binary = tmp.join(bin_name);
    if !binary.exists() {
        return Err(ReleaseError::Network(format!(
            "extracted archive does not contain {bin_name}"
        )));
    }
    Ok((binary, tmp))
}

/// Verify a detached minisign Ed25519 signature of `signed_file` using the
/// `sig_file` (.minisig) and the project's bundled public key.
///
/// Fail-closed in two ways:
/// 1. If the embedded public key is the PLACEHOLDER sentinel (not yet replaced
///    with a real key by the operator), returns an error describing the gap.
/// 2. If `minisign` is not on PATH, returns an error with install instructions.
///    The verification is shelled out rather than done in-process to avoid
///    pulling in a minisign crate dependency (no-new-crate constraint).
///    Behaviour mirrors the shell installer.
///
/// Called from `download_and_verify` after SHA-256 and before extraction.
/// Linux/POSIX is the primary use case; the function is still compiled on all
/// platforms and applies the same fail-closed logic.
pub fn verify_minisign_signature(
    signed_file: &Path,
    sig_file: &Path,
) -> Result<(), ReleaseError> {
    // Guard 1: placeholder key — verification wired but pending operator setup.
    if MINISIGN_PUBLIC_KEY.contains("PLACEHOLDER") {
        return Err(ReleaseError::Checksum(
            "minisign public key is a PLACEHOLDER — signature verification not yet active. \
             Generate a real keypair: minisign -G -p distribution/minisign.pub -s /path/to/minisign.sec \
             then commit distribution/minisign.pub and add MINISIGN_SECRET_KEY to GitHub secrets."
                .into(),
        ));
    }

    // Guard 2: minisign binary must be on PATH.
    // Probe by attempting invocation; ErrorKind::NotFound means binary absent.
    // Any other outcome (non-zero exit, other error) is treated as present.
    let probe = Command::new("minisign").arg("--version").output();
    match probe {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Err(ReleaseError::Network(
                "minisign is required for release signature verification but was not found. \
                 Install minisign: Debian/Ubuntu: apt-get install minisign | \
                 Arch: pacman -S minisign | \
                 Fedora: dnf install minisign | \
                 Homebrew: brew install minisign | \
                 Source: https://github.com/jedisct1/minisign"
                    .into(),
            ));
        }
        Err(e) => return Err(ReleaseError::Io(e)),
        Ok(_) => {} // binary present
    }

    // Write the embedded public key to a temp file so minisign can read it.
    // (minisign -V requires a file path for -p, not inline key material.)
    let tmp_key = std::env::temp_dir().join(format!(
        "mootx01-minisign-pub-{}-{}.pub",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    ));
    std::fs::write(&tmp_key, MINISIGN_PUBLIC_KEY)?;

    let result = Command::new("minisign")
        .args([
            "-V",
            "-p",
            &tmp_key.display().to_string(),
            "-m",
            &signed_file.display().to_string(),
            "-x",
            &sig_file.display().to_string(),
        ])
        .output();

    // Clean up temp key file regardless of outcome.
    let _ = std::fs::remove_file(&tmp_key);

    match result {
        Err(e) => Err(ReleaseError::Io(e)),
        Ok(out) if !out.status.success() => Err(ReleaseError::Checksum(format!(
            "minisign signature verification FAILED for {}: {}",
            signed_file.display(),
            String::from_utf8_lossy(&out.stderr).trim()
        ))),
        Ok(_) => Ok(()),
    }
}

/// Create an isolated, private temporary directory for upgrade downloads.
///
/// Uses pid + nanosecond timestamp + sequential attempt counter to guarantee
/// uniqueness even under concurrent invocations. On Unix, restricts permissions
/// to 0o700 so other users on the same machine cannot read partially-downloaded
/// release artifacts before checksum verification completes.
fn secure_upgrade_temp_dir() -> Result<PathBuf, ReleaseError> {
    let base = std::env::temp_dir();
    let pid = std::process::id();
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);

    for attempt in 0..1000_u16 {
        let dir = base.join(format!("mootx01-upgrade-{pid}-{nanos}-{attempt}"));
        match std::fs::create_dir(&dir) {
            Ok(()) => {
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700))?;
                }
                return Ok(dir);
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(ReleaseError::Io(e)),
        }
    }

    Err(ReleaseError::Io(std::io::Error::new(
        std::io::ErrorKind::AlreadyExists,
        "could not create a private upgrade temp directory",
    )))
}

pub fn sha256_hex(path: &Path) -> Result<String, ReleaseError> {
    let bytes = std::fs::read(path)?;
    let mut hasher = Sha256::new();
    hasher.update(&bytes);
    let digest = hasher.finalize();
    Ok(digest.iter().map(|b| format!("{b:02x}")).collect())
}

/// Place a new binary at the spec §1 install location, atomically where the
/// platform allows. Returns the installed path.
pub fn place_binary(new_binary: &Path, home: &Path) -> Result<PathBuf, ReleaseError> {
    #[cfg(not(target_os = "windows"))]
    {
        let bin_dir = home.join(".mootx01/bin");
        std::fs::create_dir_all(&bin_dir)?;
        let target = bin_dir.join("mootx01");
        // Copy beside, then rename — atomic replace even of a running binary.
        let staging = bin_dir.join(".mootx01.new");
        std::fs::copy(new_binary, &staging)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&staging, std::fs::Permissions::from_mode(0o755))?;
        }
        std::fs::rename(&staging, &target)?;

        // Refresh the ~/.local/bin symlink.
        let local_bin = home.join(".local/bin");
        std::fs::create_dir_all(&local_bin)?;
        let link = local_bin.join("mootx01");
        let _ = std::fs::remove_file(&link);
        #[cfg(unix)]
        std::os::unix::fs::symlink(&target, &link)?;
        Ok(target)
    }
    #[cfg(target_os = "windows")]
    {
        let bin_dir = home.join("AppData/Local/Programs/mootx01");
        std::fs::create_dir_all(&bin_dir)?;
        let target = bin_dir.join("mootx01.exe");
        // A running exe cannot be overwritten on Windows but CAN be renamed:
        // move the old aside, then move the new into place.
        if target.exists() {
            let old = bin_dir.join("mootx01.exe.old");
            let _ = std::fs::remove_file(&old);
            std::fs::rename(&target, &old)?;
        }
        std::fs::copy(new_binary, &target)?;
        Ok(target)
    }
}

/// Check whether `member_path` (a single line from `tar -tf`) is safe to
/// extract into a destination directory. Returns `Some(reason)` when the
/// member is unsafe (absolute/rooted path or `..` traversal), `None` when
/// safe.
///
/// Checks both Unix and Windows absolute-path forms explicitly at the string
/// level, because `Path::is_absolute()` on Linux/macOS returns `false` for
/// Windows-style paths (this validator runs on all platforms via `mootx01
/// upgrade`, and Windows bsdtar may use either separator convention):
///   - leading `/` — Unix absolute
///   - leading `\` — Windows rooted-to-current-drive
///   - leading `\\` — Windows UNC (\\server\share) — caught by leading `\`
///   - leading `[A-Za-z]:` — Windows drive-letter prefix (C:\, C:/, C:rel)
///
/// `..` traversal is detected by splitting on BOTH `/` and `\` so that
/// Windows-style `a\..\..` paths are caught on all platforms.
///
/// Separated from `validate_tarball_members` so the path-safety logic can
/// be unit-tested without requiring a real tar archive on disk.
pub fn unsafe_member_reason(member_path: &str) -> Option<String> {
    // Reject absolute or rooted paths. Check raw string forms explicitly:
    //   - leading / or \ catches Unix absolute and Windows rooted paths
    //     (including UNC \\server\share whose first char is \)
    //   - leading [A-Za-z]: catches all Windows drive-letter forms:
    //     C:\path, C:/path, C:relative (drive-relative, still unsafe)
    // Path::is_absolute() is also checked for robustness, though on
    // Linux/macOS it only fires for the leading-/ case covered above.
    let first = member_path.as_bytes().first().copied();
    let is_slash_rooted = matches!(first, Some(b'/') | Some(b'\\'));
    let is_drive_rooted = member_path.len() >= 2
        && member_path.as_bytes()[0].is_ascii_alphabetic()
        && member_path.as_bytes()[1] == b':';
    if is_slash_rooted || is_drive_rooted || std::path::Path::new(member_path).is_absolute() {
        return Some(format!("absolute/rooted path in archive member: {member_path:?}"));
    }
    // Reject any `..` component regardless of depth — `foo/../../etc/passwd`
    // is a traversal even though it does not start with `..`. Split on both
    // `/` and `\` so Windows-style `a\..\..` paths are caught on all
    // platforms (Path::components() uses platform-native separator only).
    if member_path.split(['/', '\\']).any(|seg| seg == "..") {
        return Some(format!("directory traversal component '..' in archive member: {member_path:?}"));
    }
    None
}

/// Run `tar -tf` to list all members of `tarball` and reject the archive if
/// any member is an absolute path or contains `..` components (zip-slip
/// prevention). Called before `tar -xzf` so a malformed archive is refused
/// before any bytes land on the filesystem.
pub fn validate_tarball_members(tarball: &Path) -> Result<(), ReleaseError> {
    let out = Command::new("tar")
        .args(["-tf", &tarball.display().to_string()])
        .output()
        .map_err(|e| ReleaseError::Network(format!("cannot run tar -tf: {e}")))?;
    if !out.status.success() {
        return Err(ReleaseError::Network(format!(
            "tar -tf failed for {}: {}",
            tarball.display(),
            String::from_utf8_lossy(&out.stderr).trim()
        )));
    }
    let listing = String::from_utf8_lossy(&out.stdout);
    for member in listing.lines() {
        if let Some(reason) = unsafe_member_reason(member) {
            return Err(ReleaseError::Checksum(format!(
                "archive {}: {reason}",
                tarball.display()
            )));
        }
    }
    Ok(())
}

fn curl_stdout(url: &str) -> Result<Vec<u8>, ReleaseError> {
    curl_stdout_within(url, None)
}

/// `curl_stdout` with an optional whole-transfer deadline (`--max-time`).
/// See `latest_version_within` for why the daemon-side caller bounds it.
fn curl_stdout_within(url: &str, timeout_secs: Option<u64>) -> Result<Vec<u8>, ReleaseError> {
    let mut cmd = Command::new("curl");
    cmd.args(["-fsSL", url]);
    if let Some(secs) = timeout_secs {
        cmd.args(["--max-time", &secs.to_string()]);
    }
    let out = cmd
        .output()
        .map_err(|e| ReleaseError::Network(format!("cannot run curl: {e}")))?;
    if !out.status.success() {
        return Err(ReleaseError::Network(format!(
            "curl failed for {url}: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        )));
    }
    Ok(out.stdout)
}

fn curl_to_file(url: &str, dest: &Path) -> Result<(), ReleaseError> {
    let out = Command::new("curl")
        .args(["-fsSL", url, "-o", &dest.display().to_string()])
        .output()
        .map_err(|e| ReleaseError::Network(format!("cannot run curl: {e}")))?;
    if !out.status.success() {
        return Err(ReleaseError::Network(format!(
            "download failed for {url}: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        )));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn semver_comparison() {
        assert_eq!(is_newer("1.0.1", "1.0.0"), Some(true));
        assert_eq!(is_newer("1.0.0", "1.0.0"), Some(false));
        assert_eq!(is_newer("0.9.9", "1.0.0"), Some(false));
        assert_eq!(is_newer("v2.0.0", "1.9.9"), Some(true));
        assert_eq!(is_newer("2.0.0-rc1", "1.9.9"), Some(true));
        assert_eq!(is_newer("1.1.0", "1.1.0-beta-03"), Some(true));
        assert_eq!(is_newer("1.1.0-beta-04", "1.1.0-beta-03"), Some(true));
        assert_eq!(is_newer("1.1.0-beta-02", "1.1.0-beta-03"), Some(false));
        assert_eq!(is_newer("1.1.0-beta-03", "1.1.0"), Some(false));
        assert_eq!(is_newer("0.8", "1.0.0"), Some(false)); // real two-segment tag
        assert_eq!(is_newer("1.1", "1.0.0"), Some(true));
        assert_eq!(is_newer("junk", "1.0.0"), None);
    }

    #[test]
    fn secure_upgrade_temp_dir_is_unique_and_private() {
        let first = secure_upgrade_temp_dir().unwrap();
        let second = secure_upgrade_temp_dir().unwrap();
        assert_ne!(first, second);
        assert!(first.is_dir());
        assert!(second.is_dir());

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                std::fs::metadata(&first).unwrap().permissions().mode() & 0o777,
                0o700
            );
            assert_eq!(
                std::fs::metadata(&second).unwrap().permissions().mode() & 0o777,
                0o700
            );
        }

        let _ = std::fs::remove_dir_all(&first);
        let _ = std::fs::remove_dir_all(&second);
    }

    #[test]
    fn unsafe_member_reason_rejects_absolute_and_traversal() {
        // Absolute paths must be rejected regardless of OS separator conventions.
        assert!(unsafe_member_reason("/etc/passwd").is_some());
        assert!(unsafe_member_reason("/absolute/path/file.bin").is_some());
        // Directory traversal (`..` component anywhere in the path) must be rejected.
        assert!(unsafe_member_reason("../etc/passwd").is_some());
        assert!(unsafe_member_reason("subdir/../../etc/passwd").is_some());
        assert!(unsafe_member_reason("a/b/../../../evil").is_some());
        // Normal relative paths must be accepted.
        assert!(unsafe_member_reason("mootx01").is_none());
        assert!(unsafe_member_reason("moot-mgr").is_none());
        assert!(unsafe_member_reason("data/subdir/file.txt").is_none());
        // A file named literally `..something` (starts with `..` but is not the
        // parent-dir component) must be accepted — it is not a traversal.
        assert!(unsafe_member_reason("..dotfile").is_none());
    }

    #[test]
    fn unsafe_member_reason_rejects_windows_absolute_path_forms() {
        // Windows drive-letter absolute path with backslash (C:\path).
        assert!(unsafe_member_reason("C:\\evil").is_some(), "C:\\evil must be rejected");
        // Windows drive-letter absolute path with forward slash (C:/path).
        assert!(unsafe_member_reason("C:/evil").is_some(), "C:/evil must be rejected");
        // Windows drive-relative path without separator (C:relative) —
        // still unsafe: resolves relative to the current directory of drive C.
        assert!(unsafe_member_reason("C:relative").is_some(), "C:relative must be rejected");
        // Windows leading backslash — rooted to current drive (\path).
        assert!(unsafe_member_reason("\\evil").is_some(), r"\evil must be rejected");
        // Windows UNC path (\\server\share\...) — leading \\ caught by leading \.
        assert!(unsafe_member_reason("\\\\srv\\share\\evil").is_some(), r"\\srv\share must be rejected");
        // Windows-style .. traversal with backslash separator — must be caught even
        // on macOS/Linux where Path::components() uses / as the only separator.
        assert!(unsafe_member_reason("..\\..\\evil").is_some(), r"..\..\ traversal must be rejected");
        assert!(unsafe_member_reason("a\\..\\..\\evil").is_some(), r"a\..\..\ traversal must be rejected");
        // Normal relative paths are still accepted.
        assert!(unsafe_member_reason("dir/file.txt").is_none(), "safe relative path must be accepted");
        assert!(unsafe_member_reason("..dotfile").is_none(), "..dotfile is not a traversal component");
    }

    #[test]
    fn sha256_of_known_bytes() {
        let dir = std::env::temp_dir().join(format!("mootx01-sha-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("x");
        std::fs::write(&p, b"abc").unwrap();
        assert_eq!(
            sha256_hex(&p).unwrap(),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn verify_minisign_real_key_fails_closed_on_invalid_or_absent() {
        // A real (non-placeholder) public key is now embedded, so the placeholder
        // guard no longer fires. Verification must STILL fail closed when either
        // (a) the minisign binary is absent (the build environment — Guard 2), or
        // (b) the binary is present but the detached signature does not verify
        // against the bundled key (a forged/dummy .minisig). Either way the
        // function must return Err, never silently accept an unverified asset.
        assert!(
            !MINISIGN_PUBLIC_KEY.contains("PLACEHOLDER"),
            "this test asserts the real-key path; embedded key must not be the placeholder"
        );
        let tmp = std::env::temp_dir().join(format!(
            "mootx01-minisig-test-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&tmp).unwrap();
        let dummy_file = tmp.join("checksums.txt");
        let dummy_sig = tmp.join("checksums.txt.minisig");
        std::fs::write(&dummy_file, b"abc123  mootx01-v1.0.0-linux-x86_64.tar.gz\n").unwrap();
        std::fs::write(&dummy_sig, b"dummy sig content").unwrap();

        // Fail closed: absent binary (Guard 2) or non-verifying dummy signature.
        let result = verify_minisign_signature(&dummy_file, &dummy_sig);
        assert!(
            result.is_err(),
            "verify_minisign_signature must fail closed on an absent binary or an invalid signature"
        );

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[cfg(unix)]
    #[test]
    fn place_binary_installs_and_symlinks() {
        let home = std::env::temp_dir().join(format!("mootx01-place-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).unwrap();
        let new = home.join("new-binary");
        std::fs::write(&new, b"#!/bin/sh\necho hi\n").unwrap();
        let installed = place_binary(&new, &home).unwrap();
        assert_eq!(installed, home.join(".mootx01/bin/mootx01"));
        assert!(installed.exists());
        let link = home.join(".local/bin/mootx01");
        assert_eq!(std::fs::read_link(&link).unwrap(), installed);
        // Replace again (simulates upgrading a present binary).
        std::fs::write(&new, b"#!/bin/sh\necho v2\n").unwrap();
        place_binary(&new, &home).unwrap();
        assert_eq!(std::fs::read(&installed).unwrap(), b"#!/bin/sh\necho v2\n");
        let _ = std::fs::remove_dir_all(&home);
    }
}
