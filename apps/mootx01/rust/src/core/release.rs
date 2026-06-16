//! core/release.rs — GitHub release download / verify / place for `upgrade`.
//!
//! Mirrors the bash `scripts/install.sh` semantics: resolve the latest tag
//! via the GitHub releases API, download
//! `mootx01-{ver}-{os}-{arch}.tar.gz` + `checksums.txt` from the release,
//! verify SHA-256, extract, place. std Rust ships no TLS, so the two network
//! legs shell out to `curl` (present on macOS, Linux, and Windows 10+);
//! checksum verification runs in-process (sha2), extraction via `tar`
//! (bsdtar on Windows handles .tar.gz).
//!
//! Binary placement (spec §1): `<home>/.mootx01/bin/mootx01` with a
//! `<home>/.local/bin/mootx01` symlink on Unix;
//! `%LOCALAPPDATA%\Programs\mootx01\mootx01.exe` on Windows (running-exe
//! replacement via the rename-old trick).

use std::path::{Path, PathBuf};
use std::process::Command;

use sha2::{Digest, Sha256};

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
    let url = format!("https://api.github.com/repos/{REPO}/releases/latest");
    let out = curl_stdout(&url)?;
    let v: serde_json::Value = serde_json::from_slice(&out)
        .map_err(|e| ReleaseError::Network(format!("GitHub API returned non-JSON: {e}")))?;
    let tag = v
        .get("tag_name")
        .and_then(|t| t.as_str())
        .ok_or_else(|| ReleaseError::Network("GitHub API response has no tag_name".into()))?;
    Ok(tag.trim_start_matches('v').to_string())
}

/// Numeric semver comparison: Some(true) when `candidate` is newer than
/// `current`. None when either fails to parse.
pub fn is_newer(candidate: &str, current: &str) -> Option<bool> {
    Some(parse_semver(candidate)? > parse_semver(current)?)
}

fn parse_semver(s: &str) -> Option<(u64, u64, u64)> {
    // Tolerant: "1", "0.8", "1.0.0", "v2.0.0", "1.0.0-rc1" all parse; missing
    // components default to 0 (real release tags have used two segments).
    let mut it = s.trim().trim_start_matches('v').splitn(3, '.');
    let num = |part: Option<&str>| -> Option<u64> {
        match part {
            None => Some(0),
            Some(p) => {
                let digits: String = p.chars().take_while(|c| c.is_ascii_digit()).collect();
                if digits.is_empty() { None } else { digits.parse().ok() }
            }
        }
    };
    let maj = num(it.next())?;
    let min = num(it.next())?;
    let patch = num(it.next())?;
    Some((maj, min, patch))
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
/// extract, and return the path to the extracted `mootx01` binary. The temp
/// dir is returned alongside so the caller controls its lifetime.
pub fn download_and_verify(version: &str) -> Result<(PathBuf, PathBuf), ReleaseError> {
    let (os, arch) = platform();
    let asset = format!("mootx01-{version}-{os}-{arch}.tar.gz");
    let base = format!("https://github.com/{REPO}/releases/download/v{version}");

    let tmp = std::env::temp_dir().join(format!("mootx01-upgrade-{}", std::process::id()));
    std::fs::create_dir_all(&tmp)?;
    let tarball = tmp.join(&asset);
    let checks = tmp.join("checksums.txt");

    curl_to_file(&format!("{base}/{asset}"), &tarball)?;
    curl_to_file(&format!("{base}/checksums.txt"), &checks)?;

    // Verify: find the asset's line in checksums.txt, compare SHA-256.
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

fn curl_stdout(url: &str) -> Result<Vec<u8>, ReleaseError> {
    let out = Command::new("curl")
        .args(["-fsSL", url])
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
        assert_eq!(is_newer("0.8", "1.0.0"), Some(false)); // real two-segment tag
        assert_eq!(is_newer("1.1", "1.0.0"), Some(true));
        assert_eq!(is_newer("junk", "1.0.0"), None);
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
