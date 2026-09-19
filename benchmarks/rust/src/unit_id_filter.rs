//! --ids support: pinned debug subsets. Twin of Swift `UnitIDFilter.swift`.
//!
//! A lane given an IDs file runs exactly those units — the instrument that
//! reproduces full-run figures on a small fixed subset (pinned via an IDs
//! file). Selection happens after corpus load and
//! BEFORE the seeded shuffle, so the same IDs file selects the same units
//! regardless of --offset/--limit. Validation (every requested ID must exist
//! in the loaded corpus) runs at the CLI layer before the runner is invoked;
//! a miss is a hard error, never a silent shrink.

use std::collections::HashSet;

/// Loads a unit-ID file: one ID per line; blank lines and #-comments skipped.
pub fn load_unit_ids(path: &str) -> Result<HashSet<String>, String> {
    let raw = std::fs::read_to_string(path)
        .map_err(|_| format!("--ids file not readable: {path}"))?;
    let ids: HashSet<String> = raw
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .map(str::to_string)
        .collect();
    if ids.is_empty() {
        return Err(format!("--ids file contains no ids: {path}"));
    }
    Ok(ids)
}

/// Normalises a unit ID that may arrive in stem form (`<evidence>__scene_N_q_M`)
/// to the bare query-id form (`scene_N_q_M`). Twin of Swift `normalizeUnitID`.
///
/// Three cases are handled:
/// - `"ET1__scene_3_q_7"` → `"scene_3_q_7"` (stem-form stripped)
/// - `"scene_3_q_7"` → `"scene_3_q_7"` (already bare, returned unchanged)
/// - `"some_other_id"` → `"some_other_id"` (no `__scene_` marker, returned unchanged)
pub fn normalize_unit_id(id: &str) -> String {
    if let Some(pos) = id.find("__scene_") {
        format!("scene_{}", &id[pos + "__scene_".len()..])
    } else {
        id.to_string()
    }
}

/// Validates that every requested ID exists among the loaded unit IDs.
pub fn validate_unit_ids<'a>(
    requested: &HashSet<String>,
    present: impl Iterator<Item = &'a str>,
    lane: &str,
) -> Result<(), String> {
    let present: HashSet<&str> = present.collect();
    let mut missing: Vec<&String> = requested
        .iter()
        .filter(|id| !present.contains(id.as_str()))
        .collect();
    if missing.is_empty() {
        return Ok(());
    }
    missing.sort();
    let sample: Vec<String> = missing.iter().take(5).map(|s| s.to_string()).collect();
    Err(format!(
        "[{lane}] --ids: {} id(s) not in the loaded corpus (first: {}). \
         The ids file does not match this data set.",
        missing.len(),
        sample.join(", ")
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validate_passes_when_all_present() {
        let req: HashSet<String> = ["a".into(), "b".into()].into();
        assert!(validate_unit_ids(&req, ["a", "b", "c"].into_iter(), "t").is_ok());
    }

    #[test]
    fn validate_fails_loud_on_missing() {
        let req: HashSet<String> = ["a".into(), "zz".into()].into();
        let err = validate_unit_ids(&req, ["a", "b"].into_iter(), "t").unwrap_err();
        assert!(err.contains("1 id(s) not in the loaded corpus"));
        assert!(err.contains("zz"));
    }

    // normalize_unit_id — item (c) gate
    // Three cases. A normaliser that strips too much passes a one-case test.

    #[test]
    fn normalize_strips_prefix() {
        // "ET1__scene_3_q_7" → "scene_3_q_7"
        // Fails if prefix stripping is absent, broken, or over-strips.
        assert_eq!(normalize_unit_id("ET1__scene_3_q_7"), "scene_3_q_7");
    }

    #[test]
    fn normalize_bare_passthrough() {
        // "scene_3_q_7" → "scene_3_q_7" — no prefix, must not be modified.
        assert_eq!(normalize_unit_id("scene_3_q_7"), "scene_3_q_7");
    }

    #[test]
    fn normalize_no_scene_marker_passthrough() {
        // "some_other_id" has no "__scene_" substring; returned as-is.
        assert_eq!(normalize_unit_id("some_other_id"), "some_other_id");
    }
}
