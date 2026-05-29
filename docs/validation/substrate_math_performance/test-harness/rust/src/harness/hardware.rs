// src/harness/hardware.rs
//
// Hardware identification for benchmark output. Returns a stable,
// filename-safe slug describing the machine the benchmark ran on.
//
// macOS: `sysctl -n machdep.cpu.brand_string` → e.g. "apple-m3-max"
// Linux: parses /proc/cpuinfo (model name line) → e.g.
//                "arm-neoverse-n2" or "intel-xeon-platinum-8480cl"
// Other: returns "unknown"
//
// The slug is appended to the benchmark output directory so
// results from different hardware live side-by-side without
// overwriting each other. Decision docs cite the slug in their
// "measured at ..." lines so the reader knows what hardware
// produced the numbers.

use std::process::Command;

/// Best-effort hardware tag. Format: lowercase, hyphens only,
/// no whitespace, safe for filenames on all major filesystems.
pub fn tag() -> String {
    if let Some(s) = macos_brand_string() {
        return slugify(&s);
    }
    if let Some(s) = linux_cpuinfo_model_name() {
        return slugify(&s);
    }
    "unknown".to_string()
}

#[cfg(target_os = "macos")]
fn macos_brand_string() -> Option<String> {
    let out = Command::new("sysctl")
        .args(["-n", "machdep.cpu.brand_string"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8(out.stdout).ok()?;
    let trimmed = s.trim();
    if trimmed.is_empty() { None } else { Some(trimmed.to_string()) }
}

#[cfg(not(target_os = "macos"))]
fn macos_brand_string() -> Option<String> { None }

#[cfg(target_os = "linux")]
fn linux_cpuinfo_model_name() -> Option<String> {
    let content = std::fs::read_to_string("/proc/cpuinfo").ok()?;
    for line in content.lines() {
        if let Some(rest) = line.strip_prefix("model name") {
            if let Some(idx) = rest.find(':') {
                let name = rest[idx + 1..].trim();
                if !name.is_empty() {
                    return Some(name.to_string());
                }
            }
        }
    }
    // ARM systems sometimes use "CPU implementer" + "CPU part"
    // instead of "model name". Fall back to whatever we can find.
    for line in content.lines() {
        if let Some(rest) = line.strip_prefix("Hardware") {
            if let Some(idx) = rest.find(':') {
                let name = rest[idx + 1..].trim();
                if !name.is_empty() {
                    return Some(name.to_string());
                }
            }
        }
    }
    None
}

#[cfg(not(target_os = "linux"))]
fn linux_cpuinfo_model_name() -> Option<String> { None }

/// Lowercase + collapse non-alphanumeric to single hyphen +
/// trim leading/trailing hyphens. Result is filename-safe on
/// every modern filesystem.
fn slugify(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut prev_hyphen = true; // suppresses leading hyphen
    for c in s.chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c.to_ascii_lowercase());
            prev_hyphen = false;
        } else if !prev_hyphen {
            out.push('-');
            prev_hyphen = true;
        }
    }
    if out.ends_with('-') { out.pop(); }
    if out.is_empty() { "unknown".to_string() } else { out }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slugify_basic() {
        assert_eq!(slugify("Apple M3 Max"), "apple-m3-max");
        assert_eq!(slugify("Intel(R) Xeon(R) Platinum 8480CL"),
                   "intel-r-xeon-r-platinum-8480cl");
        assert_eq!(slugify("  "), "unknown");
        assert_eq!(slugify("foo--bar"), "foo-bar");
    }

    #[test]
    fn tag_returns_nonempty() {
        let t = tag();
        assert!(!t.is_empty());
        assert!(!t.contains(' '));
        assert!(!t.contains('/'));
    }
}
